# Plan 003: A bulk file copy cannot flood or evict clipboard history, and nanoui prunes hourly

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/clipboard.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig Sources/Floodlight/Search/ClipboardCaptureService.swift Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`
> **Extra check for this plan**: the three Zig files had uncommitted changes
> when this plan was written, and the Zig excerpts below come from that
> working tree, not from commit `64cc313`. Line numbers can be off. Find each
> excerpt with `rg` by its text and confirm it before you edit.
> Plan 001 also edits `ClipboardCaptureService.swift`; if it has landed, the
> Swift excerpt's line numbers will differ but its text must still match.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (run after plan 001 if both are scheduled, because both
  edit `ClipboardCaptureService.swift`)
- **Category**: bug
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-10

## Why this matters

Floodlight has two frontends that each record clipboard history: the Swift app
(`Sources/`) and the Zig app (`frontends/nanoui`). Both store one history entry
per copied file, with no limit on how many files one copy may contain.

In the Zig app, history is capped at 5,000 unpinned entries, enforced after
every insert. Selecting 5,000 files in Finder and pressing ⌘C therefore
replaces the user's entire unpinned history with file paths. Each file also
runs about eight SQL statements on the main thread. In the Swift app there is
no entry cap, so the same copy adds thousands of rows on the main thread.

Separately, the Zig app prunes entries older than 30 days only once, at
launch, although it runs for weeks.

After this plan: a copy of more than 100 files records nothing in either
frontend (the same rule both already apply to oversized text and images), and
the Zig app prunes at launch and then every hour.

## Current state

Files:

- `frontends/nanoui/src/clipboard.zig` — Zig clipboard store and capture rules.
- `frontends/nanoui/src/main.zig` — Zig app shell; owns the timers.
- `frontends/nanoui/src/tests.zig` — all nanoui tests.
- `Sources/Floodlight/Search/ClipboardCaptureService.swift` — Swift capture.
- `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` — its tests.

Zig capture rules (`clipboard.zig`, `fn captures`). Note the doc comment:
over-cap content records nothing.

```zig
/// What a copy becomes: its files, else its picture, else its text; nothing
/// when it is marked private or Floodlight's own, or past a size cap.
fn captures(arena: std.mem.Allocator, board: Pasteboard, source: []const u8) []const Capture {
    for (skipped_types) |ty| if (board.has_type(board.ctx, ty)) return &.{};
    var out: std.ArrayList(Capture) = .empty;
    for (board.file_paths(board.ctx, arena)) |path| {
        const seen = for (out.items) |cap| {
            if (std.mem.eql(u8, cap.file, path)) break true;
        } else false;
        if (path.len > 0 and !seen) out.append(arena, .{ .file = path }) catch {};
    }
    if (out.items.len > 0) return out.items;
```

The size caps and budget live together (`clipboard.zig`):

```zig
pub const max_text_bytes = 32_000;
...
pub const max_image_bytes = 15 * 1024 * 1024;
pub const retention_days = 30;
...
pub const Budget = struct { bytes: u64 = 150 * 1024 * 1024, entries: u32 = 5000, queries: u32 = 1000 };
```

Each stored capture ends with the budget check (`clipboard.zig`, end of
`pub fn add`): `try s.keepWithinBudget();`

The only prune call in the Zig app (`main.zig`, in `main`):

```zig
    shell.store.prune(clipboard.wallClock(), clipboard.retention_days) catch |err| std.log.err("clipboard prune: {s}", .{@errorName(err)});
```

The Zig shell's recurring-timer pattern (`main.zig`, inside `const Shell`):

```zig
    fn captureTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(clipboard_poll_ms, s, captureTick);
```

After a capture changes history, the same function refreshes an open board:

```zig
        if (!stored or s.panel.mode != .clipboard) return;
        s.panel.board.list.markStale();
        if (s.presence.isHidden()) return;
        s.panel.refresh();
        s.panel_window.redraw();
```

Timers are first armed in `main` (find with
`rg -n "Shell.captureTick|Shell.compactTick" frontends/nanoui/src/main.zig`):

```zig
        nanoui.App.after(clipboard_poll_ms, &shell, Shell.captureTick);
        nanoui.App.after(compact_next_ms, &shell, Shell.compactTick);
```

Timer constants are at the top of `main.zig`, for example
`const compact_idle_ms = 60 * 60 * 1000;`.

Swift capture of files (`ClipboardCaptureService.swift`, in `func poll()`):

```swift
        let filePaths = observer.filePaths().compactMap(ClipboardFileReference.canonicalize)
        if !filePaths.isEmpty {
            for path in filePaths {
                store.recordFile(path: path, sourceAppBundleID: bundleID)
            }
            return
        }
```

Swift's existing size rule in the same function, for comparison:

```swift
        // Rule 5: Text exceeds 32,000 UTF-8 bytes -> skip entirely
        guard let text = observer.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= ClipboardHistoryStore.maxTextByteCount else { return }
```

Constants on the Swift service are `static let` at the top of the class, for
example `static let enabledDefaultsKey = "clipboard-history-enabled"`.

Repo conventions that apply (from `CLAUDE.md`):

- A comment says **why**, never what the next line does. No commented-out code.
- Never hand-format Swift; run `make format`.
- `.swiftlint.yml` thresholds are a ratchet. Do not raise one.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| nanoui tests, format check, bundle | `make test-nanoui` | exit 0 |
| Swift tests | `make test` | exit 0 |
| Focused Swift tests | `swift test --filter ClipboardCaptureServiceTests` | all pass |
| Swift format | `make format` | exit 0 |
| Repo gates | `make check` | exit 0 |

## Scope

**In scope** (the only files you should modify):

- `frontends/nanoui/src/clipboard.zig`
- `frontends/nanoui/src/main.zig`
- `frontends/nanoui/src/tests.zig`
- `Sources/Floodlight/Search/ClipboardCaptureService.swift`
- `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`

**Out of scope** (do NOT touch):

- The data model. Do not introduce a "multi-file entry" kind. One entry per
  file stays.
- `Budget` values and `keepWithinBudget` in `clipboard.zig`.
- `Sources/FloodlightEngine/**` — the Swift store is not changed here.
- Wrapping captures in a SQL transaction. With the 100-file cap it is not
  needed, and `keepWithinBudget` deletes image files, which a rollback could
  not restore.
- `docs/adr/**`, `README.md`.

## Git workflow

- The repository was on a detached `HEAD` with unrelated uncommitted changes,
  including in the three Zig files. Do not stash, reset, or discard them.
- Branch: `advisor/003-bulk-file-copy-cap`
- Conventional Commits, for example `fix(nanoui): ...` and
  `fix(clipboard): ...`. One commit per frontend is fine.
- Stage only your own hunks. If you cannot separate them from pre-existing
  uncommitted changes in the same file, do not commit; report that instead.
- Do NOT push or open a PR.

## Steps

### Step 1: Cap files per copy in the Zig app

In `clipboard.zig`, add next to `max_text_bytes`:

```zig
/// A copy of more files than this is a bulk file operation, not something to
/// paste back from history, and recording it would push everything else out.
pub const max_file_count = 100;
```

In `fn captures`, replace `if (out.items.len > 0) return out.items;` with:

```zig
    if (out.items.len > max_file_count) return &.{};
    if (out.items.len > 0) return out.items;
```

Returning nothing for the whole copy (not falling through to its picture or
text) matches the function's documented rule for content past a cap.

**Verify**: `make test-nanoui` → exit 0.

### Step 2: Cap files per copy in the Swift app

In `ClipboardCaptureService.swift`, add a constant with the other `static let`
declarations:

```swift
    /// A copy of more files than this is a bulk file operation, not something
    /// to paste back from history.
    static let maxFileCountPerCopy = 100
```

In `poll()`, make the file branch:

```swift
        if !filePaths.isEmpty {
            guard filePaths.count <= Self.maxFileCountPerCopy else { return }
            for path in filePaths {
                store.recordFile(path: path, sourceAppBundleID: bundleID)
            }
            return
        }
```

**Verify**: `swift build` → exit 0.

### Step 3: Prune hourly in the Zig app

In `main.zig`:

1. Add near the other timer constants: `const prune_ms = 60 * 60 * 1000;`
2. Add inside `const Shell`, after `compactTick`:

```zig
    /// The app runs for weeks, so retention enforced only at launch would let
    /// entries outlive their thirty days by however long it stays open.
    fn pruneTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(prune_ms, s, pruneTick);
        s.store.prune(clipboard.wallClock(), clipboard.retention_days) catch |err| std.log.err("clipboard prune: {s}", .{@errorName(err)});
        if (s.panel.mode == .clipboard) s.panel.board.list.markStale();
    }
```

3. Where `Shell.captureTick` and `Shell.compactTick` are first armed in
   `main`, add: `nanoui.App.after(prune_ms, &shell, Shell.pruneTick);`

Keep the existing launch-time `shell.store.prune(...)` call in `main`.

**Verify**: `make test-nanoui` → exit 0 (its bundle build is what compiles the
shell), and `rg -n "pruneTick" frontends/nanoui/src/main.zig` → 3 matches.

### Step 4: Write the tests (see Test plan), then run all gates

**Verify**: `make format && make check && make test && make test-nanoui` → all
exit 0.

## Test plan

Zig, in `frontends/nanoui/src/tests.zig`. The pattern is the existing test
that builds a `FakePasteboard` with `.files = &.{ "/a/x.pdf", "/a/y.pdf", "/a/x.pdf" }`
and calls `store.capture(a, fake.pasteboard(), .{ .bundle_id = "com.apple.finder", .name = "Finder" }, 1)`
(find it with `rg -n '"/a/x.pdf"' frontends/nanoui/src/tests.zig`). It uses
`TmpStore.init()`, `openMemory(&ts)`, and an arena.

1. `"a copy of more files than the cap records nothing and keeps the history it found"`
   - add one text entry first (`store.add(.{ .text = "kept" }, "", "Notes", 1)`)
   - build `clipboard.max_file_count + 1` distinct paths in the arena (for
     example `std.fmt.allocPrint(a, "/bulk/{d}.txt", .{i})`) and capture them
     through a `FakePasteboard` whose `.string` is also set
   - expect `capture` to return `false`
   - expect `store.list(a, "")` to have exactly 1 row with text `"kept"`
2. `"a copy of exactly the cap records every file"`
   - same shape with `clipboard.max_file_count` paths; expect `capture` to
     return `true` and `store.list(a, "")` to have `max_file_count` rows.
     (`list` returns at most 1,000 unpinned rows, so 100 is safe.)

Swift, in `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`, modeled
on the existing `pollRecordsEachCopiedFileAsItsOwnEntry`:

3. `pollSkipsACopyOfMoreFilesThanTheCap` — `setContents` with
   `ClipboardCaptureService.maxFileCountPerCopy + 1` distinct absolute paths
   (for example `"/Users/f/bulk/\(i).txt"`), `poll()`, expect
   `harness.store.isEmpty`.
4. `pollRecordsACopyOfExactlyTheCap` — same with exactly the cap; expect
   `harness.store.count == ClipboardCaptureService.maxFileCountPerCopy`.

Tests 1 and 3 must fail before Steps 1 and 2 are applied and pass after.

The hourly prune timer lives in the shell, which tests cannot construct. The
bundle build in `make test-nanoui` is its only automated check.

Verification: `make test-nanoui` and `make test` → exit 0, including 4 new
tests.

## Done criteria

- [ ] `make test-nanoui` exits 0
- [ ] `make test` exits 0
- [ ] `make check` exits 0
- [ ] `rg -n "max_file_count" frontends/nanoui/src/clipboard.zig` returns 2 matches
- [ ] `rg -n "maxFileCountPerCopy" Sources/Floodlight/Search/ClipboardCaptureService.swift` returns 2 matches
- [ ] `rg -n "pruneTick" frontends/nanoui/src/main.zig` returns 3 matches
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- An excerpt in "Current state" cannot be found by its text.
- `s.store`, `s.panel.board.list.markStale`, or `s.panel.mode` is not
  reachable from a `Shell` method the way `captureTick` uses them.
- An existing test asserts that more than 100 files in one copy are recorded.
  That would mean the cap contradicts an intended behaviour.
- `make check` fails on a SwiftLint length threshold. Do not raise it.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The cap value (100) and the choice to record nothing above it are judgment
  calls. The alternative is recording the first 100. A reviewer who prefers
  that should change `captures` and `poll()` together so both frontends agree.
- Re-copying the same set of files still adds a second set of entries, because
  both stores only collapse a repeat of the single newest entry.
- The hourly prune is not covered by a unit test. If the shell ever becomes
  constructible in tests, add one.
- The Swift app gets its own hourly prune in plan 001.
