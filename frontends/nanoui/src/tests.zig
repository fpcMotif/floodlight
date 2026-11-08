//! Floodlight on nanoui without a window: the grant flow, the search panel
//! and the list behind it, the clipboard store and board, AVIF compaction,
//! and when the panel shows and hides. Views render offscreen through
//! ui.Tester. Expected values are the Swift suites', named where each part
//! begins; the grant flow's are GuidancePanelAnchorPolicyTests and
//! FullDiskAccessGrantTests.
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
const presence = @import("presence.zig");
const list_mod = @import("list.zig");
const chrome = @import("chrome.zig");
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
    var g: permission.Guidance = .{ .phase = &phase, .app_name = "Floodlight Nano" };
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&g, permission.Guidance.view), .{ .width = 380, .height = 110 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expect(tester.hasText("Drag Floodlight Nano into the Full Disk Access list"));
    try t.expect(tester.hasText("Floodlight Nano"));
    const card = g.card orelse return error.NoCard;
    try t.expect(card.w > 300 and card.h >= 30);
    phase = .granted;
    tester.settle(0.2);
    try t.expect(tester.hasText("Full Disk Access Granted"));
    try t.expect(g.card == null);
}

const tmp_home_files = [_][]const u8{ "Documents/tax/2025-return.pdf", "Documents/notes.txt", "Music/kind-of-blue.flac" };

fn tmpCatalog(tmp: *std.testing.TmpDir, buf: *[std.posix.PATH_MAX]u8, files: *core.file_index.FileIndex) !search.Catalog {
    for (tmp_home_files) |p| {
        try tmp.dir.createDirPath(t.io, std.fs.path.dirname(p).?);
        try tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = "" });
    }
    try tmp.dir.createDirPath(t.io, "Apps/Calculator.app/Contents");
    try tmp.dir.createDirPath(t.io, "Apps/Calendar.app/Contents");
    const root = buf[0..try tmp.dir.realPath(t.io, buf)];
    var cat: search.Catalog = .{ .gpa = t.allocator };
    const apps = try std.fs.path.join(t.allocator, &.{ root, "Apps" });
    defer t.allocator.free(apps);
    try search.scanApps(&cat, t.io, apps);
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    files.* = try .open(t.allocator, idx, root, .{});
    errdefer files.close();
    files.rebuild(.{ .ready = ignoreOutcome });
    try t.expect(files.adopt());
    cat.files = files;
    return cat;
}

fn ignoreOutcome(_: ?*anyopaque, _: core.file_index.Outcome) void {}

test "a query finds apps and files, apps first" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
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

fn appTitles(arena: std.mem.Allocator, cat: *const search.Catalog, text: []const u8) ![]const []const u8 {
    var titles: std.ArrayList([]const u8) = .empty;
    for (try cat.query(arena, text)) |r| if (r.kind == .app) try titles.append(arena, r.title);
    return titles.items;
}

test "apps match by the same terms as files" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Visual Studio Code.app"));
    try cat.addApp(try t.allocator.dupe(u8, "/Applications/Calculator.app"));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reordered = try appTitles(a, &cat, "code visual");
    try t.expectEqual(@as(usize, 1), reordered.len);
    try t.expectEqualStrings("Visual Studio Code", reordered[0]);
    try t.expectEqual(@as(usize, 1), (try appTitles(a, &cat, "  vis   code ")).len);
    try t.expectEqual(@as(usize, 0), (try appTitles(a, &cat, "code zzz")).len);
    try t.expectEqualStrings("Calculator", (try appTitles(a, &cat, "calc"))[0]);
}

const FakeClock = struct {
    now: f64 = 0,
    step: f64 = 0,
    fn read(ctx: ?*anyopaque) f64 {
        const c: *FakeClock = @ptrCast(@alignCast(ctx));
        defer c.now += c.step;
        return c.now;
    }
    fn advance(c: *FakeClock, seconds: f64) void {
        c.now += seconds;
    }
    fn binding(c: *FakeClock) panel_mod.Clock {
        return .{ .ctx = c, .read = read };
    }
};

