//! Search panel, catalog, filters, inline completion, query history, suggestions, and async file search tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("floodlight_core");
const search = @import("../search.zig");
const panel_mod = @import("../panel.zig");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const chrome = @import("../chrome.zig");
const h = @import("helpers.zig");
const t = std.testing;

const tmpCatalog = h.tmpCatalog;
const ignoreOutcome = h.ignoreOutcome;
const StubHooks = h.StubHooks;
const countRows = h.countRows;
const addNumberedApps = h.addNumberedApps;
const TmpStore = h.TmpStore;
const openMemory = h.openMemory;

fn fillAlphaBehind(tester: *ui.Tester, label: []const u8) ?f32 {
    const nodes = tester.ctx.nodes.items;
    for (nodes) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
            var at = n.parent;
            while (at < nodes.len) : (at = nodes[at].parent) {
                if (nodes[at].style.background) |fill| return fill.a;
            }
        },
        else => {},
    };
    return null;
}

fn pointAt(tester: *ui.Tester, label: []const u8) !void {
    const at = tester.findText(label) orelse return error.TextNotDrawn;
    tester.moveTo(at.x + at.w / 2, at.y + at.h / 2);
}

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
    try t.expect(!tax[0].stamped);
    search.stamp(arena.allocator(), &tax[0]);
    try t.expect(tax[0].stamped);
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

test "an app linked into the apps folder is listed, as Safari is" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Cryptex/Safari.app/Contents");
    try tmp.dir.createDirPath(t.io, "Apps");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Cryptex/notes.txt", .data = "" });
    try tmp.dir.symLink(t.io, "../Cryptex/Safari.app", "Apps/Safari.app", .{});
    try tmp.dir.symLink(t.io, "../Cryptex/notes.txt", "Apps/Notes.app", .{});
    try tmp.dir.symLink(t.io, "../Cryptex/Gone.app", "Apps/Gone.app", .{});
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const apps = try std.fs.path.join(t.allocator, &.{ root, "Apps" });
    defer t.allocator.free(apps);
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try search.scanApps(&cat, t.io, apps);

    try t.expectEqual(@as(usize, 1), cat.apps.items.len);
    try t.expectEqualStrings("Safari", cat.apps.items[0].name);
    try t.expectStringEndsWith(cat.apps.items[0].path, "/Apps/Safari.app");
}

test "an app whose name starts with the query outranks a folder named exactly the query" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Projects/cal");
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    const rows = try cat.query(arena.allocator(), "cal");
    try t.expectEqual(search.Kind.app, rows[0].kind);
    try t.expectEqual(search.Kind.app, rows[1].kind);
    try t.expectEqualStrings("cal", rows[2].title);
    try t.expectEqual(search.Kind.folder, rows[2].kind);
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

fn clickText(tester: *ui.Tester, s: []const u8) !void {
    const r = tester.findText(s) orelse return error.TextNotDrawn;
    tester.click(r.x + r.w / 2, r.y + r.h / 2);
    tester.settle(0.1);
}

test "the search footer counts the rows and opens, reveals or copies the selection" {
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.typeText("cal");
    tester.settle(0.2);

    try t.expect(tester.hasText(tester.ctx.print("{d} results", .{p.list.visible.len})));
    const path = p.list.selection().?.path;
    try clickText(&tester, "Show in Finder");
    try t.expectEqualStrings(path, (p.pending orelse return error.NoAction).reveal);
    p.pending = null;
    try clickText(&tester, "Copy");
    try t.expectEqualStrings(path, (p.pending orelse return error.NoAction).copy.path);
    p.pending = null;
    try clickText(&tester, "Open");
    try t.expectEqualStrings(path, (p.pending orelse return error.NoAction).open);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.2);
    try t.expectEqual(chrome.metrics.search_height, p.panelHeight());
    try t.expect(tester.hasText("Nanospot"));
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
    try t.expectEqual(chrome.metrics.expanded_height, p.panelHeight());
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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
    try t.expect(tester.hasText("No apps match \u{201C}return\u{201D}"));
    try t.expect(tester.hasText("Press \u{2318}1 to search everything."));
    try t.expectEqualStrings("PDFs", chrome.sentenceNoun(&tester.ctx, panel_mod.Filter.pdfs));
    try t.expectEqualStrings("apps", chrome.sentenceNoun(&tester.ctx, panel_mod.Filter.apps));
}

