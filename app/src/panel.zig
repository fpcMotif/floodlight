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
const mac = @import("mac.zig");
const panel_completion = @import("panel/completion.zig");
const panel_suggestions = @import("panel/suggestions.zig");
const panel_view = @import("panel/view.zig");

const metrics = chrome.metrics;

pub const summon_label = panel_view.summon_label;

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
        return switch (f) {
            .all => true,
            .apps => r.kind == .app,
            .files => r.kind == .file,
            .folders => r.kind == .folder,
            .pdfs => r.kind == .file and std.ascii.eqlIgnoreCase(r.extension(), "pdf"),
            .images => r.kind == .file and clipboard.inSet(r.extension(), &clipboard.image_extensions),
            .documents => r.kind == .file and clipboard.inSet(r.extension(), &document_extensions),
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
    show_search,
    clipboard: board_mod.Action,
};

pub const Mode = enum { search, clipboard };

pub const Clock = clipboard.Clock;

pub const CompletionSource = panel_completion.Source;
pub const Completion = panel_completion.Completion;

/// What the panel asks of the window, handled after the frame.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    clock: Clock = .wall_clock,
    /// An action, or a new height to fit the rows.
    request: *const fn (?*anyopaque) void,
    /// An app's icon as PNG, cached by the shell; null draws a symbol.
    app_icon: *const fn (?*anyopaque, []const u8) ?ui.ImageSource.Pixels,
    describe_date: *const fn (?*anyopaque, i64, std.mem.Allocator) []const u8,
    /// "Today at 3:03 PM": the board inspector's Copied and Pinned.
    detailed_date: *const fn (?*anyopaque, f64, std.mem.Allocator) []const u8,
    suggest: *const fn (?*anyopaque, u64, []const u8) void = noSuggest,
};

fn noSuggest(_: ?*anyopaque, _: u64, _: []const u8) void {}

