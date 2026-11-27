const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mac = @import("mac.zig");

pub const max_icons: usize = 64;
const max_seen: usize = max_icons * 4;
const max_batch: usize = 16;

extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const qos_class_user_initiated: c_uint = 0x19;

pub const Kind = enum { app, file, folder, unknown };

pub const Image = struct {
    key: []const u8,
    pixels: ui.ImageSource.Pixels,
};

pub const FetchFn = *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, px: f64) ?mac.Icon;

pub const Wake = struct {
    ctx: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) void = noWake,
};

fn noWake(_: ?*anyopaque) void {}

fn noFetch(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: f64) ?mac.Icon {
    return null;
}

pub fn keyFor(buf: []u8, path: []const u8, kind: Kind) ?[]const u8 {
    if (path.len == 0) return null;
    const stripped = std.mem.trimEnd(u8, path, "/");
    const trimmed = if (stripped.len > 0) stripped else "/";
    const raw = std.fs.path.extension(trimmed);
    const ext = if (raw.len > 1) raw[1..] else "";
    if (kind == .app or std.ascii.eqlIgnoreCase(ext, "app")) {
        return std.fmt.bufPrint(buf, "app:{s}", .{trimmed}) catch null;
    }
    if (kind == .folder) return "folder";
    if (kind == .file) {
        if (4 + ext.len > buf.len) return null;
        @memcpy(buf[0..4], "ext:");
        for (ext, 0..) |ch, i| buf[4 + i] = std.ascii.toLower(ch);
        return buf[0 .. 4 + ext.len];
    }
    return std.fmt.bufPrint(buf, "path:{s}", .{trimmed}) catch null;
}

