//! A filtered, selectable list of rows: the search panel's results and the
//! clipboard board's history. The caller fetches rows; the list owns the
//! memory behind them, the filter, the selection, and when to ask again.
const std = @import("std");

/// `Filter` must have an `.all` value and `includes(Filter, Item) bool`.
/// `keyOf` names an item across fetches; it must not point into the rows,
/// since a new fetch frees them.
pub fn List(comptime Item: type, comptime Filter: type, comptime Key: type, comptime keyOf: fn (Item) Key) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        rows: []const Item = &.{},
        visible: []Item = &.{},
        filter: Filter = .all,
        selected: usize = 0,
        /// The selection moved or the rows changed: scroll it into view.
        reveal: bool = false,
        /// The rows' source changed under an unchanged query.
        stale: bool = false,
        /// The last fetch failed: no rows, whatever the query matches.
        failed: bool = false,
        /// The query `rows` answers, kept outside the arena.
        query: std.ArrayList(u8) = .empty,
        /// The selection to find again after a stale refresh.
        kept: ?Key = null,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(l: *Self) void {
            l.query.deinit(l.arena.child_allocator);
            l.arena.deinit();
        }

        /// Forgets the rows, the query, the filter, and the memory behind them.
        pub fn reset(l: *Self) void {
            l.rows = &.{};
            l.visible = &.{};
            l.query.clearRetainingCapacity();
            l.filter = .all;
            l.selected = 0;
            l.reveal = false;
            l.stale = false;
            l.failed = false;
            l.kept = null;
            _ = l.arena.reset(.free_all);
        }

        pub fn needsQuery(l: *const Self, query: []const u8) bool {
            return l.stale or !std.mem.eql(u8, query, l.query.items);
        }

        pub fn markStale(l: *Self) void {
            l.stale = true;
        }

        pub fn answered(l: *const Self) []const u8 {
            return l.query.items;
        }

        /// Frees the previous rows; fetch the new ones with the allocator
        /// returned, then hand them to `setRows`, or call `fail`.
        pub fn beginQuery(l: *Self, query: []const u8) std.mem.Allocator {
            const same = l.stale and std.mem.eql(u8, query, l.query.items);
            l.kept = if (same) if (l.selection()) |x| keyOf(x) else null else null;
            _ = l.arena.reset(.retain_capacity);
            l.rows = &.{};
            l.visible = &.{};
            return l.arena.allocator();
        }

        /// On error nothing is answered: the next refresh asks again.
        pub fn setRows(l: *Self, query: []const u8, rows: []const Item) !void {
            if (!std.mem.eql(u8, query, l.query.items)) {
                try l.query.ensureTotalCapacity(l.arena.child_allocator, query.len);
                l.query.clearRetainingCapacity();
                l.query.appendSliceAssumeCapacity(query);
            }
            l.rows = rows;
            l.stale = false;
            l.failed = false;
            l.applyFilter();
            const key = l.kept orelse return;
            l.kept = null;
            for (l.visible, 0..) |x, i| if (std.meta.eql(keyOf(x), key)) {
                l.selected = i;
                return;
            };
        }

        /// Rows for the query already answered, allocated from `allocator()`:
        /// more arrived late. The selection keeps its row, or its place when
        /// that row is gone.
        pub fn replaceRows(l: *Self, rows: []const Item) void {
            const at = l.selected;
            const key: ?Key = if (at < l.visible.len) keyOf(l.visible[at]) else null;
            const reveal = l.reveal;
            l.rows = rows;
            l.applyFilter();
            if (l.visible.len > 0) l.selected = @min(at, l.visible.len - 1);
            if (key) |k| for (l.visible, 0..) |x, i| if (std.meta.eql(keyOf(x), k)) {
                l.selected = i;
                break;
            };
            l.reveal = reveal;
        }

        /// What the current rows live in, until the next `beginQuery`.
        pub fn allocator(l: *Self) std.mem.Allocator {
            return l.arena.allocator();
        }

        /// After a failed fetch: no rows, and the next refresh asks again.
        pub fn fail(l: *Self) void {
            l.rows = &.{};
            l.visible = &.{};
            l.selected = 0;
            l.kept = null;
            l.failed = true;
        }

        pub fn count(l: *const Self, f: Filter) usize {
            var n: usize = 0;
            for (l.rows) |x| n += @intFromBool(f.includes(x));
            return n;
        }

        pub fn selectFilter(l: *Self, f: Filter) void {
            l.filter = f;
            l.applyFilter();
        }

        fn applyFilter(l: *Self) void {
            const out = l.arena.allocator().alloc(Item, l.rows.len) catch return;
            var n: usize = 0;
            for (l.rows) |x| if (l.filter.includes(x)) {
                out[n] = x;
                n += 1;
            };
            l.visible = out[0..n];
            l.selected = 0;
            l.reveal = true;
        }

        pub fn move(l: *Self, down: bool) void {
            if (l.visible.len == 0) return;
            l.selected = if (down) @min(l.selected + 1, l.visible.len - 1) else l.selected -| 1;
            l.reveal = true;
        }

        pub fn selection(l: *const Self) ?Item {
            return if (l.selected < l.visible.len) l.visible[l.selected] else null;
        }

        /// Selects row `at`, or the last row when fewer remain.
        pub fn clampSelection(l: *Self, at: usize) void {
            if (l.visible.len > 0) l.selected = @min(at, l.visible.len - 1);
            l.reveal = true;
        }

        /// The scroll offset that brings the selection into a view `view_h`
        /// tall scrolled to `now`, once per reveal; null when it already shows.
        pub fn takeScroll(l: *Self, now: f32, view_h: f32, row_h: f32) ?f32 {
            if (!l.reveal) return null;
            l.reveal = false;
            const top = @as(f32, @floatFromInt(l.selected)) * row_h;
            if (top < now) return top;
            if (top + row_h > now + view_h) return top + row_h - view_h;
            return null;
        }
    };
}

pub const RowRange = struct { first: usize, end: usize };

/// The rows a view `view_h` tall scrolled to `offset` shows, with `margin`
/// rows either side so an overscroll never reveals a gap.
pub fn rowsInView(offset: f32, len: usize, row_h: f32, view_h: f32, margin: usize) RowRange {
    const top_row: usize = @intFromFloat(@max(0, @floor(offset / row_h)));
    const in_view: usize = @intFromFloat(@ceil(view_h / row_h));
    return .{ .first = @min(len, top_row -| margin), .end = @min(len, top_row + in_view + margin) };
}
