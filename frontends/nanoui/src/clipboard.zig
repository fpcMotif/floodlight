//! Clipboard history: what was copied, classified as the Swift board does,
//! kept in SQLite beside the file index.
const std = @import("std");

pub const Kind = enum { text, file, image };

/// What a text entry holds, decided from its characters alone.
pub const Content = enum { plain, link, color, code, path };

pub const QueryScope = enum { search, clipboard };

pub const Entry = struct {
    id: i64,
    kind: Kind,
    /// The text; a file's path; an image's name.
    text: []const u8,
    created_at: f64,
    source: []const u8 = "",
    source_name: []const u8 = "Clipboard",
    pinned_at: ?f64 = null,
    width: u32 = 0,
    height: u32 = 0,
    byte_count: u64 = 0,
    thumbnail: []const u8 = "",
    sensitive: bool = false,

    pub fn isSensitive(e: Entry) bool {
        return e.sensitive or isSensitiveSource(e.source, e.source_name);
    }

    pub fn content(e: Entry) Content {
        return if (e.kind == .text) classify(e.text) else .plain;
    }

    pub fn linkUrl(e: Entry) ?[]const u8 {
        return if (e.content() == .link) std.mem.trim(u8, e.text, " \t\r\n") else null;
    }

    /// A file, or text that names one.
    pub fn filePath(e: Entry) ?[]const u8 {
        if (e.kind == .file) return e.text;
        if (e.kind == .text and e.content() == .path) return pathOf(e.text);
        return null;
    }

    pub fn title(e: Entry, arena: std.mem.Allocator) []const u8 {
        if (e.filePath()) |p| {
            const name = std.fs.path.basename(p);
            return if (name.len > 0) name else e.text;
        }
        return switch (e.kind) {
            .image => if (e.text.len > 0) e.text else "Image",
            else => oneLine(arena, e.text),
        };
    }

    /// "{App} · {age}", then the parent folder or the image's size.
    pub fn subtitle(e: Entry, arena: std.mem.Allocator, now: f64) []const u8 {
        const head = std.fmt.allocPrint(arena, "{s} \u{00B7} {s}", .{ e.source_name, age(arena, now - e.created_at) }) catch return "";
        const detail: ?[]const u8 = if (e.filePath()) |p| parentName(p) else if (e.kind == .image) std.fmt.allocPrint(arena, "{d}\u{00D7}{d}", .{ e.width, e.height }) catch null else null;
        const d = detail orelse return head;
        return std.fmt.allocPrint(arena, "{s} \u{00B7} {s}", .{ head, d }) catch head;
    }
};

const sensitive_source_markers = [_][]const u8{
    "1password",
    "onepassword",
    "passwords",
    "keychain",
    "bitwarden",
    "keepass",
    "dashlane",
    "lastpass",
    "enpass",
    "proton.pass",
    "proton pass",
    "concealed",
    "sensitive",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn isSensitiveSource(source: []const u8, source_name: []const u8) bool {
    for (sensitive_source_markers) |m| {
        if (containsIgnoreCase(source, m) or containsIgnoreCase(source_name, m)) return true;
    }
    return false;
}

pub fn classify(text: []const u8) Content {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfAny(u8, text, "\r\n") == null and
        (std.mem.startsWith(u8, text, "file://") or std.mem.startsWith(u8, text, "~/") or std.mem.startsWith(u8, text, "/"))) return .path;
    if (domain(t) != null) return .link;
    if (parseColor(t) != null) return .color;
    if (codeLanguage(t) != null) return .code;
    return .plain;
}

fn pathOf(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "file://")) text["file://".len..] else text;
}

fn parentName(path: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    const name = std.fs.path.basename(dir);
    return if (name.len > 0) name else null;
}

/// A link's host without `www.`; null when the text is not an http(s) link.
pub fn domain(text: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, text, "https://")) text["https://".len..] else if (std.mem.startsWith(u8, text, "http://")) text["http://".len..] else return null;
    if (std.mem.indexOfAny(u8, text, " \t\r\n") != null) return null;
    var host = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (std.ascii.startsWithIgnoreCase(host, "www.")) host = host[4..];
    if (host.len == 0) return null;
    return host;
}

