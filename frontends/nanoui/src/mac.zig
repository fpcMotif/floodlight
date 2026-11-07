//! Everything that talks to macOS past what nanoui covers: the global
//! hotkey, the glass slab behind the panel, NSWorkspace, the Full Disk
//! Access probe, System Settings' window, and a drag that carries a file.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const permission = @import("permission.zig");
const clipboard = @import("clipboard.zig");

// Carbon is the only public API that registers a system-wide hotkey without
// the accessibility permission a CGEventTap needs. Deprecated, still what
// every launcher ships.
const carbon = struct {
    const EventTypeSpec = extern struct { class: u32, kind: u32 };
    const HotKeyId = extern struct { signature: u32, id: u32 };
    const Handler = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) i32;
    extern "c" fn GetApplicationEventTarget() ?*anyopaque;
    extern "c" fn InstallEventHandler(target: ?*anyopaque, handler: Handler, n: usize, list: *const EventTypeSpec, user: ?*anyopaque, out: ?*?*anyopaque) i32;
    extern "c" fn RegisterEventHotKey(code: u32, modifiers: u32, id: HotKeyId, target: ?*anyopaque, options: u32, out: *?*anyopaque) i32;
    extern "c" fn GetEventParameter(event: ?*anyopaque, name: u32, kind: u32, actual_kind: ?*u32, size: usize, actual_size: ?*usize, out: *anyopaque) i32;
    const keyboard_class: u32 = 0x6b657962; // 'keyb'
    const hot_key_pressed: u32 = 5;
    const direct_object: u32 = 0x2d2d2d2d; // '----'
    const hot_key_id_type: u32 = 0x686b6964; // 'hkid'
    const shift_key: u32 = 1 << 9;
    const option_key: u32 = 1 << 11;
    const space: u32 = 49;
    const c_key: u32 = 8;
};

pub const HotKey = enum(u32) {
    /// ⌥Space, so ⌘Space stays Spotlight's.
    search = 1,
    /// ⌥⇧C, so ⇧⌘C stays the Swift board's.
    clipboard = 2,
};

var hotkey_fn: ?*const fn (?*anyopaque, HotKey) void = null;
var hotkey_ctx: ?*anyopaque = null;

fn onHotKey(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    var id: carbon.HotKeyId = undefined;
    if (carbon.GetEventParameter(event, carbon.direct_object, carbon.hot_key_id_type, null, @sizeOf(carbon.HotKeyId), null, &id) != 0) return 0;
    const which: HotKey = switch (id.id) {
        @backingInt(HotKey.search) => .search,
        @backingInt(HotKey.clipboard) => .clipboard,
        else => return 0,
    };
    if (hotkey_fn) |f| f(hotkey_ctx, which);
    return 0;
}

/// Registers both hotkeys. Runs `f` on the main thread.
pub fn registerHotKeys(ctx: ?*anyopaque, f: *const fn (?*anyopaque, HotKey) void) !void {
    hotkey_fn = f;
    hotkey_ctx = ctx;
    const target = carbon.GetApplicationEventTarget();
    const spec: carbon.EventTypeSpec = .{ .class = carbon.keyboard_class, .kind = carbon.hot_key_pressed };
    if (carbon.InstallEventHandler(target, &onHotKey, 1, &spec, null, null) != 0) return error.HotKeyHandler;
    const keys = [_]struct { HotKey, u32, u32 }{
        .{ .search, carbon.space, carbon.option_key },
        .{ .clipboard, carbon.c_key, carbon.option_key | carbon.shift_key },
    };
    for (keys) |k| {
        var ref: ?*anyopaque = null;
        const id: carbon.HotKeyId = .{ .signature = 0x464c6e75, .id = @backingInt(k[0]) }; // 'FLnu'
        if (carbon.RegisterEventHotKey(k[1], k[2], id, target, 0, &ref) != 0) std.log.warn("hotkey {s} is taken", .{@tagName(k[0])});
    }
}

var reopen_fn: ?*const fn (?*anyopaque) void = null;
var reopen_ctx: ?*anyopaque = null;

