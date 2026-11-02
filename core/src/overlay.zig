//! Entries that appeared on disk after the mapped index was written.
//!
//! A small heap table, append-only between compactions so an id handed out
//! by a search keeps naming the same entry until the next swap. Removal only
//! sets a bit. The slot count is fixed when it is created, so a burst of
//! events can never grow it past the bound compaction is sized for.
//!
//! Not synchronised: `live.zig` holds its lock around every call.

const std = @import("std");
const index = @import("index.zig");
const mask = @import("mask.zig");
const search = @import("search.zig");

/// Overlay ids sit above every mapped id, so one `u32` names either kind and
/// a hit never needs a tag beside it.
pub const id_base: u32 = 1 << 31;

pub const Overlay = struct {
    gpa: std.mem.Allocator,
    cap: u32,
    bytes: std.ArrayList(u8) = .empty,
    path_off: std.ArrayList(u32) = .empty,
    path_len: std.ArrayList(u16) = .empty,
    name_len: std.ArrayList(u16) = .empty,
    name_mask: std.ArrayList(u32) = .empty,
    path_mask: std.ArrayList(u32) = .empty,
    depth: std.ArrayList(u8) = .empty,
    flags: std.ArrayList(index.Flags) = .empty,
    dead: std.ArrayList(bool) = .empty,

    pub fn init(gpa: std.mem.Allocator, cap: u32) !Overlay {
        var o: Overlay = .{ .gpa = gpa, .cap = cap };
        errdefer o.deinit();
        try o.path_off.ensureTotalCapacityPrecise(gpa, cap);
        try o.path_len.ensureTotalCapacityPrecise(gpa, cap);
        try o.name_len.ensureTotalCapacityPrecise(gpa, cap);
        try o.name_mask.ensureTotalCapacityPrecise(gpa, cap);
        try o.path_mask.ensureTotalCapacityPrecise(gpa, cap);
        try o.depth.ensureTotalCapacityPrecise(gpa, cap);
        try o.flags.ensureTotalCapacityPrecise(gpa, cap);
        try o.dead.ensureTotalCapacityPrecise(gpa, cap);
        return o;
    }

    pub fn deinit(o: *Overlay) void {
        o.bytes.deinit(o.gpa);
        o.path_off.deinit(o.gpa);
        o.path_len.deinit(o.gpa);
        o.name_len.deinit(o.gpa);
        o.name_mask.deinit(o.gpa);
        o.path_mask.deinit(o.gpa);
        o.depth.deinit(o.gpa);
        o.flags.deinit(o.gpa);
        o.dead.deinit(o.gpa);
    }

    /// Slots used, removed ones included: the number compaction is bounded by.
    pub fn len(o: *const Overlay) u32 {
        return @intCast(o.path_off.items.len);
    }

    pub fn path(o: *const Overlay, slot: u32) []const u8 {
        return o.bytes.items[o.path_off.items[slot]..][0..o.path_len.items[slot]];
    }

    pub fn name(o: *const Overlay, slot: u32) []const u8 {
        const p = o.path(slot);
        return p[p.len - o.name_len.items[slot] ..];
    }

    pub fn isLive(o: *const Overlay, slot: u32) bool {
        return slot < o.len() and !o.dead.items[slot];
    }

    pub fn find(o: *const Overlay, rel: []const u8) ?u32 {
        for (0..o.len()) |i| {
            const slot: u32 = @intCast(i);
            if (!o.dead.items[slot] and std.mem.eql(u8, o.path(slot), rel)) return slot;
        }
        return null;
    }

    /// Appends `rel`. Returns null when the overlay is full; the caller has
    /// already queued the folder for compaction, which will pick it up.
    pub fn add(o: *Overlay, rel: []const u8, flags: index.Flags) !?u32 {
        if (o.len() == o.cap) return null;
        if (rel.len > std.math.maxInt(u16)) return error.NameTooLong;
        const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
        const entry_name = if (slash) |s| rel[s + 1 ..] else rel;
        const off: u32 = @intCast(o.bytes.items.len);
        try o.bytes.appendSlice(o.gpa, rel);
        o.path_off.appendAssumeCapacity(off);
        o.path_len.appendAssumeCapacity(@intCast(rel.len));
        o.name_len.appendAssumeCapacity(@intCast(entry_name.len));
        o.name_mask.appendAssumeCapacity(mask.of(entry_name));
        o.path_mask.appendAssumeCapacity(mask.of(rel));
        o.depth.appendAssumeCapacity(@intCast(@min(255, std.mem.count(u8, rel, "/") + 1)));
        o.flags.appendAssumeCapacity(flags);
        o.dead.appendAssumeCapacity(false);
        return o.len() - 1;
    }

    /// Removes `rel` and everything under it. Returns whether anything was
    /// live.
    pub fn removeTree(o: *Overlay, rel: []const u8) bool {
        var any = false;
        for (0..o.len()) |i| {
            if (o.dead.items[i]) continue;
            const p = o.path(@intCast(i));
            const under = p.len > rel.len and p[rel.len] == '/' and std.mem.startsWith(u8, p, rel);
            if (under or std.mem.eql(u8, p, rel)) {
                o.dead.items[i] = true;
                any = true;
            }
        }
        return any;
    }

    pub fn searchInto(o: *const Overlay, q: *const search.Query, heap: *search.TopK) void {
        for (0..o.len()) |i| {
            const slot: u32 = @intCast(i);
            if (o.dead.items[slot] or o.path_mask.items[slot] & q.path_mask != q.path_mask) continue;
            const stored: struct {
                p: []const u8,
                pub fn path(s: @This()) ?[]const u8 {
                    return s.p;
                }
            } = .{ .p = o.path(slot) };
            search.scoreEntry(q, .{
                .id = id_base | slot,
                .name = o.name(slot),
                .name_mask = o.name_mask.items[slot],
                .depth = o.depth.items[slot],
            }, heap, stored);
        }
    }
};

const t = std.testing;

test "add, find, remove a tree, and search" {
    var o = try Overlay.init(t.allocator, 4);
    defer o.deinit();
    _ = (try o.add("inbox", .{ .dir = true })).?;
    const f = (try o.add("inbox/receipt.pdf", .{})).?;
    _ = (try o.add("inboxed.txt", .{})).?;
    try t.expectEqualStrings("receipt.pdf", o.name(f));
    try t.expectEqual(f, o.find("inbox/receipt.pdf").?);

    var heap = search.TopK.init(4);
    const q = search.Query.parse("receipt");
    o.searchInto(&q, &heap);
    try t.expectEqual(@as(usize, 1), heap.len);
    try t.expectEqual(id_base | f, heap.items[0].id);

    try t.expect(o.removeTree("inbox"));
    try t.expect(o.find("inbox/receipt.pdf") == null);
    try t.expect(o.find("inboxed.txt") != null);
    _ = (try o.add("a", .{})).?;
    try t.expect(try o.add("b", .{}) == null);
}
