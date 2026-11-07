//! Floodlight on nanoui: a menu-bar agent with a search panel on ⌥Space and
//! the Full Disk Access grant flow, over the Zig core's file index.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const search = @import("search.zig");
const panel_mod = @import("panel.zig");
const permission = @import("permission.zig");
const mac = @import("mac.zig");
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");
const chrome = @import("chrome.zig");
const file_index = @import("floodlight_core").file_index;
const FileIndex = file_index.FileIndex;
const presence = @import("presence.zig");
const Presence = presence.Presence;

const metrics = chrome.metrics;
const gpa = std.heap.smp_allocator;
const clipboard_poll_ms = 500;
const resize_redraw_ms = 50;
const entrance_timeout_ms = 250;
const compact_next_ms = 2000;
const compact_idle_ms = 60 * 60 * 1000;

/// Icons drawn per session at most; all go when the panel hides.
const max_icons = 64;

const Shell = struct {
    files: FileIndex,
    catalog: search.Catalog,
    panel: panel_mod.Panel = undefined,
    panel_window: *nanoui.Window = undefined,
    guidance: permission.Guidance = undefined,
    guide_window: *nanoui.Window = undefined,
    flow: permission.Flow = undefined,
    drag: ?*mac.FileDragSource = null,
    icons: std.StringHashMapUnmanaged([]u8) = .empty,
    polling: bool = false,
    store: clipboard.Store = undefined,
    change_count: objc.NSInteger = 0,
    /// The app that was frontmost when the panel opened: Return pastes there.
    paste_target: mac.RunningApp = .{},
    presence: Presence = undefined,

    fn hotKey(ctx: ?*anyopaque, which: mac.HotKey) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        const focused = s.panel_window.isFocused();
        switch (which) {
            .search => s.presence.search(focused),
            .clipboard => {
                s.presence.board(focused, s.panel.mode == .clipboard);
                if (!s.presence.isHidden()) s.panel_window.redraw();
            },
        }
    }

    fn runPresence(ctx: ?*anyopaque, e: presence.Effect) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        switch (e) {
            .note_paste_target => s.notePasteTarget(),
            .place => s.positionOnPointerScreen(),
            .open_board => s.openBoard(),
            .order_in_unseen => {
                mac.setAlpha(s.panel_window, 0);
                s.panel_window.show();
            },
            .order_front => s.panel_window.show(),
            .start_entrance_timer => nanoui.App.after(entrance_timeout_ms, s, entranceTimedOut),
            .reveal => mac.setAlpha(s.panel_window, 1),
            .hide_window => s.panel_window.hide(),
            .end_session => s.endSession(),
            .deliver_paste => deliverPaste(s.paste_target.pid),
        }
    }

    fn openBoard(s: *Shell) void {
        s.panel.showClipboard();
        s.panel.board.paste_target = if (s.paste_target.pid != 0 and mac.canDeliverPaste()) s.paste_target.name else "";
        s.panel.board.now = clipboard.wallClock();
    }

    fn deliverPaste(pid: i32) void {
        if (pid == 0) return;
        if (!mac.canDeliverPaste()) return mac.promptAccessibility();
        if (!mac.deliverPaste(pid)) std.log.err("paste: ⌘V not delivered to pid {d}", .{pid});
    }

    fn notePasteTarget(s: *Shell) void {
        const front = mac.frontmostApp(gpa);
        if (front.pid == 0 or front.pid == mac.ownPid()) return;
        gpa.free(s.paste_target.bundle_id);
        gpa.free(s.paste_target.name);
        s.paste_target = front;
    }

    fn reopened(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.presence.reopened();
    }

    fn launched(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        mac.handleReopen(s, reopened);
        s.presence.launched(s.flow.phase == .guiding);
    }

    /// In the frame's own transaction: alpha and pixels land together.
    fn afterFrame(ctx: ?*anyopaque, surface: *nanoui.Surface) bool {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        mac.keepLinkAtDisplayRate(&surface.ctx);
        return s.presence.framePresented(surface.renderer.given_drawable != null);
    }

    fn entranceTimedOut(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.presence.entranceTimedOut();
    }

    fn positionOnPointerScreen(s: *Shell) void {
        const screen = mac.pointerScreenVisibleFrame();
        s.panel_window.setSize(s.panel.panelWidth(), s.panel.panelHeight());
        const f = mac.frameOf(s.panel_window);
        mac.setFrameOrigin(s.panel_window, .{ .x = screen.x + (screen.w - f.w) / 2, .y = screen.y + screen.h * 0.68 - f.h / 2, .w = f.w, .h = f.h });
    }

    /// Keeps the top edge and the horizontal centre where they are.
    fn resizeKeepingTop(s: *Shell, w: f32, h: f32) void {
        const f = mac.frameOf(s.panel_window);
        if (@abs(f.h - h) < 0.5 and @abs(f.w - w) < 0.5) return;
        const top = f.y + f.h;
        const mid = f.x + f.w / 2;
        s.panel_window.setSize(w, h);
        mac.setFrameOrigin(s.panel_window, .{ .x = mid - w / 2, .y = top - h, .w = w, .h = h });
        nanoui.App.after(resize_redraw_ms, s, redrawPanel);
    }

    fn redrawPanel(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.panel_window.redraw();
    }

    fn endSession(s: *Shell) void {
        s.panel.reset();
        var it = s.icons.iterator();
        while (it.next()) |e| gpa.free(e.value_ptr.*);
        s.icons.clearRetainingCapacity();
        mac.releaseFreedMemory();
    }

    fn panelKeyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (!w.isFocused()) s.presence.focusLost(mac.previewVisible());
    }

    fn panelRequest(ctx: ?*anyopaque) void {
        objc.dispatchMain(ctx, applyPanel);
    }

    fn applyPanel(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.panel.pending) |a| {
            s.panel.pending = null;
            switch (a) {
                .open => |path| mac.open(path),
                .reveal => |path| mac.reveal(path),
                .copy => |row| mac.copy(row.path),
                .hide => {},
                .clipboard => |b| s.applyBoard(b),
            }
            s.presence.settle(a);
            if (!s.presence.isHidden()) s.panel_window.redraw();
            return;
        }
        s.resizeKeepingTop(s.panel.width, s.panel.height);
    }

    /// Carries out a board action; `Presence.settle` decides whether the panel hides.
    fn applyBoard(s: *Shell, a: board_mod.Action) void {
        switch (a) {
            .paste, .copy => |e| s.writeEntry(e),
            .reveal => |path| mac.reveal(path),
            .preview => |e| s.preview(e),
            .actions => |e| s.actionsMenu(e),
        }
    }

    fn applyAndSettle(s: *Shell, a: board_mod.Action) void {
        s.applyBoard(a);
        s.presence.settle(.{ .clipboard = a });
    }

    fn writeEntry(s: *Shell, e: clipboard.Entry) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const png = if (e.kind == .image) s.store.image(arena.allocator(), e.id) else null;
        mac.writeClipboard(e.kind, e.filePath() orelse e.text, png);
        // The marker keeps capture from storing it again; this keeps the count current.
        s.change_count = mac.pasteboardChangeCount();
    }

    fn preview(s: *Shell, e: clipboard.Entry) void {
        if (e.filePath()) |path| return mac.togglePreview(path);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const stored = s.store.image(arena.allocator(), e.id) orelse e.thumbnail;
        const png = mac.pngBytes(arena.allocator(), stored) orelse e.thumbnail;
        const path = mac.previewFile(gpa, e.id, png) orelse return;
        defer gpa.free(path);
        mac.togglePreview(path);
    }

    fn actionsMenu(s: *Shell, e: clipboard.Entry) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const cmd = mac.command_modifier;
        const items = [_]mac.MenuItem{
            .{ .title = s.panel.board.pasteLabel(arena.allocator()), .key = "\r", .modifiers = 0 },
            .{ .title = "Copy", .key = "c", .modifiers = cmd },
            .{ .title = "Quick Look", .key = " ", .modifiers = 0, .enabled = s.panel.board.previewable(e), .separator_before = true },
            .{ .title = "Show in Finder", .key = "r", .modifiers = cmd, .enabled = e.filePath() != null },
            .{ .title = if (e.pinned_at != null) "Unpin" else "Pin", .key = ".", .modifiers = cmd, .separator_before = true },
            .{ .title = "Delete", .key = "d", .modifiers = cmd },
        };
        const f = mac.frameOf(s.panel_window);
        const at = [2]f64{ f.w - board_mod.board_metrics.well_inset - 110, f.h - board_mod.board_metrics.well_inset - board_mod.board_metrics.footer_height };
        const choice = mac.popUpMenu(s.panel_window, &items, at) orelse return;
        switch (choice) {
            0 => s.applyAndSettle(.{ .paste = e }),
            1 => s.writeEntry(e),
            2 => s.preview(e),
            3 => if (e.filePath()) |p| s.applyAndSettle(.{ .reveal = p }),
            4 => s.panel.board.togglePin(),
            5 => s.panel.board.delete(),
            else => {},
        }
        s.panel_window.redraw();
    }

    // Clipboard capture: the pasteboard's change count, every half second.

    fn captureTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(clipboard_poll_ms, s, captureTick);
        const count = mac.pasteboardChangeCount();
        if (count == s.change_count) return;
        s.change_count = count;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const front = mac.frontmostApp(arena.allocator());
        var reader = mac.PasteboardReader.begin();
        defer reader.end();
        const app: clipboard.App = .{ .bundle_id = front.bundle_id, .name = front.name };
        const stored = s.store.capture(arena.allocator(), reader.pasteboard(), app, clipboard.wallClock()) catch |err| blk: {
            std.log.err("clipboard capture: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (!stored or s.panel.mode != .clipboard) return;
        s.panel.board.list.markStale();
        s.panel.board.now = clipboard.wallClock();
        s.panel.refresh();
        s.panel_window.redraw();
    }

    fn compactTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (!s.presence.isHidden()) return nanoui.App.after(compact_next_ms, s, compactTick);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const more = s.store.compactOne(arena.allocator(), clipboard.wallClock(), mac.compactImage);
        nanoui.App.after(if (more) compact_next_ms else compact_idle_ms, s, compactTick);
    }

    fn detailedDate(_: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 {
        return mac.detailedDate(secs, arena);
    }

    fn describeDate(_: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 {
        return mac.relativeDate(secs, arena);
    }

    fn appIcon(ctx: ?*anyopaque, path: []const u8) ?[]const u8 {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.icons.get(path)) |png| return png;
        if (s.icons.count() >= max_icons) return null;
        const png = mac.iconPng(gpa, path, metrics.top_hit_icon_size * 2) orelse return null;
        const key = gpa.dupe(u8, path) catch return png;
        s.icons.put(gpa, key, png) catch {};
        return png;
    }

    // The grant flow's effects.

    fn isGranted(_: ?*anyopaque) bool {
        return mac.fullDiskAccessGranted();
    }

    fn openSettings(_: ?*anyopaque) void {
        mac.openFullDiskAccessSettings();
    }

    fn present(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.guidance.dismissed = false;
        const parent: ?permission.Rect = if (s.panel_window.isVisible()) mac.frameOf(s.panel_window) else null;
        const want = permission.anchorFrame(mac.systemSettingsWindow(), parent, mac.mainScreenVisibleFrame());
        if (!s.guide_window.isVisible() or permission.shouldMove(mac.frameOf(s.guide_window), want)) mac.setFrameOrigin(s.guide_window, want);
        if (!s.guide_window.isVisible()) mac.orderFrontRegardless(s.guide_window);
        s.guide_window.redraw();
        if (!s.polling) {
            s.polling = true;
            nanoui.App.after(permission.poll_ms, s, pollTick);
        }
    }

    fn close(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.guide_window.hide();
        if (s.drag) |d| d.place(null);
    }

    fn granted(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (!s.guide_window.isVisible()) return s.rebuildIndex();
        s.guide_window.redraw();
        nanoui.App.after(permission.granted_linger_ms, s, lingerDone);
        // Folders that were closed to the scan are open now.
        s.rebuildIndex();
    }

    fn lingerDone(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.flow.phase == .granted) s.flow.dismiss();
    }

    fn pollTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.polling = false;
        s.flow.poll();
    }

    fn guidanceRequest(ctx: ?*anyopaque) void {
        objc.dispatchMain(ctx, applyGuidance);
    }

    fn applyGuidance(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.guidance.dismissed) {
            s.guidance.dismissed = false;
            return s.flow.dismiss();
        }
        const d = s.drag orelse return;
        const r = s.guidance.card orelse return d.place(null);
        d.place(.{ r.x, r.y, r.w, r.h });
    }

    // The file index: the last run's opens at once, a fresh one replaces it.

    fn rebuildIndex(s: *Shell) void {
        const t = std.Thread.spawn(.{}, FileIndex.rebuild, .{ &s.files, file_index.Notify{ .ctx = s, .ready = indexReady } }) catch |err|
            return std.log.err("file index: no rebuild thread: {s}", .{@errorName(err)});
        s.panel.indexing = true;
        t.detach();
    }

    fn indexReady(ctx: ?*anyopaque, outcome: file_index.Outcome) void {
        if (outcome == .failed) std.log.err("file index: {s}", .{@errorName(outcome.failed)});
        objc.dispatchMain(ctx, indexLanded);
    }

    fn indexLanded(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.panel.indexing = s.files.busy();
        if (s.files.adopt()) {
            // The rows answer the old index: ask again.
            s.panel.list.markStale();
            s.panel.refresh();
        }
        s.panel_window.redraw();
    }
};

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const support = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/Floodlight Nano" });
    try std.Io.Dir.cwd().createDirPath(init.io, support);
    const index_path = try std.fs.path.joinZ(gpa, &.{ support, "names.flix" });

    const app = try nanoui.App.create(init, .{ .name = "Floodlight", .quit_on_last_window_closed = false });
    defer app.destroy();
    mac.becomeAccessory(app.nsapp);
    // Snapshots and hidden runs draw the panel and touch nothing else: no
    // hotkey, no System Settings, no scan of the home folder, no history on disk.
    const headless = app.flags.hidden or app.flags.snapshot != null;

    var shell: Shell = .{ .files = try .open(gpa, index_path, home, .{}), .catalog = .{ .gpa = gpa } };
    defer shell.files.close();
    shell.catalog.files = &shell.files;
    defer shell.catalog.deinit();
    for (search.app_folders) |f| try search.scanApps(&shell.catalog, init.io, f);
    try search.scanApps(&shell.catalog, init.io, try std.fs.path.join(gpa, &.{ home, "Applications" }));

    const store_path = try std.fs.path.joinZ(gpa, &.{ support, "clipboard.sqlite3" });
    const images_path = try std.fs.path.join(gpa, &.{ support, "clipboard-images" });
    const tmp = std.mem.trimEnd(u8, std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp"), "/");
    const scratch_images = try std.fmt.allocPrint(gpa, "{s}/floodlight-nano-{d}-images", .{ tmp, std.c.getpid() });
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch_images) catch {};
    shell.store = if (headless)
        try clipboard.Store.open(":memory:", scratch_images)
    else
        clipboard.Store.open(store_path, images_path) catch |err| fallback: {
            std.log.err("clipboard history: {s} at {s}; keeping this session's in memory", .{ @errorName(err), store_path });
            break :fallback try clipboard.Store.open(":memory:", scratch_images);
        };
    defer shell.store.close();
    shell.store.prune(clipboard.wallClock(), clipboard.retention_days) catch |err| std.log.err("clipboard prune: {s}", .{@errorName(err)});

    shell.panel = .init(gpa, &shell.catalog, &shell.store, .{
        .ctx = &shell,
        .request = Shell.panelRequest,
        .app_icon = Shell.appIcon,
        .describe_date = Shell.describeDate,
        .detailed_date = Shell.detailedDate,
    });
    defer shell.panel.deinit();
    shell.panel_window = try app.newWindow(.{
        .title = "Floodlight",
        .width = metrics.width,
        .height = metrics.search_height,
        .min_height = metrics.search_height,
        .decorations = false,
        .resizable = false,
        .kind = .panel,
        .non_activating = true,
        .all_spaces = true,
        .skip_taskbar = true,
        .visible = false,
        .on_key = .{ .ctx = &shell, .func = Shell.panelKeyChanged },
        .content = .{ .view = .init(&shell.panel, panel_mod.Panel.view) },
    });
    _ = mac.installSlab(shell.panel_window, metrics.corner_radius, .status, .clear);
    if (shell.panel_window.surface) |surface| {
        surface.after_frame = Shell.afterFrame;
        surface.after_frame_ctx = &shell;
    }

    shell.flow = .{ .effects = .{
        .ctx = &shell,
        .is_granted = Shell.isGranted,
        .open_settings = Shell.openSettings,
        .present = Shell.present,
        .close = Shell.close,
        .on_granted = Shell.granted,
    } };
    shell.guidance = .{ .phase = &shell.flow.phase, .app_name = "Floodlight Nano", .request = Shell.guidanceRequest, .ctx = &shell };
    shell.guidance.icon_png = mac.iconPng(gpa, mac.bundlePath(), 44);
    shell.guide_window = try app.newWindow(.{
        .title = "Full Disk Access",
        .width = permission.panel_w,
        .height = permission.panel_h,
        .decorations = false,
        .resizable = false,
        .kind = .panel,
        .non_activating = true,
        .all_spaces = true,
        .skip_taskbar = true,
        .visible = false,
        .content = .{ .view = .init(&shell.guidance, permission.Guidance.view) },
    });
    if (mac.installSlab(shell.guide_window, 16, .floating, .regular)) |host| shell.drag = mac.FileDragSource.create(host, mac.bundlePath());

    shell.presence = .{ .effects = .{ .ctx = &shell, .run = Shell.runPresence } };

    if (!headless) {
        try mac.registerHotKeys(&shell, Shell.hotKey);
        shell.change_count = mac.pasteboardChangeCount();
        nanoui.App.after(clipboard_poll_ms, &shell, Shell.captureTick);
        nanoui.App.after(compact_next_ms, &shell, Shell.compactTick);
        // First launch without access: start where the Swift onboarding does.
        if (mac.fullDiskAccessGranted()) shell.rebuildIndex() else shell.flow.begin();
        nanoui.App.after(0, &shell, Shell.launched);
    }
    try app.run();
}
