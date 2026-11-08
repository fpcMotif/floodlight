//! The File Index from open to swap: the one place that scans, writes, and
//! replaces the mapped index, so no frontend repeats that sequence.

const std = @import("std");
const index = @import("index.zig");
const scan_mod = @import("scan.zig");
const sys = @import("sys.zig");

/// The walk a rebuild runs. Tests substitute one that records and interleaves.
pub const Scanner = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, b: *index.Builder, root: []const u8) anyerror!void = scanRoot,
};

fn scanRoot(_: ?*anyopaque, b: *index.Builder, root: []const u8) anyerror!void {
    return scan_mod.scan(b, root, .{});
}

pub const Outcome = union(enum) { built: u32, failed: anyerror };

/// Called on the rebuilding thread after each scan, once `busy` already
/// reflects whether another scan follows.
pub const Notify = struct {
    ctx: ?*anyopaque = null,
    ready: *const fn (ctx: ?*anyopaque, outcome: Outcome) void,
};

/// Scans `root` and writes the index to `path`; returns the entry count.
pub fn writeIndex(gpa: std.mem.Allocator, scanner: Scanner, root: []const u8, path: []const u8) !u32 {
    var b = index.Builder.init(gpa);
    defer b.deinit();
    try scanner.run(scanner.ctx, &b, root);
    try b.writeFile(sys.cwd, path);
    return b.count();
}

pub const FileIndex = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    root: []const u8,
    scanner: Scanner,
    current: ?index.Mapped = null,
    ready: std.atomic.Value(?*index.Mapped) = .init(null),
    running: std.atomic.Value(bool) = .init(false),
    requested: std.atomic.Value(u32) = .init(0),

    /// Maps the last good index at `path` if one is there, and starts empty
    /// otherwise. Removes temp files a crashed build left beside it.
    pub fn open(gpa: std.mem.Allocator, path: []const u8, root: []const u8, scanner: Scanner) !FileIndex {
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const owned_root = try gpa.dupe(u8, root);
        removeStaleTemps(gpa, path);
        return .{
            .gpa = gpa,
            .path = owned_path,
            .root = owned_root,
            .scanner = scanner,
            .current = index.Mapped.open(sys.cwd, path) catch null,
        };
    }

    pub fn close(fi: *FileIndex) void {
        if (fi.current) |*m| m.close();
        if (fi.ready.swap(null, .acq_rel)) |m| {
            m.close();
            fi.gpa.destroy(m);
        }
        fi.gpa.free(fi.path);
        fi.gpa.free(fi.root);
        fi.* = undefined;
    }

    /// The current index; query thread only, like `adopt`.
    pub fn view(fi: *const FileIndex) ?index.View {
        return if (fi.current) |m| m.view else null;
    }

    /// True while a scan runs or one is queued. Safe from any thread.
    pub fn busy(fi: *const FileIndex) bool {
        return fi.running.load(.seq_cst) or fi.requested.load(.seq_cst) > 0;
    }

    /// Swaps in the newest finished index and unmaps the old one; true when
    /// the index changed. Call it on the thread that runs queries.
    pub fn adopt(fi: *FileIndex) bool {
        const next = fi.ready.swap(null, .acq_rel) orelse return false;
        if (fi.current) |*m| m.close();
        fi.current = next.*;
        fi.gpa.destroy(next);
        return true;
    }

    /// Blocks the calling thread for a scan that begins after this call.
    /// When a scan is already running, it returns at once and the running
    /// caller scans once more, so a burst of requests costs one extra scan.
    pub fn rebuild(fi: *FileIndex, notify: Notify) void {
        _ = fi.requested.fetchAdd(1, .seq_cst);
        while (fi.running.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
            _ = fi.requested.swap(0, .seq_cst);
            const outcome = fi.buildOnce();
            fi.running.store(false, .seq_cst);
            notify.ready(notify.ctx, outcome);
            if (fi.requested.load(.seq_cst) == 0) return;
        }
    }

    fn buildOnce(fi: *FileIndex) Outcome {
        const mapped = fi.gpa.create(index.Mapped) catch |e| return .{ .failed = e };
        mapped.* = fi.buildAndOpen() catch |e| {
            fi.gpa.destroy(mapped);
            return .{ .failed = e };
        };
        const count = mapped.view.count();
        if (fi.ready.swap(mapped, .acq_rel)) |stale| {
            stale.close();
            fi.gpa.destroy(stale);
        }
        return .{ .built = count };
    }

    fn buildAndOpen(fi: *FileIndex) !index.Mapped {
        _ = try writeIndex(fi.gpa, fi.scanner, fi.root, fi.path);
        return index.Mapped.open(sys.cwd, fi.path);
    }
};