fn onReopen(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {
    if (reopen_fn) |f| f(reopen_ctx);
}

/// Calls `f` when the app is opened again from Finder, the Dock, or `open`.
/// Call it once the run loop runs: NSApplication installs its own handler while it launches.
pub fn handleReopen(ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
    reopen_fn = f;
    reopen_ctx = ctx;
    const cls = objc.defineClass(.{ .name = "FloodlightReopenTarget", .methods = &.{
        .{ .name = "handleReopen:withReplyEvent:", .imp = &onReopen, .types = "v@:@@" },
    } });
    const target = objc.msg(objc.Object, cls, "new", .{});
    const manager = objc.msg(objc.Object, objc_getClass("NSAppleEventManager").?, "sharedAppleEventManager", .{});
    const core_class: u32 = 0x61657674; // 'aevt'
    const reopen_id: u32 = 0x72617070; // 'rapp'
    objc.msg(void, manager, "setEventHandler:andSelector:forEventClass:andEventID:", .{ target, objc.sel("handleReopen:withReplyEvent:"), core_class, reopen_id });
}

/// A menu-bar agent: no Dock icon, and the panel never steals the menu bar.
pub fn becomeAccessory(nsapp: objc.Object) void {
    _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
}

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Object;

pub const Level = enum(objc.NSInteger) { floating = 3, status = 25 };

pub const GlassStyle = enum(objc.NSInteger) { regular = 0, clear = 1 };

/// Moves a window so its bottom left is at `r`'s, in Cocoa screen points.
pub fn setFrameOrigin(window: *nanoui.Window, r: permission.Rect) void {
    objc.msg(void, window.nswindow, "setFrameOrigin:", .{objc.CGPoint{ .x = r.x, .y = r.y }});
}

pub fn frameOf(window: *nanoui.Window) permission.Rect {
    return toRect(objc.msg(objc.CGRect, window.nswindow, "frame", .{}));
}

/// Shows a window without making it key: the guidance panel sits beside
/// System Settings, which keeps the focus.
pub fn orderFrontRegardless(window: *nanoui.Window) void {
    objc.msg(void, window.nswindow, "orderFrontRegardless", .{});
}

/// For a surface's `after_frame`. nanoui 0.9.2 slows its display link to a
/// frame the view asks for later (a caret blink, a scroll bar's fade): the
/// slow link's drawables are for up to half a second ahead, and one drawn
/// at a keypress lands after the faster frames that follow, an old list
/// shown again. When that frame is due was taken before this runs.
pub fn keepLinkAtDisplayRate(c: *nanoui.ui.Context) void {
    if (c.frame_in != null) c.frame_in = 0;
}

pub fn setAlpha(window: *nanoui.Window, alpha: f64) void {
    objc.msg(void, window.nswindow, "setAlphaValue:", .{alpha});
}

fn reduceTransparency() bool {
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceTransparency", .{});
}

/// Puts the panel's content on a clear Liquid Glass slab (NSGlassEffectView,
/// macOS 26) that refracts the desktop behind it, as the Swift panel does;
/// a HUD material where glass isn't available or transparency is reduced.
/// Returns the flipped view the surface fills: native views go in it, over
/// the surface, because nanoui's surface takes every click inside it.
pub fn installSlab(window: *nanoui.Window, radius: f64, level: Level, style: GlassStyle) ?objc.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const w = window.nswindow;
    const surface = window.surface orelse return null;
    objc.msg(void, w, "setOpaque:", .{objc.NO});
    objc.msg(void, w, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
    objc.msg(void, w, "setHasShadow:", .{objc.YES});
    objc.msg(void, w, "setLevel:", .{@backingInt(level)});
    objc.msg(void, w, "setAnimationBehavior:", .{@as(objc.NSInteger, 2)}); // none
    objc.msg(void, w, "setHidesOnDeactivate:", .{objc.NO});
    objc.msg(void, w, "setCollectionBehavior:", .{@as(objc.NSUInteger, (1 << 0) | (1 << 8) | (1 << 3))});
    surface.setTransparent(true);

    const content = surface.nsview;
    objc.msg(void, objc.msg(objc.Object, content, "layer", .{}), "setContentsGravity:", .{objc.nsString("bottom")});
    objc.msg(void, content, "retain", .{});
    defer objc.msg(void, content, "release", .{});
    const frame = objc.msg(objc.CGRect, content, "frame", .{});
    const host_class = objc.defineClass(.{ .name = "FloodlightHostView", .superclass = "NSView", .methods = &.{
        .{ .name = "isFlipped", .imp = &FileDragSource.yes0, .types = "c@:" },
    } });
    const host = objc.msg(objc.Object, objc.msg(objc.Object, host_class, "alloc", .{}), "initWithFrame:", .{frame});
    objc.msg(void, content, "setFrame:", .{objc.CGRect{ .size = frame.size }});
    objc.msg(void, content, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, host, "addSubview:", .{content});
    if (objc_getClass("NSGlassEffectView") != null and !reduceTransparency()) {
        const glass = objc.msg(objc.Object, objc.alloc("NSGlassEffectView"), "initWithFrame:", .{frame});
        defer objc.release(glass);
        objc.msg(void, glass, "setStyle:", .{@backingInt(style)});
        objc.msg(void, glass, "setCornerRadius:", .{radius});
        objc.msg(void, w, "setContentView:", .{glass});
        objc.msg(void, glass, "setContentView:", .{host});
    } else {
        const fx = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{frame});
        defer objc.release(fx);
        objc.msg(void, fx, "setMaterial:", .{@as(objc.NSInteger, 13)}); // hudWindow
        objc.msg(void, fx, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behindWindow
        objc.msg(void, fx, "setState:", .{@as(objc.NSInteger, 1)}); // active
        objc.msg(void, fx, "setWantsLayer:", .{objc.YES});
        if (objc.msg(?objc.Object, fx, "layer", .{})) |layer| {
            objc.msg(void, layer, "setCornerRadius:", .{radius});
            objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
        }
        objc.msg(void, w, "setContentView:", .{fx});
        objc.msg(void, host, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
        objc.msg(void, fx, "addSubview:", .{host});
    }
    objc.release(host);
    _ = objc.msg(objc.BOOL, w, "makeFirstResponder:", .{content});
    return host;
}

fn workspace() objc.Object {
    return objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
}

fn fileURL(path: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

fn urlFor(path: []const u8) ?objc.Object {
    if (std.mem.startsWith(u8, path, "https://")) return objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(path)});
    return fileURL(path);
}

pub fn open(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = urlFor(path) orelse return;
    _ = objc.msg(objc.BOOL, workspace(), "openURL:", .{url});
}

pub fn copy(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = urlFor(path) orelse return;
    const board = beginWrite();
    const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
    _ = objc.msg(objc.BOOL, board, "writeObjects:", .{items});
    markOwnWrite(board);
}

fn generalPasteboard() objc.Object {
    return objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

fn beginWrite() objc.Object {
    const board = generalPasteboard();
    _ = objc.msg(objc.NSInteger, board, "clearContents", .{});
    return board;
}

/// The Swift shell's marker: history skips what Floodlight wrote itself.
const own_write_type = "com.floodlight.own-write";
pub const skipped_types = [_][]const u8{ own_write_type, "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.apple.is-sensitive" };

fn markOwnWrite(board: objc.Object) void {
    _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString("1"), objc.nsString(own_write_type) });
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

/// What the pasteboard holds now, in `arena`'s memory; empty when it is
/// Floodlight's own write, marked private, or nothing history keeps.
pub fn readPasteboard(arena: std.mem.Allocator, source: []const u8) []clipboard.Capture {
    const pool = objc.Pool.push();
    defer pool.pop();
    const board = generalPasteboard();
    const types = objc.msg(?objc.Object, board, "types", .{}) orelse return &.{};
    for (skipped_types) |t| if (objc.msg(objc.BOOL, types, "containsObject:", .{objc.nsString(t)})) return &.{};

    var out: std.ArrayList(clipboard.Capture) = .empty;
    const url_class = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const files_only = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{
        objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}),
        objc.nsString("NSPasteboardURLReadingFileURLsOnlyKey"),
    });
    if (objc.msg(?objc.Object, board, "readObjectsForClasses:options:", .{ url_class, files_only })) |urls| {
        const n = objc.msg(objc.NSUInteger, urls, "count", .{});
        for (0..n) |i| {
            const url = objc.msg(objc.Object, objc.msg(objc.Object, urls, "objectAtIndex:", .{i}), "standardizedURL", .{});
            const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
            if (path.len == 0) continue;
            const owned = arena.dupe(u8, path) catch continue;
            if (!containsFile(out.items, owned)) out.append(arena, .{ .file = owned }) catch {};
        }
        if (out.items.len > 0) return out.items;
    }

    if (readImage(arena, board, source)) |img| {
        out.append(arena, .{ .image = img }) catch {};
        return out.items;
    }
    const text = objc.fromNSString(objc.msg(?objc.Object, board, "stringForType:", .{objc.nsString("public.utf8-plain-text")}));
    if (text.len == 0 or text.len > clipboard.max_text_bytes) return &.{};
    out.append(arena, .{ .text = arena.dupe(u8, text) catch return &.{} }) catch {};
    return out.items;
}