pub const Rgba = struct { r: u8, g: u8, b: u8, a: ?u8 = null };

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
pub fn parseColor(text: []const u8) ?Rgba {
    if (text.len < 4 or text[0] != '#') return null;
    const hex = text[1..];
    for (hex) |ch| if (!std.ascii.isHex(ch)) return null;
    const byte = struct {
        fn at(h: []const u8, i: usize) u8 {
            return std.fmt.parseInt(u8, h[i .. i + 2], 16) catch 0;
        }
        fn nibble(h: []const u8, i: usize) u8 {
            return (std.fmt.charToDigit(h[i], 16) catch 0) * 17;
        }
    };
    return switch (hex.len) {
        3 => .{ .r = byte.nibble(hex, 0), .g = byte.nibble(hex, 1), .b = byte.nibble(hex, 2) },
        6 => .{ .r = byte.at(hex, 0), .g = byte.at(hex, 2), .b = byte.at(hex, 4) },
        8 => .{ .r = byte.at(hex, 0), .g = byte.at(hex, 2), .b = byte.at(hex, 4), .a = byte.at(hex, 6) },
        else => null,
    };
}

pub fn rgbDescription(arena: std.mem.Allocator, c: Rgba) []const u8 {
    if (c.a) |a| return std.fmt.allocPrint(arena, "rgba({d}, {d}, {d}, {d:.2})", .{ c.r, c.g, c.b, @as(f64, @floatFromInt(a)) / 255 }) catch "";
    return std.fmt.allocPrint(arena, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b }) catch "";
}

const code_markers = [_][]const u8{ "func ", "struct ", "import ", "class ", "const ", "function ", "export " };

pub fn codeLanguage(text: []const u8) ?[]const u8 {
    const wrapped = text.len >= 2 and ((text[0] == '{' and text[text.len - 1] == '}') or (text[0] == '[' and text[text.len - 1] == ']'));
    if (wrapped and (std.json.validate(std.heap.page_allocator, text) catch false)) return "JSON";
    for (code_markers) |m| if (std.mem.indexOf(u8, text, m) != null) return "Code";
    if (std.mem.startsWith(u8, text, "<!DOCTYPE") or std.mem.startsWith(u8, text, "<html")) return "HTML";
    if (text.len > 1 and text[0] == '<' and text[text.len - 1] == '>' and std.mem.indexOf(u8, text, "</") != null) return "HTML";
    return null;
}

const max_title_bytes = 512;

/// Newline runs as one space, the ends trimmed.
fn oneLine(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_break = false;
    var view = std.unicode.Utf8View.init(text) catch return text;
    var it = view.iterator();
    while (out.items.len < max_title_bytes) {
        const cp = it.nextCodepointSlice() orelse break;
        const breaks = std.mem.eql(u8, cp, "\n") or std.mem.eql(u8, cp, "\r") or std.mem.eql(u8, cp, "\u{0085}") or std.mem.eql(u8, cp, "\u{2028}") or std.mem.eql(u8, cp, "\u{2029}");
        if (breaks) {
            if (!in_break) out.append(arena, ' ') catch return text;
            in_break = true;
        } else {
            out.appendSlice(arena, cp) catch return text;
            in_break = false;
        }
    }
    const t = std.mem.trim(u8, out.items, " \t");
    return if (t.len == 0) "(Empty text)" else t;
}

pub fn age(arena: std.mem.Allocator, seconds: f64) []const u8 {
    const s: i64 = @intFromFloat(@max(0, seconds));
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divFloor(s, 60)}) catch "";
    if (s < 86400) return std.fmt.allocPrint(arena, "{d}h", .{@divFloor(s, 3600)}) catch "";
    const days = @divFloor(s, 86400);
    if (days < 30) return std.fmt.allocPrint(arena, "{d}d", .{days}) catch "";
    if (@divFloor(days, 30) < 12) return std.fmt.allocPrint(arena, "{d}mo", .{@divFloor(days, 30)}) catch "";
    return std.fmt.allocPrint(arena, "{d}y", .{@divFloor(days, 365)}) catch "";
}

