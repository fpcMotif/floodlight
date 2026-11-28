//! Pasteboard read/write, image decoding and AVIF compaction, Quick Look preview, and date formatting.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const clipboard = @import("../clipboard.zig");

pub extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Object;
pub extern "c" fn CFRelease(obj: *anyopaque) void;

pub fn fileURL(path: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

fn generalPasteboard() objc.Object {
    return objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

pub fn beginWrite() objc.Object {
    const board = generalPasteboard();
    _ = objc.msg(objc.NSInteger, board, "clearContents", .{});
    return board;
}

/// History skips what Nanospot wrote itself.
pub fn markOwnWrite(board: objc.Object) void {
    _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString("1"), objc.nsString(clipboard.own_write_type) });
}

/// Puts a clipboard entry back on the pasteboard: text, a file, or PNG.
pub fn writeClipboard(kind: clipboard.Kind, text: []const u8, png: ?[]const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const board = beginWrite();
    switch (kind) {
        .text => _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString(text), objc.nsString("public.utf8-plain-text") }),
        .file => _ = objc.msg(objc.BOOL, board, "writeObjects:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{fileURL(text)})}),
        .image => if (png) |stored| if (pngData(nsData(stored))) |data| {
            _ = objc.msg(objc.BOOL, board, "setData:forType:", .{ data, objc.nsString("public.png") });
        },
    }
    markOwnWrite(board);
}

pub fn pasteboardChangeCount() objc.NSInteger {
    return objc.msg(objc.NSInteger, generalPasteboard(), "changeCount", .{});
}

/// The general pasteboard as Clipboard History reads it. Holds an
/// autorelease pool from `begin` to `end`, so both run on one thread.
pub const PasteboardReader = struct {
    pool: @TypeOf(objc.Pool.push()),
    board: objc.Object,
    types: ?objc.Object,
    /// The picture's data, once `imageByteCount` found it.
    picture: ?objc.Object = null,
    picture_is_png: bool = false,

    pub fn begin() PasteboardReader {
        const pool = objc.Pool.push();
        const board = generalPasteboard();
        return .{ .pool = pool, .board = board, .types = objc.msg(?objc.Object, board, "types", .{}) };
    }

    pub fn end(r: *PasteboardReader) void {
        r.pool.pop();
    }

    pub fn pasteboard(r: *PasteboardReader) clipboard.Pasteboard {
        return .{ .ctx = r, .has_type = hasType, .file_paths = filePaths, .image_byte_count = imageByteCount, .image = image, .text = text };
    }

    fn of(ctx: ?*anyopaque) *PasteboardReader {
        return @ptrCast(@alignCast(ctx));
    }

    fn hasType(ctx: ?*anyopaque, ty: []const u8) bool {
        const types = of(ctx).types orelse return false;
        return objc.msg(objc.BOOL, types, "containsObject:", .{objc.nsString(ty)});
    }

    fn filePaths(ctx: ?*anyopaque, arena: std.mem.Allocator) []const []const u8 {
        const url_class = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
        const files_only = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{
            objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}),
            objc.nsString("NSPasteboardURLReadingFileURLsOnlyKey"),
        });
        const urls = objc.msg(?objc.Object, of(ctx).board, "readObjectsForClasses:options:", .{ url_class, files_only }) orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (0..objc.msg(objc.NSUInteger, urls, "count", .{})) |i| {
            const url = objc.msg(objc.Object, objc.msg(objc.Object, urls, "objectAtIndex:", .{i}), "standardizedURL", .{});
            const path = arena.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}))) catch continue;
            out.append(arena, path) catch {};
        }
        return out.items;
    }

    /// PNG wins over TIFF.
    fn imageByteCount(ctx: ?*anyopaque) ?usize {
        const r = of(ctx);
        const png = objc.msg(?objc.Object, r.board, "dataForType:", .{objc.nsString("public.png")});
        r.picture_is_png = png != null;
        r.picture = png orelse objc.msg(?objc.Object, r.board, "dataForType:", .{objc.nsString("public.tiff")});
        return if (r.picture) |data| objc.msg(objc.NSUInteger, data, "length", .{}) else null;
    }

    /// TIFF comes back as PNG. Either must decode.
    fn image(ctx: ?*anyopaque, arena: std.mem.Allocator) ?clipboard.PastedImage {
        const r = of(ctx);
        const data = r.picture orelse return null;
        const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return null;
        const raw_w = objc.msg(objc.NSInteger, rep, "pixelsWide", .{});
        const raw_h = objc.msg(objc.NSInteger, rep, "pixelsHigh", .{});
        if (raw_w <= 0 or raw_h <= 0) return null;
        const width = std.math.cast(u32, raw_w) orelse return null;
        const height = std.math.cast(u32, raw_h) orelse return null;
        if (@as(u64, width) * @as(u64, height) > max_image_pixels) return null;
        const png_data = if (r.picture_is_png) data else pngRepresentation(rep) orelse return null;
        return .{
            .png = arena.dupe(u8, dataBytes(png_data)) catch return null,
            .thumbnail = thumbnailPng(arena, data) orelse "",
            .width = width,
            .height = height,
            .format = if (r.picture_is_png) .png else .tiff,
        };
    }

    fn text(ctx: ?*anyopaque, arena: std.mem.Allocator) []const u8 {
        const s = objc.fromNSString(objc.msg(?objc.Object, of(ctx).board, "stringForType:", .{objc.nsString("public.utf8-plain-text")}));
        return arena.dupe(u8, s) catch "";
    }
};

