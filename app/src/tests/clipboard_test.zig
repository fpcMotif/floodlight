//! Clipboard text classification, SQLite store CRUD, migrations, budgets, compaction, and capture rules tests.
const std = @import("std");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const mac = @import("../mac.zig");
const h = @import("helpers.zig");
const t = std.testing;

const day = h.day;
const picture = h.picture;
const TmpStore = h.TmpStore;
const openMemory = h.openMemory;

// The clipboard board. Expected values are the Swift suite's
// (ClipboardTextContentTests, ClipboardHistoryStoreTests, SearchResultProjectionClipboardTests).

test "copied text is classified as the Swift store classifies it" {
    try t.expectEqualStrings("example.com", clipboard.classify("https://www.example.com/a?b").link);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("rgb(255, 255, 255)", clipboard.rgbDescription(arena.allocator(), clipboard.classify(" #fff ").color));
    try t.expectEqualStrings("rgba(17, 34, 51, 0.50)", clipboard.rgbDescription(arena.allocator(), clipboard.classify("#11223380").color));
    try t.expectEqualStrings("JSON", clipboard.classify("{\"a\": 1}").code);
    try t.expectEqualStrings("Code", clipboard.classify("const x = 1;").code);
    try t.expectEqualStrings("HTML", clipboard.classify("<p>hi</p>").code);
    try t.expectEqualStrings("/Users/me/a.txt", clipboard.classify("file:///Users/me/a.txt").path);
    try t.expectEqualStrings("/Users/me/a.txt", clipboard.classify("/Users/me/a.txt").path);
    try t.expect(clipboard.classify("a\n/b") == .plain);
    try t.expect(clipboard.classify("{not json}") == .plain);
    try t.expect(clipboard.classify("#12345") == .plain);
}

test "a stored entry comes back with its content and the fact it carries; a copied file's is plain" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    _ = try store.add(.{ .text = "/Users/me/a.txt" }, "", "Notes", 2);
    _ = try store.add(.{ .text = "{\"a\": 1}" }, "", "Notes", 3);
    _ = try store.add(.{ .text = " #11223380 " }, "", "Notes", 4);
    _ = try store.add(.{ .text = "https://www.example.com/a?b" }, "", "Notes", 5);
    _ = try store.add(.{ .file = "/tmp/x.pdf" }, "", "Finder", 6);
    const rows = try store.list(arena.allocator(), "");
    try t.expect(rows[0].content == .plain);
    try t.expectEqualStrings("example.com", rows[1].content.link);
    try t.expectEqual(clipboard.Rgba{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x80 }, rows[2].content.color);
    try t.expectEqualStrings("JSON", rows[3].content.code);
    try t.expectEqualStrings("/Users/me/a.txt", rows[4].content.path);
}

// The store's tables as they were before entries carried their classification.
const unclassified_schema =
    \\CREATE TABLE entries(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, created_at REAL NOT NULL,
    \\  source TEXT NOT NULL DEFAULT '', source_name TEXT NOT NULL DEFAULT 'Clipboard', pinned_at REAL,
    \\  width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, byte_count INTEGER NOT NULL DEFAULT 0,
    \\  hash BLOB, thumbnail BLOB, png BLOB);
;

const raw_sqlite = struct {
    extern "c" fn sqlite3_open(path: [*:0]const u8, db: *?*anyopaque) c_int;
    extern "c" fn sqlite3_close(db: *anyopaque) c_int;
    extern "c" fn sqlite3_exec(db: *anyopaque, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*anyopaque) c_int;

    fn run(path: [:0]const u8, sql: [:0]const u8) !void {
        var db: ?*anyopaque = null;
        if (sqlite3_open(path, &db) != 0) return error.Sqlite;
        defer _ = sqlite3_close(db.?);
        if (sqlite3_exec(db.?, sql, null, null, null) != 0) return error.Sqlite;
    }
};

