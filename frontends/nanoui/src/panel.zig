//! The search panel: a field over ranked rows of apps and files. It draws
//! no background of its own; the window's glass slab is behind it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");

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
    pub const expanded_height: f32 = search_height + 1 + filter_bar_height + row_padding * 2 + max_visible_rows * row_height;
    pub const list_height: f32 = expanded_height - search_height - 1 - filter_bar_height;
};

pub const summon_label = "⌥ Space";

pub const Filter = enum {
    all,
    apps,
    files,
    folders,
    pdfs,
    images,
    documents,

    pub const primary = [_]Filter{ .all, .apps, .files, .folders };
    pub const dynamic = [_]Filter{ .pdfs, .images, .documents };

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All",
            .apps => "Apps",
            .files => "Files",
            .folders => "Folders",
            .pdfs => "PDFs",
            .images => "Images",
            .documents => "Documents",
        };
    }

    pub fn symbol(f: Filter) []const u8 {
        return switch (f) {
            .all => "sparkle.magnifyingglass",
            .apps => "square.grid.2x2.fill",
            .files => "doc.text.fill",
            .folders => "folder.fill",
            .pdfs => "doc.richtext.fill",
            .images => "photo.fill",
            .documents => "doc.fill",
        };
    }

    pub fn includes(f: Filter, r: search.Row) bool {
        const ext = r.extension();
        return switch (f) {
            .all => true,
            .apps => r.kind == .app,
            .files => r.kind == .file,
            .folders => r.kind == .folder,
            .pdfs => r.kind == .file and std.ascii.eqlIgnoreCase(ext, "pdf"),
            .images => r.kind == .file and inSet(ext, &image_extensions),
            .documents => r.kind == .file and inSet(ext, &document_extensions),
        };
    }
};

const image_extensions = [_][]const u8{ "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp" };
const document_extensions = [_][]const u8{ "azw", "azw3", "cbr", "cbz", "csv", "djvu", "doc", "docx", "epub", "fb2", "key", "md", "mobi", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls", "xlsx" };

fn inSet(ext: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.ascii.eqlIgnoreCase(ext, s)) return true;
    return false;
}

pub const Action = union(enum) {
    open: []const u8,
    reveal: []const u8,
    copy: search.Row,
    hide,
    clipboard: board_mod.Action,
};

pub const Mode = enum { search, clipboard };

/// What the panel asks of the window, handled after the frame.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// An action, or a new height to fit the rows.
    request: *const fn (?*anyopaque) void,
    /// An app's icon as PNG, cached by the shell; null draws a symbol.
    app_icon: *const fn (?*anyopaque, []const u8) ?[]const u8,
    describe_date: *const fn (?*anyopaque, i64, std.mem.Allocator) []const u8,
    /// "Today at 3:03 PM": the board inspector's Copied and Pinned.
    detailed_date: *const fn (?*anyopaque, f64, std.mem.Allocator) []const u8,
};

