//! System integration: global hotkeys, NSWorkspace, running apps, paste delivery, menus, TCC, icons, defaults, and file drag.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const pasteboard = @import("pasteboard.zig");

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
    /// ⌥⇧C opens the clipboard board without clashing with ⇧⌘C.
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
        const id: carbon.HotKeyId = .{ .signature = 0x4e537074, .id = @backingInt(k[0]) }; // 'NSpt'
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
    const cls = objc.defineClass(.{ .name = "NanospotReopenTarget", .methods = &.{
        .{ .name = "handleReopen:withReplyEvent:", .imp = &onReopen, .types = "v@:@@" },
    } });
    const target = objc.msg(objc.Object, cls, "new", .{});
    const manager = objc.msg(objc.Object, pasteboard.objc_getClass("NSAppleEventManager").?, "sharedAppleEventManager", .{});
    const core_class: u32 = 0x61657674; // 'aevt'
    const reopen_id: u32 = 0x72617070; // 'rapp'
    objc.msg(void, manager, "setEventHandler:andSelector:forEventClass:andEventID:", .{ target, objc.sel("handleReopen:withReplyEvent:"), core_class, reopen_id });
}

/// A menu-bar agent: no Dock icon, and the panel never steals the menu bar.
pub fn becomeAccessory(nsapp: objc.Object) void {
    _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
}

fn workspace() objc.Object {
    return objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
}

fn isWebUrl(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "http://");
}

fn urlFor(path: []const u8) ?objc.Object {
    if (isWebUrl(path))
        return objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(path)});
    return pasteboard.fileURL(path);
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
    const board = pasteboard.beginWrite();
    const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
    _ = objc.msg(objc.BOOL, board, "writeObjects:", .{items});
    if (isWebUrl(path))
        _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString(path), objc.nsString("public.utf8-plain-text") });
    pasteboard.markOwnWrite(board);
}

pub const RunningApp = struct { pid: i32 = 0, bundle_id: []const u8 = "", name: []const u8 = "" };

/// The frontmost app, with strings owned by `gpa`.
pub fn frontmostApp(gpa: std.mem.Allocator) RunningApp {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.msg(?objc.Object, workspace(), "frontmostApplication", .{}) orelse return .{};
    const id = objc.fromNSString(objc.msg(?objc.Object, app, "bundleIdentifier", .{}));
    const bundle_id = gpa.dupe(u8, id) catch return .{};
    const label = sourceName(id, objc.fromNSString(objc.msg(?objc.Object, app, "localizedName", .{})));
    const name = gpa.dupe(u8, label) catch {
        gpa.free(bundle_id);
        return .{};
    };
    return .{
        .pid = objc.msg(i32, app, "processIdentifier", .{}),
        .bundle_id = bundle_id,
        .name = name,
    };
}

