# Plan 013: Picture recompression runs on a worker thread, and a captured picture is decoded once

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/clipboard.zig frontends/nanoui/src/main.zig frontends/nanoui/src/mac.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and other plans (003, 010, 012) edit
> `clipboard.zig` and `main.zig`. Line numbers will be off. Find each
> excerpt with `rg` by its text.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/012-capture-writes-once-and-trims-cheaply.md`
  (same file; run one at a time)
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher with
Clipboard History. Pictures older than 7 days are recompressed from PNG to
AVIF to save disk space. That work runs on the app's main thread, one
picture every 2 seconds while a backlog exists.

For a 5K screenshot the work decodes the picture (about 59 MB), allocates a
second buffer of the same size to check for transparency, and encodes
AVIF. While it runs, the hot key cannot open the panel. It also raises the
hidden footprint by over 100 MB for the duration.

Separately, capturing a TIFF picture encodes it to PNG and then decodes
that PNG again to make the thumbnail.

After this plan, recompression runs on a worker thread and only the two
small database steps stay on the main thread. The thumbnail is made from
the bytes the pasteboard gave.

## Current state

Files:

- `frontends/nanoui/src/clipboard.zig` — Clipboard History store.
- `frontends/nanoui/src/main.zig` — app shell; owns timers and threads.
- `frontends/nanoui/src/mac.zig` — Cocoa adapter; `compactImage`,
  `PasteboardReader`.

The timer (`main.zig`):

```zig
    fn compactTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (!s.presence.isHidden()) return nanoui.App.after(compact_next_ms, s, compactTick);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const more = s.store.compactOne(arena.allocator(), clipboard.wallClock(), mac.compactImage);
        nanoui.App.after(if (more) compact_next_ms else compact_idle_ms, s, compactTick);
    }
```

with `compact_next_ms = 2000` and `compact_idle_ms = 60 * 60 * 1000`.

The whole job in one function (`clipboard.zig`):

```zig
    pub fn compactOne(s: Store, arena: std.mem.Allocator, now: f64, compact: Compactor) bool {
        var hash: [32]u8 = undefined;
        var size: usize = 0;
        {
            const stmt = s.prepare("SELECT hash, stored_bytes FROM entries WHERE image_format = 'png' AND compacted = 0 AND length(hash) = 32 AND created_at < ? LIMIT 1") catch return false;
            defer _ = lite.sqlite3_finalize(stmt);
            bindAll(stmt, .{now - compact_after_days * 86400});
            if (lite.sqlite3_step(stmt) != lite.row) return false;
            @memcpy(&hash, columnBlob(stmt, 0));
            size = @intCast(lite.sqlite3_column_int64(stmt, 1));
        }
        const smaller = if (s.readImage(arena, &hash, "png", size)) |png| compact(arena, png) else null;
        const done = if (smaller) |bytes| blk: {
            s.writeImage(&hash, "avif", bytes) catch break :blk false;
            s.run("UPDATE entries SET image_format = 'avif', stored_bytes = ?, compacted = 1 WHERE hash = ? AND image_format = 'png'", .{ @as(i64, @intCast(bytes.len)), Blob{ .bytes = &hash } }) catch break :blk false;
            s.unlinkImage(&hash, "png");
            break :blk true;
        } else false;
        if (!done) s.run("UPDATE entries SET compacted = 1 WHERE hash = ? AND image_format = 'png'", .{Blob{ .bytes = &hash }}) catch {};
        return true;
    }
```

`readImage`, `writeImage` and `unlinkImage` are private file helpers in
`clipboard.zig`. They use only `s.images` (the picture folder path), not
the database handle. Confirm that by reading them.

`pub const Compactor = *const fn (arena: std.mem.Allocator, png: []const u8) ?[]const u8;`
— `mac.compactImage` is one. It returns null when the picture has
transparency or AVIF saves too little.

The app's existing pattern for a worker that posts back to the main thread
(`main.zig`):

```zig
    fn rebuildIndex(s: *Shell) void {
        const t = std.Thread.spawn(.{}, FileIndex.rebuild, .{ &s.files, file_index.Notify{ .ctx = s, .ready = indexReady } }) catch |err|
            return std.log.err("file index: no rebuild thread: {s}", .{@errorName(err)});
        s.panel.indexing = true;
        t.detach();
    }

    fn indexReady(ctx: ?*anyopaque, outcome: file_index.Outcome) void {
        if (outcome == .failed) std.log.err("file index: {s}", .{@errorName(outcome.failed)});
        objc.dispatchMain(ctx, indexLanded);
    }
