//! Presence state machine, session retention, state-machine invariants, and benchmark contract tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("../search.zig");
const panel_mod = @import("../panel.zig");
const mac = @import("../mac.zig");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const presence = @import("../presence.zig");
const chrome = @import("../chrome.zig");
const bench = @import("../bench.zig");
const h = @import("helpers.zig");
const t = std.testing;

const tmpCatalog = h.tmpCatalog;
const WakeSignal = h.WakeSignal;
const StubHooks = h.StubHooks;
const countRows = h.countRows;
const picture = h.picture;
const TmpStore = h.TmpStore;
const openMemory = h.openMemory;
const BoardFixture = h.BoardFixture;

const PresenceSpy = struct {
    log: [16]presence.Effect = undefined,
    len: usize = 0,
    frame_valid: bool = false,

    fn record(ctx: ?*anyopaque, e: presence.Effect) void {
        const s: *PresenceSpy = @ptrCast(@alignCast(ctx));
        s.log[s.len] = e;
        s.len += 1;
    }
    fn lastFrameValid(ctx: ?*anyopaque) bool {
        const s: *PresenceSpy = @ptrCast(@alignCast(ctx));
        return s.frame_valid;
    }
    fn presence_(s: *PresenceSpy) presence.Presence {
        return .{ .effects = .{ .ctx = s, .run = record, .last_frame_valid = lastFrameValid } };
    }
    /// The effects since the last call, in order.
    fn take(s: *PresenceSpy) []const presence.Effect {
        defer s.len = 0;
        return s.log[0..s.len];
    }
};

const showing = [_]presence.Effect{ .note_paste_target, .open_search, .place, .order_in_unseen, .start_entrance_timer };
const hiding = [_]presence.Effect{ .hide_window, .end_session };

fn shownPresence(spy: *PresenceSpy) presence.Presence {
    var p = spy.presence_();
    p.search(false, false);
    _ = p.framePresented(true);
    _ = spy.take();
    return p;
}

test "a reopened panel stays unseen until a frame of its own is presented, then shows once" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    try t.expect(!p.framePresented(true));
    p.search(false, false);
    try t.expectEqualSlices(presence.Effect, &showing, spy.take());
    try t.expectEqual(presence.Phase.entering, p.phase);
    // A frame built without a drawable is not on screen: the old one still is.
    try t.expect(!p.framePresented(false));
    try t.expect(p.framePresented(true));
    try t.expectEqualSlices(presence.Effect, &.{.reveal}, spy.take());
    try t.expect(!p.framePresented(true));
    try t.expectEqual(presence.Phase.shown, p.phase);
}

test "an entrance asks for a presented frame until one reveals it" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    try t.expect(!p.wantsPresentedFrame());
    p.search(false, false);
    try t.expect(p.wantsPresentedFrame());
    try t.expect(!p.framePresented(false));
    try t.expect(p.wantsPresentedFrame());
    try t.expect(p.framePresented(true));
    try t.expect(!p.wantsPresentedFrame());

    p.search(true, false);
    p.search(false, false);
    _ = spy.take();
    p.entranceTimedOut();
    p.entranceTimedOut();
    try t.expect(!p.wantsPresentedFrame());

    p.search(true, false);
    _ = spy.take();
    spy.frame_valid = true;
    p.search(false, false);
    try t.expect(!p.wantsPresentedFrame());
}

test "leaving the board by ⌫ switches to search in place, exactly as ⌥Space over a focused board" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.board(true, false);
    _ = spy.take();
    p.settle(.show_search);
    try t.expectEqualSlices(presence.Effect, &.{ .open_search, .place, .order_front }, spy.take());
    try t.expect(!p.isHidden());
}

test "a retained panel whose last frame is still valid shows at once, with no entrance wait" {
    var spy: PresenceSpy = .{ .frame_valid = true };
    var p = spy.presence_();
    p.search(false, false);
    try t.expectEqualSlices(presence.Effect, &.{ .note_paste_target, .open_search, .place, .order_in_seen }, spy.take());
    try t.expectEqual(presence.Phase.shown, p.phase);
    try t.expect(!p.framePresented(true));

    p.search(true, false);
    _ = spy.take();
    p.board(false, false);
    try t.expectEqualSlices(presence.Effect, &.{ .note_paste_target, .open_board, .place, .order_in_seen }, spy.take());

    p.board(true, true);
    _ = spy.take();
    spy.frame_valid = false;
    p.search(false, false);
    try t.expectEqualSlices(presence.Effect, &showing, spy.take());
    try t.expectEqual(presence.Phase.entering, p.phase);
}