test "rows recorded before classification are classified when the store opens" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    try raw_sqlite.run(ts.db, unclassified_schema ++
        "INSERT INTO entries(kind, text, created_at) VALUES('text', 'https://example.org/x', 100), ('file', '/tmp/a.pdf', 200), ('text', '#abc', 300);");
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try store.list(arena.allocator(), "");
    try t.expectEqual(clipboard.Rgba{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, rows[0].content.color);
    try t.expect(rows[1].content == .plain);
    try t.expectEqualStrings("example.org", rows[2].content.link);
}

test "rows name an entry's age, source and place" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ages = [_]struct { f64, []const u8 }{ .{ 30, "just now" }, .{ 120, "2m" }, .{ 7200, "2h" }, .{ 3 * day, "3d" }, .{ 65 * day, "2mo" }, .{ 400 * day, "1y" } };
    for (ages) |x| try t.expectEqualStrings(x[1], clipboard.age(a, x[0]));

    const file: clipboard.Entry = .{ .id = 1, .kind = .file, .text = "/Users/me/Docs/a.txt", .created_at = 1000, .source_name = "Finder" };
    try t.expectEqualStrings("a.txt", file.title(a));
    try t.expectEqualStrings("Finder \u{00B7} 2m \u{00B7} Docs", file.subtitle(a, 1120));
    const img: clipboard.Entry = .{ .id = 2, .kind = .image, .text = "PNG Image", .created_at = 1000, .width = 3, .height = 4 };
    try t.expectEqualStrings("Clipboard \u{00B7} just now \u{00B7} 3\u{00D7}4", img.subtitle(a, 1001));
    const shot: clipboard.Entry = .{ .id = 5, .kind = .image, .text = "Screenshot", .created_at = 1000, .source_name = "Screenshot", .width = 3, .height = 4 };
    try t.expectEqualStrings("just now \u{00B7} 3\u{00D7}4", shot.subtitle(a, 1001));
    const text: clipboard.Entry = .{ .id = 3, .kind = .text, .text = "a\n\nb\u{2028}c ", .created_at = 0 };
    try t.expectEqualStrings("a b c", text.title(a));
    const blank: clipboard.Entry = .{ .id = 4, .kind = .text, .text = "\n\n", .created_at = 0 };
    try t.expectEqualStrings("(Empty text)", blank.title(a));
}

const long_text: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var bytes: [5 * 10_000]u8 = undefined;
    for (0..10_000) |i| @memcpy(bytes[i * 5 ..][0..5], "word ");
    const out = bytes;
    break :blk &out;
};

test "a long text's row title stops at what one row can show" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const e: clipboard.Entry = .{ .id = 1, .kind = .text, .text = "\n\n" ++ long_text, .created_at = 0 };
    const title = e.title(arena.allocator());
    try t.expect(std.mem.startsWith(u8, title, "word word"));
    try t.expect(title.len < 1024);
}

test "the inspector lays out only the head of a long text, cut between characters" {
    const head = board_mod.shownHead(long_text, 40);
    try t.expect(std.mem.startsWith(u8, long_text, head));
    try t.expectEqual(@as(usize, 40 * board_mod.max_line_bytes), head.len);
    const wide = "\u{4E2D}";
    var cjk: [3 * 4000]u8 = undefined;
    for (0..4000) |i| @memcpy(cjk[i * 3 ..][0..3], wide);
    try t.expect(std.unicode.utf8ValidateSlice(board_mod.shownHead(&cjk, 1)));
    try t.expectEqualStrings("short", board_mod.shownHead("short", 1));
}

