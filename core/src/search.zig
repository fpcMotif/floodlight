//! One query over a View: mask prefilter, score, keep the best `k`.
//!
//! Nothing here allocates. The query, the top-k heap, and the path scratch
//! all live on the caller's stack, so a keystroke leaves no heap behind and
//! the steady-state memory of searching is zero.

const std = @import("std");
const builtin = @import("builtin");
const index = @import("index.zig");
const mask = @import("mask.zig");
const match = @import("match.zig");

const Qos = if (builtin.os.tag == .macos) struct {
    class: c_uint,
    rel: c_int,

    extern "c" fn pthread_self() ?*anyopaque;
    extern "c" fn pthread_get_qos_class_np(thread: ?*anyopaque, qos_class: *c_uint, relative_priority: *c_int) c_int;
    extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;

    fn current() ?Qos {
        var q: Qos = .{ .class = 0, .rel = 0 };
        if (pthread_get_qos_class_np(pthread_self(), &q.class, &q.rel) != 0) return null;
        return q;
    }

    fn apply(q: ?Qos) void {
        if (q) |v| if (v.class != 0) {
            _ = pthread_set_qos_class_self_np(v.class, v.rel);
        };
    }
} else struct {
    fn current() ?@This() {
        return null;
    }
    fn apply(_: ?@This()) void {}
};

pub const max_terms = 8;
pub const max_term_len = 64;
pub const max_k = 256;

pub const Hit = extern struct {
    id: u32,
    score: i32,
};

/// Space-separated terms, each of which must match. A term with a `/` is
/// matched against the whole relative path; one without is tried against
/// the name first and the path only if the name misses.
pub const Query = struct {
    terms: [max_terms][max_term_len]u8 = undefined,
    lens: [max_terms]u8 = undefined,
    has_slash: [max_terms]bool = undefined,
    term_mask: [max_terms]u32 = undefined,
    n: u8 = 0,
    path_mask: u32 = 0,
    any_slash: bool = false,
    one_miss_ceiling: i32 = 0,

    pub fn parse(text: []const u8) Query {
        var q: Query = .{};
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        var sum_ub: i32 = 0;
        while (it.next()) |raw| {
            if (q.n == max_terms) break;
            const word = raw[0..@min(raw.len, max_term_len)];
            for (word, 0..) |c, i| q.terms[q.n][i] = std.ascii.toLower(c);
            q.lens[q.n] = @intCast(word.len);
            const has_slash = std.mem.indexOfScalar(u8, word, '/') != null;
            q.has_slash[q.n] = has_slash;
            q.any_slash = q.any_slash or has_slash;
            sum_ub += match.upperBoundAnywhere(word.len);
            q.term_mask[q.n] = mask.of(word);
            q.path_mask |= q.term_mask[q.n];
            q.n += 1;
        }
        q.one_miss_ceiling = sum_ub - path_only_penalty;
        return q;
    }

    pub fn term(q: *const Query, i: usize) []const u8 {
        return q.terms[i][0..q.lens[i]];
    }
};

/// A bounded min-heap: the root is the worst hit kept, so a new candidate
/// costs one compare to reject and log k to admit.
pub const TopK = struct {
    items: [max_k]Hit = undefined,
    tie: [max_k]u64 = undefined,
    len: usize = 0,
    k: usize,

    pub fn init(k: usize) TopK {
        return .{ .k = @min(k, max_k) };
    }

    fn worse(h: *const TopK, a: usize, b: usize) bool {
        if (h.items[a].score != h.items[b].score) return h.items[a].score < h.items[b].score;
        return h.tie[a] > h.tie[b];
    }

    /// The score a candidate must reach to place, once the heap is full.
    pub fn floor(h: *const TopK) ?i32 {
        return if (h.len == h.k and h.k > 0) h.items[0].score else null;
    }

    pub fn offer(h: *TopK, hit: Hit, tie: u64) void {
        if (h.k == 0) return;
        if (h.len < h.k) {
            h.items[h.len] = hit;
            h.tie[h.len] = tie;
            h.len += 1;
            h.siftUp(h.len - 1);
            return;
        }
        const root = h.items[0];
        if (hit.score < root.score or (hit.score == root.score and tie >= h.tie[0])) return;
        h.items[0] = hit;
        h.tie[0] = tie;
        h.siftDown(0);
    }

    fn swap(h: *TopK, a: usize, b: usize) void {
        std.mem.swap(Hit, &h.items[a], &h.items[b]);
        std.mem.swap(u64, &h.tie[a], &h.tie[b]);
    }

    fn siftUp(h: *TopK, start: usize) void {
        var i = start;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (!h.worse(i, p)) break;
            h.swap(i, p);
            i = p;
        }
    }

    fn siftDown(h: *TopK, start: usize) void {
        var i = start;
        while (true) {
            const l = 2 * i + 1;
            if (l >= h.len) break;
            var m = l;
            if (l + 1 < h.len and h.worse(l + 1, l)) m = l + 1;
            if (!h.worse(m, i)) break;
            h.swap(i, m);
            i = m;
        }
    }

    /// Best first.
    pub fn sorted(h: *const TopK, out: []Hit) usize {
        const n = @min(h.len, out.len);
        var pairs: [max_k]struct { hit: Hit, tie: u64 } = undefined;
        for (0..h.len) |i| pairs[i] = .{ .hit = h.items[i], .tie = h.tie[i] };
        const Pair = @TypeOf(pairs[0]);
        std.sort.pdq(Pair, pairs[0..h.len], {}, struct {
            fn better(_: void, a: Pair, b: Pair) bool {
                if (a.hit.score != b.hit.score) return a.hit.score > b.hit.score;
                return a.tie < b.tie;
            }
        }.better);
        for (0..n) |i| out[i] = pairs[i].hit;
        return n;
    }
};

