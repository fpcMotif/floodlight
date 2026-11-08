//! Panel Presence: whether the search panel is on screen, and every rule
//! that brings it up or sends it away. The shell carries out each effect.
const mac = @import("mac.zig");
const panel = @import("panel.zig");

pub const Phase = enum {
    hidden,
    /// A window ordered out keeps the last frame it presented, and ordered in
    /// shows it until the next one lands: the board scrolled where it was left,
    /// then snapping to the top. The window is unseen until its own frame.
    entering,
    shown,
};

pub const Effect = enum {
    /// Remember the frontmost app: Return pastes there.
    note_paste_target,
    /// Size the panel and centre it on the pointer's screen.
    place,
    /// Switch the panel to search, restoring a retained session.
    open_search,
    /// Switch the panel to the clipboard board.
    open_board,
    /// Order the window in at alpha 0.
    order_in_unseen,
    /// Bring the already visible window to the front.
    order_front,
    /// Call `entranceTimedOut` after the fallback delay.
    start_entrance_timer,
    /// Set the window's alpha to 1.
    reveal,
    hide_window,
    /// End the session: keep it for the retention window, or forget it.
    end_session,
    /// Send ⌘V to the noted paste target.
    deliver_paste,
};

pub const Effects = struct {
    ctx: ?*anyopaque,
    run: *const fn (?*anyopaque, Effect) void,
};

pub const Presence = struct {
    phase: Phase = .hidden,
    effects: Effects,
    entrances: u32 = 0,
    /// Timers share one delay on the main queue, so they fire in the order
    /// they started: the nth to fire belongs to the nth entrance.
    timers_fired: u32 = 0,

    /// ⌥Space: hides only a focused panel that already shows search.
    pub fn search(p: *Presence, focused: bool, on_board: bool) void {
        if (p.phase != .hidden and focused and !on_board) return p.hide();
        p.show(false);
    }

    /// ⌥⇧C: hides only a focused panel that already shows the board.
    pub fn board(p: *Presence, focused: bool, on_board: bool) void {
        if (p.phase != .hidden and focused and on_board) return p.hide();
        p.show(true);
    }

    pub fn launched(p: *Presence, guiding: bool) void {
        if (!guiding) p.show(false);
    }

    pub fn reopened(p: *Presence) void {
        p.show(false);
    }

    /// A click anywhere else dismisses it, as Spotlight; Quick Look over
    /// the board does not.
    pub fn focusLost(p: *Presence, quick_look_open: bool) void {
        if (p.phase != .hidden and !quick_look_open) p.hide();
    }

    /// Call after the action itself is done.
    pub fn settle(p: *Presence, a: panel.Action) void {
        switch (a) {
            .open, .reveal, .copy, .hide => p.hide(),
            .clipboard => |b| switch (b) {
                .paste => {
                    // ⌘V goes to the frontmost app: the panel must be gone.
                    p.hide();
                    p.run(.deliver_paste);
                },
                .open, .reveal => p.hide(),
                .copy, .preview, .actions => {},
            },
        }
    }

    /// True for the frame the window is seen with: one being presented
    /// during an entrance. A frame without a drawable is not on screen.
    pub fn framePresented(p: *Presence, presenting: bool) bool {
        if (p.phase != .entering or !presenting) return false;
        p.reveal();
        return true;
    }

    /// A panel left see-through would be worse than one old frame.
    pub fn entranceTimedOut(p: *Presence) void {
        p.timers_fired += 1;
        if (p.phase == .entering and p.timers_fired == p.entrances) p.reveal();
    }

    pub fn isHidden(p: *const Presence) bool {
        return p.phase == .hidden;
    }

    fn show(p: *Presence, on_board: bool) void {
        const from_hidden = p.phase == .hidden;
        if (from_hidden) p.run(.note_paste_target);
        p.run(if (on_board) .open_board else .open_search);
        p.run(.place);
        if (!from_hidden) return p.run(.order_front);
        p.phase = .entering;
        mac.signpostBegin(.summon);
        p.entrances += 1;
        p.run(.order_in_unseen);
        p.run(.start_entrance_timer);
    }

    fn reveal(p: *Presence) void {
        p.phase = .shown;
        mac.signpostEnd(.summon);
        p.run(.reveal);
    }

    fn hide(p: *Presence) void {
        if (p.phase == .entering) mac.signpostEnd(.summon);
        // First: ordering out resigns focus, and that must not hide again.
        p.phase = .hidden;
        p.run(.hide_window);
        p.run(.end_session);
    }

    fn run(p: *Presence, e: Effect) void {
        p.effects.run(p.effects.ctx, e);
    }
};
