const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mac = @import("mac.zig");

pub const max_icons: usize = 64;
pub const max_kept_thumbnails: usize = 16;
const max_transient_images: usize = 32;
const max_transient_bytes: usize = 8 * 1024 * 1024;
const max_seen: usize = max_icons * 4;
const max_batch: usize = 16;

extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const qos_class_user_initiated: c_uint = 0x19;

pub const Kind = enum { app, file, folder, unknown };

pub const Image = struct {
    key: []const u8,
    pixels: ui.ImageSource.Pixels,
};

pub const FetchFn = *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, px: f64) ?mac.Icon;
pub const DecodeFn = *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, bytes: []const u8, max_w: u32, max_h: u32) ?mac.Icon;

pub const Wake = struct {
    ctx: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) void = noWake,
};

fn noWake(_: ?*anyopaque) void {}

fn noFetch(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: f64) ?mac.Icon {
    return null;
}

fn noDecode(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: u32) ?mac.Icon {
    return null;
}

pub fn keyFor(buf: []u8, path: []const u8, kind: Kind) ?[]const u8 {
    if (path.len == 0) return null;
    const stripped = std.mem.trimEnd(u8, path, "/");
    const trimmed = if (stripped.len > 0) stripped else "/";
    const raw = std.fs.path.extension(trimmed);
    const ext = if (raw.len > 1) raw[1..] else "";
    if (kind == .app or std.ascii.eqlIgnoreCase(ext, "app")) {
        return std.fmt.bufPrint(buf, "app:{s}", .{trimmed}) catch null;
    }
    if (kind == .folder) return "folder";
    if (kind == .file) {
        if (4 + ext.len > buf.len) return null;
        @memcpy(buf[0..4], "ext:");
        for (ext, 0..) |ch, i| buf[4 + i] = std.ascii.toLower(ch);
        return buf[0 .. 4 + ext.len];
    }
    return std.fmt.bufPrint(buf, "path:{s}", .{trimmed}) catch null;
}

