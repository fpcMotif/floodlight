//! `zig build screens -- DIR`: the search panel, its result list, the
//! clipboard board and the grant panel, drawn offscreen in both appearances
//! and written to DIR as PNG. Every row comes from a fixture home, so the
//! pictures can be published. No glass: the theme's background stands in.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const panel_mod = @import("panel.zig");
const permission = @import("permission.zig");
const mac = @import("mac.zig");
const chrome = @import("chrome.zig");

const gpa = std.heap.c_allocator;
const metrics = chrome.metrics;

const home_files = [_][]const u8{
    "Documents/Calendar Export 2026.pdf",
    "Documents/Budget/calculations.numbers",
    "Documents/Call Notes.md",
    "Desktop/Calgary Itinerary.pdf",
    "Pictures/calibration-chart.png",
    "Projects/nanospot/calendar.zig",
    "Projects/calc/README.md",
};

const frequent_apps = [_][]const u8{ "Safari", "Notes", "Calendar", "Maps", "Music", "Photos" };

const clips = [_][]const u8{
    "Meeting moved to 3pm, room 4B. Bring the Q3 numbers and the draft plan.",
    "#3478f6",
    "https://developer.apple.com/documentation/metal/mtldevice",
    "/System/Applications/Calendar.app",
    "const index = try FileIndex.open(gpa, path, home, .{});\ndefer index.close();\nconst hits = index.search(query, &out);",
};

const Stage = struct {
    out: []const u8,
    cat: search.Catalog,
    store: clipboard.Store,
    icons: std.StringHashMapUnmanaged([]u8) = .empty,

    fn hooks(s: *Stage) panel_mod.Hooks {
        return .{ .ctx = s, .request = ignoreRequest, .app_icon = appIcon, .describe_date = describeDate, .detailed_date = detailedDate };
    }

    fn ignoreRequest(_: ?*anyopaque) void {}

    fn appIcon(ctx: ?*anyopaque, path: []const u8) ?[]const u8 {
        const s: *Stage = @ptrCast(@alignCast(ctx));
        if (s.icons.get(path)) |png| return png;
        const png = mac.iconPng(gpa, path, metrics.top_hit_icon_size * 2) orelse return null;
        const key = gpa.dupe(u8, path) catch {
            gpa.free(png);
            return null;
        };
        s.icons.put(gpa, key, png) catch {
            gpa.free(key);
            gpa.free(png);
            return null;
        };
        return png;
    }

    fn deinitIcons(s: *Stage) void {
        var it = s.icons.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        s.icons.deinit(gpa);
    }

    fn describeDate(_: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 {
        return mac.relativeDate(secs, arena);
    }

    fn detailedDate(_: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 {
        return mac.detailedDate(secs, arena);
    }

    fn write(s: *Stage, t: *ui.Tester, name: []const u8, dark: bool) !void {
        t.settle(1);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ s.out, name, if (dark) "dark" else "light" });
        defer gpa.free(path);
        try t.screenshot(path);
    }

    /// The panel as the hot key shows it, then with `query` typed.
    fn panel(s: *Stage, dark: bool, board: bool, name: []const u8, query: []const u8) !void {
        var p = panel_mod.Panel.init(gpa, &s.cat, &s.store, s.hooks());
        defer p.deinit();
        if (board) p.showClipboard() else p.showSearch();
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&p, panel_mod.Panel.view), .{ .width = metrics.width, .height = metrics.expanded_height, .dark = dark });
        defer t.deinit();
        if (query.len > 0) t.typeText(query);
        t.settle(1);
        t.resize(p.panelWidth(), p.panelHeight());
        try s.write(&t, name, dark);
    }

    fn grant(s: *Stage, dark: bool, phase: permission.Phase, name: []const u8) !void {
        var g: permission.Grant = .{ .phase = phase, .icon_png = @embedFile("app_icon_png") };
        var t: ui.Tester = undefined;
        try t.init(gpa, g.view(), .{ .width = permission.panel_w, .height = permission.panel_h, .dark = dark });
        defer t.deinit();
        try s.write(&t, name, dark);
    }
};

fn seedClipboard(store: clipboard.Store) !void {
    const now = clipboard.wallClock();
    const minute = 60;
    for (clips, 0..) |text, i| {
        const age: f64 = @floatFromInt((clips.len - i) * 7 * minute);
        _ = try store.add(.{ .text = text }, "com.apple.Notes", "Notes", now - age);
    }
    const from = "/System/Applications/Photos.app";
    const png = mac.iconPng(gpa, from, 1024) orelse return;
    defer gpa.free(png);
    const thumbnail = mac.iconPng(gpa, from, 128) orelse return;
    defer gpa.free(thumbnail);
    const image: clipboard.Capture.Image = .{ .name = "Screenshot", .png = png, .thumbnail = thumbnail, .width = 1024, .height = 1024 };
    _ = try store.add(.{ .image = image }, "com.apple.screencaptureui", "Screenshot", now - 3 * minute);
    _ = try store.add(.{ .text = "Ship the nanoui board before Friday's review." }, "com.apple.Notes", "Notes", now - minute);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.NoOutputDir;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);

    const tmp = std.mem.trimEnd(u8, std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp"), "/");
    const home = try std.fmt.allocPrint(gpa, "{s}/nanospot-screens-{d}", .{ tmp, std.c.getpid() });
    defer gpa.free(home);
    defer cwd.deleteTree(io, home) catch {};
    for (home_files) |file| {
        const path = try std.fs.path.join(gpa, &.{ home, file });
        defer gpa.free(path);
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        try cwd.writeFile(io, .{ .sub_path = path, .data = "fixture" });
    }

    const images_dir = try std.fs.path.join(gpa, &.{ home, "images" });
    defer gpa.free(images_dir);
    var stage: Stage = .{
        .out = args[1],
        .cat = .{ .gpa = gpa },
        .store = try clipboard.Store.open(":memory:", images_dir),
    };
    defer stage.store.close();
    defer stage.cat.deinit();
    defer stage.deinitIcons();
    const idx_path = try std.fs.path.join(gpa, &.{ home, "names.flix" });
    defer gpa.free(idx_path);
    try stage.cat.buildIndex(idx_path, home);
    for ([_][]const u8{ "/System/Applications", "/System/Applications/Utilities" }) |folder| try search.scanApps(&stage.cat, io, folder);
    try seedClipboard(stage.store);
    for (frequent_apps, 0..) |app, i| {
        const path = try std.fmt.allocPrint(gpa, "/System/Applications/{s}.app", .{app});
        defer gpa.free(path);
        for (0..frequent_apps.len - i) |_| try stage.store.recordAppOpen(path, clipboard.wallClock());
    }

    for ([_]bool{ false, true }) |dark| {
        try stage.panel(dark, false, "search", "");
        try stage.panel(dark, false, "list", "cal");
        try stage.panel(dark, false, "list-web", "zzqx");
        try stage.panel(dark, true, "board", "");
        try stage.grant(dark, .guiding, "permission");
        try stage.grant(dark, .granted, "permission-granted");
    }
}