const lanes = 8;
const Vec = @Vector(lanes, u32);
const no_floor: i32 = std.math.minInt(i32);
const chunk_size: u32 = 8192;

const SharedFloor = struct {
    raw: std.atomic.Value(i32) = .init(no_floor),

    fn load(sf: *const SharedFloor) ?i32 {
        const v = sf.raw.load(.monotonic);
        return if (v == no_floor) null else v;
    }

    fn raise(sf: *SharedFloor, v: i32) i32 {
        const prev = sf.raw.fetchMax(v, .monotonic);
        return @max(prev, v);
    }
};

fn higherFloor(a: ?i32, b: ?i32) ?i32 {
    if (a) |av| {
        if (b) |bv| return @max(av, bv);
        return av;
    }
    return b;
}

const FloorState = struct {
    shared: ?*SharedFloor = null,
    local: ?i32 = null,

    fn sync(fs: *FloorState) void {
        if (fs.shared) |sf| fs.local = higherFloor(fs.local, sf.load());
    }

    fn raise(fs: *FloorState, f: i32) void {
        if (fs.local == null or f > fs.local.?) {
            fs.local = if (fs.shared) |sf| sf.raise(f) else f;
        }
    }
};

/// Requires `lo <= hi <= v.count()`.
pub fn searchRange(v: index.View, q: *const Query, lo: u32, hi: u32, heap: *TopK) void {
    var paths: PathCache = .{};
    var floor_state: FloorState = .{ .local = heap.floor() };
    searchRangeWithFloor(v, q, lo, hi, heap, &paths, &floor_state);
}

fn searchRangeWithFloor(
    v: index.View,
    q: *const Query,
    lo: u32,
    hi: u32,
    heap: *TopK,
    paths: *PathCache,
    floor_state: *FloorState,
) void {
    const need: Vec = @splat(q.path_mask);
    var use_name_mask = false;
    var masks = v.path_mask;
    var i = lo;
    var steps: u32 = 0;
    // Eight path masks per compare; most queries reject most lanes here.
    while (i + lanes <= hi) : (i += lanes) {
        if ((steps & 7) == 0) floor_state.sync();
        steps +%= 1;
        if (!q.any_slash and !use_name_mask) {
            if (floor_state.local) |f| if (f > q.one_miss_ceiling) {
                use_name_mask = true;
                masks = v.name_mask;
            };
        }
        const chunk: Vec = masks[i..][0..lanes].*;
        const pass = (chunk & need) == need;
        if (!@reduce(.Or, pass)) continue;
        const bits: u8 = @bitCast(pass);
        var m = bits;
        while (m != 0) : (m &= m - 1) {
            const lane: u32 = @ctz(m);
            scoreOne(v, q, i + lane, heap, paths, floor_state);
        }
    }
    if (i < hi) {
        floor_state.sync();
        if (!q.any_slash and !use_name_mask) {
            if (floor_state.local) |f| if (f > q.one_miss_ceiling) {
                masks = v.name_mask;
            };
        }
        while (i < hi) : (i += 1) {
            if (masks[i] & q.path_mask == q.path_mask) scoreOne(v, q, i, heap, paths, floor_state);
        }
    }
}

