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
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");
const bench = @import("bench.zig");
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

    try t.expectStringEndsWith(calc[0].subtitle, "/Apps");

    const tax = try cat.query(arena.allocator(), "return");
    try t.expect(tax.len >= 2);
    try t.expectEqualStrings("2025-return.pdf", tax[0].title);
    try t.expectEqualStrings("Documents/tax/2025-return.pdf", tax[0].subtitle);
    try t.expectEqual(@as(?u64, 0), tax[0].size);
    try t.expect(tax[0].modified != null);

    const web = tax[tax.len - 1];
    try t.expectEqual(search.Kind.web, web.kind);
    try t.expectEqualStrings("Google", web.title);
    try t.expectEqualStrings("google.com", web.subtitle);
    const spaced = try cat.query(arena.allocator(), "tax return");
    try t.expectEqualStrings("https://www.google.com/search?q=tax%20return", spaced[spaced.len - 1].path);

    try t.expectEqual(@as(usize, 0), (try cat.query(arena.allocator(), "  ")).len);
}

const FakeClock = struct {
    now: f64 = 0,
    fn read(ctx: ?*anyopaque) f64 {
        const c: *const FakeClock = @ptrCast(@alignCast(ctx));
        return c.now;
    }
    fn advance(c: *FakeClock, seconds: f64) void {
        c.now += seconds;
    }
    fn binding(c: *FakeClock) panel_mod.Clock {
        return .{ .ctx = c, .read = read };
    }
};

const NoHooks = struct {
    requests: u32 = 0,
    clock: FakeClock = .{},
    fn request(ctx: ?*anyopaque) void {
        const h: *NoHooks = @ptrCast(@alignCast(ctx));
        h.requests += 1;
    }
    fn icon(_: ?*anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
    fn date(_: ?*anyopaque, _: i64, _: std.mem.Allocator) []const u8 {
        return "Today at 9:41 AM";
    }
    fn detailed(_: ?*anyopaque, _: f64, _: std.mem.Allocator) []const u8 {
        return "Today at 9:41 AM";
    }
    fn hooks(h: *NoHooks) panel_mod.Hooks {
        return .{ .ctx = h, .clock = h.clock.binding(), .request = request, .app_icon = icon, .describe_date = date, .detailed_date = detailed };
    }
};

test "typing shows rows; Return opens the selected one; hiding keeps the session within the window and forgets it after" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expectEqual(panel_mod.metrics.search_height, p.panelHeight());
    try t.expect(tester.hasText("Floodlight"));
    try t.expect(tester.hasText(panel_mod.summon_label));

    tester.typeText("cal");
    tester.settle(0.2);
    try t.expect(p.visible.len >= 3);
    try t.expect(tester.hasText("Calculator"));
    try t.expect(tester.hasText("Calendar"));
    try t.expect(tester.hasText("Top Hit"));
    try t.expect(tester.hasText("Application"));
    try t.expect(tester.hasText("Google"));
    try t.expect(!tester.hasText(panel_mod.summon_label));
    try t.expectEqual(@as(f32, 521), p.panelHeight());
    try t.expect(hooks.requests > 0);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.up }));
    try t.expectEqual(@as(usize, 0), p.selected);
    // A window offers every key to the view first, as a shortcut.
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 1), p.selected);
    try t.expect(!tester.shortcut(.{ .key = ui.Shortcut.enter }));
    tester.key(.enter);
    tester.settle(0.1);
    const pending = p.pending orelse return error.NoAction;
    try t.expectEqualStrings(p.visible[1].path, pending.open);
    const chosen_path = try t.allocator.dupe(u8, p.visible[1].path);
    defer t.allocator.free(chosen_path);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(panel_mod.Filter.apps, p.filter);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqualStrings(chosen_path, p.visible[p.selected].path);

    p.hide();
    hooks.clock.advance(4 * 60);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("cal", p.field.text());
    try t.expectEqual(panel_mod.Filter.apps, p.filter);
    try t.expectEqualStrings(chosen_path, p.visible[p.selected].path);
    const focused = tester.ctx.focused_text orelse return error.NotFocused;
    try t.expectEqual(@as(usize, 0), focused.anchor);
    try t.expectEqual(@as(usize, 3), focused.caret);

    tester.key(.right);
    try t.expectEqualStrings("cal", p.field.text());
    try t.expectEqual(@as(usize, 3), tester.ctx.focused_text.?.anchor);
    try t.expectEqual(@as(usize, 3), tester.ctx.focused_text.?.caret);

    // Each hide starts a fresh 5-minute window.
    p.hide();
    hooks.clock.advance(4 * 60);
    p.showSearch();
    try t.expect(tester.shortcut(.{ .key = '1', .cmd = true }));
    tester.typeText("ret");
    tester.settle(0.1);
    try t.expectEqualStrings("ret", p.field.text());

    for (0..p.visible.len + 2) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(p.visible.len - 1, p.selected);

    p.hide();
    hooks.clock.advance(6 * 60);
    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.rows.len);
    try t.expectEqual(@as(usize, 0), p.visible.len);
    try t.expectEqual(panel_mod.Filter.all, p.filter);
    try t.expectEqual(@as(usize, 0), p.selected);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.metrics.search_height, p.panelHeight());
}

test "typed links normalize to URLs while prose and source files stay searches" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "github.com", "https://github.com" },
        .{ "github.com/fpcMotif/floodlight", "https://github.com/fpcMotif/floodlight" },
        .{ "https://x.y/z", "https://x.y/z" },
        .{ "localhost:3000", "http://localhost:3000" },
        .{ "127.0.0.1:8080/a", "http://127.0.0.1:8080/a" },
        .{ "www.example.org", "https://www.example.org" },
        .{ "see github.com.", null },
        .{ "github.com.", "https://github.com" },
        .{ "README.md", null },
        .{ "main.zig", null },
        .{ "google stock", null },
        .{ "build.rs", null },
        .{ "claude.ai", "https://claude.ai" },
        .{ "Claude.app", null },
        .{ "https://:8080", null },
        .{ "https://www./path", null },
    };
    for (cases) |c| {
        const got = try search.detectLink(a, c[0]);
        if (c[1]) |want| {
            try t.expectEqualStrings(want, got orelse return error.ExpectedLink);
        } else {
            try t.expect(got == null);
        }
    }
}