const StubHooks = struct {
    requests: u32 = 0,
    file_searches: u32 = 0,
    clock: FakeClock = .{},
    fn request(ctx: ?*anyopaque) void {
        const h: *StubHooks = @ptrCast(@alignCast(ctx));
        h.requests += 1;
    }
    fn searchFiles(ctx: ?*anyopaque) void {
        const h: *StubHooks = @ptrCast(@alignCast(ctx));
        h.file_searches += 1;
    }
    fn icon(_: ?*anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
    /// Every date, whatever its seconds' type, as the same one.
    fn date(comptime Seconds: type) fn (?*anyopaque, Seconds, std.mem.Allocator) []const u8 {
        return struct {
            fn at(_: ?*anyopaque, _: Seconds, _: std.mem.Allocator) []const u8 {
                return "Today at 9:41 AM";
            }
        }.at;
    }
    fn hooks(h: *StubHooks) panel_mod.Hooks {
        return .{ .ctx = h, .clock = h.clock.binding(), .request = request, .app_icon = icon, .describe_date = date(i64), .detailed_date = date(f64), .search_files = searchFiles };
    }
};

fn countRows(rows: []const search.Row, kind: search.Kind) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.kind == kind);
    return n;
}

test "typing shows rows; Return opens the selected one; hiding keeps the session within the window and forgets it after" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expectEqual(chrome.metrics.search_height, p.panelHeight());
    try t.expect(tester.hasText("Floodlight"));
    try t.expect(tester.hasText(panel_mod.summon_label));

    tester.typeText("cal");
    tester.settle(0.2);
    try t.expect(p.list.visible.len >= 3);
    try t.expect(tester.hasText("Calculator"));
    try t.expect(tester.hasText("Calendar"));
    try t.expect(tester.hasText("Top Hit"));
    try t.expect(tester.hasText("Application"));
    try t.expect(tester.hasText("Google"));
    try t.expect(!tester.hasText(panel_mod.summon_label));
    try t.expectEqual(@as(f32, 521), p.panelHeight());
    try t.expect(hooks.requests > 0);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.up }));
    try t.expectEqual(@as(usize, 0), p.list.selected);
    // A window offers every key to the view first, as a shortcut.
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 1), p.list.selected);
    try t.expect(!tester.shortcut(.{ .key = ui.Shortcut.enter }));
    tester.key(.enter);
    tester.settle(0.1);
    const pending = p.pending orelse return error.NoAction;
    try t.expectEqualStrings(p.list.visible[1].path, pending.open);
    const chosen_path = try t.allocator.dupe(u8, p.list.visible[1].path);
    defer t.allocator.free(chosen_path);

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqual(panel_mod.Filter.apps, p.list.filter);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqualStrings(chosen_path, p.list.selection().?.path);

    p.hide();
    hooks.clock.advance(4 * 60);
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("cal", p.field.text());
    try t.expectEqual(panel_mod.Filter.apps, p.list.filter);
    try t.expectEqualStrings(chosen_path, p.list.selection().?.path);
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

    for (0..p.list.visible.len + 2) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(p.list.visible.len - 1, p.list.selected);

    p.hide();
    hooks.clock.advance(6 * 60);
    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.rows.len);
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
    try t.expectEqual(panel_mod.Filter.all, p.list.filter);
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(chrome.metrics.search_height, p.panelHeight());
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
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("github.com");
    tester.settle(0.2);
    try t.expect(p.list.visible.len >= 2);
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expectEqualStrings("Open github.com", p.list.visible[0].title);
    try t.expectEqualStrings("https://github.com", p.list.visible[0].subtitle);
    try t.expectEqualStrings("Google", p.list.visible[p.list.visible.len - 1].title);

    tester.key(.enter);
    tester.settle(0.1);
    try t.expectEqualStrings("https://github.com", (p.pending orelse return error.NoAction).open);
    p.pending = null;

    try t.expect(tester.shortcut(.{ .key = 'c', .cmd = true }));
    try t.expectEqualStrings("https://github.com", (p.pending orelse return error.NoAction).copy.path);
    p.pending = null;

    try tmp.dir.writeFile(t.io, .{ .sub_path = "Documents/github.com", .data = "" });
    files.rebuild(.{ .ready = ignoreOutcome });
    try t.expect(files.adopt());
    p.list.markStale();
    p.refresh();
    try t.expect(p.list.visible.len >= 3);
    try t.expectEqual(search.Kind.file, p.list.visible[0].kind);
    try t.expectEqualStrings("github.com", p.list.visible[0].title);
    try t.expectEqualStrings("Open github.com", p.list.visible[1].title);
    try t.expectEqualStrings("https://github.com", p.list.visible[1].subtitle);
    try t.expectEqualStrings("Google", p.list.visible[p.list.visible.len - 1].title);
}

