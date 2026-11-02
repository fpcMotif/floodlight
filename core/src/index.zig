//! The file index: a flat, struct-of-arrays table of names with parent links,
//! written once and memory-mapped read-only.
//!
//! Storing each name once with a parent id, rather than each full path,
//! keeps a million-entry home folder near 37 MB instead of 90. Mapping the
//! file read-only means those pages are clean: macOS can drop them under
//! pressure and fault them back from disk, so the index never counts as
//! dirty memory the way a heap-built table does.

const std = @import("std");
const sys = @import("sys.zig");
const mask = @import("mask.zig");

pub const no_parent: u32 = std.math.maxInt(u32);

pub const Flags = packed struct(u8) {
    dir: bool = false,
    symlink: bool = false,
    _pad: u6 = 0,
};

const magic = "FLIX".*;
const version: u32 = 2;
/// Sixteen so every section starts on a vector-load boundary.
const section_align = 16;

const Header = extern struct {
    magic: [4]u8,
    version: u32,
    count: u32,
    root_len: u32,
    names_len: u64,
    off_path_mask: u64,
    off_name_mask: u64,
    off_parent: u64,
    off_name_off: u64,
    off_name_len: u64,
    off_flags: u64,
    off_depth: u64,
    off_names: u64,
    off_root: u64,
    total: u64,
};

/// Read-only access to an index, whether it lives in a mapping or in a
/// builder's buffers. Search code only ever sees this.
pub const View = struct {
    path_mask: []const u32,
    name_mask: []const u32,
    parent: []const u32,
    name_off: []const u32,
    name_len: []const u16,
    flags: []const Flags,
    /// Path components above the entry, saturating at 255. Stored so ranking
    /// never walks a parent chain per candidate.
    depth: []const u8,
    names: []const u8,
    root: []const u8,

    pub fn count(v: View) u32 {
        return @intCast(v.parent.len);
    }

    pub fn name(v: View, id: u32) []const u8 {
        const off = v.name_off[id];
        return v.names[off..][0..v.name_len[id]];
    }

    /// Writes the root-relative path into the tail of `buf` and returns it.
    /// Built back to front so it needs no second pass and no allocation.
    pub fn relativePath(v: View, id: u32, buf: []u8) ?[]const u8 {
        var end = buf.len;
        var cur = id;
        var first = true;
        while (cur != no_parent) {
            const n = v.name(cur);
            const need = n.len + @intFromBool(!first);
            if (need > end) return null;
            if (!first) {
                end -= 1;
                buf[end] = '/';
            }
            end -= n.len;
            @memcpy(buf[end..][0..n.len], n);
            first = false;
            cur = v.parent[cur];
        }
        return buf[end..];
    }
};

pub const Builder = struct {
    gpa: std.mem.Allocator,
    path_mask: std.ArrayList(u32) = .empty,
    name_mask: std.ArrayList(u32) = .empty,
    parent: std.ArrayList(u32) = .empty,
    name_off: std.ArrayList(u32) = .empty,
    name_len: std.ArrayList(u16) = .empty,
    flags: std.ArrayList(Flags) = .empty,
    depth: std.ArrayList(u8) = .empty,
    names: std.ArrayList(u8) = .empty,
    root: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.path_mask.deinit(b.gpa);
        b.name_mask.deinit(b.gpa);
        b.parent.deinit(b.gpa);
        b.name_off.deinit(b.gpa);
        b.name_len.deinit(b.gpa);
        b.flags.deinit(b.gpa);
        b.depth.deinit(b.gpa);
        b.names.deinit(b.gpa);
        b.root.deinit(b.gpa);
    }

    pub fn setRoot(b: *Builder, root: []const u8) !void {
        b.root.clearRetainingCapacity();
        try b.root.appendSlice(b.gpa, root);
    }

    pub fn count(b: *const Builder) u32 {
        return @intCast(b.parent.items.len);
    }

    pub fn add(b: *Builder, parent: u32, entry_name: []const u8, flags: Flags) !u32 {
        if (entry_name.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (b.names.items.len + entry_name.len > std.math.maxInt(u32)) return error.IndexTooLarge;
        const id = b.count();
        if (id == no_parent) return error.IndexTooLarge;
        const nm = mask.of(entry_name);
        const inherited = if (parent == no_parent) 0 else b.path_mask.items[parent];
        try b.path_mask.append(b.gpa, nm | inherited);
        try b.name_mask.append(b.gpa, nm);
        try b.parent.append(b.gpa, parent);
        try b.name_off.append(b.gpa, @intCast(b.names.items.len));
        try b.name_len.append(b.gpa, @intCast(entry_name.len));
        try b.flags.append(b.gpa, flags);
        const up: u8 = if (parent == no_parent) 0 else b.depth.items[parent];
        try b.depth.append(b.gpa, up +| 1);
        try b.names.appendSlice(b.gpa, entry_name);
        return id;
    }

    pub fn isDir(b: *const Builder, id: u32) bool {
        return b.flags.items[id].dir;
    }

    pub fn name(b: *const Builder, id: u32) []const u8 {
        return b.view().name(id);
    }

    pub fn view(b: *const Builder) View {
        return .{
            .path_mask = b.path_mask.items,
            .name_mask = b.name_mask.items,
            .parent = b.parent.items,
            .name_off = b.name_off.items,
            .name_len = b.name_len.items,
            .flags = b.flags.items,
            .depth = b.depth.items,
            .names = b.names.items,
            .root = b.root.items,
        };
    }

    /// Writes to `path` through a temporary sibling and a rename, so a reader
    /// mapping the old index never sees a half-written one.
    pub fn writeFile(b: *const Builder, dir: sys.fd_t, path: []const u8) !void {
        var tmp_buf: [std.posix.PATH_MAX]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        const fd = try sys.openat(dir, tmp, .create);
        errdefer sys.unlinkat(dir, tmp);
        {
            defer sys.close(fd);
            try b.writeTo(fd);
        }
        try sys.renameat(dir, tmp, path);
    }

    /// Sizes the file first, then writes each section at its offset. The
    /// alignment padding between sections is never written: `ftruncate`
    /// already reads back as zeros there.
    fn writeTo(b: *const Builder, fd: sys.fd_t) !void {
        const n: u64 = b.count();
        var off: u64 = std.mem.alignForward(u64, @sizeOf(Header), section_align);
        var h: Header = undefined;
        h.magic = magic;
        h.version = version;
        h.count = @intCast(n);
        h.root_len = @intCast(b.root.items.len);
        h.names_len = b.names.items.len;
        h.off_path_mask = take(&off, n * 4);
        h.off_name_mask = take(&off, n * 4);
        h.off_parent = take(&off, n * 4);
        h.off_name_off = take(&off, n * 4);
        h.off_name_len = take(&off, n * 2);
        h.off_flags = take(&off, n);
        h.off_depth = take(&off, n);
        h.off_names = take(&off, b.names.items.len);
        h.off_root = take(&off, b.root.items.len);
        h.total = off;

        try sys.ftruncate(fd, h.total);
        try sys.pwriteAll(fd, std.mem.asBytes(&h), 0);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.path_mask.items), h.off_path_mask);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.name_mask.items), h.off_name_mask);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.parent.items), h.off_parent);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.name_off.items), h.off_name_off);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.name_len.items), h.off_name_len);
        try sys.pwriteAll(fd, std.mem.sliceAsBytes(b.flags.items), h.off_flags);
        try sys.pwriteAll(fd, b.depth.items, h.off_depth);
        try sys.pwriteAll(fd, b.names.items, h.off_names);
        try sys.pwriteAll(fd, b.root.items, h.off_root);
    }
};

