//! Windowless Shell controller tests: Presence/Panel choreography, ⌘K nested
//! run-loop safety, Clipboard Capture error retry, Session Retention expiry,
//! and icon/paste-target ownership.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("../search.zig");
const shell_mod = @import("../shell.zig");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const mac = @import("../mac.zig");
const chrome = @import("../chrome.zig");
const icons_mod = @import("../icons.zig");
const h = @import("helpers.zig");
const t = std.testing;

const HostSpy = struct {
    clock: h.FakeClock = .{ .now = 1000 },
    change_count: isize = 1,
    clip_text: []const u8 = "",
    fail_next_read: bool = false,
    trusted: bool = true,
    front_pid: i32 = 77,
    front_bundle: []const u8 = "com.apple.Safari",
    front_name: []const u8 = "Safari",
    own_pid_val: i32 = 42,
    opened: std.ArrayList([]u8) = .empty,
    revealed: std.ArrayList([]u8) = .empty,
    clipboard_writes: usize = 0,
    icon_calls: std.atomic.Value(usize) = .init(0),
    decode_calls: std.atomic.Value(usize) = .init(0),
    main_thread_calls: std.atomic.Value(usize) = .init(0),
    main_thread_id: ?std.Thread.Id = null,
    entered: ?*std.Io.Semaphore = null,
    gate: ?*std.Io.Semaphore = null,
    finished: ?*std.Io.Semaphore = null,
    null_icons: bool = false,

    fn deinit(spy: *HostSpy) void {
        for (spy.opened.items) |s| t.allocator.free(s);
        spy.opened.deinit(t.allocator);
        for (spy.revealed.items) |s| t.allocator.free(s);
        spy.revealed.deinit(t.allocator);
    }

    fn openTarget(ctx: ?*anyopaque, target: []const u8) void {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        const copy = t.allocator.dupe(u8, target) catch return;
        spy.opened.append(t.allocator, copy) catch t.allocator.free(copy);
    }

    fn revealTarget(ctx: ?*anyopaque, path: []const u8) void {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        const copy = t.allocator.dupe(u8, path) catch return;
        spy.revealed.append(t.allocator, copy) catch t.allocator.free(copy);
    }

    fn writeClipboard(ctx: ?*anyopaque, _: clipboard.Kind, _: []const u8, _: ?[]const u8) void {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        spy.clipboard_writes += 1;
    }

    fn frontmost(ctx: ?*anyopaque, arena: std.mem.Allocator) mac.RunningApp {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        return .{
            .pid = spy.front_pid,
            .bundle_id = arena.dupe(u8, spy.front_bundle) catch "",
            .name = arena.dupe(u8, spy.front_name) catch "",
        };
    }

    fn ownPid(ctx: ?*anyopaque) i32 {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        return spy.own_pid_val;
    }

    fn canDeliver(ctx: ?*anyopaque) bool {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        return spy.trusted;
    }

    fn changeCount(ctx: ?*anyopaque) isize {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        return spy.change_count;
    }

    fn readBoard(ctx: ?*anyopaque, turn: ?*anyopaque, run: *const fn (?*anyopaque, clipboard.Pasteboard) anyerror!bool) anyerror!bool {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        if (spy.fail_next_read) {
            spy.fail_next_read = false;
            return error.SqliteBusy;
        }
        const pb: clipboard.Pasteboard = .{
            .ctx = spy,
            .has_type = struct {
                fn f(_: ?*anyopaque, _: []const u8) bool {
                    return false;
                }
            }.f,
            .file_paths = struct {
                fn f(_: ?*anyopaque, _: std.mem.Allocator) []const []const u8 {
                    return &.{};
                }
            }.f,
            .image_byte_count = struct {
                fn f(_: ?*anyopaque) ?usize {
                    return null;
                }
            }.f,
            .image = struct {
                fn f(_: ?*anyopaque, _: std.mem.Allocator) ?clipboard.PastedImage {
                    return null;
                }
            }.f,
            .text = struct {
                fn f(c: ?*anyopaque, _: std.mem.Allocator) []const u8 {
                    return @as(*HostSpy, @ptrCast(@alignCast(c))).clip_text;
                }
            }.f,
        };
        return run(turn, pb);
    }

    const sample_icon_bgra = [_]u8{
        10, 20, 30, 255, 40,  50,  60,  200,
        70, 80, 90, 150, 100, 110, 120, 255,
    };

    fn iconPixels(ctx: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, _: f64) ?mac.Icon {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        const idx = spy.icon_calls.fetchAdd(1, .seq_cst);
        if (spy.main_thread_id) |tid| {
            if (std.Thread.getCurrentId() == tid) _ = spy.main_thread_calls.fetchAdd(1, .seq_cst);
        }
        if (idx == 0) {
            if (spy.entered) |sem| sem.post(t.io);
            if (spy.gate) |sem| sem.waitUncancelable(t.io);
            if (spy.finished) |sem| sem.post(t.io);
        }
        if (spy.null_icons) return null;
        const bgra = gpa.dupe(u8, &sample_icon_bgra) catch return null;
        return .{ .bgra = bgra, .width = 2, .height = 2 };
    }

    fn decodePixels(ctx: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, _: u32, _: u32) ?mac.Icon {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        const idx = spy.decode_calls.fetchAdd(1, .seq_cst);
        if (spy.main_thread_id) |tid| {
            if (std.Thread.getCurrentId() == tid) _ = spy.main_thread_calls.fetchAdd(1, .seq_cst);
        }
        if (idx == 0) {
            if (spy.entered) |sem| sem.post(t.io);
            if (spy.gate) |sem| sem.waitUncancelable(t.io);
            if (spy.finished) |sem| sem.post(t.io);
        }
        if (spy.null_icons) return null;
        const bgra = gpa.dupe(u8, &sample_icon_bgra) catch return null;
        return .{ .bgra = bgra, .width = 2, .height = 2 };
    }

    fn host(spy: *HostSpy) shell_mod.Host {
        return .{
            .ctx = spy,
            .clock = spy.clock.binding(),
            .open = openTarget,
            .reveal = revealTarget,
            .write_clipboard = writeClipboard,
            .frontmost_app = frontmost,
            .own_pid = ownPid,
            .can_deliver_paste = canDeliver,
            .pasteboard_change_count = changeCount,
            .read_pasteboard = readBoard,
            .icon_pixels = iconPixels,
            .decode_pixels = decodePixels,
        };
    }
};