test "filter chips count, narrow the rows, and drop Top Hit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("return");
    tester.settle(0.2);
    for ([_][]const u8{ "All", "Apps", "Files", "Folders", "PDFs" }) |chip| try t.expect(tester.hasText(chip));
    try t.expect(!tester.hasText("Images"));
    try t.expectEqual(@as(usize, 1), p.list.count(.pdfs));

    try t.expect(tester.shortcut(.{ .key = '3', .cmd = true }));
    tester.settle(0.1);
    try t.expectEqual(panel_mod.Filter.files, p.list.filter);
    for (p.list.visible) |r| try t.expectEqual(search.Kind.file, r.kind);
    try t.expect(!p.isTopHit(0));

    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
    try t.expect(tester.hasText("No apps results for \u{201C}return\u{201D}"));
}

test "Escape asks to hide" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 120 });
    defer tester.deinit();
    tester.settle(0.1);
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.escape }));
    try t.expect(p.pending != null and p.pending.? == .hide);
}

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

const CompletionFixture = struct {
    tmp: std.testing.TmpDir,
    buf: [std.posix.PATH_MAX]u8 = undefined,
    files: core.file_index.FileIndex = undefined,
    cat: search.Catalog = undefined,
    hooks: StubHooks = .{},
    p: panel_mod.Panel = undefined,
    tester: ui.Tester = undefined,

    fn init(f: *CompletionFixture, extra_apps: []const []const u8) !void {
        f.tmp = t.tmpDir(.{});
        errdefer f.tmp.cleanup();
        for (extra_apps) |app| try f.tmp.dir.createDirPath(t.io, app);
        f.cat = try tmpCatalog(&f.tmp, &f.buf, &f.files);
        errdefer f.files.close();
        errdefer f.cat.deinit();
        f.hooks = .{};
        f.p = panel_mod.Panel.init(t.allocator, &f.cat, null, f.hooks.hooks());
        errdefer f.p.deinit();
        try f.tester.init(t.allocator, .init(&f.p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
        f.tester.settle(0.1);
    }

    fn deinit(f: *CompletionFixture) void {
        f.tester.deinit();
        f.p.deinit();
        f.cat.deinit();
        f.files.close();
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
    try t.expectEqualStrings(fx.p.list.visible[1].path, fx.p.pending.?.open);
    try t.expectEqualStrings("ant", fx.p.field.text());
    fx.p.pending = null;

    fx.tester.key(.right);
    try t.expectEqualStrings("antigravity", fx.p.field.text());
    try t.expectEqualStrings("antigravity", fx.p.list.answered());
    try t.expect(fx.p.completion == null);
    try t.expect(!fx.tester.hasText("Grant"));

    fx.p.reset();
    fx.tester.frame();
    fx.tester.typeText("ANT");
    try t.expect(fx.tester.hasText("Grant"));
    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.tab }));
    try t.expectEqualStrings("ANTigravity", fx.p.field.text());
    try t.expectEqualStrings("ANTigravity", fx.p.list.answered());
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
    try t.expectEqualStrings("visual", fx.p.list.answered());
    try t.expectEqualStrings(" Studio Code", fx.p.completion.?.suffix);

    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("visual Studio", fx.p.field.text());
    try t.expectEqualStrings("visual Studio", fx.p.list.answered());
    try t.expectEqualStrings(" Code", fx.p.completion.?.suffix);

    try t.expect(fx.tester.shortcut(.{ .key = ui.Shortcut.right, .alt = true }));
    try t.expectEqualStrings("visual Studio Code", fx.p.field.text());
    try t.expectEqualStrings("visual Studio Code", fx.p.list.answered());
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
    var ts = try TmpStore.init();
    defer ts.deinit();
    try ts.tmp.dir.createDirPath(t.io, "Apps/Antigravity.app/Contents");
    try ts.tmp.dir.createDirPath(t.io, "Apps/Anthropic Console.app/Contents");
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&ts.tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();

    {
        var store = try clipboard.Store.open(ts.db, ts.images);
        defer store.close();
        var hooks: StubHooks = .{};
        hooks.clock.advance(100);
        var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
        defer p.deinit();
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
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

    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var hooks: StubHooks = .{};
    hooks.clock.advance(200);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("git");
    const link_comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.history, link_comp.source);
    try t.expectEqualStrings("hub.com", link_comp.suffix);

    p.reset();
    tester.frame();
    tester.typeText("ant");
    try t.expectEqualStrings("Antigravity", p.list.visible[0].title);
    const beat_comp = p.completion orelse return error.NoCompletion;
    try t.expectEqual(panel_mod.CompletionSource.history, beat_comp.source);
    try t.expectEqualStrings("hropic Console", beat_comp.suffix);
}