test "a filter chip past the bar's edge scrolls into reach, and a click on a cut one brings it whole into view" {
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
    const narrow: f32 = 300;
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = narrow, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);
    tester.typeText("return");
    tester.settle(0.2);

    const bar_right = narrow - chrome.metrics.well_inset - chrome.space.edge;
    const hidden = tester.findText("PDFs") orelse return error.TextNotDrawn;
    try t.expect(hidden.x > bar_right);
    const all = tester.findText("All") orelse return error.TextNotDrawn;

    const half_shown = hidden.x + hidden.w / 2 - bar_right;
    tester.hscroll(all.x, all.y, -half_shown);
    tester.frame();
    const cut = tester.findText("PDFs") orelse return error.TextNotDrawn;
    try t.expect(cut.x < bar_right);
    try t.expect(cut.x + cut.w > bar_right);

    tester.click(cut.x + 1, cut.y + cut.h / 2);
    tester.settle(0.1);
    try t.expectEqual(panel_mod.Filter.pdfs, p.list.filter);
    const whole = tester.findText("PDFs") orelse return error.TextNotDrawn;
    try t.expect(whole.x + whole.w <= bar_right);
}

test "a Top Hit's title starts where every other row's does" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addNumberedApps(&cat, 3);
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.typeText("app");
    tester.settle(0.1);
    try t.expect(p.isTopHit(0));
    const top = tester.findText(p.list.visible[0].title) orelse return error.TextNotDrawn;
    const next = tester.findText(p.list.visible[1].title) orelse return error.TextNotDrawn;
    try t.expectEqual(next.x, top.x);
}

test "a row held down already wears the selection's fill" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addNumberedApps(&cat, 3);
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.typeText("app");
    tester.settle(0.1);
    const title = p.list.visible[1].title;
    try pointAt(&tester, title);
    const hovered = fillAlphaBehind(&tester, title) orelse return error.TextNotDrawn;
    tester.ctx.pointerDown();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expect(fillAlphaBehind(&tester, title).? > hovered);
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
        try f.tester.init(t.allocator, .init(&f.p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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
        try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = board_mod.board_metrics.width, .height = board_mod.board_metrics.height });
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("cal");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("cal", spy.queries.items[0]);
    try t.expectEqual(@as(usize, 6), p.list.visible.len);
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
    try t.expectEqual(@as(usize, 10), p.list.visible.len);
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

test "YouTube, X and Grok rows follow Google and its suggestions and open that engine's search, but never for links, paths or the board" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("lofi & chill");
    try t.expectEqual(@as(usize, 4), p.list.visible.len);
    try t.expectEqualStrings("Google", p.list.visible[0].title);
    try t.expectEqualStrings("YouTube", p.list.visible[1].title);
    try t.expectEqualStrings("youtube.com", p.list.visible[1].subtitle);
    try t.expectEqualStrings("X", p.list.visible[2].title);
    try t.expectEqualStrings("Grok", p.list.visible[3].title);

    p.receiveSuggestions("lofi & chill", &.{"lofi & chill beats"});
    tester.frame();
    try t.expectEqual(@as(usize, 5), p.list.visible.len);
    try t.expectEqualStrings("lofi & chill beats", p.list.visible[1].title);
    try t.expectEqualStrings("YouTube", p.list.visible[2].title);

    const expected = [_][]const u8{
        "https://www.youtube.com/results?search_query=lofi%20%26%20chill",
        "https://x.com/search?f=live&q=lofi%20%26%20chill",
        "https://grok.com/?q=lofi%20%26%20chill",
    };
    for (expected, 2..) |url, row| {
        try t.expectEqualStrings(url, p.list.visible[row].path);
    }

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    tester.key(.enter);
    try t.expectEqualStrings(expected[0], (p.pending orelse return error.NoAction).open);

    const none = [_][]const u8{ "github.com", "/Applications", "~/Documents", "./build.zig" };
    for (none) |q| {
        p.reset();
        tester.frame();
        tester.typeText(q);
        for (p.list.visible) |r| try t.expect(!r.engine);
    }

    p.reset();
    tester.frame();
    tester.typeText("\t");
    for (p.list.visible) |r| try t.expect(!r.engine);

    p.reset();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.visible.len);

    p.showClipboard();
    tester.frame();
    tester.typeText("lofi");
    for (p.list.visible) |r| try t.expect(!r.engine);
}