test "the store skips a repeat of the newest entry only, pins, finds and prunes" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    const store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try store.add(.{ .text = "alpha" }, "", "Notes", 100));
    try t.expect(try store.add(.{ .text = "beta" }, "", "Notes", 200));
    try t.expect(!try store.add(.{ .text = "beta" }, "", "Notes", 250));
    try t.expect(try store.add(.{ .text = "alpha" }, "", "Notes", 300));
    try t.expect(try store.add(.{ .file = "/tmp/x.pdf" }, "com.apple.finder", "Finder", 400));
    var rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqualStrings("/tmp/x.pdf", rows[0].text);
    try t.expectEqual(clipboard.Kind.file, rows[0].kind);

    // The oldest "alpha" pinned: first, ahead of newer entries.
    try store.togglePin(rows[3].id, 500);
    rows = try store.list(a, "");
    try t.expectEqual(@as(f64, 100), rows[0].created_at);
    try t.expectEqual(@as(?f64, 500), rows[0].pinned_at);

    rows = try store.list(a, "ALP");
    try t.expectEqual(@as(usize, 2), rows.len);

    // Past 30 days only the unpinned "beta" is old enough to go.
    try store.prune(250 + 30 * day, 30);
    rows = try store.list(a, "");
    try t.expectEqualSlices(f64, &.{ 100, 400, 300 }, try createdAt(a, rows));
    try store.delete(rows[1].id);
    try t.expectEqualSlices(f64, &.{ 100, 300 }, try createdAt(a, try store.list(a, "")));
}

fn createdAt(arena: std.mem.Allocator, rows: []const clipboard.Entry) ![]const f64 {
    const out = try arena.alloc(f64, rows.len);
    for (rows, out) |e, *at| at.* = e.created_at;
    return out;
}

fn imageFileName(buf: []u8, png: []const u8, ext: []const u8) []const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png, &hash, .{});
    return std.fmt.bufPrint(buf, "images/{s}.{s}", .{ &std.fmt.bytesToHex(hash, .lower), ext }) catch unreachable;
}

fn hasFile(tmp: *std.testing.TmpDir, sub: []const u8) bool {
    tmp.dir.access(t.io, sub, .{}) catch return false;
    return true;
}

test "full images live beside the database, one file per picture, gone with their last entry" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var name: [128]u8 = undefined;
    const png = "\x89PNG picture one";
    const file = imageFileName(&name, png, "png");

    try t.expect(try store.add(picture(png), "", "Preview", 100));
    try t.expect(try store.add(.{ .text = "between" }, "", "Notes", 200));
    try t.expect(try store.add(picture(png), "", "Preview", 300));
    try t.expect(hasFile(&ts.tmp, file));
    const rows = try store.list(a, "");
    try t.expectEqualStrings(png, store.image(a, rows[0].id).?);
    try t.expectEqualStrings(png, store.image(a, rows[2].id).?);

    try store.delete(rows[0].id);
    try t.expect(hasFile(&ts.tmp, file));
    try store.delete(rows[2].id);
    try t.expect(!hasFile(&ts.tmp, file));
}

test "history keeps within its byte budget, dropping the oldest unpinned pictures first" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    store.budget = .{ .bytes = 3100, .entries = 100 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pngs: [4][1000]u8 = undefined;
    for (&pngs, 0..) |*p, i| @memset(p, @intCast('a' + i));

    _ = try store.add(.{ .text = "oldest text" }, "", "Notes", 10);
    _ = try store.add(picture(&pngs[0]), "", "Preview", 20);
    try store.togglePin((try store.list(a, ""))[0].id, 25);
    _ = try store.add(picture(&pngs[1]), "", "Preview", 30);
    _ = try store.add(picture(&pngs[2]), "", "Preview", 40);
    _ = try store.add(picture(&pngs[3]), "", "Preview", 50);

    const rows = try store.list(a, "");
    var kept: [8]f64 = undefined;
    for (rows, 0..) |e, i| kept[i] = e.created_at;
    try t.expectEqualSlices(f64, &.{ 20, 50, 40, 10 }, kept[0..rows.len]);
    var name: [128]u8 = undefined;
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, &pngs[1], "png")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, &pngs[0], "png")));
}

test "history keeps at most its entry count, pinned ones aside" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    store.budget = .{ .entries = 3 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try store.add(.{ .text = "pinned" }, "", "Notes", 1);
    try store.togglePin((try store.list(a, ""))[0].id, 2);
    for (0..5) |i| _ = try store.add(.{ .text = (try std.fmt.allocPrint(a, "t{d}", .{i})) }, "", "Notes", @floatFromInt(10 + i));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqualStrings("pinned", rows[0].text);
    try t.expectEqualStrings("t4", rows[1].text);
    try t.expectEqualStrings("t2", rows[3].text);
}

