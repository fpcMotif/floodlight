//! Inline query completion: history cache, top-hit/suggestion suffix selection,
//! caret/IME tracking, and Tab/Right/Option-Right acceptance.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const clipboard = @import("../clipboard.zig");

pub const Source = enum { history, top_hit, web_suggestion };

pub const Completion = struct {
    suffix: []const u8,
    source: Source,
};

pub const Inputs = struct {
    store: ?*const clipboard.Store,
    now: f64,
    is_clipboard: bool,
    query: []const u8,
    has_link_row: bool,
    top_hit_title: ?[]const u8,
    web_suggestion: ?[]const u8,
};

pub const Completer = struct {
    suppressed_by_backspace: bool = false,
    caret_at_end: bool = true,
    composing: bool = false,
    current: ?Completion = null,
    history_query: std.ArrayList(u8) = .empty,
    history_scope: clipboard.QueryScope = .search,
    history_buf: [512]u8 = undefined,
    history_len: ?usize = null,
    history_valid: bool = false,

    pub fn deinit(self: *Completer, gpa: std.mem.Allocator) void {
        self.history_query.deinit(gpa);
        self.current = null;
    }

    pub fn reset(self: *Completer) void {
        self.suppressed_by_backspace = false;
        self.caret_at_end = true;
        self.composing = false;
        self.current = null;
    }

    pub fn clearCurrent(self: *Completer) void {
        self.current = null;
    }

    pub fn suffix(self: *const Completer) []const u8 {
        return if (self.current) |comp| comp.suffix else "";
    }

    pub fn onAccepted(self: *Completer) void {
        self.suppressed_by_backspace = false;
    }

    pub fn onQueryChanged(self: *Completer, new_len: usize, answered_len: usize) void {
        if (new_len == 0 or new_len > answered_len) self.suppressed_by_backspace = false;
    }

    pub fn setCaretAtEnd(self: *Completer, at_end: bool) void {
        self.caret_at_end = at_end;
    }

    pub fn invalidateHistory(self: *Completer) void {
        self.history_valid = false;
        if (self.current) |comp| if (comp.source == .history) {
            self.current = null;
        };
    }

    fn historyCompletion(
        self: *Completer,
        gpa: std.mem.Allocator,
        store_opt: ?*const clipboard.Store,
        now: f64,
        scope: clipboard.QueryScope,
        query: []const u8,
    ) ?[]const u8 {
        if (self.history_valid and self.history_scope == scope and std.mem.eql(u8, self.history_query.items, query)) {
            return if (self.history_len) |n| self.history_buf[0..n] else null;
        }
        const store = store_opt orelse return null;
        const match = store.completeQuery(&self.history_buf, scope, query, now);
        self.history_query.clearRetainingCapacity();
        self.history_query.appendSlice(gpa, query) catch {
            self.history_valid = false;
            return match;
        };
        self.history_scope = scope;
        self.history_len = if (match) |m| m.len else null;
        self.history_valid = true;
        return match;
    }

    /// Query history first, then the top hit's title, then the first web suggestion.
    pub fn compute(self: *Completer, gpa: std.mem.Allocator, in: Inputs) ?Completion {
        if (self.suppressed_by_backspace or !self.caret_at_end or self.composing) return null;
        if (in.query.len == 0) return null;
        if (in.is_clipboard) {
            const match = self.historyCompletion(gpa, in.store, in.now, .clipboard, in.query) orelse return null;
            return .{ .suffix = match[in.query.len..], .source = .history };
        }
        if (in.has_link_row) return null;
        if (self.historyCompletion(gpa, in.store, in.now, .search, in.query)) |match| {
            return .{ .suffix = match[in.query.len..], .source = .history };
        }
        if (in.top_hit_title) |top| {
            if (top.len > in.query.len and std.ascii.startsWithIgnoreCase(top, in.query)) {
                return .{ .suffix = top[in.query.len..], .source = .top_hit };
            }
        }
        if (in.web_suggestion) |first| {
            if (first.len > in.query.len and std.ascii.startsWithIgnoreCase(first, in.query)) {
                return .{ .suffix = first[in.query.len..], .source = .web_suggestion };
            }
        }
        return null;
    }

    pub fn refresh(self: *Completer, gpa: std.mem.Allocator, in: Inputs) void {
        self.current = self.compute(gpa, in);
    }

    pub fn observeInput(self: *Completer, c: *const ui.Context) void {
        if (hasBackspace(c)) {
            self.suppressed_by_backspace = true;
            self.current = null;
        } else if (hasInsertion(c)) {
            self.suppressed_by_backspace = false;
        }
        if (hasMarkedText(c)) {
            self.composing = true;
            self.current = null;
        }
    }

    pub fn syncFieldState(
        self: *Completer,
        gpa: std.mem.Allocator,
        c: *ui.Context,
        field: *const ui.TextBuffer,
        caret: usize,
        in: Inputs,
    ) void {
        const len = field.text().len;
        const edit = c.edits.get(field.last_id);
        const at_end = if (edit) |e| (e.caret == len and e.anchor == len) else (caret == len);
        const marked = if (edit) |e| (e.marked != null) else false;
        self.caret_at_end = at_end;
        self.composing = marked;
        const next = self.compute(gpa, in);
        if (!sameCompletion(self.current, next)) {
            self.current = next;
            c.changed = true;
        }
    }

    pub fn takeAcceptKey(self: *const Completer, c: *ui.Context) ?[]const u8 {
        const comp = self.current orelse return null;
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.right }) or c.shortcut(.{ .key = S.tab }) or takeFieldKey(c, .right, false, .move_right) or takeFieldKey(c, .tab, false, .insert_tab)) {
            return comp.suffix;
        }
        if (c.shortcut(.{ .key = S.right, .alt = true }) or takeFieldKey(c, .right, true, .move_word_right)) {
            return comp.suffix[0..nextWordEnd(comp.suffix)];
        }
        return null;
    }
};

fn sameCompletion(a: ?Completion, b: ?Completion) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.source == y.source and std.mem.eql(u8, x.suffix, y.suffix);
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