test "⌥Space while focused hides and forgets the session, during the entrance too" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.search(true, false);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
    try t.expect(p.isHidden());

    p.search(false, false);
    _ = spy.take();
    p.search(true, false);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
    try t.expect(!p.framePresented(true));
}

test "an entrance's fallback timer reveals only its own entrance" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    p.search(false, false);
    p.search(true, false);
    p.search(false, false);
    _ = spy.take();
    // The first show's timer fires during the second entrance.
    p.entranceTimedOut();
    try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
    try t.expectEqual(presence.Phase.entering, p.phase);
    p.entranceTimedOut();
    try t.expectEqualSlices(presence.Effect, &.{.reveal}, spy.take());
    try t.expectEqual(presence.Phase.shown, p.phase);
}

test "a timer after a frame revealed the panel does nothing" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.entranceTimedOut();
    try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
}

test "⌥Space on a panel that is up but not focused brings it front with no entrance" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.search(false, false);
    try t.expectEqualSlices(presence.Effect, &.{ .open_search, .place, .order_front }, spy.take());
    try t.expectEqual(presence.Phase.shown, p.phase);
}

test "⌥⇧C opens the board, notes the target only from hidden, and hides only the board" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    p.board(false, false);
    try t.expectEqualSlices(presence.Effect, &.{ .note_paste_target, .open_board, .place, .order_in_unseen, .start_entrance_timer }, spy.take());
    _ = p.framePresented(true);
    _ = spy.take();
    // Over the search panel it switches to the board in place.
    p.board(true, false);
    try t.expectEqualSlices(presence.Effect, &.{ .open_board, .place, .order_front }, spy.take());
    p.board(true, true);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
}

test "⌥Space over a focused board switches to search in place instead of hiding" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.board(true, false);
    _ = spy.take();
    p.search(true, true);
    try t.expectEqualSlices(presence.Effect, &.{ .open_search, .place, .order_front }, spy.take());
    try t.expect(!p.isHidden());
}

test "launch shows the panel unless the grant guide is up; a reopen always does" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    p.launched(true);
    try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
    p.launched(false);
    try t.expectEqualSlices(presence.Effect, &showing, spy.take());

    var spy2: PresenceSpy = .{};
    var q = spy2.presence_();
    q.reopened();
    try t.expectEqualSlices(presence.Effect, &showing, spy2.take());
}

test "losing focus hides the panel, unless Quick Look took it" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.focusLost(true);
    try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
    p.focusLost(false);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
    p.focusLost(false);
    try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
}

test "after an action the panel hides, or stays for the board's copy, preview and menu" {
    const e: clipboard.Entry = .{ .id = 1, .kind = .text, .text = "x", .created_at = 0 };
    const row: search.Row = .{ .kind = .file, .title = "a", .subtitle = "~", .path = "/a", .score = 0 };
    const hides = [_]panel_mod.Action{ .hide, .{ .open = "/a" }, .{ .reveal = "/a" }, .{ .copy = row }, .{ .clipboard = .{ .open = "https://example.com" } }, .{ .clipboard = .{ .reveal = "/a" } } };
    for (hides) |a| {
        var spy: PresenceSpy = .{};
        var p = shownPresence(&spy);
        p.settle(a);
        try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
        try t.expect(p.isHidden());
    }
    const stays = [_]panel_mod.Action{ .{ .clipboard = .{ .copy = e } }, .{ .clipboard = .{ .preview = e } }, .{ .clipboard = .{ .actions = e } } };
    for (stays) |a| {
        var spy: PresenceSpy = .{};
        var p = shownPresence(&spy);
        p.settle(a);
        try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
        try t.expect(!p.isHidden());
    }
}

test "a board paste hides the panel before it sends ⌘V, so the target app has focus" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.settle(.{ .clipboard = .{ .paste = .{ .id = 1, .kind = .text, .text = "x", .created_at = 0 } } });
    try t.expectEqualSlices(presence.Effect, &.{ .hide_window, .end_session, .deliver_paste }, spy.take());
}

