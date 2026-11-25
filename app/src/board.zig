//! The clipboard board: history on the left, the selected entry's preview
//! and information on the right, the paste, preview and actions chips
//! below, all on one solid well under the glass search row.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const clipboard = @import("clipboard.zig");
const chrome = @import("chrome.zig");
const list = @import("list.zig");

const Entry = clipboard.Entry;
const Filter = clipboard.Filter;
const metrics = chrome.metrics;
const space = chrome.space;
const type_size = chrome.type_size;
const fill = chrome.fill;

fn entryKey(e: Entry) i64 {
    return e.id;
}

pub const History = list.List(Entry, Filter, i64, entryKey);

/// What the board needs from the panel around it.
pub const Context = struct {
    ctx: ?*anyopaque,
    /// An app's icon as PNG; null draws a symbol.
    app_icon: *const fn (?*anyopaque, []const u8) ?[]const u8,
    /// "Today at 3:03 PM": the inspector's Copied and Pinned.
    detailed_date: *const fn (?*anyopaque, f64, std.mem.Allocator) []const u8,
    /// The text in the search field, filtering history.
    query: []const u8,
};

/// Clipboard board layout and inspector metrics.
pub const board_metrics = struct {
    pub const list_width: f32 = 320;
    pub const width: f32 = metrics.width;
    pub const inspector_width: f32 = width - list_width - 1 - metrics.well_inset * 2;
    pub const height: f32 = metrics.expanded_height;
    pub const content_height: f32 = metrics.well_height - metrics.filter_bar_height;
    pub const list_height: f32 = metrics.list_height;
    pub const info_label_width: f32 = 84;
    pub const media_height: f32 = 180;
    pub const swatch_height: f32 = 72;
    pub const media_placeholder_size: f32 = 32;
    pub const pin_size: f32 = 9;
    /// A tile's symbol, as a share of the tile.
    pub const tile_symbol_scale: f32 = 0.5;
    /// The line number column, by how many digits the last number has.
    pub const gutter_widths = [_]f32{ 10, 18, 26 };
    /// The plain text preview's line, as a multiple of its size plus leading.
    pub const body_line_height: f32 = type_size.body * 1.2 + space.text;
};

pub const summon_label = "⌥⇧ C";

const held_key_gap_seconds = 0.15;
const detail_kept_bytes = 1 << 20;
/// The bytes `shownHead` allows each line.
pub const max_line_bytes = 200;
const max_plain_lines = 40;
const max_link_lines = 6;
const max_thumbnails = 256;

