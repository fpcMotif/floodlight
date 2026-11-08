//! A slash term's `match.score` against a file's full path, computed from
//! per-directory state instead of from the path.
//!
//! Building and scoring a path costs a walk up the parent chain, and in an
//! index whose siblings are not contiguous every step of that walk is a cache
//! miss. Here each directory carries a small summary of how the term's match
//! can end inside its path, built from its parent's summary and its own name.
//! A file is then scored from its parent's summary and its own name alone,
//! and no ancestor is read unless its summary is not cached yet.
//!
//! The result is exactly `match.score(path, term, path.len - name.len)`. The
//! window it scores is fixed by two passes: a forward pass that finds where
//! the first full match ends, and a backward pass from there that finds the
//! tightest start. Both passes, and the scoring loop between them, are
//! greedy and read one character at a time, so each can be paused at a `/`
//! and resumed in the next component. A bonus only ever looks one character
//! back, and every component begins after a `/` (or at the start of the
//! path), so a component's bonuses never depend on the one above it.

const std = @import("std");
const index = @import("index.zig");
const match = @import("match.zig");

/// Longer slash terms take the full-path route: the summary grows with the
/// term, and a term this long is pasted, not typed.
pub const max_len = 16;

/// Names longer than this are scored through the full path. No file system
/// Floodlight indexes allows one; the bound only sizes a stack buffer.
pub const max_name = 1024;

