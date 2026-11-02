//! The C ABI the Swift shell links against. See include/floodlight_core.h for
//! the contract; this file only translates it.

const std = @import("std");
const index = @import("index.zig");
const scan = @import("scan.zig");
const search = @import("search.zig");
const sys = @import("sys.zig");
const live = @import("live.zig");
const watch = @import("watch.zig");

const Handle = struct {
    mapped: index.Mapped,
};

/// Handles are a few words each and live for the app's lifetime, so the
/// general-purpose allocator's per-thread caches buy nothing here.
const gpa = std.heap.smp_allocator;

fn errnoOf(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -12,
        error.FileNotFound => -2,
        error.AccessDenied => -13,
        error.NotDir => -20,
        error.NoSpaceLeft => -28,
        error.NameTooLong => -63,
        error.CorruptIndex => -1001,
        error.IndexTooLarge => -1002,
        error.LimitReached => -1003,
        else => -1000,
    };
}

export fn fl_index_build(root: [*:0]const u8, out_path: [*:0]const u8) c_int {
    var b = index.Builder.init(gpa);
    defer b.deinit();
    scan.scan(&b, std.mem.span(root), .{}) catch |e| return errnoOf(e);
    b.writeFile(sys.cwd, std.mem.span(out_path)) catch |e| return errnoOf(e);
    return @intCast(@min(b.count(), std.math.maxInt(c_int)));
}

export fn fl_index_open(path: [*:0]const u8, out: *?*Handle) c_int {
    out.* = null;
    const mapped = index.Mapped.open(sys.cwd, std.mem.span(path)) catch |e| return errnoOf(e);
    const h = gpa.create(Handle) catch {
        var m = mapped;
        m.close();
        return -12;
    };
    h.* = .{ .mapped = mapped };
    out.* = h;
    return 0;
}

export fn fl_index_close(h: ?*Handle) void {
    const handle = h orelse return;
    handle.mapped.close();
    gpa.destroy(handle);
}

export fn fl_index_count(h: *const Handle) u32 {
    return h.mapped.view.count();
}

export fn fl_search(h: *const Handle, query: [*:0]const u8, out: [*]search.Hit, cap: u32) u32 {
    const n = search.search(h.mapped.view, std.mem.span(query), out[0..@min(cap, search.max_k)]);
    return @intCast(n);
}

export fn fl_relative_path(h: *const Handle, id: u32, buf: [*]u8, cap: u32) u32 {
    const v = h.mapped.view;
    if (id >= v.count() or cap == 0) return 0;
    var scratch: [4096]u8 = undefined;
    const p = v.relativePath(id, &scratch) orelse return 0;
    if (p.len + 1 > cap) return 0;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return @intCast(p.len);
}

export fn fl_is_dir(h: *const Handle, id: u32) bool {
    const v = h.mapped.view;
    return id < v.count() and v.flags[id].dir;
}

/// A live index plus the watcher feeding it, if one was started.
const LiveHandle = struct {
    live: *live.Live,
    watcher: ?*watch.Watcher = null,
};

export fn fl_live_open(root: [*:0]const u8, index_path: [*:0]const u8, overlay_limit: u32, out: *?*LiveHandle) c_int {
    out.* = null;
    var opts: live.Options = .{};
    if (overlay_limit != 0) opts.overlay_limit = overlay_limit;
    const l = live.Live.open(gpa, std.mem.span(root), std.mem.span(index_path), opts) catch |e| return errnoOf(e);
    const h = gpa.create(LiveHandle) catch {
        l.close();
        return -12;
    };
    h.* = .{ .live = l };
    out.* = h;
    return 0;
}

export fn fl_live_close(h: ?*LiveHandle) void {
    const handle = h orelse return;
    if (handle.watcher) |w| w.stop();
    handle.live.close();
    gpa.destroy(handle);
}

export fn fl_live_watch(h: *LiveHandle) c_int {
    if (h.watcher != null) return 0;
    h.watcher = watch.Watcher.start(gpa, h.live) catch |e| return errnoOf(e);
    return 0;
}

export fn fl_live_notify(h: *LiveHandle, rel_path: [*:0]const u8) void {
    h.live.notify(std.mem.span(rel_path));
}

