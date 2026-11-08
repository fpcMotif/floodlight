//! What the panel searches: the installed apps, scored in memory, and the
//! home folder's name index, mapped from disk by the Zig core.
const std = @import("std");
const core = @import("floodlight_core");
const clipboard = @import("clipboard.zig");

pub const Kind = enum {
    app,
    file,
    folder,
    web,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .app => "Application",
            .file => "File",
            .folder => "Folder",
            .web => "Web",
        };
    }

    pub fn symbol(k: Kind) []const u8 {
        return switch (k) {
            .app => "square.grid.2x2.fill",
            .file => "doc.text.fill",
            .folder => "folder.fill",
            .web => "globe.americas.fill",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    title: []const u8,
    /// Where it lives: a file's path from the index's root, an app's
    /// absolute folder, a web search's site.
    subtitle: []const u8,
    path: []const u8,
    score: i32,
    size: ?u64 = null,
    modified: ?i64 = null,
    suggestion: bool = false,

    pub fn extension(r: Row) []const u8 {
        if (r.kind != .file) return "";
        const ext = std.fs.path.extension(r.title);
        return if (ext.len > 1) ext[1..] else "";
    }
};

pub const web_search_url = "https://www.google.com/search?q=";
pub const web_suggest_url = "https://suggestqueries.google.com/complete/search?client=firefox&q=";

pub const App = struct {
    /// The bundle's name without `.app`.
    name: []const u8,
    path: []const u8,
};

/// Apps outrank files that score the same: a launcher's first job.
pub const app_bonus: i32 = 60;
pub const max_rows = 80;
pub const max_suggestions = 4;

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    apps: std.ArrayList(App) = .empty,
    files: ?*const core.file_index.FileIndex = null,

    pub fn deinit(cat: *Catalog) void {
        for (cat.apps.items) |a| cat.gpa.free(a.path);
        cat.apps.deinit(cat.gpa);
        cat.* = undefined;
    }

    /// Takes ownership of `path`; the name is a slice of it.
    pub fn addApp(cat: *Catalog, path: []u8) !void {
        const base = std.fs.path.basename(path);
        try cat.apps.append(cat.gpa, .{ .name = base[0 .. base.len - ".app".len], .path = path });
    }

    /// The best rows for `query`, best first, in `arena`'s memory.
    pub fn query(cat: *const Catalog, arena: std.mem.Allocator, text: []const u8) ![]Row {
        return cat.rank(arena, text, true);
    }

    pub fn queryApps(cat: *const Catalog, arena: std.mem.Allocator, text: []const u8) ![]Row {
        return cat.rank(arena, text, false);
    }

    fn rank(cat: *const Catalog, arena: std.mem.Allocator, text: []const u8, include_files: bool) ![]Row {
        var rows: std.ArrayList(Row) = .empty;
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return rows.items;

        const terms = core.search.Query.parse(trimmed);
        try rows.ensureTotalCapacity(arena, cat.apps.items.len + max_rows);
        apps: for (cat.apps.items) |a| {
            var s: i32 = 0;
            for (0..terms.n) |i| s += core.match.score(a.name, terms.term(i), 0) orelse continue :apps;
            try rows.append(arena, .{ .kind = .app, .title = a.name, .subtitle = std.fs.path.dirname(a.path) orelse "/", .path = a.path, .score = s + app_bonus });
        }

        if (if (cat.files) |fi| if (include_files) fi.view() else null else null) |v| {
            var hits: [max_rows]core.search.Hit = undefined;
            const n = core.search.search(v, trimmed, &hits);
            const root = v.root;
            for (hits[0..n]) |h| {
                var buf: [4096]u8 = undefined;
                const rel = v.relativePath(h.id, &buf) orelse continue;
                const path = try std.fs.path.join(arena, &.{ root, rel });
                // Bundles are apps, listed above from the catalog; their insides are no one's.
                if (std.mem.endsWith(u8, rel, ".app") or std.mem.indexOf(u8, rel, ".app/") != null) continue;
                try rows.append(arena, .{
                    .kind = if (v.flags[h.id].dir) .folder else .file,
                    .title = std.fs.path.basename(path),
                    .subtitle = try arena.dupe(u8, rel),
                    .path = path,
                    .score = h.score,
                });
            }
        }
        const link = try detectLink(arena, trimmed);
        const extra: usize = if (link != null) 2 else 1;
        const ranked = try best(arena, rows.items, max_rows - extra);
        for (ranked) |*r| if (r.kind != .app) stamp(arena, r);
        var out = try arena.alloc(Row, ranked.len + extra);
        if (link) |url| {
            const link_row: Row = .{
                .kind = .web,
                .title = try std.fmt.allocPrint(arena, "Open {s}", .{clipboard.domain(url) orelse trimmed}),
                .subtitle = url,
                .path = url,
                .score = 0,
            };
            if (exactMatchIndex(ranked, trimmed)) |idx| {
                out[0] = ranked[idx];
                out[1] = link_row;
                @memcpy(out[2 .. 2 + idx], ranked[0..idx]);
                @memcpy(out[2 + idx .. ranked.len + 1], ranked[idx + 1 ..]);
            } else {
                out[0] = link_row;
                @memcpy(out[1 .. ranked.len + 1], ranked);
            }
        } else {
            @memcpy(out[0..ranked.len], ranked);
        }
        out[ranked.len + extra - 1] = .{
            .kind = .web,
            .title = "Google",
            .subtitle = "google.com",
            .path = try webSearchUrl(arena, trimmed),
            .score = 0,
        };
        return out;
    }
};

