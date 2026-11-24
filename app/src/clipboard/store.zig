//! SQLite clipboard history, query history, app open counts, and on-disk image storage.
const std = @import("std");
const model = @import("model.zig");

const Kind = model.Kind;
const Content = model.Content;
const QueryScope = model.QueryScope;
const Entry = model.Entry;
const Capture = model.Capture;
const Pasteboard = model.Pasteboard;
const App = model.App;
const Facts = model.Facts;
const Payload = model.Payload;

/// How many apps' open counts the store keeps; the lowest-ranked go first.
const max_app_opens = 500;
/// Frequency discounted by an hour of age each, the ranking Query History uses.
const app_open_rank = "(CAST(opens AS REAL) / (1.0 + max(0.0, ? - last_used) / 3600.0))";

pub const Budget = struct { bytes: u64 = 150 * 1024 * 1024, entries: u32 = 5000, queries: u32 = 1000 };
pub const Compactor = *const fn (arena: std.mem.Allocator, png: []const u8) ?[]const u8;
const window = 1000;

const lite = struct {
    const Db = opaque {};
    const Stmt = opaque {};
    extern "c" fn sqlite3_open_v2(path: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close_v2(db: *Db) c_int;
    extern "c" fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_prepare_v2(db: *Db, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: ?*?[*]const u8) c_int;
    extern "c" fn sqlite3_finalize(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_step(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_bind_text(stmt: *Stmt, i: c_int, s: [*]const u8, n: c_int, d: isize) c_int;
    extern "c" fn sqlite3_bind_blob(stmt: *Stmt, i: c_int, s: ?[*]const u8, n: c_int, d: isize) c_int;
    extern "c" fn sqlite3_bind_double(stmt: *Stmt, i: c_int, v: f64) c_int;
    extern "c" fn sqlite3_bind_int64(stmt: *Stmt, i: c_int, v: i64) c_int;
    extern "c" fn sqlite3_column_text(stmt: *Stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_blob(stmt: *Stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(stmt: *Stmt, i: c_int) c_int;
    extern "c" fn sqlite3_column_double(stmt: *Stmt, i: c_int) f64;
    extern "c" fn sqlite3_column_int64(stmt: *Stmt, i: c_int) i64;
    extern "c" fn sqlite3_column_type(stmt: *Stmt, i: c_int) c_int;
    extern "c" fn sqlite3_busy_timeout(db: *Db, ms: c_int) c_int;
    extern "c" fn sqlite3_changes(db: *Db) c_int;
    const ok = 0;
    const row = 100;
    const done = 101;
    const null_type = 5;
    const open_flags = 0x2 | 0x4; // READWRITE | CREATE
    /// SQLITE_TRANSIENT: SQLite copies the bound bytes.
    const transient: isize = -1;
};

const schema =
    \\PRAGMA auto_vacuum=INCREMENTAL;
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE IF NOT EXISTS entries(
    \\  id INTEGER PRIMARY KEY,
    \\  kind TEXT NOT NULL,
    \\  text TEXT NOT NULL,
    \\  created_at REAL NOT NULL,
    \\  source TEXT NOT NULL DEFAULT '',
    \\  source_name TEXT NOT NULL DEFAULT 'Clipboard',
    \\  pinned_at REAL,
    \\  width INTEGER NOT NULL DEFAULT 0,
    \\  height INTEGER NOT NULL DEFAULT 0,
    \\  byte_count INTEGER NOT NULL DEFAULT 0,
    \\  hash BLOB,
    \\  thumbnail BLOB,
    \\  png BLOB,
    \\  image_format TEXT NOT NULL DEFAULT '',
    \\  stored_bytes INTEGER NOT NULL DEFAULT 0,
    \\  compacted INTEGER NOT NULL DEFAULT 0,
    \\  content_kind TEXT,
    \\  content_detail TEXT,
    \\  sensitive INTEGER NOT NULL DEFAULT 0);
    \\CREATE INDEX IF NOT EXISTS entries_created ON entries(created_at DESC);
    \\CREATE INDEX IF NOT EXISTS entries_pinned ON entries(pinned_at);
    \\CREATE INDEX IF NOT EXISTS entries_hash ON entries(hash);
    \\CREATE TABLE IF NOT EXISTS queries(
    \\  id INTEGER PRIMARY KEY,
    \\  scope TEXT NOT NULL,
    \\  norm TEXT NOT NULL,
    \\  query TEXT NOT NULL,
    \\  uses INTEGER NOT NULL DEFAULT 1,
    \\  last_used REAL NOT NULL,
    \\  UNIQUE(scope, norm));
    \\CREATE INDEX IF NOT EXISTS queries_scope_norm ON queries(scope, norm);
    \\CREATE TABLE IF NOT EXISTS app_opens(
    \\  path TEXT PRIMARY KEY,
    \\  opens INTEGER NOT NULL DEFAULT 1,
    \\  last_used REAL NOT NULL);
    \\CREATE TEMP TABLE IF NOT EXISTS released(hash BLOB);
;

const columns_added_since_first_schema = [_][:0]const u8{
    "ALTER TABLE entries ADD COLUMN image_format TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE entries ADD COLUMN stored_bytes INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN compacted INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN content_kind TEXT",
    "ALTER TABLE entries ADD COLUMN content_detail TEXT",
    "ALTER TABLE entries ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0",
};

const stored_bytes_sql =
    "SELECT coalesce((SELECT sum(length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + coalesce(length(png), 0)) FROM entries), 0)" ++
    " + coalesce((SELECT sum(b) FROM (SELECT max(stored_bytes) AS b FROM entries WHERE image_format != '' GROUP BY hash, image_format)), 0)";

const columns = "id, kind, text, created_at, source, source_name, pinned_at, width, height, byte_count, content_kind, content_detail, sensitive";
const board_order = " ORDER BY pinned_at IS NULL, pinned_at, created_at DESC";

pub const Compaction = struct {
    hash: [32]u8,
    size: usize,
};

fn imagePathIn(images: []const u8, buf: *[std.posix.PATH_MAX]u8, hash: []const u8, format: []const u8) ?[:0]const u8 {
    if (hash.len != 32) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}.{s}", .{ images, &std.fmt.bytesToHex(hash[0..32].*, .lower), format }, 0) catch null;
}

fn writeImageIn(images: []const u8, hash: []const u8, format: []const u8, bytes: []const u8) !void {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = imagePathIn(images, &buf, hash, format) orelse return error.ClipboardStore;
    if (std.c.access(path, 0) == 0) return;
    var tmp_buf: [std.posix.PATH_MAX]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.tmp", .{path}, 0) catch return error.ClipboardStore;
    const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ClipboardStore;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    const synced = std.c.fsync(fd) == 0;
    _ = std.c.close(fd);
    if (written < bytes.len or !synced or std.c.rename(tmp, path) != 0) {
        _ = std.c.unlink(tmp);
        return error.ClipboardStore;
    }
}

fn readImageIn(images: []const u8, arena: std.mem.Allocator, hash: []const u8, format: []const u8, size: usize) ?[]const u8 {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    return model.readFile(arena, imagePathIn(images, &buf, hash, format) orelse return null, size);
}

fn unlinkImageIn(images: []const u8, hash: []const u8, format: []const u8) void {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (imagePathIn(images, &buf, hash, format)) |path| _ = std.c.unlink(path);
}

pub fn recompress(images: []const u8, arena: std.mem.Allocator, job: Compaction, compact: Compactor) ?usize {
    const png = readImageIn(images, arena, &job.hash, "png", job.size) orelse return null;
    const bytes = compact(arena, png) orelse return null;
    writeImageIn(images, &job.hash, "avif", bytes) catch return null;
    return bytes.len;
}

pub const Store = struct {
    db: *lite.Db,
    /// The folder that holds full pictures, one file per picture.
    images: []const u8,
    budget: Budget = .{},

    /// `path` may be `:memory:`; pictures still go to `images`.
    pub fn open(path: [:0]const u8, images: []const u8) !Store {
        var db: ?*lite.Db = null;
        if (lite.sqlite3_open_v2(path, &db, lite.open_flags, null) != lite.ok) {
            if (db) |d| _ = lite.sqlite3_close_v2(d);
            return error.ClipboardStore;
        }
        const s: Store = .{ .db = db.?, .images = images };
        errdefer s.close();
        _ = lite.sqlite3_busy_timeout(s.db, 2000);
        if (lite.sqlite3_exec(s.db, schema, null, null, null) != lite.ok) return error.ClipboardStore;
        for (columns_added_since_first_schema) |sql| _ = lite.sqlite3_exec(s.db, sql, null, null, null);
        try s.classifyUnclassified();
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{images}, 0) catch return error.ClipboardStore;
        _ = std.c.mkdir(dir_z, 0o700);
        const moved = try s.moveInlineImagesOut();
        s.clearStrayFiles(dir_z);
        if (moved or s.int("PRAGMA auto_vacuum", .{}) != 2)
            _ = lite.sqlite3_exec(s.db, "PRAGMA auto_vacuum=INCREMENTAL; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);", null, null, null);
        return s;
    }

    /// Rows recorded before entries carried their classification, done in
    /// one transaction so a crash leaves all of them for the next open.
    fn classifyUnclassified(s: Store) !void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const Row = struct { id: i64, text: []const u8 };
        var rows: std.ArrayList(Row) = .empty;
        {
            const stmt = try s.prepare("SELECT id, text FROM entries WHERE content_kind IS NULL AND kind = 'text'");
            defer _ = lite.sqlite3_finalize(stmt);
            while (lite.sqlite3_step(stmt) == lite.row)
                try rows.append(a, .{ .id = lite.sqlite3_column_int64(stmt, 0), .text = try a.dupe(u8, columnText(stmt, 1)) });
        }
        try s.run("BEGIN", .{});
        errdefer s.run("ROLLBACK", .{}) catch {};
        for (rows.items) |r| {
            var buf: [9]u8 = undefined;
            const c = model.classify(r.text);
            try s.run("UPDATE entries SET content_kind = ?, content_detail = ? WHERE id = ?", .{ @tagName(c), model.storedDetail(&buf, c), r.id });
        }
        try s.run("UPDATE entries SET content_kind = 'plain', content_detail = '' WHERE content_kind IS NULL", .{});
        try s.run("COMMIT", .{});
    }

    fn int(s: Store, sql: []const u8, args: anytype) ?i64 {
        const stmt = s.prepare(sql) catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, args);
        if (lite.sqlite3_step(stmt) != lite.row or lite.sqlite3_column_type(stmt, 0) == lite.null_type) return null;
        return lite.sqlite3_column_int64(stmt, 0);
    }

    fn writeImage(s: Store, hash: []const u8, format: []const u8, bytes: []const u8) !void {
        return writeImageIn(s.images, hash, format, bytes);
    }

    fn readImage(s: Store, arena: std.mem.Allocator, hash: []const u8, format: []const u8, size: usize) ?[]const u8 {
        return readImageIn(s.images, arena, hash, format, size);
    }

    fn unlinkImage(s: Store, hash: []const u8, format: []const u8) void {
        unlinkImageIn(s.images, hash, format);
    }

    fn moveInlineImagesOut(s: Store) !bool {
        var moved = false;
        while (true) {
            const stmt = try s.prepare("SELECT id, png FROM entries WHERE png IS NOT NULL AND length(png) > 0 LIMIT 1");
            defer _ = lite.sqlite3_finalize(stmt);
            if (lite.sqlite3_step(stmt) != lite.row) return moved;
            const id = lite.sqlite3_column_int64(stmt, 0);
            const png = columnBlob(stmt, 1);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(png, &hash, .{});
            try s.writeImage(&hash, "png", png);
            try s.run("UPDATE entries SET png = NULL, hash = ?, image_format = 'png', stored_bytes = ? WHERE id = ?", .{ Blob{ .bytes = &hash }, @as(i64, @intCast(png.len)), id });
            moved = true;
        }
    }

    fn clearStrayFiles(s: Store, dir_z: [:0]const u8) void {
        const dir = std.c.opendir(dir_z) orelse return;
        defer _ = std.c.closedir(dir);
        while (std.c.readdir(dir)) |ent| {
            const name = std.mem.sliceTo(&ent.name, 0);
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
            const format = name[dot + 1 ..];
            const known = std.mem.eql(u8, format, "png") or std.mem.eql(u8, format, "avif");
            if (!known and !std.mem.eql(u8, format, "tmp")) continue;
            var hash: [32]u8 = undefined;
            const referenced = known and dot == 64 and
                (std.fmt.hexToBytes(&hash, name[0..64]) catch null) != null and
                s.int("SELECT 1 FROM entries WHERE hash = ? AND image_format = ? LIMIT 1", .{ Blob{ .bytes = &hash }, format }) != null;
            if (referenced) continue;
            var buf: [std.posix.PATH_MAX]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir_z, name }, 0) catch continue;
            _ = std.c.unlink(path);
        }
    }

    fn removeWhere(s: Store, comptime condition: []const u8, args: anytype, defer_release: bool) !void {
        try s.run("INSERT INTO released SELECT DISTINCT hash FROM entries WHERE (" ++ condition ++ ") AND hash IS NOT NULL AND image_format != ''", args);
        try s.run("DELETE FROM entries WHERE " ++ condition, args);
        if (!defer_release) s.releaseFiles();
    }

    fn releaseFiles(s: Store) void {
        {
            const stmt = s.prepare("SELECT DISTINCT hash FROM released WHERE hash NOT IN (SELECT hash FROM entries WHERE hash IS NOT NULL AND image_format != '')") catch return;
            defer _ = lite.sqlite3_finalize(stmt);
            while (lite.sqlite3_step(stmt) == lite.row) {
                const hash = columnBlob(stmt, 0);
                s.unlinkImage(hash, "png");
                s.unlinkImage(hash, "avif");
            }
        }
        s.run("DELETE FROM released", .{}) catch {};
        _ = lite.sqlite3_exec(s.db, "PRAGMA incremental_vacuum", null, null, null);
    }

    fn keepWithinBudget(s: Store, defer_release: bool) !void {
        if ((s.int("SELECT count(*) FROM entries WHERE pinned_at IS NULL", .{}) orelse 0) > @as(i64, s.budget.entries)) {
            try s.removeWhere("pinned_at IS NULL AND id NOT IN (SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT ?)", .{@as(i64, s.budget.entries)}, defer_release);
        }
        // The newest row is the copy `add` just reported stored: pinned bytes
        // alone can exceed the budget, and it must not go with the rest.
        var total = s.int(stored_bytes_sql, .{}) orelse 0;
        var evicted: usize = 0;
        while (total > @as(i64, @intCast(s.budget.bytes))) {
            const id = s.int("SELECT id FROM entries WHERE pinned_at IS NULL AND id != (SELECT max(id) FROM entries) ORDER BY kind != 'image', created_at LIMIT 1", .{}) orelse return;
            const est = s.int("SELECT length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + coalesce(length(png), 0) + stored_bytes FROM entries WHERE id = ?", .{id}) orelse 0;
            try s.removeWhere("id = ?", .{id}, defer_release);
            evicted += 1;
            total -= est;
            if (evicted % 16 == 0 or total <= @as(i64, @intCast(s.budget.bytes))) {
                total = s.int(stored_bytes_sql, .{}) orelse 0;
            }
        }
    }

    pub fn nextCompaction(s: Store, now: f64) ?Compaction {
        const stmt = s.prepare("SELECT hash, stored_bytes FROM entries WHERE image_format = 'png' AND compacted = 0 AND length(hash) = 32 AND created_at < ? LIMIT 1") catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{now - model.compact_after_days * 86400});
        if (lite.sqlite3_step(stmt) != lite.row) return null;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, columnBlob(stmt, 0));
        return .{ .hash = hash, .size = @intCast(lite.sqlite3_column_int64(stmt, 1)) };
    }

    pub fn finishCompaction(s: Store, job: Compaction, avif_bytes: ?usize) void {
        if (avif_bytes) |len| {
            if (s.run("UPDATE entries SET image_format = 'avif', stored_bytes = ?, compacted = 1 WHERE hash = ? AND image_format = 'png'", .{ @as(i64, @intCast(len)), Blob{ .bytes = &job.hash } })) |_| {
                if (lite.sqlite3_changes(s.db) > 0) {
                    s.unlinkImage(&job.hash, "png");
                } else if (s.int("SELECT 1 FROM entries WHERE hash = ? AND image_format = 'avif' LIMIT 1", .{Blob{ .bytes = &job.hash }}) == null) {
                    s.unlinkImage(&job.hash, "avif");
                }
                return;
            } else |_| {
                if (s.int("SELECT 1 FROM entries WHERE hash = ? AND image_format = 'avif' LIMIT 1", .{Blob{ .bytes = &job.hash }}) == null) {
                    s.unlinkImage(&job.hash, "avif");
                }
            }
        }
        s.run("UPDATE entries SET compacted = 1 WHERE hash = ? AND image_format = 'png'", .{Blob{ .bytes = &job.hash }}) catch {};
    }

    pub fn compactOne(s: Store, arena: std.mem.Allocator, now: f64, compact: Compactor) bool {
        const job = s.nextCompaction(now) orelse return false;
        s.finishCompaction(job, recompress(s.images, arena, job, compact));
        return true;
    }

    pub fn close(s: Store) void {
        _ = lite.sqlite3_close_v2(s.db);
    }

    fn prepare(s: Store, sql: []const u8) !*lite.Stmt {
        var stmt: ?*lite.Stmt = null;
        if (lite.sqlite3_prepare_v2(s.db, sql.ptr, @intCast(sql.len), &stmt, null) != lite.ok) return error.ClipboardStore;
        return stmt.?;
    }

    fn run(s: Store, sql: []const u8, args: anytype) !void {
        const stmt = try s.prepare(sql);
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, args);
        if (lite.sqlite3_step(stmt) != lite.done) return error.ClipboardStore;
    }

    /// Stores `cap` unless it repeats the newest entry. True when stored.
    pub fn add(s: Store, cap: Capture, source: []const u8, source_name: []const u8, now: f64) !bool {
        return s.addEntry(cap, source, source_name, now, false);
    }

    fn addEntry(s: Store, cap: Capture, source: []const u8, source_name: []const u8, now: f64, defer_release: bool) !bool {
        var hash: [32]u8 = undefined;
        const kind: Kind, const text: []const u8 = switch (cap) {
            .text => |t| .{ .text, t },
            .file => |p| .{ .file, p },
            .image => |img| blk: {
                std.crypto.hash.sha2.Sha256.hash(img.png, &hash, .{});
                break :blk .{ .image, img.name };
            },
        };
        if (s.repeatsNewest(kind, text, if (cap == .image) &hash else null)) return false;
        const img: Capture.Image = if (cap == .image) cap.image else .{ .name = "", .png = "", .thumbnail = "", .width = 0, .height = 0 };
        if (cap == .image) try s.writeImage(&hash, "png", img.png);
        const content: Content = if (cap == .text) model.classify(text) else .plain;
        var detail_buf: [9]u8 = undefined;
        const sensitive: i64 = @intFromBool(model.isSensitiveSource(source, source_name));
        try s.run("INSERT INTO entries(kind, text, created_at, source, source_name, width, height, byte_count, hash, thumbnail, image_format, stored_bytes, content_kind, content_detail, sensitive) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", .{
            @tagName(kind),                   text,                            now,                             source,                                              source_name,
            @as(i64, img.width),              @as(i64, img.height),            @as(i64, @intCast(img.png.len)), Blob{ .bytes = if (cap == .image) &hash else null }, Blob{ .bytes = img.thumbnail },
            if (cap == .image) "png" else "", @as(i64, @intCast(img.png.len)), @tagName(content),               model.storedDetail(&detail_buf, content),            sensitive,
        });
        try s.keepWithinBudget(defer_release);
        return true;
    }

    /// Records what `board` holds, as copied from `app`. True when any of it
    /// was stored; a repeat of the newest entry is not.
    pub fn capture(s: Store, arena: std.mem.Allocator, board: Pasteboard, app: App, now: f64) !bool {
        const items = model.captures(arena, board, app.bundle_id);
        if (items.len == 0) return false;
        try s.run("BEGIN IMMEDIATE", .{});
        errdefer s.run("ROLLBACK", .{}) catch {};
        var stored = false;
        for (items) |cap| stored = (try s.addEntry(cap, app.bundle_id, app.name, now, true)) or stored;
        try s.run("COMMIT", .{});
        if (stored) s.releaseFiles();
        return stored;
    }

    /// The selection's preview, read once its facts say there is one.
    pub fn load(s: Store, arena: std.mem.Allocator, e: Entry, f: Facts) Payload {
        if (e.kind == .image) return if (s.image(arena, e.id)) |bytes| .{ .picture = bytes } else .none;
        const path = e.filePath() orelse return .none;
        const size = f.size orelse return .none;
        const ext = model.extension(path);
        const z = arena.dupeSentinel(u8, path, 0) catch return .none;
        if (model.inSet(ext, &model.board_image_extensions) and size <= model.max_image_bytes) {
            if (model.readFile(arena, z, @intCast(size))) |bytes| return .{ .picture = bytes };
        } else if (model.inSet(ext, &model.text_extensions)) {
            if (model.readFile(arena, z, @intCast(@min(size, model.text_preview_bytes)))) |bytes| return .{ .text = bytes };
        }
        return .none;
    }

    fn repeatsQuery(s: Store, sql: []const u8, kind: Kind, text: []const u8, hash: ?*const [32]u8) ?bool {
        const stmt = s.prepare(sql) catch return false;
        defer _ = lite.sqlite3_finalize(stmt);
        if (lite.sqlite3_step(stmt) != lite.row) return null;
        if (!std.mem.eql(u8, columnText(stmt, 0), @tagName(kind))) return false;
        if (hash) |h| return std.mem.eql(u8, columnBlob(stmt, 2), h);
        return std.mem.eql(u8, columnText(stmt, 1), text);
    }

    fn repeatsNewest(s: Store, kind: Kind, text: []const u8, hash: ?*const [32]u8) bool {
        return s.repeatsQuery("SELECT kind, text, hash FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT 1", kind, text, hash) orelse
            s.repeatsQuery("SELECT kind, text, hash FROM entries ORDER BY created_at DESC LIMIT 1", kind, text, hash) orelse false;
    }

    /// Pinned first by pin time, then newest first. An empty query lists
    /// the newest entries; a query matches their text, case-insensitively.
    pub fn list(s: Store, arena: std.mem.Allocator, query: []const u8) ![]Entry {
        const q = std.mem.trim(u8, query, " ");
        const stmt = if (q.len == 0)
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE pinned_at IS NOT NULL OR id IN (SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT " ++ std.fmt.comptimePrint("{d}", .{window}) ++ ")" ++ board_order)
        else
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE instr(lower(text || CASE kind WHEN 'image' THEN ' ' || width || '\u{00D7}' || height ELSE '' END), lower(?)) > 0" ++ board_order ++ " LIMIT " ++ std.fmt.comptimePrint("{d}", .{model.search_limit}));
        defer _ = lite.sqlite3_finalize(stmt);
        if (q.len > 0) bindAll(stmt, .{q});
        var out: std.ArrayList(Entry) = .empty;
        while (lite.sqlite3_step(stmt) == lite.row) {
            try out.append(arena, .{
                .id = lite.sqlite3_column_int64(stmt, 0),
                .kind = std.meta.stringToEnum(Kind, columnText(stmt, 1)) orelse .text,
                .text = try arena.dupe(u8, columnText(stmt, 2)),
                .created_at = lite.sqlite3_column_double(stmt, 3),
                .source = try arena.dupe(u8, columnText(stmt, 4)),
                .source_name = try arena.dupe(u8, columnText(stmt, 5)),
                .pinned_at = if (lite.sqlite3_column_type(stmt, 6) == lite.null_type) null else lite.sqlite3_column_double(stmt, 6),
                .width = @intCast(lite.sqlite3_column_int64(stmt, 7)),
                .height = @intCast(lite.sqlite3_column_int64(stmt, 8)),
                .byte_count = @intCast(lite.sqlite3_column_int64(stmt, 9)),
                .content = model.storedContent(columnText(stmt, 10), try arena.dupe(u8, columnText(stmt, 11))),
                .sensitive = lite.sqlite3_column_int64(stmt, 12) != 0,
            });
        }
        return out.items;
    }

    /// The full image an entry holds, in `arena`'s memory.
    pub fn image(s: Store, arena: std.mem.Allocator, id: i64) ?[]const u8 {
        const stmt = s.prepare("SELECT hash, image_format, stored_bytes FROM entries WHERE id = ? AND image_format != ''") catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{id});
        if (lite.sqlite3_step(stmt) != lite.row) return null;
        return s.readImage(arena, columnBlob(stmt, 0), columnText(stmt, 1), @intCast(lite.sqlite3_column_int64(stmt, 2)));
    }

    pub fn thumbnail(s: Store, arena: std.mem.Allocator, id: i64) []const u8 {
        const stmt = s.prepare("SELECT thumbnail FROM entries WHERE id = ?") catch return "";
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{id});
        if (lite.sqlite3_step(stmt) != lite.row) return "";
        return arena.dupe(u8, columnBlob(stmt, 0)) catch "";
    }

    pub fn togglePin(s: Store, id: i64, now: f64) !void {
        try s.run("UPDATE entries SET pinned_at = CASE WHEN pinned_at IS NULL THEN ? ELSE NULL END WHERE id = ?", .{ now, id });
    }

    pub fn delete(s: Store, id: i64) !void {
        try s.removeWhere("id = ?", .{id}, false);
    }

    /// Drops unpinned entries older than `days`; pinned ones stay.
    pub fn prune(s: Store, now: f64, days: u32) !void {
        try s.run("BEGIN IMMEDIATE", .{});
        errdefer s.run("ROLLBACK", .{}) catch {};
        try s.removeWhere("pinned_at IS NULL AND created_at < ?", .{now - @as(f64, @floatFromInt(days)) * 86400}, true);
        try s.keepWithinBudget(true);
        try s.run("COMMIT", .{});
        s.releaseFiles();
    }

    pub fn recordQuery(s: Store, scope: QueryScope, raw: []const u8, now: f64) !void {
        const q = std.mem.trim(u8, raw, " \t\r\n");
        if (q.len == 0 or q.len > model.max_text_bytes) return;
        try s.run(
            "INSERT INTO queries(scope, norm, query, uses, last_used) VALUES(?, lower(?), ?, 1, ?) " ++
                "ON CONFLICT(scope, norm) DO UPDATE SET query = excluded.query, uses = queries.uses + 1, last_used = excluded.last_used",
            .{ @tagName(scope), q, q, now },
        );
        try s.run(
            "DELETE FROM queries WHERE id NOT IN (SELECT id FROM queries ORDER BY (CAST(uses AS REAL) / (1.0 + max(0.0, ? - last_used) / 3600.0)) DESC, last_used DESC, id DESC LIMIT ?)",
            .{ now, @as(i64, s.budget.queries) },
        );
    }

    pub fn completeQuery(s: Store, buf: []u8, scope: QueryScope, prefix: []const u8, now: f64) ?[]const u8 {
        if (prefix.len == 0 or prefix.len >= buf.len) return null;
        const stmt = s.prepare(
            "SELECT query FROM queries WHERE scope = ? AND length(norm) > length(?) AND substr(norm, 1, length(?)) = lower(?) " ++
                "ORDER BY (CAST(uses AS REAL) / (1.0 + max(0.0, ? - last_used) / 3600.0)) DESC, last_used DESC, id DESC LIMIT 1",
        ) catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{ @tagName(scope), prefix, prefix, prefix, now });
        if (lite.sqlite3_step(stmt) != lite.row) return null;
        const q = columnText(stmt, 0);
        if (q.len <= prefix.len or q.len > buf.len or !std.ascii.startsWithIgnoreCase(q, prefix)) return null;
        @memcpy(buf[0..q.len], q);
        return buf[0..q.len];
    }

    pub fn clearQueries(s: Store) !void {
        try s.run("DELETE FROM queries", .{});
    }

    pub fn recordAppOpen(s: Store, path: []const u8, now: f64) !void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
        try s.run(
            "INSERT INTO app_opens(path, opens, last_used) VALUES(?, 1, ?) " ++
                "ON CONFLICT(path) DO UPDATE SET opens = app_opens.opens + 1, last_used = excluded.last_used",
            .{ path, now },
        );
        try s.run(
            "DELETE FROM app_opens WHERE path NOT IN (SELECT path FROM app_opens ORDER BY " ++ app_open_rank ++ " DESC, last_used DESC LIMIT ?)",
            .{ now, @as(i64, max_app_opens) },
        );
    }

    /// Paths of the most-opened apps, best first, copied into `arena`.
    pub fn topApps(s: Store, arena: std.mem.Allocator, limit: usize, now: f64) ![]const []const u8 {
        const stmt = try s.prepare("SELECT path FROM app_opens ORDER BY " ++ app_open_rank ++ " DESC, last_used DESC LIMIT ?");
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{ now, @as(i64, @intCast(limit)) });
        var out: std.ArrayList([]const u8) = .empty;
        while (lite.sqlite3_step(stmt) == lite.row) try out.append(arena, try arena.dupe(u8, columnText(stmt, 0)));
        return out.items;
    }

    pub fn clearAppOpens(s: Store) !void {
        try s.run("DELETE FROM app_opens", .{});
    }

    pub fn queryCount(s: Store) usize {
        return @intCast(s.int("SELECT count(*) FROM queries", .{}) orelse 0);
    }
};