test "an older store's pictures move out to files and the database gives the space back" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    const big = try t.allocator.alloc(u8, 2 << 20);
    defer t.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const sql = try std.fmt.allocPrintSentinel(arena.allocator(), unclassified_schema ++
            "INSERT INTO entries(kind, text, created_at, width, height, byte_count, thumbnail, png) VALUES('image', 'PNG Image', 100, 10, 10, {d}, X'00', X'{x}');", .{ big.len, big }, 0);
        try raw_sqlite.run(ts.db, sql);
    }
    const before = ts.size("clipboard.sqlite3") + ts.size("clipboard.sqlite3-wal");
    try t.expect(before > big.len);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    const rows = try store.list(arena.allocator(), "");
    try t.expectEqualSlices(u8, big, store.image(arena.allocator(), rows[0].id).?);
    var name: [128]u8 = undefined;
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, big, "png")));
    try t.expect(ts.size("clipboard.sqlite3") + ts.size("clipboard.sqlite3-wal") < big.len / 4);
}

fn halve(arena: std.mem.Allocator, png: []const u8) ?[]const u8 {
    return arena.dupe(u8, png[0 .. png.len / 2]) catch null;
}

fn keepAll(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
    return null;
}

test "a week-old picture is stored once as its smaller copy, and the original goes" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG an old screenshot";
    const kept = "\x89PNG see-through";
    _ = try store.add(picture(png), "", "Preview", 0);
    _ = try store.add(picture(kept), "", "Preview", 1);
    var name: [128]u8 = undefined;

    try t.expect(!store.compactOne(a, 6 * day, halve));
    try t.expect(store.compactOne(a, 8 * day, keepAll));
    try t.expect(store.compactOne(a, 8 * day, halve));
    try t.expect(!store.compactOne(a, 8 * day, halve));

    const rows = try store.list(a, "");
    try t.expectEqualStrings(kept, store.image(a, rows[0].id).?);
    try t.expectEqualStrings(png[0 .. png.len / 2], store.image(a, rows[1].id).?);
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "png")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, png, "avif")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, kept, "png")));
}

test "files a crash left behind are cleared when the store opens" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var name: [128]u8 = undefined;
    const png = "\x89PNG kept";
    {
        var store = try clipboard.Store.open(ts.db, ts.images);
        defer store.close();
        _ = try store.add(picture(png), "", "Preview", 100);
    }
    const stray = imageFileName(&name, "never stored", "png");
    try ts.tmp.dir.writeFile(t.io, .{ .sub_path = stray, .data = "x" });
    try ts.tmp.dir.writeFile(t.io, .{ .sub_path = "images/half-written.tmp", .data = "x" });

    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    try t.expect(!hasFile(&ts.tmp, stray));
    try t.expect(!hasFile(&ts.tmp, "images/half-written.tmp"));
    var name2: [128]u8 = undefined;
    try t.expect(hasFile(&ts.tmp, imageFileName(&name2, png, "png")));
}

/// A pasteboard holding what a test puts on it, counting the picture reads.
const FakePasteboard = struct {
    types: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    picture: ?clipboard.PastedImage = null,
    picture_bytes: usize = 0,
    string: []const u8 = "",
    picture_reads: usize = 0,

    fn pasteboard(f: *FakePasteboard) clipboard.Pasteboard {
        return .{ .ctx = f, .has_type = hasType, .file_paths = filePaths, .image_byte_count = imageByteCount, .image = image, .text = text };
    }

    fn of(ctx: ?*anyopaque) *FakePasteboard {
        return @ptrCast(@alignCast(ctx));
    }

    fn hasType(ctx: ?*anyopaque, ty: []const u8) bool {
        for (of(ctx).types) |x| if (std.mem.eql(u8, x, ty)) return true;
        return false;
    }

    fn filePaths(ctx: ?*anyopaque, _: std.mem.Allocator) []const []const u8 {
        return of(ctx).files;
    }

    fn imageByteCount(ctx: ?*anyopaque) ?usize {
        const f = of(ctx);
        return if (f.picture != null) f.picture_bytes else null;
    }

    fn image(ctx: ?*anyopaque, _: std.mem.Allocator) ?clipboard.PastedImage {
        const f = of(ctx);
        f.picture_reads += 1;
        return f.picture;
    }

    fn text(ctx: ?*anyopaque, _: std.mem.Allocator) []const u8 {
        return of(ctx).string;
    }
};

