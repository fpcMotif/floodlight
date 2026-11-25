//! Geometry and Full Disk Access grant flow tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const permission = @import("../permission.zig");
const mac = @import("../mac.zig");
const board_mod = @import("../board.zig");
const presence = @import("../presence.zig");
const chrome = @import("../chrome.zig");
const h = @import("helpers.zig");
const t = std.testing;

const screen = h.screen;

test "the search field sits at the same height whatever the panel's size" {
    const compact = presence.panelFrame(screen, chrome.metrics.width, chrome.metrics.search_height);
    const expanded = presence.panelFrame(screen, chrome.metrics.width, chrome.metrics.expanded_height);
    const board = presence.panelFrame(screen, board_mod.board_metrics.width, board_mod.board_metrics.height);
    try t.expectEqual(compact.y + compact.h, expanded.y + expanded.h);
    try t.expectEqual(compact.y + compact.h, board.y + board.h);
    try t.expectEqual(@as(f64, 642), compact.y + compact.h);
    try t.expectEqual((screen.w - board.w) / 2, board.x);
}

test "search and the clipboard board share one size" {
    try t.expectEqual(chrome.metrics.width, board_mod.board_metrics.width);
    try t.expectEqual(chrome.metrics.expanded_height, board_mod.board_metrics.height);
}

test "a panel taller than the room under the field stays on screen" {
    const short: permission.Rect = .{ .x = 0, .y = 25, .w = 1280, .h = 500 };
    const f = presence.panelFrame(short, board_mod.board_metrics.width, 480);
    try t.expectEqual(@as(f64, 25), f.y);
}

test "the guidance panel sits under System Settings, overlapping it" {
    const f = permission.anchorFrame(.{ .x = 400, .y = 300, .w = 640, .h = 480 }, null, screen);
    try t.expectEqual(permission.Rect{ .x = 530, .y = 210, .w = 380, .h = 110 }, f);
}

test "the guidance panel stays on screen" {
    const low = permission.anchorFrame(.{ .x = 400, .y = 40, .w = 640, .h = 480 }, null, screen);
    try t.expectEqual(@as(f64, 8), low.y);
    try t.expectEqual(@as(f64, 530), low.x);
    const right = permission.anchorFrame(.{ .x = 1200, .y = 300, .w = 400, .h = 400 }, null, screen);
    try t.expect(right.x + right.w <= screen.w - 12);
    const left = permission.anchorFrame(.{ .x = -100, .y = 300, .w = 400, .h = 400 }, null, screen);
    try t.expect(left.x >= 12);
}

test "without System Settings it follows the panel, then the screen" {
    const under_parent = permission.anchorFrame(null, .{ .x = 200, .y = 200, .w = 600, .h = 400 }, screen);
    try t.expectEqual(@as(f64, 310), under_parent.x);
    try t.expectEqual(@as(f64, 106), under_parent.y);
    const alone = permission.anchorFrame(null, null, screen);
    try t.expectEqual(@as(f64, 530), alone.x);
    try t.expectEqual(@as(f64, 80), alone.y);
}

test "window list bounds flip to Cocoa's bottom-left origin" {
    const r = permission.quartzToCocoa(.{ .x = 100, .y = 100, .w = 400, .h = 300 }, 900);
    try t.expectEqual(permission.Rect{ .x = 100, .y = 500, .w = 400, .h = 300 }, r);
}

test "beginning opens System Settings, places the panel once, and guards the poll timer" {
    var g: permission.Grant = .{ .anchors = .{ .settings = .{ .x = 400, .y = 300, .w = 640, .h = 480 }, .screen = screen } };
    try t.expectEqual(permission.Phase.idle, g.phase);

    const first = g.begin(false);
    try t.expect(g.isGuiding());
    try t.expect(first.open_settings);
    try t.expectEqual(permission.WindowOp{ .show = .{ .x = 530, .y = 210, .w = 380, .h = 110 } }, first.window);
    try t.expectEqual(@as(?u32, permission.poll_ms), first.poll_ms);

    // Asking again brings the panel back without reopening Settings or arming a second poll timer.
    const again = g.begin(false);
    try t.expect(!again.open_settings);
    try t.expectEqual(@as(?u32, null), again.poll_ms);
    try t.expectEqual(permission.WindowOp{ .show = .{ .x = 530, .y = 210, .w = 380, .h = 110 } }, again.window);
}

test "an existing grant skips System Settings and rebuilds the index" {
    var g: permission.Grant = .{};
    const out = g.begin(true);
    try t.expectEqual(permission.Phase.granted, g.phase);
    try t.expectEqual(permission.Outcome{ .rebuild_index = true }, out);
    try t.expectEqual(permission.Outcome{}, g.begin(true));
}

