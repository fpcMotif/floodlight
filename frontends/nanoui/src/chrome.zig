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
    pub const hairline: f32 = 1;
    pub const chip_height: f32 = 26;
    pub const chip_count_width: f32 = 27;
    pub const chip_count_height: f32 = 13;
    pub const key_chip_size: f32 = 24;
    pub const key_chip_radius: f32 = 7;
    pub const key_glyph_radius: f32 = 3;
    pub const clear_hit_size: f32 = 24;
    pub const empty_icon_size: f32 = 26;
    /// A web row's globe, as a share of its tile.
    pub const tile_symbol_scale: f32 = 0.58;
    pub const media_radius: f32 = 6;
};

/// Distances between things, smallest first. A call site names one of
/// these, never a number.
pub const space = struct {
    pub const hair: f32 = 1;
    pub const tight: f32 = 2;
    pub const text: f32 = 3;
    pub const snug: f32 = 5;
    pub const pad: f32 = metrics.row_padding;
    pub const inset: f32 = 10;
    pub const gap: f32 = 12;
    pub const edge: f32 = 14;
    pub const bar: f32 = 20;
    pub const gutter: f32 = 40;
};

/// The Swift shell's `FloodlightMetrics.Typography`, in points.
pub const type_size = struct {
    pub const input: f32 = 24;
    pub const top_hit_title: f32 = 19;
    pub const row_title: f32 = 15;
    pub const empty_state: f32 = 13.5;
    pub const value: f32 = 13;
    pub const body: f32 = 12.5;
    pub const inspector_row: f32 = 12;
    pub const chip: f32 = 11.5;
    pub const key_chip: f32 = 11;
    pub const caption: f32 = 10.5;
    /// The smallest text drawn: badges, counts, key glyphs.
    pub const micro: f32 = 10;
};

/// How strongly a fill or a line shows over the well.
pub const fill = struct {
    pub const inspector: f32 = 0.03;
    pub const footer: f32 = 0.04;
    pub const top_hit: f32 = 0.045;
    pub const chip: f32 = 0.055;
    pub const badge: f32 = 0.07;
    pub const code: f32 = 0.08;
    pub const key: f32 = 0.1;
    pub const outline: f32 = 0.1;
    pub const card: f32 = 0.12;
    pub const tile: f32 = 0.14;
    pub const chip_selected: f32 = 0.14;
    pub const key_glyph: f32 = 0.25;
    pub const divider: f32 = 0.45;
};

/// Text and line colors by role. `secondary` holds 4.5:1 and APCA Lc 60
/// on the well, a selected row and a selected chip; `tertiary` holds 3:1
/// on the well and is for placeholders, disabled text and quiet symbols.
pub const Tone = struct {
    secondary: ui.Color,
    tertiary: ui.Color,
    /// Pure black or white: fills and outlines that must not tint.
    ink: ui.Color,
};

pub fn tone(th: ui.Theme) Tone {
    if (th.dark) return .{ .secondary = .hex(0xc2c2c7), .tertiary = .hex(0x67676c), .ink = .hex(0xffffff) };
    return .{ .secondary = .hex(0x55555a), .tertiary = .hex(0x8d8d92), .ink = .hex(0x000000) };
}

/// A symbol color that holds 3:1 on the well and on its own tile.
pub const Hue = enum { blue, purple, cyan, green };

pub fn hue(th: ui.Theme, h: Hue) ui.Color {
    return .hex(switch (h) {
        .blue => if (th.dark) 0x0a84ff else 0x0071e3,
        .purple => if (th.dark) 0xbf5af2 else 0x8944ab,
        .cyan => if (th.dark) 0x32ade6 else 0x0071a4,
        .green => if (th.dark) 0x30d158 else 0x248a3d,
    });
}

/// A picture's edge: pure ink, so it never tints with what is behind it.
pub fn outline(th: ui.Theme) ui.Color {
    return tone(th).ink.alpha(fill.outline);
}

pub const Axis = enum { across, down };

/// A rule between two regions of the well.
pub fn divider(c: *ui.Context, axis: Axis) void {
    const color = c.theme.border.alpha(fill.divider);
    switch (axis) {
        .across => ui.div(c).wFull().h(metrics.hairline).bg(color).end(),
        .down => ui.div(c).w(metrics.hairline).hFull().bg(color).end(),
    }
}

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
        .bg(th.background).rounded(metrics.well_radius).border(th.text.alpha(metrics.well_stroke_opacity)).borderW(metrics.hairline).clip();
    return .{ .outer = outer, .inner = inner };
}

pub fn footerBar(c: *ui.Context, count: []const u8) ui.Div {
    const th = c.theme;
    divider(c, .across);
    const bar = ui.div(c).row().wFull().h(metrics.footer_height).px(space.edge).gap(space.gap).itemsCenter().bg(th.muted.alpha(fill.footer));
    ui.text(c, count, .{ .size = type_size.key_chip, .weight = .medium, .color = tone(th).secondary, .tabular = true });
    ui.div(c).grow().end();
    return bar;
}