test "typing a link selects Open <host>, Return opens it, Cmd+C copies it, and an exact title match stays first" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("github.com");
    tester.settle(0.2);
    try t.expect(p.visible.len >= 2);
    try t.expectEqual(@as(usize, 0), p.selected);
    try t.expectEqualStrings("Open github.com", p.visible[0].title);
    try t.expectEqualStrings("https://github.com", p.visible[0].subtitle);
    try t.expectEqualStrings("Google", p.visible[p.visible.len - 1].title);

    tester.key(.enter);
    tester.settle(0.1);
    try t.expectEqualStrings("https://github.com", (p.pending orelse return error.NoAction).open);
    p.pending = null;

    try t.expect(tester.shortcut(.{ .key = 'c', .cmd = true }));
    try t.expectEqualStrings("https://github.com", (p.pending orelse return error.NoAction).copy.path);
    p.pending = null;

    try tmp.dir.writeFile(t.io, .{ .sub_path = "Documents/github.com", .data = "" });
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    cat.setFiles(try search.buildFileIndex(t.allocator, root, idx));
    p.answered.clearRetainingCapacity();
    p.refresh();
    try t.expect(p.visible.len >= 3);
    try t.expectEqual(search.Kind.file, p.visible[0].kind);
    try t.expectEqualStrings("github.com", p.visible[0].title);
    try t.expectEqualStrings("Open github.com", p.visible[1].title);
    try t.expectEqualStrings("https://github.com", p.visible[1].subtitle);
    try t.expectEqualStrings("Google", p.visible[p.visible.len - 1].title);
}

test "filter chips count, narrow the rows, and drop Top Hit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("return");
    tester.settle(0.2);
    for ([_][]const u8{ "All", "Apps", "Files", "Folders", "PDFs" }) |chip| try t.expect(tester.hasText(chip));
    try t.expect(!tester.hasText("Images"));
    try t.expectEqual(@as(usize, 1), p.count(.pdfs));

    try t.expect(tester.shortcut(.{ .key = '3', .cmd = true }));
    tester.settle(0.1);
    try t.expectEqual(panel_mod.Filter.files, p.filter);
    for (p.visible) |r| try t.expectEqual(search.Kind.file, r.kind);
    try t.expect(!p.isTopHit(0));

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 0), p.visible.len);
    try t.expect(tester.hasText("No apps results for \u{201C}return\u{201D}"));
}

test "Escape asks to hide" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 120 });
    defer tester.deinit();
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.escape }));
    try t.expect(p.pending != null and p.pending.? == .hide);
}

const CompletionFixture = struct {
    tmp: std.testing.TmpDir,
    buf: [std.posix.PATH_MAX]u8 = undefined,
    cat: search.Catalog = undefined,
    hooks: NoHooks = .{},
    p: panel_mod.Panel = undefined,
    tester: ui.Tester = undefined,

    fn init(f: *CompletionFixture, extra_apps: []const []const u8) !void {
        f.tmp = t.tmpDir(.{});
        errdefer f.tmp.cleanup();
        for (extra_apps) |app| try f.tmp.dir.createDirPath(t.io, app);
        f.cat = try tmpCatalog(&f.tmp, &f.buf);
        errdefer f.cat.deinit();
        f.hooks = .{};
        f.p = panel_mod.Panel.init(t.allocator, &f.cat, null, f.hooks.hooks());
        errdefer f.p.deinit();
        try f.tester.init(t.allocator, .init(&f.p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
        f.tester.settle(0.1);
    }

    fn deinit(f: *CompletionFixture) void {
        f.tester.deinit();
        f.p.deinit();
        f.cat.deinit();
        f.tmp.cleanup();
    }
};

test "top hit offers a case-preserving inline completion suffix without changing the rows" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{ "Apps/Antigravity.app/Contents", "Apps/Grant.app/Contents" });
    defer fx.deinit();

    fx.tester.typeText("ant");
    const comp = fx.p.completion orelse return error.NoCompletion;
    try t.expectEqualStrings("igravity", comp.suffix);
    try t.expectEqual(panel_mod.CompletionSource.top_hit, comp.source);
    try t.expect(fx.tester.hasText("igravity"));
    try t.expectEqualStrings("ant", fx.p.field.text());
    try t.expect(fx.tester.hasText("Grant"));

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ANT");
    try t.expectEqualStrings("igravity", fx.p.completion.?.suffix);
    try t.expectEqualStrings("ANT", fx.p.field.text());
}

test "Right arrow and Tab accept the full completion on the same frame while Return opens the selected row" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{ "Apps/Antigravity.app/Contents", "Apps/Grant.app/Contents" });
    defer fx.deinit();

    fx.tester.typeText("ant");
    try t.expect(fx.tester.hasText("Grant"));
    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.down }));
    fx.tester.key(.enter);
    try t.expectEqualStrings(fx.p.visible[1].path, fx.p.pending.?.open);
    try t.expectEqualStrings("ant", fx.p.field.text());
    fx.p.pending = null;

    fx.tester.key(.right);
    try t.expectEqualStrings("antigravity", fx.p.field.text());
    try t.expectEqualStrings("antigravity", fx.p.answered.items);
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("Grant"));

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ANT");
    try t.expect(fx.tester.hasText("Grant"));
    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.tab }));
    try t.expectEqualStrings("ANTigravity", fx.p.field.text());
    try t.expectEqualStrings("ANTigravity", fx.p.answered.items);
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("Grant"));
}

test "Option-Right accepts a multi-word completion one word at a time" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{"Apps/Visual Studio Code.app/Contents"});
    defer fx.deinit();

    fx.tester.typeText("vi");
    try t.expectEqualStrings("sual Studio Code", fx.p.completion.?.suffix);

    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("visual", fx.p.field.text());
    try t.expectEqualStrings("visual", fx.p.answered.items);
    try t.expectEqualStrings(" Studio Code", fx.p.completion.?.suffix);

    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("visual Studio", fx.p.field.text());
    try t.expectEqualStrings("visual Studio", fx.p.answered.items);
    try t.expectEqualStrings(" Code", fx.p.completion.?.suffix);

    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("visual Studio Code", fx.p.field.text());
    try t.expectEqualStrings("visual Studio Code", fx.p.answered.items);
    try t.expect(fx.p.completion == null);
}

test "completion hides on Backspace, mid-text caret, IME composition, Link Row query, and exact match" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{ "Apps/Antigravity.app/Contents", "Apps/github.com Desktop.app/Contents", "Apps/localhost Helper.app/Contents" });
    defer fx.deinit();

    fx.tester.typeText("ant");
    try t.expect(fx.p.completion != null);

    fx.tester.key(.backspace);
    try t.expectEqualStrings("an", fx.p.field.text());
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("tigravity"));

    fx.tester.typeText("t");
    try t.expectEqualStrings("igravity", fx.p.completion.?.suffix);

    fx.tester.key(.left);
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("igravity"));

    fx.tester.key(.right);
    try t.expectEqualStrings("ant", fx.p.field.text());
    try t.expectEqualStrings("igravity", fx.p.completion.?.suffix);

    fx.p.reset();
    fx.tester.frame();
    fx.tester.textOps(&.{.{ .set_marked = .{ .text = "ant", .sel_start = 3, .sel_len = 0 } }});
    try t.expectEqualStrings("ant", fx.p.field.text());
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("igravity"));

    fx.tester.textOps(&.{.unmark});
    try t.expectEqualStrings("igravity", fx.p.completion.?.suffix);

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("github.com");
    try t.expect(fx.p.completion == null);

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("localhost:3000");
    try t.expect(fx.p.completion == null);

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("antigravity");
    try t.expect(fx.p.completion == null);
}

