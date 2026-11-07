//! The search panel: a field over ranked rows of apps and files. It draws
//! no background of its own; the window's glass slab is behind it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");
const chrome = @import("chrome.zig");
const list = @import("list.zig");

const metrics = chrome.metrics;

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
            .images => r.kind == .file and clipboard.inSet(ext, &clipboard.image_extensions),
            .documents => r.kind == .file and clipboard.inSet(ext, &document_extensions),
        };
    }
};

const document_extensions = [_][]const u8{ "azw", "azw3", "cbr", "cbz", "csv", "djvu", "doc", "docx", "epub", "fb2", "key", "md", "mobi", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls", "xlsx" };

fn rowKey(r: search.Row) u64 {
    return std.hash.Wyhash.hash(0, r.path);
}

pub const Results = list.List(search.Row, Filter, u64, rowKey);

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
    list: Results,
    indexing: bool = false,
    pending: ?Action = null,
    height: f32 = metrics.search_height,
    width: f32 = metrics.width,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, store: ?*const clipboard.Store, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .hooks = hooks, .list = .init(gpa), .board = .init(gpa, store) };
    }

    pub fn deinit(p: *Panel) void {
        p.board.deinit();
        p.field.deinit();
        p.list.deinit();
    }

    /// Hidden panels keep nothing per session: the query, the rows, and
    /// the arena behind them all go (PR #130's rule for the Swift panel).
    pub fn reset(p: *Panel) void {
        p.field.clear();
        p.list.reset();
        p.pending = null;
        p.mode = .search;
        p.board.reset();
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// The board, with history listed before anything is typed.
    pub fn showClipboard(p: *Panel) void {
        p.mode = .clipboard;
        p.field.clear();
        p.board.list.markStale();
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
        if (!p.list.needsQuery(text)) return;
        p.answer(text) catch |err| {
            std.log.err("search: {s}", .{@errorName(err)});
            return p.list.fail();
        };
        const l = &p.list;
        if (l.filter != .all and l.count(l.filter) == 0 and std.mem.indexOfScalar(Filter, &Filter.dynamic, l.filter) != null) l.selectFilter(.all);
    }

    fn answer(p: *Panel, text: []const u8) !void {
        try p.list.setRows(text, try p.catalog.query(p.list.beginQuery(text), text));
    }

    pub fn filterOptions(p: *const Panel, buf: *[Filter.primary.len + Filter.dynamic.len]Filter) []const Filter {
        var n: usize = 0;
        for (Filter.primary) |f| {
            buf[n] = f;
            n += 1;
        }
        for (Filter.dynamic) |f| if (p.list.filter == f or p.list.count(f) > 0) {
            buf[n] = f;
            n += 1;
        };
        return buf[0..n];
    }

    pub fn selectFilter(p: *Panel, f: Filter) void {
        p.list.selectFilter(f);
        p.field.focus();
    }

    pub fn isTopHit(p: *const Panel, i: usize) bool {
        return i == 0 and p.list.visible.len > 0 and p.list.filter == .all;
    }

    fn ask(p: *Panel, a: Action) void {
        p.pending = a;
        p.hooks.request(p.hooks.ctx);
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
        if (chrome.listKeys(c, &p.list, options[0..@min(options.len, 5)])) p.field.focus();
        const row = p.list.selection() orelse return;
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
            const cx: board_mod.Context = .{ .ctx = p.hooks.ctx, .app_icon = p.hooks.app_icon, .detailed_date = p.hooks.detailed_date, .query = p.field.text() };
            if (p.board.view(c, cx)) |a| p.ask(.{ .clipboard = a });
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
            if (std.mem.eql(u8, p.field.text(), " ")) if (p.board.list.selection()) |e| if (p.board.previewable(e)) {
                p.field.clear();
                return p.ask(.{ .clipboard = .{ .preview = e } });
            };
            p.refresh();
        }
        if (r.submitted) if (p.board.list.selection()) |e| p.ask(.{ .clipboard = .{ .paste = e } });
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
            if (r.submitted) if (p.list.selection()) |row| p.ask(.{ .open = row.path });
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
        } else chrome.keyChip(c, .{ .label = if (board) board_mod.summon_label else summon_label });
    }

    fn filterBar(p: *Panel, c: *ui.Context) void {
        const bar = chrome.filterBar(c);
        defer bar.end();
        var buf: [Filter.primary.len + Filter.dynamic.len]Filter = undefined;
        for (p.filterOptions(&buf)) |f| {
            const slot: chrome.ChipSlot = if (p.indexing and f != .apps) .loading else .{ .count = p.list.count(f) };
            if (chrome.filterChip(c, f.title(), f.symbol(), p.list.filter == f, slot)) p.selectFilter(f);
        }
    }

    fn resultList(p: *Panel, c: *ui.Context) void {
        if (p.list.visible.len == 0) {
            const message = if (p.list.failed)
                c.print("Could not search for \u{201C}{s}\u{201D}", .{p.field.text()})
            else
                c.print("No {s} results for \u{201C}{s}\u{201D}", .{ chrome.lowerTitle(c, p.list.filter), p.field.text() });
            return chrome.emptyState(c, metrics.list_height, message, false);
        }
        const box = ui.div(c).column().wFull().h(metrics.list_height).scrollY().p(metrics.row_padding);
        defer box.end();
        chrome.boundOverscroll(c, box.id());
        chrome.revealSelection(c, &p.list, box.id(), metrics.list_height - 2 * metrics.row_padding);
        for (p.list.visible, 0..) |row, i| p.rowView(c, row, i);
    }

    fn rowView(p: *Panel, c: *ui.Context, row: search.Row, i: usize) void {
        const th = c.theme;
        ui.keyInt(c, i);
        const selected = i == p.list.selected;
        const top_hit = p.isTopHit(i);
        const row_box = chrome.rowBox(c, selected, top_hit);
        defer row_box.box.end();
        const it = row_box.it;
        if (it.clicked) p.list.selected = i;
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
        if (selected) chrome.keyChip(c, .{ .symbol = "return" });
    }

    fn subtitleLine(p: *Panel, c: *ui.Context, row: search.Row, top_hit: bool) void {
        const style: ui.TextStyle = .{ .size = 11.5, .weight = .medium, .color = c.theme.muted };
        const line = ui.div(c).row().gap(6).itemsCenter();
        defer line.end();
        ui.text(c, row.subtitle, .{ .size = style.size, .weight = style.weight, .color = style.color, .truncate = .ellipsis });
        if (row.size) |size| if (size > 0) {
            ui.text(c, "·", style);
            ui.text(c, chrome.formatSize(c, size), style);
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