test "Return on X and Grok opens their searches, and an engine row stays selected when suggestions arrive late" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("lofi");
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqualStrings("X", p.list.visible[p.list.selected].title);

    p.receiveSuggestions("lofi", &.{ "lofi girl", "lofi hip hop" });
    tester.frame();
    try t.expectEqualStrings("X", p.list.visible[p.list.selected].title);
    tester.key(.enter);
    try t.expectEqualStrings("https://x.com/search?f=live&q=lofi", (p.pending orelse return error.NoAction).open);

    try t.expect(tester.shortcut(.{ .key = ui.Shortcut.down }));
    try t.expectEqualStrings("Grok", p.list.visible[p.list.selected].title);
    tester.key(.enter);
    try t.expectEqualStrings("https://grok.com/?q=lofi", (p.pending orelse return error.NoAction).open);
}

fn openByQuery(p: *panel_mod.Panel, tester: *ui.Tester, query: []const u8) void {
    p.reset();
    tester.frame();
    tester.typeText(query);
    tester.key(.enter);
    p.pending = null;
}

fn addApps(cat: *search.Catalog, names: []const []const u8) !void {
    for (names) |n| try cat.addApp(try std.fmt.allocPrint(t.allocator, "/Applications/{s}.app", .{n}));
}

test "an empty panel lists the apps opened most, recent ones first on a tie, and the chord opens the row" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addApps(&cat, &.{ "Alpha", "Beta", "Gamma" });
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
    try t.expectEqual(chrome.metrics.search_height, p.panelHeight());

    openByQuery(&p, &tester, "gamma");
    hooks.clock.advance(7200);
    openByQuery(&p, &tester, "alpha");
    openByQuery(&p, &tester, "alpha");
    hooks.clock.advance(7200);
    openByQuery(&p, &tester, "beta");

    p.reset();
    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 3), p.list.visible.len);
    try t.expectEqualStrings("Beta", p.list.visible[0].title);
    try t.expectEqualStrings("Alpha", p.list.visible[1].title);
    try t.expectEqualStrings("Gamma", p.list.visible[2].title);
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expectEqual(chrome.metrics.expanded_height, p.panelHeight());

    try t.expect(tester.shortcut(.{ .key = '3', .cmd = true }));
    try t.expectEqualStrings("/Applications/Gamma.app", (p.pending orelse return error.NoAction).open);
    p.pending = null;
    try t.expect(tester.shortcut(.{ .key = '2', .cmd = true }));
    try t.expectEqualStrings("/Applications/Alpha.app", (p.pending orelse return error.NoAction).open);
}

test "typing replaces the suggestions and clearing brings them back, the board shows none, and counts survive a restart until cleared" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addApps(&cat, &.{ "Alpha", "Beta" });

    {
        var store = try clipboard.Store.open(ts.db, ts.images);
        defer store.close();
        var hooks: StubHooks = .{};
        hooks.clock.advance(1000);
        var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
        defer p.deinit();
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
        defer tester.deinit();
        tester.settle(0.1);
        openByQuery(&p, &tester, "alpha");
        openByQuery(&p, &tester, "alpha");
        openByQuery(&p, &tester, "beta");
    }

    var gone: search.Catalog = .{ .gpa = t.allocator };
    defer gone.deinit();
    try addApps(&gone, &.{"Beta"});
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &gone, &store, hooks.hooks());
    defer p.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 1), p.list.visible.len);
    try t.expectEqualStrings("Beta", p.list.visible[0].title);

    tester.typeText("bet");
    try t.expectEqualStrings("Beta", p.list.visible[0].title);
    _ = tester.shortcut(.{ .key = '2', .cmd = true });
    try t.expect(p.pending == null);

    p.clearField();
    p.showSearch();
    tester.frame();
    try t.expectEqualStrings("Beta", p.list.visible[0].title);

    p.showClipboard();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.board.list.visible.len);

    p.showSearch();
    p.clearAppOpens();
    p.reset();
    p.showSearch();
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.visible.len);
}

