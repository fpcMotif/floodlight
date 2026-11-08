//! In-process latency benchmark for `Panel` over a 200-app catalog.
//! Measures `keystroke → publication`, `hot key → laid-out frame`, and
//! `Return → action`, prints `p50` and `p99` in microseconds, and exits
//! non-zero when a `p99` exceeds its budget.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const panel_mod = @import("panel.zig");
const mac = @import("mac.zig");
const presence = @import("presence.zig");
const chrome = @import("chrome.zig");

fn noEffect(_: ?*anyopaque, _: presence.Effect) void {}

/// A hidden panel whose effects do nothing: only its summon signposts run.
fn hiddenPresence() presence.Presence {
    return .{ .effects = .{ .ctx = null, .run = noEffect } };
}

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
const clock_uptime_raw: c_int = 8;

fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

pub const catalog_app_count: usize = 200;
pub const default_runs: usize = 200;

/// Today's measured p99 plus headroom; issue #143 ("Instant reopen") lowers all three to 10 µs.
pub const Budgets = struct {
    pub const keystroke_to_publication_p99_us: f64 = 35.0;
    pub const hotkey_to_laid_out_frame_p99_us: f64 = 450.0;
    pub const return_to_action_p99_us: f64 = 25.0;
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

    // Warm glyph metrics and layout tables before timing reopen frames.
    for (keystroke_queries) |q| {
        p.reset();
        var entrance = hiddenPresence();
        entrance.search(false, false);
        p.field.set(q);
        p.refresh();
        tester.frame();
        _ = entrance.framePresented(true);
        if (tester.ctx.nodes.items.len == 0) return error.EmptyFrame;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const q = keystroke_queries[i % keystroke_queries.len];
        p.reset();
        var entrance = hiddenPresence();
        const t0 = nowNs();
        entrance.search(false, false);
        p.field.set(q);
        p.refresh();
        tester.frame();
        _ = entrance.framePresented(true);
        s.* = nowNs() - t0;
        if (tester.ctx.nodes.items.len == 0) return error.EmptyFrame;
    }
    return summarize(samples);
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

pub fn withinBudgets(keystroke: Stats, summon: Stats, submit: Stats) bool {
    return keystroke.p99Us() <= Budgets.keystroke_to_publication_p99_us and
        summon.p99Us() <= Budgets.hotkey_to_laid_out_frame_p99_us and
        submit.p99Us() <= Budgets.return_to_action_p99_us;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var out_buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &fw.interface;

    const keystroke = try measureKeystrokeToPublication(gpa, default_runs);
    const summon = try measureHotKeyToLaidOutFrame(gpa, default_runs);
    const submit = try measureReturnToAction(gpa, default_runs);

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
    try out.flush();

    var failed = false;
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
