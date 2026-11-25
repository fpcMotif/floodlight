//! Clipboard history domain model: entry classification, formatting,
//! capture rules, file metadata, and clock abstraction.
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

pub const QueryScope = enum { search, clipboard };

pub const Entry = struct {
    id: i64,
    kind: Kind,
    /// The text; a file's path; an image's name.
    text: []const u8,
    created_at: f64,
    /// The bundle ID of the app it was copied from.
    source: []const u8 = "",
    source_name: []const u8 = "Clipboard",
    pinned_at: ?f64 = null,
    width: u32 = 0,
    height: u32 = 0,
    byte_count: u64 = 0,
    thumbnail: []const u8 = "",
    /// Decided when the entry was recorded; never parsed again.
    content: Content = .plain,
    sensitive: bool = false,

    pub fn isSensitive(e: Entry) bool {
        return e.sensitive or isSensitiveSource(e.source, e.source_name);
    }

    pub fn linkUrl(e: Entry) ?[]const u8 {
        return switch (e.content) {
            .link => std.mem.trim(u8, e.text, " \t\r\n"),
            else => null,
        };
    }

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
        const when = age(arena, now - e.created_at);
        const source_is_title = std.mem.eql(u8, e.source_name, e.title(arena));
        const head = if (source_is_title) when else std.fmt.allocPrint(arena, "{s} \u{00B7} {s}", .{ e.source_name, when }) catch return "";
        const detail: ?[]const u8 = if (e.filePath()) |p| parentName(p) else if (e.kind == .image) std.fmt.allocPrint(arena, "{d}\u{00D7}{d}", .{ e.width, e.height }) catch null else null;
        const d = detail orelse return head;
        return std.fmt.allocPrint(arena, "{s} \u{00B7} {s}", .{ head, d }) catch head;
    }

    pub fn matches(e: Entry, query: []const u8) bool {
        return matchesFields(e.text, e.kind == .image, e.width, e.height, query);
    }

    pub fn dupe(e: Entry, arena: std.mem.Allocator) !Entry {
        var out = e;
        out.text = try arena.dupe(u8, e.text);
        out.source = try arena.dupe(u8, e.source);
        out.source_name = try arena.dupe(u8, e.source_name);
        out.thumbnail = try arena.dupe(u8, e.thumbnail);
        out.content = switch (e.content) {
            .plain, .color => e.content,
            .link => |d| .{ .link = try arena.dupe(u8, d) },
            .code => |lang| .{ .code = try arena.dupe(u8, lang) },
            .path => |path| .{ .path = try arena.dupe(u8, path) },
        };
        return out;
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

pub fn matchesFields(text: []const u8, is_image: bool, width: u32, height: u32, query: []const u8) bool {
    const q = std.mem.trim(u8, query, " ");
    if (q.len == 0) return true;
    if (!is_image) return containsIgnoreCase(text, q);
    var dim: [64]u8 = undefined;
    const d = std.fmt.bufPrint(&dim, " {d}\u{00D7}{d}", .{ width, height }) catch return containsIgnoreCase(text, q);
    if (text.len + d.len <= 512) {
        var buf: [512]u8 = undefined;
        @memcpy(buf[0..text.len], text);
        @memcpy(buf[text.len..][0..d.len], d);
        return containsIgnoreCase(buf[0 .. text.len + d.len], q);
    }
    return containsIgnoreCase(text, q) or containsIgnoreCase(d, q);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const n0 = std.ascii.toLower(needle[0]);
    const f0: u8 = if (n0 >= 'a' and n0 <= 'z') 0x20 else 0;
    const Vec16 = @Vector(16, u8);
    const fv0: Vec16 = @splat(f0);
    const tv0: Vec16 = @splat(n0);
    if (needle.len == 1) {
        var i: usize = 0;
        while (i + 16 <= haystack.len) : (i += 16) {
            const chunk: Vec16 = haystack[i..][0..16].*;
            if (@reduce(.Or, (chunk | fv0) == tv0)) return true;
        }
        while (i < haystack.len) : (i += 1) {
            if ((haystack[i] | f0) == n0) return true;
        }
        return false;
    }
    const tail_len = needle.len - 1;
    const n_last = std.ascii.toLower(needle[tail_len]);
    const f_last: u8 = if (n_last >= 'a' and n_last <= 'z') 0x20 else 0;
    const fv_last: Vec16 = @splat(f_last);
    const tv_last: Vec16 = @splat(n_last);
    const limit = haystack.len - tail_len;
    var i: usize = 0;
    while (i + 16 <= limit) : (i += 16) {
        const c0: Vec16 = haystack[i..][0..16].*;
        const c_last: Vec16 = haystack[i + tail_len ..][0..16].*;
        const hit = ((c0 | fv0) == tv0) & ((c_last | fv_last) == tv_last);
        var m: u16 = @bitCast(hit);
        while (m != 0) : (m &= m - 1) {
            const idx = i + @ctz(m);
            if (tail_len == 1 or std.ascii.eqlIgnoreCase(haystack[idx + 1 .. idx + tail_len], needle[1..tail_len])) return true;
        }
    }
    while (i < limit) : (i += 1) {
        if ((haystack[i] | f0) == n0 and (haystack[i + tail_len] | f_last) == n_last) {
            if (tail_len == 1 or std.ascii.eqlIgnoreCase(haystack[i + 1 .. i + tail_len], needle[1..tail_len])) return true;
        }
    }
    return false;
}

pub fn isSensitiveSource(source: []const u8, source_name: []const u8) bool {
    for (sensitive_source_markers) |m| {
        if (containsIgnoreCase(source, m) or containsIgnoreCase(source_name, m)) return true;
    }
    return false;
}

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
pub fn storedDetail(buf: *[9]u8, c: Content) []const u8 {
    return switch (c) {
        .plain => "",
        .link, .code, .path => |s| s,
        .color => |rgba| if (rgba.a) |a|
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba.r, rgba.g, rgba.b, a }) catch ""
        else
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgba.r, rgba.g, rgba.b }) catch "",
    };
}