test "the 200-app latency benchmark measures keystroke publication, summon layout, and Return action" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try bench.populateCatalog(&cat, bench.catalog_app_count);
    try t.expectEqual(@as(usize, 200), cat.apps.items.len);

    const keystroke = try bench.measureKeystrokeToPublication(t.allocator, 16);
    try t.expect(keystroke.p50_ns > 0);
    try t.expect(keystroke.p99_ns >= keystroke.p50_ns);

    const summon = try bench.measureHotKeyToLaidOutFrame(t.allocator, 16);
    try t.expect(summon.p50_ns > 0);
    try t.expect(summon.p99_ns >= summon.p50_ns);

    const submit = try bench.measureReturnToAction(t.allocator, 16);
    try t.expect(submit.p50_ns > 0);
    try t.expect(submit.p99_ns >= submit.p50_ns);

    const built = try bench.measureKeystrokeToBuiltFrame(t.allocator, t.io, 4);
    try t.expectEqual(@as(usize, 4), built.runs);
    try t.expect(built.p99_ns >= built.p50_ns);

    const icons = try bench.measureFirstFrameWithIcons(t.allocator, t.io, 4);
    try t.expectEqual(@as(usize, 4), icons.runs);
    try t.expect(icons.p99_ns >= icons.p50_ns);

    const built_summon = try bench.measureHotKeyToBuiltFrame(t.allocator, 4);
    try t.expectEqual(@as(usize, 4), built_summon.runs);
    try t.expect(built_summon.p99_ns >= built_summon.p50_ns);

    try t.expect(bench.withinFrameBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 4_000_000, .runs = 4 },
        .{ .p50_ns = 1_000, .p99_ns = 7_000_000, .runs = 4 },
        .{ .p50_ns = 1_000, .p99_ns = 1_400_000, .runs = 4 },
    ));
    try t.expect(!bench.withinFrameBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 4_000_000, .runs = 4 },
        .{ .p50_ns = 1_000, .p99_ns = 9_000_000, .runs = 4 },
        .{ .p50_ns = 1_000, .p99_ns = 1_400_000, .runs = 4 },
    ));

    try t.expect(bench.withinBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 9_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 9_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 9_000, .runs = 16 },
    ));
    try t.expect(!bench.withinBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 9_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 11_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 9_000, .runs = 16 },
    ));
}

test "the injected clock advances board ages and pins, and forget clears both surfaces" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    _ = try store.add(.{ .text = "first snippet" }, "com.apple.Notes", "Notes", 1000);
    _ = try store.add(.{ .text = "second snippet" }, "com.apple.Safari", "Safari", 1000);
    var hooks: StubHooks = .{};
    hooks.clock.advance(1120);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();
    tester.settle(0.2);

    tester.typeText("cal");
    tester.settle(0.2);
    p.selectFilter(.apps);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(panel_mod.Filter.apps, p.list.filter);
    try t.expectEqual(@as(usize, 1), p.list.selected);

    p.showClipboard();
    tester.settle(0.2);
    try t.expect(tester.hasText("Safari \u{00B7} 2m"));
    hooks.clock.advance(180);
    try t.expectEqual(@as(f64, 1300), p.clock.now());
    tester.settle(0.2);
    try t.expect(tester.hasText("Safari \u{00B7} 5m"));

    _ = tester.shortcut(.{ .key = '.', .cmd = true });
    p.refresh();
    try t.expectEqual(@as(?f64, 1300), p.board.list.rows[0].pinned_at);

    p.board.list.selectFilter(.text);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.typeText("first");
    tester.settle(0.2);
    try t.expectEqual(clipboard.Filter.text, p.board.list.filter);
    try t.expectEqualStrings("first", p.field.text());

    p.forget();
    try t.expectEqual(panel_mod.Mode.search, p.mode);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(@as(usize, 0), p.list.rows.len);
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
    try t.expectEqual(panel_mod.Filter.all, p.list.filter);
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expectEqual(chrome.metrics.search_height, p.panelHeight());
    try t.expectEqual(chrome.metrics.width, p.panelWidth());
    try t.expectEqual(@as(usize, 0), p.board.list.rows.len);
    try t.expectEqual(@as(usize, 0), p.board.list.visible.len);
    try t.expectEqual(clipboard.Filter.all, p.board.list.filter);
    try t.expectEqual(@as(usize, 0), p.board.list.selected);
    try t.expect(p.board.list.stale);
    try t.expect(p.board.detail_id == null);
}