test "running a Selected-Result Action records its query across store restarts and beats the top hit" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    try ts.tmp.dir.createDirPath(t.io, "Apps/Antigravity.app/Contents");
    try ts.tmp.dir.createDirPath(t.io, "Apps/Anthropic Console.app/Contents");
    var cat = try tmpCatalog(&ts.tmp, &ts.buf);
    defer cat.deinit();

    {
        var store = try clipboard.Store.open(ts.db, null);
        defer store.close();
        var hooks: NoHooks = .{};
        hooks.clock.advance(100);
        var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
        defer p.deinit();
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
        defer tester.deinit();
        tester.settle(0.1);

        tester.typeText("github.com");
        tester.key(.enter);
        try t.expectEqualStrings("https://github.com", p.pending.?.open);
        p.pending = null;

        p.reset();
        tester.frame();
        tester.typeText("Anthropic Console");
        tester.key(.enter);
        p.pending = null;
    }

    var store = try clipboard.Store.open(ts.db, null);
    defer store.close();
    var hooks: NoHooks = .{};
    hooks.clock.advance(200);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("git");
    const link_comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.history, link_comp.source);
    try t.expectEqualStrings("hub.com", link_comp.suffix);

    p.reset();
    tester.frame();
    tester.typeText("ant");
    try t.expectEqualStrings("Antigravity", p.visible[0].title);
    const beat_comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.history, beat_comp.source);
    try t.expectEqualStrings("hropic Console", beat_comp.suffix);
}

test "Query History ranks by recency and frequency, evicts lowest-ranked entries at its bound, and falls back to the top hit when cleared" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{ "Apps/Antigravity.app/Contents", "Apps/Anthropic Console.app/Contents", "Apps/Anthem Studio.app/Contents" });
    defer fx.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    store.budget = .{ .queries = 3 };
    fx.p.store = &store;
    fx.p.board.store = &store;

    fx.hooks.clock.advance(100);
    fx.tester.typeText("anthropic console");
    fx.tester.key(.enter);
    fx.p.pending = null;

    fx.p.reset();
    fx.tester.frame();
    fx.hooks.clock.advance(100);
    fx.tester.typeText("anthem studio");
    fx.tester.key(.enter);
    fx.p.pending = null;

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ant");
    try t.expectEqualStrings("hem studio", fx.p.completion.?.suffix);
    try t.expectEqual(panel_mod.CompletionSource.history, fx.p.completion.?.source);

    fx.p.reset();
    fx.tester.frame();
    for (0..2) |_| {
        fx.tester.typeText("anthropic console");
        fx.tester.key(.enter);
        fx.p.pending = null;
        fx.p.reset();
        fx.tester.frame();
    }
    fx.hooks.clock.advance(60);
    fx.tester.typeText("anthem studio");
    fx.tester.key(.enter);
    fx.p.pending = null;

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ant");
    try t.expectEqualStrings("hropic console", fx.p.completion.?.suffix);

    fx.p.reset();
    fx.tester.frame();
    fx.hooks.clock.advance(10);
    fx.tester.typeText("calendar notes");
    fx.tester.key(.enter);
    fx.p.pending = null;
    try t.expectEqual(@as(usize, 3), store.queryCount());

    fx.p.reset();
    fx.tester.frame();
    fx.hooks.clock.advance(10);
    fx.tester.typeText("calculator pro");
    fx.tester.key(.enter);
    fx.p.pending = null;
    try t.expectEqual(@as(usize, 3), store.queryCount());

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("cal");
    try t.expectEqualStrings("culator pro", fx.p.completion.?.suffix);

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ant");
    try t.expectEqualStrings("hropic console", fx.p.completion.?.suffix);
    try t.expectEqual(panel_mod.CompletionSource.history, fx.p.completion.?.source);

    try t.expect(fx.tester.shortcut(.{ .key = 0x7f, .cmd = true, .shift = true }));
    try t.expectEqual(@as(usize, 0), store.queryCount());
    try t.expectEqualStrings("igravity", fx.p.completion.?.suffix);
    try t.expectEqual(panel_mod.CompletionSource.top_hit, fx.p.completion.?.source);
}

test "the board field completes from past board queries and skips queries matching a sensitive entry" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .text = "quarterly invoice summary" }, "com.apple.Notes", "Notes", 100);
    _ = try store.add(.{ .text = "vault-recovery-phrase-99" }, "com.1password.1password", "1Password", 200);

    var hooks: NoHooks = .{};
    hooks.clock.advance(300);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(0.2);

    tester.typeText("quarterly invoice");
    tester.key(.enter);
    try t.expectEqualStrings("quarterly invoice summary", p.pending.?.clipboard.paste.text);
    p.pending = null;

    p.showClipboard();
    tester.frame();
    tester.typeText("quar");
    const comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.history, comp.source);
    try t.expectEqualStrings("terly invoice", comp.suffix);
    try t.expect(tester.hasText("terly invoice"));

    tester.key(.right);
    try t.expectEqualStrings("quarterly invoice", p.field.text());
    try t.expectEqualStrings("quarterly invoice", p.board.answered.items);

    p.showClipboard();
    tester.frame();
    tester.typeText("vault-recovery");
    tester.key(.enter);
    try t.expectEqualStrings("vault-recovery-phrase-99", p.pending.?.clipboard.paste.text);
    p.pending = null;

    p.showClipboard();
    tester.frame();
    tester.typeText("vault");
    try t.expect(p.completion == null);
}

test "the access probe names a file that exists" {
    const failed = std.c.access(mac.full_disk_access_probe, 0) != 0;
    const missing = failed and @as(std.c.E, @fromBackingInt(@intCast(std.c._errno().*))) == .NOENT;
    try t.expect(!missing);
}

// The clipboard board. Expected values are the Swift suite's
// (ClipboardTextContentTests, ClipboardHistoryStoreTests, SearchResultProjection).

test "copied text is classified as the Swift store classifies it" {
    try t.expectEqual(clipboard.Content.link, clipboard.classify("https://www.example.com/a?b"));
    try t.expectEqualStrings("example.com", clipboard.domain("https://www.example.com/a?b").?);
    try t.expectEqual(clipboard.Content.color, clipboard.classify(" #fff "));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("rgb(255, 255, 255)", clipboard.rgbDescription(arena.allocator(), clipboard.parseColor("#fff").?));
    try t.expectEqualStrings("rgba(17, 34, 51, 0.50)", clipboard.rgbDescription(arena.allocator(), clipboard.parseColor("#11223380").?));
    try t.expectEqual(clipboard.Content.code, clipboard.classify("{\"a\": 1}"));
    try t.expectEqualStrings("JSON", clipboard.codeLanguage("{\"a\": 1}").?);
    try t.expectEqualStrings("Code", clipboard.codeLanguage("const x = 1;").?);
    try t.expectEqualStrings("HTML", clipboard.codeLanguage("<p>hi</p>").?);
    try t.expectEqual(clipboard.Content.path, clipboard.classify("/Users/me/a.txt"));
    try t.expectEqual(clipboard.Content.plain, clipboard.classify("a\n/b"));
    try t.expectEqual(clipboard.Content.plain, clipboard.classify("{not json}"));
    try t.expectEqual(clipboard.Content.plain, clipboard.classify("#12345"));
}

