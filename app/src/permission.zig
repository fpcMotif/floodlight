//! The Full Disk Access grant flow: open System Settings at the list, float
//! a guidance panel under its window with the app to drag in, and watch for
//! the grant. A port of the Swift shell's `FullDiskAccessGrantCoordinator`,
//! `GuidancePanelAnchorPolicy` and `FullDiskAccessGuidanceView`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const chrome = @import("chrome.zig");
const space = chrome.space;
const type_size = chrome.type_size;

pub const Phase = enum { idle, guiding, granted, dismissed };

/// What the flow asks of the system. Production wires these to `mac.zig`;
/// tests count the calls.
pub const Effects = struct {
    ctx: ?*anyopaque = null,
    is_granted: *const fn (?*anyopaque) bool,
    open_settings: *const fn (?*anyopaque) void,
    /// Shows the guidance panel, or moves it to follow System Settings.
    present: *const fn (?*anyopaque) void,
    /// Hides the guidance panel.
    close: *const fn (?*anyopaque) void,
    on_granted: *const fn (?*anyopaque) void,
};

/// How long the granted state stays on screen before the panel goes.
pub const granted_linger_ms = 1500;
pub const poll_ms = 500;
pub const slow_poll_ms = 5000;
pub const fast_polls = 120;

pub const Flow = struct {
    phase: Phase = .idle,
    effects: Effects,
    polls: u32 = 0,

    pub fn begin(f: *Flow) void {
        if (f.effects.is_granted(f.effects.ctx)) {
            f.phase = .granted;
            f.effects.on_granted(f.effects.ctx);
            return;
        }
        if (f.phase == .guiding) return f.effects.present(f.effects.ctx);
        f.polls = 0;
        f.phase = .guiding;
        f.effects.open_settings(f.effects.ctx);
        f.effects.present(f.effects.ctx);
    }

    /// While guiding: the grant, or the panel presented again. Else nothing.
    pub fn poll(f: *Flow) void {
        if (f.phase != .guiding) return;
        f.polls +|= 1;
        if (f.effects.is_granted(f.effects.ctx)) {
            f.phase = .granted;
            f.effects.on_granted(f.effects.ctx);
            return;
        }
        f.effects.present(f.effects.ctx);
    }

    pub fn pollDelayMs(f: *const Flow) u32 {
        return if (f.polls < fast_polls) poll_ms else slow_poll_ms;
    }

    pub fn dismiss(f: *Flow) void {
        f.effects.close(f.effects.ctx);
        f.phase = .dismissed;
    }
};

/// A rectangle in Cocoa screen points: origin at the bottom left.
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn midX(r: Rect) f64 {
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

/// The guidance panel's content. `card` is where the app card was laid
/// out last frame: the window puts its native drag source there.
pub const Guidance = struct {
    /// The flow's phase, which this view only reads.
    phase: *const Phase,
    app_name: []const u8 = "Nanospot",
    /// The app's icon as PNG, when the shell has one.
    icon_png: ?[]const u8 = null,
    dismissed: bool = false,
    card: ?ui.Rect = null,
    /// Told when `card` moves or `dismissed` is set, after the frame.
    request: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub fn view(g: *Guidance, c: *ui.Context) void {
        const th = c.theme;
        const before = g.card;
        const was_dismissed = g.dismissed;
        defer if (g.request) |r| if (!std.meta.eql(before, g.card) or g.dismissed != was_dismissed) r(g.ctx);
        if (g.phase.* != .guiding) g.card = null;
        // The window's glass slab is the material; this only draws its rim.
        const root = ui.div(c).column().sizeFull().px(space.edge).py(space.gap).gap(space.pad).rounded(metrics.radius).border(chrome.outline(th));
        defer root.end();
        // Seen once per install, so it may move: the grant eases in. A phase
        // that flips back mid-way turns the same value around.
        const settled = ui.tween(c, root.id(), 0, if (g.phase.* == .granted) 1 else 0, metrics.settle_seconds, .ease_out);
        switch (g.phase.*) {
            .guiding => g.guidingView(c),
            .granted => grantedView(c, settled),
            .idle, .dismissed => {},
        }
    }

    fn guidingView(g: *Guidance, c: *ui.Context) void {
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
            if (close.clicked()) g.dismissed = true;
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
