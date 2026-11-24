//! Generic list filtering, selection, scroll-into-view, and viewport tests.
const std = @import("std");
const list_mod = @import("../list.zig");
const t = std.testing;

// The list behind the panel's rows and the board's history, with toy rows.
const Toy = struct { id: i64, odd: bool };

const ToyFilter = enum {
    all,
    odd,

    pub fn includes(f: ToyFilter, x: Toy) bool {
        return f == .all or x.odd;
    }
};

fn toyKey(x: Toy) i64 {
    return x.id;
}

const ToyList = list_mod.List(Toy, ToyFilter, i64, toyKey);

/// Answers `query` with rows numbered `first` up, `n` of them.
fn answer(l: *ToyList, query: []const u8, first: i64, n: usize) !void {
    const a = l.beginQuery(query);
    const rows = try a.alloc(Toy, n);
    for (rows, 0..) |*r, i| {
        const id = first + @as(i64, @intCast(i));
        r.* = .{ .id = id, .odd = @mod(id, 2) == 1 };
    }
    try l.setRows(query, rows);
}

test "a list narrows to its filter, selecting its first row and asking to show it" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try answer(&l, "q", 0, 6);
    try t.expectEqual(@as(usize, 6), l.visible.len);
    try t.expectEqual(@as(usize, 3), l.count(.odd));
    l.move(true);
    l.move(true);
    _ = l.takeScroll(0, 1000, 10);
    l.selectFilter(.odd);
    try t.expectEqual(@as(usize, 3), l.visible.len);
    for (l.visible) |x| try t.expect(x.odd);
    try t.expectEqual(@as(i64, 1), l.selection().?.id);
    try t.expectEqual(@as(?f32, 0), l.takeScroll(50, 1000, 10));
    l.reset();
    try t.expectEqual(ToyFilter.all, l.filter);
    try t.expectEqual(@as(?Toy, null), l.selection());
}

test "arrows stop at a list's ends, and an empty list has no selection" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try t.expectEqual(@as(?Toy, null), l.selection());
    l.move(true);
    try t.expectEqual(@as(?Toy, null), l.selection());
    try answer(&l, "q", 10, 3);
    l.move(false);
    try t.expectEqual(@as(i64, 10), l.selection().?.id);
    for (0..5) |_| l.move(true);
    try t.expectEqual(@as(i64, 12), l.selection().?.id);
}

test "a list asks for rows again only when the query changes or history did" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try t.expect(!l.needsQuery(""));
    try t.expect(l.needsQuery("a"));
    try answer(&l, "a", 0, 2);
    try t.expect(!l.needsQuery("a"));
    try t.expect(l.needsQuery("ab"));
    l.markStale();
    try t.expect(l.needsQuery("a"));
    try answer(&l, l.answered(), 0, 2);
    try t.expectEqualStrings("a", l.answered());
    try t.expect(!l.needsQuery("a"));
}

test "history changing under the same query keeps the selected entry; a new query starts at the top" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try answer(&l, "", 0, 5);
    l.move(true);
    l.move(true);
    try t.expectEqual(@as(i64, 2), l.selection().?.id);

    // A copy lands on top: every entry moves down one place.
    l.markStale();
    try answer(&l, "", -1, 6);
    try t.expectEqual(@as(i64, 2), l.selection().?.id);
    try t.expectEqual(@as(usize, 3), l.selected);

    l.markStale();
    try answer(&l, "x", -1, 6);
    try t.expectEqual(@as(usize, 0), l.selected);
}

test "after a removal the selection keeps its place, or the new last row" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try answer(&l, "", 0, 4);
    l.markStale();
    try answer(&l, "", 0, 3);
    l.clampSelection(1);
    try t.expectEqual(@as(usize, 1), l.selected);
    l.clampSelection(7);
    try t.expectEqual(@as(usize, 2), l.selected);
    l.markStale();
    try answer(&l, "", 0, 0);
    l.clampSelection(2);
    try t.expectEqual(@as(?Toy, null), l.selection());
}

test "the selection scrolls into view once, up or down, and not when already shown" {
    var l: ToyList = .init(t.allocator);
    defer l.deinit();
    try answer(&l, "", 0, 20);
    // Rows 10 high, 30 in view: row 0 is shown at the top.
    try t.expectEqual(@as(?f32, null), l.takeScroll(0, 30, 10));
    for (0..5) |_| l.move(true);
    try t.expectEqual(@as(?f32, 30), l.takeScroll(0, 30, 10));
    try t.expectEqual(@as(?f32, null), l.takeScroll(0, 30, 10));
    l.move(false);
    try t.expectEqual(@as(?f32, null), l.takeScroll(30, 30, 10));
    l.clampSelection(1);
    try t.expectEqual(@as(?f32, 10), l.takeScroll(30, 30, 10));
}

test "only the rows in view and a margin are built, within the list" {
    const r0 = list_mod.rowsInView(0, 100, 10, 30, 2);
    try t.expectEqual(@as(usize, 0), r0.first);
    try t.expectEqual(@as(usize, 5), r0.end);
    const mid = list_mod.rowsInView(255, 100, 10, 30, 2);
    try t.expectEqual(@as(usize, 23), mid.first);
    try t.expectEqual(@as(usize, 30), mid.end);
    const bottom = list_mod.rowsInView(990, 100, 10, 30, 2);
    try t.expectEqual(@as(usize, 100), bottom.end);
    const above = list_mod.rowsInView(-15, 100, 10, 30, 2);
    try t.expectEqual(@as(usize, 0), above.first);
    const short = list_mod.rowsInView(0, 2, 10, 30, 2);
    try t.expectEqual(@as(usize, 2), short.end);
}