fn containsFile(caps: []const clipboard.Capture, path: []const u8) bool {
    for (caps) |cap| if (cap == .file and std.mem.eql(u8, cap.file, path)) return true;
    return false;
}

fn dataBytes(data: objc.Object) []const u8 {
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    if (len == 0) return "";
    return objc.msg([*]const u8, data, "bytes", .{})[0..len];
}

/// PNG wins over TIFF; TIFF is stored as PNG. Either must decode.
fn readImage(arena: std.mem.Allocator, board: objc.Object, source: []const u8) ?clipboard.Capture.Image {
    const png = objc.msg(?objc.Object, board, "dataForType:", .{objc.nsString("public.png")});
    const tiff = if (png == null) objc.msg(?objc.Object, board, "dataForType:", .{objc.nsString("public.tiff")}) else null;
    const data = png orelse tiff orelse return null;
    if (objc.msg(objc.NSUInteger, data, "length", .{}) > clipboard.max_image_bytes) return null;
    const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return null;
    const w = objc.msg(objc.NSInteger, rep, "pixelsWide", .{});
    const h = objc.msg(objc.NSInteger, rep, "pixelsHigh", .{});
    if (w <= 0 or h <= 0) return null;
    const png_data = if (png) |p| p else objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) }) orelse return null;
    const name: []const u8 = if (std.mem.eql(u8, source, "com.apple.screencapture") or std.mem.eql(u8, source, "com.apple.screencaptureui")) "Screenshot" else if (png != null) "PNG Image" else "TIFF Image";
    return .{
        .name = name,
        .png = arena.dupe(u8, dataBytes(png_data)) catch return null,
        .thumbnail = thumbnailPng(arena, png_data) orelse "",
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

extern "c" fn CGImageSourceCreateWithData(data: objc.Object, options: ?objc.Object) ?*anyopaque;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: *anyopaque, index: usize, options: objc.Object) ?*anyopaque;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: objc.Object;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: objc.Object;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: objc.Object;