test "a late reply for an old query or superseded request is ignored, and an empty failure leaves no rows" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("wea");
    const first_seq = spy.seqs.items[0];
    try t.expect(first_seq > 0);

    tester.typeText("ther");
    const second_seq = spy.seqs.items[1];
    try t.expect(second_seq > first_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"weather radar"}));
    try t.expectEqual(@as(usize, 4), p.list.visible.len);
    try t.expectEqualStrings("Google", p.list.visible[0].title);

    for (0..4) |_| tester.key(.backspace);
    try t.expectEqualStrings("wea", p.field.text());
    const third_seq = spy.seqs.getLast();
    try t.expect(third_seq > second_seq);

    try t.expect(!p.receiveSuggestionsFor(first_seq, "wea", &.{"stale weather"}));
    try t.expectEqual(@as(usize, 4), p.list.visible.len);

    try t.expect(p.receiveSuggestionsFor(third_seq, "wea", &.{}));
    try t.expectEqual(@as(usize, 4), p.list.visible.len);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    p.setWebSuggestionsEnabled(false);
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 0), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 4), p.list.visible.len);

    p.setWebSuggestionsEnabled(true);
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[0]);
    p.receiveSuggestions("weather", &.{"weather today"});
    try t.expectEqual(@as(usize, 5), p.list.visible.len);

    p.setWebSuggestionsEnabled(false);
    try t.expectEqual(@as(usize, 4), p.list.visible.len);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    p.receiveSuggestions("weather", &.{ "weather forecast", "weather radar" });
    try t.expectEqual(@as(usize, 6), p.list.visible.len);

    spy.hooks_base.clock.advance(299);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 1), spy.queries.items.len);
    try t.expectEqual(@as(usize, 6), p.list.visible.len);
    try t.expectEqualStrings("weather forecast", p.list.visible[1].title);
    try t.expectEqualStrings("weather radar", p.list.visible[2].title);

    spy.hooks_base.clock.advance(2);
    p.reset();
    tester.frame();
    tester.typeText("weather");
    try t.expectEqual(@as(usize, 2), spy.queries.items.len);
    try t.expectEqualStrings("weather", spy.queries.items[1]);
    try t.expectEqual(@as(usize, 4), p.list.visible.len);
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
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

const CountingHooks = struct {
    icon_calls: u32 = 0,
    date_calls: u32 = 0,

    fn request(_: ?*anyopaque) void {}

    fn icon(ctx: ?*anyopaque, _: []const u8) ?[]const u8 {
        const h_self: *CountingHooks = @ptrCast(@alignCast(ctx));
        h_self.icon_calls += 1;
        return null;
    }

    fn describeDate(ctx: ?*anyopaque, _: i64, _: std.mem.Allocator) []const u8 {
        const h_self: *CountingHooks = @ptrCast(@alignCast(ctx));
        h_self.date_calls += 1;
        return "Today at 9:41 AM";
    }

    fn detailedDate(_: ?*anyopaque, _: f64, _: std.mem.Allocator) []const u8 {
        return "Today at 9:41 AM";
    }

    fn hooks(h_self: *CountingHooks) panel_mod.Hooks {
        return .{ .ctx = h_self, .request = request, .app_icon = icon, .describe_date = describeDate, .detailed_date = detailedDate };
    }
};

test "rows out of view ask for no icon" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addNumberedApps(&cat, 60);
    var ch: CountingHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, ch.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    p.field.set("app");
    p.refresh();
    ch.icon_calls = 0;
    tester.frame();
    try t.expect(ch.icon_calls > 0);
    try t.expect(ch.icon_calls <= 12);
}

test "a date is described once per result set" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try tmpCatalog(&tmp, &buf, &files);
    defer files.close();
    defer cat.deinit();
    var ch: CountingHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, ch.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    p.field.set("t");
    p.refresh();
    const expected = countRows(p.list.visible, .file) + countRows(p.list.visible, .folder);
    try t.expect(expected > 0);
    tester.frame();
    tester.frame();
    tester.frame();
    try t.expectEqual(@as(u32, @intCast(expected)), ch.date_calls);
}