fn sourceName(bundle_id: []const u8, localized: []const u8) []const u8 {
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

/// Brings `pid` forward and posts ⌘V into it.
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
    for ([_]bool{ true, false }) |down| {
        const e = CGEventCreateKeyboardEvent(null, v_key, down) orelse return false;
        defer pasteboard.CFRelease(e);
        CGEventSetFlags(e, command_modifier);
        CGEventPost(0, e);
    }
    return true;
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

pub const MenuItem = struct { title: []const u8, key: []const u8 = "", modifiers: objc.NSUInteger = 0, enabled: bool = true, separator_before: bool = false };

pub const command_modifier: objc.NSUInteger = 1 << 20;

var menu_choice: ?usize = null;

fn menuPicked(_: objc.Object, _: objc.SEL, item: objc.Object) callconv(.c) void {
    menu_choice = std.math.cast(usize, objc.msg(objc.NSInteger, item, "tag", .{}));
}

/// Pops up `items` at `at` (flipped points in `window`'s content) and
/// returns the chosen index once the menu closes.
pub fn popUpMenu(window: *nanoui.Window, items: []const MenuItem, at: [2]f64) ?usize {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{ .name = "NanospotMenuTarget", .methods = &.{
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

pub fn reveal(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{pasteboard.fileURL(path)});
    objc.msg(void, workspace(), "activateFileViewerSelectingURLs:", .{urls});
}

/// Full Disk Access is granted when the TCC database opens: it is readable
/// by nothing else.
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

/// The bundle this binary runs from, or the binary itself outside one.
pub fn bundlePath() []const u8 {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.fromNSString(objc.msg(?objc.Object, bundle, "bundlePath", .{}));
}

extern "c" const kCGColorSpaceSRGB: *const anyopaque;
extern "c" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
extern "c" fn CGContextSetInterpolationQuality(context: *anyopaque, quality: c_int) void;
const bgra_premultiplied: u32 = 2 | (2 << 12);
const cg_interpolation_high: c_int = 3;

pub const Icon = struct {
    bgra: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: Icon, gpa: std.mem.Allocator) void {
        gpa.free(self.bgra);
    }

    pub fn pixels(self: Icon) nanoui.ui.ImageSource.Pixels {
        return .{ .bgra = self.bgra, .width = self.width, .height = self.height };
    }
};

fn iconCgImage(path: []const u8, px: f64) ?*anyopaque {
    const img = objc.msg(objc.Object, workspace(), "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = px, .height = px } };
    return objc.msg(?*anyopaque, img, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) });
}

pub fn iconPixels(gpa: std.mem.Allocator, path: []const u8, px: f64) ?Icon {
    const pool = objc.Pool.push();
    defer pool.pop();
    const side: u32 = @intFromFloat(@max(1.0, @min(1024.0, @ceil(px))));
    const cg = iconCgImage(path, px) orelse return null;
    const iw = pasteboard.CGImageGetWidth(cg);
    const ih = pasteboard.CGImageGetHeight(cg);
    if (iw == 0 or ih == 0) return null;
    const out = gpa.alloc(u8, @as(usize, side) * side * 4) catch return null;
    @memset(out, 0);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse {
        gpa.free(out);
        return null;
    };
    defer pasteboard.CFRelease(space);
    const ctx = pasteboard.CGBitmapContextCreate(out.ptr, side, side, 8, @as(usize, side) * 4, space, bgra_premultiplied) orelse {
        gpa.free(out);
        return null;
    };
    defer pasteboard.CFRelease(ctx);
    CGContextSetInterpolationQuality(ctx, cg_interpolation_high);
    const s_f: f64 = @floatFromInt(side);
    const scale = s_f / @as(f64, @floatFromInt(@max(iw, ih)));
    const dw = @as(f64, @floatFromInt(iw)) * scale;
    const dh = @as(f64, @floatFromInt(ih)) * scale;
    pasteboard.CGContextDrawImage(ctx, .{ .origin = .{ .x = (s_f - dw) * 0.5, .y = (s_f - dh) * 0.5 }, .size = .{ .width = dw, .height = dh } }, cg);
    return .{ .bgra = out, .width = side, .height = side };
}

/// An app's icon as PNG at `px` pixels square, in `gpa`'s memory.
pub fn iconPng(gpa: std.mem.Allocator, path: []const u8, px: f64) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cg = iconCgImage(path, px) orelse return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const data = pasteboard.pngRepresentation(rep) orelse return null;
    return gpa.dupe(u8, pasteboard.dataBytes(data)) catch null;
}

const retention_defaults_key = "sessionRetentionSeconds";

/// Seconds a hidden panel keeps its session (`sessionRetentionSeconds` in
/// user defaults; `default_seconds` when unset, `0` when non-positive).
pub fn retentionSeconds(default_seconds: f64) f64 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const defaults = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const key = objc.nsString(retention_defaults_key);
    if (objc.msg(?objc.Object, defaults, "objectForKey:", .{key}) == null) return default_seconds;
    const raw = objc.msg(f64, defaults, "doubleForKey:", .{key});
    if (!std.math.isFinite(raw)) return default_seconds;
    return std.math.clamp(raw, 0.0, 365.0 * 86400.0);
}

/// A native view over the guidance card that starts a file-URL drag:
/// System Settings' list takes files, and nanoui's own drags carry text.
pub const FileDragSource = struct {
    view: objc.Object,
    path: []const u8,

    pub fn create(parent: objc.Object, path: []const u8) *FileDragSource {
        const cls = objc.defineClass(.{ .name = "NanospotFileDragSource", .superclass = "NSView", .methods = &.{
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
        const url = pasteboard.fileURL(self.path);
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