/// 128 px on its long side, as the Swift store's thumbnails.
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
    const out = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) }) orelse return null;
    return arena.dupe(u8, dataBytes(out)) catch null;
}

fn nsData(bytes: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
}

fn isPng(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
}

fn pngData(data: objc.Object) ?objc.Object {
    if (isPng(dataBytes(data))) return data;
    const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return null;
    return objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) });
}

pub fn pngBytes(arena: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
    if (isPng(bytes)) return bytes;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = pngData(nsData(bytes)) orelse return null;
    return arena.dupe(u8, dataBytes(data)) catch null;
}

extern "c" fn CGImageSourceCreateImageAtIndex(src: *anyopaque, index: usize, options: ?objc.Object) ?*anyopaque;
extern "c" fn CGImageGetWidth(image: *anyopaque) usize;
extern "c" fn CGImageGetHeight(image: *anyopaque) usize;
extern "c" fn CGImageGetAlphaInfo(image: *anyopaque) u32;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits: usize, row_bytes: usize, space: *anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGContextDrawImage(context: *anyopaque, rect: objc.CGRect, image: *anyopaque) void;
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

fn everyPixelOpaque(image: *anyopaque) bool {
    switch (CGImageGetAlphaInfo(image)) {
        alpha_none, alpha_none_skip_last, alpha_none_skip_first => return true,
        else => {},
    }
    const w = CGImageGetWidth(image);
    const h = CGImageGetHeight(image);
    const pixels = std.heap.page_allocator.alloc(u8, w * h * 4) catch return false;
    defer std.heap.page_allocator.free(pixels);
    const space = CGColorSpaceCreateDeviceRGB() orelse return false;
    defer CFRelease(space);
    const context = CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, alpha_premultiplied_last) orelse return false;
    defer CFRelease(context);
    CGContextDrawImage(context, .{ .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    var i: usize = 3;
    while (i < pixels.len) : (i += 4) if (pixels[i] != 255) return false;
    return true;
}

pub fn compactImage(arena: std.mem.Allocator, png: []const u8) ?[]const u8 {
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
    if (bytes.len * 10 > png.len * avif_most_of_png) return null;
    return arena.dupe(u8, bytes) catch null;
}

pub const RunningApp = struct { pid: i32 = 0, bundle_id: []const u8 = "", name: []const u8 = "" };

/// The frontmost app, its strings in `gpa`'s memory. Named as the Swift
/// board names a source.
pub fn frontmostApp(gpa: std.mem.Allocator) RunningApp {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.msg(?objc.Object, workspace(), "frontmostApplication", .{}) orelse return .{};
    const id = objc.fromNSString(objc.msg(?objc.Object, app, "bundleIdentifier", .{}));
    return .{
        .pid = objc.msg(i32, app, "processIdentifier", .{}),
        .bundle_id = gpa.dupe(u8, id) catch "",
        .name = gpa.dupe(u8, sourceName(id, objc.fromNSString(objc.msg(?objc.Object, app, "localizedName", .{})))) catch "Clipboard",
    };
}

pub fn sourceName(bundle_id: []const u8, localized: []const u8) []const u8 {
    if (bundle_id.len == 0) return "Clipboard";
    if (std.mem.eql(u8, bundle_id, "com.apple.screencaptureui")) return "Screenshot";
    if (std.mem.eql(u8, bundle_id, "com.apple.finder")) return "Finder";
    if (localized.len > 0) return localized;
    return bundle_id[if (std.mem.lastIndexOfScalar(u8, bundle_id, '.')) |dot| dot + 1 else 0..];
}

pub fn ownPid() i32 {
    const info = objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
    return objc.msg(i32, info, "processIdentifier", .{});
}

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXIsProcessTrustedWithOptions(options: ?objc.Object) bool;
extern "c" const kAXTrustedCheckOptionPrompt: objc.Object;
extern "c" fn IsSecureEventInputEnabled() bool;
extern "c" fn CGEventCreateKeyboardEvent(source: ?*anyopaque, key: u16, down: bool) ?*anyopaque;
extern "c" fn CGEventSetFlags(event: *anyopaque, flags: u64) void;
extern "c" fn CGEventPost(tap: u32, event: *anyopaque) void;

/// Posting ⌘V into another app takes the Accessibility permission.
pub fn canDeliverPaste() bool {
    return AXIsProcessTrusted();
}

/// Shows the system's Accessibility prompt.
pub fn promptAccessibility() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const options = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes, kAXTrustedCheckOptionPrompt });
    _ = AXIsProcessTrustedWithOptions(options);
}

