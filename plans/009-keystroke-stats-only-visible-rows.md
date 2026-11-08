# Plan 009: A keystroke reads file size and date only for rows in view, and bundle contents stop using result slots

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/search.zig frontends/nanoui/src/panel.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and plan 008 edits `panel.zig` and `search.zig`
> before this plan runs. Line numbers will be off. Find each excerpt with
> `rg` by its text.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/008-search-builds-only-visible-rows.md`
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher. On
every keystroke the search ranks up to 80 rows and then calls `stat()` on
each file and folder row, on the main thread, before any result is shown.
Seven rows are visible. On a local disk each call is cheap; on a network
volume, an external disk or an iCloud placeholder it can block for
milliseconds, and it runs up to 79 times.

Separately, the file index returns its best 80 hits and the frontend then
drops every hit inside an `.app` bundle. A query such as `Info.plist` can
therefore return few or no file rows, because bundle contents used the
slots.

After this plan, size and date are read when a row first comes into view,
and bundle contents no longer cost result slots.

## Current state

Files:

- `frontends/nanoui/src/search.zig` — the catalog. `Catalog.rank` builds the
  rows; `stamp` reads size and date.
- `frontends/nanoui/src/panel.zig` — the search panel; `rowView` and
  `subtitleLine` draw a row.
- `core/src/search.zig` — the file index search. Read only.

`Catalog.rank` (`search.zig`). The file hits, the bundle filter and the
stamp loop:

```zig
        if (if (cat.files) |fi| if (include_files) fi.view() else null else null) |v| {
            var hits: [max_rows]core.search.Hit = undefined;
            const n = core.search.search(v, trimmed, &hits);
            const root = v.root;
            for (hits[0..n]) |h| {
                var buf: [4096]u8 = undefined;
                const rel = v.relativePath(h.id, &buf) orelse continue;
                const path = try std.fs.path.join(arena, &.{ root, rel });
                // Bundles are apps, listed above from the catalog; their insides are no one's.
                if (std.mem.endsWith(u8, rel, ".app") or std.mem.indexOf(u8, rel, ".app/") != null) continue;
                try rows.append(arena, .{
```

```zig
        const ranked = try best(arena, rows.items, max_rows - extra);
        for (ranked) |*r| if (r.kind != .app) stamp(arena, r);
```

`stamp` (`search.zig`):

```zig
fn stamp(arena: std.mem.Allocator, r: *Row) void {
    const z = arena.dupeSentinel(u8, r.path, 0) catch return;
    var st: std.c.Stat = undefined;
    if (std.c.stat(z, &st) != 0) return;
    r.modified = st.mtime().sec;
    if (r.kind == .file) r.size = @intCast(st.size);
}
```

The core search keeps at most 256 hits per call (`core/src/search.zig`, the
`TopK` type). `max_rows` in the frontend is 80.

After plan 008, `Row` has a `modified_label` field that `Panel.answer`
fills for every row whose `modified` is set, and `resultList` builds only
the rows in view. Confirm both:
`rg -n 'modified_label' frontends/nanoui/src` must find matches in
`search.zig` and `panel.zig`.

The list keeps two slices (`list.zig`): `rows: []const Item` and
`visible: []Item`. `visible` holds copies and is mutable. A filter change
rebuilds `visible` from `rows`.

Conventions: comments say why, never what. Keep the existing comment
"Bundles are apps, listed above from the catalog; their insides are no
one's." with the code it describes.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Bench only | `cd frontends/nanoui && "$(. ../../scripts/tools.sh; resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)" build bench --release` | `FLOODLIGHT_BENCH` lines |

## Scope

**In scope**:

- `frontends/nanoui/src/search.zig` (`Catalog.rank`, `stamp`, `Row`)
- `frontends/nanoui/src/panel.zig` (`rowView`, `subtitleLine`, the label
  fill added by plan 008)
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- `core/` — do not change the file index or its search.
- `list.zig`, `board.zig`, `main.zig`.
- Excluding bundles at index time. That changes what the index stores and
  needs a product decision.

## Git workflow

- Branch: `advisor/009-keystroke-stats-only-visible-rows`.
- Commit style: `perf(nanoui): a keystroke stats only the rows in view`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Check what reads `size` and `modified`

Run `rg -n '\.modified|\.size\b|modified_label' frontends/nanoui/src/panel.zig frontends/nanoui/src/search.zig frontends/nanoui/src/list.zig`.
Every reader must be drawing code (`subtitleLine`) or the plan 008 label
fill. If sorting, filtering or an action reads them, STOP.

**Verify**: your notes list each reader and its function.

### Step 2: Stop stamping at rank time

In `search.zig`: remove the `for (ranked) |*r| ... stamp(arena, r);` loop
from `rank`. Make `stamp` public and add a `stamped: bool = false` field to
`Row`. `stamp` sets `stamped = true` whether or not `stat` succeeds, so a
missing file is not retried every frame.

**Verify**: `make test-nanoui` fails only in tests that expect a size or a
date on a row. Note which ones.

### Step 3: Stamp a row when it first comes into view

In `panel.zig`, `rowView`: before drawing, if the row at
`p.list.visible[i]` is a file or folder and is not stamped, call
`search.stamp` with `p.list.allocator()`, fill `modified_label` with
`p.hooks.describe_date` using the same allocator, and write the result back
to `p.list.visible[i]`. Draw from the updated row. Remove the label fill
that plan 008 added to `answer`, so there is one place that fills it.

`p.list.allocator()` returns memory that lives until the next query, which
is the lifetime a row needs.

**Verify**: `make test-nanoui` → exit 0, including the tests noted in
step 2.

### Step 4: Skip bundle contents before they cost a slot

In `rank`: ask the core for `2 * max_rows` hits (declare the buffer as
`[2 * max_rows]core.search.Hit`), move the `.app` check before
`std.fs.path.join`, and stop appending file rows once `max_rows` have been
accepted. Keep the comment with the check.

**Verify**: `make test-nanoui` → exit 0, and the new bundle test passes.

### Step 5: Measure

Run the bench three times.

**Verify**: median p50 of `keystroke_to_built_frame` is lower than before
this plan. Report both values.

## Test plan

Add to `tests.zig`, modeled on the tests that use `tmpCatalog` (a helper
that builds a real file index in a temp folder):

- "a keystroke stats only the rows in view": a temp folder with 40 matching
  files, one query, one frame. Expect at most 12 rows in
  `p.list.visible` to have `stamped == true`.
- "a row scrolled into view shows its size and date": move the selection
  down 30 times, build a frame, expect the selected row to be stamped.
- "bundle contents do not use result slots": a temp folder with
  `Fake.app/Contents/` holding 100 files named `match-N.txt` and, outside
  it, 5 files named `match-N.txt`. Query `match`. Expect 5 file rows.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including 3 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `rg -n 'stamp\(' frontends/nanoui/src/search.zig` shows the
      definition only, no call inside `rank`.
- [ ] `rg -n 'describe_date' frontends/nanoui/src/panel.zig` shows one call
      site.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Plan 008 has not landed (`rg -n 'modified_label' frontends/nanoui/src`
  finds nothing).
- Step 1 finds a reader of `size` or `modified` outside drawing code.
- `p.list.visible` is not mutable from `rowView`.
- An existing test fails twice for a reason other than a missing size or
  date at rank time.

## Maintenance notes

- A filter change rebuilds `visible` from `rows`, so rows are stamped again
  after a chip switch. That is at most the rows in view.
- If a future feature sorts by date or size, it must stamp all rows first,
  off the main thread.
- Deferred: the index still stores bundle contents. Excluding them at scan
  time would shrink the index and the per-keystroke scan. It is recorded as
  an open decision in `plans/README.md`.