test "the selection scrolls into view from far below" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addNumberedApps(&cat, 60);
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("app");
    tester.settle(0.1);
    for (0..40) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.frame();
    try t.expectEqual(@as(usize, 40), p.list.selected);
    try t.expect(tester.hasText(p.list.visible[40].title));
}

test "the top hit stays the first row after scrolling back" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try addNumberedApps(&cat, 60);
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("app");
    tester.settle(0.1);
    const top_title = try t.allocator.dupe(u8, p.list.visible[0].title);
    defer t.allocator.free(top_title);

    for (0..40) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.frame();
    try t.expect(!tester.hasText("Top Hit"));

    for (0..40) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.up });
    tester.frame();
    try t.expectEqual(@as(usize, 0), p.list.selected);
    try t.expect(tester.hasText(top_title));
    try t.expect(tester.hasText("Top Hit"));
}

test "a late file row keeps its date" {
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
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    p.async_files = true;
    tester.typeText("return");
    tester.settle(0.1);
    try t.expect(p.files_due);
    const view = files.view().?;
    var hits: [search.max_file_hits]core.search.Hit = undefined;
    const hit_count = search.searchFiles(view, hooks.lastFileQuery(), &hits);
    p.landFiles(hooks.last_file_seq, view, hits[0..hit_count]);
    tester.frame();
    try t.expect(tester.hasText("2025-return.pdf"));
    try t.expect(tester.hasText("Today at 9:41 AM"));
}

fn manyFilesCatalog(tmp: *std.testing.TmpDir, buf: *[std.posix.PATH_MAX]u8, files: *core.file_index.FileIndex, count: usize) !search.Catalog {
    var name: [32]u8 = undefined;
    for (0..count) |i| {
        const sub = try std.fmt.bufPrint(&name, "item-{d:0>2}.txt", .{i});
        try tmp.dir.writeFile(t.io, .{ .sub_path = sub, .data = "hello" });
    }
    const root = buf[0..try tmp.dir.realPath(t.io, buf)];
    var cat: search.Catalog = .{ .gpa = t.allocator };
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    files.* = try .open(t.allocator, idx, root, .{});
    errdefer files.close();
    files.rebuild(.{ .ready = ignoreOutcome });
    try t.expect(files.adopt());
    cat.files = files;
    return cat;
}

test "a keystroke stats only the rows in view" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try manyFilesCatalog(&tmp, &buf, &files, 40);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("item");
    var stamped_count: usize = 0;
    for (p.list.visible) |r| stamped_count += @intFromBool(r.stamped);
    try t.expect(stamped_count > 0);
    try t.expect(stamped_count <= 12);
}

test "a row scrolled into view shows its size and date" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var files: core.file_index.FileIndex = undefined;
    var cat = try manyFilesCatalog(&tmp, &buf, &files, 40);
    defer files.close();
    defer cat.deinit();
    var hooks: StubHooks = .{};
    var p = panel_mod.Panel.init(t.allocator, &cat, null, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("item");
    try t.expect(!p.list.visible[30].stamped);
    for (0..30) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    tester.frame();
    try t.expect(p.list.visible[30].stamped);
    try t.expect(p.list.visible[30].modified != null);
    try t.expect(p.list.visible[30].modified_label.len > 0);
    try t.expectEqual(@as(?u64, 5), p.list.visible[30].size);
    try t.expect(tester.hasText("Today at 9:41 AM"));
}

test "bundle contents do not use result slots" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Fake.app/Contents");
    var name: [64]u8 = undefined;
    for (0..100) |i| {
        const sub = try std.fmt.bufPrint(&name, "Fake.app/Contents/match-{d:0>2}.txt", .{i});
        try tmp.dir.writeFile(t.io, .{ .sub_path = sub, .data = "" });
    }
    for (0..5) |i| {
        const sub = try std.fmt.bufPrint(&name, "match-{d:0>2}.txt", .{i});
        try tmp.dir.writeFile(t.io, .{ .sub_path = sub, .data = "" });
    }
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    var files = try core.file_index.FileIndex.open(t.allocator, idx, root, .{});
    defer files.close();
    files.rebuild(.{ .ready = ignoreOutcome });
    try t.expect(files.adopt());
    var cat: search.Catalog = .{ .gpa = t.allocator, .files = &files };
    defer cat.deinit();

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try cat.query(arena.allocator(), "match");
    var file_count: usize = 0;
    for (rows) |r| file_count += @intFromBool(r.kind == .file);
    try t.expectEqual(@as(usize, 5), file_count);
}