const pasted_png: clipboard.PastedImage = .{ .png = "\x89PNG pasted", .thumbnail = "thumb", .width = 4, .height = 3, .format = .png };
const notes_app: clipboard.App = .{ .bundle_id = "com.apple.Notes", .name = "Notes" };

test "a copy marked private, transient, auto-generated or Floodlight's own is not recorded" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const marked = [_][]const u8{ "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.apple.is-sensitive", clipboard.own_write_type };
    for (marked) |ty| {
        var fake: FakePasteboard = .{ .types = &.{ty}, .string = "secret" };
        try t.expect(!try store.capture(a, fake.pasteboard(), notes_app, 1));
    }
    try t.expectEqual(@as(usize, 0), (try store.list(a, "")).len);
    var plain: FakePasteboard = .{ .types = &.{"public.utf8-plain-text"}, .string = "kept" };
    try t.expect(try store.capture(a, plain.pasteboard(), notes_app, 2));
    const rows = try store.list(a, "");
    try t.expectEqualStrings("kept", rows[0].text);
    try t.expectEqualStrings("Notes", rows[0].source_name);
}

test "copied files win over a picture and text, each file once, and the picture is never read" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakePasteboard = .{ .files = &.{ "/a/x.pdf", "/a/y.pdf", "/a/x.pdf" }, .picture = pasted_png, .picture_bytes = 10, .string = "x.pdf" };
    try t.expect(try store.capture(a, fake.pasteboard(), .{ .bundle_id = "com.apple.finder", .name = "Finder" }, 1));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 2), rows.len);
    for (rows) |e| try t.expectEqual(clipboard.Kind.file, e.kind);
    // Both are recorded at the same time, so the list may give either first.
    var paths = [_][]const u8{ rows[0].text, rows[1].text };
    std.mem.sort([]const u8, &paths, {}, lessThan);
    try t.expectEqualStrings("/a/x.pdf", paths[0]);
    try t.expectEqualStrings("/a/y.pdf", paths[1]);
    try t.expectEqual(@as(usize, 0), fake.picture_reads);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "a picture past the size cap falls back to the copy's text" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakePasteboard = .{ .picture = pasted_png, .picture_bytes = clipboard.max_image_bytes + 1, .string = "caption" };
    try t.expect(try store.capture(a, fake.pasteboard(), notes_app, 1));
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("caption", rows[0].text);
    try t.expectEqual(@as(usize, 0), fake.picture_reads);
}

test "a screenshot is named for its source, other pictures for their format" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var shot: FakePasteboard = .{ .picture = pasted_png, .picture_bytes = 10 };
    _ = try store.capture(a, shot.pasteboard(), .{ .bundle_id = "com.apple.screencaptureui", .name = "Screenshot" }, 1);
    var tiff_png = pasted_png;
    tiff_png.png = "\x89PNG from tiff";
    tiff_png.format = .tiff;
    var tiff: FakePasteboard = .{ .picture = tiff_png, .picture_bytes = 10 };
    _ = try store.capture(a, tiff.pasteboard(), notes_app, 2);
    var other_png = pasted_png;
    other_png.png = "\x89PNG another";
    var png: FakePasteboard = .{ .picture = other_png, .picture_bytes = 10 };
    _ = try store.capture(a, png.pasteboard(), notes_app, 3);
    const rows = try store.list(a, "");
    try t.expectEqualStrings("PNG Image", rows[0].text);
    try t.expectEqualStrings("TIFF Image", rows[1].text);
    try t.expectEqualStrings("Screenshot", rows[2].text);
    try t.expectEqual(@as(u32, 4), rows[2].width);
    try t.expectEqualStrings("\x89PNG pasted", store.image(a, rows[2].id).?);
}