/// A bitmap image rep encoded as PNG data.
pub fn pngRepresentation(rep: objc.Object) ?objc.Object {
    const png_file_type: objc.NSUInteger = 4;
    return objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ png_file_type, objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) });
}

pub fn dataBytes(data: objc.Object) []const u8 {
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    if (len == 0) return "";
    return objc.msg([*]const u8, data, "bytes", .{})[0..len];
}

pub extern "c" fn CGImageSourceCreateWithData(data: objc.Object, options: ?objc.Object) ?*anyopaque;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: *anyopaque, index: usize, options: objc.Object) ?*anyopaque;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: objc.Object;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: objc.Object;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: objc.Object;

/// Scales the image to 128 px on its long side as PNG.
fn thumbnailPng(arena: std.mem.Allocator, data: objc.Object) ?[]const u8 {
    const src = CGImageSourceCreateWithData(data, null) orelse return null;
    defer CFRelease(src);
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const keys = [_]objc.Object{ kCGImageSourceThumbnailMaxPixelSize, kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform };
    const values = [_]objc.Object{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, 128)}), yes, yes };
    const options = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) orelse return null;
    defer CFRelease(cg);
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const out = pngRepresentation(rep) orelse return null;
    return arena.dupe(u8, dataBytes(out)) catch null;
}

pub fn nsData(bytes: []const u8) objc.Object {
    if (bytes.len == 0) return objc.msg(objc.Object, objc.class("NSData"), "data", .{});
    return objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
}

fn isPng(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
}

fn pngData(data: objc.Object) ?objc.Object {
    if (isPng(dataBytes(data))) return data;
    const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return null;
    return pngRepresentation(rep);
}

pub fn pngBytes(arena: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;
    if (isPng(bytes)) return bytes;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = pngData(nsData(bytes)) orelse return null;
    const out = dataBytes(data);
    if (out.len == 0) return null;
    return arena.dupe(u8, out) catch null;
}

pub extern "c" fn CGImageSourceCreateImageAtIndex(src: *anyopaque, index: usize, options: ?objc.Object) ?*anyopaque;
pub extern "c" fn CGImageGetWidth(image: *anyopaque) usize;
pub extern "c" fn CGImageGetHeight(image: *anyopaque) usize;
extern "c" fn CGImageGetAlphaInfo(image: *anyopaque) u32;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits: usize, row_bytes: usize, space: *anyopaque, info: u32) ?*anyopaque;
pub extern "c" fn CGContextDrawImage(context: *anyopaque, rect: objc.CGRect, image: *anyopaque) void;
extern "c" fn CGImageDestinationCreateWithData(data: objc.Object, kind: objc.Object, count: usize, options: ?objc.Object) ?*anyopaque;
extern "c" fn CGImageDestinationAddImageFromSource(dest: *anyopaque, src: *anyopaque, index: usize, properties: ?objc.Object) void;
extern "c" fn CGImageDestinationFinalize(dest: *anyopaque) bool;
extern "c" const kCGImageDestinationLossyCompressionQuality: objc.Object;

const alpha_none: u32 = 0;
const alpha_none_skip_last: u32 = 5;
const alpha_none_skip_first: u32 = 6;
const alpha_premultiplied_last: u32 = 1;
const avif_quality: f64 = 0.75;
const avif_most_of_png = 9;
const max_image_pixels: usize = 64 * 1024 * 1024;