/// Brings `pid` forward and types ⌘V into it, as PasteTargetDelivery.
/// False when the app is gone, never comes forward, or a password field
/// has secure input on.
pub fn deliverPaste(pid: i32) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.msg(?objc.Object, objc.class("NSRunningApplication"), "runningApplicationWithProcessIdentifier:", .{pid}) orelse return false;
    _ = objc.msg(objc.BOOL, app, "activateWithOptions:", .{@as(objc.NSUInteger, 0)});
    var tries: usize = 0;
    while (!objc.msg(objc.BOOL, app, "isActive", .{})) : (tries += 1) {
        if (tries == 40) return false;
        sleepMs(15);
        // The activation lands on the run loop, which this wait holds.
        const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "currentRunLoop", .{});
        objc.msg(void, loop, "runUntilDate:", .{objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.001)})});
    }
    if (IsSecureEventInputEnabled()) return false;
    sleepMs(80);
    const v_key: u16 = 9;
    const command: u64 = 1 << 20;
    for ([_]bool{ true, false }) |down| {
        const e = CGEventCreateKeyboardEvent(null, v_key, down) orelse return false;
        defer CFRelease(e);
        CGEventSetFlags(e, command);
        CGEventPost(0, e);
    }
    return true;
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
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
    const cls = objc.defineClass(.{ .name = "FloodlightPreviewSource", .methods = &.{
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
    const dir = std.fs.path.join(gpa, &.{ std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp"), "FloodlightNanoPreviews" }) catch return null;
    defer gpa.free(dir);
    const dir_z = gpa.dupeSentinel(u8, dir, 0) catch return null;
    defer gpa.free(dir_z);
    _ = std.c.mkdir(dir_z, 0o700);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{d}.png", .{ dir, id }, 0) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < png.len) {
        const n = std.c.write(fd, png[written..].ptr, png.len - written);
        if (n <= 0) return null;
        written += @intCast(n);
    }
    return path;
}

// The ⌘K menu: native, as the Swift board's.

pub const MenuItem = struct { title: []const u8, key: []const u8 = "", modifiers: objc.NSUInteger = 0, enabled: bool = true, separator_before: bool = false };

pub const command_modifier: objc.NSUInteger = 1 << 20;

var menu_choice: ?usize = null;

fn menuPicked(_: objc.Object, _: objc.SEL, item: objc.Object) callconv(.c) void {
    menu_choice = @intCast(objc.msg(objc.NSInteger, item, "tag", .{}));
}

/// Pops up `items` at `at` (flipped points in `window`'s content) and
/// returns the chosen index once the menu closes.
pub fn popUpMenu(window: *nanoui.Window, items: []const MenuItem, at: [2]f64) ?usize {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{ .name = "FloodlightMenuTarget", .methods = &.{
        .{ .name = "pick:", .imp = &menuPicked, .types = "v@:@" },
    } });
    const S = struct {
        var target: ?objc.Object = null;
    };
    if (S.target == null) S.target = objc.msg(objc.Object, cls, "new", .{});
    const menu = objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString("")}), "autorelease", .{});
    objc.msg(void, menu, "setAutoenablesItems:", .{objc.NO});
    for (items, 0..) |it, i| {
        if (it.separator_before) objc.msg(void, menu, "addItem:", .{objc.msg(objc.Object, objc.class("NSMenuItem"), "separatorItem", .{})});
        const item = objc.msg(objc.Object, menu, "addItemWithTitle:action:keyEquivalent:", .{ objc.nsString(it.title), objc.sel("pick:"), objc.nsString(it.key) });
        objc.msg(void, item, "setKeyEquivalentModifierMask:", .{it.modifiers});
        objc.msg(void, item, "setTarget:", .{S.target.?});
        objc.msg(void, item, "setTag:", .{@as(objc.NSInteger, @intCast(i))});
        objc.msg(void, item, "setEnabled:", .{if (it.enabled) objc.YES else objc.NO});
    }
    const view = objc.msg(objc.Object, window.nswindow, "contentView", .{});
    const h = objc.msg(objc.CGRect, view, "bounds", .{}).size.height;
    const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
    menu_choice = null;
    _ = objc.msg(objc.BOOL, menu, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(?objc.Object, null), objc.CGPoint{ .x = at[0], .y = if (flipped) at[1] else h - at[1] }, view });
    return menu_choice;
}

