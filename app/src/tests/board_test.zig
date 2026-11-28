//! Clipboard board UI, inspector, backspace/IME, scrolling, thumbnails, and query narrowing tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const panel_mod = @import("../panel.zig");
const mac = @import("../mac.zig");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const chrome = @import("../chrome.zig");
const h = @import("helpers.zig");
const t = std.testing;

const picture = h.picture;
const BoardFixture = h.BoardFixture;

/// The text drawn right of `label` on its line: an inspector row's value.
fn besideText(tester: *ui.Tester, label: []const u8) ?[]const u8 {
    const at = tester.findText(label) orelse return null;
    for (tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (n.rect.x > at.x + at.w and @abs(n.rect.y - at.y) < 0.5) return tx.str,
        else => {},
    };
    return null;
}

fn holdPastEnd(tester: *ui.Tester, x: f32, y: f32, dy: f32, events: usize) void {
    tester.moveTo(x, y);
    const c = &tester.ctx;
    c.input.precise = true;
    for (0..events) |i| {
        c.scroll_holding = true;
        c.input.scroll_phase = if (i == 0) .began else .changed;
        _ = c.applyScroll(0);
        _ = c.applyScroll(dy);
        tester.frame();
    }
}

fn release(tester: *ui.Tester) void {
    tester.ctx.scroll_holding = false;
    tester.ctx.input.scroll_phase = .ended;
    tester.settle(2);
}

fn addPicture(store: *clipboard.Store, png: []const u8, at: f64) !void {
    _ = try store.add(.{ .image = .{ .name = "", .png = png, .thumbnail = "", .width = 3840, .height = 2160 } }, "com.apple.Preview", "Preview", at);
}

const fillAlphaBehind = h.fillAlphaBehind;
const pointAt = h.pointAt;