pub fn footerChip(c: *ui.Context, title: []const u8, key: []const u8, enabled: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    const chip = ui.div(c).row().gap(space.snug).px(space.pad).py(space.text).itemsCenter().roundedFull()
        .opacity(if (enabled) 1 else metrics.footer_chip_disabled_opacity).control();
    defer chip.end();
    const it = c.interact(chip.index, .{});
    _ = chip.bg(th.muted.alpha(if (enabled) pointerAlpha(fill.card, it) else fill.card));
    ui.text(c, title, .{ .size = type_size.chip, .weight = .medium });
    {
        const k = ui.div(c).px(space.snug).py(space.hair).rounded(metrics.key_glyph_radius).bg(th.muted.alpha(fill.key_glyph));
        defer k.end();
        ui.text(c, key, .{ .size = type_size.micro, .weight = .semibold, .rounded = true });
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
    return ui.div(c).row().wFull().h(metrics.filter_bar_height).px(space.edge).gap(space.pad).itemsCenter().clip();
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
    const t = tone(c.theme);
    const empty = ui.div(c).column().wFull().h(height).center().px(space.gutter).gap(space.snug);
    defer empty.end();
    ui.icon(c, e.symbol, .{ .size = metrics.empty_icon_size, .weight = .medium, .color = t.tertiary });
    ui.div(c).h(space.snug).end();
    ui.text(c, e.title, .{ .size = type_size.empty_state, .weight = .medium, .truncate = .middle });
    if (e.hint) |hint| ui.text(c, hint, .{ .size = type_size.inspector_row, .color = t.secondary });
}

pub const RowBox = struct { box: ui.Div, it: ui.Interaction };

/// A list row's box, filled for its selection and hover; the caller ends it.
pub fn rowBox(c: *ui.Context, selected: bool, top_hit: bool) RowBox {
    const box = ui.div(c).row().wFull().h(metrics.row_height).px(space.gap).gap(space.gap).itemsCenter().rounded(metrics.row_radius).control();
    const it = c.interact(box.index, .{});
    return .{ .box = box.bg(rowFill(c.theme, selected, it.hovered, top_hit)), .it = it };
}

pub const ChipSlot = union(enum) { count: usize, loading };

/// A filter chip with its count; returns whether it was clicked.
pub fn filterChip(c: *ui.Context, title: []const u8, symbol: []const u8, selected: bool, slot: ChipSlot) bool {
    const th = c.theme;
    ui.key(c, title);
    const empty = !selected and slot == .count and slot.count == 0;
    const quiet = tone(th).secondary;
    const chip = ui.div(c).row().h(metrics.chip_height).pl(space.inset).pr(space.pad).gap(space.snug).itemsCenter().roundedFull()
        .opacity(if (empty) metrics.empty_chip_opacity else 1).control();
    defer chip.end();
    const it = c.interact(chip.index, .{});
    _ = chip.bg(th.text.alpha(pointerAlpha(if (selected) fill.chip_selected else fill.chip, it)));
    const clicked = it.clicked;
    if (clicked) c.changed = true;
    ui.icon(c, symbol, .{ .size = type_size.key_chip, .weight = .semibold, .color = if (selected) th.text else quiet });
    ui.text(c, title, .{ .size = type_size.chip, .weight = .semibold });
    const box = ui.div(c).w(metrics.chip_count_width).h(metrics.chip_count_height).center();
    defer box.end();
    switch (slot) {
        .loading => ui.icon(c, "ellipsis", .{ .size = type_size.micro, .weight = .semibold, .color = quiet }),
        .count => |n| ui.text(c, compactCount(c, n), .{ .size = type_size.micro, .weight = .semibold, .color = quiet, .tabular = true }),
    }
    return clicked;
}

pub fn boundOverscroll(c: *ui.Context, scroll_box: u64) void {
    const over = c.overscroll.getPtr(scroll_box) orelse return;
    over.* = std.math.clamp(over.*, -metrics.max_overscroll, metrics.max_overscroll);
}

pub fn rowFill(th: ui.Theme, selected: bool, hovered: bool, top_hit: bool) ui.Color {
    const ink = tone(th).ink;
    const wash: RowWash = if (th.dark) .dark else .light;
    if (selected) return ink.alpha(if (hovered) wash.selected_hovered else wash.selected);
    if (hovered) return ink.alpha(wash.hovered);
    if (top_hit) return th.text.alpha(fill.top_hit);
    return ink.alpha(0);
}

/// White lifts a dark well less per step than black sinks a light one.
const RowWash = struct {
    selected: f32,
    selected_hovered: f32,
    hovered: f32,

    const light: RowWash = .{ .selected = 0.08, .selected_hovered = 0.11, .hovered = 0.055 };
    const dark: RowWash = .{ .selected = 0.12, .selected_hovered = 0.16, .hovered = 0.075 };
};

const ChipContent = union(enum) { label: []const u8, symbol: []const u8 };

pub fn keyChip(c: *ui.Context, content: ChipContent) void {
    const th = c.theme;
    const chip = ui.div(c).row().minW(metrics.key_chip_size).h(metrics.key_chip_size).px(space.pad).center().rounded(metrics.key_chip_radius).bg(th.muted.alpha(fill.key));
    defer chip.end();
    const color = tone(th).secondary;
    switch (content) {
        .label => |s| ui.text(c, s, .{ .size = type_size.key_chip, .weight = .semibold, .color = color }),
        .symbol => |s| ui.icon(c, s, .{ .size = type_size.key_chip, .weight = .semibold, .color = color }),
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