test "history completion is asked once per query" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    try store.recordQuery(.search, "calendar", 1000);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("cal");
    try t.expectEqualStrings("endar", p.completion.?.suffix);

    for (0..5) |i| try store.recordQuery(.search, "calculator", @floatFromInt(1001 + i));
    tester.frame();
    tester.frame();
    tester.frame();
    try t.expectEqualStrings("endar", p.completion.?.suffix);
}

test "a recorded query refreshes the completion" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    try store.recordQuery(.search, "calendar", 1000);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("cal");
    try t.expectEqualStrings("endar", p.completion.?.suffix);

    for (0..5) |i| try store.recordQuery(.search, "calculator", @floatFromInt(1001 + i));
    tester.key(.enter);
    p.pending = null;
    tester.frame();
    try t.expectEqualStrings("culator", p.completion.?.suffix);
}

test "a query with no history is asked once" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("zzz");
    try t.expect(p.completion == null);
    try store.recordQuery(.search, "zzzz", 1000);
    tester.frame();
    try t.expect(p.completion == null);

    p.clearField();
    tester.typeText("zzz");
    try t.expectEqualStrings("z", p.completion.?.suffix);
    try t.expectEqual(panel_mod.CompletionSource.history, p.completion.?.source);
}

test "clearing history clears the completion" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    try store.recordQuery(.search, "calendar", 1000);

    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var hooks: StubHooks = .{};
    hooks.clock.advance(1000);
    var p = panel_mod.Panel.init(t.allocator, &cat, &store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("cal");
    try t.expectEqualStrings("endar", p.completion.?.suffix);

    p.clearQueryHistory();
    try t.expect(p.completion == null);
    p.clearField();
    tester.typeText("cal");
    try t.expect(p.completion == null);
}

test "app rows show before file rows land" {
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
    p.async_files = true;

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("a");
    tester.frame();
    try t.expectEqual(@as(u32, 1), hooks.file_searches);
    try t.expectEqual(@as(usize, 2), countRows(p.list.visible, .app));
    try t.expectEqual(@as(usize, 0), countRows(p.list.visible, .file));

    const view = files.view().?;
    var hits: [search.max_file_hits]core.search.Hit = undefined;
    const hit_count = search.searchFiles(view, hooks.lastFileQuery(), &hits);
    p.landFiles(hooks.last_file_seq, view, hits[0..hit_count]);
    try t.expect(countRows(p.list.visible, .file) > 0);
}

test "a late answer for an old query is dropped" {
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
    p.async_files = true;

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("re");
    tester.frame();
    const old_seq = hooks.last_file_seq;
    const view = files.view().?;
    var old_hits: [search.max_file_hits]core.search.Hit = undefined;
    const old_count = search.searchFiles(view, "re", &old_hits);
    try t.expect(old_count > 0);

    tester.typeText("z");
    tester.frame();
    try t.expect(hooks.last_file_seq != old_seq);
    const before_len = p.list.visible.len;

    p.landFiles(old_seq, view, old_hits[0..old_count]);
    try t.expectEqual(@as(usize, 0), countRows(p.list.visible, .file));
    try t.expectEqual(before_len, p.list.visible.len);
    try t.expectEqualStrings("rez", p.list.answered());
    try t.expect(p.files_due);
}

test "late file rows keep the selection" {
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
    p.async_files = true;

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("a");
    tester.frame();
    try t.expect(p.list.visible.len >= 3);
    p.list.selected = 2;
    const chosen_path = try t.allocator.dupe(u8, p.list.visible[2].path);
    defer t.allocator.free(chosen_path);

    const view = files.view().?;
    var hits: [search.max_file_hits]core.search.Hit = undefined;
    const hit_count = search.searchFiles(view, hooks.lastFileQuery(), &hits);
    p.landFiles(hooks.last_file_seq, view, hits[0..hit_count]);

    try t.expect(countRows(p.list.visible, .file) > 0);
    try t.expectEqualStrings(chosen_path, p.list.selection().?.path);
    try t.expect(p.list.selected > 2);
}