test "empty text and text past the cap are not recorded" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const past_cap = try a.alloc(u8, clipboard.max_text_bytes + 1);
    @memset(past_cap, 'x');
    var empty: FakePasteboard = .{};
    try t.expect(!try store.capture(a, empty.pasteboard(), notes_app, 1));
    var long: FakePasteboard = .{ .string = past_cap };
    try t.expect(!try store.capture(a, long.pasteboard(), notes_app, 2));
    var fits: FakePasteboard = .{ .string = past_cap[0..clipboard.max_text_bytes] };
    try t.expect(try store.capture(a, fits.pasteboard(), notes_app, 3));
    try t.expectEqual(@as(usize, 1), (try store.list(a, "")).len);
}

fn crc(kind: []const u8, data: []const u8) u32 {
    var h_crc = std.hash.Crc32.init();
    h_crc.update(kind);
    h_crc.update(data);
    return h_crc.final();
}

fn uncompressedGradientPng(a: std.mem.Allocator, side: u32, see_through: bool) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..side) |y| {
        try raw.append(a, 0);
        for (0..side) |x| try raw.appendSlice(a, &.{ @truncate(x * 255 / side), @truncate(y * 255 / side), @truncate((x + y) * 127 / side), if (see_through and x == 0 and y == 0) 0 else 255 });
    }
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(a, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        const last = n == rest.len;
        try z.append(a, @intFromBool(last));
        try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], side, .big);
    std.mem.writeInt(u32, ihdr[4..8], side, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |chunk| {
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(chunk[1].len))));
        try out.appendSlice(a, chunk[0]);
        try out.appendSlice(a, chunk[1]);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, crc(chunk[0], chunk[1]))));
    }
    return out.items;
}

test "an opaque picture compacts to a far smaller AVIF that pastes back as PNG; a see-through one is kept" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opaque_png = try uncompressedGradientPng(a, 256, false);
    const small = mac.compactImage(a, opaque_png).?;
    try t.expectEqualStrings("ftypavif", small[4..12]);
    try t.expect(small.len * 5 < opaque_png.len);
    const back = mac.pngBytes(a, small).?;
    try t.expect(std.mem.startsWith(u8, back, "\x89PNG"));
    try t.expect(mac.pngBytes(a, opaque_png).?.ptr == opaque_png.ptr);

    try t.expect(mac.compactImage(a, try uncompressedGradientPng(a, 256, true)) == null);
}

test "a copied app is an Application, and any other folder a Folder" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Application", clipboard.fileType(a, "/System/Applications/Calendar.app", true));
    try t.expectEqualStrings("Folder", clipboard.fileType(a, "/Users/me/Projects", true));
}

test "the list carries no thumbnails" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    _ = try store.add(picture("png-0"), "", "Preview", 10);
    _ = try store.add(picture("png-1"), "", "Preview", 20);
    _ = try store.add(picture("png-2"), "", "Preview", 30);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 3), rows.len);
    for (rows) |r| {
        try t.expectEqual(@as(usize, 0), r.thumbnail.len);
        try t.expectEqualStrings("thumb", store.thumbnail(a, r.id));
    }
}

