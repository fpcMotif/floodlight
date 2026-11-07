//! Directory walk straight on the kernel's bulk-listing call.
//!
//! macOS: `getattrlistbulk(2)` returns name and type for a whole batch of
//! entries per syscall, with no `stat` per file. Linux: `getdents64(2)`, the
//! same shape, so the engine can be built and benchmarked off a Mac.
//!
//! The walk is depth-first and recursive, holding one directory fd per level,
//! and every child is opened with `openat` relative to its parent. No full
//! path is ever built or handed to the kernel, so no path lookup is repeated.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");
const index = @import("index.zig");

pub const Options = struct {
    /// Dotfiles and dot-directories: what Finder and Spotlight hide.
    skip_hidden: bool = true,
    /// Bound on recursion, and so on open descriptors.
    max_depth: u16 = 48,
};

/// Directory names never worth descending into for a launcher: generated,
/// enormous, and never what someone types a name to find.
const pruned = [_][]const u8{
    "node_modules", "DerivedData", "__pycache__", "Caches",
    "target",       "build",       ".build",      "Pods",
};

fn isPruned(name: []const u8) bool {
    for (pruned) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

const buffer_len = 64 * 1024;

pub fn scan(b: *index.Builder, root: []const u8, opts: Options) !void {
    try b.setRoot(root);
    const fd = try sys.openRoot(root);
    defer sys.close(fd);
    // One buffer serves every level: each directory is drained into the
    // builder before any child is opened.
    const buf = try b.gpa.alignedAlloc(u8, .@"8", buffer_len);
    defer b.gpa.free(buf);
    try walk(b, fd, index.no_parent, 0, buf, opts);
}

fn walk(
    b: *index.Builder,
    fd: posix.fd_t,
    parent: u32,
    depth: u16,
    buf: []align(8) u8,
    opts: Options,
) !void {
    const first = b.count();
    try listing.drain(b, fd, parent, buf, opts);
    const last = b.count();
    if (depth + 1 >= opts.max_depth) return;

    var id = first;
    while (id < last) : (id += 1) {
        if (!b.isDir(id)) continue;
        // `openat` copies the name before it returns, so the slice into the
        // builder's buffer may move during the recursive call that follows.
        const child = sys.openat(fd, b.name(id), .dir) catch continue;
        defer sys.close(child);
        try walk(b, child, id, depth + 1, buf, opts);
    }
}

fn keep(name: []const u8, is_dir: bool, opts: Options) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (opts.skip_hidden and name[0] == '.') return false;
    if (is_dir and isPruned(name)) return false;
    return true;
}

const listing = switch (builtin.os.tag) {
    .linux => Linux,
    .macos => Darwin,
    else => @compileError("floodlight-core scans macOS and Linux only"),
};

const Linux = struct {
    const linux = std.os.linux;
    const DT_UNKNOWN = 0;
    const DT_DIR = 4;

    fn drain(b: *index.Builder, fd: posix.fd_t, parent: u32, buf: []align(8) u8, opts: Options) !void {
        while (true) {
            const rc = linux.getdents64(fd, buf.ptr, @intCast(buf.len));
            // An unreadable directory (permissions, raced away) is skipped,
            // not fatal: a home folder always has a few.
            if (posix.errno(rc) != .SUCCESS) return;
            if (rc == 0) return;
            var off: usize = 0;
            while (off < rc) {
                const rec = buf[off..];
                const reclen = std.mem.readInt(u16, rec[16..18], .little);
                const dtype = rec[18];
                const name = std.mem.sliceTo(rec[19..reclen], 0);
                off += reclen;

                var flags: index.Flags = .{ .dir = dtype == DT_DIR };
                if (dtype == DT_UNKNOWN) flags = statFlags(fd, name);
                if (!keep(name, flags.dir, opts)) continue;
                _ = try b.add(parent, name, flags);
            }
        }
    }

    /// For filesystems that leave `d_type` blank. Opening as a directory
    /// with NOFOLLOW answers "is this a real directory" in one syscall; a
    /// symlink to a directory fails it, which is the answer the walk wants.
    fn statFlags(fd: posix.fd_t, name: []const u8) index.Flags {
        const probe = sys.openat(fd, name, .dir) catch return .{};
        sys.close(probe);
        return .{ .dir = true };
    }
};

