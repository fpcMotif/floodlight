//! Latency probe CLI flag (`--nanospot-latency-session`): drives the real
//! panel and times each input to the frame that presents it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const mac = @import("mac.zig");
const stage_clock = @import("stage_clock.zig");

extern "c" fn CACurrentMediaTime() f64;

pub const session_flag = "--nanospot-latency-session";
pub const open_flag = "--nanospot-latency-open";
pub const nowNs = stage_clock.nowNs;

pub const Budgets = struct {
    pub const summon_p99_us: u64 = 8300;
    pub const keystroke_p99_us: u64 = 16000;
    pub const switch_to_board_p99_us: u64 = 8300;
    pub const return_to_hidden_p99_us: u64 = 8300;
    pub const reveal_to_hidden_p99_us: u64 = 8300;
};

pub const max_rounds: usize = 30;
pub const default_rounds: usize = max_rounds;
const open_runs = 5;
const gap_ms = 250;
const frame_timeout_ms = 1000;

pub const ParseRoundsError = error{InvalidRounds};
pub const ParseFrameLatencyError = error{InvalidFrameLatency};

pub fn parseRounds(raw: ?[]const u8) ParseRoundsError!usize {
    const slice = raw orelse return default_rounds;
    const n = std.fmt.parseInt(usize, slice, 10) catch return error.InvalidRounds;
    if (n < 1 or n > max_rounds) return error.InvalidRounds;
    return n;
}

pub fn resolveRoundsOrExit() usize {
    const raw = std.c.getenv("NANOSPOT_LATENCY_ROUNDS");
    const slice: ?[]const u8 = if (raw) |p| std.mem.span(p) else null;
    return parseRounds(slice) catch {
        std.debug.print("NANOSPOT_LATENCY error invalid NANOSPOT_LATENCY_ROUNDS={s} (expected 1..{d})\n", .{ slice orelse "", max_rounds });
        std.process.exit(1);
    };
}

pub fn parseFrameLatency(raw: ?[]const u8) ParseFrameLatencyError!?f32 {
    const slice = raw orelse return null;
    if (slice.len == 0) return error.InvalidFrameLatency;
    const v = std.fmt.parseFloat(f32, slice) catch return error.InvalidFrameLatency;
    if (!std.math.isFinite(v) or v <= 0) return error.InvalidFrameLatency;
    return v;
}

pub fn resolveFrameLatencyOrExit() ?f32 {
    const raw = std.c.getenv("NANOSPOT_FRAME_LATENCY");
    const slice: ?[]const u8 = if (raw) |p| std.mem.span(p) else null;
    return parseFrameLatency(slice) catch {
        std.debug.print("NANOSPOT_DISPLAY error invalid NANOSPOT_FRAME_LATENCY={s} (expected positive float)\n", .{slice orelse ""});
        std.process.exit(1);
    };
}

pub fn addLagNs(base_ns: u64, lag_sec: f64) u64 {
    if (!std.math.isFinite(lag_sec) or lag_sec <= 0) return base_ns;
    const lag_ns: u64 = @intFromFloat(@round(lag_sec * 1e9));
    return base_ns +| lag_ns;
}

pub fn isMissedFrame(presented_time: f64, target_time: f64, refresh_hz: f32) bool {
    if (presented_time <= 0 or target_time <= 0) return false;
    const hz: f64 = @max(60.0, @as(f64, refresh_hz));
    return presented_time > target_time + (0.5 / hz);
}

pub fn configureDisplayLink(st: *State, surface: *nanoui.Surface, override: ?f32) void {
    st.refresh_hz = surface.max_fps;
    const link = surface.display_link orelse return;
    st.default_frame_latency = objc.msg(f32, link, "preferredFrameLatency", .{});
    if (override) |v| objc.msg(void, link, "setPreferredFrameLatency:", .{v});
    st.preferred_frame_latency = objc.msg(f32, link, "preferredFrameLatency", .{});
}

/// How long the panel stays hidden before the next summon
/// (`NANOSPOT_LATENCY_IDLE_MS`): a quick re-summon and one after a rest differ.
fn idleMs() u32 {
    const raw = std.c.getenv("NANOSPOT_LATENCY_IDLE_MS") orelse return gap_ms;
    return std.fmt.parseInt(u32, std.mem.span(raw), 10) catch gap_ms;
}