test "in-memory matching agrees with the store" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.add(.{ .text = "Meet at noon" }, "x", "Notes", 10);
    _ = try store.add(.{ .text = "SOME NOTE" }, "x", "Notes", 11);
    _ = try store.add(.{ .text = "\u{00C9}lan vital" }, "x", "Notes", 12);
    _ = try store.add(.{ .text = "caf\u{00E9} menu" }, "x", "Notes", 13);
    _ = try store.add(.{ .file = "/tmp/meeting-notes.txt" }, "x", "Finder", 14);
    _ = try store.add(.{ .image = .{ .name = "Screen Shot", .png = "pngdata", .thumbnail = "t", .width = 640, .height = 480 } }, "x", "Screenshot", 15);
    var text_buf: [64]u8 = undefined;
    for (0..24) |i| {
        const s = try std.fmt.bufPrint(&text_buf, "Sample entry {d}", .{i});
        _ = try store.add(.{ .text = s }, "x", "Notes", @floatFromInt(20 + i));
    }

    const all = try store.list(a, "");
    try t.expectEqual(@as(usize, 30), all.len);

    const queries = [_][]const u8{ "me", "ME", "\u{00E9}", "640", "640\u{00D7}480", "x48", "tmp" };
    for (queries) |q| {
        const got = try store.list(a, q);
        var match_count: usize = 0;
        for (all) |e| {
            const m = e.matches(q);
            if (m) match_count += 1;
            const in_store = for (got) |g| {
                if (g.id == e.id) break true;
            } else false;
            try t.expectEqual(in_store, m);
        }
        try t.expectEqual(got.len, match_count);
    }
}

test "a repeat of the newest unpinned entry is not stored again" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    try t.expect(try store.add(.{ .text = "old" }, "", "Notes", 10));
    try t.expect(try store.add(.{ .text = "a" }, "", "Notes", 20));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try store.list(arena.allocator(), "");
    try store.togglePin(rows[1].id, 25);
    try t.expect(!try store.add(.{ .text = "a" }, "", "Notes", 30));
}

test "with only pinned entries, a repeat of the newest pinned one is not stored" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    try t.expect(try store.add(.{ .text = "a" }, "", "Notes", 10));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try store.list(arena.allocator(), "");
    try store.togglePin(rows[0].id, 20);
    try t.expect(!try store.add(.{ .text = "a" }, "", "Notes", 30));
}

test "the entry count stays at the budget" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    store.budget = .{ .entries = 5 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..8) |i| {
        const txt = try std.fmt.allocPrint(a, "item-{d}", .{i});
        _ = try store.add(.{ .text = txt }, "", "Notes", @floatFromInt(10 + i));
    }
    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 5), rows.len);
    try t.expectEqualStrings("item-7", rows[0].text);
    try t.expectEqualStrings("item-3", rows[4].text);
}

test "the byte budget evicts past sixteen rows and corrects shared picture estimates" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    store.budget = .{ .bytes = 500, .entries = 100 };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pad: [100]u8 = undefined;
    for (0..22) |i| {
        @memset(&pad, @intCast('a' + i % 26));
        const txt = try std.fmt.allocPrint(a, "{d:0>2}-{s}", .{ i, pad[0..97] });
        _ = try store.add(.{ .text = txt }, "", "Notes", @floatFromInt(10 + i));
    }
    const rows = try store.list(a, "");
    try t.expect(rows.len <= 5);
    try t.expectEqualStrings("21-", rows[0].text[0..3]);

    var ts2 = try TmpStore.init();
    defer ts2.deinit();
    var store2 = try openMemory(&ts2);
    defer store2.close();
    store2.budget = .{ .bytes = 1200, .entries = 100 };
    var small: [140]u8 = undefined;
    @memset(&small, 's');
    var big: [1000]u8 = undefined;
    @memset(&big, 'p');
    _ = try store2.add(picture(&big), "", "Preview", 10);
    _ = try store2.add(.{ .text = &small }, "", "Notes", 20);
    _ = try store2.add(picture(&big), "", "Preview", 30);
    var huge: [1040]u8 = undefined;
    @memset(&huge, 'q');
    _ = try store2.add(.{ .text = &huge }, "", "Notes", 40);
    const rows2 = try store2.list(a, "");
    try t.expectEqual(@as(usize, 2), rows2.len);
    try t.expectEqualStrings(&huge, rows2[0].text);
    try t.expectEqualStrings(&small, rows2[1].text);
}

test "a shared picture file survives while one entry still uses it" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    store.budget = .{ .entries = 2 };
    const png = "\x89PNG shared image bytes";
    var name: [128]u8 = undefined;
    const file = imageFileName(&name, png, "png");
    _ = try store.add(picture(png), "", "Preview", 10);
    _ = try store.add(.{ .text = "middle" }, "", "Notes", 20);
    _ = try store.add(picture(png), "", "Preview", 30);
    try t.expect(hasFile(&ts.tmp, file));
}