/// The last parent path built, so siblings reuse it. A scan appends a
/// directory's children contiguously, so in a real index most candidates
/// that need their path share a parent with the candidate before them.
const PathCache = struct {
    parent: u32 = index.no_parent - 1,
    buf: [4096]u8 = undefined,
    dir_len: usize = 0,

    fn of(c: *PathCache, v: index.View, id: u32, name: []const u8) ?[]const u8 {
        const parent = v.parent[id];
        if (parent == index.no_parent) return name;
        if (parent != c.parent) {
            var tmp: [4096]u8 = undefined;
            const dir = v.relativePath(parent, &tmp) orelse return null;
            if (dir.len + 1 > c.buf.len) return null;
            @memcpy(c.buf[0..dir.len], dir);
            c.buf[dir.len] = '/';
            c.dir_len = dir.len + 1;
            c.parent = parent;
        }
        if (c.dir_len + name.len > c.buf.len) return null;
        @memcpy(c.buf[c.dir_len..][0..name.len], name);
        return c.buf[0 .. c.dir_len + name.len];
    }
};

/// What a bare term costs when only the folders above a file match it. Large
/// enough that any name match outranks every folder-only match, which is how
/// Spotlight orders them, and which lets the path fallback be pruned once the
/// top k holds name matches.
pub const path_only_penalty: i32 = 1000;

fn scoreOne(
    v: index.View,
    q: *const Query,
    id: u32,
    heap: *TopK,
    paths: *PathCache,
    floor_state: *FloorState,
) void {
    const name_mask = v.name_mask[id];
    const active_floor = floor_state.local;
    if (q.n == 1 and !q.has_slash[0] and name_mask & q.path_mask != q.path_mask) {
        if (active_floor) |f| if (q.one_miss_ceiling < f) return;
    }

    const name = v.name(id);
    if (active_floor) |floor| {
        var bound: i32 = 0;
        for (0..q.n) |ti| {
            const term = q.term(ti);
            bound += if (q.has_slash[ti])
                match.upperBoundAnywhere(term.len)
            else if (name_mask & q.term_mask[ti] == q.term_mask[ti])
                match.upperBound(name, term)
            else
                match.upperBoundAnywhere(term.len) - path_only_penalty;
        }
        if (bound < floor) return;
    }

    var path: ?[]const u8 = null;
    var total: i32 = 0;
    for (0..q.n) |ti| {
        const term = q.term(ti);
        if (!q.has_slash[ti] and name_mask & q.term_mask[ti] == q.term_mask[ti]) {
            if (match.score(name, term, 0)) |s| {
                total += s;
                continue;
            }
        }
        if (path == null) {
            if (v.parent[id] == index.no_parent) {
                if (q.has_slash[ti]) path = name else return;
            } else {
                path = paths.of(v, id, name) orelse return;
            }
        }
        const p = path.?;
        total += match.score(p, term, p.len - name.len) orelse return;
        if (!q.has_slash[ti]) total -= path_only_penalty;
    }
    // Fewer path components and a shorter name break ties, so `Documents`
    // beats `Documents/old/Documents` for the query "documents". The id comes
    // last so equal hits order the same however the table was split.
    const tie = @as(u64, v.depth[id]) << 48 | @as(u64, @min(name.len, 0xffff)) << 32 | id;
    heap.offer(.{ .id = id, .score = total }, tie);
    if (heap.floor()) |f| floor_state.raise(f);
}

const WorkerCtx = struct {
    v: index.View,
    q: *const Query,
    n: u32,
    next: *std.atomic.Value(u32),
    shared_floor: *SharedFloor,
    heap: *TopK,
    qos: ?Qos = null,
};

fn searchWorker(ctx: WorkerCtx) void {
    if (ctx.qos != null) Qos.apply(ctx.qos);
    var paths: PathCache = .{};
    var floor_state: FloorState = .{ .shared = ctx.shared_floor };
    while (true) {
        const lo = ctx.next.fetchAdd(chunk_size, .monotonic);
        if (lo >= ctx.n) break;
        const hi = @min(ctx.n, lo + chunk_size);
        searchRangeWithFloor(ctx.v, ctx.q, lo, hi, ctx.heap, &paths, &floor_state);
    }
}

