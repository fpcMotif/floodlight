//! Web search suggestions: TTL cache and sequence-gated request state.
const std = @import("std");
const search = @import("../search.zig");

pub const ttl: f64 = 5 * 60;
pub const min_bytes = 2;

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

pub const State = struct {
    enabled: bool = true,
    seq: u64 = 0,
    pending_seq: u64 = 0,
    pending_query: std.ArrayList(u8) = .empty,
    cache: Cache = .{},
    items: []const []const u8 = &.{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.pending_query.deinit(gpa);
        s.cache.deinit(gpa);
        s.items = &.{};
    }

    pub fn cancel(s: *State) void {
        s.pending_seq = 0;
        s.pending_query.clearRetainingCapacity();
    }

    pub fn clear(s: *State) void {
        s.items = &.{};
        s.cancel();
    }

    pub fn pendingSeq(s: *const State) u64 {
        return s.pending_seq;
    }

    pub fn first(s: *const State) ?[]const u8 {
        return if (s.enabled and s.items.len > 0) s.items[0] else null;
    }

    pub fn lookupOrNeedFetch(
        s: *State,
        gpa: std.mem.Allocator,
        list_arena: std.mem.Allocator,
        text: []const u8,
        eligible: bool,
        now: f64,
    ) bool {
        s.items = &.{};
        if (!s.enabled or !eligible) {
            s.cancel();
            return false;
        }
        if (s.cache.get(gpa, text, now)) |cached| {
            s.cancel();
            s.items = dupeItems(list_arena, cached);
            return false;
        }
        return true;
    }

    pub fn beginFetch(s: *State, gpa: std.mem.Allocator, text: []const u8) u64 {
        s.seq += 1;
        s.pending_seq = s.seq;
        s.pending_query.clearRetainingCapacity();
        s.pending_query.appendSlice(gpa, text) catch {};
        return s.pending_seq;
    }

    pub fn accept(
        s: *State,
        gpa: std.mem.Allocator,
        list_arena: std.mem.Allocator,
        seq: u64,
        query: []const u8,
        field_text: []const u8,
        items: []const []const u8,
        now: f64,
    ) bool {
        if (!s.enabled) return false;
        if (s.pending_seq == 0 or seq != s.pending_seq) return false;
        if (!std.mem.eql(u8, query, s.pending_query.items)) return false;
        if (!std.mem.eql(u8, query, field_text)) return false;
        s.cancel();
        s.cache.put(gpa, query, items, now);
        s.items = dupeItems(list_arena, items);
        return true;
    }
};

/// How many of `items` a suggestion list keeps: non-empty ones, up to the cap.
pub fn nonEmpty(items: []const []const u8) usize {
    var n: usize = 0;
    for (items) |s| n += @intFromBool(s.len > 0);
    return @min(n, search.max_suggestions);
}

/// Copies up to `search.max_suggestions` non-empty items into `a`.
pub fn dupeItems(a: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    const kept = nonEmpty(items);
    if (kept == 0) return &.{};
    const out = a.alloc([]const u8, kept) catch return &.{};
    var n: usize = 0;
    for (items) |s| {
        if (n == kept) break;
        if (s.len == 0) continue;
        out[n] = a.dupe(u8, s) catch return out[0..n];
        n += 1;
    }
    return out[0..n];
}
