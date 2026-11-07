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
const presence = @import("presence.zig");
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

fn tmpCatalog(tmp: *std.testing.TmpDir, buf: *[std.posix.PATH_MAX]u8, files: *core.file_index.FileIndex) !search.Catalog {
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
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
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
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
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

const PresenceSpy = struct {
    log: [16]presence.Effect = undefined,
    len: usize = 0,

    fn record(ctx: ?*anyopaque, e: presence.Effect) void {
        const s: *PresenceSpy = @ptrCast(@alignCast(ctx));
        s.log[s.len] = e;
        s.len += 1;
    }
    fn presence_(s: *PresenceSpy) presence.Presence {
        return .{ .effects = .{ .ctx = s, .run = record } };
    }
    /// The effects since the last call, in order.
    fn take(s: *PresenceSpy) []const presence.Effect {
        defer s.len = 0;
        return s.log[0..s.len];
    }
};

const showing = [_]presence.Effect{ .note_paste_target, .place, .order_in_unseen, .start_entrance_timer };
const hiding = [_]presence.Effect{ .hide_window, .end_session };

fn shownPresence(spy: *PresenceSpy) presence.Presence {
    var p = spy.presence_();
    p.search(false);
    _ = p.framePresented(true);
    _ = spy.take();
    return p;
}

test "a reopened panel stays unseen until a frame of its own is presented, then shows once" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    try t.expect(!p.framePresented(true));
    p.search(false);
    try t.expectEqualSlices(presence.Effect, &showing, spy.take());
    try t.expectEqual(presence.Phase.entering, p.phase);
    // A frame built without a drawable is not on screen: the old one still is.
    try t.expect(!p.framePresented(false));
    try t.expect(p.framePresented(true));
    try t.expectEqualSlices(presence.Effect, &.{.reveal}, spy.take());
    try t.expect(!p.framePresented(true));
    try t.expectEqual(presence.Phase.shown, p.phase);
}

test "⌥Space while focused hides and forgets the session, during the entrance too" {
    var spy: PresenceSpy = .{};
    var p = shownPresence(&spy);
    p.search(true);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
    try t.expect(p.isHidden());

    p.search(false);
    _ = spy.take();
    p.search(true);
    try t.expectEqualSlices(presence.Effect, &hiding, spy.take());
    try t.expect(!p.framePresented(true));
}

test "an entrance's fallback timer reveals only its own entrance" {
    var spy: PresenceSpy = .{};
    var p = spy.presence_();
    p.search(false);
    p.search(true);
    p.search(false);
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
    p.search(false);
    try t.expectEqualSlices(presence.Effect, &.{ .place, .order_front }, spy.take());
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

test {
    _ = core;
}