fn take(off: *u64, len: u64) u64 {
    const at = off.*;
    off.* = std.mem.alignForward(u64, at + len, section_align);
    return at;
}

/// An index file mapped read-only. Opening costs one `mmap`; nothing is read
/// until a search touches it.
pub const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    view: View,

    pub fn open(dir: sys.fd_t, path: []const u8) !Mapped {
        const fd = try sys.openat(dir, path, .read);
        defer sys.close(fd);
        const len = try sys.size(fd);
        if (len < @sizeOf(Header)) return error.CorruptIndex;
        const bytes = try sys.mmapRead(fd, @intCast(len));
        errdefer sys.munmap(bytes);
        return .{ .bytes = bytes, .view = try parse(bytes) };
    }

    pub fn close(m: *Mapped) void {
        sys.munmap(m.bytes);
        m.* = undefined;
    }
};

fn parse(bytes: []align(std.heap.page_size_min) const u8) !View {
    const h: *const Header = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &h.magic, &magic) or h.version != version) return error.CorruptIndex;
    if (h.total > bytes.len) return error.CorruptIndex;
    const n: usize = h.count;
    return .{
        .path_mask = try section(u32, bytes, h.off_path_mask, n),
        .name_mask = try section(u32, bytes, h.off_name_mask, n),
        .parent = try section(u32, bytes, h.off_parent, n),
        .name_off = try section(u32, bytes, h.off_name_off, n),
        .name_len = try section(u16, bytes, h.off_name_len, n),
        .flags = try section(Flags, bytes, h.off_flags, n),
        .depth = try section(u8, bytes, h.off_depth, n),
        .names = try section(u8, bytes, h.off_names, h.names_len),
        .root = try section(u8, bytes, h.off_root, h.root_len),
    };
}

fn section(comptime T: type, bytes: []const u8, off: u64, n: u64) ![]const T {
    const len = n * @sizeOf(T);
    if (off % section_align != 0 or off + len > bytes.len) return error.CorruptIndex;
    const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr + off));
    return ptr[0..n];
}

const t = std.testing;

test "relative path walks parents" {
    var b = Builder.init(t.allocator);
    defer b.deinit();
    const docs = try b.add(no_parent, "Documents", .{ .dir = true });
    const tax = try b.add(docs, "tax", .{ .dir = true });
    const f = try b.add(tax, "2025.pdf", .{});
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("Documents/tax/2025.pdf", b.view().relativePath(f, &buf).?);
    try t.expect(b.view().path_mask[f] & mask.of("doc") == mask.of("doc"));
    try t.expect(b.view().name_mask[f] & mask.of("doc") != mask.of("doc"));
}

test "round trip through a mapped file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b = Builder.init(t.allocator);
    defer b.deinit();
    try b.setRoot("/Users/me");
    const a = try b.add(no_parent, "a", .{ .dir = true });
    _ = try b.add(a, "hello.txt", .{});
    try b.writeFile(tmp.dir.handle, "idx");

    var m = try Mapped.open(tmp.dir.handle, "idx");
    defer m.close();
    try t.expectEqual(@as(u32, 2), m.view.count());
    try t.expectEqualStrings("/Users/me", m.view.root);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a/hello.txt", m.view.relativePath(1, &buf).?);
    try t.expect(m.view.flags[0].dir);
}

test "rejects a truncated file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bad", .data = "FLIX" ++ @as([200]u8, @splat(0)) });
    try t.expectError(error.CorruptIndex, Mapped.open(tmp.dir.handle, "bad"));
}