test "the board lists history, inspects the selection, and filters" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .file = "/tmp/nanospot-test.pdf" }, "com.apple.finder", "Finder", 500);
    _ = try f.store.add(.{ .text = "hello there world" }, "com.apple.Notes", "Notes", 1000);
    _ = try f.store.add(.{ .text = "https://www.example.com/page" }, "com.apple.Safari", "Safari", 2000);
    f.hooks.clock.advance(2060);
    try f.show();
    const p = &f.p;
    const tester = &f.tester;
    try t.expectEqual(board_mod.board_metrics.width, p.panelWidth());
    try t.expectEqual(@as(f32, 560), p.panelHeight());
    try t.expect(tester.hasText("Filter clipboard"));
    try t.expect(tester.hasText("Information"));
    try t.expect(tester.hasText("Link"));
    try t.expect(tester.hasText("example.com"));
    try t.expect(tester.hasText("Safari \u{00B7} 1m"));
    try t.expect(tester.hasText("3 entries"));
    try t.expect(tester.hasText("Copy"));
    try t.expect(tester.hasText("Today at 9:41 AM"));

    p.board.paste_target = "Notes";
    tester.settle(1);
    try t.expect(tester.hasText("Paste to Notes"));

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expectEqualStrings("17", besideText(tester, "Characters").?);
    try t.expectEqualStrings("3", besideText(tester, "Words").?);

    _ = tester.shortcut(.{ .key = '2', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("2 entries"));
    _ = tester.shortcut(.{ .key = '4', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("No images copied yet"));
    _ = tester.shortcut(.{ .key = '1', .cmd = true });
    tester.settle(1);

    tester.key(.enter);
    try t.expect(p.pending != null);
    try t.expectEqualStrings("https://www.example.com/page", p.pending.?.clipboard.paste.text);
    p.pending = null;

    try t.expect(tester.shortcut(.{ .key = 'o', .cmd = true }));
    try t.expectEqualStrings("https://www.example.com/page", p.pending.?.clipboard.open);
    p.pending = null;

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expect(!tester.shortcut(.{ .key = 'o', .cmd = true }) or p.pending == null);
    _ = tester.shortcut(.{ .key = ui.Shortcut.up });
    tester.settle(1);

    _ = tester.shortcut(.{ .key = 'd', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("2 entries"));
    _ = tester.shortcut(.{ .key = 'd', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("1 entry"));

    tester.typeText("zzz");
    tester.settle(1);
    try t.expect(tester.hasText("No entries match \u{201C}zzz\u{201D}"));
}

test "⌫ on an empty board filter switches to search, and with text it edits the filter, never deleting an entry" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(3);
    try f.show();
    const p = &f.p;
    const tester = &f.tester;

    tester.typeText("entry");
    tester.settle(1);
    tester.textOps(&.{.{ .command = .delete_backward }});
    tester.settle(1);
    try t.expectEqualStrings("entr", p.field.text());
    try t.expect(tester.hasText("3 entries"));
    try t.expect(p.pending == null);

    for (0..4) |_| tester.textOps(&.{.{ .command = .delete_backward }});
    tester.settle(1);
    try t.expectEqualStrings("", p.field.text());
    try t.expect(p.pending == null);

    try t.expect(!tester.shortcut(.{ .key = chrome.backspace, .alt = true }));
    tester.textOps(&.{.{ .command = .delete_word_backward }});
    try t.expect(!tester.shortcut(.{ .key = chrome.backspace, .cmd = true }));
    tester.textOps(&.{.{ .command = .delete_to_line_start }});
    try t.expect(p.pending == null);
    // Unfocused, AppKit hands ⌥⌫ and ⌘⌫ over as the bare key, modifiers held.
    tester.setMods(.{ .alt = true });
    tester.key(.backspace);
    tester.setMods(.{ .cmd = true });
    tester.key(.backspace);
    tester.setMods(.{});
    try t.expect(p.pending == null);

    _ = tester.shortcut(.{ .key = '2', .cmd = true });
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    tester.textOps(&.{.{ .command = .delete_backward }});
    try t.expect(p.pending.? == .show_search);
    try t.expect(tester.hasText("3 entries"));

    p.pending = null;
    p.showSearch();
    tester.settle(1);
    try t.expectEqual(panel_mod.Mode.search, p.mode);
    try t.expect(tester.hasText("Nanospot"));
    try t.expect(!tester.hasText("Filter clipboard"));
    try t.expectEqual(board_mod.board_metrics.width, p.panelWidth());

    // The board's session went with it: ⌥⇧C opens a fresh board.
    p.showClipboard();
    tester.settle(1);
    try t.expectEqual(clipboard.Filter.all, p.board.list.filter);
    try t.expectEqual(@as(usize, 0), p.board.list.selected);
}

test "⌫ during IME composition on the board edits the composition and stays on the board" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(1);
    try f.show();
    f.tester.textOps(&.{.{ .set_marked = .{ .text = "z", .sel_start = 1, .sel_len = 0 } }});
    f.tester.key(.backspace);
    try t.expect(f.p.pending == null);
    try t.expectEqual(panel_mod.Mode.clipboard, f.p.mode);
}

test "search → board → ⌫ brings the retained search query back, fully selected" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(1);
    try f.show();
    const p = &f.p;
    p.showSearch();
    f.tester.settle(1);
    f.tester.typeText("zzz");
    f.tester.settle(1);

    p.showClipboard();
    f.tester.settle(1);
    f.tester.key(.backspace);
    try t.expect(p.pending.? == .show_search);
    p.pending = null;
    p.showSearch();
    f.tester.settle(1);
    try t.expectEqualStrings("zzz", p.field.text());
    f.tester.typeText("a");
    try t.expectEqualStrings("a", p.field.text());
}

test "⌫ on an empty search field changes nothing" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show();
    f.p.showSearch();
    f.tester.settle(1);
    f.tester.key(.backspace);
    try t.expect(f.p.pending == null);
    try t.expectEqual(panel_mod.Mode.search, f.p.mode);
}

