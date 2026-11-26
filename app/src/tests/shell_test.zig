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

    fn deinit(spy: *HostSpy) void {
        for (spy.opened.items) |s| t.allocator.free(s);
        spy.opened.deinit(t.allocator);
    }

    fn openTarget(ctx: ?*anyopaque, target: []const u8) void {
        const spy: *HostSpy = @ptrCast(@alignCast(ctx));
        const copy = t.allocator.dupe(u8, target) catch return;
        spy.opened.append(t.allocator, copy) catch t.allocator.free(copy);
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

    fn iconPixels(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, _: f64) ?mac.Icon {
        const bgra = gpa.dupe(u8, &sample_icon_bgra) catch return null;
        return .{ .bgra = bgra, .width = 2, .height = 2 };
    }

    fn host(spy: *HostSpy) shell_mod.Host {
        return .{
            .ctx = spy,
            .clock = spy.clock.binding(),
            .open = openTarget,
            .frontmost_app = frontmost,
            .own_pid = ownPid,
            .can_deliver_paste = canDeliver,
            .pasteboard_change_count = changeCount,
            .read_pasteboard = readBoard,
            .icon_pixels = iconPixels,
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
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
    defer tester.deinit();

    // 1. Open search, type "cal" (caching an icon PNG + duped path key), then summon when ownPid is frontmost.
    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
    tester.frame();
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
    var sh: shell_mod.Shell = undefined;
    sh.init(t.allocator, &cat, &store, spy.host());
    defer sh.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, sh.view(), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height, .scale = 2 });
    defer tester.deinit();

    _ = sh.hotKey(.search, false);
    tester.typeText("cal");
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
    try t.expectEqual(@as(usize, 2), sh.icons.count());
    try t.expectEqual(@as(usize, 0), tester.ctx.text.images.headers.count());
    try t.expectEqual(@as(u32, 8), tester.ctx.text.images.decodes_left);
    try t.expectEqual(@as(usize, 2), tester.ctx.text.images.entries.count());

    _ = sh.hotKey(.clipboard, true);
    spy.clock.advance(6 * 60);
    _ = sh.expireRetention();
    try t.expectEqual(@as(usize, 0), sh.icons.count());
}
