//! In-process latency benchmark for `Panel` over a 200-app catalog.
//! Measures `keystroke → publication`, `hot key → laid-out frame`, and
//! `Return → action`, prints `p50` and `p99` in microseconds, and exits
//! non-zero when a `p99` exceeds its budget.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("nanospot_core");
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");
const panel_mod = @import("panel.zig");
const shell_mod = @import("shell.zig");
const mac = @import("mac.zig");
const chrome = @import("chrome.zig");
const icons_mod = @import("icons.zig");

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const qos_class_user_interactive: c_uint = 0x21;
const clock_uptime_raw: c_int = 8;

fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

pub const catalog_app_count: usize = 200;
pub const default_runs: usize = 2000;

/// p99 latency budgets enforced by `zig build bench --release` (microseconds).
pub const Budgets = struct {
    pub const keystroke_to_publication_p99_us: f64 = 10.0;
    pub const hotkey_to_laid_out_frame_p99_us: f64 = 10.0;
    pub const return_to_action_p99_us: f64 = 10.0;
    pub const keystroke_to_built_frame_p99_us: f64 = 4300.0;
    pub const first_frame_with_icons_p99_us: f64 = 8000.0;
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

const SubmitSpy = struct {
    submitted: usize = 0,
    requested_ns: u64 = 0,
    handed_ns: u64 = 0,

    fn onRequest(ctx: ?*anyopaque) void {
        const spy: *SubmitSpy = @ptrCast(@alignCast(ctx));
        spy.requested_ns = nowNs();
    }

    fn open(ctx: ?*anyopaque, _: []const u8) void {
        const spy: *SubmitSpy = @ptrCast(@alignCast(ctx));
        spy.submitted += 1;
        spy.handed_ns = nowNs();
    }

    fn host(spy: *SubmitSpy) shell_mod.Host {
        return .{ .ctx = spy, .on_request = onRequest, .open = open };
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

    var sh: shell_mod.Shell = undefined;
    sh.init(gpa, &cat, null, .{});
    defer sh.deinit();
    const p = &sh.panel;

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

    var sh: shell_mod.Shell = undefined;
    sh.init(gpa, &cat, null, .{});
    defer sh.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, sh.view(), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    // Warm glyph metrics and layout tables before timing reopen frames.
    for (keystroke_queries) |q| {
        try presentThenHide(&sh, &tester, q);
        _ = sh.hotKey(.search, false);
        if (sh.presence.phase != .shown) return error.EntranceWaited;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        try presentThenHide(&sh, &tester, keystroke_queries[i % keystroke_queries.len]);
        const t0 = nowNs();
        _ = sh.hotKey(.search, false);
        s.* = nowNs() - t0;
        if (sh.presence.phase != .shown) return error.EntranceWaited;
    }
    return summarize(samples);
}

fn presentThenHide(sh: *shell_mod.Shell, tester: *ui.Tester, query: []const u8) !void {
    if (sh.isHidden()) _ = sh.hotKey(.search, false);
    sh.panel.field.set(query);
    sh.panel.refresh();
    tester.frame();
    if (tester.ctx.nodes.items.len == 0) return error.EmptyFrame;
    _ = sh.framePresented(true);
    _ = sh.hotKey(.search, true);
}

pub fn measureReturnToAction(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var spy: SubmitSpy = .{};
    var sh: shell_mod.Shell = undefined;
    sh.init(gpa, &cat, null, spy.host());
    defer sh.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, sh.view(), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    sh.panel.field.set("cal");
    sh.panel.refresh();
    tester.frame();

    for (0..8) |_| {
        const before = spy.submitted;
        tester.key(.enter);
        dispatchAction(&sh, sh.applyPending());
        if (spy.submitted == before) return error.NoActionSubmitted;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples) |*s| {
        const before = spy.submitted;
        const t0 = nowNs();
        tester.key(.enter);
        const t1 = nowNs();
        dispatchAction(&sh, sh.applyPending());
        if (spy.submitted == before) return error.NoActionSubmitted;
        s.* = (spy.requested_ns - t0) + (spy.handed_ns - t1);
    }
    return summarize(samples);
}

fn dispatchAction(sh: *shell_mod.Shell, out: shell_mod.Outcome) void {
    switch (out.action) {
        .none => {},
        .open => |path| sh.host.open(sh.host.ctx, path),
        .reveal => |path| sh.host.reveal(sh.host.ctx, path),
    }
}

pub const file_count: usize = 750_000;
pub const frame_runs: usize = 200;
pub const icon_runs: usize = 20;

/// Hooks for the built-frame metrics: real dates, and icons that are either
/// absent or rendered by the system on every request, with no cache.
const FrameHooks = struct {
    fn request(_: ?*anyopaque) void {}

    fn icon(_: ?*anyopaque, _: []const u8, _: icons_mod.Kind) ?icons_mod.Image {
        return null;
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
    io: std.Io,
    root: []u8,
    cat: search.Catalog,
    store: clipboard.Store,

    fn init(f: *Fixture, gpa: std.mem.Allocator, io: std.Io, entry_count: usize) !void {
        f.gpa = gpa;
        f.io = io;
        f.root = try std.fmt.allocPrint(gpa, "/tmp/nanospot-bench-{d}", .{std.c.getpid()});
        errdefer gpa.free(f.root);
        std.Io.Dir.cwd().deleteTree(io, f.root) catch {};
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, f.root, .{});
        dir.close(io);
        errdefer std.Io.Dir.cwd().deleteTree(io, f.root) catch {};

        f.cat = .{ .gpa = gpa };
        errdefer f.cat.deinit();
        try populateCatalog(&f.cat, catalog_app_count);

        const index_path = try std.fs.path.join(gpa, &.{ f.root, "names.flix" });
        defer gpa.free(index_path);
        _ = try core.index.writeSynthetic(gpa, index_path, "/Users/synthetic", @intCast(entry_count));
        try f.cat.openIndex(index_path, "/Users/synthetic");
        f.cat.startWorker(io, .{});

        f.store = try .open(":memory:", f.root);
        errdefer f.store.close();
        for (keystroke_queries) |q| try f.store.recordQuery(.search, q, 1);
    }

    fn deinit(f: *Fixture) void {
        f.store.close();
        f.cat.deinit();
        std.Io.Dir.cwd().deleteTree(f.io, f.root) catch {};
        f.gpa.free(f.root);
    }
};

fn measureBuiltFrame(gpa: std.mem.Allocator, io: std.Io, runs: usize) !Stats {
    var fx: Fixture = undefined;
    const count: usize = if (builtin.is_test) 2_000 else file_count;
    try fx.init(gpa, io, count);
    defer fx.deinit();

    var hooks: FrameHooks = .{};
    var p = panel_mod.Panel.init(gpa, &fx.cat, &fx.store, hooks.hooks());
    defer p.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&p, panel_mod.Panel.view), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    for (keystroke_queries) |q| {
        p.field.set(q);
        p.refresh();
        tester.frame();
        if (p.list.visible.len == 0) return error.EmptyPublication;
    }

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

pub fn measureKeystrokeToBuiltFrame(gpa: std.mem.Allocator, io: std.Io, runs: usize) !Stats {
    return measureBuiltFrame(gpa, io, runs);
}

pub fn measureFirstFrameWithIcons(gpa: std.mem.Allocator, io: std.Io, runs: usize) !Stats {
    var fx: Fixture = undefined;
    const count: usize = if (builtin.is_test) 2_000 else file_count;
    try fx.init(gpa, io, count);
    defer fx.deinit();

    var sh: shell_mod.Shell = undefined;
    sh.init(gpa, &fx.cat, &fx.store, shell_mod.macHost(null, shell_mod.noOp, shell_mod.noSuggest));
    defer sh.deinit();
    sh.startIconWorker(io, .{});

    var tester: ui.Tester = undefined;
    try tester.init(gpa, sh.view(), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();
    _ = sh.hotKey(.search, false);

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const q = keystroke_queries[i % keystroke_queries.len];
        _ = sh.pollIcons();
        const t0 = nowNs();
        sh.panel.field.set(q);
        sh.panel.refresh();
        tester.frame();
        s.* = nowNs() - t0;
        if (sh.panel.list.visible.len == 0) return error.EmptyPublication;
    }
    return summarize(samples);
}

pub fn measureHotKeyToBuiltFrame(gpa: std.mem.Allocator, runs: usize) !Stats {
    var cat: search.Catalog = .{ .gpa = gpa };
    defer cat.deinit();
    try populateCatalog(&cat, catalog_app_count);

    var sh: shell_mod.Shell = undefined;
    sh.init(gpa, &cat, null, .{});
    defer sh.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, sh.view(), .{
        .width = chrome.metrics.width,
        .height = chrome.metrics.expanded_height,
    });
    defer tester.deinit();

    for (keystroke_queries) |q| {
        try presentThenHide(&sh, &tester, q);
        _ = sh.hotKey(.search, false);
        tester.frame();
        if (sh.presence.phase != .shown) return error.EntranceWaited;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        try presentThenHide(&sh, &tester, keystroke_queries[i % keystroke_queries.len]);
        const t0 = nowNs();
        _ = sh.hotKey(.search, false);
        tester.frame();
        s.* = nowNs() - t0;
        if (sh.presence.phase != .shown) return error.EntranceWaited;
    }
    return summarize(samples);
}

pub const board_entries: usize = 5000;
pub const board_runs: usize = 40;

const board_queries = [_][]const u8{ "m", "me", "mee", "meet" };

const BoardBenchResult = struct {
    all: Stats,
    single_m: Stats,
};

fn seedBoardStore(gpa: std.mem.Allocator) !struct { root: []u8, store: clipboard.Store } {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try std.fmt.allocPrint(gpa, "/tmp/nanospot-board-bench-{d}", .{std.c.getpid()});
    errdefer gpa.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    dir.close(io);
    errdefer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var store = try clipboard.Store.open(":memory:", root);
    errdefer store.close();
    const filler = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo nebula oscar papa quebec router sierra tango upsilon victor whiskey xray yankee zulu ";
    var buf: [600]u8 = undefined;
    for (0..board_entries) |i| {
        const prefix: []const u8 = if (i % 26 == 0) "meeting notes " else "";
        const text = try std.fmt.bufPrint(&buf, "{s}{s}{s}{s} #{d}", .{ prefix, filler, filler, filler, i });
        _ = try store.add(.{ .text = text }, "com.apple.Notes", "Notes", @floatFromInt(i + 1));
    }
    return .{ .root = root, .store = store };
}

fn freeBoardStore(gpa: std.mem.Allocator, root: []u8, store: *clipboard.Store) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    store.close();
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    gpa.free(root);
}

