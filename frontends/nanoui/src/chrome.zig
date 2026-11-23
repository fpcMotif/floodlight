//! What the search panel and the clipboard board draw alike: the shared
//! metrics, rows, filter bar, chips, empty state and list keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

/// The Swift shell's `FloodlightMetrics`, so both panels measure the same.
pub const metrics = struct {
    pub const width: f32 = 760;
    pub const search_height: f32 = 60;
    pub const filter_bar_height: f32 = 40;
    pub const corner_radius: f32 = search_height / 2;
    pub const row_height: f32 = 58;
    pub const row_padding: f32 = 7;
    pub const row_radius: f32 = 12;
    pub const max_visible_rows = 7;
    pub const icon_size: f32 = 38;
    pub const top_hit_icon_size: f32 = 46;
    pub const search_icon_size: f32 = 22;
    pub const clear_button_size: f32 = 18;
    pub const row_key_width: f32 = 30;
    pub const icon_tile_radius: f32 = row_radius - 3;
    pub const max_overscroll: f32 = row_height / 2;
    pub const footer_height: f32 = 32;
    pub const footer_chip_disabled_opacity: f32 = 0.4;
    pub const well_inset: f32 = row_padding;
    pub const well_radius: f32 = corner_radius - well_inset;
    pub const well_stroke_opacity: f32 = 0.12;
    pub const empty_chip_opacity: f32 = 0.5;
    pub const expanded_height: f32 = search_height + filter_bar_height + row_padding * 3 + max_visible_rows * row_height + 1 + footer_height;
    pub const well_height: f32 = expanded_height - search_height - well_inset;
    pub const list_height: f32 = well_height - filter_bar_height - 1 - footer_height;
};

pub const Well = struct {
    outer: ui.Div,
    inner: ui.Div,

    pub fn end(w: Well) void {
        w.inner.end();
        w.outer.end();
    }
};

pub fn well(c: *ui.Context) Well {
    const th = c.theme;
    const outer = ui.div(c).column().wFull().px(metrics.well_inset).pb(metrics.well_inset);
    const inner = ui.div(c).column().wFull().h(metrics.well_height)
        .bg(th.background).rounded(metrics.well_radius).border(th.text.alpha(metrics.well_stroke_opacity)).borderW(1).clip();
    return .{ .outer = outer, .inner = inner };
}

pub fn footerBar(c: *ui.Context, count: []const u8) ui.Div {
    const th = c.theme;
    ui.div(c).wFull().h(1).bg(th.border.alpha(0.45)).end();
    const bar = ui.div(c).row().wFull().h(metrics.footer_height).px(14).gap(12).itemsCenter().bg(th.muted.alpha(0.04));
    ui.text(c, count, .{ .size = 11, .weight = .medium, .color = th.muted.alpha(0.6), .tabular = true });
    ui.div(c).grow().end();
    return bar;
}

pub fn footerChip(c: *ui.Context, title: []const u8, key: []const u8, enabled: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    const chip = ui.div(c).row().gap(5).px(8).py(4).itemsCenter().roundedFull()
        .opacity(if (enabled) 1 else metrics.footer_chip_disabled_opacity).control();
    defer chip.end();
    const it = c.interact(chip.index, .{});
    _ = chip.bg(th.muted.alpha(if (enabled) pointerAlpha(0.12, it) else 0.12));
    ui.text(c, title, .{ .size = 11.5, .weight = .medium });
    {
        const k = ui.div(c).px(4).py(1).rounded(3).bg(th.muted.alpha(0.25));
        defer k.end();
        ui.text(c, key, .{ .size = 9, .weight = .semibold, .rounded = true });
    }
    if (enabled and it.clicked) c.changed = true;
    return enabled and it.clicked;
}

pub const hover_alpha_step: f32 = 0.04;
pub const press_alpha_step: f32 = 0.08;

pub fn pointerAlpha(rest: f32, it: ui.Interaction) f32 {
    if (it.pressed) return rest + press_alpha_step;
    if (it.hovered) return rest + hover_alpha_step;
    return rest;
}

/// ⌘1… picks a filter from `options`, ↑↓ move the selection. Returns
/// whether a filter was picked.
pub fn listKeys(c: *ui.Context, l: anytype, options: anytype) bool {
    const S = ui.Shortcut;
    var picked = false;
    for (options, 0..) |f, i| {
        if (c.shortcut(.{ .key = '1' + @as(u21, @intCast(i)), .cmd = true })) {
            l.selectFilter(f);
            picked = true;
        }
    }
    if (l.visible.len == 0) return picked;
    if (c.shortcut(.{ .key = S.down })) l.move(true);
    if (c.shortcut(.{ .key = S.up })) l.move(false);
    return picked;
}

/// Scrolls a list box `view_h` tall so its selection shows, when asked to.
pub fn revealSelection(c: *ui.Context, l: anytype, scroll_box: u64, view_h: f32) void {
    if (l.takeScroll(c.scroll.get(scroll_box) orelse 0, view_h, metrics.row_height)) |y| c.setScroll(scroll_box, .y, y);
}

/// The row the filter chips sit in; the caller ends it.
pub fn filterBar(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().h(metrics.filter_bar_height).px(14).gap(7).itemsCenter().clip();
}