pub fn shownHead(text: []const u8, lines: usize) []const u8 {
    var end = lines *| max_line_bytes;
    if (text.len <= end) return text;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// What the board asks of the shell. Pin and delete it does itself.
pub const Action = union(enum) {
    paste: Entry,
    copy: Entry,
    open: []const u8,
    reveal: []const u8,
    preview: Entry,
    actions: Entry,
};

pub const Board = struct {
    store: ?*const clipboard.Store,
    list: History,
    scratch_arena: std.heap.ArenaAllocator,
    /// The selection's payload: a full image, a file's head.
    detail_arena: std.heap.ArenaAllocator,
    clock: clipboard.Clock = .wall_clock,
    /// The app Return pastes into; empty when Return only copies.
    paste_target: []const u8 = "",
    detail_id: ?i64 = null,
    detail_at: f64 = 0,
    detail_passing: bool = false,
    detail_loaded: bool = false,
    payload: clipboard.Payload = .none,
    /// What the inspector found for the entry `facts_id` names.
    facts: clipboard.Facts = .{},
    facts_id: ?i64 = null,
    thumbnails: std.AutoHashMapUnmanaged(i64, []const u8) = .empty,
    thumb_arena: std.heap.ArenaAllocator,
    truncated: bool = false,

    pub fn init(gpa: std.mem.Allocator, store: ?*const clipboard.Store, clock: clipboard.Clock) Board {
        var b: Board = .{ .store = store, .clock = clock, .list = .init(gpa), .scratch_arena = .init(gpa), .detail_arena = .init(gpa), .thumb_arena = .init(gpa) };
        b.list.markStale();
        return b;
    }

    pub fn deinit(b: *Board) void {
        b.list.deinit();
        b.scratch_arena.deinit();
        b.detail_arena.deinit();
        b.thumbnails.deinit(b.thumb_arena.child_allocator);
        b.thumb_arena.deinit();
    }

    pub fn forget(b: *Board) void {
        b.list.reset();
        _ = b.scratch_arena.reset(.free_all);
        b.list.markStale();
        b.truncated = false;
        b.releaseDetail();
        b.thumbnails.clearAndFree(b.thumb_arena.child_allocator);
        _ = b.thumb_arena.reset(.free_all);
    }

    pub fn releaseDetail(b: *Board) void {
        b.detail_id = null;
        b.facts_id = null;
        _ = b.detail_arena.reset(.free_all);
    }

    /// Asks the store again when the query changed or history did.
    pub fn refresh(b: *Board, query: []const u8) void {
        if (!b.list.needsQuery(query)) return;
        b.answer(query) catch |err| {
            std.log.err("clipboard history: {s}", .{@errorName(err)});
            b.list.fail();
        };
    }

    fn canNarrow(b: *const Board, query: []const u8) bool {
        if (b.list.stale or b.list.failed or b.truncated or b.list.rows.len >= clipboard.search_limit) return false;
        const prev = std.mem.trim(u8, b.list.answered(), " ");
        const next = std.mem.trim(u8, query, " ");
        return prev.len > 0 and std.mem.startsWith(u8, next, prev);
    }

    fn answer(b: *Board, query: []const u8) !void {
        if (b.canNarrow(query)) {
            _ = b.scratch_arena.reset(.retain_capacity);
            const ta = b.scratch_arena.allocator();
            const kept = try ta.alloc(Entry, b.list.rows.len);
            var n: usize = 0;
            for (b.list.rows) |e| {
                if (e.matches(query)) {
                    kept[n] = try e.dupe(ta);
                    n += 1;
                }
            }
            _ = b.list.beginQuery(query);
            std.mem.swap(std.heap.ArenaAllocator, &b.list.arena, &b.scratch_arena);
            try b.list.setRows(query, kept[0..n]);
            return;
        }
        const a = b.list.beginQuery(query);
        const rows = if (b.store) |s| try s.list(a, query) else &.{};
        b.truncated = rows.len >= clipboard.search_limit;
        try b.list.setRows(query, rows);
    }

    /// What Return does, for the footer chip and the actions menu.
    pub fn pasteLabel(b: *const Board, arena: std.mem.Allocator) []const u8 {
        if (b.paste_target.len == 0) return "Copy";
        return std.fmt.allocPrint(arena, "Paste to {s}", .{b.paste_target}) catch "Paste";
    }

    pub fn previewable(b: *Board, e: Entry) bool {
        return b.factsOf(e).previewable;
    }

    pub fn togglePin(b: *Board) void {
        const e = b.list.selection() orelse return;
        b.togglePinId(e.id);
    }

    pub fn togglePinId(b: *Board, id: i64) void {
        const store = b.store orelse return;
        store.togglePin(id, b.clock.now()) catch return;
        b.list.markStale();
        b.refresh(b.list.answered());
    }

    pub fn delete(b: *Board) void {
        const e = b.list.selection() orelse return;
        b.deleteId(e.id);
    }

    pub fn deleteId(b: *Board, id: i64) void {
        const store = b.store orelse return;
        store.delete(id) catch return;
        _ = b.thumbnails.remove(id);
        if (b.detail_id == id) b.releaseDetail();
        if (b.facts_id == id) b.facts_id = null;
        const selected_id: ?i64 = if (b.list.selection()) |sel| sel.id else null;
        const at = b.list.selected;
        const next = b.list.allocator().alloc(Entry, b.list.rows.len -| 1) catch {
            b.list.markStale();
            b.refresh(b.list.answered());
            b.list.clampSelection(at);
            return;
        };
        var n: usize = 0;
        for (b.list.rows) |r| if (r.id != id) {
            next[n] = r;
            n += 1;
        };
        b.list.replaceRows(next[0..n]);
        if (selected_id == null or selected_id == id) {
            b.list.clampSelection(at);
        }
    }

    fn thumbnailOf(b: *Board, e: Entry) []const u8 {
        if (b.thumbnails.get(e.id)) |bytes| return bytes;
        const gpa = b.thumb_arena.child_allocator;
        if (b.thumbnails.count() >= max_thumbnails) {
            b.thumbnails.clearRetainingCapacity();
            _ = b.thumb_arena.reset(.free_all);
        }
        const bytes = if (b.store) |s| s.thumbnail(b.thumb_arena.allocator(), e.id) else "";
        b.thumbnails.put(gpa, e.id, bytes) catch {};
        return bytes;
    }

    /// Loads what the inspector shows for the selection, once per entry.
    fn loadDetail(b: *Board, c: *ui.Context, e: Entry) void {
        if (b.detail_id != e.id) {
            b.detail_passing = b.detail_id != null and c.time - b.detail_at < held_key_gap_seconds;
            b.detail_id = e.id;
            b.detail_at = c.time;
            b.detail_loaded = false;
            _ = b.detail_arena.reset(.{ .retain_with_limit = detail_kept_bytes });
            b.payload = .none;
        }
        if (b.detail_loaded) return;
        const wait = held_key_gap_seconds - (c.time - b.detail_at);
        if (b.detail_passing and wait > 0) return c.frameIn(@floatCast(wait));
        b.detail_loaded = true;
        if (b.store) |s| b.payload = s.load(b.detail_arena.allocator(), e, b.factsOf(e));
    }

    /// One `stat` per entry the selection lands on, never one per frame.
    fn factsOf(b: *Board, e: Entry) clipboard.Facts {
        if (b.facts_id != e.id) {
            b.facts = clipboard.facts(e);
            b.facts_id = e.id;
        }
        return b.facts;
    }

    pub fn keys(b: *Board, c: *ui.Context, field_empty: bool) ?Action {
        const S = ui.Shortcut;
        _ = chrome.listKeys(c, &b.list, &Filter.options);
        const e = b.list.selection() orelse return null;
        if (c.shortcut(.{ .key = 'o', .cmd = true })) {
            if (e.linkUrl()) |u| return .{ .open = u };
        }
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
    pub fn view(b: *Board, c: *ui.Context, host: Context) ?Action {
        const m = board_metrics;
        const well = chrome.well(c);
        defer well.end();
        b.filterBar(c);
        if (b.list.visible.len == 0) {
            chrome.emptyState(c, m.content_height, b.emptyMessage(c, host.query));
            return null;
        }
        var asked: ?Action = null;
        {
            const columns = ui.div(c).row().wFull().h(m.list_height);
            defer columns.end();
            if (b.historyList(c, host)) |a| asked = a;
            chrome.divider(c, .down);
            b.inspector(c, host);
        }
        if (b.footer(c)) |a| asked = a;
        return asked;
    }

    fn emptyMessage(b: *const Board, c: *ui.Context, query: []const u8) chrome.Empty {
        if (b.list.failed) return .{ .symbol = "exclamationmark.triangle", .title = "Clipboard history could not be read" };
        const f = b.list.filter;
        const name = if (f == .all) "entries" else chrome.sentenceNoun(c, f);
        if (query.len > 0) return .{ .symbol = f.symbol(), .title = c.print("No {s} match \u{201C}{s}\u{201D}", .{ name, query }) };
        if (f != .all) return .{ .symbol = f.symbol(), .title = c.print("No {s} copied yet", .{name}) };
        return .{ .symbol = "clipboard", .title = "Nothing copied yet", .hint = "Text, files and images you copy appear here." };
    }

    fn filterBar(b: *Board, c: *ui.Context) void {
        const bar = chrome.filterBar(c);
        defer bar.end();
        var counts: [Filter.options.len]usize = @splat(0);
        counts[0] = b.list.rows.len;
        for (b.list.rows) |e| {
            switch (e.kind) {
                .text => counts[1] += 1,
                .file => counts[2] += 1,
                .image => counts[3] += 1,
            }
        }
        for (Filter.options, 0..) |f, i| {
            if (chrome.filterChip(c, bar, f.title(), b.list.filter == f, .{ .count = counts[i] })) b.list.selectFilter(f);
        }
    }

    fn historyList(b: *Board, c: *ui.Context, host: Context) ?Action {
        const m = board_metrics;
        const col = ui.div(c).column().w(m.list_width).h(m.list_height).scrollY().p(metrics.row_padding);
        defer col.end();
        chrome.boundOverscroll(c, col.id());
        chrome.revealSelection(c, &b.list, col.id(), m.list_height - 2 * metrics.row_padding);
        const visible = b.list.visible;
        const shown = list.rowsInView(c.scroll.get(col.id()) orelse 0, visible.len, metrics.row_height, m.list_height, margin_rows);
        chrome.rowSpacer(c, "above", shown.first);
        var asked: ?Action = null;
        for (visible[shown.first..shown.end], shown.first..) |e, i| if (b.rowView(c, host, e, i)) |a| {
            asked = a;
        };
        chrome.rowSpacer(c, "below", visible.len - shown.end);
        return asked;
    }

    fn rowView(b: *Board, c: *ui.Context, host: Context, e: Entry, i: usize) ?Action {
        const quiet = chrome.tone(c.theme).secondary;
        ui.keyInt(c, @intCast(e.id));
        const selected = i == b.list.selected;
        const row_box = chrome.rowBox(c, selected, false);
        defer row_box.box.end();
        const it = row_box.it;
        if (it.clicked) b.list.selected = i;
        b.iconView(c, host, e);
        {
            const text = ui.div(c).column().grow().gap(space.text);
            defer text.end();
            ui.text(c, e.title(c.arena.allocator()), .{ .size = type_size.row_title, .weight = .medium, .truncate = .ellipsis });
            {
                const line = ui.div(c).row().gap(space.snug).itemsCenter();
                defer line.end();
                if (e.pinned_at != null) ui.icon(c, "pin.fill", .{ .size = board_metrics.pin_size, .weight = .semibold, .color = quiet });
                ui.text(c, e.subtitle(c.arena.allocator(), b.clock.now()), .{ .size = type_size.chip, .weight = .medium, .color = quiet, .truncate = .middle });
            }
        }
        chrome.rowKey(c, if (selected) .enter else .none);
        return if (it.double_clicked) .{ .paste = e } else null;
    }

    fn iconView(b: *Board, c: *ui.Context, host: Context, e: Entry) void {
        const size = metrics.icon_size;
        const th = c.theme;
        const blue = chrome.hue(th, .blue);
        const amber = chrome.hue(th, .amber);
        const cyan = chrome.hue(th, .cyan);
        const gray = chrome.tone(th).secondary;
        if (e.kind == .image) {
            const thumb = b.thumbnailOf(e);
            if (thumb.len > 0 and ui.image(c, .{ .key = c.print("clip.{d}", .{e.id}), .bytes = thumb, .max_width = size, .max_height = size, .radius = metrics.media_radius })) return;
        }
        const tile = struct {
            fn draw(cx: *ui.Context, symbol: []const u8, color: ui.Color) void {
                const t = ui.div(cx).w(size).h(size).center().rounded(metrics.icon_tile_radius).bg(color.alpha(fill.tile));
                defer t.end();
                ui.icon(cx, symbol, .{ .size = size * board_metrics.tile_symbol_scale, .color = color });
            }
        }.draw;
        switch (e.kind) {
            .image => return tile(c, "photo", gray),
            .text => switch (e.content) {
                .link => return tile(c, "link", blue),
                .color => |rgba| {
                    ui.div(c).w(size).h(size).rounded(metrics.icon_tile_radius).bg(swatchColor(rgba)).border(chrome.outline(th)).borderW(metrics.hairline).end();
                    return;
                },
                .code => return tile(c, "curlybraces", cyan),
                .plain => return tile(c, "doc.text", gray),
                .path => {},
            },
            .file => {},
        }
        const path = e.filePath().?;
        const ext = clipboard.extension(path);
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.board_image_extensions)) return tile(c, "photo", cyan);
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.video_extensions)) return tile(c, "video.fill", amber);
        if (host.app_icon(host.ctx, path)) |png| {
            _ = ui.image(c, .{ .key = path, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        }
        tile(c, "doc", gray);
    }

    fn inspector(b: *Board, c: *ui.Context, host: Context) void {
        const th = c.theme;
        const pane = ui.div(c).column().grow().hFull().bg(th.text.alpha(fill.inspector)).scrollY().p(space.edge).gap(space.edge);
        defer pane.end();
        chrome.boundOverscroll(c, pane.id());
        const e = b.list.selection() orelse {
            ui.text(c, "Select an entry", .{ .size = type_size.empty_state, .weight = .medium, .color = chrome.tone(th).tertiary });
            return;
        };
        b.loadDetail(c, e);
        b.preview(c, e);
        chrome.divider(c, .across);
        b.information(c, host, e);
    }

    fn preview(b: *Board, c: *ui.Context, e: Entry) void {
        const th = c.theme;
        const quiet = chrome.tone(th).secondary;
        const title_style: ui.TextStyle = .{ .size = type_size.row_title, .weight = .semibold, .wrap = true, .max_lines = 2 };
        const width = board_metrics.inspector_width - 2 * space.edge;
        const col = ui.div(c).column().wFull().gap(space.pad);
        defer col.end();
        if (e.kind == .image) {
            switch (b.payload) {
                .picture => |full| mediaBox(c, c.print("clip.full.{d}", .{e.id}), full, width),
                else => mediaBox(c, c.print("clip.{d}", .{e.id}), b.thumbnailOf(e), width),
            }
            return ui.text(c, e.title(c.arena.allocator()), title_style);
        }
        if (e.filePath()) |path| {
            switch (b.payload) {
                .picture => |bytes| mediaBox(c, path, bytes, width),
                .text => |bytes| codeLines(c, bytes),
                .none => {},
            }
            return ui.text(c, e.title(c.arena.allocator()), title_style);
        }
        switch (e.content) {
            .link => |domain| {
                {
                    const head = ui.div(c).row().gap(space.snug).itemsCenter();
                    defer head.end();
                    ui.icon(c, "link", .{ .size = type_size.inspector_row, .weight = .semibold, .color = chrome.hue(th, .blue) });
                    ui.text(c, domain, .{ .size = type_size.inspector_row, .weight = .semibold });
                }
                const box = ui.div(c).wFull().p(space.pad).rounded(metrics.media_radius).bg(th.muted.alpha(fill.code));
                defer box.end();
                ui.text(c, shownHead(e.text, max_link_lines), .{ .size = type_size.inspector_row, .mono = true, .color = quiet, .wrap = true, .max_lines = max_link_lines });
            },
            .color => |rgba| {
                ui.div(c).wFull().h(board_metrics.swatch_height).rounded(metrics.row_radius).bg(swatchColor(rgba)).border(chrome.outline(th)).borderW(metrics.hairline).end();
                const line = ui.div(c).row().gap(space.gap).itemsCenter();
                defer line.end();
                ui.text(c, std.mem.trim(u8, e.text, " \t\r\n"), .{ .size = type_size.value, .weight = .medium, .mono = true });
                ui.text(c, clipboard.rgbDescription(c.arena.allocator(), rgba), .{ .size = type_size.inspector_row, .mono = true, .color = quiet });
            },
            .code => |lang| {
                {
                    const tag = ui.div(c).px(space.snug).py(space.tight).roundedFull().bg(th.muted.alpha(fill.card));
                    defer tag.end();
                    ui.text(c, lang, .{ .size = type_size.micro, .weight = .bold, .color = quiet });
                }
                codeLines(c, e.text);
            },
            .plain => ui.text(c, shownHead(e.text, max_plain_lines), .{ .size = type_size.body, .wrap = true, .line_height = board_metrics.body_line_height, .max_lines = max_plain_lines }),
            .path => unreachable,
        }
    }

    fn information(b: *Board, c: *ui.Context, host: Context, e: Entry) void {
        const a = c.arena.allocator();
        const col = ui.div(c).column().wFull().gap(space.pad);
        defer col.end();
        {
            const label = ui.div(c).pb(space.tight);
            defer label.end();
            ui.text(c, "Information", .{ .size = type_size.chip, .weight = .semibold, .color = chrome.tone(c.theme).secondary });
        }
        infoRow(c, "Source", e.source_name);
        if (e.kind == .image) {
            infoRow(c, "Type", "Image");
            infoRow(c, "Dimensions", c.print("{d} \u{00D7} {d}", .{ e.width, e.height }));
            infoRow(c, "Size", chrome.formatSize(c, e.byte_count));
            infoRow(c, "Format", "PNG Image");
        } else if (e.filePath()) |path| {
            const f = b.factsOf(e);
            infoRow(c, "Type", clipboard.fileType(a, path, f.is_dir));
            if (f.size) |size| infoRow(c, "Size", chrome.formatSize(c, size));
        } else {
            infoRow(c, "Type", switch (e.content) {
                .link => "Link",
                .code => "Code",
                .color => "Color",
                .plain => "Text",
                .path => unreachable,
            });
            switch (e.content) {
                .link => |d| infoRow(c, "Domain", d),
                .color => |rgba| infoRow(c, "RGB", clipboard.rgbDescription(a, rgba)),
                else => {},
            }
            const n = clipboard.counts(e.text);
            infoRow(c, "Characters", c.print("{d}", .{n.characters}));
            infoRow(c, "Words", c.print("{d}", .{n.words}));
            if (n.lines > 1) infoRow(c, "Lines", c.print("{d}", .{n.lines}));
        }
        infoRow(c, "Copied", host.detailed_date(host.ctx, e.created_at, a));
        if (e.pinned_at) |at| infoRow(c, "Pinned", host.detailed_date(host.ctx, at, a));
        if (e.filePath()) |path| infoRow(c, "Path", path);
    }

    fn footer(b: *Board, c: *ui.Context) ?Action {
        const n = b.list.visible.len;
        const bar = chrome.footerBar(c, c.print("{d} {s}", .{ n, if (n == 1) "entry" else "entries" }));
        defer bar.end();
        const e = b.list.selection();
        var asked: ?Action = null;
        if (chrome.footerChip(c, b.pasteLabel(c.arena.allocator()), "↵", e != null)) asked = .{ .paste = e.? };
        const can_preview = if (e) |x| b.previewable(x) else false;
        if (chrome.footerChip(c, "Preview", "Space", can_preview)) asked = .{ .preview = e.? };
        if (chrome.footerChip(c, "Actions", "⌘K", e != null)) asked = .{ .actions = e.? };
        return asked;
    }
};

