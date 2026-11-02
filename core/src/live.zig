//! A mapped index kept current by file-system events, without full rescans.
//!
//! Each generation is one mapped file plus two small heap structures: a
//! tombstone bitset for mapped entries that are gone from disk, and an
//! overlay of entries that appeared since the file was written. Search
//! merges all three. Every change also marks the folder it happened in as
//! dirty. When the overlay passes its bound, a background compaction
//! rebuilds the file: it copies every clean folder's entries from the old
//! mapping, lists only the dirty folders again, writes the result through a
//! temporary file and a rename, and swaps the new generation in.
//!
//! Locking: `lock` is shared by readers for a whole query and taken alone to
//! apply an event or swap a generation. `mu` guards the compaction queue.
//! Where both are held, `lock` comes first.

const std = @import("std");
const index = @import("index.zig");
const overlay = @import("overlay.zig");
const scan = @import("scan.zig");
const rank = @import("search.zig");
const sys = @import("sys.zig");

const io = sys.sync_io;

pub const Options = struct {
    /// Overlay adds plus removals that trigger a compaction.
    overlay_limit: u32 = 4096,
    /// Compact on a background thread. Off only in tests that compact by
    /// hand.
    background: bool = true,
    scan: scan.Options = .{},
};

const Generation = struct {
    /// Increases by one per swap. Ids from a search only mean something
    /// inside the generation that produced them.
    number: u64,
    mapped: index.Mapped,
    dead: []u64,
    overlay: overlay.Overlay,
    changes: u32 = 0,

    fn create(gpa: std.mem.Allocator, mapped: index.Mapped, number: u64, cap: u32) !*Generation {
        const g = try gpa.create(Generation);
        errdefer gpa.destroy(g);
        const dead = try gpa.alloc(u64, (mapped.view.count() + 63) / 64);
        errdefer gpa.free(dead);
        @memset(dead, 0);
        g.* = .{ .number = number, .mapped = mapped, .dead = dead, .overlay = try .init(gpa, cap) };
        return g;
    }

    fn destroy(g: *Generation, gpa: std.mem.Allocator) void {
        g.overlay.deinit();
        gpa.free(g.dead);
        g.mapped.close();
        gpa.destroy(g);
    }

    fn view(g: *const Generation) index.View {
        return g.mapped.view;
    }

    fn isDead(g: *const Generation, id: u32) bool {
        return rank.isDead(g.dead, id);
    }

    fn kill(g: *Generation, id: u32) void {
        g.dead[id >> 6] |= @as(u64, 1) << @intCast(id & 63);
    }

    /// Kills `id` and everything under it. A folder's descendants all come
    /// after its first child and every parent precedes its children, so one
    /// forward pass that kills whatever has a dead parent finds them all.
    fn killTree(g: *Generation, id: u32) void {
        const v = g.view();
        g.kill(id);
        if (!v.flags[id].dir) return;
        var i: u32 = @intCast(std.mem.indexOfScalarPos(u32, v.parent, id + 1, id) orelse return);
        while (i < v.count()) : (i += 1) {
            const p = v.parent[i];
            if (p != index.no_parent and g.isDead(p)) g.kill(i);
        }
    }

    fn contains(g: *const Generation, rel: []const u8) bool {
        if (g.view().lookup(rel)) |id| if (!g.isDead(id)) return true;
        return g.overlay.find(rel) != null;
    }
};

/// A queued event that arrived while a compaction was running. It is
/// replayed onto the new generation, which was built from disk listings
/// that may predate it.
const Pending = struct {
    rel: []u8,
    /// A rescan request rather than a single changed path.
    deep: bool,
};

