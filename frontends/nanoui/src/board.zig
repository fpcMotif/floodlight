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

/// The Swift shell's `FloodlightMetrics` clipboard values.
pub const board_metrics = struct {
    pub const list_width: f32 = 320;
    pub const width: f32 = metrics.width;
    pub const inspector_width: f32 = width - list_width - 1 - metrics.well_inset * 2;
    pub const height: f32 = metrics.expanded_height;
    pub const content_height: f32 = metrics.well_height - metrics.filter_bar_height;
    pub const list_height: f32 = metrics.list_height;
    pub const info_label_width: f32 = 84;
};

pub const summon_label = "⌥⇧ C";

/// ⌫ as a shortcut key; `ui.Shortcut` names no constant for it.
pub const backspace: u21 = 0x7f;
const held_key_gap_seconds = 0.15;
const detail_kept_bytes = 1 << 20;
/// The bytes `shownHead` allows each line.
pub const max_line_bytes = 200;
const max_plain_lines = 40;
const max_link_lines = 6;
const max_thumbnails = 256;

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
    open: []const u8,
    reveal: []const u8,
    preview: Entry,
    actions: Entry,

    pub fn hides(a: Action) bool {
        return switch (a) {
            .paste, .open, .reveal => true,
            .copy, .preview, .actions => false,
        };
    }
};