pub const Cache = struct {
    const SeenState = enum { queued, failed };

    const Job = struct {
        seq: u64,
        key: []u8,
        path: []u8,
    };

    const Result = struct {
        seq: u64,
        key: []u8,
        icon: ?mac.Icon,
    };

    gpa: std.mem.Allocator,
    icon_px: f64,
    entries: std.StringHashMapUnmanaged(mac.Icon) = .empty,
    seen: std.StringHashMapUnmanaged(SeenState) = .empty,
    in_flight: usize = 0,
    session_seq: u64 = 1,
    worker_started: bool = false,

    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopped: bool = false,
    active_seq: u64 = 1,
    pending_jobs: std.ArrayList(Job) = .empty,
    pending_head: usize = 0,
    ready: std.ArrayList(Result) = .empty,
    wake_scheduled: bool = false,
    fetch_ctx: ?*anyopaque = null,
    fetch_fn: FetchFn = noFetch,
    wake: Wake = .{},

    pub fn init(gpa: std.mem.Allocator, icon_px: f64) Cache {
        return .{ .gpa = gpa, .icon_px = icon_px };
    }

    pub fn deinit(c: *Cache) void {
        c.stopWorker();
        c.freeQueued();
        c.pending_jobs.deinit(c.gpa);
        c.ready.deinit(c.gpa);
        c.freeEntries();
        c.entries.deinit(c.gpa);
        c.freeSeen();
        c.seen.deinit(c.gpa);
        c.* = undefined;
    }

    pub fn startWorker(c: *Cache, io: std.Io, fetch_ctx: ?*anyopaque, fetch_fn: FetchFn, wake: Wake) void {
        if (c.worker_started) return;
        c.io = io;
        c.fetch_ctx = fetch_ctx;
        c.fetch_fn = fetch_fn;
        c.wake = wake;
        c.stopped = false;
        c.active_seq = c.session_seq;
        c.thread = std.Thread.spawn(.{}, run, .{c}) catch |err| {
            if (!@import("builtin").is_test) std.log.err("icons: no worker thread: {s}", .{@errorName(err)});
            return;
        };
        c.worker_started = true;
    }

    pub fn stopWorker(c: *Cache) void {
        const th = c.thread orelse return;
        c.mutex.lockUncancelable(c.io);
        c.stopped = true;
        c.cond.signal(c.io);
        c.mutex.unlock(c.io);
        th.join();
        c.thread = null;
        c.worker_started = false;
    }

    pub fn count(c: *const Cache) usize {
        return c.entries.count();
    }

    pub fn hasPending(c: *const Cache) bool {
        return c.in_flight > 0;
    }

    pub fn lookupOrEnqueue(c: *Cache, path: []const u8, kind: Kind) ?Image {
        var key_buf: [4096]u8 = undefined;
        const key = keyFor(&key_buf, path, kind) orelse return null;
        if (c.entries.getEntry(key)) |e| return .{ .key = e.key_ptr.*, .pixels = e.value_ptr.pixels() };
        c.enqueueKey(key, path);
        return null;
    }

    pub fn prefetch(c: *Cache, path: []const u8, kind: Kind) void {
        _ = c.lookupOrEnqueue(path, kind);
    }

    fn enqueueKey(c: *Cache, key: []const u8, path: []const u8) void {
        if (!c.worker_started) return;
        if (c.seen.contains(key)) return;
        if (c.entries.count() + c.in_flight >= max_icons) return;
        if (c.seen.count() >= max_seen) return;

        const seen_key = c.gpa.dupe(u8, key) catch return;
        const job_key = c.gpa.dupe(u8, key) catch {
            c.gpa.free(seen_key);
            return;
        };
        const job_path = c.gpa.dupe(u8, path) catch {
            c.gpa.free(job_key);
            c.gpa.free(seen_key);
            return;
        };
        c.seen.put(c.gpa, seen_key, .queued) catch {
            c.gpa.free(job_path);
            c.gpa.free(job_key);
            c.gpa.free(seen_key);
            return;
        };

        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.pending_jobs.append(c.gpa, .{ .seq = c.session_seq, .key = job_key, .path = job_path }) catch {
                if (c.seen.fetchRemove(key)) |old| c.gpa.free(old.key);
                c.gpa.free(job_path);
                c.gpa.free(job_key);
                return;
            };
            c.cond.signal(c.io);
        }
        c.in_flight += 1;
    }

    pub fn poll(c: *Cache) bool {
        if (!c.worker_started) return false;
        var batch: std.ArrayList(Result) = .empty;
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            batch = c.ready;
            c.ready = .empty;
            c.wake_scheduled = false;
        }
        defer batch.deinit(c.gpa);

        var changed = false;
        for (batch.items) |res| {
            if (res.seq != c.session_seq) {
                c.gpa.free(res.key);
                if (res.icon) |ic| ic.deinit(c.gpa);
                continue;
            }
            c.in_flight -|= 1;
            if (res.icon) |ic| {
                if (c.entries.count() < max_icons and !c.entries.contains(res.key)) {
                    if (c.entries.put(c.gpa, res.key, ic)) |_| {
                        if (c.seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                        changed = true;
                        continue;
                    } else |_| {}
                }
                if (c.seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                c.gpa.free(res.key);
                ic.deinit(c.gpa);
                continue;
            }
            if (c.seen.getPtr(res.key)) |st| st.* = .failed;
            c.gpa.free(res.key);
        }
        return changed;
    }

    pub fn clear(c: *Cache) void {
        c.session_seq += 1;
        c.in_flight = 0;
        if (c.worker_started) {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.active_seq = c.session_seq;
            c.freeQueued();
            c.wake_scheduled = false;
        }
        c.freeEntries();
        c.entries.clearRetainingCapacity();
        c.freeSeen();
        c.seen.clearRetainingCapacity();
    }

    fn freeQueued(c: *Cache) void {
        for (c.pending_jobs.items[c.pending_head..]) |job| {
            c.gpa.free(job.key);
            c.gpa.free(job.path);
        }
        c.pending_head = 0;
        c.pending_jobs.clearRetainingCapacity();
        for (c.ready.items) |res| {
            c.gpa.free(res.key);
            if (res.icon) |ic| ic.deinit(c.gpa);
        }
        c.ready.clearRetainingCapacity();
    }

    fn freeEntries(c: *Cache) void {
        var it = c.entries.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(c.gpa);
        }
    }

    fn freeSeen(c: *Cache) void {
        var it = c.seen.keyIterator();
        while (it.next()) |k| c.gpa.free(k.*);
    }

    fn hasCurrentJobLocked(c: *const Cache) bool {
        for (c.pending_jobs.items[c.pending_head..]) |job| {
            if (job.seq == c.active_seq) return true;
        }
        return false;
    }

    fn run(c: *Cache) void {
        _ = pthread_set_qos_class_self_np(qos_class_user_initiated, 0);
        while (true) {
            var job: Job = undefined;
            {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                while (!c.stopped and c.pending_head >= c.pending_jobs.items.len) {
                    c.cond.waitUncancelable(c.io, &c.mutex);
                }
                if (c.stopped) return;
                job = c.pending_jobs.items[c.pending_head];
                c.pending_head += 1;
                if (c.pending_head == c.pending_jobs.items.len) {
                    c.pending_head = 0;
                    c.pending_jobs.clearRetainingCapacity();
                }
                if (job.seq != c.active_seq) {
                    c.gpa.free(job.key);
                    c.gpa.free(job.path);
                    continue;
                }
            }
            const icon = c.fetch_fn(c.fetch_ctx, c.gpa, job.path, c.icon_px);
            c.gpa.free(job.path);
            var should_wake = false;
            var wake: Wake = .{};
            {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                if (c.stopped or job.seq != c.active_seq) {
                    c.gpa.free(job.key);
                    if (icon) |ic| ic.deinit(c.gpa);
                    continue;
                }
                c.ready.append(c.gpa, .{ .seq = job.seq, .key = job.key, .icon = icon }) catch {
                    c.gpa.free(job.key);
                    if (icon) |ic| ic.deinit(c.gpa);
                    continue;
                };
                const has_more = c.hasCurrentJobLocked();
                if ((!has_more or c.ready.items.len >= max_batch) and !c.wake_scheduled) {
                    c.wake_scheduled = true;
                    should_wake = true;
                    wake = c.wake;
                }
            }
            if (should_wake) wake.wake(wake.ctx);
        }
    }
};

