const std = @import("std");

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
const clock_uptime_raw: c_int = 8;

pub fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

pub const FrameDeltas = struct {
    publish_ns: u64,
    build_ns: u64,
    present_ns: u64,
    total_ns: u64,
};

pub const FrameSample = struct {
    input_ns: u64 = 0,
    published_ns: ?u64 = null,
    built_ns: ?u64 = null,
    presented_ns: ?u64 = null,

    pub fn deltas(s: FrameSample) ?FrameDeltas {
        const pres_t = s.presented_ns orelse return null;
        const pub_t = s.published_ns orelse s.input_ns;
        const built_t = s.built_ns orelse pres_t;
        return .{
            .publish_ns = pub_t -| s.input_ns,
            .build_ns = built_t -| pub_t,
            .present_ns = pres_t -| built_t,
            .total_ns = pres_t -| s.input_ns,
        };
    }
};

pub const ActionDeltas = struct {
    publish_ns: u64,
    action_ns: u64,
    hide_ns: u64,
    handoff_ns: u64,
    total_ns: u64,
};

pub const SwitchDeltas = struct {
    presence_ns: u64,
    store_query_ns: u64,
    resize_ns: u64,
    order_in_ns: u64,
};

pub const SwitchSample = struct {
    input_ns: u64 = 0,
    presence_ns: ?u64 = null,
    store_query_ns: ?u64 = null,
    resized_ns: ?u64 = null,
    ordered_ns: ?u64 = null,

    pub fn deltas(s: SwitchSample) SwitchDeltas {
        const pres_t = s.presence_ns orelse s.input_ns;
        const query_t = s.store_query_ns orelse pres_t;
        const res_t = s.resized_ns orelse query_t;
        const ord_t = s.ordered_ns orelse res_t;
        return .{
            .presence_ns = pres_t -| s.input_ns,
            .store_query_ns = query_t -| pres_t,
            .resize_ns = res_t -| query_t,
            .order_in_ns = ord_t -| res_t,
        };
    }
};

pub const ActionSample = struct {
    input_ns: u64 = 0,
    apply_ns: ?u64 = null,
    action_start_ns: ?u64 = null,
    action_end_ns: ?u64 = null,
    hide_start_ns: ?u64 = null,
    hide_end_ns: ?u64 = null,

    pub fn deltas(s: ActionSample) ?ActionDeltas {
        const hide_end = s.hide_end_ns orelse return null;
        const apply_t = s.apply_ns orelse s.input_ns;
        const action_ns = if (s.action_start_ns != null and s.action_end_ns != null)
            s.action_end_ns.? -| s.action_start_ns.?
        else
            0;
        const hide_ns = if (s.hide_start_ns) |hs| hide_end -| hs else 0;
        const handoff_ns = if (s.action_end_ns) |ae| ae -| s.input_ns else 0;
        return .{
            .publish_ns = apply_t -| s.input_ns,
            .action_ns = action_ns,
            .hide_ns = hide_ns,
            .handoff_ns = handoff_ns,
            .total_ns = hide_end -| s.input_ns,
        };
    }
};