fn removeStaleTemps(gpa: std.mem.Allocator, path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var listing = index.Builder.init(gpa);
    defer listing.deinit();
    scan_mod.scan(&listing, dir, .{ .skip_hidden = false, .max_depth = 1 }) catch return;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    for (0..listing.count()) |i| {
        const name = listing.name(@intCast(i));
        if (!isTempOf(name, base)) continue;
        const stale = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        sys.unlinkat(sys.cwd, stale);
    }
}

fn isTempOf(name: []const u8, base: []const u8) bool {
    return name.len > base.len and std.mem.startsWith(u8, name, base) and
        name[base.len] == '.' and std.mem.endsWith(u8, name, ".tmp");
}

const t = std.testing;

const Probe = struct {
    fi: *FileIndex = undefined,
    scans: u32 = 0,
    requests_during_first_scan: u32 = 0,
    fail_on_scan: ?u32 = null,
    busy_while_scanning: bool = true,
    outcomes: std.ArrayList(Outcome) = .empty,
    busy_at_notify: std.ArrayList(bool) = .empty,

    fn scanner(p: *Probe) Scanner {
        return .{ .ctx = p, .run = run };
    }

    fn notify(p: *Probe) Notify {
        return .{ .ctx = p, .ready = ready };
    }

    fn run(ctx: ?*anyopaque, b: *index.Builder, root: []const u8) anyerror!void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.scans += 1;
        p.busy_while_scanning = p.busy_while_scanning and p.fi.busy();
        if (p.fail_on_scan == p.scans) return error.AccessDenied;
        if (p.scans == 1) {
            for (0..p.requests_during_first_scan) |_| p.fi.rebuild(p.notify());
        }
        try b.setRoot(root);
        var name_buf: [16]u8 = undefined;
        _ = try b.add(index.no_parent, try std.fmt.bufPrint(&name_buf, "scan-{d}", .{p.scans}), .{});
    }

    fn ready(ctx: ?*anyopaque, outcome: Outcome) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.outcomes.append(t.allocator, outcome) catch unreachable;
        p.busy_at_notify.append(t.allocator, p.fi.busy()) catch unreachable;
    }

    fn deinit(p: *Probe) void {
        p.outcomes.deinit(t.allocator);
        p.busy_at_notify.deinit(t.allocator);
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.posix.PATH_MAX]u8 = undefined,
    path_buf: [std.posix.PATH_MAX]u8 = undefined,
    root: []const u8 = "",
    path: []const u8 = "",

    fn init(f: *Fixture) !void {
        f.tmp = t.tmpDir(.{});
        f.root = f.root_buf[0..try f.tmp.dir.realPath(t.io, &f.root_buf)];
        f.path = try std.fmt.bufPrint(&f.path_buf, "{s}/names.flix", .{f.root});
    }

    fn exists(f: *Fixture, name: []const u8) bool {
        f.tmp.dir.access(t.io, name, .{}) catch return false;
        return true;
    }

    fn firstName(fi: *const FileIndex) []const u8 {
        const v = fi.view().?;
        return v.name(0);
    }
};