test "⌘K menu pins and deletes the opened Clipboard Entry across nested-run-loop captures and skips redraw when hidden" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();

    _ = try store.add(.{ .text = "chosen entry" }, "com.apple.Notes", "Notes", 900);

    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.syncPasteboardCount();

    const open_out = sh.hotKey(.clipboard, false);
    try t.expect(open_out.window == .place_unseen);
    try t.expectEqualStrings("Safari", sh.panel.board.paste_target);

    const chosen = sh.panel.board.list.selection().?;
    try t.expectEqualStrings("chosen entry", chosen.text);
    sh.panel.ask(.{ .clipboard = .{ .actions = chosen } });
    const pending_out = sh.applyPending();
    const menu_entry = pending_out.actions_menu orelse return error.ExpectedActionsMenu;
    try t.expectEqual(chosen.id, menu_entry.id);

    // Simulate a 500 ms capture tick landing while NSMenu's nested run loop is open:
    // the new copy lands at index 0 and shifts `chosen entry` down to index 1.
    spy.clock.advance(5);
    spy.change_count = 2;
    spy.clip_text = "nested run-loop copy";
    const cap_out = sh.captureTick();
    try t.expect(cap_out.redraw);
    try t.expectEqualStrings("nested run-loop copy", sh.panel.board.list.visible[0].text);
    try t.expectEqual(@as(usize, 1), sh.panel.board.list.selected);
    // Selection moves to index 0 (`nested run-loop copy`), away from `menu_entry`.
    sh.panel.board.list.move(false);
    try t.expectEqualStrings("nested run-loop copy", sh.panel.board.list.selection().?.text);

    // Toggle pin on `menu_entry`: must pin `chosen entry` by id, not the new selection at index 0.
    const pin_out = sh.applyBoardMenu(menu_entry, .toggle_pin);
    try t.expect(pin_out.redraw);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for (try store.list(arena.allocator(), "")) |row| {
        if (row.id == chosen.id) try t.expect(row.pinned_at != null);
        if (!std.mem.eql(u8, row.text, "chosen entry")) try t.expect(row.pinned_at == null);
    }

    // Lose focus before the menu closes, then pick Delete: deletes `chosen.id` and skips redraw.
    _ = sh.focusLost(false);
    try t.expect(sh.isHidden());
    const del_out = sh.applyBoardMenu(menu_entry, .delete);
    try t.expect(!del_out.redraw);
    try t.expectEqual(shell_mod.PasteOp.none, del_out.paste);

    _ = arena.reset(.retain_capacity);
    const remaining = try store.list(arena.allocator(), "");
    try t.expectEqual(@as(usize, 1), remaining.len);
    try t.expectEqualStrings("nested run-loop copy", remaining[0].text);
}