pub fn relativeDate(secs: i64, gpa: std.mem.Allocator) []const u8 {
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
    const fmt = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
    defer objc.release(fmt);
    const time = struct {
        fn of(f: objc.Object, d: objc.Object) []const u8 {
            objc.msg(void, f, "setDateStyle:", .{@as(objc.NSUInteger, 0)});
            objc.msg(void, f, "setTimeStyle:", .{@as(objc.NSUInteger, 1)});
            return objc.fromNSString(objc.msg(?objc.Object, f, "stringFromDate:", .{d}));
        }
    }.of;
    if (days == 0) return std.fmt.allocPrint(gpa, "Today at {s}", .{time(fmt, date)}) catch "";
    if (days >= 2 and days <= 6) {
        objc.msg(void, fmt, "setLocalizedDateFormatFromTemplate:", .{objc.nsString("EEEE")});
        const weekday = gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, fmt, "stringFromDate:", .{date}))) catch return "";
        return std.fmt.allocPrint(gpa, "{s} at {s}", .{ weekday, time(fmt, date) }) catch "";
    }
    objc.msg(void, fmt, "setDateStyle:", .{@as(objc.NSUInteger, 2)});
    objc.msg(void, fmt, "setTimeStyle:", .{@as(objc.NSUInteger, 0)});
    return gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, fmt, "stringFromDate:", .{date}))) catch "";
}

