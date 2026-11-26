//! What the panel searches: the installed apps, scored in memory, and the
//! home folder's name index, mapped from disk by the Zig core.
const std = @import("std");
const core = @import("nanospot_core");
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
    modified_label: []const u8 = "",
    stamped: bool = false,
    suggestion: bool = false,
    /// One of `web_engines`, listed under Google; never a Link Row.
    engine: bool = false,

    pub fn extension(r: Row) []const u8 {
        if (r.kind != .file) return "";
        const ext = std.fs.path.extension(r.title);
        return if (ext.len > 1) ext[1..] else "";
    }
};

pub const web_search_url = "https://www.google.com/search?q=";
pub const web_suggest_url = "https://suggestqueries.google.com/complete/search?client=firefox&q=";

pub const WebEngine = struct {
    title: []const u8,
    host: []const u8,
    url_prefix: []const u8,
};

/// Listed under Google and its suggestions, in this order. Gemini is absent
/// until a query-prefill URL is confirmed against the live site.
pub const web_engines = [_]WebEngine{
    .{ .title = "YouTube", .host = "youtube.com", .url_prefix = "https://www.youtube.com/results?search_query=" },
    .{ .title = "X", .host = "x.com", .url_prefix = "https://x.com/search?f=live&q=" },
    .{ .title = "Grok", .host = "grok.com", .url_prefix = "https://grok.com/?q=" },
};

pub const App = struct {
    /// The bundle's name without `.app`.
    name: []const u8,
    subtitle: []const u8,
    path: []const u8,
    name_mask: u32,
};

/// Apps outrank files that score the same: a launcher's first job.
pub const app_bonus: i32 = 60;
/// Lifts an app the query begins to level with a file named exactly the
/// query, so "cal" opens Calendar, not a folder called cal.
pub const app_prefix_bonus: i32 = core.match.bonus_exact_name - core.match.bonus_name_prefix;
pub const max_rows = 80;
pub const max_file_hits = 2 * max_rows;
pub const max_suggestions = 4;
/// Apps listed under Suggestions on an empty query: ⌘2 to ⌘6 plus the selected first row.
pub const max_suggested_apps = 6;

pub const Wake = struct {
    ctx: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) void = noWake,
};

fn noWake(_: ?*anyopaque) void {}

/// Only `.live` carries an allocator, so hidden or board sessions cannot allocate rows.
pub const Session = union(enum) {
    live: struct {
        arena: std.mem.Allocator,
        query: []const u8,
    },
    retained,
    idle,
};

