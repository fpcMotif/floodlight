//! What the panel searches: the installed apps, scored in memory, and the
//! home folder's name index, mapped from disk by the Zig core.
const std = @import("std");
const core = @import("floodlight_core");

pub const Kind = enum { app, file, folder };

pub const Row = struct {
    kind: Kind,
    title: []const u8,
    /// Where it lives, with the home folder shown as `~`.
    subtitle: []const u8,
    path: []const u8,
    score: i32,
};

pub const App = struct {
    /// The bundle's name without `.app`.
    name: []const u8,
    path: []const u8,
};

/// Apps outrank files that score the same: a launcher's first job.
pub const app_bonus: i32 = 60;
pub const max_rows = 7;

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    apps: std.ArrayList(App) = .empty,
    files: ?core.index.Mapped = null,
    home: []const u8 = "",

    pub fn deinit(cat: *Catalog) void {
        for (cat.apps.items) |a| cat.gpa.free(a.path);
        cat.apps.deinit(cat.gpa);
        if (cat.files) |*m| m.close();
        cat.* = undefined;
    }

    /// Takes ownership of `path`; the name is a slice of it.
    pub fn addApp(cat: *Catalog, path: []u8) !void {
        const base = std.fs.path.basename(path);
        try cat.apps.append(cat.gpa, .{ .name = base[0 .. base.len - ".app".len], .path = path });
    }

    /// Replaces the mapped index; the old mapping is unmapped.
    pub fn setFiles(cat: *Catalog, mapped: core.index.Mapped) void {
        if (cat.files) |*m| m.close();
        cat.files = mapped;
    }

    /// The best rows for `query`, best first, in `arena`'s memory.
    pub fn query(cat: *const Catalog, arena: std.mem.Allocator, text: []const u8) ![]Row {
        var rows: std.ArrayList(Row) = .empty;
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return rows.items;

        var needle_buf: [core.search.max_term_len]u8 = undefined;
        const needle = std.ascii.lowerString(&needle_buf, trimmed[0..@min(trimmed.len, needle_buf.len)]);
        for (cat.apps.items) |a| {
            const s = core.match.score(a.name, needle, 0) orelse continue;
            try rows.append(arena, .{ .kind = .app, .title = a.name, .subtitle = "Application", .path = a.path, .score = s + app_bonus });
        }

        if (cat.files) |m| {
            var hits: [max_rows * 2]core.search.Hit = undefined;
            const n = core.search.search(m.view, trimmed, &hits);
            const root = m.view.root;
            for (hits[0..n]) |h| {
                var buf: [4096]u8 = undefined;
                const rel = m.view.relativePath(h.id, &buf) orelse continue;
                const path = try std.fs.path.join(arena, &.{ root, rel });
                // Bundles are apps, listed above from the catalog; their insides are no one's.
                if (std.mem.endsWith(u8, rel, ".app") or std.mem.indexOf(u8, rel, ".app/") != null) continue;
                const dir = std.fs.path.dirname(path) orelse "/";
                try rows.append(arena, .{
                    .kind = if (m.view.flags[h.id].dir) .folder else .file,
                    .title = std.fs.path.basename(path),
                    .subtitle = try tildify(arena, dir, cat.home),
                    .path = path,
                    .score = h.score,
                });
            }
        }
        std.mem.sort(Row, rows.items, {}, better);
        return rows.items[0..@min(rows.items.len, max_rows)];
    }
};

fn better(_: void, a: Row, b: Row) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.title.len < b.title.len;
}

pub fn tildify(arena: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    const rest = path[home.len..];
    if (rest.len != 0 and rest[0] != '/') return path;
    return std.mem.concat(arena, u8, &.{ "~", rest });
}

/// Where apps are installed. The user's own folder comes from `home`.
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

/// Scans `root` into an index file at `out_path` and maps it.
/// Runs off the main thread: a home folder takes seconds.
pub fn buildFileIndex(gpa: std.mem.Allocator, root: []const u8, out_path: []const u8) !core.index.Mapped {
    var b = core.index.Builder.init(gpa);
    defer b.deinit();
    try core.scan.scan(&b, root, .{});
    try b.writeFile(core.sys.cwd, out_path);
    return core.index.Mapped.open(core.sys.cwd, out_path);
}