pub const Live = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    root: []u8,
    root_fd: sys.fd_t,
    index_path: []u8,

    lock: std.Io.RwLock = .init,
    gen: *Generation,

    mu: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    /// Folders to list again, keyed by relative path. The value is true when
    /// everything below must be walked too.
    dirty: std.StringHashMapUnmanaged(bool) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    compacting: bool = false,
    wanted: bool = false,
    stopping: bool = false,
    compactions: u64 = 0,
    last_error: ?anyerror = null,

    /// Serialises compactions, so the background thread and an explicit
    /// `compact` call never build two files at once.
    compact_mu: std.Io.Mutex = .init,
    thread: ?std.Thread = null,

    /// Maps `index_path`, building it from `root` first if it is missing,
    /// unreadable, or was built from another root.
    pub fn open(gpa: std.mem.Allocator, root: []const u8, index_path: []const u8, opts: Options) !*Live {
        const l = try gpa.create(Live);
        errdefer gpa.destroy(l);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const path_copy = try gpa.dupe(u8, index_path);
        errdefer gpa.free(path_copy);
        const root_fd = try sys.openRoot(root);
        errdefer sys.close(root_fd);
        const gen = blk: {
            var mapped = try openOrBuild(gpa, root, index_path, opts.scan);
            errdefer mapped.close();
            break :blk try Generation.create(gpa, mapped, 1, overlayCap(opts));
        };
        errdefer gen.destroy(gpa);

        l.* = .{ .gpa = gpa, .opts = opts, .root = root_copy, .root_fd = root_fd, .index_path = path_copy, .gen = gen };
        if (opts.background) l.thread = try std.Thread.spawn(.{}, loop, .{l});
        return l;
    }

    pub fn close(l: *Live) void {
        l.mu.lockUncancelable(io);
        l.stopping = true;
        l.wake.signal(io);
        l.mu.unlock(io);
        if (l.thread) |th| th.join();

        l.gen.destroy(l.gpa);
        var keys = l.dirty.keyIterator();
        while (keys.next()) |k| l.gpa.free(k.*);
        l.dirty.deinit(l.gpa);
        for (l.pending.items) |p| l.gpa.free(p.rel);
        l.pending.deinit(l.gpa);
        sys.close(l.root_fd);
        l.gpa.free(l.root);
        l.gpa.free(l.index_path);
        l.gpa.destroy(l);
    }

    /// Mapped hits and overlay hits ranked together, best first. Writes the
    /// generation the ids belong to into `generation`. Allocates nothing.
    pub fn search(l: *Live, text: []const u8, out: []rank.Hit, generation: ?*u64) usize {
        const q = rank.Query.parse(text);
        l.lock.lockSharedUncancelable(io);
        defer l.lock.unlockShared(io);
        const g = l.gen;
        if (generation) |n| n.* = g.number;
        if (q.n == 0) return 0;
        var heap = rank.TopK.init(@min(out.len, rank.max_k));
        rank.searchInto(g.view(), g.dead, &q, &heap);
        g.overlay.searchInto(&q, &heap);
        return heap.sorted(out);
    }

    /// The relative path of a hit, or null if its generation has been
    /// replaced or the entry has since been deleted.
    pub fn relativePath(l: *Live, generation: u64, id: u32, buf: []u8) ?[]const u8 {
        l.lock.lockSharedUncancelable(io);
        defer l.lock.unlockShared(io);
        const g = l.gen;
        if (g.number != generation) return null;
        if (id >= overlay.id_base) {
            const slot = id - overlay.id_base;
            if (!g.overlay.isLive(slot)) return null;
            const p = g.overlay.path(slot);
            if (p.len > buf.len) return null;
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
        if (id >= g.view().count() or g.isDead(id)) return null;
        return g.view().relativePath(id, buf);
    }

    pub fn isDir(l: *Live, generation: u64, id: u32) bool {
        l.lock.lockSharedUncancelable(io);
        defer l.lock.unlockShared(io);
        const g = l.gen;
        if (g.number != generation) return false;
        if (id >= overlay.id_base) {
            const slot = id - overlay.id_base;
            return g.overlay.isLive(slot) and g.overlay.flags.items[slot].dir;
        }
        return id < g.view().count() and !g.isDead(id) and g.view().flags[id].dir;
    }

    /// Something at `rel` (relative to the root) was created, deleted,
    /// renamed, or changed. Looks at the disk and brings the index in line.
    /// Calls for one path should come from one thread, so they apply in the
    /// order the disk changed.
    pub fn notify(l: *Live, rel: []const u8) void {
        const r = std.mem.trim(u8, rel, "/");
        if (r.len == 0) return l.rescan("");
        if (!scan.tracked(r, l.opts.scan)) return;
        const kind = sys.probe(l.root_fd, r);

        // A folder that appears with contents (moved in, unpacked) is listed
        // here, off the lock, so its files are searchable before the next
        // compaction. Past the overlay's room the compaction picks it up.
        var subtree: ?index.Builder = null;
        defer if (subtree) |*b| b.deinit();
        if (kind == .dir and !l.has(r)) subtree = l.listNew(r);

        l.lock.lockUncancelable(io);
        defer l.lock.unlock(io);
        l.apply(r, kind, if (subtree) |*b| b else null);
    }

    /// Lists `rel` and everything below it again at the next compaction,
    /// and asks for one now. For events the source could not describe:
    /// dropped events, or a whole tree that changed at once.
    pub fn rescan(l: *Live, rel: []const u8) void {
        const r = std.mem.trim(u8, rel, "/");
        l.mu.lockUncancelable(io);
        defer l.mu.unlock(io);
        if (l.compacting) {
            const copy = l.gpa.dupe(u8, r) catch return;
            l.pending.append(l.gpa, .{ .rel = copy, .deep = true }) catch l.gpa.free(copy);
        } else {
            l.markLocked(r, true);
        }
        l.wanted = true;
        l.wake.signal(io);
    }

    fn has(l: *Live, rel: []const u8) bool {
        l.lock.lockSharedUncancelable(io);
        defer l.lock.unlockShared(io);
        return l.gen.contains(rel);
    }

    fn listNew(l: *Live, rel: []const u8) ?index.Builder {
        var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ l.root, rel }) catch return null;
        var opts = l.opts.scan;
        opts.limit = overlayCap(l.opts);
        var b = index.Builder.init(l.gpa);
        scan.scan(&b, abs, opts) catch {
            b.deinit();
            return null;
        };
        return b;
    }

    /// Applies one probed change to the current generation. Holds `lock`.
    fn apply(l: *Live, rel: []const u8, kind: sys.Kind, subtree: ?*const index.Builder) void {
        const g = l.gen;
        var changed = false;
        var full = false;
        switch (kind) {
            .missing => {
                if (g.view().lookup(rel)) |id| if (!g.isDead(id)) {
                    g.killTree(id);
                    changed = true;
                };
                if (g.overlay.removeTree(rel)) changed = true;
            },
            .file, .dir, .symlink => if (!g.contains(rel)) {
                changed = true;
                const flags: index.Flags = .{ .dir = kind == .dir, .symlink = kind == .symlink };
                full = (g.overlay.add(rel, flags) catch null) == null;
                // A folder whose contents could not be listed up front has
                // them listed by a compaction, so ask for one now.
                if (kind == .dir) full = full or if (subtree) |b| !addSubtree(g, rel, b) else true;
            },
        }
        if (!changed) return;
        g.changes += 1;

        l.mu.lockUncancelable(io);
        defer l.mu.unlock(io);
        if (l.compacting) {
            if (l.gpa.dupe(u8, rel)) |copy| {
                l.pending.append(l.gpa, .{ .rel = copy, .deep = false }) catch l.gpa.free(copy);
            } else |_| {}
        } else {
            l.markLocked(parentOf(rel), false);
        }
        if (full or g.changes >= l.opts.overlay_limit) {
            l.wanted = true;
            l.wake.signal(io);
        }
    }

    /// Adds a freshly listed folder's contents. Returns false if the overlay
    /// filled; the folder's parent is dirty, so compaction lists it whole.
    fn addSubtree(g: *Generation, rel: []const u8, b: *const index.Builder) bool {
        if (b.count() > g.overlay.cap - g.overlay.len()) return false;
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        var sub_buf: [std.posix.PATH_MAX]u8 = undefined;
        var id: u32 = 0;
        while (id < b.count()) : (id += 1) {
            const sub = b.view().relativePath(id, &sub_buf) orelse return false;
            const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rel, sub }) catch return false;
            _ = (g.overlay.add(p, b.flags.items[id]) catch null) orelse return false;
        }
        return true;
    }

    /// Holds `mu`.
    fn markLocked(l: *Live, rel: []const u8, deep: bool) void {
        const slot = l.dirty.getOrPut(l.gpa, rel) catch return;
        if (slot.found_existing) {
            slot.value_ptr.* = slot.value_ptr.* or deep;
            return;
        }
        slot.key_ptr.* = l.gpa.dupe(u8, rel) catch {
            l.dirty.removeByPtr(slot.key_ptr);
            return;
        };
        slot.value_ptr.* = deep;
    }

    /// Rebuilds the file from the old mapping and the dirty folders, then
    /// swaps it in. Readers keep searching the old generation until the swap,
    /// which holds `lock` only while queued events are replayed.
    pub fn compact(l: *Live) !void {
        l.compact_mu.lockUncancelable(io);
        defer l.compact_mu.unlock(io);

        var dirty = blk: {
            l.mu.lockUncancelable(io);
            defer l.mu.unlock(io);
            const d = l.dirty;
            l.dirty = .empty;
            l.compacting = true;
            l.wanted = false;
            break :blk d;
        };
        defer {
            var keys = dirty.keyIterator();
            while (keys.next()) |k| l.gpa.free(k.*);
            dirty.deinit(l.gpa);
        }

        const fresh = l.build(&dirty) catch |e| {
            l.abandon(&dirty, e);
            return e;
        };
        l.swap(fresh);
    }

    fn build(l: *Live, dirty: *const std.StringHashMapUnmanaged(bool)) !*Generation {
        // Only this thread swaps `gen`, so the old one stays put; its
        // tombstones still change under event application, hence the copy.
        const old = l.gen;
        const dead = blk: {
            l.lock.lockSharedUncancelable(io);
            defer l.lock.unlockShared(io);
            break :blk try l.gpa.dupe(u64, old.dead);
        };
        defer l.gpa.free(dead);

        var b = index.Builder.init(l.gpa);
        defer b.deinit();
        try rebuild(l.gpa, &b, old.view(), dead, dirty, l.root, l.root_fd, l.opts.scan);
        try b.writeFile(sys.cwd, l.index_path);
        var mapped = try index.Mapped.open(sys.cwd, l.index_path);
        errdefer mapped.close();
        return Generation.create(l.gpa, mapped, old.number + 1, overlayCap(l.opts));
    }

    fn swap(l: *Live, fresh: *Generation) void {
        l.lock.lockUncancelable(io);
        var pending = blk: {
            l.mu.lockUncancelable(io);
            defer l.mu.unlock(io);
            const p = l.pending;
            l.pending = .empty;
            l.compacting = false;
            l.compactions += 1;
            break :blk p;
        };
        const old = l.gen;
        l.gen = fresh;
        for (pending.items) |p| {
            if (p.deep) {
                l.mu.lockUncancelable(io);
                l.markLocked(p.rel, true);
                l.wanted = true;
                l.wake.signal(io);
                l.mu.unlock(io);
            } else {
                // Replays run under the lock, so a folder is not listed
                // here; `apply` queues its parent and asks for a compaction.
                l.apply(p.rel, sys.probe(l.root_fd, p.rel), null);
            }
        }
        l.lock.unlock(io);

        for (pending.items) |p| l.gpa.free(p.rel);
        pending.deinit(l.gpa);
        old.destroy(l.gpa);
    }

    /// Puts the work back after a failed build, so nothing is lost: the
    /// dirty folders, and every queued event as a dirty folder of its own.
    fn abandon(l: *Live, dirty: *std.StringHashMapUnmanaged(bool), err: anyerror) void {
        l.mu.lockUncancelable(io);
        defer l.mu.unlock(io);
        var it = dirty.iterator();
        while (it.next()) |e| l.markLocked(e.key_ptr.*, e.value_ptr.*);
        for (l.pending.items) |p| {
            l.markLocked(if (p.deep) p.rel else parentOf(p.rel), p.deep);
            l.gpa.free(p.rel);
        }
        l.pending.clearRetainingCapacity();
        l.compacting = false;
        l.last_error = err;
    }

    fn loop(l: *Live) void {
        l.mu.lockUncancelable(io);
        while (true) {
            while (!l.wanted and !l.stopping) l.wake.waitUncancelable(io, &l.mu);
            if (l.stopping) break;
            l.mu.unlock(io);
            // A failure is recorded by `abandon`; the work waits for the
            // next trigger rather than spinning on a full disk.
            l.compact() catch {};
            l.mu.lockUncancelable(io);
        }
        l.mu.unlock(io);
    }

    /// Compactions finished since open. For tests and diagnostics.
    pub fn compactionCount(l: *Live) u64 {
        l.mu.lockUncancelable(io);
        defer l.mu.unlock(io);
        return l.compactions;
    }

    pub fn overlayLen(l: *Live) u32 {
        l.lock.lockSharedUncancelable(io);
        defer l.lock.unlockShared(io);
        return l.gen.overlay.len();
    }
};