test "rows name an entry's age, source and place" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ages = [_]struct { f64, []const u8 }{ .{ 30, "just now" }, .{ 120, "2m" }, .{ 7200, "2h" }, .{ 3 * 86400, "3d" }, .{ 65 * 86400, "2mo" }, .{ 400 * 86400, "1y" } };
    for (ages) |x| try t.expectEqualStrings(x[1], clipboard.age(a, x[0]));

    const file: clipboard.Entry = .{ .id = 1, .kind = .file, .text = "/Users/me/Docs/a.txt", .created_at = 1000, .source_name = "Finder" };
    try t.expectEqualStrings("a.txt", file.title(a));
    try t.expectEqualStrings("Finder \u{00B7} 2m \u{00B7} Docs", file.subtitle(a, 1120));
    const img: clipboard.Entry = .{ .id = 2, .kind = .image, .text = "PNG Image", .created_at = 1000, .width = 3, .height = 4 };
    try t.expectEqualStrings("Clipboard \u{00B7} just now \u{00B7} 3\u{00D7}4", img.subtitle(a, 1001));
    const text: clipboard.Entry = .{ .id = 3, .kind = .text, .text = "a\n\nb\u{2028}c ", .created_at = 0 };
    try t.expectEqualStrings("a b c", text.title(a));
    const blank: clipboard.Entry = .{ .id = 4, .kind = .text, .text = "\n\n", .created_at = 0 };
    try t.expectEqualStrings("(Empty text)", blank.title(a));
}

const long_text: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var bytes: [5 * 10_000]u8 = undefined;
    for (0..10_000) |i| @memcpy(bytes[i * 5 ..][0..5], "word ");
    const out = bytes;
    break :blk &out;
};

test "a long text's row title stops at what one row can show" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const e: clipboard.Entry = .{ .id = 1, .kind = .text, .text = "\n\n" ++ long_text, .created_at = 0 };
    const title = e.title(arena.allocator());
    try t.expect(std.mem.startsWith(u8, title, "word word"));
    try t.expect(title.len < 1024);
}

test "the inspector lays out only the head of a long text, cut between characters" {
    const head = board_mod.shownHead(long_text, 40);
    try t.expect(std.mem.startsWith(u8, long_text, head));
    try t.expect(head.len >= 40 * 80 and head.len < long_text.len / 4);
    const wide = "\u{4E2D}";
    var cjk: [3 * 4000]u8 = undefined;
    for (0..4000) |i| @memcpy(cjk[i * 3 ..][0..3], wide);
    try t.expect(std.unicode.utf8ValidateSlice(board_mod.shownHead(&cjk, 1)));
    try t.expectEqualStrings("short", board_mod.shownHead("short", 1));
}

test "the store skips a repeat of the newest entry only, pins, finds and prunes" {
    const store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try store.add(.{ .text = "alpha" }, "", "Notes", 100));
    try t.expect(try store.add(.{ .text = "beta" }, "", "Notes", 200));
    try t.expect(!try store.add(.{ .text = "beta" }, "", "Notes", 250));
    try t.expect(try store.add(.{ .text = "alpha" }, "", "Notes", 300));
    try t.expect(try store.add(.{ .file = "/tmp/x.pdf" }, "com.apple.finder", "Finder", 400));
    var rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqualStrings("/tmp/x.pdf", rows[0].text);
    try t.expectEqual(clipboard.Kind.file, rows[0].kind);

    // The oldest "alpha" pinned: first, ahead of newer entries.
    try store.togglePin(rows[3].id, 500);
    rows = try store.list(a, "");
    try t.expectEqual(@as(f64, 100), rows[0].created_at);
    try t.expectEqual(@as(?f64, 500), rows[0].pinned_at);

    rows = try store.list(a, "ALP");
    try t.expectEqual(@as(usize, 2), rows.len);

    try store.prune(250 + 30 * 86400, 30);
    rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 3), rows.len);
    try store.delete(rows[1].id);
    try t.expectEqual(@as(usize, 2), (try store.list(a, "")).len);
}

const day = 86400;

fn imageFileName(buf: []u8, png: []const u8, ext: []const u8) []const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png, &hash, .{});
    return std.fmt.bufPrint(buf, "images/{s}.{s}", .{ &std.fmt.bytesToHex(hash, .lower), ext }) catch unreachable;
}

fn hasFile(tmp: *std.testing.TmpDir, sub: []const u8) bool {
    tmp.dir.access(t.io, sub, .{}) catch return false;
    return true;
}

fn picture(png: []const u8) clipboard.Capture {
    return .{ .image = .{ .name = "PNG Image", .png = png, .thumbnail = "thumb", .width = 10, .height = 10 } };
}

const TmpStore = struct {
    tmp: std.testing.TmpDir,
    buf: [std.posix.PATH_MAX]u8 = undefined,
    images: []const u8 = "",
    db: [:0]const u8 = "",

    fn init(s: *TmpStore) !void {
        s.tmp = std.testing.tmpDir(.{});
        const root = s.buf[0..try s.tmp.dir.realPath(t.io, &s.buf)];
        s.images = try std.fs.path.join(t.allocator, &.{ root, "images" });
        s.db = try std.fs.path.joinZ(t.allocator, &.{ root, "clipboard.sqlite3" });
    }

    fn deinit(s: *TmpStore) void {
        t.allocator.free(s.images);
        t.allocator.free(s.db);
        s.tmp.cleanup();
    }

    fn size(s: *TmpStore, sub: []const u8) u64 {
        return (s.tmp.dir.statFile(t.io, sub, .{}) catch return 0).size;
    }
};

test "full images live beside the database, one file per picture, gone with their last entry" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var name: [128]u8 = undefined;
    const png = "\x89PNG picture one";
    const file = imageFileName(&name, png, "png");

    try t.expect(try store.add(picture(png), "", "Preview", 100));
    try t.expect(try store.add(.{ .text = "between" }, "", "Notes", 200));
    try t.expect(try store.add(picture(png), "", "Preview", 300));
    try t.expect(hasFile(&ts.tmp, file));
    const rows = try store.list(a, "");
    try t.expectEqualStrings(png, store.image(a, rows[0].id).?);
    try t.expectEqualStrings(png, store.image(a, rows[2].id).?);

    try store.delete(rows[0].id);
    try t.expect(hasFile(&ts.tmp, file));
    try store.delete(rows[2].id);
    try t.expect(!hasFile(&ts.tmp, file));
}