test "a copied path keeps what the inspector found until the selection moves" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.ts.tmp.dir.writeFile(t.io, .{ .sub_path = "note.txt", .data = "line one\nline two" });
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/note.txt", .{std.fs.path.dirname(f.ts.images).?});
    _ = try f.store.add(.{ .text = "older" }, "", "Notes", 1);
    _ = try f.store.add(.{ .text = path }, "", "Terminal", 2);
    try f.show();
    const p = &f.p;
    const tester = &f.tester;
    try t.expect(tester.hasText("line two"));
    try t.expect(p.board.previewable(p.board.list.selection().?));

    try f.ts.tmp.dir.deleteFile(t.io, "note.txt");
    tester.frame();
    try t.expect(p.board.previewable(p.board.list.selection().?));

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    _ = tester.shortcut(.{ .key = ui.Shortcut.up });
    tester.settle(1);
    try t.expect(!p.board.previewable(p.board.list.selection().?));
}

test "a push past the board's ends stretches half a row at most, then rests" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(30);
    try f.show();
    const tester = &f.tester;
    const bound = chrome.metrics.max_overscroll + 0.5;

    // The list's top: the newest entry may not leave its resting place by more.
    const top_rest = tester.findText("entry number 29").?.y;
    holdPastEnd(tester, 150, 300, 40, 80);
    try t.expect(tester.findText("entry number 29").?.y - top_rest <= bound);
    release(tester);
    try t.expectApproxEqAbs(top_rest, tester.findText("entry number 29").?.y, 0.5);

    // The list's bottom, reached and pushed on.
    holdPastEnd(tester, 150, 300, -40, 40);
    release(tester);
    const bottom_rest = tester.findText("entry number 0").?.y;
    holdPastEnd(tester, 150, 300, -40, 80);
    try t.expect(bottom_rest - tester.findText("entry number 0").?.y <= bound);
    release(tester);
    try t.expectApproxEqAbs(bottom_rest, tester.findText("entry number 0").?.y, 0.5);

    // The inspector, which fits and so has nothing to scroll.
    const info_rest = tester.findText("Information").?.y;
    holdPastEnd(tester, 600, 300, -40, 80);
    try t.expect(info_rest - tester.findText("Information").?.y <= bound);
    release(tester);
    try t.expectApproxEqAbs(info_rest, tester.findText("Information").?.y, 0.5);
}

test "a long history builds the rows in view only, and still reaches its end" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(1000);
    try f.show();
    const tester = &f.tester;
    try t.expect(tester.hasText("entry number 999"));
    try t.expect(!tester.hasText("entry number 900"));
    try t.expect(tester.ctx.nodes.items.len < 400);

    tester.scroll(150, 300, -1e6);
    tester.settle(1);
    try t.expect(tester.hasText("entry number 0"));
    try t.expect(!tester.hasText("entry number 998"));

    tester.typeText("number 77");
    tester.settle(1);
    try t.expect(tester.hasText("entry number 778"));
}

test "a board frame that waits for a later one keeps the display link at the display's pace" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(30);
    try f.show();
    const tester = &f.tester;
    tester.scroll(150, 300, -120);
    tester.frame();
    const one_refresh: f32 = 1.0 / 60.0;
    // The scroll bar's fade wakes the board later: nanoui would slow the link to it.
    try t.expect(tester.ctx.frame_in.? > one_refresh);
    mac.keepLinkAtDisplayRate(&tester.ctx);
    if (tester.ctx.frame_in) |fi| try t.expect(fi <= one_refresh);
}

test "a held arrow passes over full pictures, and the one it rests on is loaded" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    var png: [6][4]u8 = undefined;
    for (&png, 0..) |*b, i| {
        b.* = .{ 'p', 'n', 'g', @intCast(i) };
        try addPicture(&f.store, b, @floatFromInt(100 - i));
    }
    try f.show();
    const p = &f.p;
    const tester = &f.tester;
    try t.expectEqualSlices(u8, &png[0], p.board.payload.picture);

    tester.advance(1);
    for (1..5) |_| {
        _ = tester.shortcut(.{ .key = ui.Shortcut.down });
        tester.advance(0.05);
    }
    try t.expect(p.board.payload == .none);
    tester.advance(0.5);
    try t.expectEqualSlices(u8, &png[4], p.board.payload.picture);

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.frame();
    try t.expectEqualSlices(u8, &png[5], p.board.payload.picture);
}