test "a failed capture stores nothing" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    try raw_sqlite.run(ts.db, "CREATE TRIGGER fail_boom BEFORE INSERT ON entries WHEN NEW.text = '/tmp/boom' BEGIN SELECT RAISE(ABORT, 'boom'); END;");
    var fake: FakePasteboard = .{ .files = &.{ "/tmp/a", "/tmp/b", "/tmp/boom" } };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.ClipboardStore, store.capture(arena.allocator(), fake.pasteboard(), notes_app, 10));
    try t.expectEqual(@as(usize, 0), (try store.list(arena.allocator(), "")).len);
}

test "recompression in three parts gives the same result as in one" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG three part screenshot";
    _ = try store.add(picture(png), "", "Preview", 0);

    try t.expect(store.nextCompaction(6 * day) == null);
    const job = store.nextCompaction(8 * day) orelse return error.ExpectedCompaction;
    const avif_bytes = clipboard.recompress(store.images, a, job, halve);
    store.finishCompaction(job, avif_bytes);

    try t.expect(store.nextCompaction(8 * day) == null);
    const rows = try store.list(a, "");
    try t.expectEqualStrings(png[0 .. png.len / 2], store.image(a, rows[0].id).?);
    var name: [128]u8 = undefined;
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "png")));
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, png, "avif")));
}

test "an entry deleted during recompression leaves no file behind" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG deleted while compacting";
    _ = try store.add(picture(png), "", "Preview", 0);
    const id = (try store.list(a, ""))[0].id;

    const job = store.nextCompaction(8 * day) orelse return error.ExpectedCompaction;
    try store.delete(id);
    const avif_bytes = clipboard.recompress(store.images, a, job, halve);
    store.finishCompaction(job, avif_bytes);

    var name: [128]u8 = undefined;
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "png")));
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "avif")));
}

test "a picture that does not shrink is marked and kept" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try clipboard.Store.open(ts.db, ts.images);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG kept as png";
    _ = try store.add(picture(png), "", "Preview", 0);

    const job = store.nextCompaction(8 * day) orelse return error.ExpectedCompaction;
    const avif_bytes = clipboard.recompress(store.images, a, job, keepAll);
    try t.expect(avif_bytes == null);
    store.finishCompaction(job, avif_bytes);

    try t.expect(store.nextCompaction(8 * day) == null);
    const rows = try store.list(a, "");
    try t.expectEqualStrings(png, store.image(a, rows[0].id).?);
    var name: [128]u8 = undefined;
    try t.expect(hasFile(&ts.tmp, imageFileName(&name, png, "png")));
    try t.expect(!hasFile(&ts.tmp, imageFileName(&name, png, "avif")));
}

test "a copy of more files than the cap records nothing and keeps the history it found" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.add(.{ .text = "kept" }, "", "Notes", 1);
    const paths = try a.alloc([]const u8, clipboard.max_file_count + 1);
    for (paths, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(a, "/bulk/{d}.txt", .{i});
    }
    var fake: FakePasteboard = .{ .files = paths, .string = "bulk fallback" };
    try t.expect(!try store.capture(a, fake.pasteboard(), .{ .bundle_id = "com.apple.finder", .name = "Finder" }, 2));

    const rows = try store.list(a, "");
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("kept", rows[0].text);
}

test "a copy of exactly the cap records every file" {
    var ts = try TmpStore.init();
    defer ts.deinit();
    var store = try openMemory(&ts);
    defer store.close();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paths = try a.alloc([]const u8, clipboard.max_file_count);
    for (paths, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(a, "/bulk/{d}.txt", .{i});
    }
    var fake: FakePasteboard = .{ .files = paths };
    try t.expect(try store.capture(a, fake.pasteboard(), .{ .bundle_id = "com.apple.finder", .name = "Finder" }, 2));

    const rows = try store.list(a, "");
    try t.expectEqual(clipboard.max_file_count, rows.len);
}