export fn fl_live_compact(h: *LiveHandle) c_int {
    h.live.compact() catch |e| return errnoOf(e);
    return 0;
}

export fn fl_live_search(h: *LiveHandle, query: [*:0]const u8, out: [*]search.Hit, cap: u32, generation: ?*u64) u32 {
    return @intCast(h.live.search(std.mem.span(query), out[0..@min(cap, search.max_k)], generation));
}

export fn fl_live_relative_path(h: *LiveHandle, generation: u64, id: u32, buf: [*]u8, cap: u32) u32 {
    if (cap == 0) return 0;
    var scratch: [4096]u8 = undefined;
    const p = h.live.relativePath(generation, id, &scratch) orelse return 0;
    if (p.len + 1 > cap) return 0;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return @intCast(p.len);
}

export fn fl_live_is_dir(h: *LiveHandle, generation: u64, id: u32) bool {
    return h.live.isDir(generation, id);
}

test "build, open, search through the ABI" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Music/Albums");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Music/Albums/kind-of-blue.flac", .data = "" });
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    var idx_buf: [std.posix.PATH_MAX + 8]u8 = undefined;
    const idx = try std.fmt.bufPrintSentinel(&idx_buf, "{s}/i.flix", .{root}, 0);
    var root_z: [std.posix.PATH_MAX + 1]u8 = undefined;
    @memcpy(root_z[0..root.len], root);
    root_z[root.len] = 0;

    try t.expectEqual(@as(c_int, 3), fl_index_build(@ptrCast(&root_z), idx.ptr));
    var h: ?*Handle = null;
    try t.expectEqual(@as(c_int, 0), fl_index_open(idx.ptr, &h));
    defer fl_index_close(h);

    var hits: [4]search.Hit = undefined;
    const n = fl_search(h.?, "blue", &hits, hits.len);
    try t.expect(n >= 1);
    var pbuf: [128]u8 = undefined;
    const len = fl_relative_path(h.?, hits[0].id, &pbuf, pbuf.len);
    try t.expectEqualStrings("Music/Albums/kind-of-blue.flac", pbuf[0..len]);
    try t.expect(!fl_is_dir(h.?, hits[0].id));
}

test "live index through the ABI" {
    const t = std.testing;
    var tree = t.tmpDir(.{});
    defer tree.cleanup();
    var store = t.tmpDir(.{});
    defer store.cleanup();
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root_len = try tree.dir.realPath(t.io, &root_buf);
    var root_z: [std.posix.PATH_MAX + 1]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&root_z, "{s}", .{root_buf[0..root_len]}, 0);
    var store_buf: [std.posix.PATH_MAX]u8 = undefined;
    const store_len = try store.dir.realPath(t.io, &store_buf);
    var idx_buf: [std.posix.PATH_MAX + 8]u8 = undefined;
    const idx = try std.fmt.bufPrintSentinel(&idx_buf, "{s}/i.flix", .{store_buf[0..store_len]}, 0);

    var h: ?*LiveHandle = null;
    try t.expectEqual(@as(c_int, 0), fl_live_open(root.ptr, idx.ptr, 0, &h));
    defer fl_live_close(h);

    sys.close(try sys.openat(tree.dir.handle, "budget.ods", .create));
    fl_live_notify(h.?, "budget.ods");
    var hits: [4]search.Hit = undefined;
    var generation: u64 = 0;
    try t.expectEqual(@as(u32, 1), fl_live_search(h.?, "budget", &hits, hits.len, &generation));
    var pbuf: [64]u8 = undefined;
    const len = fl_live_relative_path(h.?, generation, hits[0].id, &pbuf, pbuf.len);
    try t.expectEqualStrings("budget.ods", pbuf[0..len]);
    try t.expect(!fl_live_is_dir(h.?, generation, hits[0].id));

    try t.expectEqual(@as(c_int, 0), fl_live_compact(h.?));
    try t.expectEqual(@as(u32, 0), fl_live_relative_path(h.?, generation, hits[0].id, &pbuf, pbuf.len));
    try t.expectEqual(@as(u32, 1), fl_live_search(h.?, "budget", &hits, hits.len, &generation));
    try t.expect(fl_live_relative_path(h.?, generation, hits[0].id, &pbuf, pbuf.len) > 0);
}