const Blob = struct { bytes: ?[]const u8 };

fn bindAll(stmt: *lite.Stmt, args: anytype) void {
    inline for (args, 1..) |a, i| {
        const T = @TypeOf(a);
        _ = if (T == f64) lite.sqlite3_bind_double(stmt, i, a) else if (T == i64) lite.sqlite3_bind_int64(stmt, i, a) else if (T == Blob)
            (if (a.bytes) |b| lite.sqlite3_bind_blob(stmt, i, b.ptr, @intCast(b.len), lite.transient) else lite.sqlite3_bind_blob(stmt, i, null, 0, lite.transient))
        else blk: {
            const s: []const u8 = a;
            break :blk lite.sqlite3_bind_text(stmt, i, s.ptr, @intCast(s.len), lite.transient);
        };
    }
}

fn columnText(stmt: *lite.Stmt, i: c_int) []const u8 {
    const p = lite.sqlite3_column_text(stmt, i) orelse return "";
    return p[0..@intCast(lite.sqlite3_column_bytes(stmt, i))];
}

fn columnBlob(stmt: *lite.Stmt, i: c_int) []const u8 {
    const p = lite.sqlite3_column_blob(stmt, i) orelse return "";
    return p[0..@intCast(lite.sqlite3_column_bytes(stmt, i))];
}
