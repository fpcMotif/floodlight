//! Window placement, Liquid Glass slab, signposts, screen geometry, and surface memory release.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const permission = @import("../permission.zig");

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

const OsLog = *opaque {};
extern "c" fn _dyld_get_prog_image_header() *const anyopaque;
extern "c" fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) OsLog;
extern "c" fn os_signpost_enabled(log: OsLog) bool;
extern "c" fn _os_signpost_emit_with_name_impl(
    dso: *const anyopaque,
    log: OsLog,
    kind: u8,
    spid: u64,
    name: [*:0]const u8,
    format: [*:0]const u8,
    buf: [*]u8,
    size: u32,
) void;

pub const Signpost = enum {
    summon,
    keystroke,
    submit,
};

const signpost_begin: u8 = 1;
const signpost_end: u8 = 2;
const signpost_exclusive_id: u64 = 0xeeeeb0b5b2b2eeee;

var signpost_log: ?OsLog = null;
var signpost_dso: ?*const anyopaque = null;

fn signpostLog() OsLog {
    if (signpost_log) |l| return l;
    const l = os_log_create("com.nanospot.app", "PointsOfInterest");
    signpost_log = l;
    signpost_dso = _dyld_get_prog_image_header();
    return l;
}

// `logd` resolves signpost strings only from `__TEXT,__oslogstring`; `export`
// keeps ReleaseFast from merging them into `__TEXT,__const`.
export const ns_signpost_fmt: [0:0]u8 align(1) linksection("__TEXT,__oslogstring") = "".*;
export const ns_signpost_summon: [33:0]u8 align(1) linksection("__TEXT,__oslogstring") = "hot key → first presented frame".*;
const signpost_keystroke_name = "keystroke → presented frame";
export const ns_signpost_keystroke: [signpost_keystroke_name.len:0]u8 align(1) linksection("__TEXT,__oslogstring") = signpost_keystroke_name.*;
export const ns_signpost_submit: [33:0]u8 align(1) linksection("__TEXT,__oslogstring") = "Return → action handed to macOS".*;

fn signpostEmit(s: Signpost, kind: u8) void {
    const log = signpostLog();
    if (!os_signpost_enabled(log)) return;
    var buf: [2]u8 align(16) = .{ 0, 0 };
    const name: [*:0]const u8 = switch (s) {
        .summon => &ns_signpost_summon,
        .keystroke => &ns_signpost_keystroke,
        .submit => &ns_signpost_submit,
    };
    _os_signpost_emit_with_name_impl(signpost_dso.?, log, kind, signpost_exclusive_id, name, &ns_signpost_fmt, &buf, buf.len);
}

pub fn signpostBegin(s: Signpost) void {
    signpostEmit(s, signpost_begin);
}

pub fn signpostEnd(s: Signpost) void {
    signpostEmit(s, signpost_end);
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

fn hostIsFlipped(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

/// Puts the panel's content on a clear Liquid Glass slab (NSGlassEffectView,
/// macOS 26) that refracts the desktop behind it; a HUD material where glass
/// isn't available or transparency is reduced.
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
    const host_class = objc.defineClass(.{ .name = "NanospotHostView", .superclass = "NSView", .methods = &.{
        .{ .name = "isFlipped", .imp = &hostIsFlipped, .types = "c@:" },
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

extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;

/// Gives freed pages back to the system while the panel is hidden.
pub fn releaseFreedMemory() void {
    _ = malloc_zone_pressure_relief(null, 0);
}

pub fn releaseSurface(window: *nanoui.Window) void {
    const s = window.surface orelse return;
    if (s.is_visible) return;
    if (!s.released) {
        s.released = true;
        s.renderer.resize(.{ .w = 1, .h = 1 }, s.scale);
    }
    s.pending = true;
    s.text.images.trimDecoded();
    s.renderer.waitIdle();
    forgetImageAtlas(s);
    forgetFrameBuffers(s);
    forgetFrameStorage(s);
    _ = s.ctx.arena.reset(.{ .retain_with_limit = 64 * 1024 });
}

fn forgetFrameBuffers(s: *nanoui.Surface) void {
    s.instances.clearAndFree(s.gpa);
    for (&s.renderer.buffers, &s.renderer.capacities) |*buffer, *capacity| {
        if (buffer.*) |b| objc.release(b);
        buffer.* = null;
        capacity.* = 0;
    }
}

pub fn forgetContextStorage(c: *nanoui.ui.Context) void {
    c.nodes.clearAndFree(c.gpa);
    c.stack.clearAndFree(c.gpa);
    c.rects.clearAndFree(c.gpa);
    c.prev_rects.clearAndFree(c.gpa);
    c.hits.clearAndFree(c.gpa);
    c.next_hits.clearAndFree(c.gpa);
    c.a11y_items.clearAndFree(c.gpa);
    c.helps.clearAndFree(c.gpa);
    c.motion.entries.clearAndFree(c.gpa);
    c.anims.clearAndFree(c.gpa);
}

fn freeTextLayouts(gpa: std.mem.Allocator, map: anytype) void {
    var it = map.valueIterator();
    while (it.next()) |l| gpa.free(l.glyphs);
    map.clearAndFree(gpa);
}

fn forgetFrameStorage(s: *nanoui.Surface) void {
    forgetContextStorage(&s.ctx);
    freeTextLayouts(s.text.gpa, &s.text.layouts);
    freeTextLayouts(s.text.gpa, &s.text.previous);
    s.text.wraps.deinit(s.text.gpa);
    s.text.wraps = .{};
}

fn forgetImageAtlas(s: *nanoui.Surface) void {
    const texture = s.renderer.images_texture orelse return;
    objc.release(texture);
    s.renderer.images_texture = null;
    s.renderer.images_generation = std.math.maxInt(u64);
    const im = &s.text.images;
    im.entries.clearAndFree(im.gpa);
    im.shelf_x = 0;
    im.shelf_y = 0;
    im.shelf_h = 0;
    im.resets +%= 1;
}

pub fn drawBeforeOcclusionUpdate(window: *nanoui.Window) void {
    const s = window.surface orelse return;
    if (s.released) {
        s.released = false;
        s.renderer.resize(s.size, s.scale);
    }
    s.is_visible = true;
}