pub const Poll = union(enum) {
    none,
    redraw,
    merged: []Row,
    stale,
    failed: anyerror,
};

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    apps: std.ArrayList(App) = .empty,
    files: ?core.file_index.FileIndex = null,
    searcher: FileSearcher = .{},
    worker_started: bool = false,
    wake: Wake = .{},
    rebuild_thread: ?std.Thread = null,
    scan_pending: std.atomic.Value(bool) = .init(false),
    scan_thread_alive: std.atomic.Value(bool) = .init(false),
    inline_adopted: bool = false,
    was_indexing: bool = false,
    next_seq: u64 = 0,
    pending_seq: u64 = 0,
    pending_query: std.ArrayList(u8) = .empty,

    pub fn deinit(cat: *Catalog) void {
        if (cat.worker_started) cat.searcher.stop();
        if (cat.rebuild_thread) |th| th.join();
        if (cat.files) |*fi| fi.close();
        cat.pending_query.deinit(cat.gpa);
        for (cat.apps.items) |a| cat.gpa.free(a.path);
        cat.apps.deinit(cat.gpa);
        cat.* = undefined;
    }

    /// Takes ownership of `path`; the name is a slice of it.
    pub fn addApp(cat: *Catalog, path: []u8) !void {
        const base = std.fs.path.basename(path);
        const name = if (std.mem.endsWith(u8, base, ".app") and base.len > ".app".len) base[0 .. base.len - ".app".len] else base;
        try cat.apps.append(cat.gpa, .{
            .name = name,
            .subtitle = std.fs.path.dirname(path) orelse "/",
            .path = path,
            .name_mask = core.mask.of(name),
        });
    }

    /// Maps the last good File Index at `path` if present, or starts empty.
    pub fn openIndex(cat: *Catalog, path: []const u8, scope_root: []const u8) !void {
        return cat.openIndexWithScanner(path, scope_root, .{});
    }

    fn openIndexWithScanner(cat: *Catalog, path: []const u8, scope_root: []const u8, scanner: core.file_index.Scanner) !void {
        const next = try core.file_index.FileIndex.open(cat.gpa, path, scope_root, scanner);
        if (cat.files) |*fi| fi.close();
        cat.files = next;
    }

    /// Opens, scans, and adopts the File Index synchronously on the caller's thread.
    pub fn buildIndex(cat: *Catalog, path: []const u8, scope_root: []const u8) !void {
        try cat.openIndex(path, scope_root);
        const fi = &(cat.files.?);
        fi.rebuild(.{ .ready = logOutcome });
        if (!fi.adopt()) return error.FileIndexNotBuilt;
        cat.inline_adopted = false;
        cat.was_indexing = false;
    }

    pub fn startWorker(cat: *Catalog, io: std.Io, wake: Wake) void {
        cat.wake = wake;
        if (cat.worker_started) return;
        cat.searcher.io = io;
        cat.searcher.ready_ctx = cat;
        cat.searcher.ready_fn = workerReady;
        if (cat.searcher.start()) |_| {
            cat.worker_started = true;
        } else |err| {
            std.log.err("file search: no worker thread: {s}", .{@errorName(err)});
        }
    }

    pub fn rebuildIndex(cat: *Catalog) void {
        const fi = &(cat.files orelse return);
        if (!cat.worker_started) {
            fi.rebuild(.{ .ready = logOutcome });
            if (fi.adopt()) cat.inline_adopted = true;
            cat.was_indexing = false;
            return;
        }
        cat.scan_pending.store(true, .seq_cst);
        cat.was_indexing = true;
        if (cat.scan_thread_alive.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;
        if (cat.rebuild_thread) |th| {
            th.join();
            cat.rebuild_thread = null;
        }
        cat.rebuild_thread = std.Thread.spawn(.{}, runRebuild, .{cat}) catch |err| {
            cat.scan_pending.store(false, .seq_cst);
            cat.scan_thread_alive.store(false, .seq_cst);
            cat.was_indexing = fi.busy();
            std.log.err("file index: no rebuild thread: {s}", .{@errorName(err)});
            return;
        };
    }

    pub fn indexing(cat: *const Catalog) bool {
        const fi = &(cat.files orelse return false);
        return cat.scan_pending.load(.seq_cst) or cat.scan_thread_alive.load(.seq_cst) or fi.busy();
    }

    pub fn hasFileIndex(cat: *const Catalog) bool {
        const fi = &(cat.files orelse return false);
        return fi.view() != null;
    }

    pub fn fileEntryCount(cat: *const Catalog) u32 {
        const fi = &(cat.files orelse return 0);
        const v = fi.view() orelse return 0;
        return v.count();
    }

    pub fn hasPending(cat: *const Catalog) bool {
        return cat.pending_seq != 0;
    }

    pub fn cancel(cat: *Catalog) void {
        cat.pending_seq = 0;
        cat.pending_query.clearRetainingCapacity();
    }

    /// The best rows for `text`, best first, in `arena`'s memory. With a worker
    /// running, file search is dispatched asynchronously and lands on `poll`.
    pub fn query(cat: *Catalog, arena: std.mem.Allocator, text: []const u8) ![]Row {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) {
            cat.cancel();
            return &.{};
        }
        cat.inline_adopted = false;
        const v = (if (cat.files) |*fi| fi.view() else null) orelse {
            cat.cancel();
            return cat.rank(arena, text, null, &.{});
        };
        if (cat.worker_started) {
            try cat.pending_query.ensureTotalCapacity(cat.gpa, text.len);
            cat.pending_query.clearRetainingCapacity();
            cat.pending_query.appendSliceAssumeCapacity(text);
            cat.next_seq += 1;
            cat.pending_seq = cat.next_seq;
            cat.searcher.submit(cat.pending_seq, v, text);
            return cat.rank(arena, text, null, &.{});
        }
        cat.cancel();
        var hits: [max_file_hits]core.search.Hit = undefined;
        const n = searchFiles(v, text, &hits);
        return cat.rank(arena, text, v, hits[0..n]);
    }

    pub fn poll(cat: *Catalog, session: Session) Poll {
        const taken: FileSearcher.Taken = if (cat.worker_started)
            cat.searcher.takeResult()
        else
            .{ .result = null, .active = false };

        var adopted = cat.inline_adopted;
        cat.inline_adopted = false;
        if (!taken.active) {
            if (cat.files) |*fi| {
                if (fi.adopt()) adopted = true;
            }
        }

        const now_indexing = cat.indexing();
        const indexing_changed = now_indexing != cat.was_indexing;
        cat.was_indexing = now_indexing;

        if (adopted) {
            cat.cancel();
            return switch (session) {
                .live, .retained => .stale,
                .idle => if (indexing_changed) .redraw else .none,
            };
        }

        if (taken.result) |res| {
            if (cat.pending_seq != 0 and res.seq == cat.pending_seq) {
                const answered_query = cat.pending_query.items;
                cat.pending_seq = 0;
                switch (session) {
                    .live => |live| {
                        if (!std.mem.eql(u8, live.query, answered_query)) return .stale;
                        const rows = cat.rank(live.arena, live.query, res.view, res.slice()) catch |err| return .{ .failed = err };
                        return .{ .merged = rows };
                    },
                    .retained => return .stale,
                    .idle => {},
                }
            }
        }

        return if (indexing_changed) .redraw else .none;
    }

    fn workerReady(ctx: ?*anyopaque) void {
        const cat: *Catalog = @ptrCast(@alignCast(ctx));
        cat.wake.wake(cat.wake.ctx);
    }

    fn logIndexError(err: anyerror) void {
        if (!@import("builtin").is_test) std.log.err("file index: {s}", .{@errorName(err)});
    }

    fn logOutcome(_: ?*anyopaque, outcome: core.file_index.Outcome) void {
        if (outcome == .failed) logIndexError(outcome.failed);
    }

    fn onScanOutcome(ctx: ?*anyopaque, outcome: core.file_index.Outcome) void {
        const cat: *Catalog = @ptrCast(@alignCast(ctx));
        if (outcome == .failed) logIndexError(outcome.failed);
        const fi = &(cat.files orelse return);
        if (fi.busy() or cat.scan_pending.load(.seq_cst)) {
            cat.wake.wake(cat.wake.ctx);
        }
    }

    fn runRebuild(cat: *Catalog) void {
        const fi = &(cat.files orelse unreachable);
        while (true) {
            while (cat.scan_pending.swap(false, .seq_cst)) {
                fi.rebuild(.{ .ctx = cat, .ready = onScanOutcome });
            }
            cat.scan_thread_alive.store(false, .seq_cst);
            if (!cat.scan_pending.load(.seq_cst)) break;
            if (cat.scan_thread_alive.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) break;
        }
        cat.wake.wake(cat.wake.ctx);
    }

    fn rank(cat: *const Catalog, arena: std.mem.Allocator, text: []const u8, file_view: ?core.index.View, hits: []const core.search.Hit) ![]Row {
        var rows: std.ArrayList(Row) = .empty;
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return rows.items;

        const terms = core.search.Query.parse(trimmed);
        try rows.ensureTotalCapacity(arena, cat.apps.items.len + max_rows);
        apps: for (cat.apps.items) |a| {
            if (a.name_mask & terms.path_mask != terms.path_mask) continue;
            var s: i32 = 0;
            for (0..terms.n) |i| s += core.match.score(a.name, terms.term(i), 0) orelse continue :apps;
            if (std.ascii.startsWithIgnoreCase(a.name, trimmed)) s += app_prefix_bonus;
            try rows.append(arena, .{ .kind = .app, .title = a.name, .subtitle = a.subtitle, .path = a.path, .score = s + app_bonus });
        }

        if (file_view) |v| {
            const root = v.root;
            var file_rows: usize = 0;
            for (hits) |h| {
                var buf: [4096]u8 = undefined;
                const rel = v.relativePath(h.id, &buf) orelse continue;
                // Bundles are apps, listed above from the catalog; their insides are no one's.
                if (std.mem.endsWith(u8, rel, ".app") or std.mem.indexOf(u8, rel, ".app/") != null) continue;
                const path = try std.fs.path.join(arena, &.{ root, rel });
                const subtitle = if (path.len >= rel.len and std.mem.eql(u8, path[path.len - rel.len ..], rel))
                    path[path.len - rel.len ..]
                else
                    try arena.dupe(u8, rel);
                try rows.append(arena, .{
                    .kind = if (v.flags[h.id].dir) .folder else .file,
                    .title = std.fs.path.basename(path),
                    .subtitle = subtitle,
                    .path = path,
                    .score = h.score,
                });
                file_rows += 1;
                if (file_rows == max_rows) break;
            }
        }
        const link = try detectLink(arena, trimmed);
        const extra: usize = if (link != null) 2 else 1;
        const ranked_len = @min(rows.items.len, max_rows - extra);
        var out = try arena.alloc(Row, ranked_len + extra);
        if (link) |url| {
            try rankTop(arena, rows.items, out[1 .. 1 + ranked_len]);
            const link_row: Row = .{
                .kind = .web,
                .title = try std.fmt.allocPrint(arena, "Open {s}", .{clipboard.domain(url) orelse trimmed}),
                .subtitle = url,
                .path = url,
                .score = 0,
            };
            if (exactMatchIndex(out[1 .. 1 + ranked_len], trimmed)) |idx| {
                const match_row = out[1 + idx];
                std.mem.copyBackwards(Row, out[2 .. 2 + idx], out[1 .. 1 + idx]);
                out[0] = match_row;
                out[1] = link_row;
            } else {
                out[0] = link_row;
            }
        } else {
            try rankTop(arena, rows.items, out[0..ranked_len]);
        }
        out[ranked_len + extra - 1] = .{
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

pub fn stamp(arena: std.mem.Allocator, r: *Row) void {
    r.stamped = true;
    const z = arena.dupeSentinel(u8, r.path, 0) catch return;
    var st: std.c.Stat = undefined;
    if (std.c.stat(z, &st) != 0) return;
    r.modified = st.mtime().sec;
    if (r.kind == .file) if (std.math.cast(u64, st.size)) |sz| {
        r.size = sz;
    };
}

pub fn webSearchUrl(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    return buildQueryUrl(arena, web_search_url, query);
}

pub fn engineUrl(arena: std.mem.Allocator, engine: WebEngine, query: []const u8) ![]const u8 {
    return buildQueryUrl(arena, engine.url_prefix, query);
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

fn rankTop(arena: std.mem.Allocator, rows: []const Row, out: []Row) !void {
    if (out.len == 0) return;
    const keys = try arena.alloc(RankKey, rows.len);
    for (rows, keys, 0..) |r, *k, i| k.* = .{ .score = r.score, .title_len = @intCast(r.title.len), .at = @intCast(i) };
    std.sort.pdq(RankKey, keys, {}, better);
    for (out, keys[0..out.len]) |*o, k| o.* = rows[k.at];
}

fn better(_: void, a: RankKey, b: RankKey) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.title_len != b.title_len) return a.title_len < b.title_len;
    return a.at < b.at;
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
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;
        // Safari is a link into the system's sealed volume, not a folder here.
        const bundle = switch (entry.kind) {
            .directory => true,
            .sym_link => if (dir.statFile(io, entry.name, .{})) |st| st.kind == .directory else |_| false,
            else => false,
        };
        if (!bundle) continue;
        try cat.addApp(try std.fs.path.join(cat.gpa, &.{ folder, entry.name }));
    }
}

