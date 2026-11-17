//! In-process latency benchmark for `Panel` over a 200-app catalog.
//! Measures `keystroke → publication`, `hot key → laid-out frame`, and
//! `Return → action`, prints `p50` and `p99` in microseconds, and exits
//! non-zero when a `p99` exceeds its budget.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("floodlight_core");
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const panel_mod = @import("panel.zig");
const mac = @import("mac.zig");
const presence = @import("presence.zig");
const chrome = @import("chrome.zig");

const RetainedShell = struct {
    panel: *panel_mod.Panel,

    fn run(ctx: ?*anyopaque, e: presence.Effect) void {
        const s: *RetainedShell = @ptrCast(@alignCast(ctx));
        switch (e) {
            .open_search => s.panel.showSearch(),
            .end_session => s.panel.hide(),
            else => {},
        }
    }

    fn lastFrameValid(ctx: ?*anyopaque) bool {
        const s: *RetainedShell = @ptrCast(@alignCast(ctx));
        return s.panel.lastFrameValid();
    }

    fn presence_(s: *RetainedShell) presence.Presence {
        return .{ .effects = .{ .ctx = s, .run = run, .last_frame_valid = lastFrameValid } };
    }
};

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const qos_class_user_interactive: c_uint = 0x21;
const clock_uptime_raw: c_int = 8;

fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

pub const catalog_app_count: usize = 200;
pub const default_runs: usize = 2000;

/// Today's measured p99 plus headroom; issue #143 ("Instant reopen") lowers all three to 10 µs.
pub const Budgets = struct {
    pub const keystroke_to_publication_p99_us: f64 = 10.0;
    pub const hotkey_to_laid_out_frame_p99_us: f64 = 10.0;
    pub const return_to_action_p99_us: f64 = 10.0;
    pub const keystroke_to_built_frame_p99_us: f64 = 6200.0;
    pub const first_frame_with_icons_p99_us: f64 = 560000.0;
    pub const hotkey_to_built_frame_p99_us: f64 = 1500.0;
};

pub const Stats = struct {
    p50_ns: u64,
    p99_ns: u64,
    runs: usize,

    pub fn p50Us(s: Stats) f64 {
        return @as(f64, @floatFromInt(s.p50_ns)) / 1e3;
    }

    pub fn p99Us(s: Stats) f64 {
        return @as(f64, @floatFromInt(s.p99_ns)) / 1e3;
    }
};

const app_stems = [_][]const u8{
    "Calculator",
    "Calendar",
    "Safari",
    "System Settings",
    "Terminal",
    "Activity Monitor",
    "Notes",
    "Preview",
    "Finder",
    "Music",
    "Photos",
    "Messages",
    "Mail",
    "Reminders",
    "Maps",
    "Keynote",
    "Numbers",
    "Pages",
    "Xcode",
    "Console",
};

const keystroke_queries = [_][]const u8{
    "c",
    "ca",
    "cal",
    "calc",
    "s",
    "sa",
    "saf",
    "t",
    "te",
    "ter",
    "x",
    "xc",
    "n",
    "no",
    "not",
    "p",
    "pr",
    "pre",
    "m",
    "mu",
};

