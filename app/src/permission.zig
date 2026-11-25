//! The Full Disk Access grant flow: open System Settings at the list, float
//! a guidance panel under its window with the app to drag in, and watch for
//! the grant.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const chrome = @import("chrome.zig");
const space = chrome.space;
const type_size = chrome.type_size;

pub const Phase = enum { idle, guiding, granted, dismissed };

/// How long the granted state stays on screen before the panel goes.
pub const granted_linger_ms: u32 = 1500;
pub const poll_ms: u32 = 500;
pub const slow_poll_ms: u32 = 5000;
pub const fast_polls: u32 = 120;

/// A rectangle in Cocoa screen points: origin at the bottom left.
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn midX(r: Rect) f64 {
        return r.x + r.w / 2;
    }
};

pub const panel_w: f64 = 380;
pub const panel_h: f64 = 110;

/// Under System Settings' window when it is on screen, else under the
/// panel that started the flow, else low on the screen; always inside it.
pub fn anchorFrame(target: ?Rect, parent: ?Rect, screen: Rect) Rect {
    const r: Rect = if (target) |t|
        .{ .x = t.midX() - panel_w / 2, .y = t.y - panel_h + 20, .w = panel_w, .h = panel_h }
    else if (parent) |p|
        .{ .x = p.midX() - panel_w / 2, .y = p.y - panel_h + 16, .w = panel_w, .h = panel_h }
    else
        .{ .x = screen.midX() - panel_w / 2, .y = screen.y + 80, .w = panel_w, .h = panel_h };
    return .{
        .x = std.math.clamp(r.x, screen.x + 12, screen.x + screen.w - r.w - 12),
        .y = std.math.clamp(r.y, screen.y + 8, screen.y + screen.h - r.h - 8),
        .w = r.w,
        .h = r.h,
    };
}

/// CGWindowList bounds (origin top left of the primary screen) to Cocoa's.
pub fn quartzToCocoa(q: Rect, primary_screen_h: f64) Rect {
    return .{ .x = q.x, .y = primary_screen_h - (q.y + q.h), .w = q.w, .h = q.h };
}

/// Moves only past a few points, so polling doesn't jitter the panel.
pub fn shouldMove(from: Rect, to: Rect) bool {
    return @abs(to.x - from.x) > 4 or @abs(to.y - from.y) > 4;
}

/// Reference frames used to anchor the guidance panel while `.guiding`.
pub const Anchors = struct {
    settings: ?Rect = null,
    parent: ?Rect = null,
    screen: Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
};

pub const WindowOp = union(enum) {
    keep,
    show: Rect,
    move: Rect,
    redraw,
    hide,
};

pub const DragOp = union(enum) {
    keep,
    clear,
    place: [4]f64,

    pub fn rect(op: DragOp) ??[4]f64 {
        return switch (op) {
            .keep => null,
            .clear => @as(?[4]f64, null),
            .place => |r| r,
        };
    }
};

pub const Outcome = struct {
    open_settings: bool = false,
    window: WindowOp = .keep,
    drag: DragOp = .keep,
    poll_ms: ?u32 = null,
    linger_ms: ?u32 = null,
    rebuild_index: bool = false,
};

pub fn noOp(_: ?*anyopaque) void {}