test "a transient Clipboard Capture failure keeps change_count so the next tick retries" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();

    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.syncPasteboardCount();
    try t.expectEqual(@as(isize, 1), sh.change_count);

    spy.change_count = 2;
    spy.clip_text = "recovered after busy";
    spy.fail_next_read = true;
    _ = sh.captureTick();
    try t.expectEqual(@as(isize, 1), sh.change_count);

    // Next 500 ms tick retries the same change_count = 2 and stores the entry.
    _ = sh.captureTick();
    try t.expectEqual(@as(isize, 2), sh.change_count);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try store.list(arena.allocator(), "");
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("recovered after busy", rows[0].text);

    // Duplicate copy (`Store.capture` -> false) still advances `change_count`.
    spy.change_count = 3;
    _ = sh.captureTick();
    try t.expectEqual(@as(isize, 3), sh.change_count);
}

test "session expiry, self-frontmost summon, hidden suggest replies, and paste ordering hold their contracts" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    _ = try store.add(.{ .text = "paste me" }, "com.apple.Notes", "Notes", 900);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));

    var spy: HostSpy = .{};
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();

    // 1. Open search, type "cal" (caching an icon PNG + duped path key), then summon when ownPid is frontmost.
    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
    tester.frame();
    wake.wait();
    _ = sh.pollIcons();
    try t.expectEqual(@as(usize, 1), sh.icons.count());
    const seq = sh.panel.pendingSuggestSeq();
    try t.expect(sh.shouldSendSuggest(seq));

    // Hide (arms retention timer); late web suggestion while hidden must NOT request a window redraw.
    const hide_out = sh.hotKey(.search, true);
    try t.expectEqual(shell_mod.WindowOp.hide, hide_out.window);
    try t.expect(hide_out.expiry_ms != null);
    const sug_out = sh.receiveSuggestions(seq, "cal", "[\"cal\",[\"calendar 2026\"]]");
    try t.expect(!sug_out.redraw);

    // Summon while frontmost pid == ownPid: keeps previous Safari paste_target without leaking.
    spy.front_pid = spy.own_pid_val;
    spy.front_bundle = "com.nanospot.app";
    spy.front_name = "Nanospot";
    _ = sh.hotKey(.clipboard, false);
    try t.expectEqual(@as(i32, 77), sh.paste_target.pid);
    try t.expectEqualStrings("Safari", sh.panel.board.paste_target);

    // 2. Return on board pastes: hides window and emits `.deliver = 77` in one Outcome.
    tester.frame();
    sh.panel.ask(.{ .clipboard = .{ .paste = sh.panel.board.list.selection().? } });
    const paste_out = sh.applyPending();
    try t.expectEqual(shell_mod.WindowOp.hide, paste_out.window);
    try t.expectEqual(shell_mod.PasteOp{ .deliver = 77 }, paste_out.paste);

    // 3. Expire retention after 6 minutes: evicts cached icons cleanly (verified by t.allocator).
    spy.clock.advance(6 * 60);
    const exp_out = sh.expireRetention();
    try t.expect(exp_out.release_idle);
    try t.expectEqual(@as(usize, 0), sh.icons.count());
}

test "keystroke pending stays open until a frame presents or the panel hides" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));

    var spy: HostSpy = .{};
    defer spy.deinit();
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();

    _ = sh.hotKey(.search, false);
    sh.panel.field.set("cal");
    sh.panel.refresh();
    try t.expect(sh.panel.keystrokePending());

    _ = sh.framePresented(false);
    try t.expect(sh.panel.keystrokePending());

    _ = sh.framePresented(true);
    try t.expect(!sh.panel.keystrokePending());

    sh.panel.field.set("ca");
    sh.panel.refresh();
    try t.expect(sh.panel.keystrokePending());
    _ = sh.hotKey(.search, true);
    try t.expect(!sh.panel.keystrokePending());
}