/// "Today at 3:03 PM", "Yesterday at 3:03 PM", else the date and time.
pub fn detailedDate(secs: f64, gpa: std.mem.Allocator) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSince1970:", .{secs});
    const calendar = objc.msg(objc.Object, objc.class("NSCalendar"), "currentCalendar", .{});
    const fmt = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
    defer objc.release(fmt);
    const today = objc.msg(objc.BOOL, calendar, "isDateInToday:", .{date});
    const yesterday = !today and objc.msg(objc.BOOL, calendar, "isDateInYesterday:", .{date});
    objc.msg(void, fmt, "setDateStyle:", .{@as(objc.NSUInteger, if (today or yesterday) 0 else 2)});
    objc.msg(void, fmt, "setTimeStyle:", .{@as(objc.NSUInteger, 1)});
    const s = objc.fromNSString(objc.msg(?objc.Object, fmt, "stringFromDate:", .{date}));
    if (today) return std.fmt.allocPrint(gpa, "Today at {s}", .{s}) catch "";
    if (yesterday) return std.fmt.allocPrint(gpa, "Yesterday at {s}", .{s}) catch "";
    return gpa.dupe(u8, s) catch "";
}

pub fn reveal(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{fileURL(path)});
    objc.msg(void, workspace(), "activateFileViewerSelectingURLs:", .{urls});
}

/// Full Disk Access is granted when the TCC database opens: it is readable
/// by nothing else. The Swift shell probes the same file.
pub const full_disk_access_probe = "/Library/Application Support/com.apple.TCC/TCC.db";

pub fn fullDiskAccessGranted() bool {
    const fd = std.c.open(full_disk_access_probe, .{});
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

pub fn openFullDiskAccessSettings() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const urls = [_][]const u8{
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    };
    for (urls) |u| {
        const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(u)}) orelse continue;
        if (objc.msg(objc.BOOL, workspace(), "openURL:", .{url})) return;
    }
}

fn toRect(r: objc.CGRect) permission.Rect {
    return .{ .x = r.origin.x, .y = r.origin.y, .w = r.size.width, .h = r.size.height };
}

pub fn mainScreenVisibleFrame() permission.Rect {
    const screen = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse
        return .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    return toRect(objc.msg(objc.CGRect, screen, "visibleFrame", .{}));
}

pub fn pointerScreenVisibleFrame() permission.Rect {
    const mouse = objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, screens, "count", .{});
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const s = objc.msg(objc.Object, screens, "objectAtIndex:", .{i});
        const f = objc.msg(objc.CGRect, s, "frame", .{});
        const inside = mouse.x >= f.origin.x and mouse.x < f.origin.x + f.size.width and mouse.y >= f.origin.y and mouse.y < f.origin.y + f.size.height;
        if (inside) return toRect(objc.msg(objc.CGRect, s, "visibleFrame", .{}));
    }
    return mainScreenVisibleFrame();
}

fn primaryScreenHeight() f64 {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return 900;
    const first = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return objc.msg(objc.CGRect, first, "frame", .{}).size.height;
}

extern "c" fn CGWindowListCopyWindowInfo(options: u32, relative_to: u32) ?objc.Object;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: objc.Object, rect: *objc.CGRect) bool;

fn number(dict: objc.Object, key: []const u8) f64 {
    const v = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse return -1;
    return objc.msg(f64, v, "doubleValue", .{});
}