const NoHooks = struct {
    submitted: usize = 0,
    handed_ns: u64 = 0,
    panel: ?*panel_mod.Panel = null,

    fn request(ctx: ?*anyopaque) void {
        const h: *NoHooks = @ptrCast(@alignCast(ctx orelse return));
        const p = h.panel orelse return;
        const a = p.pending orelse return;
        if (a != .hide) {
            mac.signpostBegin(.submit);
            h.submitted += 1;
            h.handed_ns = nowNs();
            p.pending = null;
            mac.signpostEnd(.submit);
        }
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
    fn hooks(h: ?*NoHooks) panel_mod.Hooks {
        return .{ .ctx = h, .request = request, .app_icon = icon, .describe_date = date, .detailed_date = detailed };
    }
};

pub fn populateCatalog(cat: *search.Catalog, count: usize) !void {
    for (0..count) |i| {
        const stem = app_stems[i % app_stems.len];
        const tier = i / app_stems.len;
        const path = if (tier == 0)
            try std.fmt.allocPrint(cat.gpa, "/Applications/{s}.app", .{stem})
        else
            try std.fmt.allocPrint(cat.gpa, "/Applications/{s} {d}.app", .{ stem, tier });
        try cat.addApp(path);
    }
}

fn summarize(samples: []u64) Stats {
    std.sort.pdq(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;
    const p99_idx = @min(n - 1, (n * 99) / 100);
    return .{
        .p50_ns = samples[n / 2],
        .p99_ns = samples[p99_idx],
        .runs = n,
    };
}

pub fn measureKeystrokeToPublication(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var p = panel_mod.Panel.init(gpa, &cat, null, NoHooks.hooks(null));
    defer p.deinit();

    // Warm the arena and instruction cache so samples measure steady-state keystrokes.
    for (keystroke_queries) |q| {
        p.field.set(q);
        p.refresh();
        if (p.list.visible.len == 0) return error.EmptyPublication;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const q = keystroke_queries[i % keystroke_queries.len];
        const t0 = nowNs();
        p.field.set(q);
        p.refresh();
        s.* = nowNs() - t0;
        if (p.list.visible.len == 0) return error.EmptyPublication;
    }
    return summarize(samples);
}

pub fn measureHotKeyToLaidOutFrame(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var p = panel_mod.Panel.init(gpa, &cat, null, NoHooks.hooks(null));
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&p, panel_mod.Panel.view), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    var shell: RetainedShell = .{ .panel = &p };
    var entrance = shell.presence_();
    // Warm glyph metrics and layout tables before timing reopen frames.
    for (keystroke_queries) |q| {
        try presentThenHide(&p, &tester, &entrance, q);
        entrance.search(false, false);
        if (entrance.phase != .shown) return error.EntranceWaited;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        try presentThenHide(&p, &tester, &entrance, keystroke_queries[i % keystroke_queries.len]);
        const t0 = nowNs();
        entrance.search(false, false);
        s.* = nowNs() - t0;
        if (entrance.phase != .shown) return error.EntranceWaited;
    }
    return summarize(samples);
}

fn presentThenHide(p: *panel_mod.Panel, tester: *ui.Tester, entrance: *presence.Presence, query: []const u8) !void {
    if (entrance.isHidden()) entrance.search(false, false);
    p.field.set(query);
    p.refresh();
    tester.frame();
    if (tester.ctx.nodes.items.len == 0) return error.EmptyFrame;
    p.notePresented();
    _ = entrance.framePresented(true);
    entrance.search(true, false);
}

pub fn measureReturnToAction(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var hooks: NoHooks = .{};
    var p = panel_mod.Panel.init(gpa, &cat, null, NoHooks.hooks(&hooks));
    defer p.deinit();
    hooks.panel = &p;

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&p, panel_mod.Panel.view), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    p.field.set("cal");
    p.refresh();
    tester.frame();

    for (0..8) |_| {
        const before = hooks.submitted;
        tester.key(.enter);
        if (hooks.submitted == before) return error.NoActionSubmitted;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples) |*s| {
        const before = hooks.submitted;
        const t0 = nowNs();
        tester.key(.enter);
        if (hooks.submitted == before) return error.NoActionSubmitted;
        s.* = hooks.handed_ns - t0;
    }
    return summarize(samples);
}

pub const file_count: usize = 2000;
pub const frame_runs: usize = 200;
pub const icon_runs: usize = 20;

const file_extensions = [_][]const u8{ ".pdf", ".txt", ".png", ".zig" };