pub const Panel = struct {
    catalog: *search.Catalog,
    hooks: Hooks,
    mode: Mode = .search,
    board: board_mod.Board,
    field: ui.TextBuffer = .{},
    arena: std.heap.ArenaAllocator,
    rows: []search.Row = &.{},
    visible: []search.Row = &.{},
    /// The query `rows` answers, to search again only when it changes.
    answered: std.ArrayList(u8) = .empty,
    filter: Filter = .all,
    selected: usize = 0,
    reveal_selection: bool = false,
    indexing: bool = false,
    pending: ?Action = null,
    height: f32 = metrics.search_height,
    width: f32 = metrics.width,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, store: ?*const clipboard.Store, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .hooks = hooks, .arena = .init(gpa), .board = .init(gpa, store) };
    }

    pub fn deinit(p: *Panel) void {
        p.board.deinit();
        p.field.deinit();
        p.answered.deinit(p.arena.child_allocator);
        p.arena.deinit();
    }

    /// Hidden panels keep nothing per session: the query, the rows, and
    /// the arena behind them all go (PR #130's rule for the Swift panel).
    pub fn reset(p: *Panel) void {
        p.field.clear();
        p.rows = &.{};
        p.visible = &.{};
        p.answered.clearRetainingCapacity();
        p.filter = .all;
        p.selected = 0;
        p.pending = null;
        p.mode = .search;
        p.board.reset();
        _ = p.arena.reset(.free_all);
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// The board, with history listed before anything is typed.
    pub fn showClipboard(p: *Panel) void {
        p.mode = .clipboard;
        p.field.clear();
        p.board.stale = true;
        p.board.refresh("");
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    pub fn panelHeight(p: *const Panel) f32 {
        if (p.mode == .clipboard) return board_mod.board_metrics.height;
        return if (p.field.text().len == 0) metrics.search_height else metrics.expanded_height;
    }

    pub fn panelWidth(p: *const Panel) f32 {
        return if (p.mode == .clipboard) board_mod.board_metrics.width else metrics.width;
    }

    /// Searches again when the text changed since the last answer.
    pub fn refresh(p: *Panel) void {
        const text = p.field.text();
        if (p.mode == .clipboard) return p.board.refresh(text);
        if (std.mem.eql(u8, text, p.answered.items)) return;
        _ = p.arena.reset(.retain_capacity);
        p.rows = p.catalog.query(p.arena.allocator(), text) catch &.{};
        p.answered.clearRetainingCapacity();
        p.answered.appendSlice(p.arena.child_allocator, text) catch {};
        if (p.filter != .all and p.count(p.filter) == 0 and std.mem.indexOfScalar(Filter, &Filter.dynamic, p.filter) != null) p.filter = .all;
        p.applyFilter();
    }

    pub fn count(p: *const Panel, f: Filter) usize {
        var n: usize = 0;
        for (p.rows) |r| n += @intFromBool(f.includes(r));
        return n;
    }

    pub fn filterOptions(p: *const Panel, buf: *[Filter.primary.len + Filter.dynamic.len]Filter) []const Filter {
        var n: usize = 0;
        for (Filter.primary) |f| {
            buf[n] = f;
            n += 1;
        }
        for (Filter.dynamic) |f| if (p.filter == f or p.count(f) > 0) {
            buf[n] = f;
            n += 1;
        };
        return buf[0..n];
    }

    pub fn selectFilter(p: *Panel, f: Filter) void {
        p.filter = f;
        p.applyFilter();
        p.field.focus();
    }

    fn applyFilter(p: *Panel) void {
        const out = p.arena.allocator().alloc(search.Row, p.rows.len) catch return;
        var n: usize = 0;
        for (p.rows) |r| if (p.filter.includes(r)) {
            out[n] = r;
            n += 1;
        };
        p.visible = out[0..n];
        p.selected = 0;
        p.reveal_selection = true;
    }

    pub fn isTopHit(p: *const Panel, i: usize) bool {
        return i == 0 and p.visible.len > 0 and p.filter == .all;
    }

    fn ask(p: *Panel, a: Action) void {
        p.pending = a;
        p.hooks.request(p.hooks.ctx);
    }

    fn move(p: *Panel, down: bool) void {
        if (p.visible.len == 0) return;
        p.selected = if (down) @min(p.selected + 1, p.visible.len - 1) else p.selected -| 1;
        p.reveal_selection = true;
    }

    fn keys(p: *Panel, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) return p.ask(.hide);
        if (p.mode == .clipboard) {
            if (p.board.keys(c, p.field.text().len == 0)) |a| p.ask(.{ .clipboard = a });
            return;
        }
        var buf: [Filter.primary.len + Filter.dynamic.len]Filter = undefined;
        const options = p.filterOptions(&buf);
        for (options, 0..) |f, i| {
            if (i >= 5) break;
            if (c.shortcut(.{ .key = '1' + @as(u21, @intCast(i)), .cmd = true })) p.selectFilter(f);
        }
        if (p.visible.len == 0) return;
        if (c.shortcut(.{ .key = S.down })) p.move(true);
        if (c.shortcut(.{ .key = S.up })) p.move(false);
        const row = p.visible[p.selected];
        if (c.shortcut(.{ .key = S.enter, .cmd = true }) or c.shortcut(.{ .key = 'r', .cmd = true })) {
            if (row.kind != .web) p.ask(.{ .reveal = row.path });
        }
        if (c.shortcut(.{ .key = S.enter, .alt = true })) p.ask(.{ .copy = row });
    }

    pub fn view(p: *Panel, c: *ui.Context) void {
        p.keys(c);
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        p.searchBar(c);
        if (p.mode == .clipboard) {
            if (p.board.view(c, p)) |a| p.ask(.{ .clipboard = a });
        } else if (p.field.text().len > 0) {
            ui.div(c).wFull().h(1).bg(c.theme.border.alpha(0.45)).end();
            p.filterBar(c);
            p.resultList(c);
        }
        const want_h = p.panelHeight();
        const want_w = p.panelWidth();
        if (want_h != p.height or want_w != p.width) {
            p.height = want_h;
            p.width = want_w;
            p.hooks.request(p.hooks.ctx);
        }
    }

    /// Return on the board pastes; a Space typed into an empty filter
    /// previews, as the Swift board's.
    fn boardField(p: *Panel, r: anytype) void {
        if (r.changed) {
            if (std.mem.eql(u8, p.field.text(), " ")) if (p.board.selection()) |e| if (p.board.previewable(e)) {
                p.field.clear();
                return p.ask(.{ .clipboard = .{ .preview = e } });
            };
            p.refresh();
        }
        if (r.submitted) if (p.board.selection()) |e| p.ask(.{ .clipboard = .{ .paste = e } });
    }

    fn searchBar(p: *Panel, c: *ui.Context) void {
        const th = c.theme;
        const bar = ui.div(c).row().wFull().h(metrics.search_height).px(20).gap(12).itemsCenter();
        defer bar.end();
        ui.icon(c, "magnifyingglass", .{ .size = metrics.search_icon_size, .weight = .medium, .color = th.muted, .frame = metrics.search_icon_size });
        if (p.field.text().len == 0) p.field.focus();
        const board = p.mode == .clipboard;
        const r = ui.textField(c, &p.field, .{ .placeholder = if (board) "Filter clipboard" else "Floodlight", .size = 24, .width = .fill, .bare = true });
        if (board) {
            p.boardField(r);
        } else {
            if (r.changed) p.refresh();
            if (r.submitted and p.visible.len > 0) p.ask(.{ .open = p.visible[p.selected].path });
        }
        if (p.field.text().len > 0) {
            const clear = ui.div(c).w(24).h(24).center().control();
            defer clear.end();
            const hovered = clear.hovered();
            ui.icon(c, "xmark.circle.fill", .{ .size = metrics.clear_button_size, .color = if (hovered) th.text else th.muted });
            if (clear.clicked()) {
                p.field.clear();
                p.refresh();
            }
        } else keyChip(c, .{ .label = if (board) board_mod.summon_label else summon_label });
    }

    fn filterBar(p: *Panel, c: *ui.Context) void {
        const bar = ui.div(c).row().wFull().h(metrics.filter_bar_height).px(14).gap(7).itemsCenter().clip();
        defer bar.end();
        var buf: [Filter.primary.len + Filter.dynamic.len]Filter = undefined;
        for (p.filterOptions(&buf)) |f| p.filterChip(c, f);
    }

    fn filterChip(p: *Panel, c: *ui.Context, f: Filter) void {
        const th = c.theme;
        ui.key(c, f.title());
        const selected = p.filter == f;
        const chip = ui.div(c).row().h(26).pl(10).pr(7).gap(5).itemsCenter().roundedFull()
            .bg(th.text.alpha(if (selected) 0.14 else 0.055)).control();
        defer chip.end();
        if (chip.clicked()) p.selectFilter(f);
        ui.icon(c, f.symbol(), .{ .size = 11, .weight = .semibold, .color = if (selected) th.text else th.muted });
        ui.text(c, f.title(), .{ .size = 11.5, .weight = .semibold });
        const slot = ui.div(c).w(27).h(13).center();
        defer slot.end();
        const loading = p.indexing and f != .apps;
        if (loading) {
            ui.icon(c, "ellipsis", .{ .size = 10, .weight = .semibold, .color = th.muted });
        } else {
            ui.text(c, compactCount(c, p.count(f)), .{ .size = 10, .weight = .semibold, .color = th.muted });
        }
    }

    fn resultList(p: *Panel, c: *ui.Context) void {
        if (p.visible.len == 0) {
            const empty = ui.div(c).column().wFull().h(metrics.list_height).center().px(40);
            defer empty.end();
            ui.text(c, c.print("No {s} results for \u{201C}{s}\u{201D}", .{ lowerTitle(c, p.filter), p.field.text() }), .{ .size = 13.5, .weight = .medium, .color = c.theme.muted.alpha(0.6) });
            return;
        }
        const list = ui.div(c).column().wFull().h(metrics.list_height).scrollY().p(metrics.row_padding);
        defer list.end();
        if (p.reveal_selection) {
            p.reveal_selection = false;
            const id = list.id();
            const top = @as(f32, @floatFromInt(p.selected)) * metrics.row_height;
            const view_h = metrics.list_height - 2 * metrics.row_padding;
            const now = c.scroll.get(id) orelse 0;
            if (top < now) c.setScroll(id, .y, top) else if (top + metrics.row_height > now + view_h) c.setScroll(id, .y, top + metrics.row_height - view_h);
        }
        for (p.visible, 0..) |row, i| p.rowView(c, row, i);
    }

    fn rowView(p: *Panel, c: *ui.Context, row: search.Row, i: usize) void {
        const th = c.theme;
        ui.keyInt(c, i);
        const selected = i == p.selected;
        const top_hit = p.isTopHit(i);
        var box = ui.div(c).row().wFull().h(metrics.row_height).px(12).gap(12).itemsCenter().rounded(metrics.row_radius).control();
        const it = c.interact(box.index, .{});
        box = box.bg(rowFill(th, selected, it.hovered, top_hit));
        defer box.end();
        if (it.clicked) p.selected = i;
        if (it.double_clicked) p.ask(.{ .open = row.path });
        p.iconView(c, row, if (top_hit) metrics.top_hit_icon_size else metrics.icon_size);
        {
            const text = ui.div(c).column().grow().gap(3);
            defer text.end();
            {
                const head = ui.div(c).row().gap(7).itemsCenter();
                defer head.end();
                if (top_hit) {
                    ui.text(c, row.title, .{ .size = 19, .weight = .semibold, .truncate = .ellipsis });
                } else {
                    ui.text(c, row.title, .{ .size = 15, .weight = .medium, .truncate = .ellipsis });
                    const badge = ui.div(c).px(5).py(2).roundedFull().bg(th.muted.alpha(0.07));
                    defer badge.end();
                    ui.text(c, row.kind.label(), .{ .size = 8.5, .weight = .bold, .color = th.muted });
                }
            }
            p.subtitleLine(c, row, top_hit);
        }
        if (selected) keyChip(c, .{ .symbol = "return" });
    }

    fn subtitleLine(p: *Panel, c: *ui.Context, row: search.Row, top_hit: bool) void {
        const style: ui.TextStyle = .{ .size = 11.5, .weight = .medium, .color = c.theme.muted };
        const line = ui.div(c).row().gap(6).itemsCenter();
        defer line.end();
        ui.text(c, row.subtitle, .{ .size = style.size, .weight = style.weight, .color = style.color, .truncate = .ellipsis });
        if (row.size) |size| if (size > 0) {
            ui.text(c, "·", style);
            ui.text(c, formatSize(c, size), style);
        };
        if (row.modified) |secs| {
            ui.text(c, "·", style);
            ui.text(c, p.hooks.describe_date(p.hooks.ctx, secs, c.arena.allocator()), style);
        }
        if (top_hit) {
            ui.text(c, "·", style);
            ui.text(c, "Top Hit", style);
        }
    }

    fn iconView(p: *Panel, c: *ui.Context, row: search.Row, size: f32) void {
        if (row.kind != .web) if (p.hooks.app_icon(p.hooks.ctx, row.path)) |png| {
            _ = ui.image(c, .{ .key = row.path, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        };
        const tile = ui.div(c).w(size).h(size).center().rounded(metrics.icon_tile_radius).bg(c.theme.accent.alpha(0.14));
        defer tile.end();
        ui.icon(c, row.kind.symbol(), .{ .size = size * 0.58, .color = c.theme.accent });
    }
};

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

fn lowerTitle(c: *ui.Context, f: Filter) []const u8 {
    return std.ascii.allocLowerString(c.arena.allocator(), f.title()) catch f.title();
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
