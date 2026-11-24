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

const Spy = struct {
    granted: bool = false,
    opened: u32 = 0,
    presented: u32 = 0,
    closed: u32 = 0,
    on_granted: u32 = 0,

    fn of(ctx: ?*anyopaque) *Spy {
        return @ptrCast(@alignCast(ctx));
    }
    fn isGranted(ctx: ?*anyopaque) bool {
        return of(ctx).granted;
    }
    fn open(ctx: ?*anyopaque) void {
        of(ctx).opened += 1;
    }
    fn present(ctx: ?*anyopaque) void {
        of(ctx).presented += 1;
    }
    fn close(ctx: ?*anyopaque) void {
        of(ctx).closed += 1;
    }
    fn onGranted(ctx: ?*anyopaque) void {
        of(ctx).on_granted += 1;
    }
    fn flow(s: *Spy) permission.Flow {
        return .{ .effects = .{ .ctx = s, .is_granted = isGranted, .open_settings = open, .present = present, .close = close, .on_granted = onGranted } };
    }
};

test "beginning the flow opens System Settings and guides" {
    var spy: Spy = .{};
    var f = spy.flow();
    try t.expectEqual(permission.Phase.idle, f.phase);
    f.begin();
    try t.expectEqual(permission.Phase.guiding, f.phase);
    try t.expectEqual(@as(u32, 1), spy.opened);
    try t.expectEqual(@as(u32, 1), spy.presented);
    // Asking again brings the panel back without reopening Settings.
    f.begin();
    try t.expectEqual(@as(u32, 1), spy.opened);
    try t.expectEqual(@as(u32, 2), spy.presented);
}

test "an existing grant skips System Settings" {
    var spy: Spy = .{ .granted = true };
    var f = spy.flow();
    f.begin();
    try t.expectEqual(permission.Phase.granted, f.phase);
    try t.expectEqual(@as(u32, 0), spy.opened);
    try t.expectEqual(@as(u32, 1), spy.on_granted);
}

test "polling keeps guiding until the grant, then stops" {
    var spy: Spy = .{};
    var f = spy.flow();
    f.begin();
    f.poll();
    try t.expectEqual(permission.Phase.guiding, f.phase);
    try t.expectEqual(@as(u32, 2), spy.presented);
    try t.expectEqual(@as(u32, 0), spy.on_granted);
    spy.granted = true;
    f.poll();
    try t.expectEqual(permission.Phase.granted, f.phase);
    try t.expectEqual(@as(u32, 1), spy.on_granted);
    f.poll();
    try t.expectEqual(@as(u32, 1), spy.on_granted);
    try t.expectEqual(@as(u32, 2), spy.presented);
}

test "dismissing closes the panel and stops polling" {
    var spy: Spy = .{};
    var f = spy.flow();
    f.begin();
    f.dismiss();
    try t.expectEqual(permission.Phase.dismissed, f.phase);
    try t.expectEqual(@as(u32, 1), spy.closed);
    f.poll();
    try t.expectEqual(@as(u32, 1), spy.presented);
}

test "the guidance view offers the app card, then shows the grant" {
    var phase: permission.Phase = .guiding;
    var g: permission.Guidance = .{ .phase = &phase, .app_name = "Nanospot" };
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&g, permission.Guidance.view), .{ .width = 380, .height = 110 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(tester.hasText("Drag Nanospot into the Full Disk Access list"));
    try t.expect(tester.hasText("Nanospot"));
    const card = g.card orelse return error.NoCard;
    try t.expect(card.w > 300 and card.h >= 30);
    phase = .granted;
    tester.settle(0.2);
    try t.expect(tester.hasText("Full Disk Access Granted"));
    try t.expect(g.card == null);
}

test "the access probe names a file that exists" {
    const failed = std.c.access(mac.full_disk_access_probe, 0) != 0;
    const missing = failed and @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*))) == .NOENT;
    try t.expect(!missing);
}

test "the poll slows after a minute of guiding" {
    var spy: Spy = .{};
    var f = spy.flow();
    f.begin();
    try t.expectEqual(permission.poll_ms, f.pollDelayMs());
    for (0..permission.fast_polls) |_| f.poll();
    try t.expectEqual(permission.slow_poll_ms, f.pollDelayMs());
}

test "beginning again polls fast again" {
    var spy: Spy = .{};
    var f = spy.flow();
    f.begin();
    for (0..permission.fast_polls) |_| f.poll();
    try t.expectEqual(permission.slow_poll_ms, f.pollDelayMs());
    f.dismiss();
    f.begin();
    try t.expectEqual(permission.poll_ms, f.pollDelayMs());
}
