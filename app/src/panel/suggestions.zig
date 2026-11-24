//! TTL cache for web search suggestions.
const std = @import("std");
const search = @import("../search.zig");

pub const ttl: f64 = 5 * 60;

pub const Entry = struct {
    query: []u8,
    items: [][]u8,
    fetched_at: f64,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        for (c.entries.items) |entry| freeEntry(gpa, entry);
        c.entries.deinit(gpa);
    }

    pub fn get(c: *Cache, gpa: std.mem.Allocator, query: []const u8, now: f64) ?[]const []const u8 {
        var i: usize = 0;
        while (i < c.entries.items.len) {
            const entry = c.entries.items[i];
            if (now - entry.fetched_at >= ttl) {
                freeEntry(gpa, entry);
                _ = c.entries.swapRemove(i);
                continue;
            }
            if (std.mem.eql(u8, entry.query, query)) return entry.items;
            i += 1;
        }
        return null;
    }

    pub fn put(c: *Cache, gpa: std.mem.Allocator, query: []const u8, items: []const []const u8, now: f64) void {
        var i: usize = 0;
        while (i < c.entries.items.len) {
            const entry = c.entries.items[i];
            if (now - entry.fetched_at >= ttl or std.mem.eql(u8, entry.query, query)) {
                freeEntry(gpa, entry);
                _ = c.entries.swapRemove(i);
                continue;
            }
            i += 1;
        }
        const kept = nonEmpty(items);
        const q_copy = gpa.dupe(u8, query) catch return;
        const owned = gpa.alloc([]u8, kept) catch {
            gpa.free(q_copy);
            return;
        };
        var n: usize = 0;
        for (items) |s| {
            if (n == kept) break;
            if (s.len == 0) continue;
            owned[n] = gpa.dupe(u8, s) catch {
                for (owned[0..n]) |prev| gpa.free(prev);
                gpa.free(owned);
                gpa.free(q_copy);
                return;
            };
            n += 1;
        }
        c.entries.append(gpa, .{ .query = q_copy, .items = owned, .fetched_at = now }) catch {
            for (owned) |prev| gpa.free(prev);
            gpa.free(owned);
            gpa.free(q_copy);
        };
    }

    fn freeEntry(gpa: std.mem.Allocator, entry: Entry) void {
        for (entry.items) |s| gpa.free(s);
        gpa.free(entry.items);
        gpa.free(entry.query);
    }
};

/// How many of `items` a suggestion list keeps: non-empty ones, up to the cap.
pub fn nonEmpty(items: []const []const u8) usize {
    var n: usize = 0;
    for (items) |s| n += @intFromBool(s.len > 0);
    return @min(n, search.max_suggestions);
}