test "Query History ranks by recency and frequency, evicts lowest-ranked entries at its bound, and falls back to the top hit when cleared" {
    var fx: CompletionFixture = .{ .tmp = undefined };
    try fx.init(&.{ "Apps/Antigravity.app/Contents", "Apps/Anthropic Console.app/Contents", "Apps/Anthem Studio.app/Contents" });
    defer fx.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
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
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    _ = try store.add(.{ .text = "quarterly invoice summary" }, "com.apple.Notes", "Notes", 100);
    _ = try store.add(.{ .text = "vault-recovery-phrase-99" }, "com.1password.1password", "1Password", 200);

    var hooks: StubHooks = .{};
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
    try t.expectEqualStrings("quarterly invoice", p.board.list.answered());

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
// (ClipboardTextContentTests, ClipboardHistoryStoreTests, SearchResultProjectionClipboardTests).

test "copied text is classified as the Swift store classifies it" {
    try t.expectEqualStrings("example.com", clipboard.classify("https://www.example.com/a?b").link);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("rgb(255, 255, 255)", clipboard.rgbDescription(arena.allocator(), clipboard.classify(" #fff ").color));
    try t.expectEqualStrings("rgba(17, 34, 51, 0.50)", clipboard.rgbDescription(arena.allocator(), clipboard.classify("#11223380").color));
    try t.expectEqualStrings("JSON", clipboard.classify("{\"a\": 1}").code);
    try t.expectEqualStrings("Code", clipboard.classify("const x = 1;").code);
    try t.expectEqualStrings("HTML", clipboard.classify("<p>hi</p>").code);
    try t.expectEqualStrings("/Users/me/a.txt", clipboard.classify("file:///Users/me/a.txt").path);
    try t.expectEqualStrings("/Users/me/a.txt", clipboard.classify("/Users/me/a.txt").path);
    try t.expect(clipboard.classify("a\n/b") == .plain);
    try t.expect(clipboard.classify("{not json}") == .plain);
    try t.expect(clipboard.classify("#12345") == .plain);
}

test "a stored entry comes back with its content and the fact it carries; a copied file's is plain" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    _ = try store.add(.{ .text = "/Users/me/a.txt" }, "", "Notes", 2);
    _ = try store.add(.{ .text = "{\"a\": 1}" }, "", "Notes", 3);
    _ = try store.add(.{ .text = " #11223380 " }, "", "Notes", 4);
    _ = try store.add(.{ .text = "https://www.example.com/a?b" }, "", "Notes", 5);
    _ = try store.add(.{ .file = "/tmp/x.pdf" }, "", "Finder", 6);
    const rows = try store.list(arena.allocator(), "");
    try t.expect(rows[0].content == .plain);
    try t.expectEqualStrings("example.com", rows[1].content.link);
    try t.expectEqual(clipboard.Rgba{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x80 }, rows[2].content.color);
    try t.expectEqualStrings("JSON", rows[3].content.code);
    try t.expectEqualStrings("/Users/me/a.txt", rows[4].content.path);
}

// The store's tables as they were before entries carried their classification.
const unclassified_schema =
    \\CREATE TABLE entries(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, created_at REAL NOT NULL,
    \\  source TEXT NOT NULL DEFAULT '', source_name TEXT NOT NULL DEFAULT 'Clipboard', pinned_at REAL,
    \\  width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, byte_count INTEGER NOT NULL DEFAULT 0,
    \\  hash BLOB, thumbnail BLOB, png BLOB);
;

const raw_sqlite = struct {
    extern "c" fn sqlite3_open(path: [*:0]const u8, db: *?*anyopaque) c_int;
    extern "c" fn sqlite3_close(db: *anyopaque) c_int;
    extern "c" fn sqlite3_exec(db: *anyopaque, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*anyopaque) c_int;

    fn run(path: [:0]const u8, sql: [:0]const u8) !void {
        var db: ?*anyopaque = null;
        if (sqlite3_open(path, &db) != 0) return error.Sqlite;
        defer _ = sqlite3_close(db.?);
        if (sqlite3_exec(db.?, sql, null, null, null) != 0) return error.Sqlite;
    }
};