test "history keeps within its byte budget, dropping the oldest unpinned pictures first" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    store.budget = .{ .bytes = 3100, .entries = 100 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pngs: [4][1000]u8 = undefined;
    for (&pngs, 0..) |*p, i| @memset(p, @intCast('a' + i));

    _ = try store.add(.{ .text = "oldest text" }, "", "Notes", 10);
    _ = try store.add(picture(&pngs[0]), "", "Preview", 20);
    try store.togglePin((try store.list(a, ""))[0].id, 25);
    _ = try store.add(picture(&pngs[1]), "", "Preview", 30);
    _ = try store.add(picture(&pngs[2]), "", "Preview", 40);
    _ = try store.add(picture(&pngs[3]), "", "Preview", 50);

    const rows = try store.list(a, "");
    var kept: [8]f64 = undefined;
    for (rows, 0..) |e, i| kept[i] = e.created_at;
    try t.expectEqualSlices(f64, &.{ 20, 50, 40, 10 }, kept[0..rows.len]);
    var name: [128]u8 = undefined;
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, &pngs[1], "png")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, &pngs[0], "png")));
}

test "history keeps at most its entry count, pinned ones aside" {
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    store.budget = .{ .entries = 3 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try store.add(.{ .text = "pinned" }, "", "Notes", 1);
    try store.togglePin((try store.list(a, ""))[0].id, 2);
    for (0..5) |i| _ = try store.add(.{ .text = (try std.fmt.allocPrint(a, "t{d}", .{i})) }, "", "Notes", @floatFromInt(10 + i));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqualStrings("pinned", rows[0].text);
    try t.expectEqualStrings("t4", rows[1].text);
    try t.expectEqualStrings("t2", rows[3].text);
}

test "an older store's pictures move out to files and the database gives the space back" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    const big = try t.allocator.alloc(u8, 2 << 20);
    defer t.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    {
        var old = try clipboard.Store.open(ts.db, null);
        defer old.close();
        _ = try old.add(picture(big), "", "Preview", 100);
    }
    const before = ts.size("clipboard.sqlite3") + ts.size("clipboard.sqlite3-wal");
    try t.expect(before > big.len);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    const rows = try store.list(arena.allocator(), "");
    try t.expectEqualSlices(u8, big, store.image(arena.allocator(), rows[0].id).?);
    var name: [128]u8 = undefined;
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, big, "png")));
    try t.expect(ts.size("clipboard.sqlite3") + ts.size("clipboard.sqlite3-wal") < big.len / 4);
}

fn halve(arena: std.mem.Allocator, png: []const u8) ?[]const u8 {
    return arena.dupe(u8, png[0 .. png.len / 2]) catch null;
}

fn keepAll(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
    return null;
}

test "a week-old picture is stored once as its smaller copy, and the original goes" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG an old screenshot";
    const kept = "\x89PNG see-through";
    _ = try store.add(picture(png), "", "Preview", 0);
    _ = try store.add(picture(kept), "", "Preview", 1);
    var name: [128]u8 = undefined;

    try t.expect(!store.compactOne(a, 6 * day, halve));
    try t.expect(store.compactOne(a, 8 * day, keepAll));
    try t.expect(store.compactOne(a, 8 * day, halve));
    try t.expect(!store.compactOne(a, 8 * day, halve));

    const rows = try store.list(a, "");
    try t.expectEqualStrings(kept, store.image(a, rows[0].id).?);
    try t.expectEqualStrings(png[0 .. png.len / 2], store.image(a, rows[1].id).?);
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "png")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, png, "avif")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, kept, "png")));
}

test "files a crash left behind are cleared when the store opens" {
    var ts: TmpStore = .{ .tmp = undefined };
    try ts.init();
    defer ts.deinit();
    var name: [128]u8 = undefined;
    const png = "\x89PNG kept";
    {
        var store = try clipboard.Store.open(ts.db, ts.images);
        defer store.close();
        _ = try store.add(picture(png), "", "Preview", 100);
    }
    const stray = imageFileName(&name, "never stored", "png");
    try ts.tmp.dir.writeFile(t.io, .{ .sub_path = stray, .data = "x" });
    try ts.tmp.dir.writeFile(t.io, .{ .sub_path = "images/half-written.tmp", .data = "x" });

    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    try t.expect(!hasFile(&ts.tmp, stray));
    try t.expect(!hasFile(&ts.tmp, "images/half-written.tmp"));
    var name2: [128]u8 = undefined;
    try t.expect(hasFile(&ts.tmp, imageFileName(&name2, png, "png")));
}

test "copies an app marks as auto-generated stay out of history" {
    var found = false;
    for (mac.skipped_types) |ty| found = found or std.mem.eql(u8, ty, "org.nspasteboard.AutoGeneratedType");
    try t.expect(found);
}

fn crc(kind: []const u8, data: []const u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(kind);
    h.update(data);
    return h.final();
}

fn uncompressedGradientPng(a: std.mem.Allocator, side: u32, see_through: bool) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..side) |y| {
        try raw.append(a, 0);
        for (0..side) |x| try raw.appendSlice(a, &.{ @truncate(x * 255 / side), @truncate(y * 255 / side), @truncate((x + y) * 127 / side), if (see_through and x == 0 and y == 0) 0 else 255 });
    }
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(a, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        const last = n == rest.len;
        try z.append(a, @intFromBool(last));
        try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], side, .big);
    std.mem.writeInt(u32, ihdr[4..8], side, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |chunk| {
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(chunk[1].len))));
        try out.appendSlice(a, chunk[0]);
        try out.appendSlice(a, chunk[1]);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, crc(chunk[0], chunk[1]))));
    }
    return out.items;
}

test "an opaque picture compacts to a far smaller AVIF that pastes back as PNG; a see-through one is kept" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opaque_png = try uncompressedGradientPng(a, 256, false);
    const small = mac.compactImage(a, opaque_png).?;
    try t.expectEqualStrings("ftypavif", small[4..12]);
    try t.expect(small.len * 5 < opaque_png.len);
    const back = mac.pngBytes(a, small).?;
    try t.expect(std.mem.startsWith(u8, back, "\x89PNG"));
    try t.expect(mac.pngBytes(a, opaque_png).?.ptr == opaque_png.ptr);

    try t.expect(mac.compactImage(a, try uncompressedGradientPng(a, 256, true)) == null);
}