pub const min_suggest_bytes = panel_suggestions.min_bytes;

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
    list: Results,
    /// The catalog's rows for the answered query, before web suggestions.
    base_rows: []const search.Row = &.{},
    /// The apps listed on an empty query, ready before the hot key lands;
    /// rebuilt only when a count or the app catalog changes.
    frequent_rows: []const search.Row = &.{},
    frequent_arena: std.heap.ArenaAllocator,
    frequent_dirty: bool = true,
    frequent_catalog_len: usize = 0,
    web: panel_suggestions.State = .{},
    completer: panel_completion.Completer = .{},
    pending_select_key: ?u64 = null,
    /// Its bytes live in `action_arena`, not the rows': the shell runs it on
    /// a later turn, after a capture or an index swap may have queried again.
    pending: ?Action = null,
    action_arena: std.heap.ArenaAllocator,
    /// The shell's expiry timer is pending; it keeps at most one.
    expiry_armed: bool = false,
    keystroke_open: bool = false,
    presented_key: ?u64 = null,
    height: f32 = metrics.search_height,
    width: f32 = metrics.width,

    pub fn init(gpa: std.mem.Allocator, catalog: *search.Catalog, store: ?*const clipboard.Store, hooks: Hooks) Panel {
        return .{ .catalog = catalog, .store = store, .hooks = hooks, .clock = hooks.clock, .list = .init(gpa), .board = .init(gpa, store, hooks.clock), .frequent_arena = .init(gpa), .action_arena = .init(gpa) };
    }

    pub fn deinit(p: *Panel) void {
        p.endKeystroke();
        const gpa = p.list.arena.child_allocator;
        p.frequent_arena.deinit();
        p.action_arena.deinit();
        p.retained_search.deinit(gpa);
        p.retained_board.deinit(gpa);
        p.board.deinit();
        p.field.deinit();
        p.web.deinit(gpa);
        p.completer.deinit(gpa);
        p.list.deinit();
    }

    fn forgetSearch(p: *Panel) void {
        p.retained_search.clear();
        p.list.reset();
        p.catalog.cancel();
        p.pending_select_key = null;
        p.base_rows = &.{};
        p.web.clear();
        p.completer.invalidateHistory();
        p.completer.reset();
        if (p.mode == .search) {
            p.field.clear();
            p.height = p.panelHeight();
            p.width = p.panelWidth();
        }
    }

    fn forgetBoard(p: *Panel) void {
        p.retained_board.clear();
        p.board.forget();
        p.completer.invalidateHistory();
        if (p.mode == .clipboard) {
            p.field.clear();
            p.height = p.panelHeight();
            p.width = p.panelWidth();
        }
    }

    /// Drops both surfaces' retained sessions: queries, rows, and the
    /// memory behind them.
    pub fn forget(p: *Panel) void {
        p.endKeystroke();
        p.forgetSearch();
        p.forgetBoard();
        p.field.clear();
        p.pending = null;
        p.hidden = false;
        p.mode = .search;
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// Clears the field and forgets the active surface's retained session.
    pub fn clearField(p: *Panel) void {
        p.field.clear();
        if (p.mode == .clipboard) {
            p.retained_board.clear();
            p.board.forget();
            p.board.refresh("");
            return;
        }
        p.forgetSearch();
        p.loadFrequentApps();
    }

    fn saveSearch(p: *Panel, now: f64) void {
        if (p.retention_seconds <= 0 or p.field.text().len == 0) return p.forgetSearch();
        const gpa = p.list.arena.child_allocator;
        p.retained_search.query.clearRetainingCapacity();
        p.retained_search.query.appendSlice(gpa, p.field.text()) catch {};
        p.retained_search.path.clearRetainingCapacity();
        if (p.list.selection()) |row| p.retained_search.path.appendSlice(gpa, row.path) catch {};
        p.retained_search.filter = p.list.filter;
        p.retained_search.hidden_at = now;
    }

    fn saveBoard(p: *Panel, now: f64) void {
        const l = &p.board.list;
        if (p.retention_seconds <= 0 or (p.field.text().len == 0 and l.filter == .all and l.selected == 0)) return p.forgetBoard();
        const gpa = p.list.arena.child_allocator;
        p.retained_board.query.clearRetainingCapacity();
        p.retained_board.query.appendSlice(gpa, p.field.text()) catch {};
        p.retained_board.filter = l.filter;
        p.retained_board.selected_id = if (l.selection()) |e| e.id else null;
        p.retained_board.hidden_at = now;
        p.board.releaseDetail();
    }

    fn saveActive(p: *Panel, now: f64) void {
        switch (p.mode) {
            .search => p.saveSearch(now),
            .clipboard => p.saveBoard(now),
        }
    }

    fn expireAt(p: *Panel, now: f64) void {
        if (p.retained_search.hidden_at) |at| {
            if (p.retention_seconds <= 0 or now - at >= p.retention_seconds) p.forgetSearch();
        }
        if (p.retained_board.hidden_at) |at| {
            if (p.retention_seconds <= 0 or now - at >= p.retention_seconds) p.forgetBoard();
        }
    }

    /// Drops any surface whose retention window has elapsed; true when
    /// neither surface remains retained.
    pub fn expire(p: *Panel) bool {
        p.expireAt(p.clock.now());
        p.completer.invalidateHistory();
        return p.retained_search.hidden_at == null and p.retained_board.hidden_at == null;
    }

    /// Milliseconds until the earliest retained surface expires; null when
    /// nothing is retained.
    pub fn nextExpiryMs(p: *const Panel) ?u32 {
        if (p.retention_seconds <= 0) return null;
        var earliest: ?f64 = null;
        if (p.retained_search.hidden_at) |at| earliest = at + p.retention_seconds;
        if (p.retained_board.hidden_at) |at| {
            const due = at + p.retention_seconds;
            earliest = if (earliest) |e| @min(e, due) else due;
        }
        const due = earliest orelse return null;
        if (!std.math.isFinite(due)) return null;
        const now = p.clock.now();
        if (!std.math.isFinite(now)) return null;
        const rem_s = @max(0.0, due - now);
        const ms_f = @ceil(rem_s * 1000.0) + 1.0;
        if (!std.math.isFinite(ms_f) or ms_f >= @as(f64, std.math.maxInt(u32))) return std.math.maxInt(u32);
        return @intFromFloat(ms_f);
    }

    /// The delay for the shell's expiry timer; null when one is already
    /// pending or nothing is retained. A later expiry is never earlier.
    pub fn armExpiry(p: *Panel) ?u32 {
        if (p.expiry_armed) return null;
        const ms = p.nextExpiryMs() orelse return null;
        p.expiry_armed = true;
        return ms;
    }

    /// The expiry timer fired; call before `expire`.
    pub fn disarmExpiry(p: *Panel) void {
        p.expiry_armed = false;
    }

    /// Records the active surface's state for the retention window, or
    /// forgets at once when retention is off or the field was cleared.
    pub fn hide(p: *Panel) void {
        p.endKeystroke();
        p.pending = null;
        p.completer.invalidateHistory();
        const now = p.clock.now();
        p.expireAt(now);
        // Rebuilt while hidden, so the next summon only copies it.
        _ = p.frequentApps();
        if (p.retention_seconds <= 0) {
            p.forget();
            p.hidden = true;
            return;
        }
        if (!p.hidden) p.saveActive(now);
        p.hidden = true;
    }

    /// Opens search, restoring the retained query (fully selected), filter,
    /// and selected row by path when within the retention window.
    pub fn showSearch(p: *Panel) void {
        const now = p.clock.now();
        if (!p.hidden) p.saveActive(now);
        p.expireAt(now);
        p.hidden = false;
        p.mode = .search;
        if (p.retained_search.hidden_at != null) {
            p.retained_search.hidden_at = null;
            p.list.filter = p.retained_search.filter;
            p.restoreField(p.retained_search.query.items);
            p.completer.setCaretAtEnd(p.field.text().len == 0);
            p.refresh();
            p.pending_select_key = null;
            const path = p.retained_search.path.items;
            if (path.len > 0) {
                var found = false;
                for (p.list.visible, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) {
                    p.list.selected = i;
                    found = true;
                    break;
                };
                if (!found and p.catalog.hasPending()) {
                    p.pending_select_key = std.hash.Wyhash.hash(0, path);
                }
            }
            p.list.reveal = true;
        } else {
            p.forgetSearch();
            p.loadFrequentApps();
            p.field.focus();
        }
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// Opens the clipboard board, restoring its retained query, kind filter,
    /// and selection (or selecting the newest matching copy since hide).
    pub fn showClipboard(p: *Panel) void {
        const now = p.clock.now();
        if (!p.hidden) p.saveActive(now);
        p.expireAt(now);
        p.hidden = false;
        p.mode = .clipboard;
        p.web.clear();
        p.completer.reset();
        const l = &p.board.list;
        if (p.retained_board.hidden_at) |hidden_at| {
            p.retained_board.hidden_at = null;
            l.filter = p.retained_board.filter;
            p.restoreField(p.retained_board.query.items);
            l.markStale();
            p.board.refresh(p.field.text());
            l.selected = 0;
            var newest_at = hidden_at;
            var newest: ?usize = null;
            for (l.visible, 0..) |e, i| if (e.created_at > newest_at) {
                newest_at = e.created_at;
                newest = i;
            };
            if (newest) |i| {
                l.selected = i;
            } else if (p.retained_board.selected_id) |id| for (l.visible, 0..) |e, i| if (e.id == id) {
                l.selected = i;
                break;
            };
            l.reveal = true;
        } else {
            p.forgetBoard();
            p.field.focus();
            p.board.refresh("");
        }
        p.height = p.panelHeight();
        p.width = p.panelWidth();
    }

    /// The retained query, fully selected so typing replaces it.
    fn restoreField(p: *Panel, query: []const u8) void {
        p.field.set(query);
        p.field.want_caret = null;
        p.field.want_selection = .{ 0, p.field.text().len };
        p.field.focus();
        p.completer.reset();
    }

    pub fn keystrokePending(p: *const Panel) bool {
        return p.keystroke_open;
    }

    fn beginKeystroke(p: *Panel) void {
        if (p.keystroke_open) return;
        p.keystroke_open = true;
        mac.signpostBegin(.keystroke);
    }

    fn endKeystroke(p: *Panel) void {
        if (!p.keystroke_open) return;
        p.keystroke_open = false;
        mac.signpostEnd(.keystroke);
    }

    pub fn notePresented(p: *Panel) void {
        p.endKeystroke();
        p.presented_key = p.frameKey();
    }

    pub fn forgetPresented(p: *Panel) void {
        p.presented_key = null;
    }

    pub fn lastFrameValid(p: *const Panel) bool {
        const key = p.presented_key orelse return false;
        return key == p.frameKey();
    }

    fn frameKey(p: *const Panel) u64 {
        var h: std.hash.Wyhash = .init(0);
        hashValue(&h, p.mode);
        hashValue(&h, p.catalog.indexing());
        hashValue(&h, p.panelWidth());
        hashValue(&h, p.panelHeight());
        hashBytes(&h, p.field.text());
        switch (p.mode) {
            .search => {
                hashValue(&h, p.list.filter);
                hashValue(&h, p.list.selected);
                for (p.list.visible) |r| {
                    hashValue(&h, r.kind);
                    hashBytes(&h, r.path);
                }
            },
            .clipboard => {
                const l = &p.board.list;
                hashValue(&h, l.filter);
                hashValue(&h, l.selected);
                const now = p.clock.now();
                const minute_f = if (std.math.isFinite(now)) std.math.clamp(@floor(now / 60), -1e15, 1e15) else 0;
                hashValue(&h, @as(i64, @intFromFloat(minute_f)));
                for (l.visible) |e| {
                    hashValue(&h, e.id);
                    hashValue(&h, e.pinned_at orelse std.math.inf(f64));
                }
            },
        }
        return h.final();
    }

    pub fn panelHeight(p: *const Panel) f32 {
        if (p.mode == .clipboard) return board_mod.board_metrics.height;
        return if (p.field.text().len == 0 and p.list.visible.len == 0) metrics.search_height else metrics.expanded_height;
    }

    pub fn panelWidth(p: *const Panel) f32 {
        return if (p.mode == .clipboard) board_mod.board_metrics.width else metrics.width;
    }

    /// Searches again when the text changed since the last answer.
    pub fn refresh(p: *Panel) void {
        const text = p.field.text();
        if (p.mode == .clipboard) {
            if (!p.board.list.needsQuery(text)) return;
            p.beginKeystroke();
            if (text.len == 0 and p.board.list.answered().len > 0) {
                p.board.list.filter = .all;
                p.retained_board.clear();
            }
            p.completer.onQueryChanged(text.len, p.board.list.answered().len);
            p.board.refresh(text);
            p.refreshCompletion();
            return;
        }
        if (!p.list.needsQuery(text)) return;
        p.beginKeystroke();
        p.completer.onQueryChanged(text.len, p.list.answered().len);
        if (text.len == 0) {
            p.list.filter = .all;
            p.retained_search.clear();
        }
        const need_fetch = p.answer(text) catch |err| return p.failSearch(err);
        const l = &p.list;
        if (!p.catalog.hasPending() and l.filter != .all and l.count(l.filter) == 0 and std.mem.indexOfScalar(Filter, &Filter.dynamic, l.filter) != null) l.selectFilter(.all);
        p.refreshCompletion();
        if (need_fetch) {
            const seq = p.web.beginFetch(p.list.arena.child_allocator, text);
            p.hooks.suggest(p.hooks.ctx, seq, text);
        }
    }

    pub fn poll(p: *Panel) bool {
        const text = p.field.text();
        const trimmed = std.mem.trim(u8, text, " ");
        const session: search.Session = if (!p.hidden and p.mode == .search and trimmed.len > 0 and !p.list.needsQuery(text))
            .{ .live = .{ .arena = p.list.allocator(), .query = text } }
        else if ((!p.hidden and p.mode == .search and trimmed.len > 0) or p.retained_search.hidden_at != null)
            .retained
        else
            .idle;

        switch (p.catalog.poll(session)) {
            .none => return false,
            .redraw => return !p.hidden and p.mode == .search,
            .stale => {
                p.list.markStale();
                if (p.hidden or p.mode != .search) return false;
                p.refresh();
                return true;
            },
            .merged => |rows| {
                p.base_rows = rows;
                const composed = p.composeRows();
                const want_key = p.pending_select_key;
                p.pending_select_key = null;
                if (p.list.selected != 0) {
                    p.list.replaceRows(composed);
                } else {
                    p.list.setRows(text, composed) catch |err| {
                        p.failSearch(err);
                        return !p.hidden and p.mode == .search;
                    };
                    if (want_key) |k| {
                        for (p.list.visible, 0..) |r, i| if (rowKey(r) == k) {
                            p.list.selected = i;
                            p.list.reveal = true;
                            break;
                        };
                    }
                }
                const l = &p.list;
                if (l.filter != .all and l.count(l.filter) == 0 and std.mem.indexOfScalar(Filter, &Filter.dynamic, l.filter) != null) {
                    l.selectFilter(.all);
                }
                p.refreshCompletion();
                return true;
            },
            .failed => |err| {
                p.failSearch(err);
                return !p.hidden and p.mode == .search;
            },
        }
    }

    fn failSearch(p: *Panel, err: anyerror) void {
        std.log.err("search: {s}", .{@errorName(err)});
        p.base_rows = &.{};
        p.web.clear();
        p.pending_select_key = null;
        p.completer.clearCurrent();
        p.list.fail();
    }

    /// True when web suggestions for `text` must be fetched.
    fn answer(p: *Panel, text: []const u8) !bool {
        const same_stale = p.list.stale and std.mem.eql(u8, text, p.list.answered());
        const prior_key: ?u64 = if (same_stale)
            (p.pending_select_key orelse if (p.list.selection()) |r| rowKey(r) else null)
        else
            null;
        const a = p.list.beginQuery(text);
        if (text.len == 0) {
            p.catalog.cancel();
            p.base_rows = try copyRows(a, p.frequentApps());
        } else {
            p.base_rows = try p.catalog.query(a, text);
        }
        const need_fetch = p.web.lookupOrNeedFetch(p.list.arena.child_allocator, a, text, p.shouldSuggest(text), p.clock.now());
        try p.list.setRows(text, p.composeRows());
        const current_key: ?u64 = if (p.list.selection()) |r| rowKey(r) else null;
        p.pending_select_key = if (p.catalog.hasPending() and prior_key != null and current_key != prior_key) prior_key else null;
        return need_fetch;
    }

    pub fn setWebSuggestionsEnabled(p: *Panel, enabled: bool) void {
        if (p.web.enabled == enabled) return;
        p.web.enabled = enabled;
        if (!enabled) {
            p.web.clear();
            p.list.replaceRows(p.composeRows());
            p.refreshCompletion();
            return;
        }
        if (p.mode == .search and p.field.text().len > 0) {
            p.list.markStale();
            p.refresh();
        }
    }

    fn shouldSuggest(p: *Panel, text: []const u8) bool {
        if (!p.web.enabled or p.mode != .search) return false;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < min_suggest_bytes) return false;
        if (isPathLike(trimmed)) return false;
        return !hasLinkRow(p.base_rows);
    }

    pub fn pendingSuggestSeq(p: *const Panel) u64 {
        return p.web.pendingSeq();
    }

    pub fn receiveSuggestions(p: *Panel, query: []const u8, items: []const []const u8) void {
        _ = p.receiveSuggestionsFor(p.web.pendingSeq(), query, items);
    }

    /// False for a late reply: an old query, a superseded request, or a
    /// panel that has left search.
    pub fn receiveSuggestionsFor(p: *Panel, seq: u64, query: []const u8, items: []const []const u8) bool {
        if (p.mode != .search) return false;
        if (!p.web.accept(p.list.arena.child_allocator, p.list.allocator(), seq, query, p.field.text(), items, p.clock.now())) return false;
        p.list.replaceRows(p.composeRows());
        p.refreshCompletion();
        return true;
    }

    /// The catalog's rows, a Google row per suggestion, then one row per
    /// other web engine. Links and paths are not web queries, so they get no
    /// engine rows.
    fn composeRows(p: *Panel) []const search.Row {
        if (p.base_rows.len == 0) return p.base_rows;
        const query = std.mem.trim(u8, p.field.text(), " \t\r\n");
        const engines = p.mode == .search and query.len > 0 and !isPathLike(query) and !hasLinkRow(p.base_rows);
        const engine_count = if (engines) search.web_engines.len else 0;
        if (p.web.items.len == 0 and engine_count == 0) return p.base_rows;
        const a = p.list.allocator();
        const out = a.alloc(search.Row, p.base_rows.len + p.web.items.len + engine_count) catch return p.base_rows;
        @memcpy(out[0..p.base_rows.len], p.base_rows);
        for (p.web.items, p.base_rows.len..) |s, i| out[i] = .{
            .kind = .web,
            .title = s,
            .subtitle = "google.com",
            .path = search.webSearchUrl(a, s) catch "",
            .score = 0,
            .suggestion = true,
        };
        if (engines) for (search.web_engines, p.base_rows.len + p.web.items.len..) |e, i| {
            out[i] = .{
                .kind = .web,
                .title = e.title,
                .subtitle = e.host,
                .path = search.engineUrl(a, e, query) catch "",
                .score = 0,
                .engine = true,
            };
        };
        return out;
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
        p.pending_select_key = null;
        p.list.selectFilter(f);
        p.refreshCompletion();
        p.field.focus();
    }

    pub fn currentCompletion(p: *const Panel) ?Completion {
        return p.completer.current;
    }

    pub fn completionSuffix(p: *const Panel) []const u8 {
        return p.completer.suffix();
    }

    pub fn observeInput(p: *Panel, c: *const ui.Context) void {
        p.completer.observeInput(c);
    }

    pub fn acceptCompletionHint(p: *Panel) void {
        p.completer.onAccepted();
    }

    pub fn syncFieldState(p: *Panel, c: *ui.Context, caret: usize) void {
        p.completer.syncFieldState(p.list.arena.child_allocator, c, &p.field, caret, p.completionInputs());
    }

    /// Query history first, then the top hit's title, then the first web suggestion.
    pub fn computeCompletion(p: *Panel) ?Completion {
        return p.completer.compute(p.list.arena.child_allocator, p.completionInputs());
    }

    fn refreshCompletion(p: *Panel) void {
        p.completer.refresh(p.list.arena.child_allocator, p.completionInputs());
    }

    fn completionInputs(p: *const Panel) panel_completion.Inputs {
        const top_hit_title: ?[]const u8 = if (p.isTopHit(0) and p.list.visible[0].kind != .web)
            p.list.visible[0].title
        else
            null;
        return .{
            .store = p.store,
            .now = p.clock.now(),
            .is_clipboard = p.mode == .clipboard,
            .query = p.field.text(),
            .has_link_row = hasLinkRow(p.list.rows),
            .top_hit_title = top_hit_title,
            .web_suggestion = p.web.first(),
        };
    }

    /// Up to `search.max_suggested_apps` most-opened apps still in the catalog.
    fn frequentApps(p: *Panel) []const search.Row {
        const store = p.store orelse return &.{};
        if (!p.frequent_dirty and p.frequent_catalog_len == p.catalog.apps.items.len) return p.frequent_rows;
        _ = p.frequent_arena.reset(.retain_capacity);
        p.frequent_rows = &.{};
        p.frequent_dirty = false;
        p.frequent_catalog_len = p.catalog.apps.items.len;
        const a = p.frequent_arena.allocator();
        const paths = store.topApps(a, search.max_suggested_apps * 2, p.clock.now()) catch |err| {
            std.log.err("frequent apps: {s}", .{@errorName(err)});
            p.frequent_dirty = true;
            return &.{};
        };
        var rows: std.ArrayList(search.Row) = .empty;
        for (paths) |path| {
            for (p.catalog.apps.items) |app| {
                if (!std.mem.eql(u8, app.path, path)) continue;
                rows.append(a, .{
                    .kind = .app,
                    .title = app.name,
                    .subtitle = std.fs.path.dirname(path) orelse "/",
                    .path = path,
                    .score = 0,
                }) catch return &.{};
                break;
            }
            if (rows.items.len == search.max_suggested_apps) break;
        }
        p.frequent_rows = rows.items;
        return p.frequent_rows;
    }

    /// Fills an empty search field with the frequent apps.
    fn loadFrequentApps(p: *Panel) void {
        if (p.mode != .search or p.field.text().len != 0) return;
        p.list.markStale();
        p.refresh();
    }

    fn recordAppOpen(p: *Panel, path: []const u8) void {
        if (!std.mem.endsWith(u8, path, ".app")) return;
        const store = p.store orelse return;
        store.recordAppOpen(path, p.clock.now()) catch |err| return std.log.err("frequent apps: {s}", .{@errorName(err)});
        p.frequent_dirty = true;
    }

    pub fn clearAppOpens(p: *Panel) void {
        if (p.store) |store| store.clearAppOpens() catch |err| std.log.err("frequent apps: {s}", .{@errorName(err)});
        p.frequent_dirty = true;
        p.loadFrequentApps();
    }

    pub fn clearQueryHistory(p: *Panel) void {
        if (p.store) |store| store.clearQueries() catch |err| std.log.err("query history: {s}", .{@errorName(err)});
        p.completer.invalidateHistory();
        p.refreshCompletion();
    }

    fn acceptSlice(p: *Panel, part: []const u8) void {
        if (part.len == 0) return;
        p.completer.reset();
        _ = p.field.insert(p.field.text().len, part);
        p.field.want_caret = p.field.text().len;
        p.refresh();
    }

    pub fn isTopHit(p: *const Panel, i: usize) bool {
        return i == 0 and p.list.visible.len > 0 and p.list.filter == .all and p.field.text().len > 0;
    }

    pub fn ask(p: *Panel, a: Action) void {
        p.recordActionQuery(a);
        _ = p.action_arena.reset(.retain_capacity);
        p.pending = ownedAction(p.action_arena.allocator(), a) catch |err| {
            std.log.err("action: {s}", .{@errorName(err)});
            return;
        };
        p.hooks.request(p.hooks.ctx);
    }

    fn recordActionQuery(p: *Panel, a: Action) void {
        const store = p.store orelse return;
        if (a == .open) p.recordAppOpen(a.open);
        const scope: clipboard.QueryScope = switch (a) {
            .open, .reveal, .copy => .search,
            .clipboard => |ba| switch (ba) {
                .paste, .copy, .open, .reveal => if (p.hasSensitiveBoardMatch(ba)) return else .clipboard,
                .preview, .actions => return,
            },
            .hide, .show_search => return,
        };
        store.recordQuery(scope, p.field.text(), p.clock.now()) catch |err| std.log.err("query history: {s}", .{@errorName(err)});
        p.completer.invalidateHistory();
    }

    /// A query that matched a password manager's copy is never remembered.
    fn hasSensitiveBoardMatch(p: *const Panel, action: board_mod.Action) bool {
        const entry: ?clipboard.Entry = switch (action) {
            .paste, .copy => |e| e,
            .open, .reveal, .preview, .actions => p.board.list.selection(),
        };
        if (entry) |e| if (e.isSensitive()) return true;
        for (p.board.list.rows) |r| if (r.isSensitive()) return true;
        return false;
    }

    fn keys(p: *Panel, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) return p.ask(.hide);
        if (c.shortcut(.{ .key = chrome.backspace, .cmd = true, .shift = true })) return p.clearQueryHistory();
        if (c.shortcut(.{ .key = chrome.backspace, .cmd = true, .alt = true })) return p.clearAppOpens();
        if (p.completer.takeAcceptKey(c)) |part| {
            p.acceptSlice(part);
            return;
        }
        if (p.mode == .clipboard) {
            if (p.field.text().len == 0 and hasPlainBackspace(c)) return p.leaveBoard();
            if (p.board.keys(c, p.field.text().len == 0)) |a| p.ask(.{ .clipboard = a });
            return;
        }
        if (p.field.text().len == 0) {
            for (2..search.max_suggested_apps + 1) |n| {
                if (!c.shortcut(.{ .key = '0' + @as(u21, @intCast(n)), .cmd = true })) continue;
                if (n <= p.list.visible.len) p.ask(.{ .open = p.list.visible[n - 1].path });
                return;
            }
        }
        var buf: [Filter.primary.len + Filter.dynamic.len]Filter = undefined;
        const options = p.filterOptions(&buf);
        const prev_sel = p.list.selected;
        const prev_filter = p.list.filter;
        if (chrome.listKeys(c, &p.list, options[0..@min(options.len, 5)])) p.field.focus();
        if (p.list.selected != prev_sel or p.list.filter != prev_filter) p.pending_select_key = null;
        const row = p.list.selection() orelse return;
        if (c.shortcut(.{ .key = S.enter, .cmd = true }) or c.shortcut(.{ .key = 'r', .cmd = true })) {
            if (row.kind != .web) p.ask(.{ .reveal = row.path });
        }
        if (c.shortcut(.{ .key = S.enter, .alt = true }) or c.shortcut(.{ .key = 'c', .cmd = true })) p.ask(.{ .copy = row });
    }

    /// ⌫ on an empty filter drops the board's session and switches to search in place.
    fn leaveBoard(p: *Panel) void {
        p.forgetBoard();
        p.board.refresh("");
        p.ask(.show_search);
    }

    pub fn view(p: *Panel, c: *ui.Context) void {
        p.keys(c);
        panel_view.render(p, c);
    }
};