test "rows recorded before classification are classified when the store opens" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    try raw_sqlite.run(ts.db, unclassified_schema ++
        "INSERT INTO entries(kind, text, created_at) VALUES('text', 'https://example.org/x', 100), ('file', '/tmp/a.pdf', 200), ('text', '#abc', 300);");
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try store.list(arena.allocator(), "");
    try t.expectEqual(clipboard.Rgba{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, rows[0].content.color);
    try t.expect(rows[1].content == .plain);
    try t.expectEqualStrings("example.org", rows[2].content.link);
}

const day = 86400;

test "rows name an entry's age, source and place" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ages = [_]struct { f64, []const u8 }{ .{ 30, "just now" }, .{ 120, "2m" }, .{ 7200, "2h" }, .{ 3 * day, "3d" }, .{ 65 * day, "2mo" }, .{ 400 * day, "1y" } };
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
    try t.expectEqual(@as(usize, 40 * board_mod.max_line_bytes), head.len);
    const wide = "\u{4E2D}";
    var cjk: [3 * 4000]u8 = undefined;
    for (0..4000) |i| @memcpy(cjk[i * 3 ..][0..3], wide);
    try t.expect(std.unicode.utf8ValidateSlice(board_mod.shownHead(&cjk, 1)));
    try t.expectEqualStrings("short", board_mod.shownHead("short", 1));
}

test "the store skips a repeat of the newest entry only, pins, finds and prunes" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    const store = try openMemory(&ts);
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

    // Past 30 days only the unpinned "beta" is old enough to go.
    try store.prune(250 + 30 * day, 30);
    rows = try store.list(a, "");
    try t.expectEqualSlices(f64, &.{ 100, 400, 300 }, try createdAt(a, rows));
    try store.delete(rows[1].id);
    try t.expectEqualSlices(f64, &.{ 100, 300 }, try createdAt(a, try store.list(a, "")));
}

