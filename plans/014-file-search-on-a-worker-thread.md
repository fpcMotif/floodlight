# Plan 014: File search runs on a worker thread and the main thread never waits for it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/panel.zig frontends/nanoui/src/search.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig core/src`
> **Extra check for this plan**: the nanoui files had uncommitted changes
> when this plan was written, and plans 008 and 009 edit `panel.zig` and
> `search.zig` first. Line numbers will be off. Find each excerpt with `rg`
> by its text.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/006-nanoui-benchmarks-cover-real-paths.md`,
  `plans/009-keystroke-stats-only-visible-rows.md`
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher. A
keystroke searches the apps and then the file index (`core/`). The file
search is synchronous. The design record `docs/adr/0010-zig-file-index-core.md`
measures it at 2.5–4.5 ms for a name query and 70 ms for a path query on
one million files.

The panel has a 4 ms budget: when the last file search was slower, it
shows app rows first and runs the file search on the next run-loop turn.
That next turn is still the main thread, so the next key press waits for
the whole search. The panel also runs a calibration search for the letter
`e`, which matches almost every file, on the main thread at launch and
after every index rebuild.

After this plan the file search runs on one worker thread. App rows appear
at once, file rows land when ready, a stale answer is dropped, and the
calibration search is gone.

## Current state

Files:

- `frontends/nanoui/src/panel.zig` — the search panel.
- `frontends/nanoui/src/search.zig` — the catalog; `Catalog.rank`.
- `frontends/nanoui/src/main.zig` — app shell; owns threads and timers.
- `core/src/search.zig`, `core/src/file_index.zig` — the file index. Read
  only.

The budget gate (`panel.zig`, `answer`):

```zig
        if (text.len == 0) {
            p.base_rows = try copyRows(a, p.frequentApps());
        } else if (p.catalog.files == null) {
            p.base_rows = try p.catalog.query(a, text);
        } else if (force_files or p.file_search_s <= file_search_budget_s) {
            const started = p.clock.now();
            p.base_rows = try p.catalog.query(a, text);
            p.file_search_s = p.clock.now() - started;
        } else {
            p.base_rows = try p.catalog.queryApps(a, text);
            p.files_due = true;
        }
```

with `pub const file_search_budget_s: f64 = 0.004;` and
`const calibration_query = "e";`.

The deferred path (`panel.zig`):

```zig
    pub fn landFiles(p: *Panel) void {
        if (!p.files_due) return;
        p.files_due = false;
        const text = p.field.text();
        if (p.mode != .search or !std.mem.eql(u8, text, p.list.answered())) return;
        if (p.list.selected != 0) p.list.markStale();
        _ = p.answer(text, true) catch |err| return p.failSearch(err);
        p.completion = p.computeCompletion();
    }

    pub fn calibrateFileSearch(p: *Panel) void {
```

`refresh` ends with `if (p.files_due) p.hooks.search_files(p.hooks.ctx);`.
The hook's default is a no-op (`noSearchFiles`), which tests and the
benchmark use.

The shell's side (`main.zig`):

```zig
    fn searchFiles(ctx: ?*anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.landing_files) return;
        s.landing_files = true;
        nanoui.App.after(0, s, landFiles);
    }

    fn landFiles(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.landing_files = false;
        s.panel.landFiles();
        if (!s.presence.isHidden()) s.panel_window.redraw();
    }
```

Calibration call sites (`main.zig`): `shell.panel.calibrateFileSearch();`
in `main`, and in `indexLanded`:

```zig
        s.panel.indexing = s.files.busy();
        if (s.files.adopt()) {
            s.panel.calibrateFileSearch();
            // The rows answer the old index: ask again.
            s.panel.list.markStale();
            if (!s.presence.isHidden()) s.panel.refresh();
        }
```

The catalog (`search.zig`). `query` ranks apps and files; `queryApps` ranks
apps only. Both call `rank(arena, text, include_files)`, which calls the
core inline:

```zig
            var hits: [max_rows]core.search.Hit = undefined;
            const n = core.search.search(v, trimmed, &hits);