fn everyPixelOpaque(image: *anyopaque) bool {
    switch (CGImageGetAlphaInfo(image)) {
        alpha_none, alpha_none_skip_last, alpha_none_skip_first => return true,
        else => {},
    }
    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    if (w == 0 or h == 0) return false;
    const pixel_count = std.math.mul(usize, w, h) catch return false;
    if (pixel_count > max_image_pixels) return false;
    const row_bytes = std.math.mul(usize, w, 4) catch return false;
    const byte_len = std.math.mul(usize, pixel_count, 4) catch return false;
    const pixels = std.heap.page_allocator.alloc(u8, byte_len) catch return false;
    defer std.heap.page_allocator.free(pixels);
    const space = CGColorSpaceCreateDeviceRGB() orelse return false;
    defer CFRelease(space);
    const context = CGBitmapContextCreate(pixels.ptr, w, h, 8, row_bytes, space, alpha_premultiplied_last) orelse return false;
    defer CFRelease(context);
    CGContextDrawImage(context, .{ .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    var i: usize = 3;
    while (i < pixels.len) : (i += 4) if (pixels[i] != 255) return false;
    return true;
}

pub fn compactImage(arena: std.mem.Allocator, png: []const u8) ?[]const u8 {
    if (png.len == 0) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const src = CGImageSourceCreateWithData(nsData(png), null) orelse return null;
    defer CFRelease(src);
    const image = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return null;
    defer CFRelease(image);
    if (!everyPixelOpaque(image)) return null;
    const out = objc.msg(objc.Object, objc.class("NSMutableData"), "data", .{});
    const dest = CGImageDestinationCreateWithData(out, objc.nsString("public.avif"), 1, null) orelse return null;
    defer CFRelease(dest);
    const quality = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{avif_quality});
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ quality, kCGImageDestinationLossyCompressionQuality });
    CGImageDestinationAddImageFromSource(dest, src, 0, props);
    if (!CGImageDestinationFinalize(dest)) return null;
    const bytes = dataBytes(out);
    if (@as(u128, bytes.len) * 10 > @as(u128, png.len) * avif_most_of_png) return null;
    return arena.dupe(u8, bytes) catch null;
}

// Quick Look: one item, from a data source the shell points at a file.

var preview_url: ?objc.Object = null;

