//! The panel and the grant flow without a window: views render offscreen
//! through ui.Tester. Expected frames are the Swift suite's
//! (GuidancePanelAnchorPolicyTests, FullDiskAccessGrantTests).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("floodlight_core");
const search = @import("search.zig");
const panel_mod = @import("panel.zig");
const permission = @import("permission.zig");
const mac = @import("mac.zig");
const t = std.testing;

const screen: permission.Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };

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
    try t.expect(f.poll());
    try t.expectEqual(permission.Phase.guiding, f.phase);
    try t.expectEqual(@as(u32, 0), spy.on_granted);
    spy.granted = true;
    try t.expect(!f.poll());
    try t.expectEqual(permission.Phase.granted, f.phase);
    try t.expectEqual(@as(u32, 1), spy.on_granted);
    try t.expect(!f.poll());
    try t.expectEqual(@as(u32, 1), spy.on_granted);
}

test "dismissing closes the panel and stops polling" {
    var spy: Spy = .{};
    var f = spy.flow();
    f.begin();
    f.dismiss();
    try t.expectEqual(permission.Phase.dismissed, f.phase);
    try t.expectEqual(@as(u32, 1), spy.closed);
    try t.expect(!f.poll());
}

test "the guidance view offers the app card, then shows the grant" {
    var g: permission.Guidance = .{ .app_name = "Floodlight Nano" };
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&g, permission.Guidance.view), .{ .width = 380, .height = 110 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(tester.hasText("Drag Floodlight Nano into the Full Disk Access list"));
    try t.expect(tester.hasText("Floodlight Nano"));
    const card = g.card orelse return error.NoCard;
    try t.expect(card.w > 300 and card.h >= 30);
    g.phase = .granted;
    tester.settle(0.2);
    try t.expect(tester.hasText("Full Disk Access Granted"));
    try t.expect(g.card == null);
}

const tmp_home_files = [_][]const u8{ "Documents/tax/2025-return.pdf", "Documents/notes.txt", "Music/kind-of-blue.flac" };

fn tmpCatalog(tmp: *std.testing.TmpDir, buf: *[std.posix.PATH_MAX]u8) !search.Catalog {
    for (tmp_home_files) |p| {
        try tmp.dir.createDirPath(t.io, std.fs.path.dirname(p).?);
        try tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = "" });
    }
    try tmp.dir.createDirPath(t.io, "Apps/Calculator.app/Contents");
    try tmp.dir.createDirPath(t.io, "Apps/Calendar.app/Contents");
    const root = buf[0..try tmp.dir.realPath(t.io, buf)];
    var cat: search.Catalog = .{ .gpa = t.allocator, .home = root };
    const apps = try std.fs.path.join(t.allocator, &.{ root, "Apps" });
    defer t.allocator.free(apps);
    try search.scanApps(&cat, t.io, apps);
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    cat.setFiles(try search.buildFileIndex(t.allocator, root, idx));
    return cat;
}

test "a query finds apps and files, apps first" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    const calc = try cat.query(arena.allocator(), "calc");
    try t.expect(calc.len >= 1);
    try t.expectEqualStrings("Calculator", calc[0].title);
    try t.expectEqual(search.Kind.app, calc[0].kind);
    // Bundles come from the app catalog, not again as folders, nor their insides.
    for (calc) |r| {
        try t.expect(!std.mem.endsWith(u8, r.title, ".app"));
        if (r.kind != .app) try t.expect(std.mem.indexOf(u8, r.path, ".app/") == null);
    }

    const tax = try cat.query(arena.allocator(), "return");
    try t.expect(tax.len >= 1);
    try t.expectEqualStrings("2025-return.pdf", tax[0].title);
    try t.expectEqualStrings("~/Documents/tax", tax[0].subtitle);

    try t.expectEqual(@as(usize, 0), (try cat.query(arena.allocator(), "  ")).len);
}

const NoHooks = struct {
    requests: u32 = 0,
    fn request(ctx: ?*anyopaque) void {
        const h: *NoHooks = @ptrCast(@alignCast(ctx));
        h.requests += 1;
    }
    fn icon(_: ?*anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

test "typing shows rows; Return opens the selected one; hiding forgets the session" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, .{ .ctx = &hooks, .request = NoHooks.request, .app_icon = NoHooks.icon });
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 480 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expectEqual(panel_mod.metrics.search_height, p.fitHeight());

    tester.typeText("cal");
    tester.settle(0.2);
    try t.expect(p.rows.len >= 2);
    try t.expect(tester.hasText("Calculator"));
    try t.expect(tester.hasText("Calendar"));
    try t.expect(p.fitHeight() > panel_mod.metrics.search_height);
    try t.expect(hooks.requests > 0);

    // A window offers every key to the view first, as a shortcut.
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 1), p.selected);
    try t.expect(!tester.shortcut(.{ .key = ui.Shortcut.enter }));
    tester.key(.enter);
    tester.settle(0.1);
    const pending = p.pending orelse return error.NoAction;
    try t.expectEqualStrings(p.rows[1].path, pending.open);

    p.reset();
    try t.expectEqual(@as(usize, 0), p.rows.len);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.metrics.search_height, p.fitHeight());
}

test "Escape asks to hide" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, .{ .ctx = &hooks, .request = NoHooks.request, .app_icon = NoHooks.icon });
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 120 });
    defer tester.deinit();
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.escape }));
    try t.expect(p.pending != null and p.pending.? == .hide);
}

test "without access the panel offers the grant" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, .{ .ctx = &hooks, .request = NoHooks.request, .app_icon = NoHooks.icon });
    defer p.deinit();
    p.needs_access = true;
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 120 });
    defer tester.deinit();
    tester.settle(0.1);
    try tester.clickText("Grant…");
    tester.settle(0.1);
    try t.expect(p.pending != null and p.pending.? == .grant_access);
}

test "the access probe names a file that exists" {
    const failed = std.c.access(mac.full_disk_access_probe, 0) != 0;
    const missing = failed and @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*))) == .NOENT;
    try t.expect(!missing);
}

test {
    _ = core;
}