pub const FrameMetric = enum {
    summon,
    keystroke_new_rows,
    keystroke_same_rows,
    switch_to_board,

    fn budgetP99Us(m: FrameMetric) u64 {
        return switch (m) {
            .summon => Budgets.summon_p99_us,
            .keystroke_new_rows, .keystroke_same_rows => Budgets.keystroke_p99_us,
            .switch_to_board => Budgets.switch_to_board_p99_us,
        };
    }
};

pub const ActionMetric = enum {
    return_to_hidden,
    reveal_to_hidden,

    pub fn budgetP99Us(m: ActionMetric) u64 {
        return switch (m) {
            .return_to_hidden => Budgets.return_to_hidden_p99_us,
            .reveal_to_hidden => Budgets.reveal_to_hidden_p99_us,
        };
    }
};

const ScalarMetric = enum {
    summon_placed,
    summon_built,
    switch_presence,
    switch_store_query,
    switch_resize,
    switch_order_in,
    hide,
    keystroke_files_shown,
};

const Waiting = enum {
    summon,
    keystroke_new_rows,
    keystroke_same_rows,
    switch_to_board,
    return_to_hidden,
    reveal_to_hidden,

    fn frameMetric(w: Waiting) ?FrameMetric {
        return switch (w) {
            .summon => .summon,
            .keystroke_new_rows => .keystroke_new_rows,
            .keystroke_same_rows => .keystroke_same_rows,
            .switch_to_board => .switch_to_board,
            .return_to_hidden, .reveal_to_hidden => null,
        };
    }

    fn actionMetric(w: Waiting) ?ActionMetric {
        return switch (w) {
            .return_to_hidden => .return_to_hidden,
            .reveal_to_hidden => .reveal_to_hidden,
            else => null,
        };
    }
};

pub const LaunchTimings = struct {
    app_init_ns: u64 = 0,
    index_open_ns: u64 = 0,
    app_scan_ns: u64 = 0,
    clipboard_open_ns: u64 = 0,
    clipboard_prune_ns: u64 = 0,
    panel_window_ns: u64 = 0,
    guide_window_ns: u64 = 0,
    hotkeys_ns: u64 = 0,
    total_ns: u64 = 0,
};

const queries = [_][]const u8{ "a", "s", "c", "m", "t", "p", "n", "f", "d", "r" };

const PendingDisplay = struct {
    metric: FrameMetric,
    total_ns: u64,
    now_media: f64,
    target_media: f64,
    refresh_hz: f32,
    drawable: objc.Object,
};