const max_code_lines = 40;

fn swatchColor(rgba: anytype) ui.Color {
    return .{
        .r = @as(f32, @floatFromInt(rgba.r)) / 255,
        .g = @as(f32, @floatFromInt(rgba.g)) / 255,
        .b = @as(f32, @floatFromInt(rgba.b)) / 255,
        .a = if (rgba.a) |a| @as(f32, @floatFromInt(a)) / 255 else 1,
    };
}

const margin_rows = 1 + @as(usize, @intFromFloat(@ceil(metrics.max_overscroll / metrics.row_height)));

fn infoRow(c: *ui.Context, label: []const u8, value: []const u8) void {
    const row = ui.div(c).row().wFull().gap(space.gap).itemsStart();
    defer row.end();
    {
        const l = ui.div(c).w(board_metrics.info_label_width).row().justifyEnd();
        defer l.end();
        ui.text(c, label, .{ .size = type_size.inspector_row, .color = chrome.tone(c.theme).secondary });
    }
    const v = ui.div(c).grow();
    defer v.end();
    ui.text(c, value, .{ .size = type_size.inspector_row, .wrap = true });
}

fn mediaBox(c: *ui.Context, key: []const u8, bytes: []const u8, width: f32) void {
    const th = c.theme;
    const h = board_metrics.media_height;
    const box = ui.div(c).wFull().h(h).center().rounded(metrics.row_radius).bg(th.muted.alpha(fill.badge)).border(chrome.outline(th)).borderW(metrics.hairline).clip();
    defer box.end();
    if (bytes.len == 0 or !ui.image(c, .{ .key = key, .bytes = bytes, .max_width = width, .max_height = h, .radius = 0 }))
        ui.icon(c, "photo", .{ .size = board_metrics.media_placeholder_size, .color = chrome.tone(th).tertiary });
}