/// Hard room in the overlay. Compaction is asked for at `overlay_limit`; the
/// slack absorbs events that arrive while it runs.
fn overlayCap(opts: Options) u32 {
    return @max(16, opts.overlay_limit *| 4);
}

fn parentOf(rel: []const u8) []const u8 {
    const s = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..s];
}

fn openOrBuild(gpa: std.mem.Allocator, root: []const u8, path: []const u8, opts: scan.Options) !index.Mapped {
    if (index.Mapped.open(sys.cwd, path)) |m| {
        if (std.mem.eql(u8, m.view.root, root)) return m;
        var stale = m;
        stale.close();
    } else |_| {}
    var b = index.Builder.init(gpa);
    defer b.deinit();
    try scan.scan(&b, root, opts);
    try b.writeFile(sys.cwd, path);
    return index.Mapped.open(sys.cwd, path);
}

const Mark = enum(u8) { clean, shallow, deep };

/// Writes a fresh table into `b`: clean folders copied from `v`, dirty ones
/// listed from disk. Keeps the scan's layout, each folder's children in one
/// run, so `findChild` and the search path cache keep working.
fn rebuild(
    gpa: std.mem.Allocator,
    b: *index.Builder,
    v: index.View,
    dead: []const u64,
    dirty: *const std.StringHashMapUnmanaged(bool),
    root: []const u8,
    root_fd: sys.fd_t,
    opts: scan.Options,
) !void {
    try b.setRoot(root);
    const n = v.count();
    const marks = try gpa.alloc(Mark, n);
    defer gpa.free(marks);
    @memset(marks, .clean);
    const first = try gpa.alloc(u32, n);
    defer gpa.free(first);
    @memset(first, index.no_parent);
    var i: u32 = n;
    while (i > 0) {
        i -= 1;
        if (v.parent[i] != index.no_parent) first[v.parent[i]] = i;
    }

    var root_mark: Mark = .clean;
    var it = dirty.iterator();
    while (it.next()) |e| {
        const rel = e.key_ptr.*;
        const want: Mark = if (e.value_ptr.*) .deep else .shallow;
        var id = if (rel.len == 0) index.no_parent else v.deepestExisting(rel) orelse index.no_parent;
        // A path the old table does not hold is new: listing the nearest
        // folder above it finds it, and a new folder is walked whole.
        const exact = id != index.no_parent and v.lookup(rel) == id;
        var mark = if (exact or rel.len == 0) want else .shallow;
        while (id != index.no_parent and (rank.isDead(dead, id) or !v.flags[id].dir)) {
            id = v.parent[id];
            mark = .shallow;
        }
        const slot = if (id == index.no_parent) &root_mark else &marks[id];
        slot.* = @fromBackingInt(@intCast(@max(@backingInt(slot.*), @backingInt(mark))));
    }

    const buf = try gpa.alignedAlloc(u8, .@"8", scan.buffer_len);
    defer gpa.free(buf);
    const r: Rebuild = .{ .b = b, .v = v, .dead = dead, .marks = marks, .first = first, .root_fd = root_fd, .buf = buf, .opts = opts };
    try r.folder(index.no_parent, index.no_parent, root_mark);
}

