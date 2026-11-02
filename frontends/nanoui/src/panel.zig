//! The search panel: a field over ranked rows of apps and files. It draws
//! no background of its own; the window's glass slab is behind it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");

/// The Swift shell's `FloodlightMetrics`, so both panels measure the same.
pub const metrics = struct {
    pub const width: f32 = 680;
    pub const search_height: f32 = 60;
    pub const corner_radius: f32 = search_height / 2;
    pub const row_height: f32 = 58;
    pub const row_padding: f32 = 7;
    pub const row_radius: f32 = 12;
    pub const icon_size: f32 = 38;
    pub const banner_height: f32 = 40;
};

pub const Action = union(enum) {
    open: []const u8,
    reveal: []const u8,
    hide,
    grant_access,
};

/// What the panel asks of the window, handled after the frame.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// An action, or a new height to fit the rows.
    request: *const fn (?*anyopaque) void,
    /// An app's icon as PNG, cached by the shell; null draws a symbol.
    app_icon: *const fn (?*anyopaque, []const u8) ?[]const u8,
};

pub const Panel = struct {
    catalog: *search.Catalog,
    hooks: Hooks,
    field: ui.TextBuffer = .{},
    arena: std.heap.ArenaAllocator,
    rows: []search.Row = &.{},
    /// The query `rows` answers, to search again only when it changes.
    answered: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    needs_access: bool = false,
    indexing: bool = false,
    pending: ?Action = null,
    height: f32 = metrics.search_height,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .hooks = hooks, .arena = .init(gpa) };
    }

    pub fn deinit(p: *Panel) void {
        p.field.deinit();
        p.answered.deinit(p.arena.child_allocator);
        p.arena.deinit();
    }

    /// Hidden panels keep nothing per session: the query, the rows, and
    /// the arena behind them all go (PR #130's rule for the Swift panel).
    pub fn reset(p: *Panel) void {
        p.field.clear();
        p.rows = &.{};
        p.answered.clearRetainingCapacity();
        p.selected = 0;
        p.pending = null;
        _ = p.arena.reset(.free_all);
        p.height = p.fitHeight();
    }

    /// The window height that shows every row without scrolling.
    pub fn fitHeight(p: *const Panel) f32 {
        var h = metrics.search_height;
        if (p.rows.len > 0) h += @as(f32, @floatFromInt(p.rows.len)) * metrics.row_height + 2 * metrics.row_padding;
        if (p.needs_access) h += metrics.banner_height;
        return h;
    }

    /// Searches again when the text changed since the last answer.
    pub fn refresh(p: *Panel) void {
        const text = p.field.text();
        if (std.mem.eql(u8, text, p.answered.items)) return;
        _ = p.arena.reset(.retain_capacity);
        p.rows = p.catalog.query(p.arena.allocator(), text) catch &.{};
        p.answered.clearRetainingCapacity();
        p.answered.appendSlice(p.arena.child_allocator, text) catch {};
        p.selected = 0;
    }

    fn ask(p: *Panel, a: Action) void {
        p.pending = a;
        p.hooks.request(p.hooks.ctx);
    }

    fn keys(p: *Panel, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) return p.ask(.hide);
        if (p.rows.len == 0) return;
        if (c.shortcut(.{ .key = S.down })) p.selected = (p.selected + 1) % p.rows.len;
        if (c.shortcut(.{ .key = S.up })) p.selected = (p.selected + p.rows.len - 1) % p.rows.len;
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) p.ask(.{ .reveal = p.rows[p.selected].path });
    }

    pub fn view(p: *Panel, c: *ui.Context) void {
        p.keys(c);
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        {
            const bar = ui.div(c).row().wFull().h(metrics.search_height).px(20).gap(12).itemsCenter();
            defer bar.end();
            ui.icon(c, "magnifyingglass", .{ .size = 20, .weight = .medium, .color = c.theme.muted });
            if (p.field.text().len == 0) p.field.focus();
            const r = ui.textField(c, &p.field, .{ .placeholder = "Search apps and files", .size = 22, .width = .fill, .bare = true });
            if (r.changed) p.refresh();
            if (r.submitted and p.rows.len > 0) p.ask(.{ .open = p.rows[p.selected].path });
            if (p.indexing) ui.text(c, "Indexing…", .{ .size = 11.5, .color = c.theme.muted });
        }
        if (p.rows.len > 0) {
            const list = ui.div(c).column().wFull().p(metrics.row_padding);
            defer list.end();
            for (p.rows, 0..) |row, i| p.rowView(c, row, i);
        }
        if (p.needs_access) p.bannerView(c);
        const want = p.fitHeight();
        if (want != p.height) {
            p.height = want;
            p.hooks.request(p.hooks.ctx);
        }
    }

    fn rowView(p: *Panel, c: *ui.Context, row: search.Row, i: usize) void {
        const th = c.theme;
        ui.keyInt(c, i);
        const selected = i == p.selected;
        var box = ui.div(c).row().wFull().h(metrics.row_height).px(10).gap(12).itemsCenter().rounded(metrics.row_radius).control();
        if (selected) box = box.bg(th.text.alpha(0.08));
        defer box.end();
        if (box.hovered()) p.selected = i;
        if (box.clicked()) p.ask(.{ .open = row.path });
        p.iconView(c, row);
        const text = ui.div(c).column().grow().gap(2);
        defer text.end();
        ui.text(c, row.title, .{ .size = 15, .weight = .medium, .truncate = .ellipsis });
        ui.text(c, row.subtitle, .{ .size = 11.5, .weight = .medium, .color = th.muted, .truncate = .middle });
    }

    fn iconView(p: *Panel, c: *ui.Context, row: search.Row) void {
        if (row.kind == .app) if (p.hooks.app_icon(p.hooks.ctx, row.path)) |png| {
            _ = ui.image(c, .{ .key = row.path, .bytes = png, .max_width = metrics.icon_size, .max_height = metrics.icon_size, .radius = 0 });
            return;
        };
        const symbol = switch (row.kind) {
            .app => "app.dashed",
            .folder => "folder.fill",
            .file => "doc.fill",
        };
        const tile = ui.div(c).w(metrics.icon_size).h(metrics.icon_size).center().rounded(9).bg(c.theme.accent.alpha(0.14));
        defer tile.end();
        ui.icon(c, symbol, .{ .size = 18, .color = c.theme.accent });
    }

    fn bannerView(p: *Panel, c: *ui.Context) void {
        const th = c.theme;
        const bar = ui.div(c).row().wFull().h(metrics.banner_height).px(20).gap(8).itemsCenter().control();
        defer bar.end();
        ui.icon(c, "lock.shield", .{ .size = 13, .color = th.accent });
        ui.text(c, "Grant Full Disk Access to search every folder", .{ .size = 12, .weight = .medium, .color = th.muted });
        ui.spacer(c);
        ui.text(c, "Grant…", .{ .size = 12, .weight = .semibold, .color = th.accent });
        if (bar.clicked()) p.ask(.grant_access);
    }
};