test "search retention selects the top row when the remembered path is gone, and clearing the field forgets at once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.list.selected);
    const removed = cat.apps.orderedRemove(1);
    t.allocator.free(removed.path);
    p.list.markStale();

    p.hide();
    hooks.clock.advance(60);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("cal", p.field.text());
    try t.expectEqual(@as(usize, 0), p.list.selected);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(panel_mod.Filter.apps, p.list.filter);
    p.clearField();
    p.hide();
    hooks.clock.advance(10);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.Filter.all, p.list.filter);
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
}

test "a retained reopen keeps the last presented frame valid until what it shows changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);
    try t.expect(!p.lastFrameValid());

    tester.typeText("cal");
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.frame();
    p.notePresented();
    try t.expect(p.lastFrameValid());

    p.hide();
    hooks.clock.advance(60);
    p.showSearch();
    try t.expect(p.lastFrameValid());
    try t.expectEqual(@as(usize, 1), p.list.selected);
    try t.expect(p.currentCompletion() == null);

    tester.frame();
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.up }));
    try t.expect(!p.lastFrameValid());
    p.notePresented();
    p.hide();
    for (cat.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.name, "Calculator")) {
        t.allocator.free(cat.apps.orderedRemove(i).path);
        break;
    };
    p.list.markStale();
    hooks.clock.advance(60);
    p.showSearch();
    try t.expect(!p.lastFrameValid());

    tester.frame();
    p.notePresented();
    p.hide();
    hooks.clock.advance(6 * 60);
    p.showSearch();
    try t.expectEqualStrings("", p.field.text());
    try t.expect(!p.lastFrameValid());
}

test "a retained board's last frame stays valid within the minute its ages were drawn in" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    _ = try store.add(.{ .text = "older note" }, "com.apple.Notes", "Notes", 100);
    _ = try store.add(.{ .text = "newer note" }, "com.apple.Notes", "Notes", 200);

    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.frame();
    p.notePresented();

    p.hide();
    hooks.clock.advance(10);
    p.showClipboard();
    try t.expectEqual(@as(usize, 1), p.board.list.selected);
    try t.expect(p.lastFrameValid());

    tester.frame();
    p.notePresented();
    p.hide();
    hooks.clock.advance(60);
    p.showClipboard();
    try t.expectEqual(@as(usize, 1), p.board.list.selected);
    try t.expect(!p.lastFrameValid());
}

test "a slow file index publishes apps on the keystroke's frame and file rows on the next; a retained reopen shows both at once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var wake: WakeSignal = .{};
    cat.startWorker(t.io, wake.binding());
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    hooks.clock.step = 0.01;
    tester.typeText("a");
    tester.frame();
    try t.expect(cat.hasPending());
    try t.expect(tester.hasText("Calculator"));
    try t.expectEqual(@as(usize, 2), countRows(p.list.visible, .app));
    try t.expectEqual(@as(usize, 0), countRows(p.list.visible, .file));

    wake.wait();
    try t.expect(p.poll());
    tester.frame();
    try t.expect(countRows(p.list.visible, .file) > 0);
    try t.expect(tester.hasText("kind-of-blue.flac"));
    try t.expectEqual(@as(usize, 0), p.list.selected);

    p.hide();
    hooks.clock.advance(60);
    p.showSearch();
    try t.expect(!cat.hasPending());
    try t.expect(countRows(p.list.visible, .file) > 0);
}

test "switching to the clipboard board while file search is in flight retains the file rows on return" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var wake: WakeSignal = .{};
    cat.startWorker(t.io, wake.binding());
    var hooks: StubHooks = .{};
    hooks.clock.advance(100);
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("return");
    tester.frame();
    try t.expect(cat.hasPending());
    try t.expectEqual(@as(usize, 0), countRows(p.list.visible, .file));

    p.showClipboard();
    tester.frame();
    wake.wait();
    try t.expect(!p.poll());

    hooks.clock.advance(30);
    p.showSearch();
    if (cat.hasPending()) {
        wake.wait();
        try t.expect(p.poll());
    }
    tester.frame();
    try t.expect(countRows(p.list.visible, .file) > 0);
    try t.expect(tester.hasText("2025-return.pdf"));
}

