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
pub const suggestion_cache_ttl: f64 = 5 * 60;

const CachedSuggestions = struct {
    query: []u8,
    items: [][]u8,
    fetched_at: f64,
};

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
    suggest: *const fn (?*anyopaque, u64, []const u8) void = noSuggest,
};

fn noSuggest(_: ?*anyopaque, _: u64, _: []const u8) void {}

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
    store: ?*const clipboard.Store = null,
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
    base_rows: []search.Row = &.{},
    suggestions: []const []const u8 = &.{},
    rows: []search.Row = &.{},
    visible: []search.Row = &.{},
    /// The query `rows` answers, to search again only when it changes.
    answered: std.ArrayList(u8) = .empty,
    suggest_seq: u64 = 0,
    pending_suggest_seq: u64 = 0,
    pending_suggest_query: std.ArrayList(u8) = .empty,
    suggestion_cache: std.ArrayList(CachedSuggestions) = .empty,
    web_suggestions_enabled: bool = true,
    filter: Filter = .all,
    selected: usize = 0,
    reveal_selection: bool = false,
    indexing: bool = false,
    suppressed_by_backspace: bool = false,
    caret_at_end: bool = true,
    composing: bool = false,
    completion: ?Completion = null,
    completion_buf: [512]u8 = undefined,
    pending: ?Action = null,
    height: f32 = metrics.search_height,
    width: f32 = metrics.width,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, store: ?*const clipboard.Store, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .store = store, .hooks = hooks, .clock = hooks.clock, .arena = .init(gpa), .board = .init(gpa, store, hooks.clock) };
    }

    pub fn deinit(p: *Panel) void {
        const gpa = p.arena.child_allocator;
        p.retained_search.deinit(gpa);
        p.retained_board.deinit(gpa);
        p.board.deinit();
        p.field.deinit();
        p.answered.deinit(gpa);
        p.pending_suggest_query.deinit(gpa);
        p.freeAllCachedSuggestions();
        p.arena.deinit();
    }

    fn forgetSearch(p: *Panel) void {
        p.retained_search.clear();
        p.base_rows = &.{};
        p.suggestions = &.{};
        p.rows = &.{};
        p.visible = &.{};
        p.answered.clearRetainingCapacity();
        p.cancelPendingSuggest();
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
        p.cancelPendingSuggest();
        p.suggestions = &.{};
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
            if (text.len == 0 or text.len > p.board.answered.items.len) p.suppressed_by_backspace = false;
            p.board.refresh(text);
            p.completion = p.computeCompletion();
            return;
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
        p.base_rows = p.catalog.query(p.arena.allocator(), text) catch &.{};
        p.suggestions = &.{};
        const eligible = p.shouldSuggest(text);
        var need_fetch = false;
        if (eligible) {
            if (p.suggestion_cache.items.len > 0) {
                if (p.cachedSuggestions(text, p.clock.now())) |cached| {
                    p.cancelPendingSuggest();
                    p.suggestions = p.dupeSuggestions(cached);
                } else {
                    need_fetch = true;
                }
            } else {
                need_fetch = true;
            }
        } else {
            p.cancelPendingSuggest();
        }
        p.rebuildRows();
        p.answered.clearRetainingCapacity();
        p.answered.appendSlice(p.arena.child_allocator, text) catch {};
        if (p.filter != .all and p.count(p.filter) == 0 and std.mem.indexOfScalar(Filter, &Filter.dynamic, p.filter) != null) p.filter = .all;
        p.applyFilter();
        if (need_fetch) {
            p.suggest_seq += 1;
            p.pending_suggest_seq = p.suggest_seq;
            p.pending_suggest_query.clearRetainingCapacity();
            p.pending_suggest_query.appendSlice(p.arena.child_allocator, text) catch {};
            p.hooks.suggest(p.hooks.ctx, p.pending_suggest_seq, text);
        }
    }

    pub fn setWebSuggestionsEnabled(p: *Panel, enabled: bool) void {
        if (p.web_suggestions_enabled == enabled) return;
        p.web_suggestions_enabled = enabled;
        if (!enabled) {
            p.cancelPendingSuggest();
            p.suggestions = &.{};
            p.rebuildRows();
            p.updateVisible();
            return;
        }
        if (p.mode == .search and p.field.text().len > 0) {
            p.answered.clearRetainingCapacity();
            p.refresh();
        }
    }

    fn shouldSuggest(p: *Panel, text: []const u8) bool {
        if (!p.web_suggestions_enabled or p.mode != .search) return false;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return false;
        if (isPathLike(text) or isPathLike(trimmed)) return false;
        if (hasLinkRow(p.base_rows)) return false;
        return true;
    }

    fn cancelPendingSuggest(p: *Panel) void {
        p.pending_suggest_seq = 0;
        p.pending_suggest_query.clearRetainingCapacity();
    }

    pub fn receiveSuggestions(p: *Panel, query: []const u8, items: []const []const u8) void {
        _ = p.receiveSuggestionsFor(p.pending_suggest_seq, query, items);
    }

    pub fn receiveSuggestionsFor(p: *Panel, seq: u64, query: []const u8, items: []const []const u8) bool {
        if (!p.web_suggestions_enabled or p.mode != .search) return false;
        if (p.pending_suggest_seq == 0 or seq != p.pending_suggest_seq) return false;
        if (!std.mem.eql(u8, query, p.pending_suggest_query.items)) return false;
        if (!std.mem.eql(u8, query, p.field.text())) return false;
        p.cancelPendingSuggest();
        p.storeCachedSuggestions(query, items, p.clock.now());
        p.suggestions = p.dupeSuggestions(items);
        p.rebuildRows();
        p.updateVisible();
        return true;
    }

    fn cachedSuggestions(p: *Panel, query: []const u8, now: f64) ?[]const []const u8 {
        const gpa = p.arena.child_allocator;
        var i: usize = 0;
        while (i < p.suggestion_cache.items.len) {
            const entry = p.suggestion_cache.items[i];
            if (now - entry.fetched_at >= suggestion_cache_ttl) {
                freeCacheEntry(gpa, entry);
                _ = p.suggestion_cache.swapRemove(i);
                continue;
            }
            if (std.mem.eql(u8, entry.query, query)) return entry.items;
            i += 1;
        }
        return null;
    }

    fn storeCachedSuggestions(p: *Panel, query: []const u8, items: []const []const u8, now: f64) void {
        const gpa = p.arena.child_allocator;
        var i: usize = 0;
        while (i < p.suggestion_cache.items.len) {
            const entry = p.suggestion_cache.items[i];
            if (now - entry.fetched_at >= suggestion_cache_ttl or std.mem.eql(u8, entry.query, query)) {
                freeCacheEntry(gpa, entry);
                _ = p.suggestion_cache.swapRemove(i);
                continue;
            }
            i += 1;
        }
        var total: usize = 0;
        for (items) |s| {
            if (s.len == 0) continue;
            total += 1;
            if (total == search.max_suggestions) break;
        }
        const q_copy = gpa.dupe(u8, query) catch return;
        const owned = gpa.alloc([]u8, total) catch {
            gpa.free(q_copy);
            return;
        };
        var n: usize = 0;
        for (items) |s| {
            if (s.len == 0) continue;
            owned[n] = gpa.dupe(u8, s) catch {
                for (owned[0..n]) |prev| gpa.free(prev);
                gpa.free(owned);
                gpa.free(q_copy);
                return;
            };
            n += 1;
            if (n == total) break;
        }
        p.suggestion_cache.append(gpa, .{ .query = q_copy, .items = owned, .fetched_at = now }) catch {
            for (owned) |prev| gpa.free(prev);
            gpa.free(owned);
            gpa.free(q_copy);
        };
    }

    fn freeAllCachedSuggestions(p: *Panel) void {
        const gpa = p.arena.child_allocator;
        for (p.suggestion_cache.items) |entry| freeCacheEntry(gpa, entry);
        p.suggestion_cache.deinit(gpa);
    }

    fn freeCacheEntry(gpa: std.mem.Allocator, entry: CachedSuggestions) void {
        for (entry.items) |s| gpa.free(s);
        gpa.free(entry.items);
        gpa.free(entry.query);
    }

    fn dupeSuggestions(p: *Panel, items: []const []const u8) []const []const u8 {
        const a = p.arena.allocator();
        var total: usize = 0;
        for (items) |s| {
            if (s.len == 0) continue;
            total += 1;
            if (total == search.max_suggestions) break;
        }
        if (total == 0) return &.{};
        const out = a.alloc([]const u8, total) catch return &.{};
        var n: usize = 0;
        for (items) |s| {
            if (s.len == 0) continue;
            out[n] = a.dupe(u8, s) catch return out[0..n];
            n += 1;
            if (n == total) break;
        }
        return out[0..n];
    }

    fn rebuildRows(p: *Panel) void {
        if (p.suggestions.len == 0 or p.base_rows.len == 0) {
            p.rows = p.base_rows;
            return;
        }
        const a = p.arena.allocator();
        const out = a.alloc(search.Row, p.base_rows.len + p.suggestions.len) catch {
            p.rows = p.base_rows;
            return;
        };
        @memcpy(out[0..p.base_rows.len], p.base_rows);
        for (p.suggestions, 0..) |s, i| {
            out[p.base_rows.len + i] = .{
                .kind = .web,
                .title = s,
                .subtitle = "google.com",
                .path = search.webSearchUrl(a, s) catch "",
                .score = 0,
                .suggestion = true,
            };
        }
        p.rows = out;
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

    fn updateVisible(p: *Panel) void {
        const out = p.arena.allocator().alloc(search.Row, p.rows.len) catch return;
        var n: usize = 0;
        for (p.rows) |r| if (p.filter.includes(r)) {
            out[n] = r;
            n += 1;
        };
        p.visible = out[0..n];
        if (p.visible.len == 0) {
            p.selected = 0;
        } else if (p.selected >= p.visible.len) {
            p.selected = p.visible.len - 1;
        }
        p.completion = p.computeCompletion();
    }

    fn applyFilter(p: *Panel) void {
        p.selected = 0;
        p.reveal_selection = true;
        p.updateVisible();
    }

    fn computeCompletion(p: *Panel) ?Completion {
        if (p.suppressed_by_backspace or !p.caret_at_end or p.composing) return null;
        const query = p.field.text();
        if (query.len == 0) return null;
        if (p.mode == .clipboard) {
            const store = p.store orelse return null;
            const match = store.completeQuery(&p.completion_buf, .clipboard, query, p.clock.now()) orelse return null;
            return .{ .suffix = match[query.len..], .source = .history };
        }
        if (hasLinkRow(p.rows)) return null;
        if (p.store) |store| {
            if (store.completeQuery(&p.completion_buf, .search, query, p.clock.now())) |match| {
                return .{ .suffix = match[query.len..], .source = .history };
            }
        }
        if (p.isTopHit(0)) {
            const top = p.visible[0];
            if (top.kind != .web and top.title.len > query.len and std.ascii.startsWithIgnoreCase(top.title, query)) {
                return .{ .suffix = top.title[query.len..], .source = .top_hit };
            }
        }
        if (p.web_suggestions_enabled and p.suggestions.len > 0) {
            const first = p.suggestions[0];
            if (first.len > query.len and std.ascii.startsWithIgnoreCase(first, query)) {
                return .{ .suffix = first[query.len..], .source = .web_suggestion };
            }
        }
        return null;
    }

    pub fn clearQueryHistory(p: *Panel) void {
        if (p.store) |store| store.clearQueries() catch {};
        p.completion = p.computeCompletion();
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
        p.recordActionQuery(a);
        p.pending = a;
        p.hooks.request(p.hooks.ctx);
    }

    fn recordActionQuery(p: *Panel, a: Action) void {
        const store = p.store orelse return;
        switch (a) {
            .open, .reveal, .copy => store.recordQuery(.search, p.field.text(), p.clock.now()) catch {},
            .clipboard => |ba| switch (ba) {
                .paste, .copy, .open, .reveal => {
                    if (!p.hasSensitiveBoardMatch(ba)) store.recordQuery(.clipboard, p.field.text(), p.clock.now()) catch {};
                },
                .preview, .actions => {},
            },
            .hide => {},
        }
    }

    fn hasSensitiveBoardMatch(p: *const Panel, action: board_mod.Action) bool {
        const entry: ?clipboard.Entry = switch (action) {
            .paste => |e| e,
            .copy => |e| e,
            .open, .reveal, .preview, .actions => p.board.selection(),
        };
        if (entry) |e| if (e.isSensitive()) return true;
        for (p.board.rows) |r| if (r.isSensitive()) return true;
        return false;
    }

    fn move(p: *Panel, down: bool) void {
        if (p.visible.len == 0) return;
        p.selected = if (down) @min(p.selected + 1, p.visible.len - 1) else p.selected -| 1;
        p.reveal_selection = true;
    }

    fn keys(p: *Panel, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) return p.ask(.hide);
        if (c.shortcut(.{ .key = 0x7f, .cmd = true, .shift = true })) return p.clearQueryHistory();
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
        p.observeInput(c);
        const suggestion = if (p.completion) |comp| comp.suffix else "";
        const r = ui.textField(c, &p.field, .{ .placeholder = if (board) "Filter clipboard" else "Floodlight", .size = 24, .width = .fill, .bare = true, .suggestion = suggestion });
        if (r.accepted) p.suppressed_by_backspace = false;
        if (board) {
            p.boardField(r);
        } else {
            if (r.changed) p.refresh();
            if (r.submitted and p.visible.len > 0) p.ask(.{ .open = p.visible[p.selected].path });
        }
        p.syncFieldState(c, r.caret);
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
        const next = p.computeCompletion();
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
                    if (row.suggestion) {
                        p.suggestionTitle(c, row.title);
                    } else {
                        ui.text(c, row.title, .{ .size = 15, .weight = .medium, .truncate = .ellipsis });
                    }
                    const badge = ui.div(c).px(5).py(2).roundedFull().bg(th.muted.alpha(0.07));
                    defer badge.end();
                    ui.text(c, row.kind.label(), .{ .size = 8.5, .weight = .bold, .color = th.muted });
                }
            }
            p.subtitleLine(c, row, top_hit);
        }
        if (selected) keyChip(c, .{ .symbol = "return" });
    }

    fn suggestionTitle(p: *const Panel, c: *ui.Context, title: []const u8) void {
        const query = p.field.text();
        const trimmed = std.mem.trim(u8, query, " ");
        const prefix_len: usize = if (query.len > 0 and std.ascii.startsWithIgnoreCase(title, query))
            query.len
        else if (trimmed.len > 0 and std.ascii.startsWithIgnoreCase(title, trimmed))
            trimmed.len
        else
            0;
        const style: ui.TextStyle = .{ .size = 15, .weight = .regular, .truncate = .ellipsis };
        if (prefix_len >= title.len) {
            ui.text(c, title, style);
            return;
        }
        const spans = c.arena.allocator().dupe(ui.Span, &.{
            .{ .start = @intCast(prefix_len), .end = @intCast(title.len), .weight = .bold },
        }) catch {
            ui.text(c, title, style);
            return;
        };
        ui.richText(c, title, spans, style);
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

fn isPathLike(s: []const u8) bool {
    return s.len > 0 and (s[0] == '/' or s[0] == '~' or s[0] == '.');
}

fn hasLinkRow(rows: []const search.Row) bool {
    for (rows) |r| {
        if (r.kind == .web and !r.suggestion and !std.mem.eql(u8, r.title, "Google")) return true;
    }
    return false;
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