test "app icons pack from raw pixels with zero decodes and release on expiry" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    _ = try store.add(.{ .file = "/Applications/Notes.app" }, "com.apple.Finder", "Finder", 900);
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));

    var spy: HostSpy = .{};
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height, .scale = 2 });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
    tester.frame();
    try t.expectEqual(@as(usize, 0), sh.icons.count());
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.entries.count());
    wake.wait();
    try t.expect(sh.pollIcons().redraw);
    tester.frame();

    try t.expectEqual(@as(usize, 1), sh.icons.count());
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.headers.count());
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, 1), tester.ctx.text.images.entries.count());

    const atlas_side = std.math.sqrt(tester.ctx.text.images.pixels.len / 4);
    const atlas_side_f: f32 = @floatFromInt(atlas_side);
    var it = tester.ctx.text.images.entries.valueIterator();
    const e = it.next().?.entry.?;
    const ax: usize = @intFromFloat(@round(e.uv[0] * atlas_side_f));
    const ay: usize = @intFromFloat(@round(e.uv[1] * atlas_side_f));
    try t.expectEqualSlices(u8, HostSpy.sample_icon_bgra[0..8], tester.ctx.text.images.pixels[((ay + 0) * atlas_side + ax) * 4 ..][0..8]);
    try t.expectEqualSlices(u8, HostSpy.sample_icon_bgra[8..16], tester.ctx.text.images.pixels[((ay + 1) * atlas_side + ax) * 4 ..][0..8]);

    _ = sh.hotKey(.clipboard, false);
    tester.frame();
    wake.wait();
    try t.expect(sh.pollIcons().redraw);
    tester.frame();
    try t.expectEqual(@as(usize, 2), sh.icons.count());
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.headers.count());
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, 2), tester.ctx.text.images.entries.count());

    _ = sh.hotKey(.clipboard, true);
    spy.clock.advance(6 * 60);
    _ = sh.expireRetention();
    try t.expectEqual(@as(usize, 0), sh.icons.count());
}

test "open and reveal request hide before handing the target to the host" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    _ = try store.add(.{ .text = "https://example.com" }, "com.apple.Safari", "Safari", 900);
    _ = try store.add(.{ .file = "/tmp/sample.txt" }, "com.apple.Finder", "Finder", 901);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const entries = try store.list(arena.allocator(), "");
    const file_entry = entries[0];
    const url_entry = entries[1];

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();

    _ = sh.hotKey(.search, false);
    sh.panel.ask(.{ .open = "/Applications/Calendar.app" });
    const search_open = sh.applyPending();
    try t.expectEqual(shell_mod.WindowOp.hide, search_open.window);
    try t.expectEqualStrings("/Applications/Calendar.app", search_open.action.open);
    try t.expectEqual(@as(usize, 0), spy.opened.items.len);

    _ = sh.hotKey(.search, false);
    sh.panel.ask(.{ .reveal = "/tmp/sample.txt" });
    const search_reveal = sh.applyPending();
    try t.expectEqual(shell_mod.WindowOp.hide, search_reveal.window);
    try t.expectEqualStrings("/tmp/sample.txt", search_reveal.action.reveal);
    try t.expectEqual(@as(usize, 0), spy.revealed.items.len);

    _ = sh.hotKey(.clipboard, false);
    sh.panel.ask(.{ .clipboard = .{ .open = url_entry.text } });
    const board_open = sh.applyPending();
    try t.expectEqual(shell_mod.WindowOp.hide, board_open.window);
    try t.expectEqualStrings(url_entry.text, board_open.action.open);
    try t.expectEqual(@as(usize, 0), spy.opened.items.len);

    _ = sh.hotKey(.clipboard, false);
    sh.panel.ask(.{ .clipboard = .{ .reveal = file_entry.filePath().? } });
    const board_reveal = sh.applyPending();
    try t.expectEqual(shell_mod.WindowOp.hide, board_reveal.window);
    try t.expectEqualStrings(file_entry.filePath().?, board_reveal.action.reveal);
    try t.expectEqual(@as(usize, 0), spy.revealed.items.len);

    _ = sh.hotKey(.clipboard, false);
    sh.panel.ask(.{ .clipboard = .{ .actions = file_entry } });
    const menu_entry = sh.applyPending().actions_menu orelse return error.ExpectedActionsMenu;
    const menu_reveal = sh.applyBoardMenu(menu_entry, .reveal);
    try t.expectEqual(shell_mod.WindowOp.hide, menu_reveal.window);
    try t.expectEqualStrings(file_entry.filePath().?, menu_reveal.action.reveal);
    try t.expectEqual(@as(usize, 0), spy.revealed.items.len);
}