const Rebuild = struct {
    b: *index.Builder,
    v: index.View,
    dead: []const u64,
    marks: []const Mark,
    first: []const u32,
    root_fd: sys.fd_t,
    buf: []align(8) u8,
    opts: scan.Options,

    /// The first child of `old`, or null. Root children start the table.
    fn firstChild(r: Rebuild, old: u32) ?u32 {
        if (old == index.no_parent) {
            return if (r.v.count() > 0 and r.v.parent[0] == index.no_parent) 0 else null;
        }
        const f = r.first[old];
        return if (f == index.no_parent) null else f;
    }

    fn depthOf(r: Rebuild, new: u32) u16 {
        return if (new == index.no_parent) 0 else r.b.depth.items[new];
    }

    /// Fills the new folder `new` with the contents of the old folder `old`.
    fn folder(r: Rebuild, old: u32, new: u32, mark: Mark) anyerror!void {
        switch (mark) {
            .clean => try r.copy(old, new),
            .shallow, .deep => {
                const fd = r.openOld(old) catch return;
                defer sys.close(fd);
                if (mark == .deep) return scan.walk(r.b, fd, new, r.depthOf(new), r.buf, r.opts);
                try r.relist(fd, old, new);
            },
        }
    }

    fn openOld(r: Rebuild, old: u32) !sys.fd_t {
        // A fresh descriptor each time: listing a folder moves its read
        // offset, and the kept root descriptor would be at the end.
        if (old == index.no_parent) return sys.openat(r.root_fd, ".", .dir);
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const rel = r.v.relativePath(old, &path_buf) orelse return error.NameTooLong;
        return sys.openat(r.root_fd, rel, .dir);
    }

    /// Clean folder: its children come from the old table, then each child
    /// folder is filled in turn.
    fn copy(r: Rebuild, old: u32, new: u32) !void {
        const start = r.firstChild(old) orelse return;
        const n = r.v.count();
        var nid = r.b.count();
        var i = start;
        while (i < n and r.v.parent[i] == old) : (i += 1) {
            if (!rank.isDead(r.dead, i)) _ = try r.b.add(new, r.v.name(i), r.v.flags[i]);
        }
        i = start;
        while (i < n and r.v.parent[i] == old) : (i += 1) {
            if (rank.isDead(r.dead, i)) continue;
            if (r.v.flags[i].dir) try r.folder(i, nid, r.marks[i]);
            nid += 1;
        }
    }

    /// Dirty folder: list it from disk. A child folder the old table holds
    /// keeps its old contents (and its own mark); a new one is walked.
    fn relist(r: Rebuild, fd: sys.fd_t, old: u32, new: u32) !void {
        const a = r.b.count();
        try scan.drain(r.b, fd, new, r.buf, r.opts);
        const z = r.b.count();
        if (r.depthOf(new) + 1 >= r.opts.max_depth) return;
        var nid = a;
        while (nid < z) : (nid += 1) {
            if (!r.b.isDir(nid)) continue;
            if (r.oldChild(old, r.b.name(nid))) |oc| {
                try r.folder(oc, nid, r.marks[oc]);
                continue;
            }
            const child = sys.openat(fd, r.b.name(nid), .dir) catch continue;
            defer sys.close(child);
            try scan.walk(r.b, child, nid, r.depthOf(nid), r.buf, r.opts);
        }
    }

    fn oldChild(r: Rebuild, old: u32, name: []const u8) ?u32 {
        const start = r.firstChild(old) orelse return null;
        var i = start;
        while (i < r.v.count() and r.v.parent[i] == old) : (i += 1) {
            if (rank.isDead(r.dead, i) or !r.v.flags[i].dir) continue;
            if (std.mem.eql(u8, r.v.name(i), name)) return i;
        }
        return null;
    }
};

