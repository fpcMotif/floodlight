//! The C ABI for embedders outside Zig. See include/nanospot_core.h for the
//! contract; this file only translates it.

const std = @import("std");
const index = @import("index.zig");
const file_index = @import("file_index.zig");
const search = @import("search.zig");
const sys = @import("sys.zig");

/// The `ns_index` the header keeps opaque.
const Handle = index.Mapped;

/// There is one handle per open index, a few words each, so the
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
        else => -1000,
    };
}

export fn ns_index_build(root: ?[*:0]const u8, out_path: ?[*:0]const u8) c_int {
    const r = root orelse return -22;
    const o = out_path orelse return -22;
    const n = file_index.writeIndex(gpa, .{}, std.mem.span(r), std.mem.span(o)) catch |e| return errnoOf(e);
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

export fn ns_index_open(path: ?[*:0]const u8, out: ?*?*Handle) c_int {
    const out_ptr = out orelse return -22;
    out_ptr.* = null;
    const p = path orelse return -22;
    const mapped = index.Mapped.open(sys.cwd, std.mem.span(p)) catch |e| return errnoOf(e);
    const h = gpa.create(Handle) catch {
        var m = mapped;
        m.close();
        return errnoOf(error.OutOfMemory);
    };
    h.* = mapped;
    out_ptr.* = h;
    return 0;
}

export fn ns_index_close(h: ?*Handle) void {
    const handle = h orelse return;
    handle.close();
    gpa.destroy(handle);
}

export fn ns_index_count(h: ?*const Handle) u32 {
    const handle = h orelse return 0;
    return handle.view.count();
}

export fn ns_search(h: ?*const Handle, query: ?[*:0]const u8, out: ?[*]search.Hit, cap: u32) u32 {
    const handle = h orelse return 0;
    const q = query orelse return 0;
    const dst = out orelse return 0;
    if (cap == 0) return 0;
    const n = search.search(handle.view, std.mem.span(q), dst[0..@min(cap, search.max_k)]);
    return @intCast(n);
}

export fn ns_relative_path(h: ?*const Handle, id: u32, buf: ?[*]u8, cap: u32) u32 {
    const handle = h orelse return 0;
    const dst = buf orelse return 0;
    if (cap == 0) return 0;
    const v = handle.view;
    if (id >= v.count()) return 0;
    var scratch: [4096]u8 = undefined;
    const p = v.relativePath(id, &scratch) orelse return 0;
    if (p.len + 1 > cap) return 0;
    @memcpy(dst[0..p.len], p);
    dst[p.len] = 0;
    return @intCast(p.len);
}

export fn ns_is_dir(h: ?*const Handle, id: u32) bool {
    const handle = h orelse return false;
    const v = handle.view;
    return id < v.flags.len and v.flags[id].dir;
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

    try t.expectEqual(@as(c_int, 3), ns_index_build(@ptrCast(&root_z), idx.ptr));
    var h: ?*Handle = null;
    try t.expectEqual(@as(c_int, 0), ns_index_open(idx.ptr, &h));
    defer ns_index_close(h);

    var hits: [4]search.Hit = undefined;
    const n = ns_search(h.?, "blue", &hits, hits.len);
    try t.expect(n >= 1);
    var pbuf: [128]u8 = undefined;
    const len = ns_relative_path(h.?, hits[0].id, &pbuf, pbuf.len);
    try t.expectEqualStrings("Music/Albums/kind-of-blue.flac", pbuf[0..len]);
    try t.expect(!ns_is_dir(h.?, hits[0].id));
}

test "C ABI tolerates null pointers and zero capacities" {
    const t = std.testing;
    try t.expectEqual(@as(c_int, -22), ns_index_build(null, null));
    try t.expectEqual(@as(c_int, -22), ns_index_open(null, null));
    var h: ?*Handle = null;
    try t.expectEqual(@as(c_int, -22), ns_index_open(null, &h));
    ns_index_close(null);
    try t.expectEqual(@as(u32, 0), ns_index_count(null));
    var hit_buf: [4]search.Hit = undefined;
    try t.expectEqual(@as(u32, 0), ns_search(null, "a", &hit_buf, hit_buf.len));
    var path_buf: [16]u8 = undefined;
    try t.expectEqual(@as(u32, 0), ns_relative_path(null, 0, &path_buf, path_buf.len));
    try t.expect(!ns_is_dir(null, 0));

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "" });
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    var root_z: [std.posix.PATH_MAX + 1]u8 = undefined;
    @memcpy(root_z[0..root.len], root);
    root_z[root.len] = 0;
    var idx_buf: [std.posix.PATH_MAX + 8]u8 = undefined;
    const idx = try std.fmt.bufPrintSentinel(&idx_buf, "{s}/i.flix", .{root}, 0);
    try t.expectEqual(@as(c_int, 1), ns_index_build(@ptrCast(&root_z), idx.ptr));
    try t.expectEqual(@as(c_int, 0), ns_index_open(idx.ptr, &h));
    defer ns_index_close(h);

    try t.expectEqual(@as(u32, 0), ns_search(h, null, &hit_buf, hit_buf.len));
    try t.expectEqual(@as(u32, 0), ns_search(h, "a", null, hit_buf.len));
    try t.expectEqual(@as(u32, 0), ns_search(h, "a", &hit_buf, 0));
    try t.expectEqual(@as(u32, 0), ns_relative_path(h, 0, null, path_buf.len));
    try t.expectEqual(@as(u32, 0), ns_relative_path(h, 0, &path_buf, 0));
    try t.expect(!ns_is_dir(h, 999));
}