const Darwin = struct {
    const attrlist = extern struct {
        bitmapcount: u16,
        reserved: u16,
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    };
    const attribute_set = extern struct {
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    };
    const attrreference = extern struct {
        dataoffset: i32,
        length: u32,
    };

    // <sys/attr.h>
    const ATTR_BIT_MAP_COUNT = 5;
    const ATTR_CMN_NAME: u32 = 0x00000001;
    const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
    const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
    const FSOPT_PACK_INVAL_ATTRS: u64 = 0x00000008;
    // <sys/vnode.h> enum vtype
    const VDIR = 2;

    extern "c" fn getattrlistbulk(
        dirfd: c_int,
        alist: *const attrlist,
        buf: *anyopaque,
        size: usize,
        options: u64,
    ) c_int;

    const request = attrlist{
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = 0,
        .forkattr = 0,
    };

    fn drain(b: *index.Builder, fd: posix.fd_t, parent: u32, buf: []align(8) u8, opts: Options) !void {
        while (true) {
            const n = getattrlistbulk(fd, &request, buf.ptr, buf.len, FSOPT_PACK_INVAL_ATTRS);
            if (n <= 0) return;
            var off: usize = 0;
            var left: c_int = n;
            while (left > 0) : (left -= 1) {
                const rec = buf[off..];
                const len = std.mem.readInt(u32, rec[0..4], .little);
                off += len;

                // Layout in bit order after the length: the returned set,
                // then the name reference, then the object type.
                var at: usize = 4;
                const returned = std.mem.bytesToValue(attribute_set, rec[at..][0..@sizeOf(attribute_set)]);
                at += @sizeOf(attribute_set);
                if (returned.commonattr & ATTR_CMN_NAME == 0) continue;
                const ref = std.mem.bytesToValue(attrreference, rec[at..][0..@sizeOf(attrreference)]);
                const name_at: usize = @intCast(@as(i64, @intCast(at)) + ref.dataoffset);
                at += @sizeOf(attrreference);
                const raw = rec[name_at..][0..ref.length];
                const name = std.mem.sliceTo(raw, 0);

                var objtype: u32 = 0;
                if (returned.commonattr & ATTR_CMN_OBJTYPE != 0) {
                    objtype = std.mem.readInt(u32, rec[at..][0..4], .little);
                }
                const flags: index.Flags = .{ .dir = objtype == VDIR };
                if (!keep(name, flags.dir, opts)) continue;
                _ = try b.add(parent, name, flags);
            }
        }
    }
};

const t = std.testing;

test "walks, prunes, and skips hidden" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "docs/tax");
    try tmp.dir.createDirPath(t.io, "node_modules/left-pad");
    try tmp.dir.createDirPath(t.io, ".git/objects");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "docs/tax/2025.pdf", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "docs/.secret", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "readme.md", .data = "" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];

    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    try scan(&b, root, .{});

    var found = std.StringHashMap(void).init(t.allocator);
    defer {
        var it = found.keyIterator();
        while (it.next()) |k| t.allocator.free(k.*);
        found.deinit();
    }
    var buf: [512]u8 = undefined;
    var id: u32 = 0;
    while (id < b.count()) : (id += 1) {
        const p = b.view().relativePath(id, &buf).?;
        try found.put(try t.allocator.dupe(u8, p), {});
    }
    try t.expect(found.contains("docs/tax/2025.pdf"));
    try t.expect(found.contains("readme.md"));
    try t.expect(found.contains("docs/tax"));
    try t.expect(!found.contains("docs/.secret"));
    try t.expect(!found.contains("node_modules"));
    try t.expect(!found.contains(".git"));
    try t.expectEqual(@as(u32, 4), b.count());
}