pub const State = struct {
    rounds: usize = default_rounds,
    step: u32 = 0,
    waiting: ?Waiting = null,
    frame_sample: stage_clock.FrameSample = .{},
    action_sample: stage_clock.ActionSample = .{},
    switch_sample: stage_clock.SwitchSample = .{},
    switch_decodes: u32 = 0,
    generation: u32 = 0,
    timeouts: u32 = 0,
    frame_counts: [std.enums.values(FrameMetric).len]usize = @splat(0),
    frame_total: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_publish: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_build: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_present: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_handed: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_at_target_counts: [std.enums.values(FrameMetric).len]usize = @splat(0),
    frame_at_target: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_at_display_counts: [std.enums.values(FrameMetric).len]usize = @splat(0),
    frame_at_display: [std.enums.values(FrameMetric).len][max_rounds]u64 = undefined,
    frame_missed: [std.enums.values(FrameMetric).len]u32 = @splat(0),
    frame_display_runs: [std.enums.values(FrameMetric).len]usize = @splat(0),
    default_frame_latency: f32 = 0,
    preferred_frame_latency: f32 = 0,
    refresh_hz: f32 = 60,
    pending_display: ?PendingDisplay = null,
    action_counts: [std.enums.values(ActionMetric).len]usize = @splat(0),
    action_total: [std.enums.values(ActionMetric).len][max_rounds]u64 = undefined,
    action_publish: [std.enums.values(ActionMetric).len][max_rounds]u64 = undefined,
    action_action: [std.enums.values(ActionMetric).len][max_rounds]u64 = undefined,
    action_hide: [std.enums.values(ActionMetric).len][max_rounds]u64 = undefined,
    action_handoff: [std.enums.values(ActionMetric).len][max_rounds]u64 = undefined,
    files_key_ns: ?u64 = null,
    scalar_counts: [std.enums.values(ScalarMetric).len]usize = @splat(0),
    scalar_samples: [std.enums.values(ScalarMetric).len][max_rounds * std.enums.values(ActionMetric).len]u64 = undefined,
    resize_runs: usize = 0,
    resize_samples: [max_rounds * 4]u64 = undefined,
    resize_delay_runs: usize = 0,
    resize_delay_samples: [max_rounds * 4]u64 = undefined,
    resize_pending_ns: u64 = 0,
    resize_waiting_gen: u32 = 0,
    resize_waited_count: u32 = 0,
    launch: LaunchTimings = .{},
    index_entries: u32 = 0,
    measure_open: bool = false,

    fn recordFrame(st: *State, m: FrameMetric, d: stage_clock.FrameDeltas) void {
        const i = @backingInt(m);
        const k = st.frame_counts[i];
        if (k >= st.rounds) return;
        st.frame_total[i][k] = d.total_ns;
        st.frame_handed[i][k] = d.total_ns;
        st.frame_publish[i][k] = d.publish_ns;
        st.frame_build[i][k] = d.build_ns;
        st.frame_present[i][k] = d.present_ns;
        st.frame_counts[i] = k + 1;
    }

    fn recordAtTarget(st: *State, m: FrameMetric, total_ns: u64, now_media: f64, target_media: f64) void {
        const i = @backingInt(m);
        const k = st.frame_at_target_counts[i];
        if (k >= st.rounds) return;
        st.frame_at_target[i][k] = addLagNs(total_ns, target_media - now_media);
        st.frame_at_target_counts[i] = k + 1;
    }

    fn recordDisplay(st: *State, m: FrameMetric, total_ns: u64, now_media: f64, target_media: f64, presented_time: f64, refresh_hz: f32) void {
        const i = @backingInt(m);
        if (presented_time <= 0) return;
        const k = st.frame_at_display_counts[i];
        if (k >= st.rounds) return;
        st.frame_display_runs[i] += 1;
        if (isMissedFrame(presented_time, target_media, refresh_hz)) st.frame_missed[i] += 1;
        st.frame_at_display[i][k] = addLagNs(total_ns, presented_time - now_media);
        st.frame_at_display_counts[i] = k + 1;
    }

    fn recordAction(st: *State, m: ActionMetric, d: stage_clock.ActionDeltas) void {
        const i = @backingInt(m);
        const k = st.action_counts[i];
        if (k >= st.rounds) return;
        st.action_total[i][k] = d.total_ns;
        st.action_publish[i][k] = d.publish_ns;
        st.action_action[i][k] = d.action_ns;
        st.action_hide[i][k] = d.hide_ns;
        st.action_handoff[i][k] = d.handoff_ns;
        st.action_counts[i] = k + 1;
    }

    fn recordScalar(st: *State, m: ScalarMetric, ns: u64) void {
        const i = @backingInt(m);
        const k = st.scalar_counts[i];
        const limit = if (m == .hide) st.rounds * std.enums.values(ActionMetric).len else st.rounds;
        if (k >= limit) return;
        st.scalar_samples[i][k] = ns;
        st.scalar_counts[i] = k + 1;
    }

    fn waitingActionMetric(st: *const State) ?ActionMetric {
        const w = st.waiting orelse return null;
        return w.actionMetric();
    }
};

