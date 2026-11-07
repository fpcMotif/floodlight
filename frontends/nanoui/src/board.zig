//! The clipboard board: history on the left, the selected entry's preview
//! and information on the right, the paste, preview and actions chips
//! below, all on one solid well under the glass search row.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const clipboard = @import("clipboard.zig");
const panel = @import("panel.zig");

const Entry = clipboard.Entry;
const Filter = clipboard.Filter;
const metrics = panel.metrics;

/// The Swift shell's `FloodlightMetrics` clipboard values.
pub const board_metrics = struct {
    pub const list_width: f32 = 360;
    pub const inspector_width: f32 = 465;
    pub const well_inset: f32 = metrics.row_padding;
    pub const width: f32 = list_width + 1 + inspector_width + well_inset * 2;
    pub const well_radius: f32 = metrics.corner_radius - well_inset;
    pub const well_stroke_opacity: f32 = 0.12;
    pub const footer_height: f32 = 32;
    pub const footer_chip_disabled_opacity: f32 = 0.4;
    pub const height: f32 = metrics.search_height + metrics.filter_bar_height + metrics.row_padding * 2 +
        metrics.max_visible_rows * metrics.row_height + 1 + footer_height + well_inset;
    pub const content_height: f32 = height - metrics.search_height - well_inset - metrics.filter_bar_height;
    pub const list_height: f32 = content_height - 1 - footer_height;
    pub const info_label_width: f32 = 84;
};

pub const summon_label = "⌥⇧ C";

const held_key_gap_seconds = 0.15;
const detail_kept_bytes = 1 << 20;
const max_line_bytes = 200;
const max_plain_lines = 40;
const max_link_lines = 6;