/// Hooks for the built-frame metrics: real dates, and icons that are either
/// absent or rendered by the system on every request, with no cache.
const FrameHooks = struct {
    gpa: std.mem.Allocator,
    render_icons: bool,
    icons: std.ArrayList([]u8) = .empty,

    fn deinit(h: *FrameHooks) void {
        for (h.icons.items) |png| h.gpa.free(png);
        h.icons.deinit(h.gpa);
    }

    fn request(_: ?*anyopaque) void {}

    fn icon(ctx: ?*anyopaque, path: []const u8) ?[]const u8 {
        const h: *FrameHooks = @ptrCast(@alignCast(ctx orelse return null));
        if (!h.render_icons) return null;
        const png = mac.iconPng(h.gpa, path, 92) orelse return null;
        h.icons.append(h.gpa, png) catch {
            h.gpa.free(png);
            return null;
        };
        return png;
    }

    fn date(_: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 {
        return mac.relativeDate(secs, arena);
    }

    fn detailed(_: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 {
        return mac.detailedDate(secs, arena);
    }

    fn hooks(h: *FrameHooks) panel_mod.Hooks {
        return .{ .ctx = h, .request = request, .app_icon = icon, .describe_date = date, .detailed_date = detailed };
    }
};

/// A 200-app catalog with a real 2,000-file index and a clipboard store that
/// has seen every benchmark query, so a keystroke pays for all three sources.
const Fixture = struct {
    gpa: std.mem.Allocator,
    root: []u8,
    cat: search.Catalog,
    files: core.file_index.FileIndex,
    store: clipboard.Store,

    fn init(f: *Fixture, gpa: std.mem.Allocator) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        f.gpa = gpa;
        f.root = try std.fmt.allocPrint(gpa, "/tmp/floodlight-bench-{d}", .{std.c.getpid()});
        errdefer gpa.free(f.root);
        std.Io.Dir.cwd().deleteTree(io, f.root) catch {};
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, f.root, .{});
        defer dir.close(io);
        errdefer std.Io.Dir.cwd().deleteTree(io, f.root) catch {};
        var name: [96]u8 = undefined;
        for (0..file_count) |i| {
            const stem = app_stems[i % app_stems.len];
            const ext = file_extensions[i % file_extensions.len];
            const sub = try std.fmt.bufPrint(&name, "{s} {d}{s}", .{ stem, i, ext });
            try dir.writeFile(io, .{ .sub_path = sub, .data = "" });
        }

        f.cat = .{ .gpa = gpa };
        errdefer f.cat.deinit();
        try populateCatalog(&f.cat, catalog_app_count);

        const index_path = try std.fs.path.join(gpa, &.{ f.root, "names.flix" });
        defer gpa.free(index_path);
        f.files = try .open(gpa, index_path, f.root, .{});
        errdefer f.files.close();
        f.files.rebuild(.{ .ready = ignoreOutcome });
        if (!f.files.adopt()) return error.FileIndexNotBuilt;
        f.cat.files = &f.files;

        f.store = try .open(":memory:", f.root);
        errdefer f.store.close();
        for (keystroke_queries) |q| try f.store.recordQuery(.search, q, 1);
    }

    fn deinit(f: *Fixture) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        f.store.close();
        f.files.close();
        f.cat.deinit();
        std.Io.Dir.cwd().deleteTree(io, f.root) catch {};
        f.gpa.free(f.root);
    }
};

fn ignoreOutcome(_: ?*anyopaque, _: core.file_index.Outcome) void {}

fn measureBuiltFrame(gpa: std.mem.Allocator, runs: usize, render_icons: bool, warm: bool) !Stats {
    var fx: Fixture = undefined;
    try fx.init(gpa);
    defer fx.deinit();

    var hooks: FrameHooks = .{ .gpa = gpa, .render_icons = render_icons };
    defer hooks.deinit();
    var p = panel_mod.Panel.init(gpa, &fx.cat, &fx.store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&p, panel_mod.Panel.view), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    if (warm) for (keystroke_queries) |q| {
        p.field.set(q);
        p.refresh();
        tester.frame();
        if (p.list.visible.len == 0) return error.EmptyPublication;
    };

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const q = keystroke_queries[i % keystroke_queries.len];
        const t0 = nowNs();
        p.field.set(q);
        p.refresh();
        tester.frame();
        s.* = nowNs() - t0;
        if (p.list.visible.len == 0) return error.EmptyPublication;
    }
    return summarize(samples);
}

pub fn measureKeystrokeToBuiltFrame(gpa: std.mem.Allocator, runs: usize) !Stats {
    return measureBuiltFrame(gpa, runs, false, true);
}

pub fn measureFirstFrameWithIcons(gpa: std.mem.Allocator, runs: usize) !Stats {
    return measureBuiltFrame(gpa, runs, true, false);
}

pub fn measureHotKeyToBuiltFrame(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var p = panel_mod.Panel.init(gpa, &cat, null, NoHooks.hooks(null));
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&p, panel_mod.Panel.view), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    var shell: RetainedShell = .{ .panel = &p };
    var entrance = shell.presence_();
    for (keystroke_queries) |q| {
        try presentThenHide(&p, &tester, &entrance, q);
        entrance.search(false, false);
        tester.frame();
        if (entrance.phase != .shown) return error.EntranceWaited;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        try presentThenHide(&p, &tester, &entrance, keystroke_queries[i % keystroke_queries.len]);
        const t0 = nowNs();
        entrance.search(false, false);
        tester.frame();
        s.* = nowNs() - t0;
        if (entrance.phase != .shown) return error.EntranceWaited;
    }
    return summarize(samples);
}

pub fn withinBudgets(keystroke: Stats, summon: Stats, submit: Stats) bool {
    return keystroke.p99Us() <= Budgets.keystroke_to_publication_p99_us and
        summon.p99Us() <= Budgets.hotkey_to_laid_out_frame_p99_us and
        submit.p99Us() <= Budgets.return_to_action_p99_us;
}