test "the board lists history, inspects the selection, and filters" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/floodlight-nano-test.pdf" }, "com.apple.finder", "Finder", 500);
    _ = try store.add(.{ .text = "hello there world" }, "com.apple.Notes", "Notes", 1000);
    _ = try store.add(.{ .text = "https://www.example.com/page" }, "com.apple.Safari", "Safari", 2000);
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    hooks.clock.advance(2060);
    try t.expectEqual(board_mod.board_metrics.width, p.panelWidth());
    try t.expectEqual(@as(f32, 840), p.panelWidth());
    try t.expectEqual(@as(f32, 560), p.panelHeight());

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
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
    try t.expect(tester.hasText("Words"));
    try t.expect(tester.hasText("3"));

    _ = tester.shortcut(.{ .key = '2', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("2 entries"));
    _ = tester.shortcut(.{ .key = '4', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("No images clipboard entries"));
    _ = tester.shortcut(.{ .key = '1', .cmd = true });
    tester.settle(1);

    tester.key(.enter);
    try t.expect(p.pending != null);
    try t.expectEqualStrings("https://www.example.com/page", p.pending.?.clipboard.paste.text);
    p.pending = null;

    try t.expect(tester.shortcut(.{ .key = 'o', .cmd = true }));
    try t.expectEqualStrings("https://www.example.com/page", p.pending.?.clipboard.open);
    try t.expect(p.pending.?.clipboard.hides());
    p.pending = null;

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expect(!tester.shortcut(.{ .key = 'o', .cmd = true }) or p.pending == null);
    _ = tester.shortcut(.{ .key = ui.Shortcut.up });
    tester.settle(1);

    _ = tester.shortcut(.{ .key = 'd', .cmd = true });
    tester.settle(1);
    try t.expect(tester.hasText("2 entries"));

    tester.typeText("zzz");
    tester.settle(1);
    try t.expect(tester.hasText("No matching clipboard all for \u{201C}zzz\u{201D}"));
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

test "a push past the board's ends stretches half a row at most, then rests" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var buf: [32]u8 = undefined;
    for (0..30) |i| _ = try store.add(.{ .text = try std.fmt.bufPrint(&buf, "entry number {d}", .{i}) }, "x", "Notes", @floatFromInt(1000 + i));
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
    const bound = panel_mod.metrics.max_overscroll + 0.5;

    // The list's top: the newest entry may not leave its resting place by more.
    const top_rest = tester.findText("entry number 29").?.y;
    holdPastEnd(&tester, 150, 300, 40, 80);
    try t.expect(tester.findText("entry number 29").?.y - top_rest <= bound);
    release(&tester);
    try t.expectApproxEqAbs(top_rest, tester.findText("entry number 29").?.y, 0.5);

    // The list's bottom, reached and pushed on.
    holdPastEnd(&tester, 150, 300, -40, 40);
    release(&tester);
    const bottom_rest = tester.findText("entry number 0").?.y;
    holdPastEnd(&tester, 150, 300, -40, 80);
    try t.expect(bottom_rest - tester.findText("entry number 0").?.y <= bound);
    release(&tester);
    try t.expectApproxEqAbs(bottom_rest, tester.findText("entry number 0").?.y, 0.5);

    // The inspector, which fits and so has nothing to scroll.
    const info_rest = tester.findText("Information").?.y;
    holdPastEnd(&tester, 600, 300, -40, 80);
    try t.expect(info_rest - tester.findText("Information").?.y <= bound);
    release(&tester);
    try t.expectApproxEqAbs(info_rest, tester.findText("Information").?.y, 0.5);
}

test "a long history builds the rows in view only, and still reaches its end" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var buf: [32]u8 = undefined;
    for (0..1000) |i| _ = try store.add(.{ .text = try std.fmt.bufPrint(&buf, "entry number {d}", .{i}) }, "x", "Notes", @floatFromInt(1000 + i));
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
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

test "a reopened panel stays unseen until a frame of its own is presented, then shows once" {
    var e: mac.Entrance = .{};
    try t.expect(!e.reveal(true));
    e.orderedIn();
    // A frame built without a drawable is not on screen: the old one still is.
    try t.expect(!e.reveal(false));
    try t.expect(e.reveal(true));
    try t.expect(!e.reveal(true));
    e.orderedIn();
    e.cancel();
    try t.expect(!e.reveal(true));
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

    try t.expect(bench.withinBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 5_000, .runs = 16 },
        .{ .p50_ns = 10_000, .p99_ns = 40_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 5_000, .runs = 16 },
    ));
    try t.expect(!bench.withinBudgets(
        .{ .p50_ns = 1_000, .p99_ns = 500_000, .runs = 16 },
        .{ .p50_ns = 10_000, .p99_ns = 40_000, .runs = 16 },
        .{ .p50_ns = 1_000, .p99_ns = 5_000, .runs = 16 },
    ));
}

test "a board frame that waits for a later one keeps the display link at the display's pace" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var buf: [32]u8 = undefined;
    for (0..30) |i| _ = try store.add(.{ .text = try std.fmt.bufPrint(&buf, "entry number {d}", .{i}) }, "x", "Notes", @floatFromInt(1000 + i));
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
    tester.scroll(150, 300, -120);
    tester.frame();
    const one_refresh: f32 = 1.0 / 60.0;
    // The scroll bar's fade wakes the board later: nanoui would slow the link to it.
    try t.expect(tester.ctx.frame_in.? > one_refresh);
    mac.keepLinkAtDisplayRate(&tester.ctx);
    if (tester.ctx.frame_in) |fi| try t.expect(fi <= one_refresh);
}

fn addPicture(store: *clipboard.Store, png: []const u8, at: f64) !void {
    _ = try store.add(.{ .image = .{ .name = "", .png = png, .thumbnail = "", .width = 3840, .height = 2160 } }, "com.apple.Preview", "Preview", at);
}

test "a held arrow passes over full pictures, and the one it rests on is loaded" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var png: [6][4]u8 = undefined;
    for (&png, 0..) |*b, i| {
        b.* = .{ 'p', 'n', 'g', @intCast(i) };
        try addPicture(&store, b, @floatFromInt(100 - i));
    }
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
    try t.expectEqualSlices(u8, &png[0], p.board.full_image.?);

    tester.advance(1);
    for (1..5) |_| {
        _ = tester.shortcut(.{ .key = ui.Shortcut.down });
        tester.advance(0.05);
    }
    try t.expect(p.board.full_image == null);
    tester.advance(0.5);
    try t.expectEqualSlices(u8, &png[4], p.board.full_image.?);

    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.frame();
    try t.expectEqualSlices(u8, &png[5], p.board.full_image.?);
}

test "a large picture's memory goes once the inspector moves on" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .text = "after the picture" }, "com.apple.Notes", "Notes", 50);
    const big = try t.allocator.alloc(u8, 4 << 20);
    defer t.allocator.free(big);
    @memset(big, 7);
    try addPicture(&store, big, 100);
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
    try t.expectEqual(big.len, p.board.full_image.?.len);

    tester.advance(1);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.settle(1);
    try t.expect(tester.hasText("after the picture"));
    try t.expect(p.board.detail_arena.queryCapacity() < big.len);
}

test "an empty history says so" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(1);
    try t.expect(tester.hasText("Clipboard history is empty. Copied text, files, and images will appear here."));
}