test "a rebuild asked for during a scan runs one follow-up scan" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var probe: Probe = .{ .requests_during_first_scan = 2 };
    defer probe.deinit();
    var fi = try FileIndex.open(t.allocator, f.path, f.root, probe.scanner());
    defer fi.close();
    probe.fi = &fi;

    fi.rebuild(probe.notify());

    try t.expectEqual(@as(u32, 2), probe.scans);
    try t.expectEqual(@as(usize, 2), probe.outcomes.items.len);
    try t.expect(fi.adopt());
    try t.expectEqualStrings("scan-2", Fixture.firstName(&fi));
    try t.expect(!fi.adopt());
}

test "rebuilds from many threads at once leave one valid index" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    try f.tmp.dir.createDirPath(t.io, "Music/Albums");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "Music/Albums/kind-of-blue.flac", .data = "" });
    var fi = try FileIndex.open(t.allocator, f.path, f.root, .{});
    defer fi.close();

    const Tally = struct {
        failures: std.atomic.Value(u32) = .init(0),
        fn ready(ctx: ?*anyopaque, outcome: Outcome) void {
            const tally: *@This() = @ptrCast(@alignCast(ctx));
            if (outcome == .failed) _ = tally.failures.fetchAdd(1, .monotonic);
        }
    };
    var tally: Tally = .{};
    var threads: [8]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, FileIndex.rebuild, .{ &fi, Notify{ .ctx = &tally, .ready = Tally.ready } });
    for (threads) |th| th.join();

    try t.expectEqual(@as(u32, 0), tally.failures.load(.monotonic));
    try t.expect(!fi.busy());
    try t.expect(fi.adopt());
    try t.expectEqual(@as(u32, 4), fi.view().?.count());
}

test "busy holds from the request until the last scan lands" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var probe: Probe = .{ .requests_during_first_scan = 1 };
    defer probe.deinit();
    var fi = try FileIndex.open(t.allocator, f.path, f.root, probe.scanner());
    defer fi.close();
    probe.fi = &fi;

    try t.expect(!fi.busy());
    fi.rebuild(probe.notify());

    try t.expect(probe.busy_while_scanning);
    try t.expectEqualSlices(bool, &.{ true, false }, probe.busy_at_notify.items);
    try t.expect(!fi.busy());
}

test "a failed scan keeps the last good index" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var probe: Probe = .{ .fail_on_scan = 2 };
    defer probe.deinit();
    var fi = try FileIndex.open(t.allocator, f.path, f.root, probe.scanner());
    defer fi.close();
    probe.fi = &fi;

    fi.rebuild(probe.notify());
    try t.expect(fi.adopt());
    fi.rebuild(probe.notify());

    try t.expectEqual(error.AccessDenied, probe.outcomes.items[1].failed);
    try t.expect(!fi.adopt());
    try t.expectEqualStrings("scan-1", Fixture.firstName(&fi));
    try t.expect(!fi.busy());
}

test "opens the last good index before any rebuild" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var probe: Probe = .{};
    defer probe.deinit();
    {
        var first = try FileIndex.open(t.allocator, f.path, f.root, probe.scanner());
        defer first.close();
        probe.fi = &first;
        first.rebuild(probe.notify());
    }
    var fi = try FileIndex.open(t.allocator, f.path, f.root, probe.scanner());
    defer fi.close();
    try t.expectEqualStrings("scan-1", Fixture.firstName(&fi));
}

test "opens empty over a missing or corrupt index" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var missing = try FileIndex.open(t.allocator, f.path, f.root, .{});
    defer missing.close();
    try t.expect(missing.view() == null);

    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "names.flix", .data = "FLIX" ++ @as([200]u8, @splat(0)) });
    var corrupt = try FileIndex.open(t.allocator, f.path, f.root, .{});
    defer corrupt.close();
    try t.expect(corrupt.view() == null);
}

test "open removes the temp files a crashed build left" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "names.flix.tmp", .data = "" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "names.flix.4242.7.tmp", .data = "" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "other.tmp", .data = "" });

    var fi = try FileIndex.open(t.allocator, f.path, f.root, .{});
    defer fi.close();

    try t.expect(!f.exists("names.flix.tmp"));
    try t.expect(!f.exists("names.flix.4242.7.tmp"));
    try t.expect(f.exists("other.tmp"));
}
