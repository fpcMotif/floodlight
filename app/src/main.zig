//! Nanospot on nanoui: a menu-bar agent with a search panel on ⌥Space and
//! the Full Disk Access grant flow, over the Zig core's file index.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const search = @import("search.zig");
const shell_mod = @import("shell.zig");
const permission = @import("permission.zig");
const mac = @import("mac.zig");
const clipboard = @import("clipboard.zig");
const chrome = @import("chrome.zig");
const presence = @import("presence.zig");
const memory_probe = @import("memory_probe.zig");
const latency_probe = @import("latency_probe.zig");

const metrics = chrome.metrics;
const gpa = std.heap.c_allocator;
const clipboard_poll_ms = 500;
const suggest_debounce_ms = 150;
const resize_redraw_ms = 50;
const entrance_timeout_ms = 250;
const entrance_alpha = 0.01;
const compact_next_ms = 2000;
const compact_idle_ms = 60 * 60 * 1000;
const prune_ms = 60 * 60 * 1000;

const AppShell = struct {
    catalog: search.Catalog,
    store: clipboard.Store = undefined,
    shell: shell_mod.Shell = undefined,
    panel_window: *nanoui.Window = undefined,
    grant: permission.Grant = .{},
    guide_window: *nanoui.Window = undefined,
    drag: ?*mac.FileDragSource = null,
    compacting: bool = false,
    memory_step: u32 = 0,
    latency: latency_probe.State = .{},
    latency_session: bool = false,

    pub fn apply(s: *AppShell, out: shell_mod.Outcome) void {
        switch (out.window) {
            .none => {},
            .place_unseen => |sz| {
                s.positionOnPointerScreen(sz);
                mac.setAlpha(s.panel_window, entrance_alpha);
                s.panel_window.show();
                mac.drawBeforeOcclusionUpdate(s.panel_window);
            },
            .place_seen => |sz| {
                s.positionOnPointerScreen(sz);
                mac.setAlpha(s.panel_window, 1);
                s.panel_window.show();
                mac.drawBeforeOcclusionUpdate(s.panel_window);
            },
            .place_front => |sz| {
                s.positionOnPointerScreen(sz);
                s.panel_window.show();
            },
            .reveal => mac.setAlpha(s.panel_window, 1),
            .resize => |sz| s.resizeKeepingTop(sz.w, sz.h),
            .hide => {
                const t0 = if (s.latency_session) latency_probe.nowNs() else 0;
                s.panel_window.hide();
                if (s.latency_session) latency_probe.Runner(AppShell).hidden(s, t0);
            },
        }
        switch (out.paste) {
            .none => {},
            .prompt_accessibility => mac.promptAccessibility(),
            .deliver => |pid| if (!mac.deliverPaste(pid)) std.log.err("paste: ⌘V not delivered to pid {d}", .{pid}),
        }
        if (out.release_idle) {
            mac.releaseSurface(s.panel_window);
            if (!s.guide_window.isVisible()) mac.releaseSurface(s.guide_window);
            mac.releaseFreedMemory();
        }
        if (out.entrance_timer) nanoui.App.after(entrance_timeout_ms, s, entranceTimedOut);
        if (out.expiry_ms) |ms| nanoui.App.after(ms, s, expireRetention);
        if (out.actions_menu) |e| s.actionsMenu(e);
        if (out.redraw) s.panel_window.redraw();
    }

    fn hotKey(ctx: ?*anyopaque, which: mac.HotKey) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.apply(s.shell.hotKey(which, s.panel_window.isFocused()));
    }

    fn reopened(ctx: ?*anyopaque) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.apply(s.shell.reopened());
    }

    fn launched(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        mac.handleReopen(s, reopened);
        s.apply(s.shell.launched(s.grant.isGuiding()));
    }

    /// In the frame's own transaction: alpha and pixels land together.
    fn afterFrame(ctx: ?*anyopaque, surface: *nanoui.Surface) bool {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        mac.keepLinkAtDisplayRate(&surface.ctx);
        const presenting = surface.renderer.given_drawable != null;
        if (s.latency_session) latency_probe.Runner(AppShell).frame(s, presenting);
        const out = s.shell.framePresented(presenting);
        if (out.retry_frame) surface.ctx.changed = true;
        if (out.reveal) mac.setAlpha(s.panel_window, 1);
        return out.reveal;
    }

    fn searchWake(ctx: ?*anyopaque) void {
        objc.dispatchMain(ctx, searchLanded);
    }

    fn searchLanded(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.apply(s.shell.pollSearch());
    }

    fn entranceTimedOut(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.apply(s.shell.entranceTimedOut());
    }

    fn expireRetention(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.apply(s.shell.expireRetention());
    }

    fn panelKeyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        if (!w.isFocused() and !s.latency_session) s.apply(s.shell.focusLost(mac.previewVisible()));
    }

    fn onRequest(ctx: ?*anyopaque) void {
        objc.dispatchMain(ctx, applyPanel);
    }

    fn applyPanel(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        if (s.latency_session) latency_probe.Runner(AppShell).applyBegin(s);
        s.apply(s.shell.applyPending());
        if (s.latency_session) latency_probe.Runner(AppShell).applyEnd(s);
    }

    fn timedOpen(ctx: ?*anyopaque, target: []const u8) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        const t0 = latency_probe.nowNs();
        mac.open(target);
        latency_probe.Runner(AppShell).actionHanded(s, t0, latency_probe.nowNs());
    }

    fn positionOnPointerScreen(s: *AppShell, sz: shell_mod.Size) void {
        const screen = mac.pointerScreenVisibleFrame();
        s.panel_window.setSize(sz.w, sz.h);
        const f = mac.frameOf(s.panel_window);
        mac.setFrameOrigin(s.panel_window, presence.panelFrame(screen, f.w, f.h));
    }

    /// Keeps the top edge and the horizontal centre where they are.
    fn resizeKeepingTop(s: *AppShell, w: f32, h: f32) void {
        const f = mac.frameOf(s.panel_window);
        if (@abs(f.h - h) < 0.5 and @abs(f.w - w) < 0.5) return;
        const t0 = if (s.latency_session) latency_probe.nowNs() else 0;
        const top = f.y + f.h;
        const mid = f.x + f.w / 2;
        s.panel_window.setSize(w, h);
        mac.setFrameOrigin(s.panel_window, .{ .x = mid - w / 2, .y = top - h, .w = w, .h = h });
        nanoui.App.after(resize_redraw_ms, s, redrawPanel);
        if (s.latency_session) latency_probe.Runner(AppShell).resized(s, t0, latency_probe.nowNs());
    }

    fn redrawPanel(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        if (s.latency_session) latency_probe.Runner(AppShell).resizeRedrawFired(s);
        s.panel_window.redraw();
    }

    fn actionsMenu(s: *AppShell, e: clipboard.Entry) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const items = s.shell.boardMenuItems(arena.allocator(), e);
        const f = mac.frameOf(s.panel_window);
        const at = [2]f64{ f.w - metrics.well_inset - 110, f.h - metrics.well_inset - metrics.footer_height };
        const idx = mac.popUpMenu(s.panel_window, &items, at) orelse return;
        const choice = shell_mod.BoardMenuChoice.fromIndex(idx) orelse return;
        s.apply(s.shell.applyBoardMenu(e, choice));
    }

    fn captureTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(clipboard_poll_ms, s, captureTick);
        s.apply(s.shell.captureTick());
    }

    const CompactJob = struct {
        app: *AppShell,
        images: []const u8,
        job: clipboard.Compaction,
        avif_bytes: ?usize = null,
    };

    fn compactTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        if (!s.shell.isHidden() or s.compacting) return nanoui.App.after(compact_next_ms, s, compactTick);
        const job = s.store.nextCompaction(clipboard.wallClock()) orelse return nanoui.App.after(compact_idle_ms, s, compactTick);
        const state = gpa.create(CompactJob) catch {
            std.log.err("clipboard compaction: out of memory", .{});
            return nanoui.App.after(compact_idle_ms, s, compactTick);
        };
        state.* = .{ .app = s, .images = s.store.images, .job = job };
        s.compacting = true;
        const th = std.Thread.spawn(.{}, compactWorker, .{state}) catch |err| {
            s.compacting = false;
            gpa.destroy(state);
            std.log.err("clipboard compaction: no worker thread: {s}", .{@errorName(err)});
            return nanoui.App.after(compact_idle_ms, s, compactTick);
        };
        th.detach();
    }

    fn compactWorker(state: *CompactJob) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        state.avif_bytes = clipboard.recompress(state.images, arena.allocator(), state.job, mac.compactImage);
        objc.dispatchMain(state, compactionLanded);
    }

    fn compactionLanded(ctx: ?*anyopaque) callconv(.c) void {
        const state: *CompactJob = @ptrCast(@alignCast(ctx));
        const s = state.app;
        const job = state.job;
        const avif_bytes = state.avif_bytes;
        gpa.destroy(state);
        s.compacting = false;
        s.store.finishCompaction(job, avif_bytes);
        nanoui.App.after(compact_next_ms, s, compactTick);
    }

    fn pruneTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(prune_ms, s, pruneTick);
        s.shell.pruneClipboard();
    }

    const SuggestRequest = struct {
        app: *AppShell,
        seq: u64,
        query: []u8,
    };

    fn onSuggest(ctx: ?*anyopaque, seq: u64, query: []const u8) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        const q_copy = gpa.dupe(u8, query) catch return;
        const req = gpa.create(SuggestRequest) catch {
            gpa.free(q_copy);
            return;
        };
        req.* = .{ .app = s, .seq = seq, .query = q_copy };
        nanoui.App.after(suggest_debounce_ms, req, sendSuggest);
    }

    fn sendSuggest(ctx: ?*anyopaque) callconv(.c) void {
        const req: *SuggestRequest = @ptrCast(@alignCast(ctx));
        const s = req.app;
        if (!s.shell.shouldSendSuggest(req.seq)) {
            gpa.free(req.query);
            gpa.destroy(req);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const url = search.webSuggestUrl(arena.allocator(), std.mem.trim(u8, req.query, " \t\r\n")) catch {
            gpa.free(req.query);
            gpa.destroy(req);
            return;
        };
        nanoui.http.fetch(gpa, .{ .url = url }, req, receiveSuggest);
    }

    fn receiveSuggest(req: *SuggestRequest, res: nanoui.http.Response) void {
        defer {
            gpa.free(req.query);
            gpa.destroy(req);
        }
        if (res.err.len > 0 or res.status != 200) return;
        const s = req.app;
        s.apply(s.shell.receiveSuggestions(req.seq, req.query, res.body));
    }

    fn applyGrant(s: *AppShell, out: permission.Outcome) void {
        if (out.open_settings) mac.openFullDiskAccessSettings();
        switch (out.window) {
            .keep => {},
            .show => |r| {
                mac.setFrameOrigin(s.guide_window, r);
                mac.orderFrontRegardless(s.guide_window);
                s.guide_window.redraw();
            },
            .move => |r| mac.setFrameOrigin(s.guide_window, r),
            .redraw => s.guide_window.redraw(),
            .hide => s.guide_window.hide(),
        }
        if (out.drag.rect()) |r| if (s.drag) |d| d.place(r);
        if (out.poll_ms) |ms| nanoui.App.after(ms, s, grantPoll);
        if (out.linger_ms) |ms| nanoui.App.after(ms, s, grantLinger);
        if (out.rebuild_index) s.apply(s.shell.rebuildIndex());
    }

    fn grantAnchors(ctx: ?*anyopaque) permission.Anchors {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        return .{
            .settings = mac.systemSettingsWindow(),
            .parent = if (s.panel_window.isVisible()) mac.frameOf(s.panel_window) else null,
            .screen = mac.mainScreenVisibleFrame(),
        };
    }

    fn onGrantRequest(ctx: ?*anyopaque) void {
        objc.dispatchMain(ctx, flushGrant);
    }

    fn flushGrant(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.applyGrant(s.grant.applyPending());
    }

    fn grantPoll(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.applyGrant(s.grant.poll(mac.fullDiskAccessGranted()));
    }

    fn grantLinger(ctx: ?*anyopaque) callconv(.c) void {
        const s: *AppShell = @ptrCast(@alignCast(ctx));
        s.applyGrant(s.grant.lingerTimedOut());
    }
};

