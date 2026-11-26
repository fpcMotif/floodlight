//! Windowless controller for Panel Presence, Search Session, Session Retention,
//! Selected-Result Actions, and Clipboard Capture.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const panel_mod = @import("panel.zig");
const board_mod = @import("board.zig");
const clipboard = @import("clipboard.zig");
const presence = @import("presence.zig");
const chrome = @import("chrome.zig");
const mac = @import("mac.zig");

const metrics = chrome.metrics;

/// Icons drawn per session at most; all go when the session is forgotten.
pub const max_icons: usize = 64;

pub const Size = struct {
    w: f32,
    h: f32,
};

pub const WindowOp = union(enum) {
    none,
    place_unseen: Size,
    place_seen: Size,
    place_front: Size,
    reveal,
    resize: Size,
    hide,
};

pub const PasteOp = union(enum) {
    none,
    prompt_accessibility,
    deliver: i32,
};

pub const ActionOp = union(enum) {
    none,
    open: []const u8,
    reveal: []const u8,
};

pub const BoardMenuChoice = enum(u3) {
    paste = 0,
    copy = 1,
    preview = 2,
    reveal = 3,
    toggle_pin = 4,
    delete = 5,

    pub fn fromIndex(i: usize) ?BoardMenuChoice {
        return if (i <= 5) @fromBackingInt(@intCast(i)) else null;
    }
};

pub const Outcome = struct {
    window: WindowOp = .none,
    action: ActionOp = .none,
    paste: PasteOp = .none,
    redraw: bool = false,
    release_idle: bool = false,
    entrance_timer: bool = false,
    expiry_ms: ?u32 = null,
    /// Owned by `Shell.menu_arena` until the next `⌘K` menu opens or `Shell.deinit`.
    actions_menu: ?clipboard.Entry = null,
};

pub const FrameOutcome = struct {
    reveal: bool = false,
    retry_frame: bool = false,
};

