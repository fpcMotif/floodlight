//! Pure nanoui view layout and input observation for the search panel.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("../search.zig");
const board_mod = @import("../board.zig");
const chrome = @import("../chrome.zig");
const list = @import("../list.zig");

const metrics = chrome.metrics;
const space = chrome.space;
const type_size = chrome.type_size;

pub const summon_label = "⌥ Space";

pub fn render(p: anytype, c: *ui.Context) void {
    const root = ui.div(c).column().sizeFull();
    defer root.end();
    searchBar(p, c);
    if (p.mode == .clipboard) {
        const cx: board_mod.Context = .{ .ctx = p.hooks.ctx, .app_icon = p.hooks.app_icon, .detailed_date = p.hooks.detailed_date, .query = p.field.text() };
        if (p.board.view(c, cx)) |a| p.ask(.{ .clipboard = a });
    } else if (p.field.text().len > 0 or p.list.visible.len > 0) {
        const well = chrome.well(c);
        defer well.end();
        if (p.field.text().len > 0) {
            filterBar(p, c);
        } else {
            const bar = chrome.filterBar(c);
            defer bar.end();
            ui.text(c, "Suggestions", .{ .size = type_size.chip, .weight = .semibold, .color = chrome.tone(c.theme).secondary });
        }
        resultList(p, c);
        footer(p, c);
    }
    const want_h = p.panelHeight();
    const want_w = p.panelWidth();
    if (want_h != p.height or want_w != p.width) {
        p.height = want_h;
        p.width = want_w;
        p.hooks.request(p.hooks.ctx);
    }
}

/// Return on the board pastes; Space on an empty filter triggers Quick Look.
fn boardField(p: anytype, r: anytype) void {
    if (r.changed) {
        if (std.mem.eql(u8, p.field.text(), " ")) if (p.board.list.selection()) |e| if (p.board.previewable(e)) {
            p.field.clear();
            return p.ask(.{ .clipboard = .{ .preview = e } });
        };
        p.refresh();
    }
    if (r.submitted) if (p.board.list.selection()) |e| p.ask(.{ .clipboard = .{ .paste = e } });
}

fn searchBar(p: anytype, c: *ui.Context) void {
    const th = c.theme;
    const tone = chrome.tone(th);
    const bar = ui.div(c).row().wFull().h(metrics.search_height).px(space.bar).gap(space.gap).itemsCenter();
    defer bar.end();
    ui.icon(c, "magnifyingglass", .{ .size = metrics.search_icon_size, .weight = .medium, .color = tone.secondary, .frame = metrics.search_icon_size });
    if (p.field.text().len == 0) p.field.focus();
    const board = p.mode == .clipboard;
    p.observeInput(c);
    const suggestion = p.completionSuffix();
    const r = ui.textField(c, &p.field, .{ .placeholder = if (board) "Filter clipboard" else "Nanospot", .size = type_size.input, .width = .fill, .bare = true, .suggestion = suggestion, .placeholder_color = tone.tertiary });
    if (r.accepted) p.acceptCompletionHint();
    if (board) {
        boardField(p, r);
    } else {
        if (r.changed) p.refresh();
        if (r.submitted) if (p.list.selection()) |row| p.ask(.{ .open = row.path });
    }
    p.syncFieldState(c, r.caret);
    if (p.field.text().len > 0) {
        const clear = ui.div(c).w(metrics.clear_hit_size).h(metrics.clear_hit_size).center().control();
        defer clear.end();
        const it = c.interact(clear.index, .{});
        const color = if (it.hovered and !it.pressed) th.text else tone.secondary;
        ui.icon(c, "xmark.circle.fill", .{ .size = metrics.clear_button_size, .color = color });
        if (clear.clicked()) p.clearField();
    } else chrome.keyChip(c, .{ .label = if (board) board_mod.summon_label else summon_label });
}

fn filterBar(p: anytype, c: *ui.Context) void {
    const Filter = @TypeOf(p.list.filter);
    const bar = chrome.filterBar(c);
    defer bar.end();
    var buf: [Filter.primary.len + Filter.dynamic.len]Filter = undefined;
    for (p.filterOptions(&buf)) |f| {
        const slot: chrome.ChipSlot = if (p.catalog.indexing() and f != .apps) .loading else .{ .count = p.list.count(f) };
        if (chrome.filterChip(c, bar, f.title(), p.list.filter == f, slot)) p.selectFilter(f);
    }
}

fn resultList(p: anytype, c: *ui.Context) void {
    if (p.list.visible.len == 0) {
        const f = p.list.filter;
        const message: chrome.Empty = if (p.list.failed)
            .{ .symbol = "exclamationmark.triangle", .title = c.print("Could not search for \u{201C}{s}\u{201D}", .{p.field.text()}) }
        else
            .{
                .symbol = f.symbol(),
                .title = c.print("No {s} match \u{201C}{s}\u{201D}", .{ chrome.sentenceNoun(c, f), p.field.text() }),
                .hint = if (f == .all) null else "Press \u{2318}1 to search everything.",
            };
        return chrome.emptyState(c, metrics.list_height, message);
    }
    const box = ui.div(c).column().wFull().h(metrics.list_height).scrollY().p(metrics.row_padding);
    defer box.end();
    chrome.boundOverscroll(c, box.id());
    const view_h = metrics.list_height - 2 * metrics.row_padding;
    chrome.revealSelection(c, &p.list, box.id(), view_h);
    const visible = p.list.visible;
    const shown = list.rowsInView(c.scroll.get(box.id()) orelse 0, visible.len, metrics.row_height, view_h, 2);
    chrome.rowSpacer(c, "above", shown.first);
    for (shown.first..shown.end) |i| rowView(p, c, i);
    chrome.rowSpacer(c, "below", visible.len - shown.end);
}

