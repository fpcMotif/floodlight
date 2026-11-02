//! File-system event sources that feed `Live.notify`.
//!
//! macOS: FSEvents through the CoreServices C API, delivered on a private
//! dispatch queue. One stream covers the whole tree, and file-level events
//! name each changed path. Linux: inotify, one watch per indexed folder,
//! read on a thread of its own. It exists so the live path runs under test
//! off a Mac; a home folder past the kernel's watch limit loses events below
//! the folders it could not watch until the next rescan.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("live.zig");
const index = @import("index.zig");
const scan = @import("scan.zig");
const sys = @import("sys.zig");

pub const Watcher = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos => FsEvents,
    else => @compileError("floodlight-core watches macOS and Linux only"),
};

/// `full` is root plus a path below it. Returns the part after the root, or
/// null for a path outside it. FSEvents reports resolved paths, so the root
/// compared against is resolved too.
fn relativeTo(root: []const u8, full: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, full, root)) return null;
    if (full.len == root.len) return "";
    if (full[root.len] != '/') return null;
    return full[root.len + 1 ..];
}

const Inotify = struct {
    const linux = std.os.linux;
    const IN = linux.IN;
    const events = IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF;

    gpa: std.mem.Allocator,
    target: *live.Live,
    fd: sys.fd_t,
    /// An eventfd; writing to it ends the read loop.
    stop_fd: sys.fd_t,
    /// Watch descriptor to the folder it watches, relative to the root.
    /// Touched only by the starting thread before the loop runs, then only
    /// by the loop.
    folders: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
    thread: ?std.Thread = null,

    pub fn start(gpa: std.mem.Allocator, target: *live.Live) !*Inotify {
        const w = try gpa.create(Inotify);
        errdefer gpa.destroy(w);
        const fd = try check(linux.inotify_init1(IN.CLOEXEC));
        errdefer sys.close(fd);
        const stop_fd = try check(linux.eventfd(0, linux.EFD.CLOEXEC));
        errdefer sys.close(stop_fd);
        w.* = .{ .gpa = gpa, .target = target, .fd = fd, .stop_fd = stop_fd };
        errdefer w.freeFolders();
        try w.watchTree("");
        w.thread = try std.Thread.spawn(.{}, run, .{w});
        return w;
    }

    pub fn stop(w: *Inotify) void {
        const one: u64 = 1;
        _ = linux.write(w.stop_fd, std.mem.asBytes(&one), 8);
        if (w.thread) |th| th.join();
        w.freeFolders();
        sys.close(w.fd);
        sys.close(w.stop_fd);
        w.gpa.destroy(w);
    }

    fn check(rc: usize) !sys.fd_t {
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => error.Unexpected,
        };
    }

    fn freeFolders(w: *Inotify) void {
        var it = w.folders.valueIterator();
        while (it.next()) |v| w.gpa.free(v.*);
        w.folders.deinit(w.gpa);
    }

    /// Watches `rel` and every folder a scan would index below it. Listed
    /// from disk rather than from the index, so a folder that is not in the
    /// index yet is covered too.
    fn watchTree(w: *Inotify, rel: []const u8) !void {
        var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
        const abs = if (rel.len == 0) w.target.root else std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ w.target.root, rel }) catch return;
        w.watch(rel);
        var b = index.Builder.init(w.gpa);
        defer b.deinit();
        scan.scan(&b, abs, w.target.opts.scan) catch return;
        var sub_buf: [std.posix.PATH_MAX]u8 = undefined;
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        var id: u32 = 0;
        while (id < b.count()) : (id += 1) {
            if (!b.isDir(id)) continue;
            const sub = b.view().relativePath(id, &sub_buf) orelse continue;
            const p = if (rel.len == 0) sub else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rel, sub }) catch continue;
            w.watch(p);
        }
    }

    fn watch(w: *Inotify, rel: []const u8) void {
        var abs_buf: [std.posix.PATH_MAX:0]u8 = undefined;
        const abs = (if (rel.len == 0)
            std.fmt.bufPrintSentinel(&abs_buf, "{s}", .{w.target.root}, 0)
        else
            std.fmt.bufPrintSentinel(&abs_buf, "{s}/{s}", .{ w.target.root, rel }, 0)) catch return;
        // Past the watch limit the folder goes unwatched; see the file
        // comment.
        const wd = check(linux.inotify_add_watch(w.fd, abs, events | IN.ONLYDIR | IN.DONT_FOLLOW)) catch return;
        const copy = w.gpa.dupe(u8, rel) catch return;
        const slot = w.folders.getOrPut(w.gpa, wd) catch return w.gpa.free(copy);
        if (slot.found_existing) w.gpa.free(slot.value_ptr.*);
        slot.value_ptr.* = copy;
    }

    /// Forgets watches on `rel` and below after the folder moved away. Its
    /// watch descriptors would otherwise keep reporting the old path.
    fn unwatchTree(w: *Inotify, rel: []const u8) void {
        var it = w.folders.iterator();
        while (it.next()) |e| {
            const p = e.value_ptr.*;
            const under = p.len > rel.len and p[rel.len] == '/' and std.mem.startsWith(u8, p, rel);
            if (under or std.mem.eql(u8, p, rel)) _ = linux.inotify_rm_watch(w.fd, e.key_ptr.*);
        }
    }

    fn run(w: *Inotify) void {
        var buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var fds = [_]linux.pollfd{
            .{ .fd = w.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = w.stop_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        while (true) {
            const rc = linux.poll(&fds, fds.len, -1);
            if (std.posix.errno(rc) == .INTR) continue;
            if (std.posix.errno(rc) != .SUCCESS or fds[1].revents != 0) return;
            const n = linux.read(w.fd, &buf, buf.len);
            if (std.posix.errno(n) != .SUCCESS) continue;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_bytes = buf[off + @sizeOf(linux.inotify_event) ..][0..ev.len];
                off += @sizeOf(linux.inotify_event) + ev.len;
                w.handle(ev.wd, ev.mask, std.mem.sliceTo(name_bytes, 0));
            }
        }
    }

    fn handle(w: *Inotify, wd: i32, mask: u32, name: []const u8) void {
        if (mask & IN.Q_OVERFLOW != 0) return w.target.rescan("");
        const folder = w.folders.get(wd) orelse return;
        if (mask & IN.IGNORED != 0) {
            if (w.folders.fetchRemove(wd)) |kv| w.gpa.free(kv.value);
            return;
        }
        if (name.len == 0) return;
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const rel = if (folder.len == 0) name else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ folder, name }) catch return;
        if (mask & IN.ISDIR != 0 and mask & IN.MOVED_FROM != 0) w.unwatchTree(rel);
        // Watch a new folder before `notify` lists it, so a file created in
        // between is caught by one or the other.
        if (mask & IN.ISDIR != 0 and mask & (IN.CREATE | IN.MOVED_TO) != 0) w.watchTree(rel) catch {};
        w.target.notify(rel);
    }
};