test "an index is not swapped while a search runs" {
    var gate: search.AdoptGate = .{};
    try t.expect(!gate.requestAdopt(true));
    try t.expect(gate.pending);
    try t.expect(!gate.takeAfterSearch(true));
    try t.expect(gate.pending);
    try t.expect(gate.takeAfterSearch(false));
    try t.expect(!gate.pending);
    try t.expect(!gate.takeAfterSearch(false));
    try t.expect(gate.requestAdopt(false));
    try t.expect(!gate.pending);
}

test "the worker searches only the newest waiting query" {
    const Ctx = struct {
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        entered: std.Io.Semaphore = .{ .permits = 0 },
        gate: std.Io.Semaphore = .{ .permits = 0 },
        done: std.Io.Semaphore = .{ .permits = 0 },
        seen: [8][64]u8 = undefined,
        seen_lens: [8]usize = @splat(0),
        seen_count: usize = 0,

        fn searchFn(raw: ?*anyopaque, _: core.index.View, text: []const u8, _: []core.search.Hit) usize {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.mutex.lockUncancelable(c.io);
            const idx = c.seen_count;
            c.seen_count += 1;
            const n = @min(text.len, 64);
            @memcpy(c.seen[idx][0..n], text[0..n]);
            c.seen_lens[idx] = n;
            c.mutex.unlock(c.io);
            if (idx == 0) {
                c.entered.post(c.io);
                c.gate.waitUncancelable(c.io);
            }
            return 0;
        }

        fn readyFn(raw: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.done.post(c.io);
        }
    };

    var ctx: Ctx = .{ .io = t.io };
    var searcher: search.FileSearcher = .{
        .io = t.io,
        .search_ctx = &ctx,
        .search_fn = Ctx.searchFn,
        .ready_ctx = &ctx,
        .ready_fn = Ctx.readyFn,
    };
    try searcher.start();
    defer searcher.stop();

    const empty_view: core.index.View = .{
        .path_mask = &.{},
        .name_mask = &.{},
        .parent = &.{},
        .name_off = &.{},
        .name_len = &.{},
        .flags = &.{},
        .depth = &.{},
        .names = &.{},
        .root = "",
    };

    searcher.submit(1, empty_view, "first");
    ctx.entered.waitUncancelable(t.io);
    searcher.submit(2, empty_view, "second");
    searcher.submit(3, empty_view, "third");
    ctx.gate.post(t.io);

    ctx.done.waitUncancelable(t.io);
    ctx.done.waitUncancelable(t.io);

    ctx.mutex.lockUncancelable(t.io);
    defer ctx.mutex.unlock(t.io);
    try t.expectEqual(@as(usize, 2), ctx.seen_count);
    try t.expectEqualStrings("first", ctx.seen[0][0..ctx.seen_lens[0]]);
    try t.expectEqualStrings("third", ctx.seen[1][0..ctx.seen_lens[1]]);
    try t.expectEqual(@as(u64, 3), searcher.takeResult().result.?.seq);
}

test "the synchronous path still returns file rows" {
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
    try t.expect(!p.async_files);

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();

    tester.typeText("return");
    tester.frame();
    try t.expect(!p.files_due);
    try t.expectEqual(@as(u32, 0), hooks.file_searches);
    try t.expect(countRows(p.list.visible, .file) > 0);
}

test "a one-byte query asks for no suggestions, a two-byte query and a single CJK character do" {
    var cat: search.Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    var spy: SuggestSpy = .{};
    defer spy.deinit();
    var p = panel_mod.Panel.init(t.allocator, &cat, null, spy.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&p, panel_mod.Panel.view), .{ .width = chrome.metrics.width, .height = chrome.metrics.expanded_height });
    defer tester.deinit();
    tester.settle(0.1);

    tester.typeText("w");
    try t.expectEqual(@as(usize, 0), spy.queries.items.len);

    p.reset();
    tester.frame();
    tester.typeText("we");
    try t.expectEqualStrings("we", spy.queries.getLast());

    p.reset();
    tester.frame();
    tester.typeText("\u{5929}");
    try t.expectEqualStrings("\u{5929}", spy.queries.getLast());
}