test "board paste writes the clipboard before hiding and delivering" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    _ = try store.add(.{ .text = "paste ordered" }, "com.apple.Notes", "Notes", 900);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();

    _ = sh.hotKey(.clipboard, false);
    const entry = sh.panel.board.list.selection().?;
    sh.panel.ask(.{ .clipboard = .{ .paste = entry } });
    const pending_paste = sh.applyPending();
    try t.expectEqual(@as(usize, 1), spy.clipboard_writes);
    try t.expectEqual(shell_mod.WindowOp.hide, pending_paste.window);
    try t.expectEqual(shell_mod.ActionOp.none, pending_paste.action);
    try t.expectEqual(shell_mod.PasteOp{ .deliver = 77 }, pending_paste.paste);

    _ = sh.hotKey(.clipboard, false);
    sh.panel.ask(.{ .clipboard = .{ .actions = entry } });
    const menu_entry = sh.applyPending().actions_menu orelse return error.ExpectedActionsMenu;
    const menu_paste = sh.applyBoardMenu(menu_entry, .paste);
    try t.expectEqual(@as(usize, 2), spy.clipboard_writes);
    try t.expectEqual(shell_mod.WindowOp.hide, menu_paste.window);
    try t.expectEqual(shell_mod.ActionOp.none, menu_paste.action);
    try t.expectEqual(shell_mod.PasteOp{ .deliver = 77 }, menu_paste.paste);
}

test "layout never fetches icons on the main thread" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));

    var spy: HostSpy = .{ .main_thread_id = std.Thread.getCurrentId() };
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
    tester.frame();
    try t.expectEqual(@as(usize, 0), spy.main_thread_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.entries.count());

    wake.wait();
    try t.expect(sh.pollIcons().redraw);
    try t.expectEqual(@as(usize, 1), spy.icon_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), spy.main_thread_calls.load(.seq_cst));

    tester.frame();
    try t.expectEqual(@as(usize, 1), tester.ctx.text.images.entries.count());
}

const WakeCounter = struct {
    sem: std.Io.Semaphore = .{ .permits = 0 },
    count: std.atomic.Value(usize) = .init(0),

    fn wake(ctx: ?*anyopaque) void {
        const w: *@This() = @ptrCast(@alignCast(ctx));
        _ = w.count.fetchAdd(1, .seq_cst);
        w.sem.post(t.io);
    }

    fn binding(w: *@This()) icons_mod.Wake {
        return .{ .ctx = w, .wake = wake };
    }
};

test "two files with one extension cause one fetch, folders share one key, and apps keep bundle keys" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "docs");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "docs/shared_first.pdf", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "docs/shared_SECOND.PDF", .data = "" });
    try tmp.dir.createDirPath(t.io, "shared_alpha");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shared_alpha/one.pdf", .data = "" });
    try tmp.dir.createDirPath(t.io, "shared_beta.dir");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shared_beta.dir/two.pdf", .data = "" });
    try tmp.dir.createDirPath(t.io, "Apps/SharedOne.app/Contents");
    try tmp.dir.createDirPath(t.io, "Apps/SharedTwo.app/Contents");
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    const apps = try std.fs.path.join(t.allocator, &.{ root, "Apps" });
    defer t.allocator.free(apps);
    try search.scanApps(&cat, t.io, apps);
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    try cat.buildIndex(idx, root);

    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();

    var spy: HostSpy = .{};
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    sh.panel.field.set("pdf");
    sh.panel.refresh();
    tester.frame();
    while (sh.icons.hasPending()) {
        wake.wait();
        _ = sh.pollIcons();
    }
    try t.expectEqual(@as(usize, 1), spy.icon_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 1), sh.icons.count());

    sh.panel.field.set("shared");
    sh.panel.refresh();
    tester.frame();
    while (sh.icons.hasPending()) {
        wake.wait();
        _ = sh.pollIcons();
    }
    try t.expectEqual(@as(usize, 4), spy.icon_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 4), sh.icons.count());

    tester.frame();
    try t.expectEqual(@as(usize, 4), tester.ctx.text.images.entries.count());
    try t.expectEqual(@as(usize, 4), spy.icon_calls.load(.seq_cst));
}

test "many icons arriving together cause one redraw and cache caps at max_icons" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try h.addNumberedApps(&cat, 70);

    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var gate: std.Io.Semaphore = .{ .permits = 0 };
    var spy: HostSpy = .{ .entered = &entered, .gate = &gate };
    defer spy.deinit();
    var wake: WakeCounter = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    defer gate.post(t.io);
    sh.startIconWorker(t.io, wake.binding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    tester.typeText("app");
    tester.frame();
    entered.waitUncancelable(t.io);
    gate.post(t.io);

    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        const out = sh.pollIcons();
        try t.expect(out.redraw);
    }
    try t.expectEqual(@as(usize, 1), wake.count.load(.seq_cst));
    try t.expect(!sh.pollIcons().redraw);
    const first_batch = sh.icons.count();
    try t.expect(first_batch >= 4);

    spy.entered = null;
    spy.gate = null;
    for (0..69) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        _ = sh.pollIcons();
    }
    try t.expectEqual(shell_mod.max_icons, sh.icons.count());
    try t.expectEqual(shell_mod.max_icons, spy.icon_calls.load(.seq_cst));
}