pub fn storedContent(kind: []const u8, detail: []const u8) Content {
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
    if (wrapped) {
        var buf: [512]u8 = undefined;
        var fallback = std.heap.BufferFirstAllocator.init(&buf, std.heap.c_allocator);
        if (std.json.validate(fallback.allocator(), text) catch false) return "JSON";
    }
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
    const clamped = if (std.math.isFinite(seconds)) std.math.clamp(seconds, 0, 1e15) else 0;
    const s: i64 = @intFromFloat(clamped);
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
    const ext = extension(path);
    if (is_dir) return if (std.ascii.eqlIgnoreCase(ext, "app")) "Application" else "Folder";
    // Source Code before Video so `.ts` classifies as TypeScript, not a transport stream.
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

/// The marker Nanospot puts on its own writes, so capture skips them.
pub const own_write_type = "com.nanospot.own-write";
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
/// when it is marked private or Nanospot's own, or past a size cap.
pub fn captures(arena: std.mem.Allocator, board: Pasteboard, source: []const u8) []const Capture {
    for (skipped_types) |ty| if (board.has_type(board.ctx, ty)) return &.{};
    var out: std.ArrayList(Capture) = .empty;
    for (board.file_paths(board.ctx, arena)) |path| {
        const seen = for (out.items) |cap| {
            if (std.mem.eql(u8, cap.file, path)) break true;
        } else false;
        if (path.len > 0 and !seen) out.append(arena, .{ .file = path }) catch {};
    }
    if (out.items.len > max_file_count) return &.{};
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
    const size = std.math.cast(u64, st.size) orelse return null;
    return .{ .dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR, .size = size };
}

/// The first `len` bytes of `path`, in `a`'s memory. Null when it does not
/// open or is shorter: a file cut since its `stat`, or a damaged picture.
pub fn readFile(a: std.mem.Allocator, path: [:0]const u8, len: usize) ?[]const u8 {
    const fd = std.c.open(path, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const buf = a.alloc(u8, len) catch return null;
    var got: usize = 0;
    while (got < len) {
        const n = std.c.read(fd, buf[got..].ptr, len - got);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) {
            a.free(buf);
            return null;
        }
        got += @intCast(n);
    }
    return buf;
}

/// Text past this byte limit is dropped whole.
pub const max_text_bytes = 32_000;
pub const max_file_count = 100;
/// Image representations past this are not read.
pub const max_image_bytes = 15 * 1024 * 1024;
pub const retention_days = 30;
pub const compact_after_days = 7;
pub const search_limit = 200;

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
