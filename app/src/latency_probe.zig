//! Latency probe CLI flag (`--nanospot-latency-session`): drives the real
//! panel and times each input to the frame that presents it.
const std = @import("std");
const nanoui = @import("nanoui");
const mac = @import("mac.zig");
const stage_clock = @import("stage_clock.zig");

pub const session_flag = "--nanospot-latency-session";
pub const open_flag = "--nanospot-latency-open";
pub const nowNs = stage_clock.nowNs;

pub const Budgets = struct {
    pub const summon_p99_us: u64 = 8300;
    pub const keystroke_p99_us: u64 = 16000;
    pub const switch_to_board_p99_us: u64 = 8300;
    pub const return_to_hidden_p99_us: u64 = 8300;
};

const rounds = 30;
const open_runs = 5;
const gap_ms = 250;
const frame_timeout_ms = 1000;

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

const ScalarMetric = enum { summon_placed, summon_built, hide };

const Waiting = enum {
    summon,
    keystroke_new_rows,
    keystroke_same_rows,
    switch_to_board,
    return_to_hidden,

    fn frameMetric(w: Waiting) ?FrameMetric {
        return switch (w) {
            .summon => .summon,
            .keystroke_new_rows => .keystroke_new_rows,
            .keystroke_same_rows => .keystroke_same_rows,
            .switch_to_board => .switch_to_board,
            .return_to_hidden => null,
        };
    }
};

pub const LaunchTimings = struct {
    index_open_ns: u64 = 0,
    app_scan_ns: u64 = 0,
    clipboard_open_ns: u64 = 0,
    clipboard_prune_ns: u64 = 0,
    guide_window_ns: u64 = 0,
    total_ns: u64 = 0,
};

const queries = [_][]const u8{ "a", "s", "c", "m", "t", "p", "n", "f", "d", "r" };

pub const State = struct {
    step: u32 = 0,
    waiting: ?Waiting = null,
    frame_sample: stage_clock.FrameSample = .{},
    action_sample: stage_clock.ActionSample = .{},
    generation: u32 = 0,
    timeouts: u32 = 0,
    frame_counts: [std.enums.values(FrameMetric).len]usize = @splat(0),
    frame_total: [std.enums.values(FrameMetric).len][rounds]u64 = undefined,
    frame_publish: [std.enums.values(FrameMetric).len][rounds]u64 = undefined,
    frame_build: [std.enums.values(FrameMetric).len][rounds]u64 = undefined,
    frame_present: [std.enums.values(FrameMetric).len][rounds]u64 = undefined,
    action_count: usize = 0,
    action_total: [rounds]u64 = undefined,
    action_publish: [rounds]u64 = undefined,
    action_action: [rounds]u64 = undefined,
    action_hide: [rounds]u64 = undefined,
    action_handoff: [rounds]u64 = undefined,
    scalar_counts: [std.enums.values(ScalarMetric).len]usize = @splat(0),
    scalar_samples: [std.enums.values(ScalarMetric).len][rounds]u64 = undefined,
    resize_runs: usize = 0,
    resize_samples: [rounds * 4]u64 = undefined,
    resize_delay_runs: usize = 0,
    resize_delay_samples: [rounds * 4]u64 = undefined,
    resize_pending_ns: u64 = 0,
    resize_waiting_gen: u32 = 0,
    resize_waited_count: u32 = 0,
    launch: LaunchTimings = .{},
    index_entries: u32 = 0,
    measure_open: bool = false,

    fn recordFrame(st: *State, m: FrameMetric, d: stage_clock.FrameDeltas) void {
        const i = @backingInt(m);
        const k = st.frame_counts[i];
        if (k == rounds) return;
        st.frame_total[i][k] = d.total_ns;
        st.frame_publish[i][k] = d.publish_ns;
        st.frame_build[i][k] = d.build_ns;
        st.frame_present[i][k] = d.present_ns;
        st.frame_counts[i] = k + 1;
    }

    fn recordAction(st: *State, d: stage_clock.ActionDeltas) void {
        const k = st.action_count;
        if (k == rounds) return;
        st.action_total[k] = d.total_ns;
        st.action_publish[k] = d.publish_ns;
        st.action_action[k] = d.action_ns;
        st.action_hide[k] = d.hide_ns;
        st.action_handoff[k] = d.handoff_ns;
        st.action_count = k + 1;
    }

    fn recordScalar(st: *State, m: ScalarMetric, ns: u64) void {
        const i = @backingInt(m);
        const k = st.scalar_counts[i];
        if (k == rounds) return;
        st.scalar_samples[i][k] = ns;
        st.scalar_counts[i] = k + 1;
    }
};

