//! `flcore`: build, query, and measure an index from the command line.
//!
//!   flcore index <root> <out.flix>
//!   flcore search <in.flix> <query...>
//!   flcore bench <in.flix> [query ...]
//!   flcore synth <out.flix> <count>
//!
//! `bench` exists so a latency or memory claim about the engine is a number
//! someone can reproduce, not a sentence in an issue.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("root.zig");
const index = core.index;
const search = core.search;
const sys = core.sys;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &fw.interface;
    try run(gpa, out, args);
    try out.flush();
}

fn run(gpa: std.mem.Allocator, out: *std.Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 3) return usage(out);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "index") and args.len == 4) return cmdIndex(gpa, out, args[2], args[3]);
    if (std.mem.eql(u8, cmd, "search") and args.len >= 4) return cmdSearch(gpa, out, args[2], args[3..]);
    if (std.mem.eql(u8, cmd, "bench")) return cmdBench(gpa, out, args[2], args[3..]);
    if (std.mem.eql(u8, cmd, "synth") and args.len == 4) return cmdSynth(gpa, out, args[2], args[3]);
    return usage(out);
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\usage:
        \\  flcore index <root> <out.flix>
        \\  flcore search <in.flix> <query...>
        \\  flcore bench <in.flix> [query ...]
        \\  flcore synth <out.flix> <count>
        \\
    );
}

fn cmdIndex(gpa: std.mem.Allocator, out: *std.Io.Writer, root: []const u8, path: []const u8) !void {
    var b = index.Builder.init(gpa);
    defer b.deinit();
    var timer = Timer.begin();
    try core.scan.scan(&b, root, .{});
    const scan_ns = timer.lap();
    try b.writeFile(sys.cwd, path);
    const write_ns = timer.read();
    const size = try fileSize(path);
    try out.print("entries={d} scan_ms={d:.1} write_ms={d:.1} file_bytes={d} bytes_per_entry={d:.1}\n", .{
        b.count(),
        ms(scan_ns),
        ms(write_ns),
        size,
        @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(@max(1, b.count()))),
    });
}

fn cmdSearch(gpa: std.mem.Allocator, out: *std.Io.Writer, path: []const u8, words: []const [:0]const u8) !void {
    var m = try index.Mapped.open(sys.cwd, path);
    defer m.close();
    const q = try std.mem.join(gpa, " ", @ptrCast(words));
    defer gpa.free(q);

    var hits: [20]search.Hit = undefined;
    var timer = Timer.begin();
    const n = search.search(m.view, q, &hits);
    const ns = timer.read();
    var buf: [4096]u8 = undefined;
    for (hits[0..n]) |h| {
        try out.print("{d:>6}  {s}\n", .{ h.score, m.view.relativePath(h.id, &buf) orelse "?" });
    }
    try out.print("-- {d} hits in {d:.3} ms over {d} entries\n", .{ n, ms(ns), m.view.count() });
}

const default_queries = [_][]const u8{
    "r", "re", "rea", "read", "readme", "pkg", "main.zig", "conf", "lib/x", "zzzq", "doc tax", "png",
};

fn cmdBench(gpa: std.mem.Allocator, out: *std.Io.Writer, path: []const u8, given: []const [:0]const u8) !void {
    const rss_before = residentBytes();
    var timer = Timer.begin();
    var m = try index.Mapped.open(sys.cwd, path);
    defer m.close();
    const open_ns = timer.read();

    var queries: std.ArrayList([]const u8) = .empty;
    defer queries.deinit(gpa);
    if (given.len == 0) {
        try queries.appendSlice(gpa, &default_queries);
    } else for (given) |g| try queries.append(gpa, g);

    // One untimed pass faults the mapping in, so the numbers below are the
    // warm, every-keystroke cost rather than first-touch disk reads.
    var hits: [60]search.Hit = undefined;
    for (queries.items) |q| _ = search.search(m.view, q, &hits);

    const runs = 50;
    var samples: [runs]u64 = undefined;
    try out.print("entries={d} open_us={d:.1}\n", .{ m.view.count(), us(open_ns) });
    for (queries.items) |q| {
        var n: usize = 0;
        for (&samples) |*s| {
            timer.reset();
            n = search.search(m.view, q, &hits);
            s.* = timer.read();
        }
        std.sort.pdq(u64, &samples, {}, std.sort.asc(u64));
        try out.print("query={s: <10} hits={d: >2} p50_us={d: >8.1} p99_us={d: >8.1}\n", .{
            q, n, us(samples[runs / 2]), us(samples[runs - 1]),
        });
    }
    const rss_after = residentBytes();
    try out.writeAll("rss_before_open_kb=");
    try writeKb(out, rss_before);
    try out.writeAll(" rss_after_bench_kb=");
    try writeKb(out, rss_after);
    try out.print(" index_mapped_kb={d}\n", .{m.bytes.len / 1024});
}