pub fn shownHead(text: []const u8, lines: usize) []const u8 {
    var end = lines * max_line_bytes;
    if (text.len <= end) return text;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// What the board asks of the shell. Pin and delete it does itself.
pub const Action = union(enum) {
    paste: Entry,
    copy: Entry,
    reveal: []const u8,
    preview: Entry,
    actions: Entry,
};

/// A file's bytes, read once per selection for its preview.
const FilePreview = union(enum) {
    none,
    image: []const u8,
    text: []const u8,
};

pub const Board = struct {
    store: ?*const clipboard.Store,
    arena: std.heap.ArenaAllocator,
    /// The selection's payload: a full image, a file's head.
    detail_arena: std.heap.ArenaAllocator,
    rows: []Entry = &.{},
    visible: []Entry = &.{},
    answered: std.ArrayList(u8) = .empty,
    stale: bool = true,
    filter: Filter = .all,
    selected: usize = 0,
    reveal_selection: bool = false,
    clock: clipboard.Clock = .wall_clock,
    /// The app Return pastes into; empty when Return only copies.
    paste_target: []const u8 = "",
    detail_id: ?i64 = null,
    detail_at: f64 = 0,
    detail_passing: bool = false,
    detail_loaded: bool = false,
    full_image: ?[]const u8 = null,
    file_preview: FilePreview = .none,
    file_size: ?u64 = null,
    file_is_dir: bool = false,

    pub fn init(gpa: std.mem.Allocator, store: ?*const clipboard.Store, clock: clipboard.Clock) Board {
        return .{ .store = store, .clock = clock, .arena = .init(gpa), .detail_arena = .init(gpa) };
    }

    pub fn deinit(b: *Board) void {
        b.answered.deinit(b.arena.child_allocator);
        b.arena.deinit();
        b.detail_arena.deinit();
    }

    pub fn forget(b: *Board) void {
        b.rows = &.{};
        b.visible = &.{};
        b.answered.clearRetainingCapacity();
        b.stale = true;
        b.filter = .all;
        b.selected = 0;
        b.detail_id = null;
        _ = b.arena.reset(.free_all);
        _ = b.detail_arena.reset(.free_all);
    }

    /// Asks the store again when the query changed or history did.
    pub fn refresh(b: *Board, query: []const u8) void {
        if (!b.stale and std.mem.eql(u8, query, b.answered.items)) return;
        const keep = if (b.selection()) |e| e.id else null;
        const was_stale = b.stale;
        b.stale = false;
        _ = b.arena.reset(.retain_capacity);
        const store = b.store orelse return;
        b.rows = store.list(b.arena.allocator(), query) catch &.{};
        const query_changed = !std.mem.eql(u8, query, b.answered.items);
        b.answered.clearRetainingCapacity();
        b.answered.appendSlice(b.arena.child_allocator, query) catch {};
        b.applyFilter();
        // History changing under the board keeps the selection where it can.
        if (was_stale and !query_changed) if (keep) |id| for (b.visible, 0..) |e, i| if (e.id == id) {
            b.selected = i;
        };
    }

    pub fn count(b: *const Board, f: Filter) usize {
        var n: usize = 0;
        for (b.rows) |e| n += @intFromBool(f.includes(e));
        return n;
    }

    pub fn selectFilter(b: *Board, f: Filter) void {
        b.filter = f;
        b.applyFilter();
    }

    fn applyFilter(b: *Board) void {
        const out = b.arena.allocator().alloc(Entry, b.rows.len) catch return;
        var n: usize = 0;
        for (b.rows) |e| if (b.filter.includes(e)) {
            out[n] = e;
            n += 1;
        };
        b.visible = out[0..n];
        b.selected = 0;
        b.reveal_selection = true;
    }

    pub fn selection(b: *const Board) ?Entry {
        return if (b.selected < b.visible.len) b.visible[b.selected] else null;
    }

    pub fn move(b: *Board, down: bool) void {
        if (b.visible.len == 0) return;
        b.selected = if (down) @min(b.selected + 1, b.visible.len - 1) else b.selected -| 1;
        b.reveal_selection = true;
    }

    pub fn pasteLabel(b: *const Board, c: *ui.Context) []const u8 {
        return if (b.paste_target.len > 0) c.print("Paste to {s}", .{b.paste_target}) else "Copy";
    }

    /// A file that exists, or an image with bytes to show.
    pub fn previewable(b: *const Board, e: Entry) bool {
        if (e.kind == .image) return e.thumbnail.len > 0 or e.byte_count > 0;
        const path = e.filePath() orelse return false;
        _ = b;
        return exists(path);
    }

    pub fn togglePin(b: *Board) void {
        const e = b.selection() orelse return;
        const store = b.store orelse return;
        store.togglePin(e.id, b.clock.now()) catch return;
        b.stale = true;
    }

    pub fn delete(b: *Board) void {
        const e = b.selection() orelse return;
        const store = b.store orelse return;
        store.delete(e.id) catch return;
        const at = b.selected;
        b.stale = true;
        b.refresh(b.answered.items);
        if (b.visible.len > 0) b.selected = @min(at, b.visible.len - 1);
        b.reveal_selection = true;
    }

    /// Loads what the inspector shows for the selection, once per entry.
    fn loadDetail(b: *Board, c: *ui.Context, e: Entry) void {
        if (b.detail_id != e.id) {
            b.detail_passing = b.detail_id != null and c.time - b.detail_at < held_key_gap_seconds;
            b.detail_id = e.id;
            b.detail_at = c.time;
            b.detail_loaded = false;
            _ = b.detail_arena.reset(.{ .retain_with_limit = detail_kept_bytes });
            b.full_image = null;
            b.file_preview = .none;
            b.file_size = null;
            b.file_is_dir = false;
            if (e.filePath()) |path| if (stat(path)) |st| {
                b.file_is_dir = st.dir;
                if (!st.dir and st.size > 0) b.file_size = st.size;
            };
        }
        if (b.detail_loaded) return;
        const wait = held_key_gap_seconds - (c.time - b.detail_at);
        if (b.detail_passing and wait > 0) return c.frameIn(@floatCast(wait));
        b.detail_loaded = true;
        const a = b.detail_arena.allocator();
        if (e.kind == .image) {
            if (b.store) |s| b.full_image = s.image(a, e.id);
            return;
        }
        const path = e.filePath() orelse return;
        const st = stat(path) orelse return;
        if (st.dir) return;
        const ext = clipboard.extension(path);
        if (clipboard.inSet(ext, &clipboard.image_extensions) and st.size <= clipboard.max_image_bytes) {
            if (readFile(a, path, @intCast(st.size))) |bytes| b.file_preview = .{ .image = bytes };
        } else if (clipboard.inSet(ext, &clipboard.text_extensions)) {
            if (readFile(a, path, @min(st.size, text_preview_bytes))) |bytes| b.file_preview = .{ .text = bytes };
        }
    }

    pub fn keys(b: *Board, c: *ui.Context, field_empty: bool) ?Action {
        const S = ui.Shortcut;
        for (Filter.options, 0..) |f, i| {
            if (c.shortcut(.{ .key = '1' + @as(u21, @intCast(i)), .cmd = true })) b.selectFilter(f);
        }
        if (b.visible.len == 0) return null;
        if (c.shortcut(.{ .key = S.down })) b.move(true);
        if (c.shortcut(.{ .key = S.up })) b.move(false);
        const e = b.visible[b.selected];
        if (c.shortcut(.{ .key = S.enter, .cmd = true }) or c.shortcut(.{ .key = 'r', .cmd = true })) {
            if (e.filePath()) |p| return .{ .reveal = p };
        }
        if (c.shortcut(.{ .key = S.enter, .alt = true }) or c.shortcut(.{ .key = 'c', .cmd = true })) return .{ .copy = e };
        if (c.shortcut(.{ .key = '.', .cmd = true })) b.togglePin();
        if (c.shortcut(.{ .key = 'd', .cmd = true })) b.delete();
        if (c.shortcut(.{ .key = 'k', .cmd = true })) return .{ .actions = e };
        if (c.shortcut(.{ .key = 'y', .cmd = true }) and b.previewable(e)) return .{ .preview = e };
        if (field_empty and c.shortcut(.{ .key = ' ' }) and b.previewable(e)) return .{ .preview = e };
        return null;
    }

    /// The well below the search row; returns what a click asked for.
    pub fn view(b: *Board, c: *ui.Context, p: *panel.Panel) ?Action {
        const th = c.theme;
        const m = board_metrics;
        const outer = ui.div(c).column().wFull().px(m.well_inset).pb(m.well_inset);
        defer outer.end();
        const well = ui.div(c).column().wFull().h(m.height - metrics.search_height - m.well_inset)
            .bg(th.background).rounded(m.well_radius).border(th.text.alpha(m.well_stroke_opacity)).borderW(1).clip();
        defer well.end();
        b.filterBar(c);
        if (b.visible.len == 0) {
            const empty = ui.div(c).column().wFull().h(m.content_height).center().px(40);
            defer empty.end();
            ui.text(c, b.emptyMessage(c, p.field.text()), .{ .size = 13.5, .weight = .medium, .color = th.muted.alpha(0.6), .wrap = true });
            return null;
        }
        var asked: ?Action = null;
        {
            const columns = ui.div(c).row().wFull().h(m.list_height);
            defer columns.end();
            if (b.list(c, p)) |a| asked = a;
            ui.div(c).w(1).hFull().bg(th.border.alpha(0.45)).end();
            b.inspector(c, p);
        }
        ui.div(c).wFull().h(1).bg(th.border.alpha(0.45)).end();
        if (b.footer(c)) |a| asked = a;
        return asked;
    }

    fn emptyMessage(b: *const Board, c: *ui.Context, query: []const u8) []const u8 {
        const name = std.ascii.allocLowerString(c.arena.allocator(), b.filter.title()) catch b.filter.title();
        if (query.len == 0) {
            if (b.filter == .all) return "Clipboard history is empty. Copied text, files, and images will appear here.";
            return c.print("No {s} clipboard entries", .{name});
        }
        return c.print("No matching clipboard {s} for \u{201C}{s}\u{201D}", .{ name, query });
    }

    fn filterBar(b: *Board, c: *ui.Context) void {
        const th = c.theme;
        const bar = ui.div(c).row().wFull().h(metrics.filter_bar_height).px(14).gap(7).itemsCenter().clip();
        defer bar.end();
        for (Filter.options) |f| {
            ui.key(c, f.title());
            const selected = b.filter == f;
            const chip = ui.div(c).row().h(26).pl(10).pr(7).gap(5).itemsCenter().roundedFull()
                .bg(th.text.alpha(if (selected) 0.14 else 0.055)).control();
            defer chip.end();
            if (chip.clicked()) b.selectFilter(f);
            ui.icon(c, f.symbol(), .{ .size = 11, .weight = .semibold, .color = if (selected) th.text else th.muted });
            ui.text(c, f.title(), .{ .size = 11.5, .weight = .semibold });
            const slot = ui.div(c).w(27).h(13).center();
            defer slot.end();
            ui.text(c, panel.compactCount(c, b.count(f)), .{ .size = 10, .weight = .semibold, .color = th.muted });
        }
    }

    fn list(b: *Board, c: *ui.Context, p: *panel.Panel) ?Action {
        const m = board_metrics;
        const col = ui.div(c).column().w(m.list_width).h(m.list_height).scrollY().p(metrics.row_padding);
        defer col.end();
        panel.boundOverscroll(c, col.id());
        if (b.reveal_selection) {
            b.reveal_selection = false;
            const id = col.id();
            const top = @as(f32, @floatFromInt(b.selected)) * metrics.row_height;
            const view_h = m.list_height - 2 * metrics.row_padding;
            const now = c.scroll.get(id) orelse 0;
            if (top < now) c.setScroll(id, .y, top) else if (top + metrics.row_height > now + view_h) c.setScroll(id, .y, top + metrics.row_height - view_h);
        }
        const shown = rowsInView(c.scroll.get(col.id()) orelse 0, b.visible.len);
        spacer(c, "above", shown.first);
        var asked: ?Action = null;
        for (b.visible[shown.first..shown.end], shown.first..) |e, i| if (b.rowView(c, p, e, i)) |a| {
            asked = a;
        };
        spacer(c, "below", b.visible.len - shown.end);
        return asked;
    }

    fn spacer(c: *ui.Context, name: []const u8, rows: usize) void {
        if (rows == 0) return;
        ui.key(c, name);
        ui.div(c).wFull().h(@as(f32, @floatFromInt(rows)) * metrics.row_height).end();
    }

    fn rowView(b: *Board, c: *ui.Context, p: *panel.Panel, e: Entry, i: usize) ?Action {
        const th = c.theme;
        ui.keyInt(c, @intCast(e.id));
        const selected = i == b.selected;
        var box = ui.div(c).row().wFull().h(metrics.row_height).px(12).gap(12).itemsCenter().rounded(metrics.row_radius).control();
        const it = c.interact(box.index, .{});
        box = box.bg(panel.rowFill(th, selected, it.hovered, false));
        defer box.end();
        if (it.clicked) b.selected = i;
        b.iconView(c, p, e);
        {
            const text = ui.div(c).column().grow().gap(3);
            defer text.end();
            ui.text(c, e.title(c.arena.allocator()), .{ .size = 15, .weight = .medium, .truncate = .ellipsis });
            {
                const line = ui.div(c).row().gap(5).itemsCenter();
                defer line.end();
                if (e.pinned_at != null) ui.icon(c, "pin.fill", .{ .size = 9, .weight = .semibold, .color = th.muted });
                ui.text(c, e.subtitle(c.arena.allocator(), b.clock.now()), .{ .size = 11.5, .weight = .medium, .color = th.muted, .truncate = .middle });
            }
        }
        if (selected) panel.keyChip(c, .{ .symbol = "return" });
        return if (it.double_clicked) .{ .paste = e } else null;
    }

    fn iconView(b: *Board, c: *ui.Context, p: *panel.Panel, e: Entry) void {
        _ = b;
        const size = metrics.icon_size;
        if (e.kind == .image and e.thumbnail.len > 0) {
            if (ui.image(c, .{ .key = c.print("clip.{d}", .{e.id}), .bytes = e.thumbnail, .max_width = size, .max_height = size, .radius = 6 })) return;
        }
        const tile = struct {
            fn draw(cx: *ui.Context, symbol: []const u8, color: ui.Color) void {
                const t = ui.div(cx).w(size).h(size).center().rounded(metrics.icon_tile_radius).bg(color.alpha(0.14));
                defer t.end();
                ui.icon(cx, symbol, .{ .size = size * 0.5, .color = color });
            }
        }.draw;
        switch (e.kind) {
            .image => return tile(c, "photo", gray),
            .text => switch (e.content()) {
                .link => return tile(c, "link", blue),
                .color => return tile(c, "paintpalette.fill", purple),
                .code => return tile(c, "curlybraces", cyan),
                .plain => return tile(c, "doc.text", gray),
                .path => {},
            },
            .file => {},
        }
        const path = e.filePath().?;
        const ext = clipboard.extension(path);
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.image_extensions)) return tile(c, "photo", cyan);
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.video_extensions)) return tile(c, "video.fill", purple);
        if (p.hooks.app_icon(p.hooks.ctx, path)) |png| {
            _ = ui.image(c, .{ .key = path, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        }
        tile(c, "doc", gray);
    }

    fn inspector(b: *Board, c: *ui.Context, p: *panel.Panel) void {
        const th = c.theme;
        const pane = ui.div(c).column().grow().hFull().bg(th.text.alpha(0.03)).scrollY().p(14).gap(14);
        defer pane.end();
        panel.boundOverscroll(c, pane.id());
        const e = b.selection() orelse {
            ui.text(c, "Select an entry", .{ .size = 13.5, .weight = .medium, .color = th.muted.alpha(0.6) });
            return;
        };
        b.loadDetail(c, e);
        b.preview(c, e);
        ui.div(c).wFull().h(1).bg(th.border.alpha(0.4)).end();
        b.information(c, p, e);
    }

    fn preview(b: *Board, c: *ui.Context, e: Entry) void {
        const th = c.theme;
        const width = board_metrics.inspector_width - 28;
        const col = ui.div(c).column().wFull().gap(8);
        defer col.end();
        if (e.kind == .image) {
            const bytes = b.full_image orelse e.thumbnail;
            mediaBox(c, c.print("clip.full.{d}", .{e.id}), bytes, width);
            return ui.text(c, e.title(c.arena.allocator()), .{ .size = 15, .weight = .semibold, .wrap = true, .max_lines = 2 });
        }
        if (e.filePath()) |path| {
            switch (b.file_preview) {
                .image => |bytes| mediaBox(c, path, bytes, width),
                .text => |bytes| codeLines(c, bytes),
                .none => {},
            }
            return ui.text(c, e.title(c.arena.allocator()), .{ .size = 15, .weight = .semibold, .wrap = true, .max_lines = 2 });
        }
        switch (e.content()) {
            .link => {
                {
                    const head = ui.div(c).row().gap(6).itemsCenter();
                    defer head.end();
                    ui.icon(c, "link", .{ .size = 12, .weight = .semibold, .color = blue });
                    if (clipboard.domain(std.mem.trim(u8, e.text, " \t\r\n"))) |d| ui.text(c, d, .{ .size = 12, .weight = .semibold });
                }
                const box = ui.div(c).wFull().p(8).rounded(6).bg(th.muted.alpha(0.08));
                defer box.end();
                ui.text(c, shownHead(e.text, max_link_lines), .{ .size = 12, .mono = true, .color = th.muted, .wrap = true, .max_lines = max_link_lines });
            },
            .color => {
                const t = std.mem.trim(u8, e.text, " \t\r\n");
                if (clipboard.parseColor(t)) |rgba| {
                    const swatch: ui.Color = .{ .r = @as(f32, @floatFromInt(rgba.r)) / 255, .g = @as(f32, @floatFromInt(rgba.g)) / 255, .b = @as(f32, @floatFromInt(rgba.b)) / 255, .a = if (rgba.a) |a| @as(f32, @floatFromInt(a)) / 255 else 1 };
                    ui.div(c).wFull().h(72).rounded(metrics.row_radius).bg(swatch).border(ui.Color.hex(0xffffff).alpha(0.15)).borderW(1).end();
                    const line = ui.div(c).row().gap(10).itemsCenter();
                    defer line.end();
                    ui.text(c, t, .{ .size = 13, .weight = .medium, .mono = true });
                    ui.text(c, clipboard.rgbDescription(c.arena.allocator(), rgba), .{ .size = 12, .mono = true, .color = th.muted });
                } else ui.text(c, t, .{ .size = 13, .weight = .medium, .mono = true });
            },
            .code => {
                if (clipboard.codeLanguage(std.mem.trim(u8, e.text, " \t\r\n"))) |lang| {
                    const tag = ui.div(c).px(6).py(2).roundedFull().bg(th.muted.alpha(0.12));
                    defer tag.end();
                    ui.text(c, lang, .{ .size = 10, .weight = .bold, .color = th.muted });
                }
                codeLines(c, e.text);
            },
            .plain, .path => ui.text(c, shownHead(e.text, max_plain_lines), .{ .size = 12.5, .wrap = true, .line_height = 12.5 * 1.2 + 3, .max_lines = max_plain_lines }),
        }
    }

    fn information(b: *Board, c: *ui.Context, p: *panel.Panel, e: Entry) void {
        const th = c.theme;
        const a = c.arena.allocator();
        const col = ui.div(c).column().wFull().gap(7);
        defer col.end();
        {
            const label = ui.div(c).pb(2);
            defer label.end();
            ui.text(c, "Information", .{ .size = 11.5, .weight = .semibold, .color = th.muted });
        }
        infoRow(c, "Source", e.source_name);
        if (e.kind == .image) {
            infoRow(c, "Type", "Image");
            infoRow(c, "Dimensions", c.print("{d} \u{00D7} {d}", .{ e.width, e.height }));
            infoRow(c, "Size", panel.formatSize(c, e.byte_count));
            infoRow(c, "Format", "PNG Image");
        } else if (e.filePath()) |path| {
            infoRow(c, "Type", clipboard.fileType(a, path, b.file_is_dir));
            if (b.file_size) |size| infoRow(c, "Size", panel.formatSize(c, size));
        } else {
            const content = e.content();
            infoRow(c, "Type", switch (content) {
                .link => "Link",
                .code => "Code",
                .color => "Color",
                .plain, .path => "Text",
            });
            if (content == .link) if (clipboard.domain(std.mem.trim(u8, e.text, " \t\r\n"))) |d| infoRow(c, "Domain", d);
            if (content == .color) if (clipboard.parseColor(std.mem.trim(u8, e.text, " \t\r\n"))) |rgba| infoRow(c, "RGB", clipboard.rgbDescription(a, rgba));
            const n = clipboard.counts(e.text);
            infoRow(c, "Characters", c.print("{d}", .{n.characters}));
            infoRow(c, "Words", c.print("{d}", .{n.words}));
            if (n.lines > 1) infoRow(c, "Lines", c.print("{d}", .{n.lines}));
        }
        const date = p.hooks.detailed_date;
        infoRow(c, "Copied", date(p.hooks.ctx, e.created_at, a));
        if (e.pinned_at) |at| infoRow(c, "Pinned", date(p.hooks.ctx, at, a));
        if (e.filePath()) |path| infoRow(c, "Path", path);
    }

    fn footer(b: *Board, c: *ui.Context) ?Action {
        const th = c.theme;
        const bar = ui.div(c).row().wFull().h(board_metrics.footer_height).px(14).gap(12).itemsCenter().bg(th.muted.alpha(0.04));
        defer bar.end();
        const n = b.visible.len;
        ui.text(c, c.print("{d} {s}", .{ n, if (n == 1) "entry" else "entries" }), .{ .size = 11, .weight = .medium, .color = th.muted.alpha(0.6) });
        ui.div(c).grow().end();
        const e = b.selection();
        var asked: ?Action = null;
        if (footerChip(c, b.pasteLabel(c), "↵", e != null)) asked = .{ .paste = e.? };
        const can_preview = if (e) |x| b.previewable(x) else false;
        if (footerChip(c, "Preview", "␣", can_preview)) asked = .{ .preview = e.? };
        if (footerChip(c, "Actions", "⌘K", e != null)) asked = .{ .actions = e.? };
        return asked;
    }
};