pub fn measureBoardKeystroke(gpa: std.mem.Allocator, runs: usize) !Stats {
    var seeded = try seedBoardStore(gpa);
    defer freeBoardStore(gpa, seeded.root, &seeded.store);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    for (board_queries) |q| {
        _ = arena.reset(.retain_capacity);
        const rows = try seeded.store.list(arena.allocator(), q);
        if (rows.len == 0) return error.EmptyPublication;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        const q = board_queries[i % board_queries.len];
        _ = arena.reset(.retain_capacity);
        const t0 = nowNs();
        const rows = try seeded.store.list(arena.allocator(), q);
        s.* = nowNs() - t0;
        if (rows.len == 0) return error.EmptyPublication;
    }
    return summarize(samples);
}

fn measureBoardKeystrokes(gpa: std.mem.Allocator, runs: usize) !BoardBenchResult {
    var seeded = try seedBoardStore(gpa);
    defer freeBoardStore(gpa, seeded.root, &seeded.store);

    var b: board_mod.Board = .init(gpa, &seeded.store, .wall_clock);
    defer b.deinit();

    for (board_queries) |q| {
        b.refresh(q);
        if (b.list.visible.len == 0) return error.EmptyPublication;
    }

    const samples = try gpa.alloc(u64, runs);
    defer gpa.free(samples);
    const single_samples = try gpa.alloc(u64, @max(1, runs / board_queries.len));
    defer gpa.free(single_samples);
    var single_n: usize = 0;
    for (samples, 0..) |*s, i| {
        const idx = i % board_queries.len;
        const q = board_queries[idx];
        const t0 = nowNs();
        b.refresh(q);
        s.* = nowNs() - t0;
        if (b.list.visible.len == 0) return error.EmptyPublication;
        if (idx == 0 and single_n < single_samples.len) {
            single_samples[single_n] = s.*;
            single_n += 1;
        }
    }
    return .{
        .all = summarize(samples),
        .single_m = summarize(single_samples[0..single_n]),
    };
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

fn checkBudget(failed: *bool, label: []const u8, stats: Stats, budget_us: f64) void {
    if (stats.p99Us() <= budget_us) return;
    std.log.err("{s} p99 {d:.2} us exceeds budget {d:.2} us", .{ label, stats.p99Us(), budget_us });
    failed.* = true;
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
    const built = try measureKeystrokeToBuiltFrame(gpa, init.io, frame_runs);
    const icons = try measureFirstFrameWithIcons(gpa, init.io, icon_runs);
    const built_summon = try measureHotKeyToBuiltFrame(gpa, default_runs);
    const board_keystroke = try measureBoardKeystroke(gpa, board_runs);
    const board_narrowed = try measureBoardKeystrokes(gpa, board_runs);

    try out.print(
        "NANOSPOT_BENCH metric=keystroke_to_publication apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, keystroke.runs, keystroke.p50Us(), keystroke.p99Us(), Budgets.keystroke_to_publication_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=hotkey_to_laid_out_frame apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, summon.runs, summon.p50Us(), summon.p99Us(), Budgets.hotkey_to_laid_out_frame_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=return_to_action apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, submit.runs, submit.p50Us(), submit.p99Us(), Budgets.return_to_action_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=keystroke_to_built_frame apps={d} files={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, file_count, built.runs, built.p50Us(), built.p99Us(), Budgets.keystroke_to_built_frame_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=first_frame_with_icons apps={d} files={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, file_count, icons.runs, icons.p50Us(), icons.p99Us(), Budgets.first_frame_with_icons_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=hotkey_to_built_frame apps={d} runs={d} p50_us={d:.2} p99_us={d:.2} budget_p99_us={d:.2}\n",
        .{ catalog_app_count, built_summon.runs, built_summon.p50Us(), built_summon.p99Us(), Budgets.hotkey_to_built_frame_p99_us },
    );
    try out.print(
        "NANOSPOT_BENCH metric=board_keystroke entries={d} runs={d} p50_us={d:.2} p99_us={d:.2}\n",
        .{ board_entries, board_keystroke.runs, board_keystroke.p50Us(), board_keystroke.p99Us() },
    );
    try out.print(
        "NANOSPOT_BENCH metric=board_keystroke_narrowed entries={d} runs={d} p50_us={d:.2} p99_us={d:.2} m_p50_us={d:.2}\n",
        .{ board_entries, board_narrowed.all.runs, board_narrowed.all.p50Us(), board_narrowed.all.p99Us(), board_narrowed.single_m.p50Us() },
    );
    try out.flush();

    var failed = false;
    checkBudget(&failed, "keystroke -> built frame", built, Budgets.keystroke_to_built_frame_p99_us);
    checkBudget(&failed, "first frame with icons", icons, Budgets.first_frame_with_icons_p99_us);
    checkBudget(&failed, "hot key -> built frame", built_summon, Budgets.hotkey_to_built_frame_p99_us);
    checkBudget(&failed, "keystroke -> publication", keystroke, Budgets.keystroke_to_publication_p99_us);
    checkBudget(&failed, "hot key -> laid-out frame", summon, Budgets.hotkey_to_laid_out_frame_p99_us);
    checkBudget(&failed, "Return -> action", submit, Budgets.return_to_action_p99_us);
    if (failed) std.process.exit(1);
}
