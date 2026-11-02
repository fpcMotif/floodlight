//! A 32-bit "which characters occur" signature per name and per path.
//!
//! The search loop tests `(entry & query) == query` over a dense array of
//! these before it looks at a single byte of text, so a query rejects most of
//! a million entries with a few SIMD compares instead of a few million string
//! walks. Buckets fold digits three to a bit; that costs some false positives
//! the matcher then rejects, never a false negative.

const std = @import("std");

/// Bit for a byte, or null for a byte the mask does not track (path
/// separators, non-ASCII). An untracked byte can only ever widen a match, so
/// leaving it out of the query mask is always safe.
pub inline fn bucket(c: u8) ?u5 {
    return switch (c) {
        'a'...'z' => @intCast(c - 'a'),
        'A'...'Z' => @intCast(c - 'A'),
        '0'...'9' => @intCast(26 + (c - '0') / 3),
        '.' => 30,
        '-', '_' => 31,
        else => null,
    };
}

pub fn of(s: []const u8) u32 {
    var m: u32 = 0;
    for (s) |c| {
        if (bucket(c)) |b| m |= @as(u32, 1) << b;
    }
    return m;
}

test "case folds and ignores separators" {
    try std.testing.expectEqual(of("abc"), of("ABC"));
    try std.testing.expectEqual(of("a/b"), of("ab"));
    try std.testing.expect(of("report.pdf") & of("rpt") == of("rpt"));
    try std.testing.expect(of("report.pdf") & of("xyz") != of("xyz"));
}

test "digits share buckets but never drop" {
    try std.testing.expectEqual(of("0"), of("2"));
    try std.testing.expect(of("v9") & of("9") == of("9"));
}