pub fn Runner(comptime Shell: type) type {
    return struct {
        pub fn launched(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            std.debug.print("NANOSPOT_LATENCY catalog apps={d} file_entries={d}\n", .{ s.catalog.apps.items.len, s.catalog.fileEntryCount() });
            nanoui.App.after(gap_ms * 4, ctx, stepFn);
        }

        /// Call after every frame; a frame that presents ends the interval a step began.
        pub fn frame(s: *Shell, presenting: bool) void {
            const st = &s.latency;
            const w = st.waiting orelse return;
            const fm = w.frameMetric() orelse return;
            const now = nowNs();
            if (st.frame_sample.built_ns == null) {
                st.frame_sample.built_ns = now;
                if (fm == .summon) st.recordScalar(.summon_built, now -| st.frame_sample.input_ns);
            }
            if (!presenting) return;
            st.frame_sample.presented_ns = now;
            if (st.frame_sample.deltas()) |d| st.recordFrame(fm, d);
            st.waiting = null;
            st.generation +%= 1;
            nanoui.App.after(gap_ms, s, stepFn);
        }

        pub fn applyBegin(s: *Shell) void {
            const st = &s.latency;
            if (st.waiting != .return_to_hidden) return;
            st.action_sample.apply_ns = nowNs();
        }

        pub fn actionHanded(s: *Shell, t_start: u64, t_end: u64) void {
            const st = &s.latency;
            if (st.waiting != .return_to_hidden) return;
            st.action_sample.action_start_ns = t_start;
            st.action_sample.action_end_ns = t_end;
        }

        pub fn hidden(s: *Shell, t_start: u64) void {
            const st = &s.latency;
            const now = nowNs();
            st.recordScalar(.hide, now -| t_start);
            if (st.waiting != .return_to_hidden) return;
            st.action_sample.hide_start_ns = t_start;
            st.action_sample.hide_end_ns = now;
        }

        pub fn applyEnd(s: *Shell) void {
            const st = &s.latency;
            if (st.waiting != .return_to_hidden) return;
            const d = st.action_sample.deltas() orelse return;
            st.recordAction(d);
            st.waiting = null;
            st.generation +%= 1;
            nanoui.App.after(idleMs(), s, stepFn);
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

        fn beginAction(s: *Shell, t0: u64) void {
            const st = &s.latency;
            st.waiting = .return_to_hidden;
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
            const st = &s.latency;
            const round = st.step / 5;
            const step = st.step % 5;
            st.step += 1;
            if (round == rounds) return finish(s);
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
                    const out = s.shell.hotKey(.clipboard, false);
                    st.frame_sample.published_ns = nowNs();
                    s.apply(out);
                    s.panel_window.redraw();
                    armWatchIfWaiting(s);
                },
                else => {
                    const t0 = nowNs();
                    beginAction(s, t0);
                    const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
                    s.shell.panel.ask(.{ .open = home });
                    armWatchIfWaiting(s);
                },
            }
        }

        fn key(s: *Shell, w: Waiting, text: []const u8) void {
            const t0 = nowNs();
            beginFrame(s, w, t0);
            s.shell.panel.field.set(text);
            s.shell.panel.refresh();
            s.latency.frame_sample.published_ns = nowNs();
            s.panel_window.redraw();
            armWatchIfWaiting(s);
        }

        fn finish(s: *Shell) void {
            const st = &s.latency;
            printScalar("summon_placed", st.scalar_samples[@backingInt(ScalarMetric.summon_placed)][0..st.scalar_counts[@backingInt(ScalarMetric.summon_placed)]]);
            printScalar("summon_built", st.scalar_samples[@backingInt(ScalarMetric.summon_built)][0..st.scalar_counts[@backingInt(ScalarMetric.summon_built)]]);
            for (std.enums.values(FrameMetric)) |m| {
                const i = @backingInt(m);
                const n = st.frame_counts[i];
                printFrame(
                    @tagName(m),
                    st.frame_total[i][0..n],
                    st.frame_publish[i][0..n],
                    st.frame_build[i][0..n],
                    st.frame_present[i][0..n],
                    m.budgetP99Us(),
                );
            }
            printAction(
                st.action_total[0..st.action_count],
                st.action_publish[0..st.action_count],
                st.action_action[0..st.action_count],
                st.action_hide[0..st.action_count],
                st.action_handoff[0..st.action_count],
            );
            printScalar("hide", st.scalar_samples[@backingInt(ScalarMetric.hide)][0..st.scalar_counts[@backingInt(ScalarMetric.hide)]]);
            printResize(
                st.resize_samples[0..st.resize_runs],
                st.resize_delay_samples[0..st.resize_delay_runs],
                st.resize_waited_count,
            );
            std.debug.print(
                "NANOSPOT_LATENCY metric=launch runs=1 index_open_us={d:.0} app_scan_us={d:.0} clipboard_open_us={d:.0} clipboard_prune_us={d:.0} guide_window_us={d:.0} total_us={d:.0}\n",
                .{
                    us(st.launch.index_open_ns),
                    us(st.launch.app_scan_ns),
                    us(st.launch.clipboard_open_ns),
                    us(st.launch.clipboard_prune_ns),
                    us(st.launch.guide_window_ns),
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
                printScalar("open_handoff", &opens);
            }
            std.debug.print("NANOSPOT_LATENCY done entries={d} timeouts={d}\n", .{ st.index_entries, st.timeouts });
            std.process.exit(0);
        }

        fn us(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e3;
        }

        fn printScalar(name: []const u8, samples: []u64) void {
            const sum = stage_clock.summarize(samples);
            if (sum.runs == 0) return std.debug.print("NANOSPOT_LATENCY metric={s} runs=0\n", .{name});
            std.debug.print("NANOSPOT_LATENCY metric={s} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0}\n", .{
                name, sum.runs, us(sum.p50_ns), us(sum.p99_ns), us(sum.max_ns),
            });
        }

        fn printFrame(
            name: []const u8,
            total: []u64,
            publish: []u64,
            build: []u64,
            present: []u64,
            budget_p99_us: u64,
        ) void {
            const tot = stage_clock.summarize(total);
            if (tot.runs == 0) {
                return std.debug.print("NANOSPOT_LATENCY metric={s} runs=0 budget_p99_us={d}\n", .{ name, budget_p99_us });
            }
            const pub_s = stage_clock.summarize(publish);
            const bld_s = stage_clock.summarize(build);
            const prs_s = stage_clock.summarize(present);
            std.debug.print(
                "NANOSPOT_LATENCY metric={s} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} publish_p50_us={d:.0} build_p50_us={d:.0} present_p50_us={d:.0} budget_p99_us={d}\n",
                .{ name, tot.runs, us(tot.p50_ns), us(tot.p99_ns), us(tot.max_ns), us(pub_s.p50_ns), us(bld_s.p50_ns), us(prs_s.p50_ns), budget_p99_us },
            );
        }

        fn printAction(total: []u64, publish: []u64, action: []u64, hide: []u64, handoff: []u64) void {
            const tot = stage_clock.summarize(total);
            if (tot.runs == 0) {
                return std.debug.print("NANOSPOT_LATENCY metric=return_to_hidden runs=0 budget_p99_us={d}\n", .{Budgets.return_to_hidden_p99_us});
            }
            const pub_s = stage_clock.summarize(publish);
            const act_s = stage_clock.summarize(action);
            const hid_s = stage_clock.summarize(hide);
            const hnd_s = stage_clock.summarize(handoff);
            std.debug.print(
                "NANOSPOT_LATENCY metric=return_to_hidden runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} publish_p50_us={d:.0} action_p50_us={d:.0} hide_p50_us={d:.0} handoff_p50_us={d:.0} budget_p99_us={d}\n",
                .{ tot.runs, us(tot.p50_ns), us(tot.p99_ns), us(tot.max_ns), us(pub_s.p50_ns), us(act_s.p50_ns), us(hid_s.p50_ns), us(hnd_s.p50_ns), Budgets.return_to_hidden_p99_us },
            );
        }

        fn printResize(resize_samples: []u64, delay_samples: []u64, waited_count: u32) void {
            const res_s = stage_clock.summarize(resize_samples);
            const del_s = stage_clock.summarize(delay_samples);
            std.debug.print(
                "NANOSPOT_LATENCY metric=resize_redraw runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0} delay_runs={d} delay_p50_us={d:.0} waited_count={d}\n",
                .{ res_s.runs, us(res_s.p50_ns), us(res_s.p99_ns), us(res_s.max_ns), del_s.runs, us(del_s.p50_ns), waited_count },
            );
        }
    };
}