pub const ReadPasteboardFn = *const fn (
    ctx: ?*anyopaque,
    turn_ctx: ?*anyopaque,
    run: *const fn (turn_ctx: ?*anyopaque, board: clipboard.Pasteboard) anyerror!bool,
) anyerror!bool;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    clock: clipboard.Clock = .wall_clock,
    on_request: *const fn (ctx: ?*anyopaque) void = noOp,
    on_suggest: *const fn (ctx: ?*anyopaque, seq: u64, query: []const u8) void = noSuggest,
    open: *const fn (ctx: ?*anyopaque, target: []const u8) void = noTarget,
    reveal: *const fn (ctx: ?*anyopaque, path: []const u8) void = noTarget,
    copy: *const fn (ctx: ?*anyopaque, target: []const u8) void = noTarget,
    write_clipboard: *const fn (ctx: ?*anyopaque, kind: clipboard.Kind, text: []const u8, png: ?[]const u8) void = noWriteClipboard,
    /// Returned strings live in `arena`; `Shell` dupes into its own allocator when kept.
    frontmost_app: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) mac.RunningApp = noFrontmostApp,
    own_pid: *const fn (ctx: ?*anyopaque) i32 = noPid,
    can_deliver_paste: *const fn (ctx: ?*anyopaque) bool = notTrusted,
    pasteboard_change_count: *const fn (ctx: ?*anyopaque) isize = zeroChangeCount,
    read_pasteboard: ReadPasteboardFn = noReadPasteboard,
    preview_path: *const fn (ctx: ?*anyopaque, path: []const u8) void = noTarget,
    preview_image: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, id: i64, stored: []const u8, fallback_png: []const u8) void = noPreviewImage,
    icon_pixels: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, px: f64) ?mac.Icon = noIcon,
    relative_date: *const fn (ctx: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 = stubDateI64,
    detailed_date: *const fn (ctx: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 = stubDateF64,
    retention_seconds: ?*const fn (ctx: ?*anyopaque, default_seconds: f64) f64 = null,
};

pub fn noOp(_: ?*anyopaque) void {}
pub fn noSuggest(_: ?*anyopaque, _: u64, _: []const u8) void {}
fn noTarget(_: ?*anyopaque, _: []const u8) void {}
fn noWriteClipboard(_: ?*anyopaque, _: clipboard.Kind, _: []const u8, _: ?[]const u8) void {}
fn noFrontmostApp(_: ?*anyopaque, _: std.mem.Allocator) mac.RunningApp {
    return .{};
}
fn noPid(_: ?*anyopaque) i32 {
    return -1;
}
fn notTrusted(_: ?*anyopaque) bool {
    return false;
}
fn zeroChangeCount(_: ?*anyopaque) isize {
    return 0;
}
fn noReadPasteboard(_: ?*anyopaque, _: ?*anyopaque, _: *const fn (?*anyopaque, clipboard.Pasteboard) anyerror!bool) anyerror!bool {
    return false;
}
fn noPreviewImage(_: ?*anyopaque, _: std.mem.Allocator, _: i64, _: []const u8, _: []const u8) void {}
fn noIcon(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: f64) ?mac.Icon {
    return null;
}
fn stubDateI64(_: ?*anyopaque, _: i64, _: std.mem.Allocator) []const u8 {
    return "Today at 9:41 AM";
}
fn stubDateF64(_: ?*anyopaque, _: f64, _: std.mem.Allocator) []const u8 {
    return "Today at 9:41 AM";
}

/// Production macOS host adapter delegating to `mac.*`.
pub fn macHost(
    ctx: ?*anyopaque,
    on_request: *const fn (?*anyopaque) void,
    on_suggest: *const fn (?*anyopaque, u64, []const u8) void,
) Host {
    return .{
        .ctx = ctx,
        .clock = .wall_clock,
        .on_request = on_request,
        .on_suggest = on_suggest,
        .open = struct {
            fn f(_: ?*anyopaque, target: []const u8) void {
                mac.open(target);
            }
        }.f,
        .reveal = struct {
            fn f(_: ?*anyopaque, path: []const u8) void {
                mac.reveal(path);
            }
        }.f,
        .copy = struct {
            fn f(_: ?*anyopaque, target: []const u8) void {
                mac.copy(target);
            }
        }.f,
        .write_clipboard = struct {
            fn f(_: ?*anyopaque, kind: clipboard.Kind, text: []const u8, png: ?[]const u8) void {
                mac.writeClipboard(kind, text, png);
            }
        }.f,
        .frontmost_app = struct {
            fn f(_: ?*anyopaque, arena: std.mem.Allocator) mac.RunningApp {
                return mac.frontmostApp(arena);
            }
        }.f,
        .own_pid = struct {
            fn f(_: ?*anyopaque) i32 {
                return mac.ownPid();
            }
        }.f,
        .can_deliver_paste = struct {
            fn f(_: ?*anyopaque) bool {
                return mac.canDeliverPaste();
            }
        }.f,
        .pasteboard_change_count = struct {
            fn f(_: ?*anyopaque) isize {
                return mac.pasteboardChangeCount();
            }
        }.f,
        .read_pasteboard = struct {
            fn f(_: ?*anyopaque, turn_ctx: ?*anyopaque, run: *const fn (?*anyopaque, clipboard.Pasteboard) anyerror!bool) anyerror!bool {
                var reader = mac.PasteboardReader.begin();
                defer reader.end();
                return run(turn_ctx, reader.pasteboard());
            }
        }.f,
        .preview_path = struct {
            fn f(_: ?*anyopaque, path: []const u8) void {
                mac.togglePreview(path);
            }
        }.f,
        .preview_image = struct {
            fn f(_: ?*anyopaque, gpa: std.mem.Allocator, id: i64, stored: []const u8, fallback_png: []const u8) void {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const png = mac.pngBytes(arena.allocator(), stored) orelse fallback_png;
                const path = mac.previewFile(gpa, id, png) orelse return;
                defer gpa.free(path);
                mac.togglePreview(path);
            }
        }.f,
        .icon_pixels = struct {
            fn f(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, px: f64) ?mac.Icon {
                return mac.iconPixels(gpa, path, px);
            }
        }.f,
        .relative_date = struct {
            fn f(_: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 {
                return mac.relativeDate(secs, arena);
            }
        }.f,
        .detailed_date = struct {
            fn f(_: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 {
                return mac.detailedDate(secs, arena);
            }
        }.f,
        .retention_seconds = struct {
            fn f(_: ?*anyopaque, default_seconds: f64) f64 {
                return mac.retentionSeconds(default_seconds);
            }
        }.f,
    };
}

pub const Shell = struct {
    gpa: std.mem.Allocator,
    store: ?*const clipboard.Store,
    host: Host,
    panel: panel_mod.Panel,
    presence: presence.Presence,
    icons: std.StringHashMapUnmanaged(mac.Icon) = .empty,
    paste_target: mac.RunningApp = .{},
    change_count: isize = 0,
    submitting: bool = false,
    menu_arena: std.heap.ArenaAllocator,
    active_out: ?*Outcome = null,

    /// Initializes `s` in place; `s` holds self-referential pointers and must not move.
    pub fn init(
        s: *Shell,
        gpa: std.mem.Allocator,
        catalog: *search.Catalog,
        store: ?*const clipboard.Store,
        host: Host,
    ) void {
        s.* = .{
            .gpa = gpa,
            .store = store,
            .host = host,
            .panel = .init(gpa, catalog, store, .{
                .ctx = s,
                .clock = host.clock,
                .request = panelRequest,
                .app_icon = appIcon,
                .describe_date = describeDate,
                .detailed_date = detailedDate,
                .suggest = suggestHook,
            }),
            .presence = .{
                .effects = .{
                    .ctx = s,
                    .run = runPresence,
                    .last_frame_valid = lastFrameValid,
                },
            },
            .menu_arena = .init(gpa),
        };
    }

    pub fn deinit(s: *Shell) void {
        s.endSubmit();
        s.clearIcons();
        s.icons.deinit(s.gpa);
        s.freePasteTarget();
        s.menu_arena.deinit();
        s.panel.deinit();
        s.* = undefined;
    }

    pub fn view(s: *Shell) ui.View {
        return .init(&s.panel, panel_mod.Panel.view);
    }

    pub fn isHidden(s: *const Shell) bool {
        return s.presence.isHidden();
    }

    pub fn panelSize(s: *const Shell) Size {
        return .{ .w = s.panel.panelWidth(), .h = s.panel.panelHeight() };
    }

    pub fn syncPasteboardCount(s: *Shell) void {
        s.change_count = s.host.pasteboard_change_count(s.host.ctx);
    }

    pub fn hotKey(s: *Shell, which: mac.HotKey, focused: bool) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        switch (which) {
            .search => s.presence.search(focused, s.panel.mode == .clipboard),
            .clipboard => s.presence.board(focused, s.panel.mode == .clipboard),
        }
        if (!s.isHidden()) out.redraw = true;
        return out;
    }

    pub fn launched(s: *Shell, guiding: bool) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        s.presence.launched(guiding);
        return out;
    }

    pub fn reopened(s: *Shell) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        s.presence.reopened();
        return out;
    }

    pub fn focusLost(s: *Shell, quick_look_open: bool) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        s.presence.focusLost(quick_look_open);
        return out;
    }

    pub fn entranceTimedOut(s: *Shell) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        s.presence.entranceTimedOut();
        return out;
    }

    pub fn settle(s: *Shell, a: panel_mod.Action) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        s.presence.settle(a);
        if (!s.isHidden()) out.redraw = true;
        return out;
    }

    pub fn framePresented(s: *Shell, presenting: bool) FrameOutcome {
        if (presenting) s.panel.notePresented();
        const retry = !presenting and s.presence.wantsPresentedFrame();
        const revealed = s.presence.framePresented(presenting);
        return .{ .reveal = revealed, .retry_frame = retry };
    }

    pub fn applyPending(s: *Shell) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        if (s.panel.pending) |a| {
            s.panel.pending = null;
            switch (a) {
                .open => |path| out.action = .{ .open = path },
                .reveal => |path| out.action = .{ .reveal = path },
                .copy => |row| s.host.copy(s.host.ctx, row.path),
                .hide, .show_search => {},
                .clipboard => |b| s.applyBoardAction(b, &out),
            }
            s.presence.settle(a);
            if (out.action == .none) s.endSubmit();
            if (!s.isHidden() and out.actions_menu == null) out.redraw = true;
            return out;
        }
        out.window = .{ .resize = .{ .w = s.panel.width, .h = s.panel.height } };
        return out;
    }

    pub fn boardMenuItems(s: *Shell, arena: std.mem.Allocator, e: clipboard.Entry) [6]mac.MenuItem {
        const cmd = mac.command_modifier;
        return .{
            .{ .title = s.panel.board.pasteLabel(arena), .key = "\r", .modifiers = 0 },
            .{ .title = "Copy", .key = "c", .modifiers = cmd },
            .{ .title = "Quick Look", .key = " ", .modifiers = 0, .enabled = s.panel.board.previewable(e), .separator_before = true },
            .{ .title = "Show in Finder", .key = "r", .modifiers = cmd, .enabled = e.filePath() != null },
            .{ .title = if (e.pinned_at != null) "Unpin" else "Pin", .key = ".", .modifiers = cmd, .separator_before = true },
            .{ .title = "Delete", .key = "d", .modifiers = cmd },
        };
    }

    pub fn applyBoardMenu(s: *Shell, e: clipboard.Entry, choice: BoardMenuChoice) Outcome {
        var out: Outcome = .{};
        const prev = s.active_out;
        s.active_out = &out;
        defer s.active_out = prev;

        switch (choice) {
            .paste => {
                s.writeEntry(e);
                s.presence.settle(.{ .clipboard = .{ .paste = e } });
            },
            .copy => s.writeEntry(e),
            .preview => s.previewEntry(e),
            .reveal => if (e.filePath()) |path| {
                out.action = .{ .reveal = path };
                s.presence.settle(.{ .clipboard = .{ .reveal = path } });
            },
            .toggle_pin => s.panel.board.togglePinId(e.id),
            .delete => s.panel.board.deleteId(e.id),
        }
        if (!s.isHidden()) out.redraw = true;
        return out;
    }

    pub fn expireRetention(s: *Shell) Outcome {
        var out: Outcome = .{};
        s.panel.disarmExpiry();
        s.syncRetention();
        if (s.panel.expire()) {
            if (s.isHidden()) {
                s.evictIdleSession();
                out.release_idle = true;
            }
        } else {
            out.expiry_ms = s.panel.armExpiry();
        }
        return out;
    }

    pub fn pollSearch(s: *Shell) Outcome {
        return .{ .redraw = s.panel.poll() and !s.isHidden() };
    }

    pub fn shouldSendSuggest(s: *const Shell, seq: u64) bool {
        return seq != 0 and seq == s.panel.pendingSuggestSeq();
    }

    pub fn receiveSuggestions(s: *Shell, seq: u64, query: []const u8, body: []const u8) Outcome {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const items = search.parseSuggestions(arena.allocator(), body);
        return .{ .redraw = s.panel.receiveSuggestionsFor(seq, query, items) and !s.isHidden() };
    }

    pub fn captureTick(s: *Shell) Outcome {
        var out: Outcome = .{};
        const store = s.store orelse return out;
        const count = s.host.pasteboard_change_count(s.host.ctx);
        if (count == s.change_count) return out;

        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const front = s.host.frontmost_app(s.host.ctx, arena.allocator());
        const turn: CaptureTurn = .{
            .store = store.*,
            .arena = arena.allocator(),
            .app = .{ .bundle_id = front.bundle_id, .name = front.name },
            .now = s.host.clock.now(),
        };
        const stored = s.host.read_pasteboard(s.host.ctx, @ptrCast(@constCast(&turn)), CaptureTurn.run) catch |err| {
            if (!@import("builtin").is_test) std.log.err("clipboard capture: {s}", .{@errorName(err)});
            return out;
        };
        s.change_count = count;
        if (!stored or s.panel.mode != .clipboard) return out;
        s.panel.board.list.markStale();
        if (s.isHidden()) return out;
        s.panel.refresh();
        out.redraw = true;
        return out;
    }

    pub fn pruneClipboard(s: *Shell) void {
        const store = s.store orelse return;
        store.prune(s.host.clock.now(), clipboard.retention_days) catch |err| {
            if (!@import("builtin").is_test) std.log.err("clipboard prune: {s}", .{@errorName(err)});
        };
        if (s.panel.mode == .clipboard) s.panel.board.list.markStale();
    }

    pub fn rebuildIndex(s: *Shell) Outcome {
        s.panel.catalog.rebuildIndex();
        return .{ .redraw = !s.isHidden() };
    }

    const CaptureTurn = struct {
        store: clipboard.Store,
        arena: std.mem.Allocator,
        app: clipboard.App,
        now: f64,

        fn run(raw: ?*anyopaque, board: clipboard.Pasteboard) anyerror!bool {
            const turn: *const CaptureTurn = @ptrCast(@alignCast(raw));
            return turn.store.capture(turn.arena, board, turn.app, turn.now);
        }
    };

    fn applyBoardAction(s: *Shell, a: board_mod.Action, out: *Outcome) void {
        switch (a) {
            .paste, .copy => |e| s.writeEntry(e),
            .open => |url| out.action = .{ .open = url },
            .reveal => |path| out.action = .{ .reveal = path },
            .preview => |e| s.previewEntry(e),
            .actions => |e| if (!s.isHidden()) {
                _ = s.menu_arena.reset(.retain_capacity);
                out.actions_menu = e.dupe(s.menu_arena.allocator()) catch null;
            },
        }
    }

    fn writeEntry(s: *Shell, e: clipboard.Entry) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const png = if (e.kind == .image) if (s.store) |st| st.image(arena.allocator(), e.id) else null else null;
        s.host.write_clipboard(s.host.ctx, e.kind, e.filePath() orelse e.text, png);
        // The marker keeps capture from storing it again; this keeps the count current.
        s.change_count = s.host.pasteboard_change_count(s.host.ctx);
    }

    fn previewEntry(s: *Shell, e: clipboard.Entry) void {
        if (e.filePath()) |path| return s.host.preview_path(s.host.ctx, path);
        const st = s.store orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const stored = st.image(a, e.id) orelse "";
        const thumb = if (stored.len == 0) st.thumbnail(a, e.id) else "";
        s.host.preview_image(s.host.ctx, s.gpa, e.id, stored, thumb);
    }

    fn runPresence(ctx: ?*anyopaque, e: presence.Effect) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        const out = s.active_out;
        switch (e) {
            .note_paste_target => s.notePasteTarget(),
            .place => {},
            .open_search => {
                s.syncRetention();
                s.panel.showSearch();
            },
            .open_board => {
                s.syncRetention();
                s.panel.showClipboard();
                s.panel.board.paste_target = if (s.paste_target.pid != 0 and s.host.can_deliver_paste(s.host.ctx)) s.paste_target.name else "";
            },
            .order_in_unseen => if (out) |o| {
                o.window = .{ .place_unseen = s.panelSize() };
            },
            .order_in_seen => if (out) |o| {
                o.window = .{ .place_seen = s.panelSize() };
            },
            .order_front => if (out) |o| {
                o.window = .{ .place_front = s.panelSize() };
            },
            .start_entrance_timer => if (out) |o| {
                o.entrance_timer = true;
            },
            .reveal => if (out) |o| {
                o.window = .reveal;
            },
            .hide_window => if (out) |o| {
                o.window = .hide;
            },
            .end_session => s.endSession(out),
            .deliver_paste => if (out) |o| {
                if (s.paste_target.pid != 0) {
                    o.paste = if (s.host.can_deliver_paste(s.host.ctx))
                        .{ .deliver = s.paste_target.pid }
                    else
                        .prompt_accessibility;
                }
            },
        }
    }

    fn syncRetention(s: *Shell) void {
        if (s.host.retention_seconds) |f| {
            s.panel.retention_seconds = f(s.host.ctx, panel_mod.default_retention_seconds);
        }
    }

    fn notePasteTarget(s: *Shell) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const front = s.host.frontmost_app(s.host.ctx, arena.allocator());
        if (front.pid == 0 or front.pid == s.host.own_pid(s.host.ctx)) return;
        const bundle_id = if (front.bundle_id.len > 0) (s.gpa.dupe(u8, front.bundle_id) catch "") else "";
        const name = if (front.name.len > 0) (s.gpa.dupe(u8, front.name) catch {
            if (bundle_id.len > 0) s.gpa.free(bundle_id);
            return;
        }) else "";
        s.freePasteTarget();
        s.paste_target = .{ .pid = front.pid, .bundle_id = bundle_id, .name = name };
    }

    fn freePasteTarget(s: *Shell) void {
        if (s.paste_target.bundle_id.len > 0) s.gpa.free(s.paste_target.bundle_id);
        if (s.paste_target.name.len > 0) s.gpa.free(s.paste_target.name);
        s.paste_target = .{};
    }

    fn endSession(s: *Shell, out: ?*Outcome) void {
        if (out == null or out.?.action == .none) s.endSubmit();
        s.syncRetention();
        s.panel.hide();
        if (s.panel.nextExpiryMs() == null) {
            s.evictIdleSession();
            if (out) |o| o.release_idle = true;
            return;
        }
        const ms = s.panel.armExpiry();
        if (out) |o| o.expiry_ms = ms;
    }

    fn evictIdleSession(s: *Shell) void {
        s.panel.forgetPresented();
        s.clearIcons();
    }

    fn clearIcons(s: *Shell) void {
        var it = s.icons.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(s.gpa);
        }
        s.icons.clearRetainingCapacity();
    }

    pub fn finishSubmit(s: *Shell) void {
        s.endSubmit();
    }

    fn endSubmit(s: *Shell) void {
        if (!s.submitting) return;
        s.submitting = false;
        mac.signpostEnd(.submit);
    }

    fn lastFrameValid(ctx: ?*anyopaque) bool {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        return s.panel.lastFrameValid();
    }

    fn panelRequest(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.panel.pending) |a| {
            if (a != .hide and a != .show_search and !s.submitting) {
                s.submitting = true;
                mac.signpostBegin(.submit);
            } else if (a == .hide or a == .show_search) {
                s.endSubmit();
            }
        }
        s.host.on_request(s.host.ctx);
    }

    fn suggestHook(ctx: ?*anyopaque, seq: u64, query: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.host.on_suggest(s.host.ctx, seq, query);
    }

    fn detailedDate(ctx: ?*anyopaque, secs: f64, arena: std.mem.Allocator) []const u8 {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        return s.host.detailed_date(s.host.ctx, secs, arena);
    }

    fn describeDate(ctx: ?*anyopaque, secs: i64, arena: std.mem.Allocator) []const u8 {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        return s.host.relative_date(s.host.ctx, secs, arena);
    }

    fn appIcon(ctx: ?*anyopaque, path: []const u8) ?ui.ImageSource.Pixels {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.icons.get(path)) |icon| return icon.pixels();
        if (s.icons.count() >= max_icons) return null;
        const icon = s.host.icon_pixels(s.host.ctx, s.gpa, path, metrics.top_hit_icon_size * 2) orelse return null;
        const key = s.gpa.dupe(u8, path) catch {
            icon.deinit(s.gpa);
            return null;
        };
        s.icons.put(s.gpa, key, icon) catch {
            s.gpa.free(key);
            icon.deinit(s.gpa);
            return null;
        };
        return icon.pixels();
    }
};