pub fn Runner(comptime Shell: type) type {
    return struct {
        pub fn launched(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            std.debug.print("NANOSPOT_LATENCY catalog rounds={d} apps={d} file_entries={d}\n", .{ s.latency.rounds, s.catalog.apps.items.len, s.catalog.fileEntryCount() });
            nanoui.App.after(gap_ms * 4, ctx, stepFn);
        }

        /// Call after every frame; a frame that presents ends the interval a step began.
        pub fn frame(s: *Shell, surface: *nanoui.Surface, presenting: bool, decodes: u32) void {
            const st = &s.latency;
            st.refresh_hz = surface.max_fps;
            if (presenting) if (st.files_key_ns) |t0| for (s.shell.panel.base_rows) |r| {
                if (r.kind != .file and r.kind != .folder) continue;
                st.recordScalar(.keystroke_files_shown, nowNs() -| t0);
                st.files_key_ns = null;
                break;
            };
            const w = st.waiting orelse return;
            const fm = w.frameMetric() orelse return;
            if (fm == .switch_to_board) st.switch_decodes += decodes;
            const now = nowNs();
            if (st.frame_sample.built_ns == null) {
                st.frame_sample.built_ns = now;
                if (fm == .summon) st.recordScalar(.summon_built, now -| st.frame_sample.input_ns);
            }
            if (!presenting) return;
            const now_media = CACurrentMediaTime();
            st.frame_sample.presented_ns = now;
            if (st.frame_sample.deltas()) |d| {
                st.recordFrame(fm, d);
                if (surface.renderer.given_drawable) |drawable| {
                    settlePendingDisplay(s);
                    st.pending_display = .{
                        .metric = fm,
                        .total_ns = d.total_ns,
                        .now_media = now_media,
                        .target_media = 0,
                        .refresh_hz = surface.max_fps,
                        .drawable = objc.retain(drawable),
                    };
                    objc.dispatchMain(s, captureTarget);
                }
            }
            st.waiting = null;
            st.generation +%= 1;
            nanoui.App.after(gap_ms, s, stepFn);
        }

        fn captureTarget(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            const st = &s.latency;
            const pending = &(st.pending_display orelse return);
            if (pending.target_media != 0) return;
            const surface = s.panel_window.surface orelse return;
            const target = if (surface.last_present_target > 0) surface.last_present_target else surface.last_frame_time;
            pending.target_media = target;
            st.recordAtTarget(pending.metric, pending.total_ns, pending.now_media, target);
        }

        fn settlePendingDisplay(s: *Shell) void {
            const st = &s.latency;
            const pending = st.pending_display orelse return;
            st.pending_display = null;
            defer objc.release(pending.drawable);
            var target = pending.target_media;
            if (target == 0) {
                if (s.panel_window.surface) |surface| {
                    target = if (surface.last_present_target > 0) surface.last_present_target else surface.last_frame_time;
                }
                st.recordAtTarget(pending.metric, pending.total_ns, pending.now_media, target);
            }
            const presented_time = objc.msg(f64, pending.drawable, "presentedTime", .{});
            st.recordDisplay(pending.metric, pending.total_ns, pending.now_media, target, presented_time, pending.refresh_hz);
        }

        pub fn switchResized(s: *Shell) void {
            const st = &s.latency;
            if (st.waiting != .switch_to_board) return;
            st.switch_sample.resized_ns = nowNs();
        }

        pub fn switchOrderedIn(s: *Shell) void {
            const st = &s.latency;
            if (st.waiting != .switch_to_board) return;
            st.switch_sample.ordered_ns = nowNs();
        }

        pub fn applyBegin(s: *Shell) void {
            const st = &s.latency;
            if (st.waitingActionMetric() == null) return;
            st.action_sample.apply_ns = nowNs();
        }

        pub fn actionHanded(s: *Shell, t_start: u64, t_end: u64) void {
            const st = &s.latency;
            if (st.waitingActionMetric() == null) return;
            st.action_sample.action_start_ns = t_start;
            st.action_sample.action_end_ns = t_end;
        }

        pub fn hidden(s: *Shell, t_start: u64) void {
            const st = &s.latency;
            const now = nowNs();
            st.recordScalar(.hide, now -| t_start);
            if (st.waitingActionMetric() == null) return;
            st.action_sample.hide_start_ns = t_start;
            st.action_sample.hide_end_ns = now;
        }

        pub fn applyEnd(s: *Shell) void {
            const st = &s.latency;
            const am = st.waitingActionMetric() orelse return;
            const d = st.action_sample.deltas() orelse return;
            st.recordAction(am, d);
            st.waiting = null;
            st.generation +%= 1;
            nanoui.App.after(if (am == .reveal_to_hidden) idleMs() else gap_ms, s, stepFn);
        }

        pub fn resized(s: *Shell, t_start: u64, t_end: u64) void {
            const st = &s.latency;
            if (st.resize_runs < st.resize_samples.len) {
                st.resize_samples[st.resize_runs] = t_end -| t_start;
                st.resize_runs += 1;
            }
            st.resize_pending_ns = t_end;
            st.resize_waiting_gen = if (st.waiting != null) st.generation else 0;
        }

        pub fn resizeRedrawFired(s: *Shell) void {
            const st = &s.latency;
            if (st.resize_pending_ns == 0) return;
            if (st.resize_delay_runs < st.resize_delay_samples.len) {
                st.resize_delay_samples[st.resize_delay_runs] = nowNs() -| st.resize_pending_ns;
                st.resize_delay_runs += 1;
            }
            if (st.resize_waiting_gen != 0 and st.waiting != null and st.generation == st.resize_waiting_gen) {
                st.resize_waited_count += 1;
            }
            st.resize_pending_ns = 0;
            st.resize_waiting_gen = 0;
        }

        fn beginFrame(s: *Shell, w: Waiting, t0: u64) void {
            const st = &s.latency;
            st.waiting = w;
            st.frame_sample = .{ .input_ns = t0 };
            st.generation +%= 1;
        }

        fn beginAction(s: *Shell, w: Waiting, t0: u64) void {
            const st = &s.latency;
            st.waiting = w;
            st.action_sample = .{ .input_ns = t0 };
            st.generation +%= 1;
        }

        fn armWatchIfWaiting(s: *Shell) void {
            const st = &s.latency;
            if (st.waiting == null) return;
            const tag = std.heap.c_allocator.create(Watch) catch return;
            tag.* = .{ .shell = s, .generation = st.generation };
            nanoui.App.after(frame_timeout_ms, tag, timedOut);
        }

        const Watch = struct { shell: *Shell, generation: u32 };

        fn timedOut(ctx: ?*anyopaque) callconv(.c) void {
            const tag: *Watch = @ptrCast(@alignCast(ctx));
            const s = tag.shell;
            const generation = tag.generation;
            std.heap.c_allocator.destroy(tag);
            const st = &s.latency;
            if (st.waiting == null or st.generation != generation) return;
            st.waiting = null;
            st.timeouts += 1;
            nanoui.App.after(gap_ms, s, stepFn);
        }

        fn stepFn(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            settlePendingDisplay(s);
            const st = &s.latency;
            const steps_per_round = 7;
            const round = st.step / steps_per_round;
            const step = st.step % steps_per_round;
            st.step += 1;
            if (round >= st.rounds) return finish(s);
            const q = queries[round % queries.len];
            switch (step) {
                0 => {
                    const t0 = nowNs();
                    beginFrame(s, .summon, t0);
                    const out = s.shell.hotKey(.search, false);
                    st.frame_sample.published_ns = nowNs();
                    s.apply(out);
                    st.recordScalar(.summon_placed, nowNs() -| t0);
                    armWatchIfWaiting(s);
                },
                1 => key(s, .keystroke_new_rows, q),
                2 => {
                    var buf: [8]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{s} ", .{q}) catch q;
                    key(s, .keystroke_same_rows, text);
                },
                3 => {
                    const t0 = nowNs();
                    beginFrame(s, .switch_to_board, t0);
                    st.switch_sample = .{ .input_ns = t0 };
                    const out = s.shell.hotKey(.clipboard, false);
                    const after_hotkey = nowNs();
                    st.switch_sample.presence_ns = s.shell.panel.board_presence_ns;
                    st.switch_sample.store_query_ns = after_hotkey;
                    st.frame_sample.published_ns = after_hotkey;
                    s.apply(out);
                    const sd = st.switch_sample.deltas();
                    st.recordScalar(.switch_presence, sd.presence_ns);
                    st.recordScalar(.switch_store_query, sd.store_query_ns);
                    st.recordScalar(.switch_resize, sd.resize_ns);
                    st.recordScalar(.switch_order_in, sd.order_in_ns);
                    armWatchIfWaiting(s);
                },
                4 => triggerAction(s, .return_to_hidden),
                5 => {
                    s.apply(s.shell.hotKey(.search, false));
                    nanoui.App.after(gap_ms, s, stepFn);
                },
                else => triggerAction(s, .reveal_to_hidden),
            }
        }

        fn triggerAction(s: *Shell, w: Waiting) void {
            const t0 = nowNs();
            beginAction(s, w, t0);
            const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
            s.shell.panel.ask(if (w == .reveal_to_hidden) .{ .reveal = home } else .{ .open = home });
            armWatchIfWaiting(s);
        }

        fn key(s: *Shell, w: Waiting, text: []const u8) void {
            const t0 = nowNs();
            beginFrame(s, w, t0);
            s.latency.files_key_ns = if (w == .keystroke_new_rows) t0 else null;
            s.shell.panel.field.set(text);
            s.shell.panel.refresh();
            s.latency.frame_sample.published_ns = nowNs();
            s.panel_window.redraw();
            armWatchIfWaiting(s);
        }

        fn finish(s: *Shell) void {
            settlePendingDisplay(s);
            const st = &s.latency;
            std.debug.print(
                "NANOSPOT_DISPLAY link preferred_frame_latency={d:.2} default_frame_latency={d:.2} refresh_hz={d:.0}\n",
                .{ st.preferred_frame_latency, st.default_frame_latency, st.refresh_hz },
            );
            for (std.enums.values(FrameMetric)) |m| {
                const i = @backingInt(m);
                printDisplay(
                    @tagName(m),
                    st.frame_handed[i][0..st.frame_counts[i]],
                    st.frame_at_target[i][0..st.frame_at_target_counts[i]],
                    st.frame_at_display[i][0..st.frame_at_display_counts[i]],
                    st.frame_missed[i],
                    st.frame_display_runs[i],
                );
            }
            printScalar(st.rounds, "summon_placed", st.scalar_samples[@backingInt(ScalarMetric.summon_placed)][0..st.scalar_counts[@backingInt(ScalarMetric.summon_placed)]]);
            printScalar(st.rounds, "summon_built", st.scalar_samples[@backingInt(ScalarMetric.summon_built)][0..st.scalar_counts[@backingInt(ScalarMetric.summon_built)]]);
            printScalar(st.rounds, "keystroke_files_shown", st.scalar_samples[@backingInt(ScalarMetric.keystroke_files_shown)][0..st.scalar_counts[@backingInt(ScalarMetric.keystroke_files_shown)]]);
            for (std.enums.values(FrameMetric)) |m| {
                const i = @backingInt(m);
                const n = st.frame_counts[i];
                printFrame(
                    st.rounds,
                    @tagName(m),
                    st.frame_total[i][0..n],
                    st.frame_publish[i][0..n],
                    st.frame_build[i][0..n],
                    st.frame_present[i][0..n],
                    m.budgetP99Us(),
                );
            }
            for (std.enums.values(ActionMetric)) |m| {
                const i = @backingInt(m);
                const n = st.action_counts[i];
                printAction(
                    st.rounds,
                    @tagName(m),
                    st.action_total[i][0..n],
                    st.action_publish[i][0..n],
                    st.action_action[i][0..n],
                    st.action_hide[i][0..n],
                    st.action_handoff[i][0..n],
                    m.budgetP99Us(),
                );
            }
            printScalar(st.rounds, "switch_presence", st.scalar_samples[@backingInt(ScalarMetric.switch_presence)][0..st.scalar_counts[@backingInt(ScalarMetric.switch_presence)]]);
            printScalar(st.rounds, "switch_store_query", st.scalar_samples[@backingInt(ScalarMetric.switch_store_query)][0..st.scalar_counts[@backingInt(ScalarMetric.switch_store_query)]]);
            printScalar(st.rounds, "switch_resize", st.scalar_samples[@backingInt(ScalarMetric.switch_resize)][0..st.scalar_counts[@backingInt(ScalarMetric.switch_resize)]]);
            printScalar(st.rounds, "switch_order_in", st.scalar_samples[@backingInt(ScalarMetric.switch_order_in)][0..st.scalar_counts[@backingInt(ScalarMetric.switch_order_in)]]);
            printScalar(st.rounds, "hide", st.scalar_samples[@backingInt(ScalarMetric.hide)][0..st.scalar_counts[@backingInt(ScalarMetric.hide)]]);
            printResize(
                st.rounds,
                st.resize_samples[0..st.resize_runs],
                st.resize_delay_samples[0..st.resize_delay_runs],
                st.resize_waited_count,
            );
            std.debug.print(
                "NANOSPOT_LATENCY metric=launch rounds={d} runs=1 app_init_us={d:.0} index_open_us={d:.0} app_scan_us={d:.0} clipboard_open_us={d:.0} clipboard_prune_us={d:.0} panel_window_us={d:.0} guide_window_us={d:.0} hotkeys_us={d:.0} total_us={d:.0}\n",
                .{
                    st.rounds,
                    us(st.launch.app_init_ns),
                    us(st.launch.index_open_ns),
                    us(st.launch.app_scan_ns),
                    us(st.launch.clipboard_open_ns),
                    us(st.launch.clipboard_prune_ns),
                    us(st.launch.panel_window_ns),
                    us(st.launch.guide_window_ns),
                    us(st.launch.hotkeys_ns),
                    us(st.launch.total_ns),
                },
            );
            if (st.measure_open) {
                var opens: [open_runs]u64 = undefined;
                const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
                for (&opens) |*o| {
                    const t0 = nowNs();
                    mac.open(home);
                    o.* = nowNs() -| t0;
                }
                printScalar(st.rounds, "open_handoff", &opens);
            }
            std.debug.print(
                "NANOSPOT_LATENCY done rounds={d} entries={d} timeouts={d} switch_decodes={d} kept_thumbs={d} kept_thumb_bytes={d}\n",
                .{ st.rounds, st.index_entries, st.timeouts, st.switch_decodes, s.shell.icons.keptCount(), s.shell.icons.keptBytes() },
            );
            std.process.exit(0);
        }

        fn us(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e3;
        }

        fn printScalar(rounds: usize, name: []const u8, samples: []u64) void {
            const sum = stage_clock.summarize(samples);
            if (sum.runs == 0) return std.debug.print("NANOSPOT_LATENCY metric={s} rounds={d} runs=0\n", .{ name, rounds });
            std.debug.print("NANOSPOT_LATENCY metric={s} rounds={d} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0}\n", .{
                name, rounds, sum.runs, us(sum.p50_ns), us(sum.p99_ns), us(sum.max_ns),
            });
        }

        fn printFrame(
            rounds: usize,
            name: []const u8,
            total: []u64,
            publish: []u64,
            build: []u64,
            present: []u64,
            budget_p99_us: u64,
        ) void {
            const tot = stage_clock.summarize(total);
            if (tot.runs == 0) {
                return std.debug.print("NANOSPOT_LATENCY metric={s} rounds={d} runs=0 budget_p99_us={d}\n", .{ name, rounds, budget_p99_us });
            }
            const pub_s = stage_clock.summarize(publish);
            const bld_s = stage_clock.summarize(build);
            const prs_s = stage_clock.summarize(present);
            std.debug.print(
                "NANOSPOT_LATENCY metric={s} rounds={d} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} publish_p50_us={d:.0} build_p50_us={d:.0} present_p50_us={d:.0} budget_p99_us={d}\n",
                .{ name, rounds, tot.runs, us(tot.p50_ns), us(tot.p99_ns), us(tot.max_ns), us(pub_s.p50_ns), us(bld_s.p50_ns), us(prs_s.p50_ns), budget_p99_us },
            );
        }

        fn printAction(
            rounds: usize,
            name: []const u8,
            total: []u64,
            publish: []u64,
            action: []u64,
            hide: []u64,
            handoff: []u64,
            budget_p99_us: u64,
        ) void {
            const tot = stage_clock.summarize(total);
            if (tot.runs == 0) {
                return std.debug.print("NANOSPOT_LATENCY metric={s} rounds={d} runs=0 budget_p99_us={d}\n", .{ name, rounds, budget_p99_us });
            }
            const pub_s = stage_clock.summarize(publish);
            const act_s = stage_clock.summarize(action);
            const hid_s = stage_clock.summarize(hide);
            const hnd_s = stage_clock.summarize(handoff);
            std.debug.print(
                "NANOSPOT_LATENCY metric={s} rounds={d} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} publish_p50_us={d:.0} action_p50_us={d:.0} hide_p50_us={d:.0} handoff_p50_us={d:.0} budget_p99_us={d}\n",
                .{ name, rounds, tot.runs, us(tot.p50_ns), us(tot.p99_ns), us(tot.max_ns), us(pub_s.p50_ns), us(act_s.p50_ns), us(hid_s.p50_ns), us(hnd_s.p50_ns), budget_p99_us },
            );
        }

        fn printDisplay(
            name: []const u8,
            handed: []u64,
            at_target: []u64,
            at_display: []u64,
            missed: u32,
            display_runs: usize,
        ) void {
            const hnd = stage_clock.summarize(handed);
            const tgt = stage_clock.summarize(at_target);
            const dsp = stage_clock.summarize(at_display);
            std.debug.print(
                "NANOSPOT_DISPLAY metric={s} runs={d} handed_p50_us={d:.0} handed_p99_us={d:.0} at_target_p50_us={d:.0} at_target_p99_us={d:.0} at_display_p50_us={d:.0} at_display_p99_us={d:.0} missed={d}/{d}\n",
                .{
                    name,
                    hnd.runs,
                    us(hnd.p50_ns),
                    us(hnd.p99_ns),
                    us(tgt.p50_ns),
                    us(tgt.p99_ns),
                    us(dsp.p50_ns),
                    us(dsp.p99_ns),
                    missed,
                    display_runs,
                },
            );
        }

        fn printResize(rounds: usize, resize_samples: []u64, delay_samples: []u64, waited_count: u32) void {
            const res_s = stage_clock.summarize(resize_samples);
            const del_s = stage_clock.summarize(delay_samples);
            std.debug.print(
                "NANOSPOT_LATENCY metric=resize_redraw rounds={d} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} delay_runs={d} delay_p50_us={d:.0} waited_count={d}\n",
                .{ rounds, res_s.runs, us(res_s.p50_ns), us(res_s.p99_ns), us(res_s.max_ns), del_s.runs, us(del_s.p50_ns), waited_count },
            );
        }
    };
}

