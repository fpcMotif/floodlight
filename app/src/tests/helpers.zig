//! Shared fixtures and stubs for nanoui frontend tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const search = @import("../search.zig");
const panel_mod = @import("../panel.zig");
const permission = @import("../permission.zig");
const clipboard = @import("../clipboard.zig");
const board_mod = @import("../board.zig");
const chrome = @import("../chrome.zig");
const icons = @import("../icons.zig");
const t = std.testing;

pub const screen: permission.Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
pub const day = 86400;

pub const tmp_home_files = [_][]const u8{ "Documents/tax/2025-return.pdf", "Documents/notes.txt", "Music/kind-of-blue.flac" };

pub fn tmpCatalog(tmp: *std.testing.TmpDir) !search.Catalog {
    for (tmp_home_files) |p| {
        try tmp.dir.createDirPath(t.io, std.fs.path.dirname(p).?);
        try tmp.dir.writeFile(t.io, .{ .sub_path = p, .data = "" });
    }
    try tmp.dir.createDirPath(t.io, "Apps/Calculator.app/Contents");
    try tmp.dir.createDirPath(t.io, "Apps/Calendar.app/Contents");
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var cat: search.Catalog = .{ .gpa = t.allocator };
    errdefer cat.deinit();
    const apps = try std.fs.path.join(t.allocator, &.{ root, "Apps" });
    defer t.allocator.free(apps);
    try search.scanApps(&cat, t.io, apps);
    const idx = try std.fs.path.join(t.allocator, &.{ root, "names.flix" });
    defer t.allocator.free(idx);
    try cat.buildIndex(idx, root);
    return cat;
}

pub const WakeSignal = struct {
    sem: std.Io.Semaphore = .{ .permits = 0 },

    pub fn wake(ctx: ?*anyopaque) void {
        const w: *WakeSignal = @ptrCast(@alignCast(ctx));
        w.sem.post(t.io);
    }

    pub fn binding(w: *WakeSignal) search.Wake {
        return .{ .ctx = w, .wake = wake };
    }

    pub fn iconBinding(w: *WakeSignal) icons.Wake {
        return .{ .ctx = w, .wake = wake };
    }

    pub fn wait(w: *WakeSignal) void {
        w.sem.waitUncancelable(t.io);
    }
};

pub const FakeClock = struct {
    now: f64 = 0,
    step: f64 = 0,
    pub fn read(ctx: ?*anyopaque) f64 {
        const c: *FakeClock = @ptrCast(@alignCast(ctx));
        defer c.now += c.step;
        return c.now;
    }
    pub fn advance(c: *FakeClock, seconds: f64) void {
        c.now += seconds;
    }
    pub fn binding(c: *FakeClock) panel_mod.Clock {
        return .{ .ctx = c, .read = read };
    }
};

pub const StubHooks = struct {
    requests: u32 = 0,
    clock: FakeClock = .{},
    pub fn request(ctx: ?*anyopaque) void {
        const h: *StubHooks = @ptrCast(@alignCast(ctx));
        h.requests += 1;
    }
    pub fn icon(_: ?*anyopaque, _: []const u8, _: icons.Kind) ?icons.Image {
        return null;
    }
    /// Every date, whatever its seconds' type, as the same one.
    pub fn date(comptime Seconds: type) fn (?*anyopaque, Seconds, std.mem.Allocator) []const u8 {
        return struct {
            fn at(_: ?*anyopaque, _: Seconds, _: std.mem.Allocator) []const u8 {
                return "Today at 9:41 AM";
            }
        }.at;
    }
    pub fn hooks(h: *StubHooks) panel_mod.Hooks {
        return .{ .ctx = h, .clock = h.clock.binding(), .request = request, .app_icon = icon, .describe_date = date(i64), .detailed_date = date(f64) };
    }
};

pub fn countRows(rows: []const search.Row, kind: search.Kind) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.kind == kind);
    return n;
}

pub fn fillAlphaBehind(tester: *ui.Tester, label: []const u8) ?f32 {
    const nodes = tester.ctx.nodes.items;
    for (nodes) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
            var at = n.parent;
            while (at < nodes.len) : (at = nodes[at].parent) {
                if (nodes[at].style.background) |fill| return fill.a;
            }
        },
        else => {},
    };
    return null;
}

pub fn pointAt(tester: *ui.Tester, label: []const u8) !void {
    const at = tester.findText(label) orelse return error.TextNotDrawn;
    tester.moveTo(at.x + at.w / 2, at.y + at.h / 2);
}