/// One stretch of path the passes read: a directory's name with its trailing
/// `/`, or a file's name. `low` is `text` lowercased once, so the passes
/// compare bytes directly; the bonuses still read `text` for case.
const Piece = struct {
    text: []const u8,
    low: []const u8,
    /// Which bytes occur in `low`. Most components hold few of a term's
    /// characters, and a pass whose next character is absent can stop
    /// without reading the piece.
    has: [4]u64,
    /// The file's own name: it earns the in-name bonus, and the name-start
    /// bonus at 0.
    is_name: bool,

    fn init(buf: *[max_name + 1]u8, text: []const u8, is_name: bool) Piece {
        var has: [4]u64 = @splat(0);
        for (text, buf[0..text.len]) |c, *l| {
            l.* = std.ascii.toLower(c);
            has[l.* >> 6] |= @as(u64, 1) << @intCast(l.* & 63);
        }
        return .{ .text = text, .low = buf[0..text.len], .has = has, .is_name = is_name };
    }

    inline fn holds(p: *const Piece, c: u8) bool {
        return p.has[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0;
    }
};

/// The scoring loop's running state, carried across pieces.
const Run = struct {
    /// Term characters matched so far.
    j: usize,
    score: i32,
    /// Where the last match was, relative to the current piece's start, so
    /// one before it for a match at the end of the previous piece. Null
    /// before the first match.
    last: ?isize,

    /// Characters read since the last match by the end of `p`, saturating
    /// where the gap penalty stops growing.
    fn gapAfter(r: Run, p: Piece) u8 {
        const gap = @as(isize, @intCast(p.low.len)) - 1 - r.last.?;
        return @intCast(@min(gap, 33));
    }
};

/// What the scoring loop would have done with `p` from `from` on, starting
/// from `run`. Stops when the term is complete.
fn scoreRun(term: []const u8, run: *Run, p: Piece, from: usize) void {
    var k = from;
    while (run.j < term.len and p.holds(term[run.j])) : (k += 1) {
        k = std.mem.indexOfScalarPos(u8, p.low, k, term[run.j]) orelse break;
        const c = p.text[k];
        var bonus: i32 = 0;
        if (p.is_name and k == 0) {
            bonus = match.bonus_name_start;
        } else if (k == 0 or isSeparator(p.text[k - 1])) {
            bonus = match.bonus_boundary;
        } else if (std.ascii.isUpper(c) and std.ascii.isLower(p.text[k - 1])) {
            bonus = match.bonus_camel;
        }
        if (run.j == 0) bonus *= 2;
        var sc = match.score_match + bonus;
        if (p.is_name) sc += match.bonus_in_name;
        if (run.last) |last| {
            const gap = @as(isize, @intCast(k)) - last - 1;
            sc += if (gap == 0) match.bonus_consecutive else -gapPenalty(@intCast(gap));
        }
        run.score += sc;
        run.last = @intCast(k);
        run.j += 1;
    }
}

inline fn isSeparator(c: u8) bool {
    return switch (c) {
        '/', '-', '_', '.', ' ' => true,
        else => false,
    };
}

/// The backward pass over `p.low[0..end]`, right to left, for the term's
/// first `unmatched` characters. Returns how many are still unmatched, and
/// where the window starts if none are.
fn backward(term: []const u8, unmatched: usize, p: Piece, end: usize) struct { left: usize, start: usize } {
    var j = unmatched;
    var i = end;
    while (i > 0 and j > 0) {
        if (!p.holds(term[j - 1])) return .{ .left = j, .start = 0 };
        i -= 1;
        if (p.low[i] == term[j - 1]) j -= 1;
    }
    return .{ .left = j, .start = i };
}

/// How far a greedy forward match of `term[from..]` gets in `p`, and where
/// it completes if it does.
fn forward(term: []const u8, from: usize, p: Piece) struct { j: usize, end: ?usize } {
    var j = from;
    var i: usize = 0;
    while (p.holds(term[j])) : (i += 1) {
        i = std.mem.indexOfScalarPos(u8, p.low, i, term[j]) orelse break;
        j += 1;
        if (j == term.len) return .{ .j = j, .end = i };
    }
    return .{ .j = j, .end = null };
}

/// For one prefix of the term: the window a backward pass for that prefix
/// would open, ending at the end of the directory's path, and what the
/// scoring loop then does from that window's start through the path.
const Tail = extern struct {
    /// Term characters the scoring loop matched in the path; `none` when the
    /// prefix is not a subsequence of the path at all.
    y: u8,
    /// Characters after the loop's last match, saturating.
    gap: u8,
    score: i16,

    const none: Tail = .{ .y = 0xff, .gap = 0, .score = 0 };

    /// The loop's state as it enters the next piece.
    fn run(tail: Tail) ?Run {
        if (tail.y == 0xff) return null;
        return .{ .j = tail.y, .score = tail.score, .last = -1 - @as(isize, tail.gap) };
    }
};

/// What a directory's children need to know about its path, `dir/` with the
/// trailing slash included.
pub const State = extern struct {
    id: u32,
    /// Term characters a greedy forward match takes in the path.
    reach: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// The term's score against the path alone, when `reach` is the whole
    /// term: the window then closes before any child's name starts.
    whole: i32,
    /// No file under this directory can score more: its name holds no `/`,
    /// so a slash term's window always opens in the directory's path.
    /// Search compares it with the worst hit it is keeping, so most files are
    /// rejected without reading past their parent's state.
    best: i32,
    /// Indexed by prefix length, 1 through len - 1. Unused once `reach` is
    /// the whole term.
    tails: [max_len]Tail,

    /// The state above a root-level directory: an empty path.
    const root: State = .{ .id = index.no_parent, .reach = 0, .whole = 0, .best = 0, .tails = @splat(Tail.none) };

    /// `parent`'s state extended by one component, `name` followed by `/`.
    fn child(parent: *const State, term: []const u8, id: u32, name: []const u8) ?State {
        var out: State = .{ .id = id, .reach = parent.reach, .whole = parent.whole, .best = parent.whole, .tails = @splat(Tail.none) };
        if (parent.reach == term.len) return out;

        if (name.len + 1 > max_name) return null;
        var text: [max_name + 1]u8 = undefined;
        @memcpy(text[0..name.len], name);
        text[name.len] = '/';
        var low: [max_name + 1]u8 = undefined;
        const p = Piece.init(&low, text[0 .. name.len + 1], false);

        const fwd = forward(term, parent.reach, p);
        out.reach = @intCast(fwd.j);
        if (fwd.end) |end| {
            out.whole = finish(term, parent, p, end).?;
            out.best = out.whole;
            return out;
        }
        out.best = std.math.minInt(i32);
        const after_slash = if (std.mem.lastIndexOfScalar(u8, term, '/')) |i| i + 1 else 0;
        // A prefix longer than `reach` is not in the path at all.
        for (1..@as(usize, out.reach) + 1) |x| {
            const back = backward(term, x, p, p.low.len);
            var r: Run = undefined;
            if (back.left == 0) {
                // A window opened for a prefix keeps matching past it, the
                // way the real loop would, until the path runs out.
                r = .{ .j = 0, .score = 0, .last = null };
                scoreRun(term, &r, p, back.start);
            } else {
                r = parent.tails[back.left].run() orelse continue;
                scoreRun(term, &r, p, 0);
            }
            const gap = r.gapAfter(p);
            out.tails[x] = .{ .y = @intCast(r.j), .gap = gap, .score = @intCast(r.score) };
            // A file's backward pass stops at the term's last `/`, which its
            // name cannot hold, so a file only ever resumes a longer prefix.
            if (x >= after_slash) out.best = @max(out.best, r.score + nameMost(term.len - r.j, gap));
        }
        return out;
    }
};

/// The most the scoring loop can add while it matches the last `left` term
/// characters inside a file name, having read `gap` characters since its last
/// match. Only for a window that opened above the name: a name with no `/`
/// cannot hold a slash term's whole window.
fn nameMost(left: usize, gap: u8) i32 {
    const in_name = match.score_match + match.bonus_in_name;
    // At the name's first character: the name-start bonus, and the run
    // carries on only if the last match was the `/` just before it.
    const at_start = in_name + match.bonus_name_start +
        if (gap == 0) match.bonus_consecutive else -gapPenalty(gap);
    // Anywhere later: at best a boundary, after at least one more gap.
    const later = in_name + match.bonus_boundary - gapPenalty(gap + 1);
    const rest: i32 = @intCast((left - 1) * (in_name + match.bonus_boundary + match.bonus_consecutive));
    return @max(at_start, later) + rest;
}

fn gapPenalty(gap: usize) i32 {
    const g: i32 = @intCast(@min(gap, 32));
    return match.penalty_gap_start + (g - 1) * match.penalty_gap_extend;
}

/// Scores a window that closes at `p.low[end]`, where `p` follows `parent`'s
/// path. The backward pass runs through `p` and, if it needs more, picks up
/// the parent's summary for the prefix it still has to place.
fn finish(term: []const u8, parent: *const State, p: Piece, end: usize) ?i32 {
    const back = backward(term, term.len, p, end + 1);
    var r: Run = undefined;
    if (back.left == 0) {
        r = .{ .j = 0, .score = 0, .last = null };
        scoreRun(term, &r, p, back.start);
    } else {
        r = parent.tails[back.left].run() orelse return null;
        scoreRun(term, &r, p, 0);
    }
    std.debug.assert(r.j == term.len);
    return r.score;
}

/// The term's score against a file under the directory `parent` describes.
/// `name` is at most `max_name` long.
/// Kept out of line: its buffer would otherwise grow the frame of every
/// candidate search scores, slash query or not.
pub noinline fn scoreFile(term: []const u8, parent: *const State, name: []const u8) ?i32 {
    const bonus = match.nameBonus(name, term);
    if (parent.reach == term.len) return parent.whole + bonus;
    var low: [max_name + 1]u8 = undefined;
    const p = Piece.init(&low, name, true);
    const end = forward(term, parent.reach, p).end orelse return null;
    return (finish(term, parent, p, end) orelse return null) + bonus;
}

/// Recently built directory states, for one slash term over one search
/// range. Direct-mapped: a collision just costs a rebuild.
///
/// It only pays when files under one directory sit near each other in the
/// table, as they do in every index a scan writes. When they do not, nearly
/// every lookup rebuilds a chain of states, which costs more than building
/// the path, so the memo watches its own rebuild rate and steps aside.
pub const Memo = struct {
    pub const slot_bits = 8;
    const slots = 1 << slot_bits;
    /// Chains deeper than this are scored through the full path instead.
    const max_chain = 256;
    /// Lookups before the rebuild rate is trusted.
    const warmup = 4096;

    states: [slots]State,
    lookups: u32,
    built: u32,

    pub fn reset(m: *Memo) void {
        for (&m.states) |*s| s.id = index.no_parent;
        m.lookups = 0;
        m.built = 0;
    }

    fn slot(id: u32) usize {
        return (id *% 0x9e3779b1) >> (32 - slot_bits);
    }

    /// `dir`'s state, building any missing ancestors' on the way down. Null
    /// when the caller should score through the full path.
    pub inline fn get(m: *Memo, v: index.View, term: []const u8, dir: u32) ?*const State {
        // More states built than looked up: the memo is thrashing.
        if (m.lookups >= warmup and m.built > m.lookups) return null;
        m.lookups += 1;
        const hit = &m.states[slot(dir)];
        if (hit.id == dir) return hit;
        return m.build(v, term, dir);
    }

    noinline fn build(m: *Memo, v: index.View, term: []const u8, dir: u32) ?*const State {
        const hit = &m.states[slot(dir)];
        var chain: [max_chain]u32 = undefined;
        var n: usize = 0;
        var above: State = State.root;
        var up = dir;
        while (up != index.no_parent) : (up = v.parent[up]) {
            const s = &m.states[slot(up)];
            if (s.id == up) {
                above = s.*;
                break;
            }
            if (n == chain.len) return null;
            chain[n] = up;
            n += 1;
        }
        m.built += @intCast(n);
        while (n > 0) {
            n -= 1;
            const d = chain[n];
            above = State.child(&above, term, d, v.name(d)) orelse return null;
            m.states[slot(d)] = above;
        }
        return hit;
    }
};

const t = std.testing;

fn expectSame(b: *index.Builder, term: []const u8) !void {
    const v = b.view();
    var memo: Memo = undefined;
    memo.reset();
    var buf: [512]u8 = undefined;
    for (0..v.count()) |i| {
        const id: u32 = @intCast(i);
        const parent = v.parent[id];
        if (parent == index.no_parent) continue;
        const path = v.relativePath(id, &buf).?;
        const want = match.score(path, term, path.len - v.name(id).len);
        // A scattered tree trips the memo's thrash cutoff; start it over.
        const dir = memo.get(v, term, parent) orelse retry: {
            memo.reset();
            break :retry memo.get(v, term, parent).?;
        };
        const got = scoreFile(term, dir, v.name(id));
        if (got) |s| if (std.mem.indexOfScalar(u8, term, '/') != null and s > dir.best) {
            std.debug.print("bound {s} vs {s}: {d} > {d}\n", .{ term, path, s, dir.best });
            return error.BoundTooLow;
        };
        if (want != got) {
            std.debug.print("{s} vs {s}: want {?d} got {?d}\n", .{ term, path, want, got });
            return error.Mismatch;
        }
    }
}

test "agrees with scoring the full path" {
    var b = index.Builder.init(t.allocator);
    defer b.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const alphabet = "abcli-_.xB";
    var dirs: std.ArrayList(u32) = .empty;
    defer dirs.deinit(t.allocator);
    var name: [12]u8 = undefined;
    for (0..4000) |_| {
        const len = 1 + r.uintLessThan(usize, name.len);
        for (name[0..len]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const parent = if (dirs.items.len == 0 or r.uintLessThan(u32, 8) == 0)
            index.no_parent
        else
            dirs.items[r.uintLessThan(usize, dirs.items.len)];
        const is_dir = r.uintLessThan(u32, 3) == 0;
        const id = try b.add(parent, name[0..len], .{ .dir = is_dir });
        if (is_dir) try dirs.append(t.allocator, id);
    }
    for ([_][]const u8{ "a/b", "lib/x", "b/i", "a/", "/a", "/", "c/l/a", "ab/c.x", "b-/a", "x", "abc", "a//b" }) |term| {
        try expectSame(&b, term);
    }
}