fn searchFiles(view: core.index.View, text: []const u8, out: []core.search.Hit) usize {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return 0;
    return core.search.search(view, trimmed, out);
}

extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const qos_class_user_interactive: c_uint = 0x21;

const FileSearcher = struct {
    const max_query_bytes = 256;
    const SearchFn = *const fn (?*anyopaque, core.index.View, []const u8, []core.search.Hit) usize;
    const ReadyFn = *const fn (?*anyopaque) void;

    const Result = struct {
        seq: u64 = 0,
        view: core.index.View = undefined,
        hits: [max_file_hits]core.search.Hit = undefined,
        len: usize = 0,

        fn slice(r: *const Result) []const core.search.Hit {
            return r.hits[0..r.len];
        }
    };

    const Taken = struct {
        result: ?Result,
        active: bool,
    };

    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopped: bool = false,
    busy: bool = false,
    req_seq: u64 = 0,
    served_seq: u64 = 0,
    req_view: core.index.View = undefined,
    req_buf: [max_query_bytes]u8 = undefined,
    req_len: usize = 0,
    has_result: bool = false,
    result: Result = .{},
    search_ctx: ?*anyopaque = null,
    search_fn: SearchFn = defaultSearch,
    ready_ctx: ?*anyopaque = null,
    ready_fn: ReadyFn = noReady,

    fn defaultSearch(_: ?*anyopaque, view: core.index.View, text: []const u8, out: []core.search.Hit) usize {
        return searchFiles(view, text, out);
    }

    fn noReady(_: ?*anyopaque) void {}

    fn truncateUtf8(text: []const u8, max_len: usize) usize {
        var n = @min(text.len, max_len);
        if (n == text.len) return n;
        while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
        return n;
    }

    fn start(fs: *FileSearcher) !void {
        if (fs.thread != null) return;
        fs.stopped = false;
        fs.thread = try std.Thread.spawn(.{}, run, .{fs});
    }

    fn stop(fs: *FileSearcher) void {
        const th = fs.thread orelse return;
        fs.mutex.lockUncancelable(fs.io);
        fs.stopped = true;
        fs.cond.signal(fs.io);
        fs.mutex.unlock(fs.io);
        th.join();
        fs.thread = null;
    }

    fn submit(fs: *FileSearcher, seq: u64, view: core.index.View, text: []const u8) void {
        fs.mutex.lockUncancelable(fs.io);
        defer fs.mutex.unlock(fs.io);
        fs.req_seq = seq;
        fs.req_view = view;
        const n = truncateUtf8(text, max_query_bytes);
        @memcpy(fs.req_buf[0..n], text[0..n]);
        fs.req_len = n;
        fs.cond.signal(fs.io);
    }

    fn takeResult(fs: *FileSearcher) Taken {
        fs.mutex.lockUncancelable(fs.io);
        defer fs.mutex.unlock(fs.io);
        const res: ?Result = if (fs.has_result) fs.result else null;
        fs.has_result = false;
        return .{ .result = res, .active = fs.busy or fs.req_seq > fs.served_seq };
    }

    fn run(fs: *FileSearcher) void {
        _ = pthread_set_qos_class_self_np(qos_class_user_interactive, 0);
        var query_buf: [max_query_bytes]u8 = undefined;
        var hits_buf: [max_file_hits]core.search.Hit = undefined;
        while (true) {
            var seq: u64 = 0;
            var view: core.index.View = undefined;
            var query_len: usize = 0;
            {
                fs.mutex.lockUncancelable(fs.io);
                defer fs.mutex.unlock(fs.io);
                while (!fs.stopped and fs.req_seq <= fs.served_seq) {
                    fs.cond.waitUncancelable(fs.io, &fs.mutex);
                }
                if (fs.stopped) return;
                seq = fs.req_seq;
                fs.served_seq = seq;
                view = fs.req_view;
                query_len = fs.req_len;
                @memcpy(query_buf[0..query_len], fs.req_buf[0..query_len]);
                fs.busy = true;
            }
            const n = @min(max_file_hits, fs.search_fn(fs.search_ctx, view, query_buf[0..query_len], &hits_buf));
            var ready_fn: ReadyFn = undefined;
            var ready_ctx: ?*anyopaque = undefined;
            {
                fs.mutex.lockUncancelable(fs.io);
                defer fs.mutex.unlock(fs.io);
                fs.result.seq = seq;
                fs.result.view = view;
                fs.result.len = n;
                @memcpy(fs.result.hits[0..n], hits_buf[0..n]);
                fs.has_result = true;
                fs.busy = false;
                ready_fn = fs.ready_fn;
                ready_ctx = fs.ready_ctx;
            }
            ready_fn(ready_ctx);
        }
    }
};

