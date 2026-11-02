//! Everything that talks to macOS past what nanoui covers: the global
//! hotkey, the glass slab behind the panel, NSWorkspace, the Full Disk
//! Access probe, System Settings' window, and a drag that carries a file.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const permission = @import("permission.zig");

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
    const keyboard_class: u32 = 0x6b657962; // 'keyb'
    const hot_key_pressed: u32 = 5;
    const option_key: u32 = 1 << 11;
    const space: u32 = 49;
};

var hotkey_fn: ?*const fn (?*anyopaque) void = null;
var hotkey_ctx: ?*anyopaque = null;

fn onHotKey(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    if (hotkey_fn) |f| f(hotkey_ctx);
    return 0;
}

/// ⌥Space, so ⌘Space stays Spotlight's. Runs `f` on the main thread.
pub fn registerHotKey(ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) !void {
    hotkey_fn = f;
    hotkey_ctx = ctx;
    const target = carbon.GetApplicationEventTarget();
    const spec: carbon.EventTypeSpec = .{ .class = carbon.keyboard_class, .kind = carbon.hot_key_pressed };
    if (carbon.InstallEventHandler(target, &onHotKey, 1, &spec, null, null) != 0) return error.HotKeyHandler;
    var ref: ?*anyopaque = null;
    const id: carbon.HotKeyId = .{ .signature = 0x464c6e75, .id = 1 }; // 'FLnu'
    if (carbon.RegisterEventHotKey(carbon.space, carbon.option_key, id, target, 0, &ref) != 0) return error.HotKeyTaken;
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

pub fn open(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.BOOL, workspace(), "openURL:", .{fileURL(path)});
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
