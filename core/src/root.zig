pub const mask = @import("mask.zig");
pub const match = @import("match.zig");
pub const index = @import("index.zig");
pub const file_index = @import("file_index.zig");
pub const scan = @import("scan.zig");
pub const search = @import("search.zig");
pub const c_api = @import("c_api.zig");
pub const sys = @import("sys.zig");

// Zig analyses lazily: without this reference the `export fn`s are never
// compiled and the static library ships with no symbols.
comptime {
    _ = c_api;
}

test {
    @import("std").testing.refAllDecls(@This());
}
