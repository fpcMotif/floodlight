//! Nanospot on nanoui without a window: the grant flow, the search panel
//! and the list behind it, the clipboard store and board, AVIF compaction,
//! and when the panel shows and hides. Views render offscreen through
//! ui.Tester.
comptime {
    _ = @import("search.zig");
    _ = @import("tests/permission_test.zig");
    _ = @import("tests/panel_test.zig");
    _ = @import("tests/list_test.zig");
    _ = @import("tests/clipboard_test.zig");
    _ = @import("tests/board_test.zig");
    _ = @import("tests/state_machines_test.zig");
    _ = @import("tests/shell_test.zig");
    _ = @import("stage_clock.zig");
    _ = @import("latency_probe.zig");
}