const FsEvents = struct {
    const CFIndex = isize;
    const Callback = *const fn (?*anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;
    const Context = extern struct {
        version: CFIndex = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };

    // <CoreServices/FSEvents.h>
    const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
    const create_no_defer: u32 = 0x02;
    const create_watch_root: u32 = 0x04;
    const create_file_events: u32 = 0x10;
    const event_must_scan_sub_dirs: u32 = 0x01;
    const event_user_dropped: u32 = 0x02;
    const event_kernel_dropped: u32 = 0x04;
    const event_root_changed: u32 = 0x20;
    const utf8: u32 = 0x08000100;

    extern const kCFTypeArrayCallBacks: u8;
    extern fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: u8) ?*anyopaque;
    extern fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*anyopaque, n: CFIndex, callbacks: *const anyopaque) ?*anyopaque;
    extern fn CFRelease(cf: *anyopaque) void;
    extern fn FSEventStreamCreate(alloc: ?*anyopaque, cb: Callback, ctx: *const Context, paths: *anyopaque, since: u64, latency: f64, flags: u32) ?*anyopaque;
    extern fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: ?*anyopaque) void;
    extern fn FSEventStreamStart(stream: *anyopaque) u8;
    extern fn FSEventStreamStop(stream: *anyopaque) void;
    extern fn FSEventStreamInvalidate(stream: *anyopaque) void;
    extern fn FSEventStreamRelease(stream: *anyopaque) void;
    extern fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
    extern fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
    extern fn dispatch_release(obj: *anyopaque) void;
    extern fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

    gpa: std.mem.Allocator,
    target: *live.Live,
    /// The root as FSEvents spells it: symlinks resolved (`/tmp` is
    /// `/private/tmp`).
    root_buf: [std.posix.PATH_MAX]u8,
    root_len: usize,
    stream: *anyopaque,
    queue: *anyopaque,

    pub fn start(gpa: std.mem.Allocator, target: *live.Live) !*FsEvents {
        const w = try gpa.create(FsEvents);
        errdefer gpa.destroy(w);
        w.gpa = gpa;
        w.target = target;
        var root_z: [std.posix.PATH_MAX:0]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&root_z, "{s}", .{target.root}, 0) catch return error.NameTooLong;
        const resolved = realpath(z.ptr, &w.root_buf) orelse return error.FileNotFound;
        w.root_len = std.mem.len(resolved);

        const path = CFStringCreateWithBytes(null, &w.root_buf, @intCast(w.root_len), utf8, 0) orelse return error.Unexpected;
        defer CFRelease(path);
        const values = [_]?*anyopaque{path};
        const paths = CFArrayCreate(null, &values, 1, &kCFTypeArrayCallBacks) orelse return error.Unexpected;
        defer CFRelease(paths);

        w.queue = dispatch_queue_create("floodlight.core.fsevents", null) orelse return error.Unexpected;
        errdefer dispatch_release(w.queue);
        const ctx: Context = .{ .info = w };
        // 50 ms: FSEvents coalesces a burst into one delivery, and NoDefer
        // delivers the first event of a quiet period at once.
        w.stream = FSEventStreamCreate(null, callback, &ctx, paths, since_now, 0.05, create_no_defer | create_watch_root | create_file_events) orelse return error.Unexpected;
        errdefer FSEventStreamRelease(w.stream);
        FSEventStreamSetDispatchQueue(w.stream, w.queue);
        if (FSEventStreamStart(w.stream) == 0) {
            FSEventStreamInvalidate(w.stream);
            return error.Unexpected;
        }
        return w;
    }

    pub fn stop(w: *FsEvents) void {
        FSEventStreamStop(w.stream);
        FSEventStreamInvalidate(w.stream);
        // An empty block through the queue: once it runs, no callback is
        // still in flight and `w` can be freed.
        dispatch_sync_f(w.queue, null, noop);
        FSEventStreamRelease(w.stream);
        dispatch_release(w.queue);
        w.gpa.destroy(w);
    }

    fn noop(_: ?*anyopaque) callconv(.c) void {}

    fn callback(_: ?*anyopaque, info: ?*anyopaque, n: usize, raw_paths: ?*anyopaque, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
        const w: *FsEvents = @ptrCast(@alignCast(info orelse return));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(raw_paths orelse return));
        const root = w.root_buf[0..w.root_len];
        for (0..n) |i| {
            const rel = relativeTo(root, std.mem.span(paths[i])) orelse continue;
            if (flags[i] & event_root_changed != 0) {
                w.target.rescan("");
            } else if (flags[i] & (event_must_scan_sub_dirs | event_user_dropped | event_kernel_dropped) != 0) {
                w.target.rescan(rel);
            } else {
                w.target.notify(rel);
            }
        }
    }
};