pub const Cache = struct {
    const SeenState = enum { queued, failed };
    const Bucket = enum { icon, kept_image, transient_image };

    const Payload = union(enum) {
        path: []u8,
        encoded: struct {
            bytes: []u8,
            max_w: u32,
            max_h: u32,
        },

        fn deinit(p: Payload, gpa: std.mem.Allocator) void {
            switch (p) {
                .path => |s| gpa.free(s),
                .encoded => |e| gpa.free(e.bytes),
            }
        }
    };

    const Job = struct {
        bucket: Bucket,
        seq: u64,
        key: []u8,
        payload: Payload,
    };

    const Result = struct {
        bucket: Bucket,
        seq: u64,
        key: []u8,
        icon: ?mac.Icon,
    };

    gpa: std.mem.Allocator,
    icon_px: f64,
    entries: std.StringHashMapUnmanaged(mac.Icon) = .empty,
    seen: std.StringHashMapUnmanaged(SeenState) = .empty,
    kept_images: std.StringHashMapUnmanaged(mac.Icon) = .empty,
    kept_seen: std.StringHashMapUnmanaged(SeenState) = .empty,
    transient_images: std.StringArrayHashMapUnmanaged(mac.Icon) = .empty,
    transient_seen: std.StringHashMapUnmanaged(SeenState) = .empty,
    transient_bytes: usize = 0,
    in_flight: usize = 0,
    kept_in_flight: usize = 0,
    transient_in_flight: usize = 0,
    session_seq: u64 = 1,
    worker_started: bool = false,

    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopped: bool = false,
    active_seq: u64 = 1,
    pending_jobs: std.ArrayList(Job) = .empty,
    pending_head: usize = 0,
    ready: std.ArrayList(Result) = .empty,
    wake_scheduled: bool = false,
    fetch_ctx: ?*anyopaque = null,
    fetch_fn: FetchFn = noFetch,
    decode_ctx: ?*anyopaque = null,
    decode_fn: DecodeFn = noDecode,
    wake: Wake = .{},

    pub fn init(gpa: std.mem.Allocator, icon_px: f64) Cache {
        return .{ .gpa = gpa, .icon_px = icon_px };
    }

    pub fn deinit(c: *Cache) void {
        c.stopWorker();
        c.freeAllQueued();
        c.pending_jobs.deinit(c.gpa);
        c.ready.deinit(c.gpa);
        c.freeMap(&c.entries);
        c.entries.deinit(c.gpa);
        c.freeSeenMap(&c.seen);
        c.seen.deinit(c.gpa);
        c.freeMap(&c.kept_images);
        c.kept_images.deinit(c.gpa);
        c.freeSeenMap(&c.kept_seen);
        c.kept_seen.deinit(c.gpa);
        c.freeTransient();
        c.transient_images.deinit(c.gpa);
        c.freeSeenMap(&c.transient_seen);
        c.transient_seen.deinit(c.gpa);
        c.* = undefined;
    }

    pub fn setDecoder(c: *Cache, decode_ctx: ?*anyopaque, decode_fn: DecodeFn) void {
        c.decode_ctx = decode_ctx;
        c.decode_fn = decode_fn;
    }

    pub fn startWorker(c: *Cache, io: std.Io, fetch_ctx: ?*anyopaque, fetch_fn: FetchFn, wake: Wake) void {
        if (c.worker_started) return;
        c.io = io;
        c.fetch_ctx = fetch_ctx;
        c.fetch_fn = fetch_fn;
        c.wake = wake;
        c.stopped = false;
        c.active_seq = c.session_seq;
        c.thread = std.Thread.spawn(.{}, run, .{c}) catch |err| {
            if (!@import("builtin").is_test) std.log.err("icons: no worker thread: {s}", .{@errorName(err)});
            return;
        };
        c.worker_started = true;
    }

    pub fn stopWorker(c: *Cache) void {
        const th = c.thread orelse return;
        c.mutex.lockUncancelable(c.io);
        c.stopped = true;
        c.cond.signal(c.io);
        c.mutex.unlock(c.io);
        th.join();
        c.thread = null;
        c.worker_started = false;
    }

    pub fn count(c: *const Cache) usize {
        return c.entries.count();
    }

    pub fn keptCount(c: *const Cache) usize {
        return c.kept_images.count();
    }

    pub fn keptBytes(c: *const Cache) usize {
        var total: usize = 0;
        var it = c.kept_images.valueIterator();
        while (it.next()) |ic| total += ic.bgra.len;
        return total;
    }

    pub fn hasPending(c: *const Cache) bool {
        return c.in_flight + c.kept_in_flight + c.transient_in_flight > 0;
    }

    pub fn lookupOrEnqueue(c: *Cache, path: []const u8, kind: Kind) ?Image {
        var key_buf: [4096]u8 = undefined;
        const key = keyFor(&key_buf, path, kind) orelse return null;
        if (c.entries.getEntry(key)) |e| return .{ .key = e.key_ptr.*, .pixels = e.value_ptr.pixels() };
        c.enqueueKey(key, path);
        return null;
    }

    pub fn prefetch(c: *Cache, path: []const u8, kind: Kind) void {
        _ = c.lookupOrEnqueue(path, kind);
    }

    pub fn lookupImage(c: *const Cache, key: []const u8) ?Image {
        if (c.kept_images.getEntry(key)) |e| return .{ .key = e.key_ptr.*, .pixels = e.value_ptr.pixels() };
        if (c.transient_images.getEntry(key)) |e| return .{ .key = e.key_ptr.*, .pixels = e.value_ptr.pixels() };
        return null;
    }

    pub fn decodeOrEnqueue(c: *Cache, key: []const u8, bytes: []const u8, max_w: u32, max_h: u32, keep_across_hide: bool) ?Image {
        if (c.lookupImage(key)) |img| return img;
        if (!c.worker_started or bytes.len == 0 or key.len == 0) return null;
        if (c.kept_seen.contains(key) or c.transient_seen.contains(key)) return null;
        if (keep_across_hide and c.kept_images.count() + c.kept_in_flight < max_kept_thumbnails) {
            c.enqueueImage(.kept_image, &c.kept_seen, &c.kept_in_flight, 0, key, bytes, max_w, max_h);
        } else {
            c.enqueueImage(.transient_image, &c.transient_seen, &c.transient_in_flight, c.session_seq, key, bytes, max_w, max_h);
        }
        return null;
    }

    pub fn retainFirstPage(c: *Cache, live_keys: []const []const u8) void {
        for (live_keys) |k| {
            if (c.kept_images.contains(k) or c.kept_images.count() >= max_kept_thumbnails) continue;
            if (c.transient_images.fetchOrderedRemove(k)) |kv| {
                c.transient_bytes -|= kv.value.bgra.len;
                c.kept_images.put(c.gpa, kv.key, kv.value) catch {
                    c.gpa.free(kv.key);
                    kv.value.deinit(c.gpa);
                };
            }
        }
        var dead_keys: [max_kept_thumbnails][]const u8 = undefined;
        var dead_n: usize = 0;
        var it = c.kept_images.keyIterator();
        while (it.next()) |k| {
            if (!containsSlice(live_keys, k.*) and dead_n < dead_keys.len) {
                dead_keys[dead_n] = k.*;
                dead_n += 1;
            }
        }
        for (dead_keys[0..dead_n]) |k| {
            if (c.kept_images.fetchRemove(k)) |old| {
                c.gpa.free(old.key);
                old.value.deinit(c.gpa);
            }
        }
        var dead_seen: std.ArrayList([]const u8) = .empty;
        defer dead_seen.deinit(c.gpa);
        var sit = c.kept_seen.keyIterator();
        while (sit.next()) |k| {
            if (!containsSlice(live_keys, k.*)) dead_seen.append(c.gpa, k.*) catch {};
        }
        for (dead_seen.items) |k| {
            if (c.kept_seen.fetchRemove(k)) |old| c.gpa.free(old.key);
        }
    }

    fn enqueueImage(
        c: *Cache,
        bucket: Bucket,
        seen_map: *std.StringHashMapUnmanaged(SeenState),
        counter: *usize,
        seq: u64,
        key: []const u8,
        bytes: []const u8,
        max_w: u32,
        max_h: u32,
    ) void {
        if (bucket == .transient_image and counter.* >= max_transient_images) return;
        const job_bytes = c.gpa.dupe(u8, bytes) catch return;
        if (!c.enqueuePayload(bucket, seen_map, counter, seq, key, .{ .encoded = .{ .bytes = job_bytes, .max_w = max_w, .max_h = max_h } })) {
            c.gpa.free(job_bytes);
        }
    }

    fn enqueueKey(c: *Cache, key: []const u8, path: []const u8) void {
        if (!c.worker_started) return;
        if (c.entries.count() + c.in_flight >= max_icons) return;
        const job_path = c.gpa.dupe(u8, path) catch return;
        if (!c.enqueuePayload(.icon, &c.seen, &c.in_flight, c.session_seq, key, .{ .path = job_path })) {
            c.gpa.free(job_path);
        }
    }

    fn enqueuePayload(
        c: *Cache,
        bucket: Bucket,
        seen_map: *std.StringHashMapUnmanaged(SeenState),
        counter: *usize,
        seq: u64,
        key: []const u8,
        payload: Payload,
    ) bool {
        if (seen_map.contains(key)) return false;
        if (seen_map.count() >= max_seen) return false;
        const seen_key = c.gpa.dupe(u8, key) catch return false;
        const job_key = c.gpa.dupe(u8, key) catch {
            c.gpa.free(seen_key);
            return false;
        };
        seen_map.put(c.gpa, seen_key, .queued) catch {
            c.gpa.free(job_key);
            c.gpa.free(seen_key);
            return false;
        };
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.pending_jobs.append(c.gpa, .{
                .bucket = bucket,
                .seq = seq,
                .key = job_key,
                .payload = payload,
            }) catch {
                if (seen_map.fetchRemove(key)) |old| c.gpa.free(old.key);
                c.gpa.free(job_key);
                return false;
            };
            c.cond.signal(c.io);
        }
        counter.* += 1;
        return true;
    }

    pub fn poll(c: *Cache) bool {
        if (!c.worker_started) return false;
        var batch: std.ArrayList(Result) = .empty;
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            batch = c.ready;
            c.ready = .empty;
            c.wake_scheduled = false;
        }
        defer batch.deinit(c.gpa);

        var changed = false;
        for (batch.items) |res| {
            switch (res.bucket) {
                .icon => {
                    if (res.seq != c.session_seq) {
                        c.gpa.free(res.key);
                        if (res.icon) |ic| ic.deinit(c.gpa);
                        continue;
                    }
                    c.in_flight -|= 1;
                    if (res.icon) |ic| {
                        if (c.entries.count() < max_icons and !c.entries.contains(res.key)) {
                            if (c.entries.put(c.gpa, res.key, ic)) |_| {
                                if (c.seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                                changed = true;
                                continue;
                            } else |_| {}
                        }
                        if (c.seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                        c.gpa.free(res.key);
                        ic.deinit(c.gpa);
                        continue;
                    }
                    if (c.seen.getPtr(res.key)) |st| st.* = .failed;
                    c.gpa.free(res.key);
                },
                .kept_image => {
                    c.kept_in_flight -|= 1;
                    if (!c.kept_seen.contains(res.key)) {
                        c.gpa.free(res.key);
                        if (res.icon) |ic| ic.deinit(c.gpa);
                        continue;
                    }
                    if (res.icon) |ic| {
                        if (c.kept_images.count() < max_kept_thumbnails and !c.kept_images.contains(res.key)) {
                            if (c.kept_images.put(c.gpa, res.key, ic)) |_| {
                                if (c.kept_seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                                changed = true;
                                continue;
                            } else |_| {}
                        }
                        if (c.kept_seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                        c.gpa.free(res.key);
                        ic.deinit(c.gpa);
                        continue;
                    }
                    if (c.kept_seen.getPtr(res.key)) |st| st.* = .failed;
                    c.gpa.free(res.key);
                },
                .transient_image => {
                    if (res.seq != c.session_seq) {
                        c.gpa.free(res.key);
                        if (res.icon) |ic| ic.deinit(c.gpa);
                        continue;
                    }
                    c.transient_in_flight -|= 1;
                    if (res.icon) |ic| {
                        if (!c.transient_images.contains(res.key) and ic.bgra.len <= max_transient_bytes) {
                            while (c.transient_images.count() >= max_transient_images or
                                (c.transient_bytes + ic.bgra.len > max_transient_bytes and c.transient_images.count() > 0))
                            {
                                const old_key = c.transient_images.keys()[0];
                                const old_val = c.transient_images.values()[0];
                                c.transient_bytes -|= old_val.bgra.len;
                                c.transient_images.orderedRemoveAt(0);
                                c.gpa.free(old_key);
                                old_val.deinit(c.gpa);
                            }
                            if (c.transient_images.put(c.gpa, res.key, ic)) |_| {
                                c.transient_bytes += ic.bgra.len;
                                if (c.transient_seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                                changed = true;
                                continue;
                            } else |_| {}
                        }
                        if (c.transient_seen.fetchRemove(res.key)) |old| c.gpa.free(old.key);
                        c.gpa.free(res.key);
                        ic.deinit(c.gpa);
                        continue;
                    }
                    if (c.transient_seen.getPtr(res.key)) |st| st.* = .failed;
                    c.gpa.free(res.key);
                },
            }
        }
        return changed;
    }

    pub fn clear(c: *Cache) void {
        c.session_seq += 1;
        c.in_flight = 0;
        c.transient_in_flight = 0;
        var should_wake = false;
        var wake: Wake = .{};
        if (c.worker_started) {
            c.mutex.lockUncancelable(c.io);
            c.active_seq = c.session_seq;
            c.pruneSessionQueuedLocked();
            if (c.ready.items.len > 0 and !c.hasCurrentJobLocked() and !c.wake_scheduled) {
                c.wake_scheduled = true;
                should_wake = true;
                wake = c.wake;
            }
            c.mutex.unlock(c.io);
        }
        c.freeMap(&c.entries);
        c.entries.clearRetainingCapacity();
        c.freeSeenMap(&c.seen);
        c.seen.clearRetainingCapacity();
        c.freeTransient();
        c.transient_images.clearRetainingCapacity();
        c.freeSeenMap(&c.transient_seen);
        c.transient_seen.clearRetainingCapacity();
        if (should_wake) wake.wake(wake.ctx);
    }

    fn freeAllQueued(c: *Cache) void {
        for (c.pending_jobs.items[c.pending_head..]) |job| {
            c.gpa.free(job.key);
            job.payload.deinit(c.gpa);
        }
        c.pending_head = 0;
        c.pending_jobs.clearRetainingCapacity();
        for (c.ready.items) |res| {
            c.gpa.free(res.key);
            if (res.icon) |ic| ic.deinit(c.gpa);
        }
        c.ready.clearRetainingCapacity();
    }

    fn pruneSessionQueuedLocked(c: *Cache) void {
        var write_job: usize = 0;
        for (c.pending_jobs.items[c.pending_head..]) |job| {
            if (job.bucket == .kept_image) {
                c.pending_jobs.items[write_job] = job;
                write_job += 1;
            } else {
                c.gpa.free(job.key);
                job.payload.deinit(c.gpa);
            }
        }
        c.pending_head = 0;
        c.pending_jobs.items.len = write_job;

        var write_res: usize = 0;
        for (c.ready.items) |res| {
            if (res.bucket == .kept_image) {
                c.ready.items[write_res] = res;
                write_res += 1;
            } else {
                c.gpa.free(res.key);
                if (res.icon) |ic| ic.deinit(c.gpa);
            }
        }
        c.ready.items.len = write_res;
        if (write_res == 0) c.wake_scheduled = false;
    }

    fn freeMap(c: *Cache, map: *std.StringHashMapUnmanaged(mac.Icon)) void {
        var it = map.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(c.gpa);
        }
    }

    fn freeTransient(c: *Cache) void {
        for (c.transient_images.keys(), c.transient_images.values()) |k, v| {
            c.gpa.free(k);
            v.deinit(c.gpa);
        }
        c.transient_bytes = 0;
    }

    fn freeSeenMap(c: *Cache, map: *std.StringHashMapUnmanaged(SeenState)) void {
        var it = map.keyIterator();
        while (it.next()) |k| c.gpa.free(k.*);
    }

    fn isJobLive(c: *const Cache, bucket: Bucket, seq: u64) bool {
        return switch (bucket) {
            .kept_image => true,
            .icon, .transient_image => seq == c.active_seq,
        };
    }

    fn hasCurrentJobLocked(c: *const Cache) bool {
        for (c.pending_jobs.items[c.pending_head..]) |job| {
            if (c.isJobLive(job.bucket, job.seq)) return true;
        }
        return false;
    }

    fn run(c: *Cache) void {
        _ = pthread_set_qos_class_self_np(qos_class_user_initiated, 0);
        while (true) {
            var job: Job = undefined;
            {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                while (!c.stopped and c.pending_head >= c.pending_jobs.items.len) {
                    c.cond.waitUncancelable(c.io, &c.mutex);
                }
                if (c.stopped) return;
                job = c.pending_jobs.items[c.pending_head];
                c.pending_head += 1;
                if (c.pending_head == c.pending_jobs.items.len) {
                    c.pending_head = 0;
                    c.pending_jobs.clearRetainingCapacity();
                }
                if (!c.isJobLive(job.bucket, job.seq)) {
                    c.gpa.free(job.key);
                    job.payload.deinit(c.gpa);
                    continue;
                }
            }
            const icon = switch (job.payload) {
                .path => |p| c.fetch_fn(c.fetch_ctx, c.gpa, p, c.icon_px),
                .encoded => |e| c.decode_fn(c.decode_ctx, c.gpa, e.bytes, e.max_w, e.max_h),
            };
            job.payload.deinit(c.gpa);
            var should_wake = false;
            var wake: Wake = .{};
            {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                if (c.stopped or !c.isJobLive(job.bucket, job.seq)) {
                    c.gpa.free(job.key);
                    if (icon) |ic| ic.deinit(c.gpa);
                    continue;
                }
                c.ready.append(c.gpa, .{ .bucket = job.bucket, .seq = job.seq, .key = job.key, .icon = icon }) catch {
                    c.gpa.free(job.key);
                    if (icon) |ic| ic.deinit(c.gpa);
                    continue;
                };
                const has_more = c.hasCurrentJobLocked();
                if ((!has_more or c.ready.items.len >= max_batch) and !c.wake_scheduled) {
                    c.wake_scheduled = true;
                    should_wake = true;
                    wake = c.wake;
                }
            }
            if (should_wake) wake.wake(wake.ctx);
        }
    }
};

fn containsSlice(list: []const []const u8, target: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, target)) return true;
    return false;
}

