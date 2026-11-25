//! Memory probe CLI flags (`--nanospot-memory-session` and `--nanospot-memory-seed`).
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const mac = @import("mac.zig");

pub const session_flag = "--nanospot-memory-session";
pub const seed_flag = "--nanospot-memory-seed";

const cycles = 3;
const step_ms = 400;
const settle_ms = 1500;
const steps = 7;
const board_moves = 20;

pub fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

fn markMemory(phase: []const u8, cycle: u32) void {
    std.debug.print("NANOSPOT_MEMORY phase={s} cycle={d}\n", .{ phase, cycle });
}

pub fn Runner(comptime Shell: type) type {
    return struct {
        pub fn launched(ctx: ?*anyopaque) callconv(.c) void {
            markMemory("launched", 0);
            nanoui.App.after(settle_ms, ctx, stepFn);
        }

        fn stepFn(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            const cycle = s.memory_step / steps + 1;
            const step = s.memory_step % steps;
            s.memory_step += 1;
            switch (step) {
                0 => s.apply(s.shell.hotKey(.search, false)),
                1 => {
                    s.shell.panel.field.set("cal");
                    s.shell.panel.refresh();
                },
                2 => s.apply(s.shell.hotKey(.clipboard, false)),
                3 => {
                    s.shell.panel.field.set("meeting");
                    s.shell.panel.refresh();
                },
                4 => for (0..board_moves) |_| s.shell.panel.board.list.move(true),
                5 => {
                    markMemory("open", cycle);
                    return nanoui.App.after(settle_ms, s, stepFn);
                },
                else => {
                    s.apply(s.shell.settle(.hide));
                    return nanoui.App.after(settle_ms, s, idle);
                },
            }
            s.panel_window.redraw();
            nanoui.App.after(step_ms, s, stepFn);
        }

        fn idle(ctx: ?*anyopaque) callconv(.c) void {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            const cycle = s.memory_step / steps;
            markMemory("idle", cycle);
            if (cycle < cycles) nanoui.App.after(settle_ms, s, stepFn);
        }
    };
}

pub fn seedMemoryHistory(gpa: std.mem.Allocator, store: clipboard.Store) void {
    const texts = [_][]const u8{
        "Meeting moved to 3pm, room 4B. Bring the Q3 numbers and the draft plan.",
        "https://developer.apple.com/documentation/metal/mtldevice",
        "const index = try FileIndex.open(gpa, path, home, .{});",
        "#3478f6",
        "/Users/shared/Projects/nanospot/README.md",
    };
    const pictures = [_][]const u8{ "/System/Applications/Calendar.app", "/System/Applications/Notes.app", "/System/Applications/Maps.app", "/System/Applications/Photos.app" };
    const now = clipboard.wallClock();
    const text_count = 5000;
    const long_text_every = 50;
    const long_text_bytes = 30_000;
    const picture_repeats = 50;
    const sentence = "The quarterly review covers roadmap, hiring, and the migration plan. ";
    const long_buf = gpa.alloc(u8, long_text_bytes) catch return;
    defer gpa.free(long_buf);
    for (long_buf, 0..) |*c, i| c.* = sentence[i % sentence.len];
    var buf: [160]u8 = undefined;
    for (0..text_count) |i| {
        const age = now - @as(f64, @floatFromInt(text_count - i)) * 72;
        if (i % long_text_every == 0) {
            _ = store.add(.{ .text = long_buf }, "com.apple.Safari", "Safari", age) catch {};
            continue;
        }
        const text = std.fmt.bufPrint(&buf, "{s} ({d})", .{ texts[i % texts.len], i }) catch continue;
        _ = store.add(.{ .text = text }, "com.apple.Safari", "Safari", age) catch {};
    }
    var pngs: [pictures.len][]u8 = undefined;
    var thumbnails: [pictures.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (0..loaded) |i| {
        gpa.free(pngs[i]);
        gpa.free(thumbnails[i]);
    };
    for (pictures) |path| {
        const png = mac.iconPng(gpa, path, 1024) orelse continue;
        const thumbnail = mac.iconPng(gpa, path, 128) orelse {
            gpa.free(png);
            continue;
        };
        pngs[loaded] = png;
        thumbnails[loaded] = thumbnail;
        loaded += 1;
    }
    if (loaded == 0) return;
    var name: [32]u8 = undefined;
    for (0..loaded * picture_repeats) |j| {
        const k = j % loaded;
        const label = std.fmt.bufPrint(&name, "Screenshot {d}", .{j}) catch continue;
        const image: clipboard.Capture.Image = .{ .name = label, .png = pngs[k], .thumbnail = thumbnails[k], .width = 1024, .height = 1024 };
        _ = store.add(.{ .image = image }, "com.apple.screencaptureui", "Screenshot", now - @as(f64, @floatFromInt(loaded * picture_repeats - j))) catch {};
    }
}