test "frequent apps prefetch at launch and at hide without redrawing while hidden" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Notes.app"));
    try store.recordAppOpen("/Applications/Calendar.app", 900);

    var spy: HostSpy = .{};
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    _ = sh.launched(true);
    try t.expect(sh.icons.hasPending());
    while (sh.icons.hasPending()) {
        wake.wait();
        const out = sh.pollIcons();
        try t.expect(!out.redraw);
    }
    try t.expectEqual(@as(usize, 1), sh.icons.count());
    try t.expectEqual(@as(usize, 1), spy.icon_calls.load(.seq_cst));

    _ = sh.hotKey(.search, false);
    tester.frame();
    try t.expectEqual(@as(usize, 1), tester.ctx.text.images.entries.count());
    try t.expectEqual(@as(usize, 1), spy.icon_calls.load(.seq_cst));

    _ = sh.framePresented(true);
    tester.typeText("cal");
    sh.panel.ask(.{ .open = "/Applications/Notes.app" });
    _ = sh.applyPending();
    try t.expect(sh.isHidden());
    try t.expect(sh.icons.hasPending());
    while (sh.icons.hasPending()) {
        wake.wait();
        const out = sh.pollIcons();
        try t.expect(!out.redraw);
    }
    try t.expectEqual(@as(usize, 2), sh.icons.count());
    try t.expectEqual(@as(usize, 2), spy.icon_calls.load(.seq_cst));

    _ = sh.hotKey(.search, false);
    sh.panel.clearField();
    tester.frame();
    try t.expectEqual(@as(usize, 2), tester.ctx.text.images.entries.count());
    try t.expectEqual(@as(usize, 2), spy.icon_calls.load(.seq_cst));

    _ = sh.hotKey(.search, true);
    try t.expect(sh.icons.hasPending());
    while (sh.icons.hasPending()) {
        wake.wait();
        try t.expect(!sh.pollIcons().redraw);
    }
    try t.expectEqual(@as(usize, 2), sh.icons.count());

    _ = sh.hotKey(.search, false);
    sh.panel.retention_seconds = 0;
    _ = sh.hotKey(.search, true);
    try t.expect(!sh.icons.hasPending());
    try t.expectEqual(@as(usize, 0), sh.icons.count());
}

test "icon worker drops results from a forgotten session and null fetches do not loop" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calendar.app"));
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Notes.app"));

    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var gate: std.Io.Semaphore = .{ .permits = 0 };
    var finished: std.Io.Semaphore = .{ .permits = 0 };
    var spy: HostSpy = .{ .entered = &entered, .gate = &gate, .finished = &finished };
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    defer gate.post(t.io);
    sh.startIconWorker(t.io, wake.iconBinding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
    tester.frame();
    entered.waitUncancelable(t.io);

    _ = sh.hotKey(.search, true);
    spy.clock.advance(6 * 60);
    const exp = sh.expireRetention();
    try t.expect(exp.release_idle);
    try t.expectEqual(@as(usize, 0), sh.icons.count());
    try t.expect(!sh.icons.hasPending());

    gate.post(t.io);
    finished.waitUncancelable(t.io);
    spy.entered = null;
    spy.gate = null;
    spy.finished = null;

    _ = sh.hotKey(.search, false);
    tester.typeText("not");
    tester.frame();
    while (sh.icons.hasPending()) {
        wake.wait();
        _ = sh.pollIcons();
    }
    try t.expectEqual(@as(usize, 1), sh.icons.count());
    try t.expect(sh.icons.entries.contains("app:/Applications/Notes.app"));
    try t.expect(!sh.icons.entries.contains("app:/Applications/Calendar.app"));

    sh.icons.clear();
    spy.null_icons = true;
    const before_null = spy.icon_calls.load(.seq_cst);
    sh.panel.field.set("cal");
    sh.panel.refresh();
    tester.frame();
    while (sh.icons.hasPending()) {
        wake.wait();
        try t.expect(!sh.pollIcons().redraw);
    }
    tester.frame();
    try t.expectEqual(@as(usize, 0), sh.icons.count());
    try t.expect(!sh.icons.hasPending());
    try t.expectEqual(before_null + 1, spy.icon_calls.load(.seq_cst));
}