const t = std.testing;

test "keyFor normalizes bundles, folders, extensions, and unknown paths" {
    var buf: [256]u8 = undefined;
    try t.expect(keyFor(&buf, "", .file) == null);
    try t.expectEqualStrings("app:/Applications/Calendar.app", keyFor(&buf, "/Applications/Calendar.app", .app).?);
    try t.expectEqualStrings("app:/Applications/Calendar.app", keyFor(&buf, "/Applications/Calendar.app/", .unknown).?);
    try t.expectEqualStrings("app:/Applications/Notes.APP", keyFor(&buf, "/Applications/Notes.APP", .unknown).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/Users/f/alpha", .folder).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/Users/f/beta.dir/", .folder).?);
    try t.expectEqualStrings("folder", keyFor(&buf, "/", .folder).?);
    try t.expectEqualStrings("ext:pdf", keyFor(&buf, "/Users/f/first.pdf", .file).?);
    try t.expectEqualStrings("ext:pdf", keyFor(&buf, "/Users/f/SECOND.PDF", .file).?);
    try t.expectEqualStrings("ext:", keyFor(&buf, "/Users/f/.gitignore", .file).?);
    try t.expectEqualStrings("ext:", keyFor(&buf, "/Users/f/README", .file).?);
    try t.expectEqualStrings("path:/Users/f/Makefile", keyFor(&buf, "/Users/f/Makefile", .unknown).?);

    var tiny: [4]u8 = undefined;
    try t.expect(keyFor(&tiny, "/Applications/Calendar.app", .app) == null);
    try t.expect(keyFor(&tiny, "/Users/f/first.pdf", .file) == null);
    try t.expect(keyFor(&tiny, "/Users/f/Makefile", .unknown) == null);
}