const t = std.testing;

test "relative paths under a root" {
    try t.expectEqualStrings("a/b", relativeTo("/r", "/r/a/b").?);
    try t.expectEqualStrings("", relativeTo("/r", "/r").?);
    try t.expect(relativeTo("/r", "/rx/a") == null);
    try t.expect(relativeTo("/r", "/q/a") == null);
}

fn topPath(l: *live.Live, query: []const u8, buf: []u8) ?[]const u8 {
    var hits: [4]@import("search.zig").Hit = undefined;
    var generation: u64 = 0;
    if (l.search(query, &hits, &generation) == 0) return null;
    return l.relativePath(generation, hits[0].id, buf);
}

/// Polls for up to four seconds: events arrive on the watcher's thread.
fn eventually(l: *live.Live, query: []const u8, want: ?[]const u8) bool {
    var buf: [256]u8 = undefined;
    for (0..400) |_| {
        const got = topPath(l, query, &buf);
        if (want) |w| {
            if (got != null and std.mem.eql(u8, got.?, w)) return true;
        } else if (got == null) return true;
        sys.sleepMs(10);
    }
    return false;
}

test "watcher sees create, rename, and delete" {
    var tree = t.tmpDir(.{});
    defer tree.cleanup();
    var store = t.tmpDir(.{});
    defer store.cleanup();
    try tree.dir.createDirPath(t.io, "work");
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buf[0..try tree.dir.realPath(t.io, &root_buf)];
    var store_buf: [std.posix.PATH_MAX]u8 = undefined;
    const store_path = store_buf[0..try store.dir.realPath(t.io, &store_buf)];
    var idx_buf: [std.posix.PATH_MAX]u8 = undefined;
    const idx = try std.fmt.bufPrint(&idx_buf, "{s}/i.flix", .{store_path});

    const l = try live.Live.open(t.allocator, root, idx, .{});
    defer l.close();
    const w = try Watcher.start(t.allocator, l);
    defer w.stop();

    sys.close(try sys.openat(tree.dir.handle, "work/draft.md", .create));
    try t.expect(eventually(l, "draft", "work/draft.md"));

    try sys.renameat(tree.dir.handle, "work/draft.md", "work/final.md");
    try t.expect(eventually(l, "final", "work/final.md"));
    try t.expect(eventually(l, "draft", null));

    // A folder created after the watch started is watched too.
    try tree.dir.createDirPath(t.io, "work/later");
    try t.expect(eventually(l, "later", "work/later"));
    sys.close(try sys.openat(tree.dir.handle, "work/later/inner.txt", .create));
    try t.expect(eventually(l, "inner", "work/later/inner.txt"));

    sys.unlinkat(tree.dir.handle, "work/final.md");
    try t.expect(eventually(l, "final", null));
}
