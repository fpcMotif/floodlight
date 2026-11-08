# Plan 006: The nanoui benchmarks measure a built frame, file rows, the store, and a realistic hidden session

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/bench.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig scripts/bench-nanoui-memory.sh`
> **Extra check for this plan**: `main.zig`, `tests.zig` and
> `scripts/bench-nanoui-memory.sh` had uncommitted changes when this plan was
> written, and the excerpts below come from that working tree, not from commit
> `64cc313`. Line numbers can be off. Find each excerpt with `rg` by its text
> and confirm it before you edit.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none. Plans 007, 008, 009 and 014 depend on this plan.
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher with
clipboard history. It has two benchmarks. Neither measures what a user feels.

The latency benchmark (`src/bench.zig`) reports 1.79 µs p50 per keystroke. It
gets that number with no file index, no clipboard store, stub hooks, and no
frame build. The metric named `hotkey_to_laid_out_frame` builds its frame
outside the timer. The memory benchmark turns Session Retention off and seeds
300 small rows, so it never runs the path that real users hit.

Plans 007, 008, 009 and 014 each remove real work. Without this plan they
have no number to beat and no gate to keep the gain. After this plan the
benchmarks report the cost of a keystroke through a built frame with file
rows and a store, and the hidden footprint after a realistic session.

## Current state

Files:

- `frontends/nanoui/src/bench.zig` — in-process latency benchmark, 337 lines.
- `frontends/nanoui/src/main.zig` — app shell. Holds the memory session
  (`memoryStep`, `memoryIdle`) and the seed (`seedMemoryHistory`).
- `frontends/nanoui/src/tests.zig` — all nanoui tests. Has `tmpCatalog`, a
  helper that builds a real file index in a temp folder.
- `scripts/bench-nanoui-memory.sh` — runs the memory session and checks the
  idle budget.

The keystroke metric uses no store and no frame (`bench.zig`,
`measureKeystrokeToPublication`):

```zig
    var p = panel_mod.Panel.init(gpa, &cat, null, NoHooks.hooks(null));
    ...
        const t0 = nowNs();
        p.field.set(q);
        p.refresh();
        s.* = nowNs() - t0;
```

The summon metric times only `entrance.search`. The frame is built in
`presentThenHide`, before `t0` (`bench.zig`, `measureHotKeyToLaidOutFrame`):

```zig
        try presentThenHide(&p, &tester, &entrance, keystroke_queries[i % keystroke_queries.len]);
        const t0 = nowNs();
        entrance.search(false, false);
        s.* = nowNs() - t0;