const blue: ui.Color = .hex(0x0a84ff);
const purple: ui.Color = .hex(0xbf5af2);
const cyan: ui.Color = .hex(0x32ade6);
const gray: ui.Color = .hex(0x8e8e93);

const text_preview_bytes = 16 * 1024;
const max_code_lines = 40;

const RowRange = struct { first: usize, end: usize };

fn rowsInView(offset: f32, len: usize) RowRange {
    const m = board_metrics;
    const margin_rows = 1 + @as(usize, @intFromFloat(@ceil(metrics.max_overscroll / metrics.row_height)));
    const top_row: usize = @intFromFloat(@max(0, @floor(offset / metrics.row_height)));
    const first = @min(len, top_row -| margin_rows);
    const in_view: usize = @intFromFloat(@ceil(m.list_height / metrics.row_height));
    return .{ .first = first, .end = @min(len, top_row + in_view + margin_rows) };
}

fn infoRow(c: *ui.Context, label: []const u8, value: []const u8) void {
    const row = ui.div(c).row().wFull().gap(12).itemsStart();
    defer row.end();
    {
        const l = ui.div(c).w(board_metrics.info_label_width).row().justifyEnd();
        defer l.end();
        ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    }
    const v = ui.div(c).grow();
    defer v.end();
    ui.text(c, value, .{ .size = 12, .wrap = true });
}