test "a large picture's memory goes once the inspector moves on" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "after the picture" }, "com.apple.Notes", "Notes", 50);
    const big = try t.allocator.alloc(u8, 4 << 20);
    defer t.allocator.free(big);
    @memset(big, 7);
    try addPicture(&f.store, big, 100);
    try f.show();
    const p = &f.p;
    const tester = &f.tester;
    try t.expectEqual(big.len, p.board.payload.picture.len);

    tester.advance(1);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expect(tester.hasText("after the picture"));
    try t.expect(p.board.detail_arena.queryCapacity() < big.len);
}

test "an empty history says so" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show();
    try t.expect(f.tester.hasText("Nothing copied yet"));
    try t.expect(f.tester.hasText("Text, files and images you copy appear here."));
}

test "⌘. pins the selected entry, and the board shows it pinned at once" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(3);
    try f.show();
    const p = &f.p;
    const tester = &f.tester;
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expect(!tester.hasText("Pinned"));

    try t.expect(tester.shortcut(.{ .key = '.', .cmd = true }));
    tester.settle(1);
    // Pinned entries list first, and the selection follows the entry there.
    try t.expectEqualStrings("entry number 1", p.board.list.visible[0].text);
    try t.expectEqualStrings("entry number 1", p.board.list.selection().?.text);
    try t.expect(tester.hasText("Pinned"));
}

test "the inspector types a file by the extensions the board's tiles use" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Image", clipboard.fileType(a, "/x.bmp", false));
    try t.expectEqualStrings("Video", clipboard.fileType(a, "/x.wmv", false));
    // `.ts` classifies as TypeScript, not a video stream.
    try t.expectEqualStrings("Source Code", clipboard.fileType(a, "/x.ts", false));
    try t.expectEqualStrings("ZZZ", clipboard.fileType(a, "/x.zzz", false));
}

test "a chip's fill deepens under the pointer and again while held, and a disabled chip's stays" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(2);
    try f.show();
    const tester = &f.tester;
    inline for (.{ "Files", "Actions" }) |label| {
        const rest = fillAlphaBehind(tester, label) orelse return error.TextNotDrawn;
        try pointAt(tester, label);
        const hovered = fillAlphaBehind(tester, label).?;
        try t.expect(hovered > rest);
        tester.ctx.pointerDown();
        tester.frame();
        try t.expect(fillAlphaBehind(tester, label).? > hovered);
        tester.moveTo(1, 1);
        tester.ctx.pointerUp();
        tester.frame();
        tester.frame();
        try t.expectEqual(rest, fillAlphaBehind(tester, label).?);
    }
    const disabled = fillAlphaBehind(tester, "Preview") orelse return error.TextNotDrawn;
    try pointAt(tester, "Preview");
    try t.expectEqual(disabled, fillAlphaBehind(tester, "Preview").?);
}

test "a row's title is as wide selected as not, so moving the selection never cuts it anew" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    const long = "a title long enough that the history list has to cut it short";
    _ = try f.store.add(.{ .text = long ++ " one" }, "x", "Notes", 1000);
    _ = try f.store.add(.{ .text = long ++ " two" }, "x", "Notes", 1001);
    try f.show();
    var widths: [2]f32 = undefined;
    var n: usize = 0;
    for (f.tester.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (n < widths.len and tx.style.size == 15 and std.mem.startsWith(u8, tx.str, "a title")) {
            widths[n] = node.rect.w;
            n += 1;
        },
        else => {},
    };
    try t.expectEqual(widths.len, n);
    try t.expectEqual(@as(usize, 0), f.p.board.list.selected);
    try t.expectEqual(widths[0], widths[1]);
}