```

The stub hooks return no icon and a fixed date (`bench.zig`, `NoHooks`):

```zig
    fn icon(_: ?*anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
    fn date(_: ?*anyopaque, _: i64, _: std.mem.Allocator) []const u8 {
        return "Today at 9:41 AM";
    }
```

Budgets (`bench.zig`). Issue #143 set these three; do not change them:

```zig
pub const Budgets = struct {
    pub const keystroke_to_publication_p99_us: f64 = 10.0;
    pub const hotkey_to_laid_out_frame_p99_us: f64 = 10.0;
    pub const return_to_action_p99_us: f64 = 10.0;
};
```

Output lines have this shape, and `scripts/test-nanoui.sh` runs the
benchmark with `zig build bench --release`:

```
FLOODLIGHT_BENCH metric=keystroke_to_publication apps=200 runs=2000 p50_us=1.79 p99_us=6.58 budget_p99_us=10.00
```

The memory script disables retention (`scripts/bench-nanoui-memory.sh`):

```sh
HOME="$scratch_home" "$bin" --floodlight-memory-seed >"$log" 2>&1
HOME="$scratch_home" "$bin" --floodlight-memory-session -sessionRetentionSeconds 0 >"$log" 2>&1 &
```

The seed is 300 texts and 4 pictures (`main.zig`, `seedMemoryHistory`):

```zig
    for (0..300) |i| {
        const text = std.fmt.bufPrint(&buf, "{s} ({d})", .{ texts[i % texts.len], i }) catch continue;
        _ = store.add(.{ .text = text }, "com.apple.Safari", "Safari", now - @as(f64, @floatFromInt(300 - i)) * 72) catch {};
    }
```

The session opens search, types `cal`, opens the board, then hides
(`main.zig`, `memoryStep`, steps 0–4). It never types in the board and never
moves the selection.

Measured on 2026-11-17, Apple silicon, before any change:

| Metric | Value |
|---|---|
| keystroke_to_publication | p50 1.79 µs, p99 6.58 µs |
| hotkey_to_laid_out_frame | p50 0.46 µs, p99 3.92 µs |
| return_to_action | p50 0.71 µs, p99 5.38 µs |
| idle footprint, 3 cycles | 58.8, 59.0, 62.8 MB (budget 60, fails) |
| open footprint | 181–194 MB |

Conventions:

- Domain terms (`CONTEXT.md`): **Search Session**, **Session Retention**,
  **Clipboard History**, **Clipboard Entry**. Use these words in names.
- Comments say why, never what. `make check` rejects commented-out code.
- A test's name is a sentence about behavior, for example
  `test "the board lists history, inspects the selection, and filters"`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Memory benchmark | `make bench-nanoui-memory` | prints `FLOODLIGHT_MEMORY` lines |
| Bench only | `cd frontends/nanoui && "$(. ../../scripts/tools.sh; resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)" build bench --release` | prints `FLOODLIGHT_BENCH` lines |

`make bench-nanoui-memory` exits 1 today because idle footprint exceeds the
budget. That is the known baseline, not a failure of this plan.

## Scope

**In scope**:

- `frontends/nanoui/src/bench.zig`
- `frontends/nanoui/src/main.zig` (only `seedMemoryHistory`, `memoryStep`,
  `memoryIdle`, `memory_*` constants)
- `frontends/nanoui/src/tests.zig` (only the bench smoke test and new tests)
- `scripts/bench-nanoui-memory.sh`

**Out of scope**:

- `panel.zig`, `search.zig`, `board.zig`, `clipboard.zig`, `mac.zig` — this
  plan measures; it must not make anything faster.
- The three existing budgets and the three existing metric names.
- `scripts/test-nanoui.sh`.

## Git workflow

- Branch: `advisor/006-nanoui-benchmarks` from the current `HEAD`.
- Commit style, from `git log`: `perf(nanoui): instant reopen within the 10 µs budgets (#143)`.
  Use `test(nanoui): ...` or `perf(nanoui): ...`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Add `keystroke_to_built_frame` with file rows and a store

In `bench.zig` add `pub fn measureKeystrokeToBuiltFrame(gpa, runs) !Stats`.

1. Build a catalog with `populateCatalog(&cat, catalog_app_count)`.
2. Give it a real file index. `tests.zig` has `fn tmpCatalog(tmp, buf, files)`
   that creates files in a temp folder and builds a
   `core.file_index.FileIndex`. Read it and do the same in `bench.zig` with
   2,000 empty files named from `app_stems` plus a number and the extensions
   `.pdf`, `.txt`, `.png`, `.zig`. Set `cat.files = &files`.
3. Open a store with `clipboard.Store.open(":memory:", scratch_dir)` and pass
   `&store` to `Panel.init`. Record each query in `keystroke_queries` once
   with `store.recordQuery(.search, q, 1)` so history completion has rows.
4. Use hooks whose `describe_date` calls `mac.relativeDate` and whose
   `app_icon` returns null. Icons are measured in step 2.
5. Create a `ui.Tester` as `measureReturnToAction` does.
6. Warm up over `keystroke_queries`, then time this per sample:

```zig
        const t0 = nowNs();
        p.field.set(q);
        p.refresh();
        tester.frame();
        s.* = nowNs() - t0;
```

Print it from `main` in the existing format with `files=2000` added. Use
`runs=200`, because each sample is far slower than the existing metrics.

**Verify**: bench command → a line starting
`FLOODLIGHT_BENCH metric=keystroke_to_built_frame`.

### Step 2: Add `first_frame_with_icons`

Add `pub fn measureFirstFrameWithIcons(gpa, runs) !Stats`. Same setup as
step 1, but `app_icon` calls `mac.iconPng(gpa, path, 92)` with no cache and
frees nothing until the end. Time one `p.field.set(q); p.refresh();
tester.frame();` per sample, with `runs=20`. This is the cost of the first
frame after a query brings new paths. Print it as
`metric=first_frame_with_icons`.

**Verify**: bench command → a line starting
`FLOODLIGHT_BENCH metric=first_frame_with_icons`.

### Step 3: Add `hotkey_to_built_frame`

Add `pub fn measureHotKeyToBuiltFrame`. Copy `measureHotKeyToLaidOutFrame`
and put `tester.frame()` inside the timed span, after `entrance.search`. Do
not change `measureHotKeyToLaidOutFrame`. Print it as
`metric=hotkey_to_built_frame`.

**Verify**: bench command → a line starting
`FLOODLIGHT_BENCH metric=hotkey_to_built_frame`.

### Step 4: Set budgets for the three new metrics

Run the bench five times. For each new metric take the largest p99 seen,
multiply by 3, and round up to two significant digits. Add these as new
constants in `Budgets`, print them as `budget_p99_us`, and fail the run when
a p99 exceeds its budget, exactly as the existing three do. Extend
`withinBudgets` only if its callers in `tests.zig` still compile; otherwise
add a second function `withinFrameBudgets`.

Record the five p99 values per metric in your final report.

**Verify**: `make test-nanoui` → exit 0.

### Step 5: Seed a realistic Clipboard History

In `main.zig`, `seedMemoryHistory`: raise the text count from 300 to 5,000.
Make every 50th text 30,000 bytes long (repeat a sentence). Add each of the
4 pictures 50 times with a distinct `name` and a timestamp one second apart,
so the store holds 200 picture entries. `Store.add` drops a repeat of the
newest entry only, so alternate the 4 pictures.

**Verify**: run the seed by hand with a scratch home, then
`sqlite3 "$scratch/Library/Application Support/"*/clipboard.sqlite3 'select count(*) from entries'`
→ `5000` (the entry budget caps unpinned rows at 5,000).

### Step 6: Exercise the board in the memory session

In `main.zig`, `memoryStep`: after the step that opens the board, add steps
that set the field to `meeting`, call `s.panel.refresh()`, then move the
board selection down 20 times with `s.panel.board.list.move(true)` and
redraw. Raise `memory_steps` to match. Keep the `open` and `idle` markers.

**Verify**: `make bench-nanoui-memory` → three `phase=open` and three
`phase=idle` lines.

### Step 7: Add a retained-then-expired run to the script

In `scripts/bench-nanoui-memory.sh`, after the existing run, start a second
session with `-sessionRetentionSeconds 2` in a fresh scratch home, seeded
the same way. Sample it 4 seconds after the final idle marker, so the
retention timer has expired. Print the sample as
`FLOODLIGHT_MEMORY phase=expired footprint_mb=...` with the largest
categories. Apply the same idle budget to it.

**Verify**: `make bench-nanoui-memory` → output contains `phase=expired`.

## Test plan

- Extend the bench smoke test in `tests.zig` (find it with
  `rg -n 'bench.measureKeystrokeToPublication' frontends/nanoui/src/tests.zig`)
  to call each new measure function with 4 runs and expect `runs == 4` and
  `p99_ns >= p50_ns`.
- Verification: `make test-nanoui` → all tests pass, including the extended
  smoke test.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] The bench prints six `FLOODLIGHT_BENCH` lines, three of them new.
- [ ] `make bench-nanoui-memory` prints `phase=expired`.
- [ ] `git diff 64cc313 -- frontends/nanoui/src/bench.zig | rg 'keystroke_to_publication_p99_us: f64 = 10.0'` shows no changed line (the old budgets are untouched).
- [ ] `git status --short` lists only in-scope files.
- [ ] Your report lists the measured p50 and p99 of each new metric and the
      idle and expired footprints.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `tmpCatalog` does not exist in `tests.zig`, or building a file index needs
  an API you cannot find in `core/src/file_index.zig`.
- `mac.relativeDate` or `mac.iconPng` crashes without a running `NSApp`.
  Report it; do not stub it out, because the real call is the point.
- A new metric varies by more than 5x between runs.
- The seed makes `make bench-nanoui-memory` run longer than 5 minutes.

## Maintenance notes

- The memory budget fails before and after this plan. Plan 007 is the fix.
  Do not raise `FLOODLIGHT_NANO_IDLE_BUDGET_MB` here.
- Plans 008, 009 and 014 must lower `keystroke_to_built_frame` and
  `first_frame_with_icons`. Each should tighten the budget it improves.
- Reviewer: check that the new metrics time the frame build, and that the
  icon metric does not cache across samples.
