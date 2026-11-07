//! Fuzzy subsequence scoring over one haystack, in two linear passes.
//!
//! The shape is fzf's v1 algorithm: a forward pass finds where the first full
//! match ends, a backward pass from there finds the tightest start, and only
//! that window is scored. It is not the optimal alignment (that is fzf v2's
//! O(n·m) table), but a launcher scores hundreds of thousands of names per
//! keystroke and the window is right for names, which is what people type.

const std = @import("std");

pub const score_match: i32 = 16;
pub const bonus_boundary: i32 = 8;
pub const bonus_name_start: i32 = 12;
pub const bonus_camel: i32 = 7;
pub const bonus_consecutive: i32 = 5;
pub const bonus_in_name: i32 = 3;
pub const penalty_gap_start: i32 = 3;
pub const penalty_gap_extend: i32 = 1;
pub const bonus_exact_name: i32 = 120;
pub const bonus_name_prefix: i32 = 40;

inline fn isSeparator(c: u8) bool {
    return switch (c) {
        '/', '-', '_', '.', ' ' => true,
        else => false,
    };
}

/// `needle` must already be lowercase. `name_start` is where the last path
/// component begins inside `hay` (0 when `hay` is the name itself), so a
/// match inside the file name outranks the same letters spread across
/// directories.
pub fn score(hay: []const u8, needle: []const u8, name_start: usize) ?i32 {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;

    var j: usize = 0;
    var end: usize = 0;
    for (hay, 0..) |c, i| {
        if (std.ascii.toLower(c) == needle[j]) {
            j += 1;
            if (j == needle.len) {
                end = i;
                break;
            }
        }
    } else return null;

    // Walk back from the end so the window starts at the last possible
    // place: "abc" in "a_xx_abc" scores the tight "abc", not the spread one.
    var start = end;
    j = needle.len;
    var i = end + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.toLower(hay[i]) == needle[j - 1]) {
            j -= 1;
            if (j == 0) {
                start = i;
                break;
            }
        }
    }

    var total: i32 = 0;
    var prev_match: ?usize = null;
    j = 0;
    var k = start;
    while (k <= end) : (k += 1) {
        const c = hay[k];
        if (std.ascii.toLower(c) != needle[j]) continue;

        var bonus: i32 = 0;
        if (k == name_start) {
            bonus = bonus_name_start;
        } else if (k == 0 or isSeparator(hay[k - 1])) {
            bonus = bonus_boundary;
        } else if (std.ascii.isUpper(c) and std.ascii.isLower(hay[k - 1])) {
            bonus = bonus_camel;
        }
        if (j == 0) bonus *= 2;

        var s = score_match + bonus;
        if (k >= name_start) s += bonus_in_name;
        if (prev_match) |p| {
            const gap = k - p - 1;
            if (gap == 0) {
                s += bonus_consecutive;
            } else {
                const g: i32 = @intCast(@min(gap, 32));
                s -= penalty_gap_start + (g - 1) * penalty_gap_extend;
            }
        }
        total += s;
        prev_match = k;
        j += 1;
        if (j == needle.len) break;
    }

    const name = hay[name_start..];
    if (name.len >= needle.len and startsWithFold(name, needle)) {
        total += if (name.len == needle.len or name[needle.len] == '.')
            bonus_exact_name
        else
            bonus_name_prefix;
    }
    return total;
}

/// The most a first matched character can earn: a name start, doubled.
const first_max = score_match + 2 * bonus_name_start + bonus_in_name;
/// The most any later character can earn: a boundary plus a run.
const next_max = score_match + bonus_boundary + bonus_in_name + bonus_consecutive;
/// A first character anywhere but position 0 can at most sit on a boundary.
const first_inner_max = score_match + 2 * bonus_boundary + bonus_in_name;

/// No `score(hay, needle, _)` can exceed this. Search compares it with the
/// worst hit it is keeping, so a candidate that cannot place is rejected on a
/// prefix compare instead of a full scoring pass.
pub fn upperBound(name: []const u8, needle: []const u8) i32 {
    if (needle.len == 0) return 0;
    const rest: i32 = @intCast((needle.len - 1) * next_max);
    if (name.len >= needle.len and startsWithFold(name, needle)) {
        return first_max + rest + bonus_exact_name;
    }
    return first_inner_max + rest;
}

/// The bound for a match anywhere in a path, where the name-start bonus and
/// the prefix bonus are both still reachable.
pub fn upperBoundAnywhere(needle_len: usize) i32 {
    if (needle_len == 0) return 0;
    return first_max + @as(i32, @intCast((needle_len - 1) * next_max)) + bonus_exact_name;
}

pub fn startsWithFold(hay: []const u8, needle: []const u8) bool {
    for (needle, 0..) |n, idx| {
        if (std.ascii.toLower(hay[idx]) != n) return false;
    }
    return true;
}

const t = std.testing;

test "subsequence required" {
    try t.expect(score("readme.md", "rdm", 0) != null);
    try t.expect(score("readme.md", "xyz", 0) == null);
    try t.expect(score("ab", "abc", 0) == null);
}

test "case insensitive" {
    try t.expect(score("ReadMe.MD", "readme", 0) != null);
}

test "exact name beats prefix beats scatter" {
    const exact = score("notes.txt", "notes", 0).?;
    const prefix = score("notesbook.txt", "notes", 0).?;
    const scatter = score("n_o_t_e_s.txt", "notes", 0).?;
    try t.expect(exact > prefix);
    try t.expect(prefix > scatter);
}

test "match in name beats match in directory" {
    const in_name = score("src/budget.xlsx", "budget", 4).?;
    const in_dir = score("budget/q3.xlsx", "budget", 7).?;
    try t.expect(in_name > in_dir);
}

test "consecutive beats scattered" {
    const tight = score("xxabcxx", "abc", 0).?;
    const loose = score("xaxbxcx", "abc", 0).?;
    try t.expect(tight > loose);
}

test "backward pass tightens the window" {
    // Forward alone would start at the first `a` and pay for the gap.
    const s = score("axxxxabc", "abc", 0).?;
    const plain = score("xxxxxabc", "abc", 0).?;
    try t.expectEqual(plain, s);
}

test "upper bounds hold" {
    const cases = [_][2][]const u8{
        .{ "readme.md", "readme" }, .{ "readme", "readme" },   .{ "xreadme", "readme" },
        .{ "r_e_a_d", "read" },     .{ "MyReadMe", "readme" }, .{ "a", "a" },
        .{ "abc-abc", "abc" },      .{ "x.y.z", "xyz" },
    };
    for (cases) |c| {
        const s = score(c[0], c[1], 0).?;
        try t.expect(s <= upperBound(c[0], c[1]));
        try t.expect(s <= upperBoundAnywhere(c[1].len));
    }
    const p = score("docs/readme/x.txt", "readme", 13).?;
    try t.expect(p <= upperBoundAnywhere(6));
}

test "word boundary beats mid-word" {
    const boundary = score("my-app", "app", 0).?;
    const mid = score("mapping", "app", 0).?;
    try t.expect(boundary > mid);
}
