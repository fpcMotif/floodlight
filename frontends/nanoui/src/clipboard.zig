//! Clipboard history: what was copied, classified as the Swift board does,
//! kept in SQLite beside the file index.
const std = @import("std");

pub const Kind = enum { text, file, image };

/// What a text entry holds, decided from its characters alone, with the
/// one fact its kind carries: a link's domain, a colour, a code language,
/// a path without `file://`. Files and images are `.plain`.
pub const Content = union(enum) {
    plain,
    link: []const u8,
    color: Rgba,
    code: []const u8,
    path: []const u8,
};

pub const Entry = struct {
    id: i64,
    kind: Kind,
    /// The text; a file's path; an image's name.
    text: []const u8,
    created_at: f64,
    source_name: []const u8 = "Clipboard",
    pinned_at: ?f64 = null,
    width: u32 = 0,
    height: u32 = 0,
    byte_count: u64 = 0,
    thumbnail: []const u8 = "",
    /// Decided when the entry was recorded; never parsed again.
    content: Content = .plain,

    /// A file, or text that names one.
    pub fn filePath(e: Entry) ?[]const u8 {
        if (e.kind == .file) return e.text;
        return switch (e.content) {
            .path => |p| p,
            else => null,
        };
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

/// The content of copied text. Its slices point into `text`.
pub fn classify(text: []const u8) Content {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfAny(u8, text, "\r\n") == null and
        (std.mem.startsWith(u8, text, "file://") or std.mem.startsWith(u8, text, "~/") or std.mem.startsWith(u8, text, "/"))) return .{ .path = pathOf(text) };
    if (domain(t)) |d| return .{ .link = d };
    if (parseColor(t)) |c| return .{ .color = c };
    if (codeLanguage(t)) |lang| return .{ .code = lang };
    return .plain;
}

/// The column form of a content's fact; a colour as `#RRGGBB[AA]`.
fn storedDetail(buf: *[9]u8, c: Content) []const u8 {
    return switch (c) {
        .plain => "",
        .link, .code, .path => |s| s,
        .color => |rgba| if (rgba.a) |a|
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba.r, rgba.g, rgba.b, a }) catch ""
        else
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgba.r, rgba.g, rgba.b }) catch "",
    };
}

fn storedContent(kind: []const u8, detail: []const u8) Content {
    const tag = std.meta.stringToEnum(std.meta.Tag(Content), kind) orelse return .plain;
    return switch (tag) {
        .plain => .plain,
        .link => .{ .link = detail },
        .code => .{ .code = detail },
        .path => .{ .path = detail },
        .color => if (parseColor(detail)) |c| .{ .color = c } else .plain,
    };
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
fn domain(text: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, text, "https://")) text["https://".len..] else if (std.mem.startsWith(u8, text, "http://")) text["http://".len..] else return null;
    if (std.mem.indexOfAny(u8, text, " \t\r\n") != null) return null;
    var host = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (host.len == 0) return null;
    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