const t = std.testing;

test "keyFor normalizes bundles, folders, extensions, and unknown paths" {
    var buf: [256]u8 = undefined;
    try t.expect(keyFor(&buf, "", .file) == null);
    try t.expectEqualStrings("app:/Applications/Calendar.app", keyFor(&buf, "/Applications/Calendar.app", .app).?);
    try t.expectEqualStrings("app:/Applications/Calendar.app", keyFor(&buf, "/Applications/Calendar.app/", .unknown).?);
    try t.expectEqualStrings("app:/Applications/Notes.APP", keyFor(&buf, "/Applications/Notes.APP", .unknown).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/Users/f/alpha", .folder).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/Users/f/beta.dir/", .folder).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/", .folder).?);
    try t.expectEqualStrings("ext:pdf", keyFor(&buf, "/Users/f/first.pdf", .file).?);
    try t.expectEqualStrings("ext:pdf", keyFor(&buf, "/Users/f/SECOND.PDF", .file).?);
    try t.expectEqualStrings("ext:", keyFor(&buf, "/Users/f/.gitignore", .file).?);
    try t.expectEqualStrings("ext:", keyFor(&buf, "/Users/f/README", .file).?);
    try t.expectEqualStrings("path:/Users/f/Makefile", keyFor(&buf, "/Users/f/Makefile", .unknown).?);

    var tiny: [4]u8 = undefined;
    try t.expect(keyFor(&tiny, "/Applications/Calendar.app", .app) == null);
    try t.expect(keyFor(&tiny, "/Users/f/first.pdf", .file) == null);
    try t.expect(keyFor(&tiny, "/Users/f/Makefile", .unknown) == null);
}