/// System Settings' window on screen, in Cocoa coordinates.
pub fn systemSettingsWindow() ?permission.Rect {
    const pool = objc.Pool.push();
    defer pool.pop();
    // On screen only, without desktop elements.
    const list = CGWindowListCopyWindowInfo((1 << 0) | (1 << 4), 0) orelse return null;
    defer objc.release(list);
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    for (0..n) |i| {
        const info = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        if (number(info, "kCGWindowLayer") != 0 or number(info, "kCGWindowAlpha") <= 0.5) continue;
        const owner = objc.fromNSString(objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kCGWindowOwnerName")}));
        if (std.mem.indexOf(u8, owner, "System Settings") == null and std.mem.indexOf(u8, owner, "System Preferences") == null) continue;
        const bounds = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kCGWindowBounds")}) orelse continue;
        var q: objc.CGRect = .{};
        if (!CGRectMakeWithDictionaryRepresentation(bounds, &q) or q.size.width <= 100 or q.size.height <= 100) continue;
        return permission.quartzToCocoa(toRect(q), primaryScreenHeight());
    }
    return null;
}

/// The bundle this binary runs from, or the binary itself outside one.
pub fn bundlePath() []const u8 {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.fromNSString(objc.msg(?objc.Object, bundle, "bundlePath", .{}));
}

/// An app's icon as PNG at `px` pixels square, in `gpa`'s memory.
pub fn iconPng(gpa: std.mem.Allocator, path: []const u8, px: f64) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const img = objc.msg(objc.Object, workspace(), "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = px, .height = px } };
    const cg = objc.msg(?*anyopaque, img, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    const data = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg([*]const u8, data, "bytes", .{});
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;

/// Gives freed pages back to the system while the panel is hidden.
pub fn releaseFreedMemory() void {
    _ = malloc_zone_pressure_relief(null, 0);
}

/// A native view over the guidance card that starts a drag carrying the
/// app's file URL, as SwiftUI's `.draggable(appURL)`: System Settings' list
/// takes files, and nanoui's own drags carry text.
pub const FileDragSource = struct {
    view: objc.Object,
    path: []const u8,

    pub fn create(parent: objc.Object, path: []const u8) *FileDragSource {
        const cls = objc.defineClass(.{ .name = "FloodlightFileDragSource", .superclass = "NSView", .methods = &.{
            .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
            .{ .name = "mouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
            .{ .name = "acceptsFirstMouse:", .imp = &yes, .types = "c@:@" },
            .{ .name = "mouseDownCanMoveWindow", .imp = &no, .types = "c@:" },
            .{ .name = "resetCursorRects", .imp = &resetCursorRects, .types = "v@:" },
            .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &copyMask, .types = "Q@:@q" },
        } });
        const self = std.heap.c_allocator.create(FileDragSource) catch @panic("out of memory");
        const view = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
        self.* = .{ .view = view, .path = path };
        objc.setZig(view, self);
        objc.msg(void, parent, "addSubview:", .{view});
        return self;
    }

    /// Covers `r`, in the parent's flipped points; hidden when null.
    pub fn place(self: *FileDragSource, r: ?[4]f64) void {
        const f = r orelse return objc.msg(void, self.view, "setHidden:", .{objc.YES});
        objc.msg(void, self.view, "setHidden:", .{objc.NO});
        objc.msg(void, self.view, "setFrame:", .{objc.CGRect{ .origin = .{ .x = f[0], .y = f[1] }, .size = .{ .width = f[2], .height = f[3] } }});
        if (objc.msg(?objc.Object, self.view, "window", .{})) |w| objc.msg(void, w, "invalidateCursorRectsForView:", .{self.view});
    }

    fn yes(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
        return objc.YES;
    }
    fn yes0(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
        return objc.YES;
    }
    fn no(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
        return objc.NO;
    }
    fn copyMask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
        return 1; // NSDragOperationCopy
    }
    fn mouseDown(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {}
    fn resetCursorRects(obj: objc.Object, _: objc.SEL) callconv(.c) void {
        const b = objc.msg(objc.CGRect, obj, "bounds", .{});
        objc.msg(void, obj, "addCursorRect:cursor:", .{ b, objc.msg(objc.Object, objc.class("NSCursor"), "openHandCursor", .{}) });
    }

    fn mouseDragged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
        const self = objc.getZig(FileDragSource, obj) orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const url = fileURL(self.path);
        const icon = objc.msg(objc.Object, workspace(), "iconForFile:", .{objc.nsString(self.path)});
        objc.msg(void, icon, "setSize:", .{objc.CGSize{ .width = 32, .height = 32 }});
        const item = objc.msg(objc.Object, objc.alloc("NSDraggingItem"), "initWithPasteboardWriter:", .{url});
        defer objc.release(item);
        const at = objc.msg(objc.CGPoint, obj, "convertPoint:fromView:", .{ objc.msg(objc.CGPoint, event, "locationInWindow", .{}), @as(?objc.Object, null) });
        objc.msg(void, item, "setDraggingFrame:contents:", .{ objc.CGRect{ .origin = .{ .x = at.x - 16, .y = at.y - 16 }, .size = .{ .width = 32, .height = 32 } }, icon });
        const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{item});
        _ = objc.msg(?objc.Object, obj, "beginDraggingSessionWithItems:event:source:", .{ items, event, obj });
    }
};