fn createdAt(arena: std.mem.Allocator, rows: []const clipboard.Entry) ![]const f64 {
    const out = try arena.alloc(f64, rows.len);
    for (rows, out) |e, *at| at.* = e.created_at;
    return out;
}

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
    images: []const u8,
    db: [:0]const u8,

    fn init() !TmpStore {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
        const images = try std.fs.path.join(t.allocator, &.{ root, "images" });
        errdefer t.allocator.free(images);
        const db = try std.fs.path.joinZ(t.allocator, &.{ root, "clipboard.sqlite3" });
        return .{ .tmp = tmp, .images = images, .db = db };
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

/// History in memory, its pictures in a folder `ts` owns, as on disk.
fn openMemory(ts: *const TmpStore) !clipboard.Store {
    return clipboard.Store.open(":memory:", ts.images);
}

test "full images live beside the database, one file per picture, gone with their last entry" {
    var ts = try TmpStore.init();
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
    var ts = try TmpStore.init();
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
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
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
    var ts = try TmpStore.init();
    defer ts.deinit();
    const big = try t.allocator.alloc(u8, 2 << 20);
    defer t.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const sql = try std.fmt.allocPrintSentinel(arena.allocator(), unclassified_schema ++
            "INSERT INTO entries(kind, text, created_at, width, height, byte_count, thumbnail, png) VALUES('image', 'PNG Image', 100, 10, 10, {d}, X'00', X'{x}');", .{ big.len, big }, 0);
        try raw_sqlite.run(ts.db, sql);
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
    var ts = try TmpStore.init();
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
    var ts = try TmpStore.init();
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

/// A pasteboard holding what a test puts on it, counting the picture reads.
const FakePasteboard = struct {
    types: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    picture: ?clipboard.PastedImage = null,
    picture_bytes: usize = 0,
    string: []const u8 = "",
    picture_reads: usize = 0,

    fn pasteboard(f: *FakePasteboard) clipboard.Pasteboard {
        return .{ .ctx = f, .has_type = hasType, .file_paths = filePaths, .image_byte_count = imageByteCount, .image = image, .text = text };
    }

    fn of(ctx: ?*anyopaque) *FakePasteboard {
        return @ptrCast(@alignCast(ctx));
    }

    fn hasType(ctx: ?*anyopaque, ty: []const u8) bool {
        for (of(ctx).types) |x| if (std.mem.eql(u8, x, ty)) return true;
        return false;
    }

    fn filePaths(ctx: ?*anyopaque, _: std.mem.Allocator) []const []const u8 {
        return of(ctx).files;
    }

    fn imageByteCount(ctx: ?*anyopaque) ?usize {
        const f = of(ctx);
        return if (f.picture != null) f.picture_bytes else null;
    }

    fn image(ctx: ?*anyopaque, _: std.mem.Allocator) ?clipboard.PastedImage {
        const f = of(ctx);
        f.picture_reads += 1;
        return f.picture;
    }

    fn text(ctx: ?*anyopaque, _: std.mem.Allocator) []const u8 {
        return of(ctx).string;
    }
};

const pasted_png: clipboard.PastedImage = .{ .png = "\x89PNG pasted", .thumbnail = "thumb", .width = 4, .height = 3, .format = .png };
const notes_app: clipboard.App = .{ .bundle_id = "com.apple.Notes", .name = "Notes" };

test "a copy marked private, transient, auto-generated or Floodlight's own is not recorded" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marked = [_][]const u8{ "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.apple.is-sensitive", clipboard.own_write_type };
    for (marked) |ty| {
        var fake: FakePasteboard = .{ .types = &.{ty}, .string = "secret" };
        try t.expect(!try store.capture(a, fake.pasteboard(), notes_app, 1));
    }
    try t.expectEqual(@as(usize, 0), (try store.list(a, "")).len);
    var plain: FakePasteboard = .{ .types = &.{"public.utf8-plain-text"}, .string = "kept" };
    try t.expect(try store.capture(a, plain.pasteboard(), notes_app, 2));
    const rows = try store.list(a, "");
    try t.expectEqualStrings("kept", rows[0].text);
    try t.expectEqualStrings("Notes", rows[0].source_name);
}

test "copied files win over a picture and text, each file once, and the picture is never read" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakePasteboard = .{ .files = &.{ "/a/x.pdf", "/a/y.pdf", "/a/x.pdf" }, .picture = pasted_png, .picture_bytes = 10, .string = "x.pdf" };
    try t.expect(try store.capture(a, fake.pasteboard(), .{ .bundle_id = "com.apple.finder", .name = "Finder" }, 1));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 2), rows.len);
    for (rows) |e| try t.expectEqual(clipboard.Kind.file, e.kind);
    // Both are recorded at the same time, so the list may give either first.
    var paths = [_][]const u8{ rows[0].text, rows[1].text };
    std.mem.sort([]const u8, &paths, {}, lessThan);
    try t.expectEqualStrings("/a/x.pdf", paths[0]);
    try t.expectEqualStrings("/a/y.pdf", paths[1]);
    try t.expectEqual(@as(usize, 0), fake.picture_reads);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "a picture past the size cap falls back to the copy's text" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakePasteboard = .{ .picture = pasted_png, .picture_bytes = clipboard.max_image_bytes + 1, .string = "caption" };
    try t.expect(try store.capture(a, fake.pasteboard(), notes_app, 1));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("caption", rows[0].text);
    try t.expectEqual(@as(usize, 0), fake.picture_reads);
}

test "a screenshot is named for its source, other pictures for their format" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var shot: FakePasteboard = .{ .picture = pasted_png, .picture_bytes = 10 };
    _ = try store.capture(a, shot.pasteboard(), .{ .bundle_id = "com.apple.screencaptureui", .name = "Screenshot" }, 1);
    var tiff_png = pasted_png;
    tiff_png.png = "\x89PNG from tiff";
    tiff_png.format = .tiff;
    var tiff: FakePasteboard = .{ .picture = tiff_png, .picture_bytes = 10 };
    _ = try store.capture(a, tiff.pasteboard(), notes_app, 2);
    var other_png = pasted_png;
    other_png.png = "\x89PNG another";
    var png: FakePasteboard = .{ .picture = other_png, .picture_bytes = 10 };
    _ = try store.capture(a, png.pasteboard(), notes_app, 3);
    const rows = try store.list(a, "");
    try t.expectEqualStrings("PNG Image", rows[0].text);
    try t.expectEqualStrings("TIFF Image", rows[1].text);
    try t.expectEqualStrings("Screenshot", rows[2].text);
    try t.expectEqual(@as(u32, 4), rows[2].width);
    try t.expectEqualStrings("\x89PNG pasted", store.image(a, rows[2].id).?);
}