test "the injected clock advances board ages and pins, and forget clears both surfaces" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .text = "first snippet" }, "com.apple.Notes", "Notes", 1000);
    _ = try store.add(.{ .text = "second snippet" }, "com.apple.Safari", "Safari", 1000);
    var hooks: NoHooks = .{};
    hooks.clock.advance(1120);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(0.2);

    tester.typeText("cal");
    tester.settle(0.2);
    p.selectFilter(.apps);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(panel_mod.Filter.apps, p.filter);
    try t.expectEqual(@as(usize, 1), p.selected);

    p.showClipboard();
    tester.settle(0.2);
    try t.expect(tester.hasText("Safari \u{00B7} 2m"));
    hooks.clock.advance(180);
    try t.expectEqual(@as(f64, 1300), p.clock.now());
    tester.settle(0.2);
    try t.expect(tester.hasText("Safari \u{00B7} 5m"));

    _ = tester.shortcut(.{ .key = '.', .cmd = true });
    p.refresh();
    try t.expectEqual(@as(?f64, 1300), p.board.rows[0].pinned_at);

    p.board.selectFilter(.text);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.typeText("first");
    tester.settle(0.2);
    try t.expectEqual(clipboard.Filter.text, p.board.filter);
    try t.expectEqualStrings("first", p.field.text());

    p.forget();
    try t.expectEqual(panel_mod.Mode.search, p.mode);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(@as(usize, 0), p.rows.len);
    try t.expectEqual(@as(usize, 0), p.visible.len);
    try t.expectEqual(panel_mod.Filter.all, p.filter);
    try t.expectEqual(@as(usize, 0), p.selected);
    try t.expectEqual(panel_mod.metrics.search_height, p.panelHeight());
    try t.expectEqual(panel_mod.metrics.width, p.panelWidth());
    try t.expectEqual(@as(usize, 0), p.board.rows.len);
    try t.expectEqual(@as(usize, 0), p.board.visible.len);
    try t.expectEqual(clipboard.Filter.all, p.board.filter);
    try t.expectEqual(@as(usize, 0), p.board.selected);
    try t.expect(p.board.stale);
    try t.expect(p.board.detail_id == null);
}

test "search retention selects the top row when the remembered path is gone, and clearing the field forgets at once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.selected);
    const removed = cat.apps.orderedRemove(1);
    t.allocator.free(removed.path);

    p.hide();
    hooks.clock.advance(60);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("cal", p.field.text());
    try t.expectEqual(@as(usize, 0), p.selected);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(panel_mod.Filter.apps, p.filter);
    p.clearField();
    p.hide();
    hooks.clock.advance(10);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.Filter.all, p.filter);
    try t.expectEqual(@as(usize, 0), p.visible.len);
}

test "board retention restores query, kind filter, and selection or selects the newest matching copy" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/report.pdf" }, "com.apple.finder", "Finder", 100);
    _ = try store.add(.{ .text = "hello older note" }, "com.apple.Notes", "Notes", 200);
    _ = try store.add(.{ .text = "hello newer note" }, "com.apple.Notes", "Notes", 300);

    var hooks: NoHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
    defer tester.deinit();
    tester.settle(0.2);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(clipboard.Filter.text, p.board.filter);
    tester.typeText("hello");
    tester.settle(0.2);
    try t.expectEqual(@as(usize, 2), p.board.visible.len);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.board.selected);
    const remembered_id = p.board.selection().?.id;

    p.hide();
    // An unrelated copy while hidden does not match the query+filter, so the remembered selection stays.
    _ = try store.add(.{ .file = "/tmp/hello-other.pdf" }, "com.apple.finder", "Finder", 1050);
    _ = try store.add(.{ .text = "unrelated text" }, "com.apple.Notes", "Notes", 1060);
    hooks.clock.advance(4 * 60);
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("hello", p.field.text());
    try t.expectEqual(clipboard.Filter.text, p.board.filter);
    try t.expectEqual(remembered_id, p.board.selection().?.id);
    try t.expectEqual(@as(usize, 0), tester.ctx.focused_text.?.anchor);
    try t.expectEqual(@as(usize, 5), tester.ctx.focused_text.?.caret);

    p.hide();
    _ = try store.add(.{ .text = "hello brand new" }, "com.apple.Notes", "Notes", 1300);
    hooks.clock.advance(60);
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("hello", p.field.text());
    try t.expectEqual(clipboard.Filter.text, p.board.filter);
    try t.expectEqual(@as(usize, 0), p.board.selected);
    try t.expectEqualStrings("hello brand new", p.board.selection().?.text);

    p.clearField();
    p.hide();
    try t.expect(p.nextExpiryMs() == null);
    try t.expectEqual(@as(usize, 0), p.board.rows.len);
}

test "search and clipboard board sessions expire separately, and zero retention forgets on hide" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/report.pdf" }, "com.apple.finder", "Finder", 50);
    _ = try store.add(.{ .text = "alpha clip" }, "com.apple.Notes", "Notes", 60);

    var hooks: NoHooks = .{};
    hooks.clock.advance(100);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
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
    try t.expectEqual(clipboard.Filter.files, p.board.filter);
    p.hide();

    // Search is 6m old (expired) while the board is 3m old (still retained).
    hooks.clock.advance(3 * 60);
    try t.expect(!p.expire());
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.Filter.all, p.filter);

    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("report", p.field.text());
    try t.expectEqual(clipboard.Filter.files, p.board.filter);

    p.retention_seconds = 0;
    p.hide();
    p.showClipboard();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(clipboard.Filter.all, p.board.filter);

    p.showSearch();
    tester.frame();
    tester.typeText("cal");
    tester.settle(0.1);
    p.hide();
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(@as(usize, 0), p.rows.len);
}

const SuggestSpy = struct {
    hooks_base: NoHooks = .{},
    seqs: std.ArrayList(u64) = .empty,
    queries: std.ArrayList([]u8) = .empty,

    fn deinit(s: *SuggestSpy) void {
        for (s.queries.items) |q| t.allocator.free(q);
        s.queries.deinit(t.allocator);
        s.seqs.deinit(t.allocator);
    }

    fn suggest(ctx: ?*anyopaque, seq: u64, query: []const u8) void {
        const s: *SuggestSpy = @ptrCast(@alignCast(ctx));
        const copy = t.allocator.dupe(u8, query) catch return;
        s.queries.append(t.allocator, copy) catch {
            t.allocator.free(copy);
            return;
        };
        s.seqs.append(t.allocator, seq) catch {};
    }

    fn request(ctx: ?*anyopaque) void {
        const s: *SuggestSpy = @ptrCast(@alignCast(ctx));
        s.hooks_base.requests += 1;
    }

    fn hooks(s: *SuggestSpy) panel_mod.Hooks {
        return .{
            .ctx = s,
            .clock = s.hooks_base.clock.binding(),
            .request = request,
            .app_icon = NoHooks.icon,
            .describe_date = NoHooks.date,
            .detailed_date = NoHooks.detailed,
            .suggest = suggest,
        };
    }
};

