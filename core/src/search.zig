//! One query over a View: mask prefilter, score, keep the best `k`.
//!
//! Nothing here allocates. The query, the top-k heap, and the path scratch
//! all live on the caller's stack, so a keystroke leaves no heap behind and
//! the steady-state memory of searching is zero.

const std = @import("std");
const index = @import("index.zig");
const mask = @import("mask.zig");
const match = @import("match.zig");

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

    pub fn parse(text: []const u8) Query {
        var q: Query = .{};
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        while (it.next()) |raw| {
            if (q.n == max_terms) break;
            const word = raw[0..@min(raw.len, max_term_len)];
            for (word, 0..) |c, i| q.terms[q.n][i] = std.ascii.toLower(c);
            q.lens[q.n] = @intCast(word.len);
            q.has_slash[q.n] = std.mem.indexOfScalar(u8, word, '/') != null;
            q.term_mask[q.n] = mask.of(word);
            q.path_mask |= q.term_mask[q.n];
            q.n += 1;
        }
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

    /// Best first. Consumes the heap order; call once at the end.
    pub fn sorted(h: *TopK, out: []Hit) usize {
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

/// One bit per id, set when the entry is gone from disk but still in the
/// mapped file. Null means nothing is deleted.
pub const Dead = ?[]const u64;

pub inline fn isDead(dead: Dead, id: u32) bool {
    const bits = dead orelse return false;
    return (bits[id >> 6] >> @intCast(id & 63)) & 1 != 0;
}

/// Scores ids in `[lo, hi)` into `heap`, skipping ids marked in `dead`.
pub fn searchRange(v: index.View, dead: Dead, q: *const Query, lo: u32, hi: u32, heap: *TopK) void {
    var paths: PathCache = .{};
    const need: Vec = @splat(q.path_mask);
    var i = lo;
    // Eight path masks per compare; most queries reject most lanes here.
    while (i + lanes <= hi) : (i += lanes) {
        const chunk: Vec = v.path_mask[i..][0..lanes].*;
        const pass = (chunk & need) == need;
        if (!@reduce(.Or, pass)) continue;
        const bits: u8 = @bitCast(pass);
        var m = bits;
        while (m != 0) : (m &= m - 1) {
            const lane: u32 = @ctz(m);
            if (!isDead(dead, i + lane)) scoreOne(v, q, i + lane, heap, &paths);
        }
    }
    while (i < hi) : (i += 1) {
        if (v.path_mask[i] & q.path_mask == q.path_mask and !isDead(dead, i)) scoreOne(v, q, i, heap, &paths);
    }
}

/// The last parent path built, so siblings reuse it. A scan appends a
/// directory's children contiguously, so in a real index most candidates
/// that need their path share a parent with the candidate before them.
const PathCache = struct {
    parent: u32 = index.no_parent - 1,
    buf: [4096]u8 = undefined,
    dir_len: usize = 0,

    fn of(c: *PathCache, v: index.View, id: u32) ?[]const u8 {
        const parent = v.parent[id];
        const name = v.name(id);
        if (parent == index.no_parent) return name;
        if (parent != c.parent) {
            var tmp: [4096]u8 = undefined;
            const dir = v.relativePath(parent, &tmp) orelse return null;
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

fn scoreOne(v: index.View, q: *const Query, id: u32, heap: *TopK, paths: *PathCache) void {
    const lazy: struct {
        v: index.View,
        id: u32,
        cache: *PathCache,
        pub fn path(s: @This()) ?[]const u8 {
            return s.cache.of(s.v, s.id);
        }
    } = .{ .v = v, .id = id, .cache = paths };
    scoreEntry(q, .{ .id = id, .name = v.name(id), .name_mask = v.name_mask[id], .depth = v.depth[id] }, heap, lazy);
}

/// What the scorer needs to know about one entry before it has a path.
pub const Entry = struct {
    id: u32,
    name: []const u8,
    name_mask: u32,
    depth: u8,
};

/// Scores one mask survivor into `heap`. `source.path()` yields the entry's
/// relative path and is called only when a term misses the name, so mapped
/// entries build theirs lazily and overlay entries hand back a stored one.
pub fn scoreEntry(q: *const Query, e: Entry, heap: *TopK, source: anytype) void {
    if (heap.floor()) |floor| {
        var bound: i32 = 0;
        for (0..q.n) |ti| {
            const term = q.term(ti);
            bound += if (q.has_slash[ti])
                match.upperBoundAnywhere(term.len)
            else if (e.name_mask & q.term_mask[ti] == q.term_mask[ti])
                match.upperBound(e.name, term)
            else
                match.upperBoundAnywhere(term.len) - path_only_penalty;
        }
        if (bound < floor) return;
    }

    var path: ?[]const u8 = null;
    var total: i32 = 0;
    for (0..q.n) |ti| {
        const term = q.term(ti);
        if (!q.has_slash[ti] and e.name_mask & q.term_mask[ti] == q.term_mask[ti]) {
            if (match.score(e.name, term, 0)) |s| {
                total += s;
                continue;
            }
        }
        if (path == null) path = source.path() orelse return;
        const p = path.?;
        total += match.score(p, term, p.len - e.name.len) orelse return;
        if (!q.has_slash[ti]) total -= path_only_penalty;
    }
    // Fewer path components and a shorter name break ties, so `Documents`
    // beats `Documents/old/Documents` for the query "documents". The id comes
    // last so equal hits order the same however the table was split.
    const tie = @as(u64, e.depth) << 48 | @as(u64, @min(e.name.len, 0xffff)) << 32 | e.id;
    heap.offer(.{ .id = e.id, .score = total }, tie);
}

pub fn search(v: index.View, text: []const u8, out: []Hit) usize {
    const q = Query.parse(text);
    if (q.n == 0) return 0;
    var heap = TopK.init(out.len);
    searchInto(v, null, &q, &heap);
    return heap.sorted(out);
}

/// Offers every live match in `v` to `heap`. Splits the table across threads
/// when it is large enough to pay for them; the per-thread heaps live on this
/// stack frame, so a parallel query allocates nothing either.
pub fn searchInto(v: index.View, dead: Dead, q: *const Query, heap: *TopK) void {
    const n = v.count();
    const threads = threadCount(n);
    if (threads <= 1) return searchRange(v, dead, q, 0, n, heap);

    var heaps: [max_threads]TopK = undefined;
    var handles: [max_threads]?std.Thread = @splat(null);
    const per = (n + threads - 1) / threads;
    for (0..threads) |ti| {
        heaps[ti] = TopK.init(heap.k);
        const lo: u32 = @intCast(@min(n, ti * per));
        const hi: u32 = @intCast(@min(n, lo + per));
        if (ti == 0) continue;
        handles[ti] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, searchRange, .{ v, dead, q, lo, hi, &heaps[ti] }) catch null;
        if (handles[ti] == null) searchRange(v, dead, q, lo, hi, &heaps[ti]);
    }
    searchRange(v, dead, q, 0, @intCast(@min(n, per)), &heaps[0]);

    for (0..threads) |ti| {
        if (handles[ti]) |h| h.join();
        for (heaps[ti].items[0..heaps[ti].len], heaps[ti].tie[0..heaps[ti].len]) |hit, tie| heap.offer(hit, tie);
    }
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
    const fl = try b.add(proj, "floodlight", .{ .dir = true });
    _ = try b.add(fl, "README.md", .{});
    _ = try b.add(fl, "Package.swift", .{});
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
    try t.expectEqualStrings("projects/floodlight/Package.swift", top(b.view(), "pkgswift", &buf).?);
    try t.expectEqualStrings("Documents/tax/2025-return.pdf", top(b.view(), "tax/2025", &buf).?);
    try t.expectEqualStrings("projects/floodlight/README.md", top(b.view(), "flood readme", &buf).?);
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
    searchRange(b.view(), null, &q, 0, b.count(), &heap);
    var ser: [16]Hit = undefined;
    const ns = heap.sorted(&ser);
    try t.expectEqual(ns, np);
    for (par[0..np], ser[0..ns]) |a, c| try t.expectEqual(a, c);
}