test "board retention restores query, kind filter, and selection or selects the newest matching copy" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/report.pdf" }, "com.apple.finder", "Finder", 100);
    _ = try store.add(.{ .text = "hello older note" }, "com.apple.Notes", "Notes", 200);
    _ = try store.add(.{ .text = "hello newer note" }, "com.apple.Notes", "Notes", 300);

    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();
    tester.settle(0.2);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(clipboard.Filter.text, p.board.list.filter);
    tester.typeText("hello");
    tester.settle(0.2);
    try t.expectEqual(@as(usize, 2), p.board.list.visible.len);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.board.list.selected);
    const remembered_id = p.board.list.selection().?.id;

    p.hide();
    // An unrelated copy while hidden does not match the query+filter, so the remembered selection stays.
    _ = try store.add(.{ .file = "/tmp/hello-other.pdf" }, "com.apple.finder", "Finder", 1050);
    _ = try store.add(.{ .text = "unrelated text" }, "com.apple.Notes", "Notes", 1060);
    hooks.clock.advance(4 * 60);
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("hello", p.field.text());
    try t.expectEqual(clipboard.Filter.text, p.board.list.filter);
    try t.expectEqual(remembered_id, p.board.list.selection().?.id);
    try t.expectEqual(@as(usize, 0), tester.ctx.focused_text.?.anchor);
    try t.expectEqual(@as(usize, 5), tester.ctx.focused_text.?.caret);

    p.hide();
    _ = try store.add(.{ .text = "hello brand new" }, "com.apple.Notes", "Notes", 1300);
    hooks.clock.advance(60);
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("hello", p.field.text());
    try t.expectEqual(clipboard.Filter.text, p.board.list.filter);
    try t.expectEqual(@as(usize, 0), p.board.list.selected);
    try t.expectEqualStrings("hello brand new", p.board.list.selection().?.text);

    p.clearField();
    p.hide();
    try t.expect(p.nextExpiryMs() == null);
    try t.expectEqual(@as(usize, 0), p.board.list.rows.len);
}

test "search and clipboard board sessions expire separately, and zero retention forgets on hide" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/report.pdf" }, "com.apple.finder", "Finder", 50);
    _ = try store.add(.{ .text = "alpha clip" }, "com.apple.Notes", "Notes", 60);

    var hooks: StubHooks = .{};
    hooks.clock.advance(100);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    p.hide();

    hooks.clock.advance(3 * 60);
    p.showClipboard();
    tester.frame();
    try t.expect(tester.shortcut(.{ .key = '3', .cmd = true }));
    tester.typeText("report");
    tester.settle(0.1);
    try t.expectEqual(clipboard.Filter.files, p.board.list.filter);
    p.hide();

    // Search is 6m old (expired) while the board is 3m old (still retained).
    hooks.clock.advance(3 * 60);
    try t.expect(!p.expire());
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.Filter.all, p.list.filter);

    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("report", p.field.text());
    try t.expectEqual(clipboard.Filter.files, p.board.list.filter);

    p.retention_seconds = 0;
    p.hide();
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(clipboard.Filter.all, p.board.list.filter);

    p.showSearch();
    tester.frame();
    tester.typeText("cal");
    tester.settle(0.1);
    p.hide();
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(@as(usize, 0), p.list.rows.len);
}

// The state machines' invariants, docs/state-machines.md. Each test names the
// invalid state it once reached.

test "a board action keeps the entry it named when a copy lands before the shell runs it" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .text = "the entry the user chose" }, "x", "Notes", 1000);
    try f.show();
    f.tester.key(.enter);
    const asked = (f.p.pending orelse return error.NoAction).clipboard.paste;
    // The shell's capture tick, run before the shell's turn: an ⌘K menu's own run loop allows it.
    _ = try f.store.add(.{ .text = "a copy from another app, longer than the first" }, "x", "Notes", 1001);
    f.p.board.list.markStale();
    f.p.refresh();
    try t.expectEqualStrings("the entry the user chose", asked.text);
}