test "a picture row in view shows its thumbnail" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(picture("png-one"), "", "Preview", 100);
    try f.show();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const id = f.p.board.list.visible[0].id;
    try t.expectEqualStrings("thumb", f.store.thumbnail(arena.allocator(), id));
    try t.expectEqual(@as(usize, 1), f.p.board.thumbnails.count());
    try t.expectEqualStrings("thumb", f.p.board.thumbnails.get(id).?);
}

test "rows out of view fetch no thumbnail" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [32]u8 = undefined;
    for (0..60) |i| {
        const bytes = try std.fmt.bufPrint(&buf, "png-{d}", .{i});
        _ = try f.store.add(picture(bytes), "", "Preview", @floatFromInt(100 + i));
    }
    try f.show();
    try t.expect(f.p.board.thumbnails.count() > 0);
    try t.expect(f.p.board.thumbnails.count() < 20);
}

test "deleting keeps the other rows and the selection's place" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(5);
    try f.show();

    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down });
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(@as(usize, 2), f.p.board.list.selected);
    try t.expectEqualStrings("entry number 2", f.p.board.list.selection().?.text);

    f.p.board.delete();
    try t.expectEqual(@as(usize, 4), f.p.board.list.rows.len);
    try t.expectEqual(@as(usize, 2), f.p.board.list.selected);
    try t.expectEqualStrings("entry number 1", f.p.board.list.selection().?.text);
    for (f.p.board.list.rows) |r| try t.expect(!std.mem.eql(u8, r.text, "entry number 2"));
}

test "deleting does not ask the store for the list again" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(4);
    _ = try f.store.add(picture("png-del"), "", "Preview", 2000);
    try f.show();

    const pic_id = f.p.board.list.rows[0].id;
    try t.expect(f.p.board.thumbnails.get(pic_id) != null);
    f.p.board.delete();
    try t.expect(!f.p.board.list.stale);
    try t.expectEqual(@as(usize, 4), f.p.board.list.rows.len);
    try t.expect(f.p.board.thumbnails.get(pic_id) == null);
}

test "a longer query narrows without asking the store" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "hello world" }, "x", "Notes", 10);
    _ = try f.store.add(.{ .text = "help desk" }, "x", "Notes", 20);
    _ = try f.store.add(.{ .text = "heavy rain" }, "x", "Notes", 30);
    _ = try f.store.add(.{ .text = "shell script" }, "x", "Notes", 40);
    try f.show();

    f.tester.typeText("he");
    f.tester.frame();
    try t.expectEqual(@as(usize, 4), f.p.board.list.rows.len);

    _ = try f.store.add(.{ .text = "helium balloon" }, "x", "Notes", 50);

    f.tester.typeText("l");
    f.tester.frame();
    try t.expectEqual(@as(usize, 3), f.p.board.list.rows.len);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const fresh = try f.store.list(arena.allocator(), "hel");
    try t.expectEqual(@as(usize, 4), fresh.len);
    var expected: [3]i64 = undefined;
    var n: usize = 0;
    for (fresh) |e| {
        if (!std.mem.eql(u8, e.text, "helium balloon")) {
            expected[n] = e.id;
            n += 1;
        }
    }
    try t.expectEqual(@as(usize, 3), n);
    for (f.p.board.list.rows, 0..) |r, i| try t.expectEqual(expected[i], r.id);
}

test "a query that hit the limit asks the store again" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..10) |i| {
        const s = try std.fmt.bufPrint(&buf, "entry en match {d}", .{i});
        _ = try f.store.add(.{ .text = s }, "x", "Notes", @floatFromInt(10 + i));
    }
    for (0..clipboard.search_limit) |i| {
        const s = try std.fmt.bufPrint(&buf, "alpha e item {d}", .{i});
        _ = try f.store.add(.{ .text = s }, "x", "Notes", @floatFromInt(100 + i));
    }
    try f.show();

    f.tester.typeText("e");
    f.tester.frame();
    try t.expectEqual(clipboard.search_limit, f.p.board.list.rows.len);

    f.tester.typeText("n");
    f.tester.frame();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const expected = try f.store.list(arena.allocator(), "en");
    try t.expectEqual(expected.len, f.p.board.list.rows.len);
    for (expected, f.p.board.list.rows) |a, b| try t.expectEqual(a.id, b.id);
}

