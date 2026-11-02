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

const NoHooks = struct {
    requests: u32 = 0,
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
        return .{ .ctx = h, .request = request, .app_icon = icon, .describe_date = date, .detailed_date = detailed };
    }
};

test "typing shows rows; Return opens the selected one; hiding forgets the session" {
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

    p.pending = null;
    for (0..p.visible.len + 2) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(p.visible.len - 1, p.selected);

    p.reset();
    try t.expectEqual(@as(usize, 0), p.rows.len);
    try t.expectEqualStrings("", p.field.text());
    try t.expectEqual(panel_mod.metrics.search_height, p.panelHeight());
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

test "the store skips a repeat of the newest entry only, pins, finds and prunes" {
    const store = try clipboard.Store.open(":memory:");
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

test "the board lists history, inspects the selection, and filters" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:");
    defer store.close();
    _ = try store.add(.{ .file = "/tmp/floodlight-nano-test.pdf" }, "com.apple.finder", "Finder", 500);
    _ = try store.add(.{ .text = "hello there world" }, "com.apple.Notes", "Notes", 1000);
    _ = try store.add(.{ .text = "https://www.example.com/page" }, "com.apple.Safari", "Safari", 2000);
    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    p.showClipboard();
    p.board.now = 2060;
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
    var store = try clipboard.Store.open(":memory:");
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
    var store = try clipboard.Store.open(":memory:");
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

test "an empty history says so" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var store = try clipboard.Store.open(":memory:");
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

test {
    _ = core;
}