/// Windowless controller and view for the Full Disk Access grant flow.
pub const Grant = struct {
    phase: Phase = .idle,
    app_name: []const u8 = "Nanospot",
    /// The app's icon as PNG, when the shell has one.
    icon_png: ?[]const u8 = null,
    anchors: Anchors = .{},
    read_anchors: ?*const fn (?*anyopaque) Anchors = null,
    on_request: *const fn (?*anyopaque) void = noOp,
    ctx: ?*anyopaque = null,
    /// Where the app card was laid out last frame; the window puts its native drag source there.
    card: ?ui.Rect = null,

    polls: u32 = 0,
    visible: bool = false,
    placed_frame: ?Rect = null,
    placed_card: ?ui.Rect = null,
    poll_armed: bool = false,
    lingering: bool = false,
    close_requested: bool = false,

    pub fn view(g: *Grant) ui.View {
        return .init(g, draw);
    }

    pub fn isGuiding(g: *const Grant) bool {
        return g.phase == .guiding;
    }

    pub fn pollDelayMs(g: *const Grant) u32 {
        return if (g.phase == .dismissed or g.polls >= fast_polls) slow_poll_ms else poll_ms;
    }

    fn currentAnchor(g: *const Grant) Rect {
        const a = if (g.read_anchors) |r| r(g.ctx) else g.anchors;
        return anchorFrame(a.settings, a.parent, a.screen);
    }

    fn enterGranted(g: *Grant) Outcome {
        g.phase = .granted;
        g.close_requested = false;
        g.card = null;
        g.placed_card = null;
        var out: Outcome = .{ .rebuild_index = true };
        if (g.visible) {
            out.window = .redraw;
            out.drag = .clear;
            if (!g.lingering) {
                g.lingering = true;
                out.linger_ms = granted_linger_ms;
            }
        }
        return out;
    }

    fn hidePanel(g: *Grant) Outcome {
        g.visible = false;
        g.placed_frame = null;
        g.card = null;
        g.placed_card = null;
        return .{ .window = .hide, .drag = .clear };
    }

    pub fn begin(g: *Grant, granted: bool) Outcome {
        if (g.phase == .granted) return .{};
        if (granted) return g.enterGranted();
        g.close_requested = false;
        var out: Outcome = .{};
        if (g.phase != .guiding) {
            g.polls = 0;
            g.phase = .guiding;
            out.open_settings = true;
        }
        const want = g.currentAnchor();
        g.visible = true;
        g.placed_frame = want;
        out.window = .{ .show = want };
        if (!g.poll_armed) {
            g.poll_armed = true;
            out.poll_ms = g.pollDelayMs();
        }
        return out;
    }

    pub fn poll(g: *Grant, granted: bool) Outcome {
        g.poll_armed = false;
        if (g.close_requested) {
            var out = g.dismiss();
            if (granted and g.phase == .dismissed) {
                g.phase = .granted;
                g.poll_armed = false;
                out.poll_ms = null;
                out.rebuild_index = true;
            }
            return out;
        }
        switch (g.phase) {
            .idle, .granted => return .{},
            .dismissed => {
                if (granted) {
                    g.phase = .granted;
                    return .{ .rebuild_index = true };
                }
                g.poll_armed = true;
                return .{ .poll_ms = slow_poll_ms };
            },
            .guiding => {},
        }
        g.polls +|= 1;
        if (granted) return g.enterGranted();
        const want = g.currentAnchor();
        var out: Outcome = .{};
        if (!g.visible) {
            g.visible = true;
            g.placed_frame = want;
            out.window = .{ .show = want };
        } else if (g.placed_frame == null or shouldMove(g.placed_frame.?, want)) {
            g.placed_frame = want;
            out.window = .{ .move = want };
        }
        g.poll_armed = true;
        out.poll_ms = g.pollDelayMs();
        return out;
    }

    pub fn dismiss(g: *Grant) Outcome {
        g.close_requested = false;
        switch (g.phase) {
            .guiding => {
                g.phase = .dismissed;
                var out = g.hidePanel();
                if (!g.poll_armed) {
                    g.poll_armed = true;
                    out.poll_ms = slow_poll_ms;
                }
                return out;
            },
            .granted => return if (g.visible) g.hidePanel() else .{},
            .idle, .dismissed => return .{},
        }
    }

    pub fn lingerTimedOut(g: *Grant) Outcome {
        g.lingering = false;
        return if (g.phase == .granted and g.visible) g.hidePanel() else .{};
    }

    pub fn applyPending(g: *Grant) Outcome {
        if (g.close_requested) return g.dismiss();
        if (g.phase != .guiding) {
            if (g.placed_card != null) {
                g.placed_card = null;
                return .{ .drag = .clear };
            }
            return .{};
        }
        if (std.meta.eql(g.placed_card, g.card)) return .{};
        g.placed_card = g.card;
        if (g.card) |r| return .{ .drag = .{ .place = .{ r.x, r.y, r.w, r.h } } };
        return .{ .drag = .clear };
    }

    fn draw(g: *Grant, c: *ui.Context) void {
        const th = c.theme;
        const before = g.card;
        const was_close = g.close_requested;
        defer if (!std.meta.eql(before, g.card) or g.close_requested != was_close) g.on_request(g.ctx);
        if (g.phase != .guiding) g.card = null;
        // The window's glass slab is the material; this only draws its rim.
        const root = ui.div(c).column().sizeFull().px(space.edge).py(space.gap).gap(space.pad).rounded(metrics.radius).border(chrome.outline(th));
        defer root.end();
        // Seen once per install, so it may move: the grant eases in. A phase
        // that flips back mid-way turns the same value around.
        const settled = ui.tween(c, root.id(), 0, if (g.phase == .granted) 1 else 0, metrics.settle_seconds, .ease_out);
        switch (g.phase) {
            .guiding => g.guidingView(c),
            .granted => grantedView(c, settled),
            .idle, .dismissed => {},
        }
    }

    fn guidingView(g: *Grant, c: *ui.Context) void {
        const th = c.theme;
        const tone = chrome.tone(th);
        const blue = chrome.hue(th, .blue);
        {
            const head = ui.div(c).row().wFull().gap(space.snug).itemsCenter();
            defer head.end();
            ui.icon(c, "arrow.up", .{ .size = type_size.chip, .weight = .semibold, .color = blue });
            ui.text(c, c.print("Drag {s} into the Full Disk Access list", .{g.app_name}), .{ .size = type_size.body, .weight = .medium, .truncate = .ellipsis });
            ui.spacer(c);
            const close = ui.div(c).w(metrics.close_hit_size).h(metrics.close_hit_size).center().roundedFull().control();
            const it = c.interact(close.index, .{});
            _ = close.bg(th.muted.alpha(chrome.pointerAlpha(0, it)));
            ui.icon(c, "xmark", .{ .size = type_size.micro, .weight = .bold, .color = tone.secondary });
            if (close.clicked()) g.close_requested = true;
            close.end();
        }
        {
            const card = ui.div(c).row().wFull().h(metrics.card_height).px(space.gap).gap(space.pad).itemsCenter().rounded(metrics.card_radius).bg(th.muted.alpha(chrome.fill.card));
            defer card.end();
            g.card = card.interaction().rect;
            if (g.icon_png) |png| {
                _ = ui.image(c, .{ .key = "app-icon", .bytes = png, .max_width = metrics.app_icon_size, .max_height = metrics.app_icon_size, .radius = space.snug });
            } else ui.icon(c, "app.fill", .{ .size = metrics.app_symbol_size, .color = blue });
            ui.text(c, g.app_name, .{ .size = type_size.inspector_row, .weight = .medium });
            ui.spacer(c);
            ui.icon(c, "line.3.horizontal", .{ .size = type_size.key_chip, .color = tone.tertiary });
        }
        ui.text(c, c.print("Or click + in System Settings and choose {s}", .{g.app_name}), .{ .size = type_size.key_chip, .color = tone.secondary });
    }

    fn grantedView(c: *ui.Context, settled: f32) void {
        const th = c.theme;
        const row = ui.div(c).row().sizeFull().px(space.pad).gap(space.gap).itemsCenter().opacity(settled);
        defer row.end();
        {
            const mark = ui.div(c).scale(metrics.settle_from_scale + (1 - metrics.settle_from_scale) * settled);
            defer mark.end();
            ui.icon(c, "checkmark.circle.fill", .{ .size = metrics.check_size, .color = chrome.hue(th, .green) });
        }
        const col = ui.div(c).column().gap(space.tight);
        defer col.end();
        ui.text(c, "Full Disk Access Granted", .{ .size = type_size.empty_state, .weight = .semibold });
        ui.text(c, "You\u{2019}re ready to search everywhere.", .{ .size = type_size.chip, .color = chrome.tone(th).secondary });
    }
};

/// The guidance panel's own sizes; the rest are `chrome`'s.
pub const metrics = struct {
    pub const radius: f32 = 16;
    pub const card_height: f32 = 34;
    /// Inside a 16 point panel 12 from its edge, 4 would be concentric; 8
    /// reads as the row it is.
    pub const card_radius: f32 = 8;
    pub const close_hit_size: f32 = 24;
    pub const app_icon_size: f32 = 22;
    pub const app_symbol_size: f32 = 18;
    pub const check_size: f32 = 24;
    /// Short enough to finish before the eye lands, long enough to read as arriving.
    pub const settle_seconds: f32 = 0.18;
    pub const settle_from_scale: f32 = 0.95;
};