test "parseRounds defaults to 30 and rejects out-of-range or invalid values" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 30), try parseRounds(null));
    try t.expectEqual(@as(usize, 1), try parseRounds("1"));
    try t.expectEqual(@as(usize, 5), try parseRounds("5"));
    try t.expectEqual(@as(usize, 30), try parseRounds("30"));
    try t.expectError(error.InvalidRounds, parseRounds("0"));
    try t.expectError(error.InvalidRounds, parseRounds("31"));
    try t.expectError(error.InvalidRounds, parseRounds("abc"));
    try t.expectError(error.InvalidRounds, parseRounds(""));
    try t.expectError(error.InvalidRounds, parseRounds("-1"));
}

test "ActionMetric exposes 8.3 ms p99 budgets and State records open and reveal independently" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 8300), ActionMetric.return_to_hidden.budgetP99Us());
    try t.expectEqual(@as(u64, 8300), ActionMetric.reveal_to_hidden.budgetP99Us());

    var st: State = .{ .rounds = 2 };
    st.recordAction(.return_to_hidden, .{
        .publish_ns = 10,
        .action_ns = 20,
        .hide_ns = 30,
        .handoff_ns = 40,
        .total_ns = 50,
    });
    st.recordAction(.reveal_to_hidden, .{
        .publish_ns = 110,
        .action_ns = 120,
        .hide_ns = 130,
        .handoff_ns = 140,
        .total_ns = 150,
    });
    for (0..5) |k| st.recordScalar(.hide, @intCast(100 + k));

    const ret_i = @backingInt(ActionMetric.return_to_hidden);
    const rev_i = @backingInt(ActionMetric.reveal_to_hidden);
    try t.expectEqual(@as(usize, 1), st.action_counts[ret_i]);
    try t.expectEqual(@as(usize, 1), st.action_counts[rev_i]);
    try t.expectEqual(@as(u64, 50), st.action_total[ret_i][0]);
    try t.expectEqual(@as(u64, 150), st.action_total[rev_i][0]);
    try t.expectEqual(@as(u64, 40), st.action_handoff[ret_i][0]);
    try t.expectEqual(@as(u64, 140), st.action_handoff[rev_i][0]);
    try t.expectEqual(@as(usize, 4), st.scalar_counts[@backingInt(ScalarMetric.hide)]);
}