test "empty text and text past the cap are not recorded" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const past_cap = try a.alloc(u8, clipboard.max_text_bytes + 1);
    @memset(past_cap, 'x');
    var empty: FakePasteboard = .{};
    try t.expect(!try store.capture(a, empty.pasteboard(), notes_app, 1));
    var long: FakePasteboard = .{ .string = past_cap };
    try t.expect(!try store.capture(a, long.pasteboard(), notes_app, 2));
    var fits: FakePasteboard = .{ .string = past_cap[0..clipboard.max_text_bytes] };
    try t.expect(try store.capture(a, fits.pasteboard(), notes_app, 3));
    try t.expectEqual(@as(usize, 1), (try store.list(a, "")).len);
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

/// The board over a history in memory and no apps or files. Fill `store`
/// between `init` and `show`; the fixture must not move after `init`.
const BoardFixture = struct {
    ts: TmpStore,
    store: clipboard.Store,
    cat: search.Catalog,
    hooks: StubHooks,
    p: panel_mod.Panel,
    tester: ui.Tester,
    shown: bool,

    fn init(f: *BoardFixture) !void {
        f.ts = try TmpStore.init();
        errdefer f.ts.deinit();
        f.store = try openMemory(&f.ts);
        f.cat = .{ .gpa = t.allocator };
        f.hooks = .{};
        f.p = .init(t.allocator, &f.cat, &f.store, f.hooks.hooks());
        f.shown = false;
    }

    /// Opens the board and draws it at its own size until it rests.
    fn show(f: *BoardFixture) !void {
        f.p.showClipboard();
        const m = board_mod.board_metrics;
        try f.tester.init(t.allocator, .init(&f.p, panel_mod.Panel.view), .{ .width = m.width, .height = m.height });
        f.shown = true;
        f.tester.settle(1);
    }

    /// `n` texts, "entry number 0" the oldest.
    fn seed(f: *BoardFixture, n: usize) !void {
        var buf: [32]u8 = undefined;
        for (0..n) |i| _ = try f.store.add(.{ .text = try std.fmt.bufPrint(&buf, "entry number {d}", .{i}) }, "x", "Notes", @floatFromInt(1000 + i));
    }

    fn deinit(f: *BoardFixture) void {
        if (f.shown) f.tester.deinit();
        f.p.deinit();
        f.cat.deinit();
        f.store.close();
        f.ts.deinit();
    }
};

/// The text drawn right of `label` on its line: an inspector row's value.
fn besideText(tester: *ui.Tester, label: []const u8) ?[]const u8 {
    const at = tester.findText(label) orelse return null;
    for (tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (n.rect.x > at.x + at.w and @abs(n.rect.y - at.y) < 0.5) return tx.str,
        else => {},
    };
    return null;
}

test "the board lists history, inspects the selection, and filters" {
    var f: BoardFixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(.{ .file = "/tmp/floodlight-nano-test.pdf" }, "com.apple.finder", "Finder", 500);
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
    try t.expect(tester.shortcut(.{ .key = board_mod.backspace }));
    tester.settle(1);
    try t.expect(tester.hasText("1 entry"));

    tester.typeText("zzz");
    tester.settle(1);
    try t.expect(tester.hasText("No matching clipboard all for \u{201C}zzz\u{201D}"));
    // ⌫ on the board deletes entries only, never the filter's text.
    try t.expect(tester.shortcut(.{ .key = board_mod.backspace }));
    tester.settle(1);
    try t.expectEqualStrings("zzz", p.field.text());
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
    const hides = [_]panel_mod.Action{ .hide, .{ .open = "/a" }, .{ .reveal = "/a" }, .{ .copy = row }, .{ .clipboard = .{ .reveal = "/a" } } };
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

fn addPicture(store: *clipboard.Store, png: []const u8, at: f64) !void {
    _ = try store.add(.{ .image = .{ .name = "", .png = png, .thumbnail = "", .width = 3840, .height = 2160 } }, "com.apple.Preview", "Preview", at);
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
    try t.expect(f.tester.hasText("Clipboard history is empty. Copied text, files, and images will appear here."));
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
    // `.ts` is TypeScript to the Swift inspector, not a video stream.
    try t.expectEqualStrings("Source Code", clipboard.fileType(a, "/x.ts", false));
    try t.expectEqualStrings("ZZZ", clipboard.fileType(a, "/x.zzz", false));
}

test "the injected clock advances board ages and pins, and forget clears both surfaces" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
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
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
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
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
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
    try t.expect(p.completion == null);

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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
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
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    hooks.clock.step = 0.01;
    p.calibrateFileSearch();
    tester.typeText("a");
    tester.frame();
    try t.expectEqual(@as(u32, 1), hooks.file_searches);
    try t.expect(tester.hasText("Calculator"));
    try t.expectEqual(@as(usize, 2), countRows(p.list.visible, .app));
    try t.expectEqual(@as(usize, 0), countRows(p.list.visible, .file));

    p.landFiles();
    tester.frame();
    try t.expect(countRows(p.list.visible, .file) > 0);
    try t.expect(tester.hasText("kind-of-blue.flac"));
    try t.expectEqual(@as(usize, 0), p.list.selected);

    p.hide();
    hooks.clock.advance(60);
    p.showSearch();
    try t.expectEqual(@as(u32, 1), hooks.file_searches);
    try t.expect(countRows(p.list.visible, .file) > 0);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = 840, .height = 560 });
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
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
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