const t = std.testing;

/// A temporary tree and a separate folder for its index, so the index file
/// is never itself indexed.
const Fixture = struct {
    tree: std.testing.TmpDir,
    store: std.testing.TmpDir,
    root_buf: [std.posix.PATH_MAX]u8 = undefined,
    root_len: usize = 0,
    idx_buf: [std.posix.PATH_MAX]u8 = undefined,
    idx_len: usize = 0,

    fn init(f: *Fixture) !void {
        f.tree = t.tmpDir(.{});
        f.store = t.tmpDir(.{});
        f.root_len = try f.tree.dir.realPath(t.io, &f.root_buf);
        var store_buf: [std.posix.PATH_MAX]u8 = undefined;
        const store = store_buf[0..try f.store.dir.realPath(t.io, &store_buf)];
        f.idx_len = (try std.fmt.bufPrint(&f.idx_buf, "{s}/i.flix", .{store})).len;
    }

    fn deinit(f: *Fixture) void {
        f.tree.cleanup();
        f.store.cleanup();
    }

    fn root(f: *const Fixture) []const u8 {
        return f.root_buf[0..f.root_len];
    }

    fn open(f: *const Fixture, opts: Options) !*Live {
        return Live.open(t.allocator, f.root(), f.idx_buf[0..f.idx_len], opts);
    }

    fn touch(f: *const Fixture, rel: []const u8) !void {
        sys.close(try sys.openat(f.tree.dir.handle, rel, .create));
    }

    fn mkdir(f: *const Fixture, rel: []const u8) !void {
        try f.tree.dir.createDirPath(t.io, rel);
    }
};