pub fn main(init: std.process.Init) !void {
    const t_launch0 = latency_probe.nowNs();
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const support = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/Nanospot" });
    defer gpa.free(support);
    try std.Io.Dir.cwd().createDirPath(init.io, support);
    const index_path = try std.fs.path.joinZ(gpa, &.{ support, "names.flix" });
    defer gpa.free(index_path);

    const app = try nanoui.App.create(init, .{ .name = "Nanospot", .quit_on_last_window_closed = false });
    defer app.destroy();
    mac.becomeAccessory(app.nsapp);
    // Snapshots and hidden runs draw the panel and touch nothing else: no
    // hotkey, no System Settings, no scan of the home folder, no history on disk.
    const headless = app.flags.hidden or app.flags.snapshot != null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const memory_session = memory_probe.hasFlag(args, memory_probe.session_flag);
    const memory_seed = memory_probe.hasFlag(args, memory_probe.seed_flag);
    const latency_session = memory_probe.hasFlag(args, latency_probe.session_flag);
    const latency_rounds = if (latency_session) latency_probe.resolveRoundsOrExit() else latency_probe.default_rounds;

    var shell: AppShell = .{ .catalog = .{ .gpa = gpa }, .latency_session = latency_session };
    shell.latency.rounds = latency_rounds;
    shell.latency.measure_open = memory_probe.hasFlag(args, latency_probe.open_flag);
    defer shell.catalog.deinit();
    const t_index0 = latency_probe.nowNs();
    try shell.catalog.openIndex(index_path, home);
    const index_open_ns = latency_probe.nowNs() -| t_index0;
    const t_apps0 = latency_probe.nowNs();
    for (search.app_folders) |f| try search.scanApps(&shell.catalog, init.io, f);
    const user_apps = try std.fs.path.join(gpa, &.{ home, "Applications" });
    defer gpa.free(user_apps);
    try search.scanApps(&shell.catalog, init.io, user_apps);
    const app_scan_ns = latency_probe.nowNs() -| t_apps0;

    const store_path = try std.fs.path.joinZ(gpa, &.{ support, "clipboard.sqlite3" });
    defer gpa.free(store_path);
    const images_path = try std.fs.path.join(gpa, &.{ support, "clipboard-images" });
    defer gpa.free(images_path);
    const tmp = std.mem.trimEnd(u8, std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp"), "/");
    const scratch_images = try std.fmt.allocPrint(gpa, "{s}/nanospot-{d}-images", .{ tmp, std.c.getpid() });
    defer gpa.free(scratch_images);
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch_images) catch {};
    const t_clip_open0 = latency_probe.nowNs();
    shell.store = if (headless)
        try clipboard.Store.open(":memory:", scratch_images)
    else
        clipboard.Store.open(store_path, images_path) catch |err| fallback: {
            std.log.err("clipboard history: {s} at {s}; keeping this session's in memory", .{ @errorName(err), store_path });
            break :fallback try clipboard.Store.open(":memory:", scratch_images);
        };
    const clipboard_open_ns = latency_probe.nowNs() -| t_clip_open0;
    defer shell.store.close();
    const t_prune0 = latency_probe.nowNs();
    shell.store.prune(clipboard.wallClock(), clipboard.retention_days) catch |err| std.log.err("clipboard prune: {s}", .{@errorName(err)});
    const clipboard_prune_ns = latency_probe.nowNs() -| t_prune0;
    if (memory_seed) return memory_probe.seedMemoryHistory(gpa, shell.store);

    var host = shell_mod.macHost(&shell, AppShell.onRequest, if (headless) shell_mod.noSuggest else AppShell.onSuggest);
    if (latency_session) host.open = AppShell.timedOpen;
    shell.shell.init(
        gpa,
        &shell.catalog,
        &shell.store,
        host,
    );
    defer shell.shell.deinit();
    if (!headless) {
        shell.catalog.startWorker(init.io, .{ .ctx = &shell, .wake = AppShell.searchWake });
    }
    if (nanoui.kv.standard().get(gpa, "web_suggestions") catch null) |v| {
        defer gpa.free(v);
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) {
            shell.shell.panel.setWebSuggestionsEnabled(false);
        }
    }
    const initial_height: f32 = if (app.flags.snapshot != null and app.flags.script.len > 0)
        metrics.expanded_height
    else
        metrics.search_height;
    shell.panel_window = try app.newWindow(.{
        .title = "Nanospot",
        .width = metrics.width,
        .height = initial_height,
        .min_height = metrics.search_height,
        .decorations = false,
        .resizable = false,
        .kind = .panel,
        .non_activating = true,
        .all_spaces = true,
        .skip_taskbar = true,
        .visible = false,
        .on_key = .{ .ctx = &shell, .func = AppShell.panelKeyChanged },
        .content = .{ .view = shell.shell.view() },
    });
    _ = mac.installSlab(shell.panel_window, metrics.corner_radius, .status, .clear);
    if (shell.panel_window.surface) |surface| {
        surface.after_frame = AppShell.afterFrame;
        surface.after_frame_ctx = &shell;
    }

    const t_guide0 = latency_probe.nowNs();
    const guide_icon = mac.iconPng(gpa, mac.bundlePath(), 44);
    defer if (guide_icon) |p| gpa.free(p);
    shell.grant = .{
        .icon_png = guide_icon,
        .read_anchors = AppShell.grantAnchors,
        .on_request = AppShell.onGrantRequest,
        .ctx = &shell,
    };
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
        .content = .{ .view = shell.grant.view() },
    });
    if (mac.installSlab(shell.guide_window, permission.metrics.radius, .floating, .regular)) |guide_host| shell.drag = mac.FileDragSource.create(guide_host, mac.bundlePath());
    const guide_window_ns = latency_probe.nowNs() -| t_guide0;

    if (!headless) {
        try mac.registerHotKeys(&shell, AppShell.hotKey);
        shell.shell.syncPasteboardCount();
        nanoui.App.after(clipboard_poll_ms, &shell, AppShell.captureTick);
        nanoui.App.after(compact_next_ms, &shell, AppShell.compactTick);
        nanoui.App.after(prune_ms, &shell, AppShell.pruneTick);
        shell.applyGrant(shell.grant.begin(mac.fullDiskAccessGranted()));
        nanoui.App.after(0, &shell, if (memory_session)
            memory_probe.Runner(AppShell).launched
        else if (latency_session)
            latency_probe.Runner(AppShell).launched
        else
            AppShell.launched);
    }
    if (latency_session) {
        shell.latency.index_entries = if (shell.catalog.files) |*fi| if (fi.view()) |v| v.count() else 0 else 0;
        shell.latency.launch = .{
            .index_open_ns = index_open_ns,
            .app_scan_ns = app_scan_ns,
            .clipboard_open_ns = clipboard_open_ns,
            .clipboard_prune_ns = clipboard_prune_ns,
            .guide_window_ns = guide_window_ns,
            .total_ns = latency_probe.nowNs() -| t_launch0,
        };
    }
    try app.run();
}