/// A filter's title as it reads mid-sentence: "apps", but "PDFs".
pub fn sentenceNoun(c: *ui.Context, f: anytype) []const u8 {
    const title = f.title();
    if (title.len < 2 or std.ascii.isUpper(title[1])) return title;
    const out = c.arena.allocator().dupe(u8, title) catch return title;
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

pub const Empty = struct {
    symbol: []const u8,
    title: []const u8,
    hint: ?[]const u8 = null,
};

/// What a list with no rows says, centred in a box `height` tall.
pub fn emptyState(c: *ui.Context, height: f32, e: Empty) void {
    const muted = c.theme.muted;
    const empty = ui.div(c).column().wFull().h(height).center().px(40).gap(5);
    defer empty.end();
    ui.icon(c, e.symbol, .{ .size = 26, .weight = .medium, .color = muted.alpha(0.32) });
    ui.div(c).h(5).end();
    ui.text(c, e.title, .{ .size = 13.5, .weight = .medium, .color = muted.alpha(0.75), .truncate = .middle });
    if (e.hint) |hint| ui.text(c, hint, .{ .size = 12, .color = muted.alpha(0.5) });
}

pub const RowBox = struct { box: ui.Div, it: ui.Interaction };

/// A list row's box, filled for its selection and hover; the caller ends it.
pub fn rowBox(c: *ui.Context, selected: bool, top_hit: bool) RowBox {
    const box = ui.div(c).row().wFull().h(metrics.row_height).px(12).gap(12).itemsCenter().rounded(metrics.row_radius).control();
    const it = c.interact(box.index, .{});
    return .{ .box = box.bg(rowFill(c.theme, selected, it.hovered, top_hit)), .it = it };
}

pub const ChipSlot = union(enum) { count: usize, loading };

/// A filter chip with its count; returns whether it was clicked.
pub fn filterChip(c: *ui.Context, title: []const u8, symbol: []const u8, selected: bool, slot: ChipSlot) bool {
    const th = c.theme;
    ui.key(c, title);
    const empty = !selected and slot == .count and slot.count == 0;
    const chip = ui.div(c).row().h(26).pl(10).pr(7).gap(5).itemsCenter().roundedFull()
        .opacity(if (empty) metrics.empty_chip_opacity else 1).control();
    defer chip.end();
    const it = c.interact(chip.index, .{});
    _ = chip.bg(th.text.alpha(pointerAlpha(if (selected) 0.14 else 0.055, it)));
    const clicked = it.clicked;
    if (clicked) c.changed = true;
    ui.icon(c, symbol, .{ .size = 11, .weight = .semibold, .color = if (selected) th.text else th.muted });
    ui.text(c, title, .{ .size = 11.5, .weight = .semibold });
    const box = ui.div(c).w(27).h(13).center();
    defer box.end();
    switch (slot) {
        .loading => ui.icon(c, "ellipsis", .{ .size = 10, .weight = .semibold, .color = th.muted }),
        .count => |n| ui.text(c, compactCount(c, n), .{ .size = 10, .weight = .semibold, .color = th.muted, .tabular = true }),
    }
    return clicked;
}

pub fn boundOverscroll(c: *ui.Context, scroll_box: u64) void {
    const over = c.overscroll.getPtr(scroll_box) orelse return;
    over.* = std.math.clamp(over.*, -metrics.max_overscroll, metrics.max_overscroll);
}

pub fn rowFill(th: ui.Theme, selected: bool, hovered: bool, top_hit: bool) ui.Color {
    const ink: ui.Color = if (th.dark) .hex(0xffffff) else .hex(0x000000);
    if (selected) return ink.alpha(if (th.dark) (if (hovered) 0.16 else 0.12) else (if (hovered) 0.11 else 0.08));
    if (hovered) return ink.alpha(if (th.dark) 0.075 else 0.055);
    if (top_hit) return th.text.alpha(0.045);
    return ink.alpha(0);
}

const ChipContent = union(enum) { label: []const u8, symbol: []const u8 };

pub fn keyChip(c: *ui.Context, content: ChipContent) void {
    const th = c.theme;
    const chip = ui.div(c).row().minW(24).h(24).px(7).center().rounded(7).bg(th.muted.alpha(0.1));
    defer chip.end();
    const color = th.text.alpha(0.82);
    switch (content) {
        .label => |s| ui.text(c, s, .{ .size = 11, .weight = .semibold, .color = color }),
        .symbol => |s| ui.icon(c, s, .{ .size = 11, .weight = .semibold, .color = color }),
    }
}

pub const RowKey = union(enum) { none, enter, label: []const u8 };

pub fn rowKey(c: *ui.Context, key: RowKey) void {
    const slot = ui.div(c).row().minW(metrics.row_key_width).justifyEnd();
    defer slot.end();
    switch (key) {
        .none => {},
        .enter => keyChip(c, .{ .symbol = "return" }),
        .label => |s| keyChip(c, .{ .label = s }),
    }
}

pub fn compactCount(c: *ui.Context, n: usize) []const u8 {
    if (n < 1000) return c.print("{d}", .{n});
    const tenths = (n + 50) / 100;
    if (tenths % 10 == 0) return c.print("{d}K", .{tenths / 10});
    return c.print("{d}.{d}K", .{ tenths / 10, tenths % 10 });
}

pub fn formatSize(c: *ui.Context, bytes: u64) []const u8 {
    if (bytes < 1000) return c.print("{d} bytes", .{bytes});
    if (bytes < 1_000_000) return c.print("{d} KB", .{(bytes + 500) / 1000});
    const units = [_][]const u8{ "MB", "GB", "TB" };
    var scaled: f64 = @as(f64, @floatFromInt(bytes)) / 1_000_000;
    var u: usize = 0;
    while (scaled >= 1000 and u + 1 < units.len) : (u += 1) scaled /= 1000;
    if (u == 0) return c.print("{d:.1} {s}", .{ scaled, units[u] });
    return c.print("{d:.2} {s}", .{ scaled, units[u] });
}