fn exactMatchIndex(rows: []const Row, query: []const u8) ?usize {
    for (rows, 0..) |r, i| {
        if ((r.kind == .app or r.kind == .file) and std.ascii.eqlIgnoreCase(r.title, query)) return i;
    }
    return null;
}

fn stamp(arena: std.mem.Allocator, r: *Row) void {
    const z = arena.dupeSentinel(u8, r.path, 0) catch return;
    var st: std.c.Stat = undefined;
    if (std.c.stat(z, &st) != 0) return;
    r.modified = st.mtime().sec;
    if (r.kind == .file) r.size = @intCast(st.size);
}

pub fn webSearchUrl(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    return buildQueryUrl(arena, web_search_url, query);
}

pub fn webSuggestUrl(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    return buildQueryUrl(arena, web_suggest_url, query);
}

fn buildQueryUrl(arena: std.mem.Allocator, prefix: []const u8, query: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, prefix);
    for (query) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~') {
            try out.append(arena, b);
        } else {
            try out.print(arena, "%{X:0>2}", .{b});
        }
    }
    return out.items;
}

pub fn parseSuggestions(arena: std.mem.Allocator, body: []const u8) [][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return &.{};
    const second = parsed.value.array.items[1];
    if (second != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (second.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        const copy = arena.dupe(u8, item.string) catch break;
        out.append(arena, copy) catch break;
        if (out.items.len == max_suggestions) break;
    }
    return out.items;
}

const web_tlds = [_][]const u8{
    "com",     "org",    "net",    "edu",   "gov",    "mil",  "int",  "io",      "co",    "ai",    "dev",  "me",      "gg",
    "xyz",     "tv",     "fm",     "am",    "to",     "ly",   "uk",   "de",      "fr",    "jp",    "cn",   "au",      "ca",
    "ch",      "nl",     "se",     "no",    "dk",     "fi",   "es",   "pt",      "it",    "is",    "at",   "be",      "us",
    "eu",      "kr",     "tw",     "hk",    "sg",     "nz",   "ie",   "ru",      "ua",    "cz",    "sk",   "hu",      "ro",
    "bg",      "gr",     "tr",     "il",    "za",     "mx",   "ar",   "cl",      "pe",    "tech",  "site", "online",  "blog",
    "biz",     "design", "studio", "cloud", "page",   "live", "work", "world",   "space", "fun",   "club", "team",    "zone",
    "chat",    "social", "media",  "games", "lol",    "wtf",  "fyi",  "run",     "build", "tools", "wiki", "systems", "security",
    "finance", "money",  "bank",   "law",   "health", "care", "bio",  "science", "math",  "art",   "book", "books",
};

pub fn detectLink(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const s = std.mem.trimEnd(u8, std.mem.trim(u8, text, " \t\r\n"), ".,;)");
    if (s.len == 0 or std.mem.indexOfAny(u8, s, " \t\r\n") != null) return null;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, s, scheme)) {
            return if (clipboard.domain(s) != null) try arena.dupe(u8, s) else null;
        }
    }
    if (std.mem.indexOf(u8, s, "://") != null) return null;
    const slash = std.mem.indexOfAny(u8, s, "/?#");
    const host_port = if (slash) |idx| s[0..idx] else s;
    const colon = std.mem.indexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    if (colon) |idx| if (!isValidPort(host_port[idx + 1 ..])) return null;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or isIpv4(host)) {
        return try std.fmt.allocPrint(arena, "http://{s}", .{s});
    }
    const tld = lastHostLabel(host) orelse return null;
    const www = std.ascii.startsWithIgnoreCase(host, "www.") and std.mem.indexOfScalar(u8, host["www.".len..], '.') != null;
    if (www or colon != null or slash != null or inTldSet(tld)) {
        return try std.fmt.allocPrint(arena, "https://{s}", .{s});
    }
    return null;
}

fn isValidPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    const n = std.fmt.parseInt(u16, port, 10) catch return false;
    return n > 0;
}

fn isIpv4(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) {
        if (parts == 4 or part.len == 0 or part.len > 3) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return parts == 4;
}

fn lastHostLabel(host: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, host, '.') == null) return null;
    var it = std.mem.splitScalar(u8, host, '.');
    var last: []const u8 = "";
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return null;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return null;
        last = label;
    }
    if (last.len < 2) return null;
    for (last) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return last;
}

fn inTldSet(tld: []const u8) bool {
    for (web_tlds) |w| if (std.ascii.eqlIgnoreCase(tld, w)) return true;
    return false;
}

const RankKey = struct { score: i32, title_len: u32, at: u32 };

fn best(arena: std.mem.Allocator, rows: []const Row, limit: usize) ![]Row {
    const keys = try arena.alloc(RankKey, rows.len);
    for (rows, keys, 0..) |r, *k, i| k.* = .{ .score = r.score, .title_len = @intCast(r.title.len), .at = @intCast(i) };
    std.mem.sort(RankKey, keys, {}, better);
    const out = try arena.alloc(Row, @min(rows.len, limit));
    for (out, keys[0..out.len]) |*o, k| o.* = rows[k.at];
    return out;
}

fn better(_: void, a: RankKey, b: RankKey) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.title_len < b.title_len;
}

/// Where apps are installed, besides the user's own `~/Applications`.
pub const app_folders = [_][]const u8{
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
};

/// Adds every `*.app` directly inside `folder`. A missing folder adds none.
pub fn scanApps(cat: *Catalog, io: std.Io, folder: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.endsWith(u8, entry.name, ".app")) continue;
        try cat.addApp(try std.fs.path.join(cat.gpa, &.{ folder, entry.name }));
    }
}