fn previewCount(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSInteger {
    return if (preview_url != null) 1 else 0;
}

fn previewItem(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) ?objc.Object {
    return preview_url;
}

fn previewPanel() ?objc.Object {
    const cls = objc_getClass("QLPreviewPanel") orelse return null;
    return objc.msg(?objc.Object, cls, "sharedPreviewPanel", .{});
}

pub fn previewVisible() bool {
    const cls = objc_getClass("QLPreviewPanel") orelse return false;
    if (!objc.msg(objc.BOOL, cls, "sharedPreviewPanelExists", .{})) return false;
    const panel = objc.msg(objc.Object, cls, "sharedPreviewPanel", .{});
    return objc.msg(objc.BOOL, panel, "isVisible", .{});
}

/// Shows `path` in Quick Look, or closes Quick Look when it is up.
pub fn togglePreview(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = previewPanel() orelse return;
    if (objc.msg(objc.BOOL, panel, "isVisible", .{})) return objc.msg(void, panel, "orderOut:", .{@as(?objc.Object, null)});
    if (preview_url) |old| objc.release(old);
    preview_url = objc.retain(fileURL(path));
    const cls = objc.defineClass(.{ .name = "NanospotPreviewSource", .methods = &.{
        .{ .name = "numberOfPreviewItemsInPreviewPanel:", .imp = &previewCount, .types = "q@:@" },
        .{ .name = "previewPanel:previewItemAtIndex:", .imp = &previewItem, .types = "@@:@q" },
    } });
    const S = struct {
        var source: ?objc.Object = null;
    };
    if (S.source == null) S.source = objc.msg(objc.Object, cls, "new", .{});
    objc.msg(void, panel, "setDataSource:", .{S.source.?});
    objc.msg(void, panel, "reloadData", .{});
    objc.msg(void, panel, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
}

/// An image entry's bytes as a file Quick Look can open.
pub fn previewFile(gpa: std.mem.Allocator, id: i64, png: []const u8) ?[]const u8 {
    if (png.len == 0) return null;
    const dir = std.fs.path.join(gpa, &.{ std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp"), "NanospotPreviews" }) catch return null;
    defer gpa.free(dir);
    const dir_z = gpa.dupeSentinel(u8, dir, 0) catch return null;
    defer gpa.free(dir_z);
    _ = std.c.mkdir(dir_z, 0o700);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{d}.png", .{ dir, id }, 0) catch return null;
    errdefer gpa.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return null;
    var ok = true;
    var written: usize = 0;
    while (written < png.len) {
        const n = std.c.write(fd, png[written..].ptr, png.len - written);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) {
            ok = false;
            break;
        }
        written += @intCast(n);
    }
    _ = std.c.close(fd);
    if (!ok) {
        _ = std.c.unlink(path);
        gpa.free(path);
        return null;
    }
    return path;
}

const DateFormatters = struct {
    threadlocal var time_fmt: ?objc.Object = null;
    threadlocal var weekday_fmt: ?objc.Object = null;
    threadlocal var date_fmt: ?objc.Object = null;
    threadlocal var detailed_fmt: ?objc.Object = null;

    fn timeOnly() objc.Object {
        if (time_fmt) |f| return f;
        const f = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
        objc.msg(void, f, "setDateStyle:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, f, "setTimeStyle:", .{@as(objc.NSUInteger, 1)});
        time_fmt = f;
        return f;
    }

    fn weekdayOnly() objc.Object {
        if (weekday_fmt) |f| return f;
        const f = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
        objc.msg(void, f, "setLocalizedDateFormatFromTemplate:", .{objc.nsString("EEEE")});
        weekday_fmt = f;
        return f;
    }

    fn dateOnly() objc.Object {
        if (date_fmt) |f| return f;
        const f = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
        objc.msg(void, f, "setDateStyle:", .{@as(objc.NSUInteger, 2)});
        objc.msg(void, f, "setTimeStyle:", .{@as(objc.NSUInteger, 0)});
        date_fmt = f;
        return f;
    }

    fn dateAndTime() objc.Object {
        if (detailed_fmt) |f| return f;
        const f = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
        objc.msg(void, f, "setDateStyle:", .{@as(objc.NSUInteger, 2)});
        objc.msg(void, f, "setTimeStyle:", .{@as(objc.NSUInteger, 1)});
        detailed_fmt = f;
        return f;
    }
};

pub fn relativeDate(secs: i64, arena: std.mem.Allocator) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSince1970:", .{@as(f64, @floatFromInt(secs))});
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    const calendar = objc.msg(objc.Object, objc.class("NSCalendar"), "currentCalendar", .{});
    const from = objc.msg(objc.Object, calendar, "startOfDayForDate:", .{date});
    const to = objc.msg(objc.Object, calendar, "startOfDayForDate:", .{now});
    const unit_day: objc.NSUInteger = 1 << 4;
    const parts = objc.msg(objc.Object, calendar, "components:fromDate:toDate:options:", .{ unit_day, from, to, @as(objc.NSUInteger, 0) });
    const days = objc.msg(objc.NSInteger, parts, "day", .{});
    if (days == 1) return "Yesterday";
    if (days == 0) {
        const s = objc.fromNSString(objc.msg(?objc.Object, DateFormatters.timeOnly(), "stringFromDate:", .{date}));
        return std.fmt.allocPrint(arena, "Today at {s}", .{s}) catch "";
    }
    if (days >= 2 and days <= 6) {
        const w = objc.fromNSString(objc.msg(?objc.Object, DateFormatters.weekdayOnly(), "stringFromDate:", .{date}));
        const weekday = arena.dupe(u8, w) catch return "";
        const s = objc.fromNSString(objc.msg(?objc.Object, DateFormatters.timeOnly(), "stringFromDate:", .{date}));
        return std.fmt.allocPrint(arena, "{s} at {s}", .{ weekday, s }) catch "";
    }
    return arena.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, DateFormatters.dateOnly(), "stringFromDate:", .{date}))) catch "";
}

/// "Today at 3:03 PM", "Yesterday at 3:03 PM", else the date and time.
pub fn detailedDate(secs: f64, arena: std.mem.Allocator) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSince1970:", .{secs});
    const calendar = objc.msg(objc.Object, objc.class("NSCalendar"), "currentCalendar", .{});
    const today = objc.msg(objc.BOOL, calendar, "isDateInToday:", .{date});
    const yesterday = !today and objc.msg(objc.BOOL, calendar, "isDateInYesterday:", .{date});
    const fmt = if (today or yesterday) DateFormatters.timeOnly() else DateFormatters.dateAndTime();
    const s = objc.fromNSString(objc.msg(?objc.Object, fmt, "stringFromDate:", .{date}));
    if (today) return std.fmt.allocPrint(arena, "Today at {s}", .{s}) catch "";
    if (yesterday) return std.fmt.allocPrint(arena, "Yesterday at {s}", .{s}) catch "";
    return arena.dupe(u8, s) catch "";
}