pub fn withinFrameBudgets(built: Stats, icons: Stats, summon: Stats) bool {
    return built.p99Us() <= Budgets.keystroke_to_built_frame_p99_us and
        icons.p99Us() <= Budgets.first_frame_with_icons_p99_us and
        summon.p99Us() <= Budgets.hotkey_to_built_frame_p99_us;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var out_buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &fw.interface;

    _ = pthread_set_qos_class_self_np(qos_class_user_interactive, 0);
    const keystroke = try measureKeystrokeToPublication(gpa, default_runs);
    const summon = try measureHotKeyToLaidOutFrame(gpa, default_runs);
    const submit = try measureReturnToAction(gpa, default_runs);
    const built = try measureKeystrokeToBuiltFrame(gpa, frame_runs);
    const icons = try measureFirstFrameWithIcons(gpa, icon_runs);
    const built_summon = try measureHotKeyToBuiltFrame(gpa, default_runs);

    try out.print(
        "FLOODLIGHT_BENCH metric=keystroke_to_publication apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, keystroke.runs, keystroke.p50Us(), keystroke.p99Us(), Budgets.keystroke_to_publication_p99_us },
    );
    try out.print(
        "FLOODLIGHT_BENCH metric=hotkey_to_laid_out_frame apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, summon.runs, summon.p50Us(), summon.p99Us(), Budgets.hotkey_to_laid_out_frame_p99_us },
    );
    try out.print(
        "FLOODLIGHT_BENCH metric=return_to_action apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, submit.runs, submit.p50Us(), submit.p99Us(), Budgets.return_to_action_p99_us },
    );
    try out.print(
        "FLOODLIGHT_BENCH metric=keystroke_to_built_frame apps={d} files={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, file_count, built.runs, built.p50Us(), built.p99Us(), Budgets.keystroke_to_built_frame_p99_us },
    );
    try out.print(
        "FLOODLIGHT_BENCH metric=first_frame_with_icons apps={d} files={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, file_count, icons.runs, icons.p50Us(), icons.p99Us(), Budgets.first_frame_with_icons_p99_us },
    );
    try out.print(
        "FLOODLIGHT_BENCH metric=hotkey_to_built_frame apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, built_summon.runs, built_summon.p50Us(), built_summon.p99Us(), Budgets.hotkey_to_built_frame_p99_us },
    );
    try out.flush();

    var failed = false;
    if (built.p99Us() > Budgets.keystroke_to_built_frame_p99_us) {
        std.log.err(
            "keystroke -> built frame p99 {d:.2} us exceeds budget {d:.2} us",
            .{ built.p99Us(), Budgets.keystroke_to_built_frame_p99_us },
        );
        failed = true;
    }
    if (icons.p99Us() > Budgets.first_frame_with_icons_p99_us) {
        std.log.err(
            "first frame with icons p99 {d:.2} us exceeds budget {d:.2} us",
            .{ icons.p99Us(), Budgets.first_frame_with_icons_p99_us },
        );
        failed = true;
    }
    if (built_summon.p99Us() > Budgets.hotkey_to_built_frame_p99_us) {
        std.log.err(
            "hot key -> built frame p99 {d:.2} us exceeds budget {d:.2} us",
            .{ built_summon.p99Us(), Budgets.hotkey_to_built_frame_p99_us },
        );
        failed = true;
    }
    if (keystroke.p99Us() > Budgets.keystroke_to_publication_p99_us) {
        std.log.err(
            "keystroke -> publication p99 {d:.2} us exceeds budget {d:.2} us",
            .{ keystroke.p99Us(), Budgets.keystroke_to_publication_p99_us },
        );
        failed = true;
    }
    if (summon.p99Us() > Budgets.hotkey_to_laid_out_frame_p99_us) {
        std.log.err(
            "hot key -> laid-out frame p99 {d:.2} us exceeds budget {d:.2} us",
            .{ summon.p99Us(), Budgets.hotkey_to_laid_out_frame_p99_us },
        );
        failed = true;
    }
    if (submit.p99Us() > Budgets.return_to_action_p99_us) {
        std.log.err(
            "Return -> action p99 {d:.2} us exceeds budget {d:.2} us",
            .{ submit.p99Us(), Budgets.return_to_action_p99_us },
        );
        failed = true;
    }
    if (failed) std.process.exit(1);
}
