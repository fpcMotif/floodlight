//! What the search panel and the clipboard board draw alike: the shared
//! metrics, rows, chips and list keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

/// The Swift shell's `FloodlightMetrics`, so both panels measure the same.
pub const metrics = struct {
    pub const width: f32 = 680;
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
    pub const icon_tile_radius: f32 = row_radius - 3;
    pub const max_overscroll: f32 = row_height / 2;
    pub const expanded_height: f32 = search_height + 1 + filter_bar_height + row_padding * 2 + max_visible_rows * row_height;
    pub const list_height: f32 = expanded_height - search_height - 1 - filter_bar_height;
};

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

pub const ChipSlot = union(enum) { count: usize, loading };

/// A filter chip with its count; returns whether it was clicked.
pub fn filterChip(c: *ui.Context, title: []const u8, symbol: []const u8, selected: bool, slot: ChipSlot) bool {
    const th = c.theme;
    ui.key(c, title);
    const chip = ui.div(c).row().h(26).pl(10).pr(7).gap(5).itemsCenter().roundedFull()
        .bg(th.text.alpha(if (selected) 0.14 else 0.055)).control();
    defer chip.end();
    const clicked = chip.clicked();
    ui.icon(c, symbol, .{ .size = 11, .weight = .semibold, .color = if (selected) th.text else th.muted });
    ui.text(c, title, .{ .size = 11.5, .weight = .semibold });
    const box = ui.div(c).w(27).h(13).center();
    defer box.end();
    switch (slot) {
        .loading => ui.icon(c, "ellipsis", .{ .size = 10, .weight = .semibold, .color = th.muted }),
        .count => |n| ui.text(c, compactCount(c, n), .{ .size = 10, .weight = .semibold, .color = th.muted }),
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