const SuggestSpy = struct {
    hooks_base: StubHooks = .{},
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
            .app_icon = StubHooks.icon,
            .describe_date = StubHooks.date(i64),
            .detailed_date = StubHooks.date(f64),
            .suggest = suggest,
        };
    }
};

test "the first frame after a keystroke does not wait for suggestions, and arrival adds up to four bold-tail rows under Google without moving selection" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("cal", spy.queries.items[0]);
    try t.expectEqual(@as(usize, 3), p.list.visible.len);
    try t.expectEqualStrings("Calendar", p.list.visible[0].title);
    try t.expectEqualStrings("Calculator", p.list.visible[1].title);
    try t.expectEqualStrings("Google", p.list.visible[2].title);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqual(@as(usize, 1), p.list.selected);

    p.receiveSuggestions("cal", &.{
        "calculator online",
        "calendar 2026",
        "california dmv",
        "caltrain schedule",
        "calories in an apple",
    });
    tester.frame();

    try t.expectEqual(@as(usize, 1), p.list.selected);
    try t.expectEqual(@as(usize, 7), p.list.visible.len);
    try t.expectEqualStrings("Google", p.list.visible[2].title);
    try t.expectEqualStrings("calculator online", p.list.visible[3].title);
    try t.expectEqualStrings("calendar 2026", p.list.visible[4].title);
    try t.expectEqualStrings("california dmv", p.list.visible[5].title);
    try t.expectEqualStrings("caltrain schedule", p.list.visible[6].title);
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
    try t.expectEqual(@as(usize, 3), p.list.selected);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("wea");
    const first_seq = spy.seqs.items[0];
    try t.expect(first_seq > 0);

    tester.typeText("ther");
    const second_seq = spy.seqs.items[1];
    try t.expect(second_seq > first_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"weather radar"}));
    try t.expectEqual(@as(usize, 1), p.list.visible.len);
    try t.expectEqualStrings("Google", p.list.visible[0].title);

    for (0..4) |_| tester.key(.backspace);
    try t.expectEqualStrings("wea", p.field.text());
    const third_seq = spy.seqs.getLast();
    try t.expect(third_seq > second_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"stale weather"}));
    try t.expectEqual(@as(usize, 1), p.list.visible.len);

    try t.expect(p.receiveSuggestionsFor(third_seq, "wea", &.{}));
    try t.expectEqual(@as(usize, 1), p.list.visible.len);
    try t.expectEqualStrings("Google", p.list.visible[0].title);
}

test "with the setting off, or for a Link Row, a path-like query, or Clipboard mode, the suggestion source receives no request" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    p.setWebSuggestionsEnabled(false);
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 0), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 1), p.list.visible.len);

    p.setWebSuggestionsEnabled(true);
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[0]);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 2), p.list.visible.len);

    p.setWebSuggestionsEnabled(false);
    try t.expectEqual(@as(usize, 1), p.list.visible.len);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{ "weather forecast", "weather radar" });
    try t.expectEqual(@as(usize, 3), p.list.visible.len);

    spy.hooks_base.clock.advance(299);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqual(@as(usize, 3), p.list.visible.len);
    try t.expectEqualStrings("weather forecast", p.list.visible[1].title);
    try t.expectEqualStrings("weather radar", p.list.visible[2].title);

    spy.hooks_base.clock.advance(2);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 2), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[1]);
    try t.expectEqual(@as(usize, 1), p.list.visible.len);
}

test "the first web suggestion becomes the completion only when neither query history nor top hit matches" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var mem = try TmpStore.init();
    defer mem.deinit();
    var store = try openMemory(&mem);
    defer store.close();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    spy.hooks_base.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = 521 });
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