fn mediaBox(c: *ui.Context, key: []const u8, bytes: []const u8, width: f32) void {
    const box = ui.div(c).wFull().h(180).center().rounded(metrics.row_radius).bg(c.theme.muted.alpha(0.06)).clip();
    defer box.end();
    if (bytes.len == 0 or !ui.image(c, .{ .key = key, .bytes = bytes, .max_width = width, .max_height = 180, .radius = 0 }))
        ui.icon(c, "photo", .{ .size = 32, .color = c.theme.muted });
}

/// Numbered lines, as the Swift board's code block.
fn codeLines(c: *ui.Context, text: []const u8) void {
    const th = c.theme;
    const total = std.mem.count(u8, text, "\n") + 1;
    const shown = @min(total, max_code_lines);
    const gutter: f32 = if (shown >= 100) 26 else if (shown >= 10) 18 else 10;
    const box = ui.div(c).column().wFull().p(8).gap(3).rounded(6).bg(th.muted.alpha(0.08));
    defer box.end();
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == shown) break;
        ui.keyInt(c, i);
        const row = ui.div(c).row().gap(8).itemsStart();
        defer row.end();
        {
            const g = ui.div(c).w(gutter).row().justifyEnd();
            defer g.end();
            ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 10.5, .mono = true, .color = th.muted.alpha(0.6) });
        }
        ui.text(c, if (line.len == 0) " " else std.mem.trimEnd(u8, shownHead(line, 1), "\r"), .{ .size = 11.5, .mono = true, .truncate = .ellipsis });
    }
    if (total > shown) ui.text(c, "Preview truncated", .{ .size = 10.5, .weight = .medium, .color = th.muted.alpha(0.6) });
}