fn writeKb(out: *std.Io.Writer, bytes: ?usize) !void {
    if (bytes) |b| try out.print("{d}", .{b / 1024}) else try out.writeAll("unavailable");
}

/// A deterministic tree shaped like a home folder: a few wide directories,
/// a long tail of deep ones, names drawn from words people actually type.
fn cmdSynth(gpa: std.mem.Allocator, out: *std.Io.Writer, path: []const u8, count_text: []const u8) !void {
    const want = try std.fmt.parseInt(u32, count_text, 10);
    var b = index.Builder.init(gpa);
    defer b.deinit();
    try b.setRoot("/Users/synthetic");
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const words = [_][]const u8{
        "readme",  "notes",  "budget", "report", "invoice", "photo",  "main",   "index",
        "config",  "test",   "draft",  "final",  "backup",  "music",  "album",  "track",
        "project", "source", "lib",    "util",   "server",  "client", "design", "mock",
        "tax",     "2024",   "2025",   "q3",     "meeting", "resume", "letter", "scan",
    };
    const exts = [_][]const u8{ ".md", ".txt", ".pdf", ".png", ".jpg", ".swift", ".zig", ".json", ".xlsx", "" };

    var dirs: std.ArrayList(u32) = .empty;
    defer dirs.deinit(gpa);
    var name_buf: [96]u8 = undefined;
    while (b.count() < want) {
        const parent = if (dirs.items.len == 0 or r.uintLessThan(u32, 16) == 0)
            index.no_parent
        else
            dirs.items[r.uintLessThan(usize, dirs.items.len)];
        const is_dir = r.uintLessThan(u32, 10) == 0;
        const w1 = words[r.uintLessThan(usize, words.len)];
        const w2 = words[r.uintLessThan(usize, words.len)];
        const ext = if (is_dir) "" else exts[r.uintLessThan(usize, exts.len)];
        const sep: []const u8 = switch (r.uintLessThan(u32, 3)) {
            0 => "-",
            1 => "_",
            else => "",
        };
        const nm = try std.fmt.bufPrint(&name_buf, "{s}{s}{s}{d}{s}", .{ w1, sep, w2, r.uintLessThan(u32, 1000), ext });
        const id = try b.add(parent, nm, .{ .dir = is_dir });
        if (is_dir) try dirs.append(gpa, id);
    }
    try b.writeFile(sys.cwd, path);
    const size = try fileSize(path);
    try out.print("entries={d} file_bytes={d}\n", .{ b.count(), size });
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e3;
}

const Timer = struct {
    start: u64,

    fn begin() Timer {
        return .{ .start = sys.monotonicNs() };
    }

    fn read(t: *const Timer) u64 {
        return sys.monotonicNs() - t.start;
    }

    fn lap(t: *Timer) u64 {
        const now = sys.monotonicNs();
        defer t.start = now;
        return now - t.start;
    }

    fn reset(t: *Timer) void {
        t.start = sys.monotonicNs();
    }
};

fn fileSize(path: []const u8) !u64 {
    const fd = try sys.openat(sys.cwd, path, .read);
    defer sys.close(fd);
    return sys.size(fd);
}

/// Current resident set, not the peak: the peak would include whatever the
/// argument parsing and the first search touched and forgot. Null when the
/// system would not report it, so bench never prints a made-up zero.
fn residentBytes() ?usize {
    switch (builtin.os.tag) {
        .linux => {
            var buf: [256]u8 = undefined;
            const fd = sys.openat(sys.cwd, "/proc/self/statm", .read) catch return null;
            defer sys.close(fd);
            const n = std.posix.read(fd, &buf) catch return null;
            var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
            _ = it.next();
            const pages = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
            return pages * std.heap.pageSize();
        },
        .macos => {
            var info: std.c.mach_task_basic_info = undefined;
            var count = std.c.MACH.TASK.BASIC.INFO_COUNT;
            const rc = std.c.task_info(std.c.mach_task_self(), std.c.MACH.TASK.BASIC.INFO, @ptrCast(&info), &count);
            if (rc != 0) return null;
            return @intCast(info.resident_size);
        },
        else => return null,
    }
}