fn footer(p: anytype, c: *ui.Context) void {
    const n = p.list.visible.len;
    const bar = chrome.footerBar(c, c.print("{d} {s}", .{ n, if (n == 1) "result" else "results" }));
    defer bar.end();
    const row = p.list.selection();
    if (chrome.footerChip(c, "Open", "↵", row != null)) p.ask(.{ .open = row.?.path });
    const revealable = if (row) |r| r.kind != .web else false;
    if (chrome.footerChip(c, "Show in Finder", "⌘↵", revealable)) p.ask(.{ .reveal = row.?.path });
    if (chrome.footerChip(c, "Copy", "⌘C", row != null)) p.ask(.{ .copy = row.? });
}

fn rowView(p: anytype, c: *ui.Context, i: usize) void {
    const r = &p.list.visible[i];
    if ((r.kind == .file or r.kind == .folder) and !r.stamped) {
        const a = p.list.allocator();
        search.stamp(a, r);
        if (r.modified) |secs| r.modified_label = p.hooks.describe_date(p.hooks.ctx, secs, a);
    }
    const row = r.*;
    ui.keyInt(c, i);
    const selected = i == p.list.selected;
    const top_hit = p.isTopHit(i);
    const row_box = chrome.rowBox(c, selected, top_hit);
    defer row_box.box.end();
    const it = row_box.it;
    if (it.clicked) {
        p.list.selected = i;
        p.pending_select_key = null;
    }
    if (it.double_clicked) p.ask(.{ .open = row.path });
    {
        const lead = chrome.rowLead(c, top_hit);
        defer lead.end();
        iconView(p, c, row, if (top_hit) metrics.top_hit_icon_size else metrics.icon_size);
        const text = ui.div(c).column().grow().gap(space.text);
        defer text.end();
        if (top_hit) {
            ui.text(c, row.title, .{ .size = type_size.top_hit_title, .weight = .semibold, .truncate = .ellipsis });
        } else if (row.suggestion) {
            suggestionTitle(p, c, row.title);
        } else {
            ui.text(c, row.title, .{ .size = type_size.row_title, .weight = .medium, .truncate = .ellipsis });
        }
        subtitleLine(c, row, top_hit);
    }
    chrome.rowKey(c, if (selected)
        .enter
    else if (p.field.text().len == 0 and i > 0 and i < search.max_suggested_apps)
        .{ .label = c.print("\u{2318}{d}", .{i + 1}) }
    else
        .none);
}

/// The part of a suggestion past the typed query is bold.
fn suggestionTitle(p: anytype, c: *ui.Context, title: []const u8) void {
    const query = p.field.text();
    const trimmed = std.mem.trim(u8, query, " ");
    const prefix_len: usize = if (query.len > 0 and std.ascii.startsWithIgnoreCase(title, query))
        query.len
    else if (trimmed.len > 0 and std.ascii.startsWithIgnoreCase(title, trimmed))
        trimmed.len
    else
        0;
    const style: ui.TextStyle = .{ .size = type_size.row_title, .weight = .regular, .truncate = .ellipsis };
    if (prefix_len >= title.len) return ui.text(c, title, style);
    const spans = c.arena.allocator().dupe(ui.Span, &.{
        .{ .start = @intCast(prefix_len), .end = @intCast(title.len), .weight = .bold },
    }) catch return ui.text(c, title, style);
    ui.richText(c, title, spans, style);
}

fn subtitleLine(c: *ui.Context, row: search.Row, top_hit: bool) void {
    const style: ui.TextStyle = .{ .size = type_size.chip, .weight = .medium, .color = chrome.tone(c.theme).secondary };
    const line = ui.div(c).row().gap(space.snug).itemsCenter();
    defer line.end();
    ui.text(c, row.subtitle, .{ .size = style.size, .weight = style.weight, .color = style.color, .truncate = .ellipsis });
    if (row.size) |size| if (size > 0) {
        ui.text(c, "·", style);
        ui.text(c, chrome.formatSize(c, size), style);
    };
    if (row.modified_label.len > 0) {
        ui.text(c, "·", style);
        ui.text(c, row.modified_label, style);
    }
    if (top_hit) {
        ui.text(c, "·", style);
        ui.text(c, "Top Hit", style);
    } else {
        ui.text(c, "·", style);
        ui.text(c, row.kind.label(), style);
    }
}

fn iconView(p: anytype, c: *ui.Context, row: search.Row, size: f32) void {
    if (row.kind != .web) if (p.hooks.app_icon(p.hooks.ctx, row.path)) |px| {
        _ = ui.image(c, .{ .key = row.path, .source = .{ .pixels = px }, .max_width = size, .max_height = size, .radius = 0 });
        return;
    };
    const blue = chrome.hue(c.theme, .blue);
    const tile = ui.div(c).w(size).h(size).center().rounded(metrics.icon_tile_radius).bg(blue.alpha(chrome.fill.tile));
    defer tile.end();
    ui.icon(c, row.kind.symbol(), .{ .size = size * metrics.tile_symbol_scale, .color = blue });
}