/// Splits the table across threads when it is large enough to pay for them.
pub fn search(v: index.View, text: []const u8, out: []Hit) usize {
    const q = Query.parse(text);
    if (q.n == 0) return 0;
    const n = v.count();
    const threads = threadCount(n);
    if (threads <= 1) return runSingleThread(v, &q, n, out);

    var heaps: [max_threads]TopK = undefined;
    var handles: [max_threads]?std.Thread = @splat(null);
    var next: std.atomic.Value(u32) = .init(0);
    var shared_floor: SharedFloor = .{};
    const qos = Qos.current();
    for (0..threads) |ti| {
        heaps[ti] = TopK.init(out.len);
        const ctx: WorkerCtx = .{ .v = v, .q = &q, .n = n, .next = &next, .shared_floor = &shared_floor, .heap = &heaps[ti], .qos = qos };
        if (ti == 0) continue;
        handles[ti] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, searchWorker, .{ctx}) catch null;
    }
    searchWorker(.{ .v = v, .q = &q, .n = n, .next = &next, .shared_floor = &shared_floor, .heap = &heaps[0] });

    var merged = TopK.init(out.len);
    for (0..threads) |ti| {
        if (handles[ti]) |h| h.join();
        for (heaps[ti].items[0..heaps[ti].len], heaps[ti].tie[0..heaps[ti].len]) |hit, tie| merged.offer(hit, tie);
    }
    return merged.sorted(out);
}

pub fn searchSingleThread(v: index.View, text: []const u8, out: []Hit) usize {
    const q = Query.parse(text);
    if (q.n == 0) return 0;
    return runSingleThread(v, &q, v.count(), out);
}

fn runSingleThread(v: index.View, q: *const Query, n: u32, out: []Hit) usize {
    var heap = TopK.init(out.len);
    searchRange(v, q, 0, n, &heap);
    return heap.sorted(out);
}

const max_threads = 8;
/// Below this a spawn costs more than the scan it would split.
const parallel_threshold = 200_000;

fn threadCount(n: u32) usize {
    if (n < parallel_threshold) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus, max_threads, n / (parallel_threshold / 2)));
}

const t = std.testing;

fn fixture(b: *index.Builder) !void {
    const docs = try b.add(index.no_parent, "Documents", .{ .dir = true });
    const tax = try b.add(docs, "tax", .{ .dir = true });
    _ = try b.add(tax, "2025-return.pdf", .{});
    _ = try b.add(docs, "budget.xlsx", .{});
    const proj = try b.add(index.no_parent, "projects", .{ .dir = true });
    const ns = try b.add(proj, "nanospot", .{ .dir = true });
    _ = try b.add(ns, "README.md", .{});
    _ = try b.add(ns, "Package.swift", .{});
}

fn top(v: index.View, q: []const u8, buf: []u8) ?[]const u8 {
    var hits: [8]Hit = undefined;
    const n = search(v, q, &hits);
    if (n == 0) return null;
    return v.relativePath(hits[0].id, buf);
}

test "finds by name, by path, and by terms" {
    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    try fixture(&b);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("Documents/budget.xlsx", top(b.view(), "budget", &buf).?);
    try t.expectEqualStrings("projects/nanospot/Package.swift", top(b.view(), "pkgswift", &buf).?);
    try t.expectEqualStrings("Documents/tax/2025-return.pdf", top(b.view(), "tax/2025", &buf).?);
    try t.expectEqualStrings("projects/nanospot/README.md", top(b.view(), "nano readme", &buf).?);
    try t.expect(top(b.view(), "zzz", &buf) == null);
}

test "top-k keeps the best and orders them" {
    var h = TopK.init(3);
    for ([_]i32{ 5, 1, 9, 7, 3 }, 0..) |s, i| h.offer(.{ .id = @intCast(i), .score = s }, 0);
    var out: [3]Hit = undefined;
    try t.expectEqual(@as(usize, 3), h.sorted(&out));
    try t.expectEqual(@as(i32, 9), out[0].score);
    try t.expectEqual(@as(i32, 7), out[1].score);
    try t.expectEqual(@as(i32, 5), out[2].score);
}

test "parallel path agrees with serial" {
    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    var name_buf: [32]u8 = undefined;
    const root = try b.add(index.no_parent, "r", .{ .dir = true });
    for (0..parallel_threshold + 1000) |i| {
        const nm = try std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i});
        _ = try b.add(root, nm, .{});
    }
    var par: [16]Hit = undefined;
    const np = search(b.view(), "file12345", &par);
    var heap = TopK.init(16);
    const q = Query.parse("file12345");
    searchRange(b.view(), &q, 0, b.count(), &heap);
    var ser: [16]Hit = undefined;
    const ns = heap.sorted(&ser);
    try t.expectEqual(ns, np);
    for (par[0..np], ser[0..ns]) |a, c| try t.expectEqual(a, c);
}