const t = std.testing;

test "the worker searches only the newest waiting query" {
    const Ctx = struct {
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        entered: std.Io.Semaphore = .{ .permits = 0 },
        gate: std.Io.Semaphore = .{ .permits = 0 },
        done: std.Io.Semaphore = .{ .permits = 0 },
        seen: [8][64]u8 = undefined,
        seen_lens: [8]usize = @splat(0),
        seen_count: usize = 0,

        fn searchFn(raw: ?*anyopaque, _: core.index.View, text: []const u8, _: []core.search.Hit) usize {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.mutex.lockUncancelable(c.io);
            const idx = c.seen_count;
            c.seen_count += 1;
            const n = @min(text.len, 64);
            @memcpy(c.seen[idx][0..n], text[0..n]);
            c.seen_lens[idx] = n;
            c.mutex.unlock(c.io);
            if (idx == 0) {
                c.entered.post(c.io);
                c.gate.waitUncancelable(c.io);
            }
            return 0;
        }

        fn wake(raw: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.done.post(c.io);
        }
    };

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "note.txt", .data = "" });
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const idx_path = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx_path);

    var ctx: Ctx = .{ .io = t.io };
    var cat: Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    defer ctx.gate.post(t.io);
    try cat.buildIndex(idx_path, root);
    cat.searcher.search_ctx = &ctx;
    cat.searcher.search_fn = Ctx.searchFn;
    cat.startWorker(t.io, .{ .ctx = &ctx, .wake = Ctx.wake });

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    _ = try cat.query(arena.allocator(), "first");
    ctx.entered.waitUncancelable(t.io);
    _ = try cat.query(arena.allocator(), "second");
    _ = try cat.query(arena.allocator(), "third");
    ctx.gate.post(t.io);

    ctx.done.waitUncancelable(t.io);
    ctx.done.waitUncancelable(t.io);

    ctx.mutex.lockUncancelable(t.io);
    defer ctx.mutex.unlock(t.io);
    try t.expectEqual(@as(usize, 2), ctx.seen_count);
    try t.expectEqualStrings("first", ctx.seen[0][0..ctx.seen_lens[0]]);
    try t.expectEqualStrings("third", ctx.seen[1][0..ctx.seen_lens[1]]);
    const polled = cat.poll(.{ .live = .{ .arena = arena.allocator(), .query = "third" } });
    try t.expect(polled == .merged);
    try t.expect(!cat.hasPending());
}