pub const Rgba = struct { r: u8, g: u8, b: u8, a: ?u8 = null };

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
fn parseColor(text: []const u8) ?Rgba {
    if (text.len < 4 or text[0] != '#') return null;
    const hex = text[1..];
    for (hex) |ch| if (!std.ascii.isHex(ch)) return null;
    const byte = struct {
        fn at(h: []const u8, i: usize) u8 {
            return std.fmt.parseInt(u8, h[i .. i + 2], 16) catch unreachable;
        }
        fn nibble(h: []const u8, i: usize) u8 {
            return (std.fmt.charToDigit(h[i], 16) catch unreachable) * 17;
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

fn codeLanguage(text: []const u8) ?[]const u8 {
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
    // Source Code before Video: `.ts` is TypeScript here, as in the Swift inspector.
    const table = [_]struct { []const u8, []const []const u8 }{
        .{ "Source Code", &.{ "swift", "rs", "ts", "js", "py", "go", "c", "cpp", "h", "sh" } },
        .{ "Video", &video_extensions },
        .{ "Image", &board_image_extensions },
        .{ "JSON", &.{"json"} },
        .{ "Markdown", &.{ "md", "markdown", "mdown", "mkdn" } },
        .{ "Plain Text", &.{ "txt", "text" } },
        .{ "Archive", &.{ "zip", "tar", "gz", "dmg" } },
    };
    for (table) |t| if (inSet(ext, t[1])) return t[0];
    return if (ext.len == 0) "File" else std.ascii.allocUpperString(arena, ext) catch ext;
}

/// A picture's: what the search panel's Images filter keeps.
pub const image_extensions = [_][]const u8{ "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "avif", "svg" };
/// What the board shows and previews as a picture: icons too, which search
/// does not count as images.
pub const board_image_extensions = image_extensions ++ [_][]const u8{ "ico", "icns" };
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

pub const TextCounts = struct { characters: usize, words: usize, lines: usize };

pub fn counts(text: []const u8) TextCounts {
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

/// The marker Floodlight puts on its own writes, so capture skips them.
pub const own_write_type = "com.floodlight.own-write";
/// A copy carrying any of these is not recorded.
const skipped_types = [_][]const u8{ own_write_type, "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.apple.is-sensitive" };

/// A picture on the pasteboard, decoded, as PNG whatever it came as.
pub const PastedImage = struct {
    png: []const u8,
    thumbnail: []const u8,
    width: u32,
    height: u32,
    format: enum { png, tiff },
};

/// The pasteboard as capture reads it, one representation at a time, so a
/// picture is never decoded when files win. Results live in the arena given.
pub const Pasteboard = struct {
    ctx: ?*anyopaque,
    has_type: *const fn (?*anyopaque, []const u8) bool,
    /// File URLs' paths, in pasteboard order.
    file_paths: *const fn (?*anyopaque, std.mem.Allocator) []const []const u8,
    /// The picture's bytes as stored on the pasteboard; null with none.
    image_byte_count: *const fn (?*anyopaque) ?usize,
    /// Null when the picture does not decode.
    image: *const fn (?*anyopaque, std.mem.Allocator) ?PastedImage,
    text: *const fn (?*anyopaque, std.mem.Allocator) []const u8,
};

/// The app a copy came from.
pub const App = struct { bundle_id: []const u8, name: []const u8 };

/// What a copy becomes: its files, else its picture, else its text; nothing
/// when it is marked private or Floodlight's own, or past a size cap.
fn captures(arena: std.mem.Allocator, board: Pasteboard, source: []const u8) []const Capture {
    for (skipped_types) |ty| if (board.has_type(board.ctx, ty)) return &.{};
    var out: std.ArrayList(Capture) = .empty;
    for (board.file_paths(board.ctx, arena)) |path| {
        const seen = for (out.items) |cap| {
            if (std.mem.eql(u8, cap.file, path)) break true;
        } else false;
        if (path.len > 0 and !seen) out.append(arena, .{ .file = path }) catch {};
    }
    if (out.items.len > 0) return out.items;
    if (board.image_byte_count(board.ctx)) |n| if (n <= max_image_bytes) if (board.image(board.ctx, arena)) |img| {
        const screenshot = std.mem.eql(u8, source, "com.apple.screencapture") or std.mem.eql(u8, source, "com.apple.screencaptureui");
        const name = if (screenshot) "Screenshot" else switch (img.format) {
            .png => "PNG Image",
            .tiff => "TIFF Image",
        };
        return arena.dupe(Capture, &.{.{ .image = .{ .name = name, .png = img.png, .thumbnail = img.thumbnail, .width = img.width, .height = img.height } }}) catch &.{};
    };
    const text = board.text(board.ctx, arena);
    if (text.len == 0 or text.len > max_text_bytes) return &.{};
    return arena.dupe(Capture, &.{.{ .text = text }}) catch &.{};
}

/// What the inspector knows of an entry without reading its payload.
pub const Facts = struct {
    /// A file that exists, or an image with bytes to show.
    previewable: bool = false,
    is_dir: bool = false,
    /// A non-empty file's size.
    size: ?u64 = null,
};

/// One `stat` for a path; nothing for text or an image.
pub fn facts(e: Entry) Facts {
    if (e.kind == .image) return .{ .previewable = e.thumbnail.len > 0 or e.byte_count > 0 };
    const path = e.filePath() orelse return .{};
    const st = stat(path) orelse return .{};
    return .{ .previewable = true, .is_dir = st.dir, .size = if (!st.dir and st.size > 0) st.size else null };
}

/// What the inspector previews: a full picture, or a readable file's head.
pub const Payload = union(enum) {
    none,
    picture: []const u8,
    text: []const u8,
};

pub const text_preview_bytes = 16 * 1024;

const Stat = struct { dir: bool, size: u64 };

fn stat(path: []const u8) ?Stat {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: std.c.Stat = undefined;
    if (std.c.stat(buf[0..path.len :0], &st) != 0) return null;
    return .{ .dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR, .size = @intCast(st.size) };
}

/// The first `len` bytes of `path`, in `a`'s memory. Null when it does not
/// open or is shorter: a file cut since its `stat`, or a damaged picture.
fn readFile(a: std.mem.Allocator, path: [:0]const u8, len: usize) ?[]const u8 {
    const fd = std.c.open(path, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const buf = a.alloc(u8, len) catch return null;
    var got: usize = 0;
    while (got < len) {
        const n = std.c.read(fd, buf[got..].ptr, len - got);
        if (n <= 0) return null;
        got += @intCast(n);
    }
    return buf;
}

/// Text past this is dropped whole, as the Swift store does.
pub const max_text_bytes = 32_000;
/// Image representations past this are not read.
pub const max_image_bytes = 15 * 1024 * 1024;
pub const retention_days = 30;
pub const compact_after_days = 7;
pub const Budget = struct { bytes: u64 = 150 * 1024 * 1024, entries: u32 = 5000 };
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
    \\  content_kind TEXT,
    \\  content_detail TEXT);
    \\CREATE INDEX IF NOT EXISTS entries_created ON entries(created_at DESC);
    \\CREATE INDEX IF NOT EXISTS entries_pinned ON entries(pinned_at);
    \\CREATE INDEX IF NOT EXISTS entries_hash ON entries(hash);
    \\CREATE TEMP TABLE IF NOT EXISTS released(hash BLOB);
;

const columns_added_since_first_schema = [_][:0]const u8{
    "ALTER TABLE entries ADD COLUMN image_format TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE entries ADD COLUMN stored_bytes INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN compacted INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE entries ADD COLUMN content_kind TEXT",
    "ALTER TABLE entries ADD COLUMN content_detail TEXT",
};

const stored_bytes_sql =
    "SELECT coalesce((SELECT sum(length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + coalesce(length(png), 0)) FROM entries), 0)" ++
    " + coalesce((SELECT sum(b) FROM (SELECT max(stored_bytes) AS b FROM entries WHERE image_format != '' GROUP BY hash, image_format)), 0)";

const columns = "id, kind, text, created_at, source_name, pinned_at, width, height, byte_count, thumbnail, content_kind, content_detail";
const board_order = " ORDER BY pinned_at IS NULL, pinned_at, created_at DESC";

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
            const c = classify(r.text);
            try s.run("UPDATE entries SET content_kind = ?, content_detail = ? WHERE id = ?", .{ @tagName(c), storedDetail(&buf, c), r.id });
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

    fn imagePath(s: Store, buf: *[std.posix.PATH_MAX]u8, hash: []const u8, format: []const u8) ?[:0]const u8 {
        if (hash.len != 32) return null;
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}.{s}", .{ s.images, &std.fmt.bytesToHex(hash[0..32].*, .lower), format }, 0) catch null;
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
        return readFile(arena, s.imagePath(&buf, hash, format) orelse return null, size);
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
        if (cap == .image) try s.writeImage(&hash, "png", img.png);
        const content: Content = if (cap == .text) classify(text) else .plain;
        var detail_buf: [9]u8 = undefined;
        try s.run("INSERT INTO entries(kind, text, created_at, source, source_name, width, height, byte_count, hash, thumbnail, image_format, stored_bytes, content_kind, content_detail) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", .{
            @tagName(kind),                   text,                            now,                             source,                                              source_name,
            @as(i64, img.width),              @as(i64, img.height),            @as(i64, @intCast(img.png.len)), Blob{ .bytes = if (cap == .image) &hash else null }, Blob{ .bytes = img.thumbnail },
            if (cap == .image) "png" else "", @as(i64, @intCast(img.png.len)), @tagName(content),               storedDetail(&detail_buf, content),
        });
        try s.keepWithinBudget();
        return true;
    }

    /// Records what `board` holds, as copied from `app`. True when any of it
    /// was stored; a repeat of the newest entry is not.
    pub fn capture(s: Store, arena: std.mem.Allocator, board: Pasteboard, app: App, now: f64) !bool {
        var stored = false;
        for (captures(arena, board, app.bundle_id)) |cap| stored = (try s.add(cap, app.bundle_id, app.name, now)) or stored;
        return stored;
    }

    /// The selection's preview, read once its facts say there is one.
    pub fn load(s: Store, arena: std.mem.Allocator, e: Entry, f: Facts) Payload {
        if (e.kind == .image) return if (s.image(arena, e.id)) |bytes| .{ .picture = bytes } else .none;
        const path = e.filePath() orelse return .none;
        const size = f.size orelse return .none;
        const ext = extension(path);
        const z = arena.dupeSentinel(u8, path, 0) catch return .none;
        if (inSet(ext, &board_image_extensions) and size <= max_image_bytes) {
            if (readFile(arena, z, @intCast(size))) |bytes| return .{ .picture = bytes };
        } else if (inSet(ext, &text_extensions)) {
            if (readFile(arena, z, @intCast(@min(size, text_preview_bytes)))) |bytes| return .{ .text = bytes };
        }
        return .none;
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
                .source_name = try arena.dupe(u8, columnText(stmt, 4)),
                .pinned_at = if (lite.sqlite3_column_type(stmt, 5) == lite.null_type) null else lite.sqlite3_column_double(stmt, 5),
                .width = @intCast(lite.sqlite3_column_int64(stmt, 6)),
                .height = @intCast(lite.sqlite3_column_int64(stmt, 7)),
                .byte_count = @intCast(lite.sqlite3_column_int64(stmt, 8)),
                .thumbnail = try arena.dupe(u8, columnBlob(stmt, 9)),
                .content = storedContent(columnText(stmt, 10), try arena.dupe(u8, columnText(stmt, 11))),
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