pub const Summary = struct {
    runs: usize,
    p50_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

pub fn summarize(samples: []u64) Summary {
    if (samples.len == 0) return .{ .runs = 0, .p50_ns = 0, .p99_ns = 0, .max_ns = 0 };
    std.sort.pdq(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;
    return .{
        .runs = n,
        .p50_ns = samples[n / 2],
        .p99_ns = samples[@min(n - 1, n * 99 / 100)],
        .max_ns = samples[n - 1],
    };
}

const t = std.testing;

test "FrameSample deltas sum to total for indirect and direct presents" {
    const missing: FrameSample = .{ .input_ns = 100, .published_ns = 150, .built_ns = 250 };
    try t.expect(missing.deltas() == null);

    const indirect: FrameSample = .{ .input_ns = 100, .published_ns = 150, .built_ns = 250, .presented_ns = 400 };
    const id = indirect.deltas().?;
    try t.expectEqual(@as(u64, 50), id.publish_ns);
    try t.expectEqual(@as(u64, 100), id.build_ns);
    try t.expectEqual(@as(u64, 150), id.present_ns);
    try t.expectEqual(@as(u64, 300), id.total_ns);
    try t.expectEqual(id.total_ns, id.publish_ns + id.build_ns + id.present_ns);

    const direct: FrameSample = .{ .input_ns = 100, .published_ns = 150, .built_ns = 400, .presented_ns = 400 };
    const dd = direct.deltas().?;
    try t.expectEqual(@as(u64, 50), dd.publish_ns);
    try t.expectEqual(@as(u64, 250), dd.build_ns);
    try t.expectEqual(@as(u64, 0), dd.present_ns);
    try t.expectEqual(@as(u64, 300), dd.total_ns);
    try t.expectEqual(dd.total_ns, dd.publish_ns + dd.build_ns + dd.present_ns);

    const no_build: FrameSample = .{ .input_ns = 100, .published_ns = 150, .presented_ns = 400 };
    const nb = no_build.deltas().?;
    try t.expectEqual(@as(u64, 50), nb.publish_ns);
    try t.expectEqual(@as(u64, 250), nb.build_ns);
    try t.expectEqual(@as(u64, 0), nb.present_ns);
    try t.expectEqual(@as(u64, 300), nb.total_ns);
}

test "ActionSample deltas handle open-before-hide and hide-before-open without underflow" {
    const incomplete: ActionSample = .{ .input_ns = 1000, .apply_ns = 1200 };
    try t.expect(incomplete.deltas() == null);

    const open_first: ActionSample = .{
        .input_ns = 1000,
        .apply_ns = 1200,
        .action_start_ns = 1250,
        .action_end_ns = 35_250,
        .hide_start_ns = 35_300,
        .hide_end_ns = 35_800,
    };
    const ofd = open_first.deltas().?;
    try t.expectEqual(@as(u64, 200), ofd.publish_ns);
    try t.expectEqual(@as(u64, 34_000), ofd.action_ns);
    try t.expectEqual(@as(u64, 500), ofd.hide_ns);
    try t.expectEqual(@as(u64, 34_250), ofd.handoff_ns);
    try t.expectEqual(@as(u64, 34_800), ofd.total_ns);

    const hide_first: ActionSample = .{
        .input_ns = 1000,
        .apply_ns = 1200,
        .hide_start_ns = 1210,
        .hide_end_ns = 1710,
        .action_start_ns = 1720,
        .action_end_ns = 1734,
    };
    const hfd = hide_first.deltas().?;
    try t.expectEqual(@as(u64, 200), hfd.publish_ns);
    try t.expectEqual(@as(u64, 14), hfd.action_ns);
    try t.expectEqual(@as(u64, 500), hfd.hide_ns);
    try t.expectEqual(@as(u64, 734), hfd.handoff_ns);
    try t.expectEqual(@as(u64, 710), hfd.total_ns);
}

test "summarize computes p50, p99, and max for empty, single, and 30-sample inputs" {
    var empty = [_]u64{};
    const es = summarize(&empty);
    try t.expectEqual(@as(usize, 0), es.runs);
    try t.expectEqual(@as(u64, 0), es.p50_ns);
    try t.expectEqual(@as(u64, 0), es.p99_ns);
    try t.expectEqual(@as(u64, 0), es.max_ns);

    var one = [_]u64{42};
    const os = summarize(&one);
    try t.expectEqual(@as(usize, 1), os.runs);
    try t.expectEqual(@as(u64, 42), os.p50_ns);
    try t.expectEqual(@as(u64, 42), os.p99_ns);
    try t.expectEqual(@as(u64, 42), os.max_ns);

    var thirty: [30]u64 = undefined;
    for (0..30) |i| thirty[i] = @intCast(30 - i);
    const ts = summarize(&thirty);
    try t.expectEqual(@as(usize, 30), ts.runs);
    try t.expectEqual(@as(u64, 16), ts.p50_ns);
    try t.expectEqual(@as(u64, 30), ts.p99_ns);
    try t.expectEqual(@as(u64, 30), ts.max_ns);
}

test "SwitchSample deltas split presence, store query, resize, and order-in" {
    const full: SwitchSample = .{
        .input_ns = 1000,
        .presence_ns = 1150,
        .store_query_ns = 2050,
        .resized_ns = 3300,
        .ordered_ns = 8300,
    };
    const d = full.deltas();
    try t.expectEqual(@as(u64, 150), d.presence_ns);
    try t.expectEqual(@as(u64, 900), d.store_query_ns);
    try t.expectEqual(@as(u64, 1250), d.resize_ns);
    try t.expectEqual(@as(u64, 5000), d.order_in_ns);

    const no_window: SwitchSample = .{
        .input_ns = 500,
        .presence_ns = 550,
        .store_query_ns = 800,
    };
    const nw = no_window.deltas();
    try t.expectEqual(@as(u64, 50), nw.presence_ns);
    try t.expectEqual(@as(u64, 250), nw.store_query_ns);
    try t.expectEqual(@as(u64, 0), nw.resize_ns);
    try t.expectEqual(@as(u64, 0), nw.order_in_ns);
}
