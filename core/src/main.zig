//! `flcore`: build, query, and measure an index from the command line.
//!
//!   flcore index <root> <out.flix>
//!   flcore search <in.flix> <query...>
//!   flcore bench <in.flix> [query ...]
//!   flcore synth <out.flix> <count> [--scatter]
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
    defer out.flush() catch {};

    if (args.len < 3) return usage(out);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "index") and args.len == 4) return cmdIndex(gpa, out, args[2], args[3]);
    if (std.mem.eql(u8, cmd, "search") and args.len >= 4) return cmdSearch(gpa, out, args[2], args[3..]);
    if (std.mem.eql(u8, cmd, "bench")) return cmdBench(gpa, out, args[2], args[3..]);
    if (std.mem.eql(u8, cmd, "synth") and args.len == 4) return cmdSynth(gpa, out, args[2], args[3], false);
    if (std.mem.eql(u8, cmd, "synth") and args.len == 5 and std.mem.eql(u8, args[4], "--scatter")) return cmdSynth(gpa, out, args[2], args[3], true);
    return usage(out);
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\usage:
        \\  flcore index <root> <out.flix>
        \\  flcore search <in.flix> <query...>
        \\  flcore bench <in.flix> [query ...]
        \\  flcore synth <out.flix> <count> [--scatter]
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
    try out.print("rss_before_open_kb={d} rss_after_bench_kb={d} index_mapped_kb={d}\n", .{
        rss_before / 1024, rss_after / 1024, m.bytes.len / 1024,
    });
}

/// A deterministic tree shaped like a home folder: a few wide directories,
/// a long tail of deep ones, names drawn from words people actually type.
/// Written in the order a scan writes entries; `--scatter` keeps generation
/// order instead, which puts siblings far apart, as a worst case.
fn cmdSynth(gpa: std.mem.Allocator, out: *std.Io.Writer, path: []const u8, count_text: []const u8, scatter: bool) !void {
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
    if (scatter) {
        try b.writeFile(sys.cwd, path);
    } else {
        var scanned = index.Builder.init(gpa);
        defer scanned.deinit();
        try scanned.setRoot(b.root.items);
        try inScanOrder(gpa, b.view(), &scanned);
        try scanned.writeFile(sys.cwd, path);
    }
    const size = try fileSize(path);
    try out.print("entries={d} file_bytes={d}\n", .{ b.count(), size });
}

/// Re-adds `v`'s entries in the order `scan.walk` would have added them: a
/// directory's children together, then each child directory's subtree in
/// turn. The generator above picks parents at random, so without this a
/// file's siblings are scattered across the table, which no real index is,
/// and every parent lookup in a benchmark would miss the cache.
fn inScanOrder(gpa: std.mem.Allocator, v: index.View, dst: *index.Builder) !void {
    const n = v.count();
    // Children of each directory as a linked list, in id order.
    const first = try gpa.alloc(u32, n);
    defer gpa.free(first);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const renamed = try gpa.alloc(u32, n);
    defer gpa.free(renamed);
    @memset(first, index.no_parent);
    var roots: u32 = index.no_parent;
    var id = n;
    while (id > 0) {
        id -= 1;
        const head = if (v.parent[id] == index.no_parent) &roots else &first[v.parent[id]];
        next[id] = head.*;
        head.* = id;
    }

    // Each frame is a directory whose children are listed but whose
    // subdirectories are not walked yet, holding the next child to visit.
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, try addChildren(v, dst, roots, index.no_parent, next, renamed));
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        var c = top.*;
        while (c != index.no_parent and !v.flags[c].dir) c = next[c];
        if (c == index.no_parent) {
            _ = stack.pop();
            continue;
        }
        top.* = next[c];
        try stack.append(gpa, try addChildren(v, dst, first[c], renamed[c], next, renamed));
    }
}

/// Adds the list starting at `head` under `parent` and returns `head`.
fn addChildren(v: index.View, dst: *index.Builder, head: u32, parent: u32, next: []const u32, renamed: []u32) !u32 {
    var c = head;
    while (c != index.no_parent) : (c = next[c]) {
        renamed[c] = try dst.add(parent, v.name(c), v.flags[c]);
    }
    return head;
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
/// argument parsing and the first search touched and forgot.
fn residentBytes() usize {
    switch (builtin.os.tag) {
        .linux => {
            var buf: [256]u8 = undefined;
            const fd = sys.openat(sys.cwd, "/proc/self/statm", .read) catch return 0;
            defer sys.close(fd);
            const n = std.posix.read(fd, &buf) catch return 0;
            var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
            _ = it.next();
            const pages = std.fmt.parseInt(usize, it.next() orelse return 0, 10) catch return 0;
            return pages * std.heap.pageSize();
        },
        else => {
            const ru = std.posix.getrusage(std.posix.rusage.SELF);
            return @intCast(ru.maxrss);
        },
    }
}