pub fn addNumberedApps(cat: *search.Catalog, count: usize) !void {
    for (0..count) |i| {
        try cat.addApp(try std.fmt.allocPrint(t.allocator, "/Applications/App {d:0>2}.app", .{i}));
    }
}

pub fn picture(png: []const u8) clipboard.Capture {
    return .{ .image = .{ .name = "PNG Image", .png = png, .thumbnail = "thumb", .width = 10, .height = 10 } };
}

pub const valid_png: [73]u8 = blk: {
    var out: [73]u8 = undefined;
    @memcpy(out[0..8], "\x89PNG\r\n\x1a\n");
    const ihdr = "IHDR" ++ "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00";
    std.mem.writeInt(u32, out[8..12], 13, .big);
    @memcpy(out[12..29], ihdr);
    std.mem.writeInt(u32, out[29..33], std.hash.Crc32.hash(ihdr), .big);
    const raw = [_]u8{ 0, 255, 64, 32, 255 };
    var idat: [4 + 2 + 5 + raw.len + 4]u8 = undefined;
    @memcpy(idat[0..4], "IDAT");
    idat[4] = 0x78;
    idat[5] = 0x01;
    idat[6] = 0x01;
    std.mem.writeInt(u16, idat[7..9], raw.len, .little);
    std.mem.writeInt(u16, idat[9..11], ~@as(u16, raw.len), .little);
    @memcpy(idat[11..16], &raw);
    std.mem.writeInt(u32, idat[16..20], std.hash.Adler32.hash(&raw), .big);
    std.mem.writeInt(u32, out[33..37], idat.len - 4, .big);
    @memcpy(out[37..57], &idat);
    std.mem.writeInt(u32, out[57..61], std.hash.Crc32.hash(&idat), .big);
    std.mem.writeInt(u32, out[61..65], 0, .big);
    @memcpy(out[65..69], "IEND");
    std.mem.writeInt(u32, out[69..73], std.hash.Crc32.hash("IEND"), .big);
    break :blk out;
};

pub const TmpStore = struct {
    tmp: std.testing.TmpDir,
    images: []const u8,
    db: [:0]const u8,

    pub fn init() !TmpStore {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
        const images = try std.fs.path.join(t.allocator, &.{ root, "images" });
        errdefer t.allocator.free(images);
        const db = try std.fs.path.joinZ(t.allocator, &.{ root, "clipboard.sqlite3" });
        return .{ .tmp = tmp, .images = images, .db = db };
    }

    pub fn deinit(s: *TmpStore) void {
        t.allocator.free(s.images);
        t.allocator.free(s.db);
        s.tmp.cleanup();
    }

    pub fn size(s: *TmpStore, sub: []const u8) u64 {
        return (s.tmp.dir.statFile(t.io, sub, .{}) catch return 0).size;
    }
};

/// History in memory, its pictures in a folder `ts` owns, as on disk.
pub fn openMemory(ts: *const TmpStore) !clipboard.Store {
    return clipboard.Store.open(":memory:", ts.images);
}

/// The board over a history in memory and no apps or files. Fill `store`
/// between `init` and `show`; the fixture must not move after `init`.
pub const BoardFixture = struct {
    ts: TmpStore,
    store: clipboard.Store,
    cat: search.Catalog,
    hooks: StubHooks,
    p: panel_mod.Panel,
    tester: ui.Tester,
    shown: bool,

    pub fn init(f: *BoardFixture) !void {
        f.ts = try TmpStore.init();
        errdefer f.ts.deinit();
        f.store = try openMemory(&f.ts);
        f.cat = .{ .gpa = t.allocator };
        f.hooks = .{};
        f.p = .init(t.allocator, &f.cat, &f.store, f.hooks.hooks());
        f.shown = false;
    }

    /// Opens the board and draws it at its own size until it rests.
    pub fn show(f: *BoardFixture) !void {
        f.p.showClipboard();
        const m = board_mod.board_metrics;
        try f.tester.init(t.allocator, .init(&f.p, panel_mod.Panel.view), .{ .width = m.width, .height = m.height });
        f.shown = true;
        f.tester.settle(1);
    }

    /// `n` texts, "entry number 0" the oldest.
    pub fn seed(f: *BoardFixture, n: usize) !void {
        var buf: [32]u8 = undefined;
        for (0..n) |i| _ = try f.store.add(.{ .text = try std.fmt.bufPrint(&buf, "entry number {d}", .{i}) }, "x", "Notes", @floatFromInt(1000 + i));
    }

    pub fn deinit(f: *BoardFixture) void {
        if (f.shown) f.tester.deinit();
        f.p.deinit();
        f.cat.deinit();
        f.store.close();
        f.ts.deinit();
    }
};