/// The relative path of the best hit for `query`, or null for no hits.
fn top(l: *Live, query: []const u8, buf: []u8) ?[]const u8 {
    var hits: [8]rank.Hit = undefined;
    var generation: u64 = 0;
    const n = l.search(query, &hits, &generation);
    if (n == 0) return null;
    return l.relativePath(generation, hits[0].id, buf);
}

fn waitFor(l: *Live, query: []const u8, want: ?[]const u8) bool {
    var buf: [256]u8 = undefined;
    for (0..400) |_| {
        const got = top(l, query, &buf);
        if (want) |w| {
            if (got != null and std.mem.eql(u8, got.?, w)) return true;
        } else if (got == null) return true;
        sys.sleepMs(10);
    }
    return false;
}

test "create, rename, and delete a file, then search" {
    var f: Fixture = .{ .tree = undefined, .store = undefined };
    try f.init();
    defer f.deinit();
    try f.mkdir("docs/old");
    try f.touch("docs/notes.txt");
    try f.touch("docs/old/ledger.csv");
    const l = try f.open(.{ .background = false });
    defer l.close();
    var buf: [256]u8 = undefined;

    try f.touch("docs/quarterly.pdf");
    l.notify("docs/quarterly.pdf");
    try t.expectEqualStrings("docs/quarterly.pdf", top(l, "quarterly", &buf).?);

    try sys.renameat(f.tree.dir.handle, "docs/quarterly.pdf", "docs/annual.pdf");
    l.notify("docs/quarterly.pdf");
    l.notify("docs/annual.pdf");
    try t.expect(top(l, "quarterly", &buf) == null);
    try t.expectEqualStrings("docs/annual.pdf", top(l, "annual", &buf).?);

    sys.unlinkat(f.tree.dir.handle, "docs/notes.txt");
    l.notify("docs/notes.txt");
    try t.expect(top(l, "notes", &buf) == null);

    // A deleted folder takes its mapped descendants with it.
    try f.tree.dir.deleteTree(t.io, "docs/old");
    l.notify("docs/old");
    try t.expect(top(l, "ledger", &buf) == null);

    // Events inside hidden or pruned folders never reach the index.
    try f.mkdir("node_modules");
    try f.touch("node_modules/annual-pkg");
    l.notify("node_modules/annual-pkg");
    try t.expectEqualStrings("docs/annual.pdf", top(l, "annual", &buf).?);

    try l.compact();
    try t.expectEqual(@as(u32, 0), l.overlayLen());
    try t.expectEqualStrings("docs/annual.pdf", top(l, "annual", &buf).?);
    try t.expect(top(l, "quarterly", &buf) == null);
    try t.expect(top(l, "notes", &buf) == null);
    try t.expect(top(l, "ledger", &buf) == null);
    try t.expectEqualStrings("docs", top(l, "docs", &buf).?);

    // A second compaction lists the root again from a fresh descriptor.
    try f.touch("todo.txt");
    l.notify("todo.txt");
    try l.compact();
    try t.expectEqualStrings("todo.txt", top(l, "todo", &buf).?);
    try t.expectEqualStrings("docs/annual.pdf", top(l, "annual", &buf).?);
}