test "index adoption waits while the worker searches and supersedes unpolled hits from the old index" {
    const Ctx = struct {
        io: std.Io,
        entered: std.Io.Semaphore = .{ .permits = 0 },
        gate: std.Io.Semaphore = .{ .permits = 0 },
        wakes: std.Io.Semaphore = .{ .permits = 0 },
        abort: std.atomic.Value(bool) = .init(false),
        block_first: bool = true,

        fn searchFn(raw: ?*anyopaque, view: core.index.View, text: []const u8, out: []core.search.Hit) usize {
            const c: *@This() = @ptrCast(@alignCast(raw));
            if (c.block_first) {
                c.block_first = false;
                c.entered.post(c.io);
                c.gate.waitUncancelable(c.io);
            }
            if (c.abort.load(.seq_cst)) return 0;
            return searchFiles(view, text, out);
        }

        fn wake(raw: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.wakes.post(c.io);
        }
    };

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "alpha-one.txt", .data = "" });
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const idx_path = try std.fs.path.join(t.allocator, &.{ root, ".names.flix" });
    defer t.allocator.free(idx_path);

    var ctx: Ctx = .{ .io = t.io };
    var cat: Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    defer {
        ctx.abort.store(true, .seq_cst);
        ctx.gate.post(t.io);
    }
    try cat.buildIndex(idx_path, root);
    cat.searcher.search_ctx = &ctx;
    cat.searcher.search_fn = Ctx.searchFn;
    cat.startWorker(t.io, .{ .ctx = &ctx, .wake = Ctx.wake });

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    // 1. Start a worker search on the 1-file index and pause it mid-flight.
    _ = try cat.query(arena.allocator(), "alpha");
    ctx.entered.waitUncancelable(t.io);

    // 2. Build a 2-file index while the worker still holds the 1-file View.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "alpha-two.txt", .data = "" });
    cat.rebuildIndex();
    try t.expect(cat.indexing());
    ctx.wakes.waitUncancelable(t.io);
    try t.expect(!cat.indexing());

    // Polling while the worker is still active must NOT swap/unmap the old View yet.
    const while_busy = cat.poll(.{ .live = .{ .arena = arena.allocator(), .query = "alpha" } });
    try t.expectEqual(Poll.redraw, while_busy);
    try t.expectEqual(@as(u32, 1), cat.files.?.view().?.count());

    // 3. Release the worker; the next poll adopts the 2-file index and returns .stale instead of ranking old hits.
    ctx.gate.post(t.io);
    ctx.wakes.waitUncancelable(t.io);
    const after_worker = cat.poll(.{ .live = .{ .arena = arena.allocator(), .query = "alpha" } });
    try t.expectEqual(Poll.stale, after_worker);
    try t.expectEqual(@as(u32, 2), cat.files.?.view().?.count());

    // 4. Also verify the hidden/retained race: worker finishes first, rebuild finishes second, poll(.retained) adopts safely.
    _ = try cat.query(arena.allocator(), "alpha");
    ctx.wakes.waitUncancelable(t.io);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "alpha-three.txt", .data = "" });
    cat.rebuildIndex();
    ctx.wakes.waitUncancelable(t.io);
    try t.expectEqual(Poll.stale, cat.poll(.retained));
    try t.expectEqual(@as(u32, 3), cat.files.?.view().?.count());
}