test "board thumbnails decode on the worker in one batch and only the first page survives hide and expiry" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var png_buf: [16]u8 = undefined;
    for (0..12) |i| {
        const png = try std.fmt.bufPrint(&png_buf, "img-{d}", .{i});
        _ = try store.add(.{ .image = .{ .name = "Shot", .png = png, .thumbnail = &h.valid_png, .width = 100, .height = 100 } }, "com.apple.screencaptureui", "Screenshot", @floatFromInt(100 + i));
    }

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var gate: std.Io.Semaphore = .{ .permits = 0 };
    var spy: HostSpy = .{ .main_thread_id = std.Thread.getCurrentId(), .entered = &entered, .gate = &gate };
    defer spy.deinit();
    var wake: WakeCounter = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    defer gate.post(t.io);
    sh.startIconWorker(t.io, wake.binding());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height, .scale = 2 });
    defer tester.deinit();

    _ = sh.hotKey(.clipboard, false);
    tester.frame();
    try t.expectEqual(@as(usize, 0), spy.main_thread_calls.load(.seq_cst));
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.entries.count());
    try t.expect(sh.icons.hasPending());

    entered.waitUncancelable(t.io);
    gate.post(t.io);
    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        try t.expect(sh.pollIcons().redraw);
    }
    try t.expectEqual(@as(usize, 1), wake.count.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), spy.main_thread_calls.load(.seq_cst));

    tester.frame();
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expect(tester.ctx.text.images.entries.count() >= 8);

    spy.entered = null;
    spy.gate = null;
    tester.scroll(150, 300, -1e6);
    tester.settle(1);
    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        _ = sh.pollIcons();
    }
    const before_hide = spy.decode_calls.load(.seq_cst);
    try t.expectEqual(@as(usize, 13), before_hide);

    _ = sh.hotKey(.clipboard, true);
    spy.clock.advance(6 * 60);
    const exp = sh.expireRetention();
    try t.expect(exp.release_idle);

    var fresh: ui.Tester = undefined;
    try fresh.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height, .scale = 2 });
    defer fresh.deinit();

    _ = sh.hotKey(.clipboard, false);
    fresh.frame();
    try t.expectEqual(@as(u32, 8), fresh.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, chrome.metrics.max_visible_rows), fresh.ctx.text.images.entries.count());
    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        _ = sh.pollIcons();
    }
    try t.expectEqual(before_hide + 1, spy.decode_calls.load(.seq_cst));

    fresh.scroll(150, 300, -1e6);
    fresh.settle(1);
    while (sh.icons.hasPending()) {
        wake.sem.waitUncancelable(t.io);
        _ = sh.pollIcons();
    }
    try t.expectEqual(before_hide + 3, spy.decode_calls.load(.seq_cst));
}

test "warming the board while hidden prepares first-page rows and thumbnails, refreshes on capture, and loads older rows on scroll" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var text_buf: [32]u8 = undefined;
    for (0..25) |i| {
        const line = try std.fmt.bufPrint(&text_buf, "entry {d}", .{i});
        _ = try store.add(.{ .text = line }, "com.apple.Notes", "Notes", @floatFromInt(100 + i));
    }
    _ = try store.add(.{ .image = .{ .name = "Warm One", .png = "w1", .thumbnail = &h.valid_png, .width = 80, .height = 80 } }, "com.apple.Preview", "Preview", 500);
    _ = try store.add(.{ .image = .{ .name = "Warm Two", .png = "w2", .thumbnail = &h.valid_png, .width = 80, .height = 80 } }, "com.apple.Preview", "Preview", 501);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();
    var wake: h.WakeSignal = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.syncPasteboardCount();
    sh.startIconWorker(t.io, wake.iconBinding());

    sh.warmBoard();
    try t.expect(sh.icons.hasPending());
    while (sh.icons.hasPending()) {
        wake.wait();
        try t.expect(!sh.pollIcons().redraw);
    }

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height, .scale = 2 });
    defer tester.deinit();

    _ = sh.hotKey(.clipboard, false);
    tester.frame();
    try t.expect(tester.hasText("27 entries"));
    try t.expect(tester.hasText("Warm Two"));
    try t.expect(tester.hasText("entry 24"));
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expect(tester.ctx.text.images.entries.count() >= 2);

    tester.scroll(150, 300, -1e6);
    tester.settle(1);
    try t.expect(tester.hasText("entry 0"));

    _ = sh.hotKey(.clipboard, true);
    spy.clock.advance(5);
    spy.change_count = 2;
    spy.clip_text = "copied while hidden";
    const cap = sh.captureTick();
    try t.expect(!cap.redraw);

    _ = sh.hotKey(.clipboard, false);
    tester.scroll(150, 300, 1e6);
    tester.settle(1);
    try t.expect(tester.hasText("28 entries"));
    try t.expect(tester.hasText("copied while hidden"));
}