fn footerChip(c: *ui.Context, title: []const u8, key: []const u8, enabled: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    const chip = ui.div(c).row().gap(5).px(8).py(4).itemsCenter().roundedFull().bg(th.muted.alpha(0.12))
        .opacity(if (enabled) 1 else board_metrics.footer_chip_disabled_opacity).control();
    defer chip.end();
    ui.text(c, title, .{ .size = 11.5, .weight = .medium });
    {
        const k = ui.div(c).px(4).py(1).rounded(3).bg(th.muted.alpha(0.25));
        defer k.end();
        ui.text(c, key, .{ .size = 9, .weight = .semibold, .rounded = true });
    }
    return enabled and chip.clicked();
}

const Stat = struct { dir: bool, size: u64 };

fn stat(path: []const u8) ?Stat {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: std.c.Stat = undefined;
    if (std.c.stat(buf[0..path.len :0], &st) != 0) return null;
    return .{ .dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR, .size = @intCast(st.size) };
}

fn exists(path: []const u8) bool {
    return stat(path) != null;
}

fn readFile(a: std.mem.Allocator, path: []const u8, len: usize) ?[]const u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    const fd = std.c.open(z, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const buf = a.alloc(u8, len) catch return null;
    var got: usize = 0;
    while (got < len) {
        const n = std.c.read(fd, buf[got..].ptr, len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return buf[0..got];
}