test "a failed background scan settles indexing and asks for a redraw while keeping the last good index" {
    const ScanProbe = struct {
        scans: u32 = 0,
        wakes: std.Io.Semaphore = .{ .permits = 0 },

        fn run(raw: ?*anyopaque, b: *core.index.Builder, root: []const u8) anyerror!void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.scans += 1;
            if (p.scans >= 2) return error.AccessDenied;
            try b.setRoot(root);
            _ = try b.add(core.index.no_parent, "kept.txt", .{});
        }

        fn wake(raw: ?*anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.wakes.post(t.io);
        }
    };

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const idx_path = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx_path);

    var probe: ScanProbe = .{};
    var cat: Catalog = .{ .gpa = t.allocator };
    defer cat.deinit();
    try cat.openIndexWithScanner(idx_path, root, .{ .ctx = &probe, .run = ScanProbe.run });
    cat.rebuildIndex();
    try t.expectEqual(@as(u32, 1), cat.files.?.view().?.count());

    cat.startWorker(t.io, .{ .ctx = &probe, .wake = ScanProbe.wake });
    cat.rebuildIndex();
    probe.wakes.waitUncancelable(t.io);
    try t.expect(!cat.indexing());
    try t.expectEqual(Poll.redraw, cat.poll(.idle));
    try t.expectEqual(@as(u32, 1), cat.files.?.view().?.count());
}