pub const Board = struct {
    store: ?*const clipboard.Store,
    list: History,
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
        var b: Board = .{ .store = store, .clock = clock, .list = .init(gpa), .detail_arena = .init(gpa), .thumb_arena = .init(gpa) };
        b.list.markStale();
        return b;
    }

    pub fn deinit(b: *Board) void {
        b.list.deinit();
        b.detail_arena.deinit();
        b.thumbnails.deinit(b.thumb_arena.child_allocator);
        b.thumb_arena.deinit();
    }

    pub fn forget(b: *Board) void {
        b.list.reset();
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
            const gpa = b.list.arena.child_allocator;
            var tmp: std.heap.ArenaAllocator = .init(gpa);
            defer tmp.deinit();
            const ta = tmp.allocator();
            var kept: std.ArrayList(Entry) = .empty;
            for (b.list.rows) |e| {
                if (e.matches(query)) try kept.append(ta, try e.dupe(ta));
            }
            const a = b.list.beginQuery(query);
            const rows = try a.alloc(Entry, kept.items.len);
            for (kept.items, 0..) |e, i| rows[i] = try e.dupe(a);
            try b.list.setRows(query, rows);
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
        const store = b.store orelse return;
        store.togglePin(e.id, b.clock.now()) catch return;
        b.list.markStale();
        b.refresh(b.list.answered());
    }

    pub fn delete(b: *Board) void {
        const e = b.list.selection() orelse return;
        const store = b.store orelse return;
        store.delete(e.id) catch return;
        _ = b.thumbnails.remove(e.id);
        const at = b.list.selected;
        const next = b.list.allocator().alloc(Entry, b.list.rows.len -| 1) catch {
            b.list.markStale();
            b.refresh(b.list.answered());
            b.list.clampSelection(at);
            return;
        };
        var n: usize = 0;
        for (b.list.rows) |r| if (r.id != e.id) {
            next[n] = r;
            n += 1;
        };
        b.list.replaceRows(next[0..n]);
        b.list.clampSelection(at);
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
        const th = c.theme;
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
            ui.div(c).w(1).hFull().bg(th.border.alpha(0.45)).end();
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
        for (Filter.options) |f| {
            if (chrome.filterChip(c, f.title(), f.symbol(), b.list.filter == f, .{ .count = b.list.count(f) })) b.list.selectFilter(f);
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
        spacer(c, "above", shown.first);
        var asked: ?Action = null;
        for (visible[shown.first..shown.end], shown.first..) |e, i| if (b.rowView(c, host, e, i)) |a| {
            asked = a;
        };
        spacer(c, "below", visible.len - shown.end);
        return asked;
    }

    fn spacer(c: *ui.Context, name: []const u8, rows: usize) void {
        if (rows == 0) return;
        ui.key(c, name);
        ui.div(c).wFull().h(@as(f32, @floatFromInt(rows)) * metrics.row_height).end();
    }

    fn rowView(b: *Board, c: *ui.Context, host: Context, e: Entry, i: usize) ?Action {
        const th = c.theme;
        ui.keyInt(c, @intCast(e.id));
        const selected = i == b.list.selected;
        const row_box = chrome.rowBox(c, selected, false);
        defer row_box.box.end();
        const it = row_box.it;
        if (it.clicked) b.list.selected = i;
        b.iconView(c, host, e);
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
        chrome.rowKey(c, if (selected) .enter else .none);
        return if (it.double_clicked) .{ .paste = e } else null;
    }

    fn iconView(b: *Board, c: *ui.Context, host: Context, e: Entry) void {
        const size = metrics.icon_size;
        if (e.kind == .image) {
            const thumb = b.thumbnailOf(e);
            if (thumb.len > 0 and ui.image(c, .{ .key = c.print("clip.{d}", .{e.id}), .bytes = thumb, .max_width = size, .max_height = size, .radius = 6 })) return;
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
            .text => switch (e.content) {
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
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.board_image_extensions)) return tile(c, "photo", cyan);
        if (e.kind == .text and clipboard.inSet(ext, &clipboard.video_extensions)) return tile(c, "video.fill", purple);
        if (host.app_icon(host.ctx, path)) |png| {
            _ = ui.image(c, .{ .key = path, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        }
        tile(c, "doc", gray);
    }

    fn inspector(b: *Board, c: *ui.Context, host: Context) void {
        const th = c.theme;
        const pane = ui.div(c).column().grow().hFull().bg(th.text.alpha(0.03)).scrollY().p(14).gap(14);
        defer pane.end();
        chrome.boundOverscroll(c, pane.id());
        const e = b.list.selection() orelse {
            ui.text(c, "Select an entry", .{ .size = 13.5, .weight = .medium, .color = th.muted.alpha(0.6) });
            return;
        };
        b.loadDetail(c, e);
        b.preview(c, e);
        ui.div(c).wFull().h(1).bg(th.border.alpha(0.4)).end();
        b.information(c, host, e);
    }

    fn preview(b: *Board, c: *ui.Context, e: Entry) void {
        const th = c.theme;
        const width = board_metrics.inspector_width - 28;
        const col = ui.div(c).column().wFull().gap(8);
        defer col.end();
        if (e.kind == .image) {
            switch (b.payload) {
                .picture => |full| mediaBox(c, c.print("clip.full.{d}", .{e.id}), full, width),
                else => mediaBox(c, c.print("clip.{d}", .{e.id}), b.thumbnailOf(e), width),
            }
            return ui.text(c, e.title(c.arena.allocator()), .{ .size = 15, .weight = .semibold, .wrap = true, .max_lines = 2 });
        }
        if (e.filePath()) |path| {
            switch (b.payload) {
                .picture => |bytes| mediaBox(c, path, bytes, width),
                .text => |bytes| codeLines(c, bytes),
                .none => {},
            }
            return ui.text(c, e.title(c.arena.allocator()), .{ .size = 15, .weight = .semibold, .wrap = true, .max_lines = 2 });
        }
        switch (e.content) {
            .link => |domain| {
                {
                    const head = ui.div(c).row().gap(6).itemsCenter();
                    defer head.end();
                    ui.icon(c, "link", .{ .size = 12, .weight = .semibold, .color = blue });
                    ui.text(c, domain, .{ .size = 12, .weight = .semibold });
                }
                const box = ui.div(c).wFull().p(8).rounded(6).bg(th.muted.alpha(0.08));
                defer box.end();
                ui.text(c, shownHead(e.text, max_link_lines), .{ .size = 12, .mono = true, .color = th.muted, .wrap = true, .max_lines = max_link_lines });
            },
            .color => |rgba| {
                const swatch: ui.Color = .{ .r = @as(f32, @floatFromInt(rgba.r)) / 255, .g = @as(f32, @floatFromInt(rgba.g)) / 255, .b = @as(f32, @floatFromInt(rgba.b)) / 255, .a = if (rgba.a) |a| @as(f32, @floatFromInt(a)) / 255 else 1 };
                ui.div(c).wFull().h(72).rounded(metrics.row_radius).bg(swatch).border(ui.Color.hex(0xffffff).alpha(0.15)).borderW(1).end();
                const line = ui.div(c).row().gap(10).itemsCenter();
                defer line.end();
                ui.text(c, std.mem.trim(u8, e.text, " \t\r\n"), .{ .size = 13, .weight = .medium, .mono = true });
                ui.text(c, clipboard.rgbDescription(c.arena.allocator(), rgba), .{ .size = 12, .mono = true, .color = th.muted });
            },
            .code => |lang| {
                {
                    const tag = ui.div(c).px(6).py(2).roundedFull().bg(th.muted.alpha(0.12));
                    defer tag.end();
                    ui.text(c, lang, .{ .size = 10, .weight = .bold, .color = th.muted });
                }
                codeLines(c, e.text);
            },
            .plain => ui.text(c, shownHead(e.text, max_plain_lines), .{ .size = 12.5, .wrap = true, .line_height = 12.5 * 1.2 + 3, .max_lines = max_plain_lines }),
            .path => unreachable,
        }
    }

    fn information(b: *Board, c: *ui.Context, host: Context, e: Entry) void {
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
        if (chrome.footerChip(c, "Preview", "␣", can_preview)) asked = .{ .preview = e.? };
        if (chrome.footerChip(c, "Actions", "⌘K", e != null)) asked = .{ .actions = e.? };
        return asked;
    }
};

const blue: ui.Color = .hex(0x0a84ff);
const purple: ui.Color = .hex(0xbf5af2);
const cyan: ui.Color = .hex(0x32ade6);
const gray: ui.Color = .hex(0x8e8e93);

const max_code_lines = 40;

const margin_rows = 1 + @as(usize, @intFromFloat(@ceil(metrics.max_overscroll / metrics.row_height)));

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