test "a folder that appears with contents is searchable at once" {
    var f: Fixture = .{ .tree = undefined, .store = undefined };
    try f.init();
    defer f.deinit();
    const l = try f.open(.{ .background = false });
    defer l.close();
    var buf: [256]u8 = undefined;

    try f.mkdir("photos/2026/trip");
    try f.touch("photos/2026/trip/lisbon.heic");
    l.notify("photos");
    try t.expectEqualStrings("photos/2026/trip/lisbon.heic", top(l, "lisbon", &buf).?);

    try l.compact();
    try t.expectEqualStrings("photos/2026/trip/lisbon.heic", top(l, "lisbon", &buf).?);
    try t.expectEqual(@as(u32, 0), l.overlayLen());
}

test "ids from a replaced generation resolve to nothing" {
    var f: Fixture = .{ .tree = undefined, .store = undefined };
    try f.init();
    defer f.deinit();
    try f.touch("alpha.txt");
    const l = try f.open(.{ .background = false });
    defer l.close();
    var hits: [4]rank.Hit = undefined;
    var generation: u64 = 0;
    try t.expectEqual(@as(usize, 1), l.search("alpha", &hits, &generation));
    var buf: [64]u8 = undefined;
    try t.expect(l.relativePath(generation, hits[0].id, &buf) != null);
    try l.compact();
    try t.expect(l.relativePath(generation, hits[0].id, &buf) == null);
}