test "the first frame after a keystroke does not wait for suggestions, and arrival adds up to four bold-tail rows under Google without moving selection" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("cal", spy.queries.items[0]);
    try t.expectEqual(@as(usize, 3), p.visible.len);
    try t.expectEqualStrings("Calendar", p.visible[0].title);
    try t.expectEqualStrings("Calculator", p.visible[1].title);
    try t.expectEqualStrings("Google", p.visible[2].title);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.selected);

    p.receiveSuggestions("cal", &.{
        "calculator online",
        "calendar 2026",
        "california dmv",
        "caltrain schedule",
        "calories in an apple",
    });
    tester.frame();

    try t.expectEqual(@as(usize, 1), p.selected);
    try t.expectEqual(@as(usize, 7), p.visible.len);
    try t.expectEqualStrings("Google", p.visible[2].title);
    try t.expectEqualStrings("calculator online", p.visible[3].title);
    try t.expectEqualStrings("calendar 2026", p.visible[4].title);
    try t.expectEqualStrings("california dmv", p.visible[5].title);
    try t.expectEqualStrings("caltrain schedule", p.visible[6].title);
    try t.expect(!tester.hasText("calories in an apple"));

    var found_node = false;
    for (tester.ctx.nodes.items) |n| {
        if (n.content == .text and std.mem.eql(u8, n.content.text.str, "calculator online")) {
            found_node = true;
            try t.expectEqual(ui.Weight.regular, n.content.text.style.weight);
            try t.expectEqual(@as(usize, 1), n.content.text.spans.len);
            try t.expectEqual(@as(u32, 3), n.content.text.spans[0].start);
            try t.expectEqual(@as(u32, "calculator online".len), n.content.text.spans[0].end);
            try t.expectEqual(@as(?ui.Weight, .bold), n.content.text.spans[0].weight);
        }
    }
    try t.expect(found_node);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 3), p.selected);
    tester.key(.enter);
    try t.expectEqualStrings("https://www.google.com/search?q=calculator%20online", (p.pending orelse return error.NoAction).open);
}

test "a late reply for an old query or superseded request is ignored, and an empty failure leaves no rows" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("wea");
    const first_seq = spy.seqs.items[0];
    try t.expect(first_seq > 0);

    tester.typeText("ther");
    const second_seq = spy.seqs.items[1];
    try t.expect(second_seq > first_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"weather radar"}));
    try t.expectEqual(@as(usize, 1), p.visible.len);
    try t.expectEqualStrings("Google", p.visible[0].title);

    for (0..4) |_| tester.key(.backspace);
    try t.expectEqualStrings("wea", p.field.text());
    const third_seq = spy.seqs.getLast();
    try t.expect(third_seq > second_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"stale weather"}));
    try t.expectEqual(@as(usize, 1), p.visible.len);

    try t.expect(p.receiveSuggestionsFor(third_seq, "wea", &.{}));
    try t.expectEqual(@as(usize, 1), p.visible.len);
    try t.expectEqualStrings("Google", p.visible[0].title);
}

test "with the setting off, or for a Link Row, a path-like query, or Clipboard mode, the suggestion source receives no request" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    p.setWebSuggestionsEnabled(false);
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 0), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 1), p.visible.len);

    p.setWebSuggestionsEnabled(true);
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[0]);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 2), p.visible.len);

    p.setWebSuggestionsEnabled(false);
    try t.expectEqual(@as(usize, 1), p.visible.len);
    p.setWebSuggestionsEnabled(true);

    const suppressed = [_][]const u8{
        "github.com",
        "https://example.org",
        "localhost:3000",
        "/Applications",
        "~/Documents",
        "./build.zig",
    };
    const count_before = spy.queries.items.len;
    for (suppressed) |q| {
        p.reset();
        tester.frame();
        tester.typeText(q);
        try t.expectEqual(count_before, spy.queries.items.len);
    }

    p.showClipboard();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(count_before, spy.queries.items.len);
}

test "a cached query reuses suggestions within five minutes without sending a second request, then refetches after expiry" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    spy.hooks_base.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{ "weather forecast", "weather radar" });
    try t.expectEqual(@as(usize, 3), p.visible.len);

    spy.hooks_base.clock.advance(299);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqual(@as(usize, 3), p.visible.len);
    try t.expectEqualStrings("weather forecast", p.visible[1].title);
    try t.expectEqualStrings("weather radar", p.visible[2].title);

    spy.hooks_base.clock.advance(2);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 2), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[1]);
    try t.expectEqual(@as(usize, 1), p.visible.len);
}

test "the first web suggestion becomes the completion only when neither query history nor top hit matches" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var cat = try tmpCatalog(&tmp, &buf);
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:", null);
    defer store.close();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    spy.hooks_base.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = panel_mod.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("WEA");
    try t.expect(p.completion == null);
    p.receiveSuggestions("WEA", &.{ "weather forecast", "wealthsimple" });
    tester.frame();
    const web_comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.web_suggestion, web_comp.source);
    try t.expectEqualStrings("ther forecast", web_comp.suffix);
    try t.expect(tester.hasText("ther forecast"));

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("WEAther", p.field.text());
    p.receiveSuggestions("WEAther", &.{ "forecast tomorrow", "weather radar" });
    tester.frame();
    try t.expect(p.completion == null);

    p.reset();
    tester.frame();
    tester.typeText("cal");
    try t.expectEqual(panel_mod.CompletionSource.top_hit, p.completion.?.source);
    try t.expectEqualStrings("endar", p.completion.?.suffix);
    p.receiveSuggestions("cal", &.{"calculator online"});
    tester.frame();
    try t.expectEqual(panel_mod.CompletionSource.top_hit, p.completion.?.source);
    try t.expectEqualStrings("endar", p.completion.?.suffix);

    try store.recordQuery(.search, "weather radar", 1000);
    p.reset();
    tester.frame();
    tester.typeText("wea");
    try t.expectEqual(panel_mod.CompletionSource.history, p.completion.?.source);
    try t.expectEqualStrings("ther radar", p.completion.?.suffix);
    p.receiveSuggestions("wea", &.{"weather forecast"});
    tester.frame();
    try t.expectEqual(panel_mod.CompletionSource.history, p.completion.?.source);
    try t.expectEqualStrings("ther radar", p.completion.?.suffix);
}

test "Google suggestion URL encoding and Firefox JSON response parsing cap at four items and ignore malformed payloads" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try search.webSuggestUrl(a, "zig std.mem");
    try t.expectEqualStrings("https://suggestqueries.google.com/complete/search?client=firefox&q=zig%20std.mem", url);

    const parsed = search.parseSuggestions(a, "[\"zig\",[\"ziglang\",\"zig download\",\"zig tutorial\",\"zig build\",\"zig fifth\"]]");
    try t.expectEqual(@as(usize, 4), parsed.len);
    try t.expectEqualStrings("ziglang", parsed[0]);
    try t.expectEqualStrings("zig download", parsed[1]);
    try t.expectEqualStrings("zig tutorial", parsed[2]);
    try t.expectEqualStrings("zig build", parsed[3]);

    try t.expectEqual(@as(usize, 0), search.parseSuggestions(a, "not json").len);
    try t.expectEqual(@as(usize, 0), search.parseSuggestions(a, "[\"only_one\"]").len);
    try t.expectEqual(@as(usize, 0), search.parseSuggestions(a, "{}").len);
}

test {
    _ = core;
}