test "search writes leave warm rows valid, pinned overflow still selects a hidden capture, and clear wakes ready kept images" {
    var ts = try h.TmpStore.init();
    defer ts.deinit();
    var store = try h.openMemory(&ts);
    defer store.close();
    var text_buf: [32]u8 = undefined;
    for (0..board_mod.board_metrics.first_page_rows) |i| {
        const line = try std.fmt.bufPrint(&text_buf, "pinned {d}", .{i});
        _ = try store.add(.{ .text = line }, "com.apple.Notes", "Notes", @floatFromInt(100 + i));
    }
    var list_arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer list_arena.deinit();
    for (try store.list(list_arena.allocator(), ""), 0..) |e, i| {
        try store.togglePin(e.id, @floatFromInt(200 + i));
    }

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: HostSpy = .{};
    defer spy.deinit();
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();
    sh.syncPasteboardCount();
    sh.warmBoard();

    const tok_before = store.changeToken();
    try store.recordQuery(.search, "cal", 300);
    try store.recordAppOpen("/Applications/Safari.app", 300);
    try t.expectEqual(tok_before, store.changeToken());
    try t.expectEqual(tok_before, sh.panel.board.warm_changes.?);

    _ = sh.hotKey(.clipboard, false);
    sh.panel.field.set("pinned");
    sh.panel.refresh();
    _ = sh.hotKey(.clipboard, true);
    sh.panel.field.clear();
    sh.panel.retained_board.query.clearRetainingCapacity();

    spy.clock.advance(5);
    spy.change_count = 2;
    spy.clip_text = "unpinned fresh copy";
    _ = sh.captureTick();

    _ = sh.hotKey(.clipboard, false);
    try t.expectEqualStrings("unpinned fresh copy", sh.panel.board.list.selection().?.text);

    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var gate: std.Io.Semaphore = .{ .permits = 0 };
    var icon_spy: HostSpy = .{ .entered = &entered, .gate = &gate };
    defer icon_spy.deinit();
    var wake: WakeCounter = .{};
    var cache: icons_mod.Cache = .init(t.allocator, 64);
    defer cache.deinit();
    defer gate.post(t.io);
    cache.setDecoder(&icon_spy, HostSpy.decodePixels);
    cache.startWorker(t.io, &icon_spy, HostSpy.iconPixels, wake.binding());

    _ = cache.decodeOrEnqueue("entry.1", &h.valid_png, 32, 32, true);
    cache.prefetch("/Applications/Slow.app", .app);
    entered.waitUncancelable(t.io);
    gate.post(t.io);
    entered.waitUncancelable(t.io);
    cache.clear();
    gate.post(t.io);
    wake.sem.waitUncancelable(t.io);
    try t.expect(cache.poll());
    try t.expect(cache.lookupImage("entry.1") != null);
    try t.expectEqual(@as(usize, 1), cache.keptCount());
    try t.expectEqual(cache.lookupImage("entry.1").?.pixels.bgra.len, cache.keptBytes());
}

test "decodeOrEnqueue skips a key already queued in the other bucket and retainFirstPage promotes it" {
    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var gate: std.Io.Semaphore = .{ .permits = 0 };
    var spy: HostSpy = .{ .entered = &entered, .gate = &gate };
    defer spy.deinit();
    var wake: WakeCounter = .{};
    var cache: icons_mod.Cache = .init(t.allocator, 64);
    defer cache.deinit();
    defer gate.post(t.io);
    cache.setDecoder(&spy, HostSpy.decodePixels);
    cache.startWorker(t.io, &spy, HostSpy.iconPixels, wake.binding());

    try t.expect(cache.decodeOrEnqueue("entry.1", &h.valid_png, 32, 32, false) == null);
    entered.waitUncancelable(t.io);
    try t.expect(cache.decodeOrEnqueue("entry.1", &h.valid_png, 32, 32, true) == null);
    gate.post(t.io);
    wake.sem.waitUncancelable(t.io);

    try t.expect(cache.poll());
    try t.expectEqual(@as(usize, 1), spy.decode_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), cache.keptCount());
    try t.expectEqual(@as(usize, 0), cache.keptBytes());

    cache.retainFirstPage(&.{"entry.1"});
    try t.expectEqual(@as(usize, 1), cache.keptCount());
    try t.expectEqual(cache.lookupImage("entry.1").?.pixels.bgra.len, cache.keptBytes());
}