test "parallel search matches single-thread output identically across skewed directories and queries" {
    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    const early = try b.add(index.no_parent, "work", .{ .dir = true });
    _ = try b.add(early, "doc", .{});
    _ = try b.add(early, "doc.txt", .{});
    _ = try b.add(early, "report-2026.pdf", .{});

    var name_buf: [48]u8 = undefined;
    const docs_dir = try b.add(index.no_parent, "doc", .{ .dir = true });
    const tax_dir = try b.add(docs_dir, "tax", .{ .dir = true });
    for (0..parallel_threshold + 20_000) |i| {
        const parent = if (i < 120_000) docs_dir else if (i % 7 == 0) tax_dir else early;
        const nm = switch (i % 5) {
            0 => try std.fmt.bufPrint(&name_buf, "item-{d}-2026.txt", .{i}),
            1 => try std.fmt.bufPrint(&name_buf, "alpha-{d}.md", .{i}),
            2 => try std.fmt.bufPrint(&name_buf, "report_{d}.pdf", .{i}),
            3 => try std.fmt.bufPrint(&name_buf, "doc_note_{d}.txt", .{i}),
            else => try std.fmt.bufPrint(&name_buf, "misc-{d}.bin", .{i}),
        };
        _ = try b.add(parent, nm, .{});
    }

    const v = b.view();
    const queries = [_][]const u8{ "doc", "2026", "report", "doc tax", "doc/item", "alpha", "a", "zzzq" };
    for (queries) |qtext| {
        var par: [60]Hit = undefined;
        var ser: [60]Hit = undefined;
        const np = search(v, qtext, &par);
        const ns = searchSingleThread(v, qtext, &ser);
        try t.expectEqual(ns, np);
        for (par[0..np], ser[0..ns]) |a, c| try t.expectEqual(c, a);
    }
}

fn bruteScore(v: index.View, q: *const Query, id: u32) ?i32 {
    const name = v.name(id);
    var buf: [4096]u8 = undefined;
    const p = v.relativePath(id, &buf) orelse return null;
    const name_start = p.len - name.len;
    var total: i32 = 0;
    for (0..q.n) |ti| {
        const term = q.term(ti);
        if (!q.has_slash[ti]) {
            if (match.score(name, term, 0)) |s| {
                total += s;
                continue;
            }
            total += (match.score(p, term, name_start) orelse return null) - path_only_penalty;
        } else {
            total += match.score(p, term, name_start) orelse return null;
        }
    }
    return total;
}

test "SIMD tightening and PathCache pruning match brute-force results identically" {
    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    const lib = try b.add(index.no_parent, "lib", .{ .dir = true });
    const sub = try b.add(lib, "alpha", .{ .dir = true });
    const docs = try b.add(index.no_parent, "doc", .{ .dir = true });
    const tax = try b.add(docs, "tax", .{ .dir = true });
    var nbuf: [32]u8 = undefined;
    for (0..300) |i| {
        const nm = try std.fmt.bufPrint(&nbuf, "item_{d}.zig", .{i});
        _ = try b.add(sub, nm, .{});
    }
    _ = try b.add(sub, "x_match.zig", .{});
    _ = try b.add(lib, "beta_x.txt", .{});
    _ = try b.add(tax, "return_a.pdf", .{});
    _ = try b.add(docs, "tax_note.md", .{});
    _ = try b.add(index.no_parent, "a", .{ .dir = true });
    _ = try b.add(index.no_parent, "tax", .{ .dir = true });

    const v = b.view();
    const queries = [_][]const u8{ "item", "lib/x", "a//b", "doc tax", "lib/beta", "x" };
    for (queries) |qtext| {
        const q = Query.parse(qtext);
        var got_heap = TopK.init(16);
        searchRange(v, &q, 0, v.count(), &got_heap);
        var got: [16]Hit = undefined;
        const ng = got_heap.sorted(&got);

        var want_heap = TopK.init(16);
        var id: u32 = 0;
        while (id < v.count()) : (id += 1) {
            if (bruteScore(v, &q, id)) |s| {
                const nm = v.name(id);
                const tie = @as(u64, v.depth[id]) << 48 | @as(u64, @min(nm.len, 0xffff)) << 32 | id;
                want_heap.offer(.{ .id = id, .score = s }, tie);
            }
        }
        var want: [16]Hit = undefined;
        const nw = want_heap.sorted(&want);
        try t.expectEqual(nw, ng);
        for (got[0..ng], want[0..nw]) |a, c| try t.expectEqual(c, a);
    }
}