/// ⌫ alone, never ⌥⌫ or ⌘⌫. AppKit never offers a bare ⌫ as a shortcut:
/// a focused field gets `deleteBackward:`, an unfocused window the key.
fn hasPlainBackspace(c: *const ui.Context) bool {
    const in = c.input;
    if (in.key == .backspace) return !(in.cmd or in.ctrl or in.alt);
    for (c.input.ops) |op| {
        if (op == .command and op.command == .delete_backward) return true;
    }
    return false;
}

fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    h.update(std.mem.asBytes(&v));
}

fn hashBytes(h: *std.hash.Wyhash, s: []const u8) void {
    hashValue(h, s.len);
    h.update(s);
}

/// The list outlives the frequent-apps cache's rebuilds, so it owns its rows.
fn copyRows(a: std.mem.Allocator, rows: []const search.Row) ![]search.Row {
    const out = try a.dupe(search.Row, rows);
    for (out) |*r| {
        r.subtitle = try a.dupe(u8, r.subtitle);
        r.path = try a.dupe(u8, r.path);
    }
    return out;
}

/// `a` with every byte it points at copied into `arena`.
fn ownedAction(arena: std.mem.Allocator, a: Action) !Action {
    return switch (a) {
        .open => |path| .{ .open = try arena.dupe(u8, path) },
        .reveal => |path| .{ .reveal = try arena.dupe(u8, path) },
        .copy => |row| .{ .copy = try ownedRow(arena, row) },
        .hide, .show_search => a,
        .clipboard => |b| .{ .clipboard = switch (b) {
            .paste => |e| .{ .paste = try e.dupe(arena) },
            .copy => |e| .{ .copy = try e.dupe(arena) },
            .preview => |e| .{ .preview = try e.dupe(arena) },
            .actions => |e| .{ .actions = try e.dupe(arena) },
            .open => |url| .{ .open = try arena.dupe(u8, url) },
            .reveal => |path| .{ .reveal = try arena.dupe(u8, path) },
        } },
    };
}

fn ownedRow(arena: std.mem.Allocator, r: search.Row) !search.Row {
    var out = r;
    out.title = try arena.dupe(u8, r.title);
    out.subtitle = try arena.dupe(u8, r.subtitle);
    out.path = try arena.dupe(u8, r.path);
    return out;
}

fn isPathLike(s: []const u8) bool {
    return s.len > 0 and (s[0] == '/' or s[0] == '~' or s[0] == '.');
}

fn hasLinkRow(rows: []const search.Row) bool {
    for (rows) |r| {
        if (r.kind == .web and !r.suggestion and !r.engine and !std.mem.eql(u8, r.title, "Google")) return true;
    }
    return false;
}