test "parseFrameLatency accepts positive floats and rejects invalid values" {
    const t = std.testing;
    try t.expectEqual(@as(?f32, null), try parseFrameLatency(null));
    try t.expectEqual(@as(?f32, 1.0), try parseFrameLatency("1.0"));
    try t.expectEqual(@as(?f32, 1.5), try parseFrameLatency("1.5"));
    try t.expectEqual(@as(?f32, 2.0), try parseFrameLatency("2"));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency(""));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency("0"));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency("-1.0"));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency("nan"));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency("inf"));
    try t.expectError(error.InvalidFrameLatency, parseFrameLatency("abc"));
}

test "addLagNs and isMissedFrame compute at-target, at-display, and half-refresh threshold" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 5_000_000), addLagNs(5_000_000, -0.002));
    try t.expectEqual(@as(u64, 5_000_000), addLagNs(5_000_000, 0));
    try t.expectEqual(@as(u64, 25_000_000), addLagNs(5_000_000, 0.020));

    try t.expect(!isMissedFrame(100.000, 100.000, 120.0));
    try t.expect(!isMissedFrame(100.004, 100.000, 120.0));
    try t.expect(isMissedFrame(100.005, 100.000, 120.0));
    try t.expect(!isMissedFrame(0.0, 100.000, 120.0));
}