test "a search action keeps the row it named when the file rows land before the shell runs it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var wake: WakeSignal = .{};
    cat.startWorker(t.io, wake.binding());
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.typeText("cal");
    tester.settle(0.2);
    try t.expect(cat.hasPending());
    p.list.selected = p.list.visible.len - 1;
    tester.key(.enter);
    const asked = (p.pending orelse return error.NoAction).open;
    const want = try t.allocator.dupe(u8, asked);
    defer t.allocator.free(want);
    wake.wait();
    try t.expect(p.poll());
    try t.expectEqualStrings(want, asked);
}

test "an action settled after the panel already hid repeats no exit, sends no ⌘V, and summons nothing" {
    const e: clipboard.Entry = .{ .id = 1, .kind = .text, .text = "x", .created_at = 0 };
    const late = [_]panel_mod.Action{ .hide, .{ .open = "/a" }, .{ .clipboard = .{ .paste = e } }, .show_search };
    for (late) |a| {
        var spy: PresenceSpy = .{};
        var p = shownPresence(&spy);
        p.focusLost(false);
        try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
        p.settle(a);
        try t.expectEqualSlices(presence.Effect, &.{}, spy.take());
        try t.expect(p.isHidden());
    }
}

test "a copy stored while pinned entries alone fill the byte budget stays in history" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    store.budget = .{ .bytes = 3100, .entries = 100 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pngs: [4][1000]u8 = undefined;
    for (&pngs, 0..) |*png, i| {
        @memset(png, @intCast('a' + i));
        _ = try store.add(picture(png), "", "Preview", @floatFromInt(10 + i));
        for (try store.list(a, "")) |e| if (e.pinned_at == null) try store.togglePin(e.id, @floatFromInt(20 + i));
    }

    try t.expect(try store.add(.{ .text = "just copied" }, "", "Notes", 100));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 5), rows.len);
    try t.expectEqualStrings("just copied", rows[4].text);
}

test "hiding again within the retention window arms no second expiry timer" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    p.showSearch();
    p.field.set("notes");
    p.hide();
    try t.expect(p.armExpiry() != null);
    hooks.clock.advance(60);
    p.showSearch();
    p.hide();
    try t.expect(p.armExpiry() == null);
    // The pending timer fires: its turn arms the next one.
    p.disarmExpiry();
    try t.expect(!p.expire());
    try t.expect(p.armExpiry() != null);
}

test "a released surface draws the same frame again" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cat = try tmpCatalog(&tmp);
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("cal");
    tester.settle(0.2);
    try t.expect(tester.hasText("Calendar"));
    try t.expect(tester.hasText("Calculator"));

    mac.forgetContextStorage(&tester.ctx);
    try t.expectEqual(@as(usize, 0), tester.ctx.nodes.capacity);
    tester.frame();
    try t.expect(tester.hasText("Calendar"));
    try t.expect(tester.hasText("Calculator"));
}

test "scroll position survives a release" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.seed(30);
    try f.show();

    const tester = &f.tester;
    tester.scroll(150, 300, -180);
    tester.settle(0.2);

    var scroll_id: ?u64 = null;
    var saved_offset: f32 = 0;
    var it = tester.ctx.scroll.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > 0) {
            scroll_id = e.key_ptr.*;
            saved_offset = e.value_ptr.*;
            break;
        }
    }
    const id = scroll_id orelse return error.ExpectedScrollOffset;

    mac.forgetContextStorage(&tester.ctx);
    tester.frame();
    try t.expectEqual(saved_offset, tester.ctx.scroll.get(id).?);
}

test "extreme clock and retention values do not overflow expiry or frame keys" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    p.retention_seconds = std.math.inf(f64);
    p.showSearch();
    p.field.set("notes");
    p.hide();
    try t.expect(p.nextExpiryMs() == null);

    p.retention_seconds = 1e20;
    p.showSearch();
    p.hide();
    try t.expectEqual(std.math.maxInt(u32), p.nextExpiryMs().?);

    hooks.clock.advance(1e20);
    p.showClipboard();
    p.notePresented();
    try t.expect(p.lastFrameValid());
}