pub const Filter = enum {
    all,
    text,
    files,
    images,

    pub const options = [_]Filter{ .all, .text, .files, .images };

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All",
            .text => "Text",
            .files => "Files",
            .images => "Images",
        };
    }

    pub fn symbol(f: Filter) []const u8 {
        return switch (f) {
            .all => "sparkle.magnifyingglass",
            .text => "doc.text.fill",
            .files => "doc.fill",
            .images => "photo.fill",
        };
    }

    pub fn includes(f: Filter, e: Entry) bool {
        return switch (f) {
            .all => true,
            .text => e.kind == .text,
            .files => e.kind == .file,
            .images => e.kind == .image,
        };
    }
};

/// The inspector's Type for a file, from its extension.
pub fn fileType(arena: std.mem.Allocator, path: []const u8, is_dir: bool) []const u8 {
    if (is_dir) return "Folder";
    const ext = extension(path);
    const table = [_]struct { []const u8, []const []const u8 }{
        .{ "Video", &.{ "mp4", "mov", "m4v", "webm", "mkv", "avi" } },
        .{ "Image", &.{ "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "svg" } },
        .{ "JSON", &.{"json"} },
        .{ "Markdown", &.{ "md", "markdown", "mdown", "mkdn" } },
        .{ "Plain Text", &.{ "txt", "text" } },
        .{ "Source Code", &.{ "swift", "rs", "ts", "js", "py", "go", "c", "cpp", "h", "sh" } },
        .{ "Archive", &.{ "zip", "tar", "gz", "dmg" } },
    };
    for (table) |t| if (inSet(ext, t[1])) return t[0];
    return if (ext.len == 0) "File" else std.ascii.allocUpperString(arena, ext) catch ext;
}

pub const image_extensions = [_][]const u8{ "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif", "bmp", "avif", "ico", "icns", "svg" };
pub const video_extensions = [_][]const u8{ "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg" };
pub const text_extensions = [_][]const u8{
    "json", "py",       "swift", "js",   "mjs", "cjs",  "ts",  "mts",  "cts", "jsx", "tsx", "rs",  "go",   "c",    "cpp",        "cc",   "cxx",
    "h",    "hpp",      "hh",    "hxx",  "m",   "mm",   "cs",  "java", "kt",  "kts", "rb",  "php", "sh",   "bash", "zsh",        "fish", "sql",
    "md",   "markdown", "mdown", "mkdn", "txt", "text", "log", "csv",  "tsv", "rtf", "env", "ini", "conf", "cfg",  "properties", "zig",  "toml",
    "yaml", "yml",      "xml",   "html", "css",
};

pub fn extension(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return if (ext.len > 1) ext[1..] else "";
}

pub fn inSet(ext: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.ascii.eqlIgnoreCase(ext, s)) return true;
    return false;
}

pub const Word = struct { characters: usize, words: usize, lines: usize };

pub fn counts(text: []const u8) Word {
    var words: usize = 0;
    var in_word = false;
    for (text) |b| {
        const space = std.ascii.isWhitespace(b);
        if (!space and !in_word) words += 1;
        in_word = !space;
    }
    return .{
        .characters = std.unicode.utf8CountCodepoints(text) catch text.len,
        .words = words,
        .lines = std.mem.count(u8, text, "\n") + 1,
    };
}

/// What a copy put on the pasteboard, before it is stored.
pub const Capture = union(enum) {
    text: []const u8,
    file: []const u8,
    image: Image,

    pub const Image = struct {
        name: []const u8,
        png: []const u8,
        thumbnail: []const u8,
        width: u32,
        height: u32,
    };
};

/// Text past this is dropped whole, as the Swift store does.
pub const max_text_bytes = 32_000;
/// Image representations past this are not read.
pub const max_image_bytes = 15 * 1024 * 1024;
pub const retention_days = 30;
pub const compact_after_days = 7;
pub const Budget = struct { bytes: u64 = 150 * 1024 * 1024, entries: u32 = 5000, queries: u32 = 1000 };
pub const Compactor = *const fn (arena: std.mem.Allocator, png: []const u8) ?[]const u8;
const window = 1000;
const search_limit = 200;

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
    \\CREATE TEMP TABLE IF NOT EXISTS released(hash BLOB);
;

const columns_added_since_inline_images = [_][:0]const u8{
    "ALTER TABLE entries ADD COLUMN image_format TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE entries ADD COLUMN stored_bytes INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN compacted INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0",
};

const stored_bytes_sql =
    "SELECT coalesce((SELECT sum(length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + coalesce(length(png), 0)) FROM entries), 0)" ++
    " + coalesce((SELECT sum(b) FROM (SELECT max(stored_bytes) AS b FROM entries WHERE image_format != '' GROUP BY hash, image_format)), 0)";

const columns = "id, kind, text, created_at, source, source_name, pinned_at, width, height, byte_count, thumbnail, sensitive";
const board_order = " ORDER BY pinned_at IS NULL, pinned_at, created_at DESC";

pub const Store = struct {
    db: *lite.Db,
    images: ?[]const u8,
    budget: Budget = .{},

    pub fn open(path: [:0]const u8, images: ?[]const u8) !Store {
        var db: ?*lite.Db = null;
        if (lite.sqlite3_open_v2(path, &db, lite.open_flags, null) != lite.ok) {
            if (db) |d| _ = lite.sqlite3_close_v2(d);
            return error.ClipboardStore;
        }
        const s: Store = .{ .db = db.?, .images = images };
        _ = lite.sqlite3_busy_timeout(s.db, 2000);
        if (lite.sqlite3_exec(s.db, schema, null, null, null) != lite.ok) {
            s.close();
            return error.ClipboardStore;
        }
        for (columns_added_since_inline_images) |sql| _ = lite.sqlite3_exec(s.db, sql, null, null, null);
        if (images) |dir| {
            var buf: [std.posix.PATH_MAX]u8 = undefined;
            const dir_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch {
                s.close();
                return error.ClipboardStore;
            };
            _ = std.c.mkdir(dir_z, 0o700);
            const moved = s.moveInlineImagesOut() catch {
                s.close();
                return error.ClipboardStore;
            };
            s.clearStrayFiles(dir_z);
            if (moved or s.int("PRAGMA auto_vacuum", .{}) != 2)
                _ = lite.sqlite3_exec(s.db, "PRAGMA auto_vacuum=INCREMENTAL; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);", null, null, null);
        }
        return s;
    }

    fn int(s: Store, sql: []const u8, args: anytype) ?i64 {
        const stmt = s.prepare(sql) catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, args);
        if (lite.sqlite3_step(stmt) != lite.row or lite.sqlite3_column_type(stmt, 0) == lite.null_type) return null;
        return lite.sqlite3_column_int64(stmt, 0);
    }

    fn imagePath(s: Store, buf: *[std.posix.PATH_MAX]u8, hash: []const u8, format: []const u8) ?[:0]const u8 {
        const dir = s.images orelse return null;
        if (hash.len != 32) return null;
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}.{s}", .{ dir, &std.fmt.bytesToHex(hash[0..32].*, .lower), format }, 0) catch null;
    }

    fn writeImage(s: Store, hash: []const u8, format: []const u8, bytes: []const u8) !void {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const path = s.imagePath(&buf, hash, format) orelse return error.ClipboardStore;
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

    fn readImage(s: Store, arena: std.mem.Allocator, hash: []const u8, format: []const u8, size: usize) ?[]const u8 {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const path = s.imagePath(&buf, hash, format) orelse return null;
        const fd = std.c.open(path, .{});
        if (fd < 0) return null;
        defer _ = std.c.close(fd);
        const out = arena.alloc(u8, size) catch return null;
        var got: usize = 0;
        while (got < size) {
            const n = std.c.read(fd, out[got..].ptr, size - got);
            if (n <= 0) return null;
            got += @intCast(n);
        }
        return out;
    }

    fn unlinkImage(s: Store, hash: []const u8, format: []const u8) void {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (s.imagePath(&buf, hash, format)) |path| _ = std.c.unlink(path);
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

    fn removeWhere(s: Store, comptime condition: []const u8, args: anytype) !void {
        try s.run("INSERT INTO released SELECT DISTINCT hash FROM entries WHERE (" ++ condition ++ ") AND hash IS NOT NULL AND image_format != ''", args);
        try s.run("DELETE FROM entries WHERE " ++ condition, args);
        {
            const stmt = try s.prepare("SELECT DISTINCT hash FROM released WHERE hash NOT IN (SELECT hash FROM entries WHERE hash IS NOT NULL AND image_format != '')");
            defer _ = lite.sqlite3_finalize(stmt);
            while (lite.sqlite3_step(stmt) == lite.row) {
                const hash = columnBlob(stmt, 0);
                s.unlinkImage(hash, "png");
                s.unlinkImage(hash, "avif");
            }
        }
        try s.run("DELETE FROM released", .{});
        _ = lite.sqlite3_exec(s.db, "PRAGMA incremental_vacuum", null, null, null);
    }

    fn keepWithinBudget(s: Store) !void {
        try s.removeWhere("pinned_at IS NULL AND id NOT IN (SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT ?)", .{@as(i64, s.budget.entries)});
        while ((s.int(stored_bytes_sql, .{}) orelse 0) > s.budget.bytes) {
            const id = s.int("SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY kind != 'image', created_at LIMIT 1", .{}) orelse return;
            try s.removeWhere("id = ?", .{id});
        }
    }

    pub fn compactOne(s: Store, arena: std.mem.Allocator, now: f64, compact: Compactor) bool {
        if (s.images == null) return false;
        var hash: [32]u8 = undefined;
        var size: usize = 0;
        {
            const stmt = s.prepare("SELECT hash, stored_bytes FROM entries WHERE image_format = 'png' AND compacted = 0 AND length(hash) = 32 AND created_at < ? LIMIT 1") catch return false;
            defer _ = lite.sqlite3_finalize(stmt);
            bindAll(stmt, .{now - compact_after_days * 86400});
            if (lite.sqlite3_step(stmt) != lite.row) return false;
            @memcpy(&hash, columnBlob(stmt, 0));
            size = @intCast(lite.sqlite3_column_int64(stmt, 1));
        }
        const smaller = if (s.readImage(arena, &hash, "png", size)) |png| compact(arena, png) else null;
        const done = if (smaller) |bytes| blk: {
            s.writeImage(&hash, "avif", bytes) catch break :blk false;
            s.run("UPDATE entries SET image_format = 'avif', stored_bytes = ?, compacted = 1 WHERE hash = ? AND image_format = 'png'", .{ @as(i64, @intCast(bytes.len)), Blob{ .bytes = &hash } }) catch break :blk false;
            s.unlinkImage(&hash, "png");
            break :blk true;
        } else false;
        if (!done) s.run("UPDATE entries SET compacted = 1 WHERE hash = ? AND image_format = 'png'", .{Blob{ .bytes = &hash }}) catch {};
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
        const in_file = cap == .image and s.images != null;
        if (in_file) try s.writeImage(&hash, "png", img.png);
        const sensitive: i64 = @intFromBool(isSensitiveSource(source, source_name));
        try s.run("INSERT INTO entries(kind, text, created_at, source, source_name, width, height, byte_count, hash, thumbnail, png, image_format, stored_bytes, sensitive) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", .{
            @tagName(kind),                                  text,                       now,                                                 source,                                              source_name,
            @as(i64, img.width),                             @as(i64, img.height),       @as(i64, @intCast(img.png.len)),                     Blob{ .bytes = if (cap == .image) &hash else null }, Blob{ .bytes = img.thumbnail },
            Blob{ .bytes = if (in_file) null else img.png }, if (in_file) "png" else "", @as(i64, if (in_file) @intCast(img.png.len) else 0), sensitive,
        });
        try s.keepWithinBudget();
        return true;
    }

    fn repeatsNewest(s: Store, kind: Kind, text: []const u8, hash: ?*const [32]u8) bool {
        const stmt = s.prepare("SELECT kind, text, hash FROM entries ORDER BY pinned_at IS NOT NULL, created_at DESC LIMIT 1") catch return false;
        defer _ = lite.sqlite3_finalize(stmt);
        if (lite.sqlite3_step(stmt) != lite.row) return false;
        if (!std.mem.eql(u8, columnText(stmt, 0), @tagName(kind))) return false;
        if (hash) |h| return std.mem.eql(u8, columnBlob(stmt, 2), h);
        return std.mem.eql(u8, columnText(stmt, 1), text);
    }

    /// Pinned first by pin time, then newest first. An empty query lists
    /// the newest entries; a query matches their text, case-insensitively.
    pub fn list(s: Store, arena: std.mem.Allocator, query: []const u8) ![]Entry {
        const q = std.mem.trim(u8, query, " ");
        const stmt = if (q.len == 0)
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE pinned_at IS NOT NULL OR id IN (SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT " ++ std.fmt.comptimePrint("{d}", .{window}) ++ ")" ++ board_order)
        else
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE instr(lower(text || CASE kind WHEN 'image' THEN ' ' || width || '\u{00D7}' || height ELSE '' END), lower(?)) > 0" ++ board_order ++ " LIMIT " ++ std.fmt.comptimePrint("{d}", .{search_limit}));
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
                .thumbnail = try arena.dupe(u8, columnBlob(stmt, 10)),
                .sensitive = lite.sqlite3_column_int64(stmt, 11) != 0,
            });
        }
        return out.items;
    }

    /// The full image an entry holds, in `arena`'s memory.
    pub fn image(s: Store, arena: std.mem.Allocator, id: i64) ?[]const u8 {
        const stmt = s.prepare("SELECT png, hash, image_format, stored_bytes FROM entries WHERE id = ?") catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{id});
        if (lite.sqlite3_step(stmt) != lite.row) return null;
        const format = columnText(stmt, 2);
        if (format.len > 0) return s.readImage(arena, columnBlob(stmt, 1), format, @intCast(lite.sqlite3_column_int64(stmt, 3)));
        const bytes = columnBlob(stmt, 0);
        return if (bytes.len == 0) null else arena.dupe(u8, bytes) catch null;
    }

    pub fn togglePin(s: Store, id: i64, now: f64) !void {
        try s.run("UPDATE entries SET pinned_at = CASE WHEN pinned_at IS NULL THEN ? ELSE NULL END WHERE id = ?", .{ now, id });
    }

    pub fn delete(s: Store, id: i64) !void {
        try s.removeWhere("id = ?", .{id});
    }

    /// Drops unpinned entries older than `days`; pinned ones stay.
    pub fn prune(s: Store, now: f64, days: u32) !void {
        try s.removeWhere("pinned_at IS NULL AND created_at < ?", .{now - @as(f64, @floatFromInt(days)) * 86400});
        try s.keepWithinBudget();
    }

    pub fn recordQuery(s: Store, scope: QueryScope, raw: []const u8, now: f64) !void {
        const q = std.mem.trim(u8, raw, " \t\r\n");
        if (q.len == 0 or q.len > max_text_bytes) return;
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

/// Seconds since 1970, as the store keeps them.
pub fn wallClock() f64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / std.time.ns_per_s;
}

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (?*anyopaque) f64 = wall,

    pub const wall_clock: Clock = .{};

    pub fn now(c: Clock) f64 {
        return c.read(c.ctx);
    }

    fn wall(_: ?*anyopaque) f64 {
        return wallClock();
    }
};
