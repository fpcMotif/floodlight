//! Latency probe CLI flag (`--nanospot-latency-session`): drives the real
//! panel and times each input to the frame that presents it.
const std = @import("std");
const nanoui = @import("nanoui");
const mac = @import("mac.zig");

pub const session_flag = "--nanospot-latency-session";
pub const open_flag = "--nanospot-latency-open";

const rounds = 30;
const open_runs = 5;
const gap_ms = 250;
const frame_timeout_ms = 1000;

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
const clock_uptime_raw: c_int = 8;

/// How long the panel stays hidden before the next summon
/// (`NANOSPOT_LATENCY_IDLE_MS`): a quick re-summon and one after a rest differ.
fn idleMs() u32 {
    const raw = std.c.getenv("NANOSPOT_LATENCY_IDLE_MS") orelse return gap_ms;
    return std.fmt.parseInt(u32, std.mem.span(raw), 10) catch gap_ms;
}

fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

const Metric = enum { summon_placed, summon_built, summon, keystroke_new_rows, keystroke_same_rows, switch_to_board, hide };

const queries = [_][]const u8{ "a", "s", "c", "m", "t", "p", "n", "f", "d", "r" };

pub const State = struct {
    step: u32 = 0,
    waiting: ?Metric = null,
    built: bool = false,
    started_ns: u64 = 0,
    generation: u32 = 0,
    timeouts: u32 = 0,
    counts: [std.enums.values(Metric).len]usize = @splat(0),
    samples: [std.enums.values(Metric).len][rounds]u64 = undefined,
    measure_open: bool = false,

    fn record(st: *State, m: Metric, ns: u64) void {
        const i = @backingInt(m);
        if (st.counts[i] == rounds) return;
        st.samples[i][st.counts[i]] = ns;
        st.counts[i] += 1;
    }
};

pub fn Runner(comptime Shell: type) type {
    return struct {
        pub fn launched(ctx: ?*anyopaque) callconv(.c) void {
            nanoui.App.after(gap_ms * 4, ctx, stepFn);
        }

        /// Call after every frame; a frame that presents ends the interval a step began.
        pub fn frame(s: *Shell, presenting: bool) void {
            const st = &s.latency;
            const m = st.waiting orelse return;
            if (m == .summon and !st.built) {
                st.built = true;
                st.record(.summon_built, nowNs() - st.started_ns);
            }
            if (!presenting) return;
            st.record(m, nowNs() - st.started_ns);
            st.waiting = null;
            st.generation +%= 1;
            nanoui.App.after(gap_ms, s, stepFn);
        }

        fn await(s: *Shell, m: Metric, t0: u64) void {
            const st = &s.latency;
            st.waiting = m;
            st.built = false;
            st.started_ns = t0;
            st.generation +%= 1;
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
                    s.apply(s.shell.hotKey(.search, false));
                    st.record(.summon_placed, nowNs() - t0);
                    await(s, .summon, t0);
                },
                1 => key(s, .keystroke_new_rows, q),
                2 => {
                    var buf: [8]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{s} ", .{q}) catch q;
                    key(s, .keystroke_same_rows, text);
                },
                3 => {
                    const t0 = nowNs();
                    s.apply(s.shell.hotKey(.clipboard, false));
                    s.panel_window.redraw();
                    await(s, .switch_to_board, t0);
                },
                else => {
                    const t0 = nowNs();
                    s.apply(s.shell.settle(.hide));
                    st.record(.hide, nowNs() - t0);
                    nanoui.App.after(idleMs(), s, stepFn);
                },
            }
        }

        fn key(s: *Shell, m: Metric, text: []const u8) void {
            const t0 = nowNs();
            s.shell.panel.field.set(text);
            s.shell.panel.refresh();
            s.panel_window.redraw();
            await(s, m, t0);
        }

        fn finish(s: *Shell) void {
            const st = &s.latency;
            for (std.enums.values(Metric)) |m| {
                const i = @backingInt(m);
                print(@tagName(m), st.samples[i][0..st.counts[i]]);
            }
            if (st.measure_open) {
                var opens: [open_runs]u64 = undefined;
                const home = std.mem.span(std.c.getenv("HOME") orelse "/tmp");
                for (&opens) |*o| {
                    const t0 = nowNs();
                    mac.open(home);
                    o.* = nowNs() - t0;
                }
                print("open_handoff", &opens);
            }
            std.debug.print("NANOSPOT_LATENCY done timeouts={d}\n", .{st.timeouts});
            std.process.exit(0);
        }

        fn print(name: []const u8, samples: []u64) void {
            if (samples.len == 0) return std.debug.print("NANOSPOT_LATENCY metric={s} runs=0\n", .{name});
            std.sort.pdq(u64, samples, {}, std.sort.asc(u64));
            const n = samples.len;
            const us = struct {
                fn f(ns: u64) f64 {
                    return @as(f64, @floatFromInt(ns)) / 1e3;
                }
            }.f;
            std.debug.print("NANOSPOT_LATENCY metric={s} runs={d} p50_us={d:.0} p99_us={d:.0} max_us={d:.0}\n", .{
                name, n, us(samples[n / 2]), us(samples[@min(n - 1, n * 99 / 100)]), us(samples[n - 1]),
            });
        }
    };
}