fn codeLines(c: *ui.Context, text: []const u8) void {
    const th = c.theme;
    const quiet = chrome.tone(th).secondary;
    const total = std.mem.count(u8, text, "\n") + 1;
    const shown = @min(total, max_code_lines);
    const gutter = board_metrics.gutter_widths[@min(board_metrics.gutter_widths.len - 1, std.math.log10_int(@max(1, shown)))];
    const box = ui.div(c).column().wFull().p(space.pad).gap(space.text).rounded(metrics.media_radius).bg(th.muted.alpha(fill.code));
    defer box.end();
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == shown) break;
        ui.keyInt(c, i);
        const row = ui.div(c).row().gap(space.pad).itemsStart();
        defer row.end();
        {
            const g = ui.div(c).w(gutter).row().justifyEnd();
            defer g.end();
            ui.text(c, c.print("{d}", .{i + 1}), .{ .size = type_size.caption, .mono = true, .color = quiet });
        }
        ui.text(c, if (line.len == 0) " " else std.mem.trimEnd(u8, shownHead(line, 1), "\r"), .{ .size = type_size.chip, .mono = true, .truncate = .ellipsis });
    }
    if (total > shown) ui.text(c, "Preview truncated", .{ .size = type_size.caption, .weight = .medium, .color = quiet });
}