```

The SQLite connection must be used from one thread at a time. The store
has one connection, and the main thread uses it. The worker must not touch
`s.db`.

Thumbnail at capture (`mac.zig`, `PasteboardReader.image`):

```zig
        const png_data = if (r.picture_is_png) data else pngRepresentation(rep) orelse return null;
        return .{
            .png = arena.dupe(u8, dataBytes(png_data)) catch return null,
            .thumbnail = thumbnailPng(arena, png_data) orelse "",
```

`thumbnailPng` reads its input through `CGImageSourceCreateWithData`, which
accepts TIFF as well as PNG.

Design record `docs/adr/0011-nano-clipboard-history.md`: Clipboard History
(`clipboard.zig`) owns the capture rules; `mac.zig` only reads and
converts. Keep rules out of `mac.zig`.

Conventions: comments say why, never what. Domain terms from `CONTEXT.md`:
**Clipboard History**, **Clipboard Entry**, **Clipboard Capture**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |

## Scope

**In scope**:

- `frontends/nanoui/src/clipboard.zig` (`compactOne` and new functions
  beside it)
- `frontends/nanoui/src/main.zig` (`compactTick` and new functions beside
  it)
- `frontends/nanoui/src/mac.zig` (one line in `PasteboardReader.image`)
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- `mac.compactImage` and `everyPixelOpaque`. Their memory use is deferred.
- Moving capture itself to a worker. The pasteboard reader holds an
  autorelease pool and the capture rules live in `clipboard.zig`; that move
  needs its own design.
- The 7-day threshold, the AVIF quality, and the schema.

## Git workflow

- Branch: `advisor/013-image-recompression-off-main-thread`.
- Commit style: `perf(nanoui): pictures recompress on a worker thread`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Make the thumbnail from the pasteboard's bytes

In `mac.zig`, `PasteboardReader.image`: pass `data` to `thumbnailPng`, not
`png_data`.

**Verify**: `make test-nanoui` → exit 0.

### Step 2: Split `compactOne` into three parts

In `clipboard.zig`:

- `pub const Compaction = struct { hash: [32]u8, size: usize };`
- `pub fn nextCompaction(s: Store, now: f64) ?Compaction` — the `SELECT`
  from `compactOne`. Main thread.
- `pub fn recompress(images: []const u8, arena: std.mem.Allocator, job: Compaction, compact: Compactor) ?usize`
  — reads the PNG file, calls `compact`, writes the AVIF file, and returns
  the AVIF byte count, or null when nothing was written. It takes the
  picture folder path, not a `Store`, so it cannot reach the database. If
  `readImage` and `writeImage` are methods on `Store`, give them a variant
  that takes the folder path and have the methods call it.
- `pub fn finishCompaction(s: Store, job: Compaction, avif_bytes: ?usize) void`
  — the two `UPDATE` statements and the `unlinkImage` of the PNG. Main
  thread. When `avif_bytes` is set but the `UPDATE` changes no row (the
  entry was deleted while the worker ran; check `sqlite3_changes`), unlink
  the AVIF file just written.

Keep `compactOne` and implement it by calling the three in order, so
existing tests and callers still work.

**Verify**: `make test-nanoui` → exit 0, with the existing compaction tests
unchanged (find them with `rg -n 'compactOne' frontends/nanoui/src/tests.zig`).

### Step 3: Run `recompress` on a worker

In `main.zig`, change `compactTick`:

1. When the panel is not hidden, or a recompression is already running
   (a new `compacting: bool` field on `Shell`), re-arm and return.
2. Call `s.store.nextCompaction(...)`. When it returns null, arm the timer
   with `compact_idle_ms` and return.
3. Allocate a job struct with `gpa` holding the shell pointer, the
   `Compaction`, and a result field. Set `compacting = true`. Spawn a
   detached thread, as `rebuildIndex` does, that creates its own arena,
   calls `clipboard.recompress(images_path, arena, job, mac.compactImage)`,
   stores the result, and calls `objc.dispatchMain(job, compactionLanded)`.
4. `compactionLanded` runs on the main thread: call
   `s.store.finishCompaction`, free the job, set `compacting = false`, and
   arm the timer with `compact_next_ms`.

If the thread cannot be spawned, log the error as `rebuildIndex` does, mark
nothing, and arm the idle timer.

The picture folder path is a local in `main` (`images_path`,
`scratch_images`). The store keeps it as `store.images`; read it from
there.

**Verify**: `make test-nanoui` → exit 0.

### Step 4: Check the worker never touches the database

**Verify**: `rg -n 'fn recompress' -A 30 frontends/nanoui/src/clipboard.zig`
shows no use of `s.db`, `s.run`, `s.prepare` or `s.int`.

## Test plan

Add to `tests.zig`, using the existing compaction tests as the pattern:

- "recompression in three parts gives the same result as in one": run
  `nextCompaction`, `recompress`, `finishCompaction` by hand with a fake
  `Compactor` that returns a short byte string; expect the entry's format
  to be `avif` and the PNG file gone.
- "an entry deleted during recompression leaves no file behind": run
  `nextCompaction`, delete the entry, run `recompress` and
  `finishCompaction`; expect no AVIF file in the picture folder.
- "a picture that does not shrink is marked and kept": a `Compactor` that
  returns null; expect `compacted = 1`, the format still `png`, the PNG
  file present, and `nextCompaction` returning null afterwards.
- "a TIFF copy has a thumbnail": only if an existing test already drives
  `PasteboardReader` with real image data; otherwise skip and say so.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including at least 3 new
tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `rg -n 'compactOne' frontends/nanoui/src/main.zig` returns no
      matches.
- [ ] `rg -n 'thumbnailPng\(arena, data\)' frontends/nanoui/src/mac.zig`
      returns one match.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `readImage` or `writeImage` uses the database handle.
- `objc.dispatchMain` cannot carry a per-job pointer.
- The app can exit while the worker runs and a test or sanitizer reports a
  use after free. Report it; do not add a join at exit without approval.
- An existing compaction test fails twice.

## Maintenance notes

- The worker still decodes the whole picture and allocates a second
  full-size buffer in `everyPixelOpaque`. Checking transparency on a
  downscaled copy would cut that; it is deferred.
- An oversized picture is still fetched from the pasteboard in full before
  the 15 MB cap is checked. AppKit offers no size query; a fix needs
  `NSPasteboardItem` type inspection and its own plan.
- Any future worker must follow the same rule: files on the worker,
  database on the main thread.
