//! The C ABI the Swift shell links against. See include/floodlight_core.h for
//! the contract; this file only translates it.

const std = @import("std");
const index = @import("index.zig");
const scan = @import("scan.zig");
const search = @import("search.zig");

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
        error.CorruptIndex => -1001,
        error.IndexTooLarge => -1002,
        else => -1000,
    };
}

export fn fl_index_build(root: [*:0]const u8, out_path: [*:0]const u8) c_int {
    var b = index.Builder.init(gpa);
    defer b.deinit();
    scan.scan(&b, std.mem.span(root), .{}) catch |e| return errnoOf(e);
    b.writeFile(std.fs.cwd(), std.mem.span(out_path)) catch |e| return errnoOf(e);
    return @intCast(@min(b.count(), std.math.maxInt(c_int)));
}

export fn fl_index_open(path: [*:0]const u8, out: *?*Handle) c_int {
    out.* = null;
    const mapped = index.Mapped.open(std.fs.cwd(), std.mem.span(path)) catch |e| return errnoOf(e);
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

test "build, open, search through the ABI" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("Music/Albums");
    try tmp.dir.writeFile(.{ .sub_path = "Music/Albums/kind-of-blue.flac", .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    var idx_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const idx = try std.fmt.bufPrintZ(&idx_buf, "{s}/i.flix", .{root});
    var root_z: [std.fs.max_path_bytes + 1]u8 = undefined;
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