```

(Plan 009 may have changed the buffer to `2 * max_rows`.)

The file index's thread rule (`core/src/file_index.zig`):

```zig
    /// The current index; query thread only, like `adopt`.
    pub fn view(fi: *const FileIndex) ?index.View {
    ...
    /// Swaps in the newest finished index and unmaps the old one; true when
    /// the index changed. Call it on the thread that runs queries.
    pub fn adopt(fi: *FileIndex) bool {
```

`adopt` unmaps the old index. A search that still reads the old `View`
after that reads unmapped memory. This is the main hazard of this plan.

The pattern for late results with a sequence number already exists for web
suggestions (`panel.zig`): `p.suggest_seq`, `p.pending_suggest_seq`, and
`receiveSuggestionsFor(seq, query, items)`. The list accepts late rows
through `replaceRows`.

The pattern for a worker posting back to the main thread (`main.zig`):
`std.Thread.spawn(...)`, then `objc.dispatchMain(ctx, callback)`.

Conventions: comments say why, never what. Domain terms from `CONTEXT.md`:
**Search Execution** ("the live attempt to answer the current query ...
ends when superseded"), **Search Source**, **Search Snapshot**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Core tests | `make test-core` | exit 0 |
| Thread sanitizer for Zig, if the build supports it | `cd frontends/nanoui && <zig> build test -Dsanitize-thread` | see step 6 |

## Scope

**In scope**:

- `frontends/nanoui/src/panel.zig`
- `frontends/nanoui/src/search.zig`
- `frontends/nanoui/src/main.zig`
- `frontends/nanoui/src/tests.zig`
- `frontends/nanoui/src/bench.zig` (only if a metric needs the synchronous
  path selected explicitly)

**Out of scope**:

- Everything under `core/`. The core still spawns its own helper threads
  for indexes above 200,000 files; leave that.
- What the index contains. Excluding `~/Library` and package contents is an
  open product decision recorded in `plans/README.md`.
- Web suggestions and the clipboard board.

## Git workflow

- Branch: `advisor/014-file-search-on-a-worker-thread`.
- Commit style: `perf(nanoui): file search runs on a worker thread`.
- Commit after each step.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Let the catalog rank with hits it is given

In `search.zig`, split `rank` so the file hits can come from outside:

- `pub fn searchFiles(view: core.index.View, text: []const u8, out: []core.search.Hit) usize`
  — trims the text and calls `core.search.search`. No allocation, no access
  to the catalog. Safe on any thread that holds a valid `View`.
- `pub fn queryWithHits(cat, arena, text, view, hits) ![]Row` — what
  `query` does today, using the given hits and view to build file rows.
- `query` stays, and calls `searchFiles` then `queryWithHits`.

Use the exact type name of the view from `core/src/index.zig`.

**Verify**: `make test-nanoui` → exit 0 with no test changed.

### Step 2: Add the worker to the shell

In `main.zig` add a `FileSearcher` struct owned by `Shell`: one thread
started at launch, a mutex, a condition variable, and one request slot
holding a sequence number, a copy of the query text (fixed buffer, 256
bytes; longer queries are truncated for the file search only), and the
`View` to search. The worker loop:

1. wait until the slot holds a request newer than the last one served;
2. copy the request out and unlock;
3. run `search.searchFiles` into a hit buffer the worker owns;
4. lock, store the result (sequence number, hit count, hits) in a result
   slot, mark itself idle, unlock;
5. `objc.dispatchMain(shell, filesLanded)`.

A newer request overwrites the slot, so only the latest query is searched
after the one in flight. Set the worker's quality of service to
user-interactive with `pthread_set_qos_class_self_np` (see `bench.zig` for
the declaration).

**Verify**: `make test-nanoui` → exit 0.

### Step 3: Never unmap an index the worker is reading

The main thread calls `s.files.adopt()` in `indexLanded`. Guard it: when
the worker is busy or a request is waiting, set `adopt_pending = true` and
return without adopting. In `filesLanded`, after taking the result, if
`adopt_pending` is set and the worker is idle with no waiting request, run
the adopt path then. The `View` given to the worker is always taken on the
main thread from `s.files.view()` at request time.

**Verify**: `make test-nanoui` → exit 0, and the new test "an index is not
swapped while a search runs" passes.

### Step 4: Make the panel ask and receive

In `panel.zig`:

- Add `file_seq: u64` and `async_files: bool = false` to `Panel`.
- Change the hook to
  `search_files: *const fn (?*anyopaque, seq: u64, text: []const u8) void`.
- In `answer`: when `async_files` is true and the catalog has files, show
  `queryApps` rows, increment `file_seq`, and set `files_due`. `refresh`
  then calls the hook with the sequence number and text. When
  `async_files` is false, call `catalog.query` inline as the
  `catalog.files == null` branch does today. Tests and the benchmark keep
  that synchronous path.
- Replace `landFiles()` with
  `landFiles(p, seq, view, hits)`: return when `seq != p.file_seq`, when
  the mode is not search, or when the field text differs from
  `p.list.answered()`. Otherwise build rows with `queryWithHits`, allocated
  from `p.list.allocator()`, and install them with the same calls
  `landFiles` used before. Recompute the completion.
- Delete `calibrateFileSearch`, `calibration_query`, `file_search_s` and
  `file_search_budget_s`.

In `main.zig`: set `shell.panel.async_files = true`, implement the hook by
filling the worker's request slot, call `p.landFiles(...)` from
`filesLanded` and redraw, and delete both `calibrateFileSearch` calls,
`landing_files`, and the old `searchFiles`/`landFiles` pair.

**Verify**: `make test-nanoui` → exit 0.
`rg -n 'calibrat|file_search_budget_s|file_search_s' frontends/nanoui/src`
→ no matches.

### Step 5: Keep rows steady when files land

When file rows land, the selection must stay on the row the user chose.
`replaceRows` keeps the selected row by key, or its place when that row is
gone. Use it. When the selection is still on row 0 and the user has not
moved it, the top row may change; that matches today's behavior.

**Verify**: the tests "late file rows keep the selection" and "a late
answer for an old query is dropped" pass.

### Step 6: Check for races

Run the tests under a thread sanitizer if `build.zig` offers one
(`rg -n 'sanitize' frontends/nanoui/build.zig`). If it does not, state that
in your report and review by hand: every field of `FileSearcher` that both
threads touch must be read and written under the mutex.

**Verify**: sanitizer run clean, or the hand review written in the report.

## Test plan

Add to `tests.zig`. Tests drive the panel synchronously: call the hook's
effect by hand, as the web-suggestion tests do with
`receiveSuggestionsFor` (find them with
`rg -n 'receiveSuggestionsFor' frontends/nanoui/src/tests.zig`). Use
`tmpCatalog` for a real file index.

- "app rows show before file rows land": `async_files = true`, type a
  query, expect app rows and no file rows; call `landFiles` with hits from
  `search.searchFiles`; expect file rows.
- "a late answer for an old query is dropped": type `re`, capture seq, type
  `rea`, land the `re` answer, expect the rows unchanged.
- "late file rows keep the selection": select row 2 of the app rows, land
  files, expect the same row selected.
- "an index is not swapped while a search runs": test the guard as a small
  pure function or state struct (busy, waiting, pending) so it needs no
  real thread.
- "the worker searches only the newest waiting query": drive
  `FileSearcher` with a fake search function that blocks on a semaphore;
  post three requests; release; expect the first and the third to run and
  the second to be skipped.
- "the synchronous path still returns file rows": `async_files = false`,
  type a query, expect file rows at once.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including 6 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `make test-core` exits 0 (nothing under `core/` changed).
- [ ] `rg -n 'calibrat|file_search_budget_s' frontends/nanoui/src` returns
      no matches.
- [ ] `git status --short core` prints nothing.
- [ ] The three original `FLOODLIGHT_BENCH` budgets are met.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Plans 006 or 009 have not landed.
- The `View` type holds anything other than slices into the mapped file
  and plain values, so it cannot be handed to another thread by value.
- A test shows file rows from an old query on screen.
- Any crash or sanitizer report that involves the mapped index.
- The app must join the worker at exit and doing so hangs.
- A step's verification fails twice.

## Maintenance notes

- The rule after this plan: `adopt` runs on the main thread, and only
  while the worker is idle with nothing waiting.
- The core still creates up to 7 threads per query above 200,000 files. A
  persistent pool inside the core is the next step, and it belongs to
  `core/`.
- The first keystroke after memory pressure can page the index back in
  from disk. That now happens on the worker.
- Reviewer: type fast with a large home folder, rebuild the index while
  typing (grant Full Disk Access, or relaunch), and watch for stale rows
  or a crash.
