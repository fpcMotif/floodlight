//! The search panel: a field over ranked rows of apps and files. It draws
//! no background of its own; the window's glass slab is behind it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const board_mod = @import("board.zig");
const mac = @import("mac.zig");

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

pub const Clock = clipboard.Clock;

pub const CompletionSource = enum { history, top_hit, web_suggestion };

pub const Completion = struct {
    suffix: []const u8,
    source: CompletionSource,
};

/// What the panel asks of the window, handled after the frame.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    clock: Clock = .wall_clock,
    /// An action, or a new height to fit the rows.
    request: *const fn (?*anyopaque) void,
    /// An app's icon as PNG, cached by the shell; null draws a symbol.
    app_icon: *const fn (?*anyopaque, []const u8) ?[]const u8,
    describe_date: *const fn (?*anyopaque, i64, std.mem.Allocator) []const u8,
    /// "Today at 3:03 PM": the board inspector's Copied and Pinned.
    detailed_date: *const fn (?*anyopaque, f64, std.mem.Allocator) []const u8,
};

pub const default_retention_seconds: f64 = 5 * 60;

const RetainedSearch = struct {
    query: std.ArrayList(u8) = .empty,
    path: std.ArrayList(u8) = .empty,
    filter: Filter = .all,
    hidden_at: ?f64 = null,

    fn deinit(r: *RetainedSearch, gpa: std.mem.Allocator) void {
        r.query.deinit(gpa);
        r.path.deinit(gpa);
        r.* = .{};
    }

    fn clear(r: *RetainedSearch) void {
        r.query.clearRetainingCapacity();
        r.path.clearRetainingCapacity();
        r.filter = .all;
        r.hidden_at = null;
    }
};

const RetainedBoard = struct {
    query: std.ArrayList(u8) = .empty,
    filter: clipboard.Filter = .all,
    selected_id: ?i64 = null,
    hidden_at: ?f64 = null,

    fn deinit(r: *RetainedBoard, gpa: std.mem.Allocator) void {
        r.query.deinit(gpa);
        r.* = .{};
    }

    fn clear(r: *RetainedBoard) void {
        r.query.clearRetainingCapacity();
        r.filter = .all;
        r.selected_id = null;
        r.hidden_at = null;
    }
};