test "polling follows System Settings past jitter, lingers on grant, then hides while staying granted" {
    var g: permission.Grant = .{ .anchors = .{ .settings = .{ .x = 400, .y = 300, .w = 640, .h = 480 }, .screen = screen } };
    _ = g.begin(false);

    g.anchors.settings.?.x += 3;
    try t.expectEqual(permission.WindowOp.keep, g.poll(false).window);

    g.anchors.settings.?.x += 10;
    const moved = g.poll(false);
    try t.expectEqual(permission.WindowOp{ .move = .{ .x = 543, .y = 210, .w = 380, .h = 110 } }, moved.window);

    const granted = g.poll(true);
    try t.expectEqual(permission.Phase.granted, g.phase);
    try t.expectEqual(permission.Outcome{
        .window = .redraw,
        .drag = .clear,
        .linger_ms = permission.granted_linger_ms,
        .rebuild_index = true,
    }, granted);
    try t.expectEqual(permission.Outcome{}, g.poll(true));

    try t.expectEqual(permission.Outcome{ .window = .hide, .drag = .clear }, g.lingerTimedOut());
    try t.expectEqual(permission.Phase.granted, g.phase);
}

test "the poll slows after a minute of guiding and resets when beginning again" {
    var g: permission.Grant = .{};
    _ = g.begin(false);
    try t.expectEqual(permission.poll_ms, g.pollDelayMs());
    for (0..permission.fast_polls - 1) |_| {
        try t.expectEqual(@as(?u32, permission.poll_ms), g.poll(false).poll_ms);
    }
    try t.expectEqual(@as(?u32, permission.slow_poll_ms), g.poll(false).poll_ms);
    _ = g.dismiss();
    _ = g.begin(false);
    try t.expectEqual(permission.poll_ms, g.pollDelayMs());
}

test "the guidance view offers the app card, then shows the grant" {
    var g: permission.Grant = .{ .phase = .guiding, .app_name = "Nanospot" };
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, g.view(), .{ .width = 380, .height = 110 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(tester.hasText("Drag Nanospot into the Full Disk Access list"));
    try t.expect(tester.hasText("Nanospot"));
    switch (g.applyPending().drag) {
        .place => |r| try t.expect(r[2] > 300 and r[3] >= 30),
        else => return error.NoCard,
    }
    g.phase = .granted;
    tester.settle(0.2);
    try t.expect(tester.hasText("Full Disk Access Granted"));
    try t.expect(g.card == null);
    try t.expectEqual(permission.DragOp.clear, g.applyPending().drag);
}

test "the access probe names a file that exists" {
    const failed = std.c.access(mac.full_disk_access_probe, 0) != 0;
    const missing = failed and @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*))) == .NOENT;
    try t.expect(!missing);
}

test "Finding 5: a poll tick before post-frame applyPending never clears a clicked close button" {
    var g: permission.Grant = .{};
    _ = g.begin(false);

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, g.view(), .{ .width = permission.panel_w, .height = permission.panel_h });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(g.applyPending().drag == .place);

    const x = permission.panel_w - chrome.space.edge - permission.metrics.close_hit_size / 2;
    const y = chrome.space.gap + permission.metrics.close_hit_size / 2;
    tester.click(@floatCast(x), @floatCast(y));

    const poll_out = g.poll(false);
    try t.expectEqual(permission.Phase.dismissed, g.phase);
    try t.expectEqual(permission.WindowOp.hide, poll_out.window);
    try t.expectEqual(permission.DragOp.clear, poll_out.drag);
    try t.expectEqual(@as(?u32, permission.slow_poll_ms), poll_out.poll_ms);
    try t.expectEqual(permission.Outcome{}, g.applyPending());
}

test "Finding 8: dismissing hides immediately, polls silently at 5s without reading anchors, and rebuilds once on grant" {
    const AnchorSpy = struct {
        reads: u32 = 0,
        fn read(ctx: ?*anyopaque) permission.Anchors {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.reads += 1;
            return .{ .screen = screen };
        }
    };
    var spy: AnchorSpy = .{};
    var g: permission.Grant = .{ .ctx = &spy, .read_anchors = AnchorSpy.read };
    const started = g.begin(false);
    try t.expectEqual(@as(?u32, permission.poll_ms), started.poll_ms);
    try t.expectEqual(@as(u32, 1), spy.reads);

    // Dismiss while initial 500ms timer is still in flight: hides & clears drag, no duplicate poll timer.
    const dis = g.dismiss();
    try t.expectEqual(permission.Phase.dismissed, g.phase);
    try t.expectEqual(permission.Outcome{ .window = .hide, .drag = .clear }, dis);

    // In-flight timer fires while dismissed: silently checks TCC and switches to slow_poll_ms without reading anchors.
    const silent = g.poll(false);
    try t.expectEqual(permission.Outcome{ .poll_ms = permission.slow_poll_ms }, silent);
    try t.expectEqual(@as(u32, 1), spy.reads);

    // Grant arrives while dismissed: rebuilds index once, no show/redraw/linger, and stops polling permanently.
    const granted = g.poll(true);
    try t.expectEqual(permission.Phase.granted, g.phase);
    try t.expectEqual(permission.Outcome{ .rebuild_index = true }, granted);
    try t.expectEqual(permission.Outcome{}, g.poll(true));
}