test "overlay bound triggers compaction" {
    var f: Fixture = .{ .tree = undefined, .store = undefined };
    try f.init();
    defer f.deinit();
    const l = try f.open(.{ .overlay_limit = 4 });
    defer l.close();

    var name_buf: [32]u8 = undefined;
    for (0..6) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "invoice-{d}.pdf", .{i});
        try f.touch(name);
        l.notify(name);
    }
    var waited: u32 = 0;
    while (l.compactionCount() == 0 and waited < 5000) : (waited += 10) sys.sleepMs(10);
    try t.expect(l.compactionCount() >= 1);
    // The swap replays what arrived while the file was built; whatever is
    // left in the overlay is under the bound that started it.
    try t.expect(l.overlayLen() < 4);
    for (0..6) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "invoice-{d}.pdf", .{i});
        try t.expect(waitFor(l, name, name));
    }
}

const Reader = struct {
    l: *Live,
    stop: *std.atomic.Value(bool),
    queries: u32 = 0,
    misses: u32 = 0,

    fn run(r: *Reader) void {
        var buf: [256]u8 = undefined;
        while (!r.stop.load(.acquire)) {
            r.queries += 1;
            const got = top(r.l, "anchor", &buf);
            // A swap between the search and the path lookup yields null,
            // which is the contract; only a wrong path is a miss.
            if (got) |p| {
                if (!std.mem.eql(u8, p, "keep/anchor.md")) r.misses += 1;
            }
            var hits: [4]rank.Hit = undefined;
            if (r.l.search("anchor", &hits, null) == 0) r.misses += 1;
        }
    }
};

const Writer = struct {
    f: *const Fixture,
    l: *Live,
    n: u32,
    failed: bool = false,

    fn run(w: *Writer) void {
        var name_buf: [32]u8 = undefined;
        for (0..w.n) |i| {
            const name = std.fmt.bufPrint(&name_buf, "inbox/msg-{d}.eml", .{i}) catch unreachable;
            w.f.touch(name) catch {
                w.failed = true;
                return;
            };
            w.l.notify(name);
        }
    }
};

test "concurrent search during compaction" {
    var f: Fixture = .{ .tree = undefined, .store = undefined };
    try f.init();
    defer f.deinit();
    try f.mkdir("keep");
    try f.mkdir("inbox");
    try f.touch("keep/anchor.md");
    const l = try f.open(.{ .background = false, .overlay_limit = 1 << 20 });
    defer l.close();

    var stop = std.atomic.Value(bool).init(false);
    var readers: [4]Reader = @splat(.{ .l = l, .stop = &stop });
    var threads: [4]std.Thread = undefined;
    for (&readers, &threads) |*r, *th| th.* = try std.Thread.spawn(.{}, Reader.run, .{r});

    // Events land while compactions run, so the swap's replay is exercised
    // as well as the readers.
    var writer: Writer = .{ .f = &f, .l = l, .n = 200 };
    const wt = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    for (0..20) |_| try l.compact();
    wt.join();
    try l.compact();

    stop.store(true, .release);
    for (threads) |th| th.join();
    try t.expect(!writer.failed);
    for (readers) |r| {
        try t.expect(r.queries > 0);
        try t.expectEqual(@as(u32, 0), r.misses);
    }
    var name_buf: [32]u8 = undefined;
    var buf: [256]u8 = undefined;
    for (0..200) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "inbox/msg-{d}.eml", .{i});
        const q = name["inbox/".len..];
        try t.expectEqualStrings(name, top(l, q, &buf) orelse return error.TestExpectedEqual);
    }
}