pub const Panel = struct {
    catalog: *search.Catalog,
    hooks: Hooks,
    clock: Clock = .wall_clock,
    retention_seconds: f64 = default_retention_seconds,
    mode: Mode = .search,
    hidden: bool = false,
    retained_search: RetainedSearch = .{},
    retained_board: RetainedBoard = .{},
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
    suppressed_by_backspace: bool = false,
    caret_at_end: bool = true,
    composing: bool = false,
    completion: ?Completion = null,
    pending: ?Action = null,
    height: f32 = metrics.search_height,
    width: f32 = metrics.width,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, store: ?*const clipboard.Store, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .hooks = hooks, .clock = hooks.clock, .arena = .init(gpa), .board = .init(gpa, store, hooks.clock) };
    }

    pub fn deinit(p: *Panel) void {
        const gpa = p.arena.child_allocator;
        p.retained_search.deinit(gpa);
        p.retained_board.deinit(gpa);
        p.board.deinit();
        p.field.deinit();
        p.answered.deinit(gpa);
        p.arena.deinit();
    }

    fn forgetSearch(p: *Panel) void {
        p.retained_search.clear();
        p.rows = &.{};
        p.visible = &.{};
        p.answered.clearRetainingCapacity();
        p.filter = .all;
        p.selected = 0;
        p.resetCompletion();
        _ = p.arena.reset(.free_all);
        if (p.mode == .search) {
            p.field.clear();
            p.height = p.panelHeight();
            p.width = p.panelWidth();
        }
    }

    fn forgetBoard(p: *Panel) void {
        p.retained_board.clear();
        p.board.forget();
        if (p.mode == .clipboard) {
            p.field.clear();
            p.height = p.panelHeight();
            p.width = p.panelWidth();
        }
    }

    /// Drops retained search and clipboard state, queries, rows, and arenas.
    pub fn forget(p: *Panel) void {
        p.forgetSearch();
        p.forgetBoard();
        p.field.clear();
        p.pending = null;
        p.hidden = false;
        p.mode = .search;
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    pub fn reset(p: *Panel) void {
        p.forget();
    }

    /// Clears the field and forgets the active surface's retained session.
    pub fn clearField(p: *Panel) void {
        p.field.clear();
        if (p.mode == .clipboard) {
            p.retained_board.clear();
            p.board.filter = .all;
            p.board.answered.clearRetainingCapacity();
            p.board.selected = 0;
            p.board.stale = true;
            p.board.refresh("");
            return;
        }
        p.forgetSearch();
    }

    fn saveSearch(p: *Panel, now: f64) void {
        if (p.retention_seconds <= 0 or p.field.text().len == 0) {
            p.forgetSearch();
            return;
        }
        const gpa = p.arena.child_allocator;
        p.retained_search.query.clearRetainingCapacity();
        p.retained_search.query.appendSlice(gpa, p.field.text()) catch {};
        p.retained_search.path.clearRetainingCapacity();
        if (p.selected < p.visible.len) {
            p.retained_search.path.appendSlice(gpa, p.visible[p.selected].path) catch {};
        }
        p.retained_search.filter = p.filter;
        p.retained_search.hidden_at = now;
    }

    fn saveBoard(p: *Panel, now: f64) void {
        if (p.retention_seconds <= 0 or (p.field.text().len == 0 and p.board.filter == .all and p.board.selected == 0)) {
            p.forgetBoard();
            return;
        }
        const gpa = p.arena.child_allocator;
        p.retained_board.query.clearRetainingCapacity();
        p.retained_board.query.appendSlice(gpa, p.field.text()) catch {};
        p.retained_board.filter = p.board.filter;
        p.retained_board.selected_id = if (p.board.selection()) |e| e.id else null;
        p.retained_board.hidden_at = now;
        p.board.releaseDetail();
    }

    fn expireAt(p: *Panel, now: f64) void {
        if (p.retained_search.hidden_at) |t| {
            if (p.retention_seconds <= 0 or now - t >= p.retention_seconds) p.forgetSearch();
        }
        if (p.retained_board.hidden_at) |t| {
            if (p.retention_seconds <= 0 or now - t >= p.retention_seconds) p.forgetBoard();
        }
    }

    /// Drops any surface whose retention window has elapsed; true when
    /// neither surface remains retained.
    pub fn expire(p: *Panel) bool {
        p.expireAt(p.clock.now());
        return p.retained_search.hidden_at == null and p.retained_board.hidden_at == null;
    }

    /// Milliseconds until the earliest retained surface expires; null when
    /// nothing is retained.
    pub fn nextExpiryMs(p: *const Panel) ?u32 {
        if (p.retention_seconds <= 0) return null;
        const now = p.clock.now();
        var earliest: ?f64 = null;
        if (p.retained_search.hidden_at) |t| earliest = t + p.retention_seconds;
        if (p.retained_board.hidden_at) |t| {
            const due = t + p.retention_seconds;
            earliest = if (earliest) |e| @min(e, due) else due;
        }
        const due = earliest orelse return null;
        const rem_s = @max(0.0, due - now);
        return @intFromFloat(@ceil(rem_s * 1000.0) + 1.0);
    }

    /// Records the active surface's state for the retention window, or
    /// forgets at once when retention is off or the field was cleared.
    pub fn hide(p: *Panel) void {
        p.pending = null;
        const now = p.clock.now();
        p.expireAt(now);
        if (p.retention_seconds <= 0) {
            p.forget();
            p.hidden = true;
            return;
        }
        if (!p.hidden) {
            switch (p.mode) {
                .search => p.saveSearch(now),
                .clipboard => p.saveBoard(now),
            }
            p.hidden = true;
        }
    }

    /// Opens search, restoring the retained query (fully selected), filter,
    /// and selected row by path when within the retention window.
    pub fn showSearch(p: *Panel) void {
        const now = p.clock.now();
        if (!p.hidden) switch (p.mode) {
            .search => p.saveSearch(now),
            .clipboard => p.saveBoard(now),
        };
        p.expireAt(now);
        p.hidden = false;
        p.mode = .search;
        if (p.retained_search.hidden_at != null) {
            p.retained_search.hidden_at = null;
            p.filter = p.retained_search.filter;
            p.field.set(p.retained_search.query.items);
            p.field.want_caret = null;
            p.field.want_selection = .{ 0, p.field.text().len };
            p.field.focus();
            p.resetCompletion();
            p.caret_at_end = p.field.text().len == 0;
            p.answered.clearRetainingCapacity();
            p.refresh();
            if (p.retained_search.path.items.len > 0) {
                for (p.visible, 0..) |r, i| if (std.mem.eql(u8, r.path, p.retained_search.path.items)) {
                    p.selected = i;
                    break;
                };
            }
            p.reveal_selection = true;
        } else {
            p.forgetSearch();
            p.field.focus();
        }
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// Opens the clipboard board, restoring its retained query, kind filter,
    /// and selection (or selecting the newest matching copy since hide).
    pub fn showClipboard(p: *Panel) void {
        const now = p.clock.now();
        if (!p.hidden) switch (p.mode) {
            .search => p.saveSearch(now),
            .clipboard => p.saveBoard(now),
        };
        p.expireAt(now);
        p.hidden = false;
        p.mode = .clipboard;
        p.resetCompletion();
        if (p.retained_board.hidden_at) |hidden_at| {
            p.retained_board.hidden_at = null;
            p.board.filter = p.retained_board.filter;
            p.field.set(p.retained_board.query.items);
            p.field.want_caret = null;
            p.field.want_selection = .{ 0, p.field.text().len };
            p.field.focus();
            p.board.stale = true;
            p.board.answered.clearRetainingCapacity();
            p.board.refresh(p.field.text());
            p.board.selected = 0;
            var newest_idx: ?usize = null;
            var newest_at: f64 = hidden_at;
            for (p.board.visible, 0..) |e, i| {
                if (e.created_at > newest_at) {
                    newest_at = e.created_at;
                    newest_idx = i;
                }
            }
            if (newest_idx) |idx| {
                p.board.selected = idx;
            } else if (p.retained_board.selected_id) |id| {
                for (p.board.visible, 0..) |e, i| if (e.id == id) {
                    p.board.selected = i;
                    break;
                };
            }
            p.board.reveal_selection = true;
        } else {
            p.forgetBoard();
            p.field.focus();
            p.board.stale = true;
            p.board.refresh("");
        }
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
        if (p.mode == .clipboard) {
            if (!p.board.stale and std.mem.eql(u8, text, p.board.answered.items)) return;
            mac.signpostBegin(.keystroke);
            defer mac.signpostEnd(.keystroke);
            if (text.len == 0 and p.board.answered.items.len > 0) {
                p.board.filter = .all;
                p.retained_board.clear();
            }
            return p.board.refresh(text);
        }
        if (std.mem.eql(u8, text, p.answered.items)) return;
        mac.signpostBegin(.keystroke);
        defer mac.signpostEnd(.keystroke);
        if (text.len == 0 or text.len > p.answered.items.len) p.suppressed_by_backspace = false;
        if (text.len == 0) {
            p.filter = .all;
            p.retained_search.clear();
        }
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
        p.completion = p.topHitCompletion();
    }

    fn topHitCompletion(p: *const Panel) ?Completion {
        if (p.mode != .search or p.suppressed_by_backspace or !p.caret_at_end or p.composing or !p.isTopHit(0)) return null;
        const query = p.field.text();
        if (query.len == 0 or isLinkQuery(query) or hasLinkRow(p.rows)) return null;
        const top = p.visible[0];
        if (top.kind == .web) return null;
        if (top.title.len <= query.len or !std.ascii.startsWithIgnoreCase(top.title, query)) return null;
        return .{ .suffix = top.title[query.len..], .source = .top_hit };
    }

    fn resetCompletion(p: *Panel) void {
        p.suppressed_by_backspace = false;
        p.caret_at_end = true;
        p.composing = false;
        p.completion = null;
    }

    fn acceptSlice(p: *Panel, part: []const u8) void {
        if (part.len == 0) return;
        p.resetCompletion();
        _ = p.field.insert(p.field.text().len, part);
        p.field.want_caret = p.field.text().len;
        p.refresh();
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
        if (p.completion) |comp| {
            if (c.shortcut(.{ .key = S.right }) or c.shortcut(.{ .key = S.tab }) or takeFieldKey(c, .right, false, .move_right) or takeFieldKey(c, .tab, false, .insert_tab)) {
                p.acceptSlice(comp.suffix);
                return;
            }
            if (c.shortcut(.{ .key = S.right, .alt = true }) or takeFieldKey(c, .right, true, .move_word_right)) {
                p.acceptSlice(comp.suffix[0..nextWordEnd(comp.suffix)]);
                return;
            }
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
        if (c.shortcut(.{ .key = S.enter, .alt = true }) or c.shortcut(.{ .key = 'c', .cmd = true })) p.ask(.{ .copy = row });
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
        if (!board) p.observeInput(c);
        const suggestion = if (!board and p.completion != null) p.completion.?.suffix else "";
        const r = ui.textField(c, &p.field, .{ .placeholder = if (board) "Filter clipboard" else "Floodlight", .size = 24, .width = .fill, .bare = true, .suggestion = suggestion });
        if (board) {
            p.boardField(r);
        } else {
            if (r.accepted) p.suppressed_by_backspace = false;
            if (r.changed) p.refresh();
            p.syncFieldState(c, r.caret);
            if (r.submitted and p.visible.len > 0) p.ask(.{ .open = p.visible[p.selected].path });
        }
        if (p.field.text().len > 0) {
            const clear = ui.div(c).w(24).h(24).center().control();
            defer clear.end();
            const hovered = clear.hovered();
            ui.icon(c, "xmark.circle.fill", .{ .size = metrics.clear_button_size, .color = if (hovered) th.text else th.muted });
            if (clear.clicked()) p.clearField();
        } else keyChip(c, .{ .label = if (board) board_mod.summon_label else summon_label });
    }

    fn observeInput(p: *Panel, c: *const ui.Context) void {
        if (hasBackspace(c)) {
            p.suppressed_by_backspace = true;
            p.completion = null;
        } else if (hasInsertion(c)) {
            p.suppressed_by_backspace = false;
        }
        if (hasMarkedText(c)) {
            p.composing = true;
            p.completion = null;
        }
    }

    fn syncFieldState(p: *Panel, c: *ui.Context, caret: usize) void {
        const len = p.field.text().len;
        const edit = c.edits.get(p.field.last_id);
        const at_end = if (edit) |e| (e.caret == len and e.anchor == len) else (caret == len);
        const marked = if (edit) |e| (e.marked != null) else false;
        p.caret_at_end = at_end;
        p.composing = marked;
        const next = p.topHitCompletion();
        if (!sameCompletion(p.completion, next)) {
            p.completion = next;
            c.changed = true;
        }
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
        boundOverscroll(c, list.id());
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

pub fn boundOverscroll(c: *ui.Context, scroll_box: u64) void {
    const over = c.overscroll.getPtr(scroll_box) orelse return;
    over.* = std.math.clamp(over.*, -metrics.max_overscroll, metrics.max_overscroll);
}

fn takeFieldKey(c: *ui.Context, key: anytype, alt: bool, cmd: anytype) bool {
    if (c.input.shift or c.input.cmd or c.input.ctrl) return false;
    if (c.input.alt == alt and c.input.key == key) {
        c.input.key = null;
        c.changed = true;
        return true;
    }
    if (c.input.ops.len == 1 and c.input.ops[0] == .command and c.input.ops[0].command == cmd) {
        c.input.ops = &.{};
        c.changed = true;
        return true;
    }
    return false;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn nextWordEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and !isWordByte(s[i])) i += 1;
    while (i < s.len and isWordByte(s[i])) i += 1;
    return i;
}

fn sameCompletion(a: ?Completion, b: ?Completion) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.source == y.source and std.mem.eql(u8, x.suffix, y.suffix);
}

fn hasBackspace(c: *const ui.Context) bool {
    if (c.input.key == .backspace) return true;
    for (c.input.ops) |op| {
        if (op == .command and (op.command == .delete_backward or op.command == .delete_word_backward or op.command == .delete_to_line_start)) return true;
    }
    return false;
}

fn hasInsertion(c: *const ui.Context) bool {
    if (c.input.chars.len > 0) return true;
    for (c.input.ops) |op| {
        if (op == .insert and op.insert.len > 0) return true;
    }
    return false;
}

fn hasMarkedText(c: *const ui.Context) bool {
    for (c.input.ops) |op| {
        if (op == .set_marked and op.set_marked.text.len > 0) return true;
    }
    return false;
}

fn hasLinkRow(rows: []const search.Row) bool {
    for (rows) |r| {
        if (r.kind == .web and !std.mem.eql(u8, r.title, "Google")) return true;
    }
    return false;
}

const web_tlds = [_][]const u8{
    "com",     "org",    "net",    "edu",   "gov",    "mil",  "int",  "io",      "co",    "ai",    "dev",  "me",      "gg",
    "xyz",     "tv",     "fm",     "am",    "to",     "ly",   "uk",   "de",      "fr",    "jp",    "cn",   "au",      "ca",
    "ch",      "nl",     "se",     "no",    "dk",     "fi",   "es",   "pt",      "it",    "is",    "at",   "be",      "us",
    "eu",      "kr",     "tw",     "hk",    "sg",     "nz",   "ie",   "ru",      "ua",    "cz",    "sk",   "hu",      "ro",
    "bg",      "gr",     "tr",     "il",    "za",     "mx",   "ar",   "cl",      "pe",    "tech",  "site", "online",  "blog",
    "biz",     "design", "studio", "cloud", "page",   "live", "work", "world",   "space", "fun",   "club", "team",    "zone",
    "chat",    "social", "media",  "games", "lol",    "wtf",  "fyi",  "run",     "build", "tools", "wiki", "systems", "security",
    "finance", "money",  "bank",   "law",   "health", "care", "bio",  "science", "math",  "art",   "book", "books",
};

fn isLinkQuery(text: []const u8) bool {
    const s = std.mem.trimEnd(u8, std.mem.trim(u8, text, " \t\r\n"), ".,;)");
    if (s.len == 0 or std.mem.indexOfAny(u8, s, " \t\r\n") != null) return false;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(s, scheme)) return clipboard.domain(s) != null;
    }
    if (std.mem.indexOf(u8, s, "://") != null) return false;
    const slash = std.mem.indexOfAny(u8, s, "/?#");
    const host_port = if (slash) |idx| s[0..idx] else s;
    const colon = std.mem.indexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    if (colon) |idx| if (!isValidPort(host_port[idx + 1 ..])) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or isIpv4(host)) return true;
    const tld = lastHostLabel(host) orelse return false;
    const www = std.ascii.startsWithIgnoreCase(host, "www.") and std.mem.indexOfScalar(u8, host["www.".len..], '.') != null;
    return www or colon != null or slash != null or inSet(tld, &web_tlds);
}

fn isValidPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    return (std.fmt.parseInt(u16, port, 10) catch 0) > 0;
}

fn isIpv4(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) {
        if (parts == 4 or part.len == 0 or part.len > 3) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return parts == 4;
}

fn lastHostLabel(host: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, host, '.') == null) return null;
    var it = std.mem.splitScalar(u8, host, '.');
    var last: []const u8 = "";
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return null;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return null;
        last = label;
    }
    if (last.len < 2) return null;
    for (last) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return last;
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