test "history that changed is asked again" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "hello one" }, "x", "Notes", 10);
    _ = try f.store.add(.{ .text = "heavy rain" }, "x", "Notes", 20);
    try f.show();

    f.tester.typeText("he");
    f.tester.frame();

    _ = try f.store.add(.{ .text = "hello new" }, "x", "Notes", 30);
    f.p.board.list.markStale();

    f.tester.typeText("l");
    f.tester.frame();
    try t.expectEqual(@as(usize, 2), f.p.board.list.rows.len);
    try t.expectEqualStrings("hello new", f.p.board.list.rows[0].text);
}

test "a shorter query asks the store again" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "hello world" }, "x", "Notes", 10);
    _ = try f.store.add(.{ .text = "heavy rain" }, "x", "Notes", 20);
    try f.show();

    f.tester.typeText("hel");
    f.tester.frame();
    try t.expectEqual(@as(usize, 1), f.p.board.list.rows.len);

    f.tester.key(.backspace);
    f.tester.frame();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const expected = try f.store.list(arena.allocator(), "he");
    try t.expectEqual(expected.len, f.p.board.list.rows.len);
    for (expected, f.p.board.list.rows) |a, b| try t.expectEqual(a.id, b.id);
}

test "a board frame with undecoded thumbnails runs no decode and still lists every entry" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "first text note" }, "com.apple.Notes", "Notes", 100);
    _ = try f.store.add(.{ .image = .{ .name = "Alpha Shot", .png = &h.valid_png, .thumbnail = &h.valid_png, .width = 120, .height = 80 } }, "com.apple.Preview", "Preview", 200);
    _ = try f.store.add(.{ .text = "second text note" }, "com.apple.Safari", "Safari", 300);
    _ = try f.store.add(.{ .image = .{ .name = "Beta Shot", .png = &h.valid_png, .thumbnail = &h.valid_png, .width = 200, .height = 200 } }, "com.apple.screencaptureui", "Screenshot", 400);
    try f.show();

    try t.expectEqual(@as(u32, 8), f.tester.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, 0), f.tester.ctx.text.images.decoded.count());
    try t.expect(f.tester.hasText("4 entries"));
    try t.expect(f.tester.hasText("Beta Shot"));
    try t.expect(f.tester.hasText("second text note"));
    try t.expect(f.tester.hasText("Alpha Shot"));
    try t.expect(f.tester.hasText("first text note"));
    var placeholders: usize = 0;
    const nodes = f.tester.ctx.nodes.items;
    for (nodes) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, "photo") and n.parent < nodes.len) {
            const tile = nodes[n.parent];
            if (@abs(tile.rect.w - chrome.metrics.icon_size) < 0.5 and @abs(tile.rect.h - chrome.metrics.icon_size) < 0.5) {
                placeholders += 1;
            }
        },
        else => {},
    };
    try t.expectEqual(@as(usize, 2), placeholders);
}

test "holding cmd or copying keeps partial first page while switching filter loads all rows" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(board_mod.board_metrics.first_page_rows + 10);
    _ = f.p.board.warmFirstPage();
    try f.show();

    try t.expect(f.p.board.hasPartialRows());
    const partial_len = f.p.board.list.rows.len;

    f.tester.setMods(.{ .cmd = true });
    f.tester.frame();
    try t.expect(f.p.board.hasPartialRows());
    try t.expectEqual(partial_len, f.p.board.list.rows.len);

    _ = f.tester.shortcut(.{ .key = 'c', .cmd = true });
    try t.expect(f.p.board.hasPartialRows());
    try t.expectEqual(partial_len, f.p.board.list.rows.len);

    f.tester.setMods(.{});
    _ = f.tester.shortcut(.{ .key = '2', .cmd = true });
    try t.expect(!f.p.board.hasPartialRows());
    try t.expectEqual(board_mod.board_metrics.first_page_rows + 10, f.p.board.list.rows.len);
}
