# Plan 008: Search builds only the rows in view, formats each date once, and makes icons only for visible rows

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/panel.zig frontends/nanoui/src/search.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and the excerpts come from that working tree. Line
> numbers can be off. Find each excerpt with `rg` by its text.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/006-nanoui-benchmarks-cover-real-paths.md`
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher. Its
UI is immediate-mode: the function `Panel.view` rebuilds the whole view on
every frame, and a keystroke frame runs it two to four times.

The search result list holds up to 80 rows and shows 7. On every build it:

- creates UI nodes for all 80 rows;
- creates a new `NSDateFormatter` for every file row, to format a date that
  only changes when the query changes;
- asks for an icon for every file row. A miss renders the icon and encodes
  it as PNG on the main thread, for rows nobody can see. The cache holds 64
  icons per session, so off-screen rows use it up and later rows get a
  placeholder.

The clipboard board in the same codebase already builds only the rows in
view. This plan makes search do the same, formats dates once per result
set, and stops off-screen rows from costing icons.

## Current state

Files:

- `frontends/nanoui/src/panel.zig` — the search panel. Builds the result
  list.
- `frontends/nanoui/src/search.zig` — the catalog and the `Row` type.
- `frontends/nanoui/src/board.zig` — the clipboard board. Exemplar for
  building only visible rows.
- `frontends/nanoui/src/list.zig` — the shared list type and `rowsInView`.
- `frontends/nanoui/src/main.zig` — app shell; owns the icon cache.
- `frontends/nanoui/src/mac.zig` — Cocoa adapter; `relativeDate`, `iconPng`.

Every row is built (`panel.zig`, `resultList`):

```zig
        const box = ui.div(c).column().wFull().h(metrics.list_height).scrollY().p(metrics.row_padding);
        defer box.end();
        chrome.boundOverscroll(c, box.id());
        chrome.revealSelection(c, &p.list, box.id(), metrics.list_height - 2 * metrics.row_padding);
        for (p.list.visible, 0..) |row, i| p.rowView(c, row, i);
```

The board's pattern to copy (`board.zig`, `historyList` and `spacer`):

```zig
        const visible = b.list.visible;
        const shown = list.rowsInView(c.scroll.get(col.id()) orelse 0, visible.len, metrics.row_height, m.list_height, margin_rows);
        spacer(c, "above", shown.first);
        var asked: ?Action = null;
        for (visible[shown.first..shown.end], shown.first..) |e, i| if (b.rowView(c, host, e, i)) |a| {
            asked = a;
        };
        spacer(c, "below", visible.len - shown.end);
```

```zig
    fn spacer(c: *ui.Context, name: []const u8, rows: usize) void {
        if (rows == 0) return;
        ui.key(c, name);
        ui.div(c).wFull().h(@as(f32, @floatFromInt(rows)) * metrics.row_height).end();
    }
```

`rowsInView` (`list.zig`):

```zig
pub fn rowsInView(offset: f32, len: usize, row_h: f32, view_h: f32, margin: usize) RowRange {
```

The date is formatted per row per build (`panel.zig`, `subtitleLine`):

```zig
        if (row.modified) |secs| {
            ui.text(c, "·", style);
            ui.text(c, p.hooks.describe_date(p.hooks.ctx, secs, c.arena.allocator()), style);
        }
```

The hook reaches `mac.relativeDate`, which creates a calendar and a
formatter on each call (`mac.zig`):

```zig
    const calendar = objc.msg(objc.Object, objc.class("NSCalendar"), "currentCalendar", .{});
    ...
    const fmt = objc.msg(objc.Object, objc.class("NSDateFormatter"), "new", .{});
    defer objc.release(fmt);
```

Icons (`panel.zig`, `iconView`, called from `rowView` for every row):

```zig
        if (row.kind != .web) if (p.hooks.app_icon(p.hooks.ctx, row.path)) |png| {
            _ = ui.image(c, .{ .key = row.path, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        };
```

The icon cache (`main.zig`):

```zig
/// Icons drawn per session at most; all go when the session is forgotten.
const max_icons = 64;
...
    fn appIcon(ctx: ?*anyopaque, path: []const u8) ?[]const u8 {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.icons.get(path)) |png| return png;
        if (s.icons.count() >= max_icons) return null;
        const png = mac.iconPng(gpa, path, metrics.top_hit_icon_size * 2) orelse return null;
```

Rows have unequal heights: the top hit row is taller than the others. Read
`chrome.rowBox` and `p.isTopHit` in `panel.zig` and `chrome.zig`, and the
`metrics` struct in `chrome.zig`, to learn the two heights.

The row list is filled in `Panel.answer`, which ends with
`try p.list.setRows(text, p.composeRows());`. Rows live in the list's arena
until the next query.

Conventions: comments say why, never what. `Row` is defined in `search.zig`.
Domain terms from `CONTEXT.md`: **Result Projection** (rows shown for a
Search Session), **Result Publication**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Bench only | `cd frontends/nanoui && "$(. ../../scripts/tools.sh; resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)" build bench --release` | `FLOODLIGHT_BENCH` lines |

## Scope

**In scope**:

- `frontends/nanoui/src/panel.zig` (`resultList`, `subtitleLine`, `answer`
  or `composeRows`)
- `frontends/nanoui/src/search.zig` (the `Row` type only)
- `frontends/nanoui/src/tests.zig`
- `frontends/nanoui/src/bench.zig` (budget constants only, step 5)

**Out of scope**:

- `board.zig` and `list.zig`: use them, do not change them.
- `mac.zig`: do not rewrite `relativeDate` or `iconPng`.
- `main.zig`: the icon cache and `max_icons` stay as they are. Moving icon
  work off the main thread is a separate change.
- `Catalog.rank` and the `stamp` function in `search.zig`: plan 009 owns
  them.

## Git workflow

- Branch: `advisor/008-search-builds-only-visible-rows`.
- Commit style: `perf(nanoui): search builds only the rows in view`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Record the baseline

Run the bench three times. Save p50 and p99 of `keystroke_to_built_frame`
and `first_frame_with_icons`.

**Verify**: your notes hold both metrics.

### Step 2: Format each date once per result set

Add a field to `Row` in `search.zig`: `modified_label: []const u8 = ""`.
In `panel.zig`, after the rows are composed and before
`p.list.setRows(...)`, fill `modified_label` for each row whose `modified`
is set, by calling `p.hooks.describe_date` with the list's arena allocator
(the allocator `answer` already holds as `a`). In `subtitleLine`, draw
`row.modified_label` when it is not empty and stop calling the hook there.

Late rows also pass through `answer` (`landFiles` calls `answer(text, true)`),
so one place covers both.

**Verify**: `make test-nanoui` → exit 0.
`rg -n 'describe_date' frontends/nanoui/src/panel.zig` → the hook is called
in one place, outside `subtitleLine`.

### Step 3: Build only the rows in view

Change `resultList` to follow the board's pattern: compute the range with
`list.rowsInView`, draw a spacer above, the rows in range, and a spacer
below. Import `list.zig` the way `board.zig` does.

Row heights differ: row 0 is taller when it is the top hit. Handle it this
way: always build row 0 when it is the top hit, and apply `rowsInView` to
the remaining rows with the scroll offset reduced by the top-hit row's
height. Compute the spacer heights from the same two metrics. Use a margin
of 2 rows, or the board's `margin_rows` value if it is exported.

Keep `ui.keyInt(c, i)` in `rowView` so each row keeps its identity.

**Verify**: `make test-nanoui` → exit 0, and the new tests in the test plan
pass.

### Step 4: Confirm icons follow visibility

No code change is expected: `iconView` is called from `rowView`, so after
step 3 only rows in view ask for icons.

**Verify**: the test "rows out of view ask for no icon" passes.

### Step 5: Measure and tighten

Run the bench three times.

**Verify**: median p50 of `keystroke_to_built_frame` is at least 2x lower
than the step 1 baseline, and `first_frame_with_icons` is at least 3x
lower. Lower the two budgets in `bench.zig` to 3x the new largest p99.

## Test plan

Add to `tests.zig`. Use the existing search-panel tests that build a
catalog and a `ui.Tester` as the pattern (search for `tester.hasText` near
`populateCatalog`), and a stub hook that counts calls, like `StubHooks`.

- "rows out of view ask for no icon": 60 matching apps, one frame, expect
  the icon hook's call count to be at most 12.
- "a date is described once per result set": a result set with file rows,
  three frames with no query change, expect the date hook's call count to
  equal the number of file rows, not three times that.
- "the selection scrolls into view from far below": 60 rows, press down 40
  times, expect the 41st row's title on screen (`tester.hasText`).
- "the top hit stays the first row after scrolling back": scroll down, then
  up, expect the top hit's title and "Top Hit" on screen.
- "a late file row keeps its date": rows replaced through `landFiles` still
  show a date.

Each new test must fail before its step and pass after it. Check that by
running the test once before you make the change.

Verification: `make test-nanoui` → all pass, including 5 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `keystroke_to_built_frame` median p50 is at least 2x lower than the
      baseline. Report both.
- [ ] `first_frame_with_icons` median p50 is at least 3x lower. Report both.
- [ ] The three original budgets in `bench.zig` are unchanged and met.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Plan 006 has not landed (`rg -n 'keystroke_to_built_frame' frontends/nanoui/src/bench.zig`
  finds nothing).
- The top-hit row's height cannot be derived from `chrome.metrics`.
- Scrolling shows a gap or a jump that the 2-row margin does not fix after
  one attempt at a larger margin.
- `revealSelection` stops bringing the selection into view.
- The improvement in step 5 is below the stated factors. Report the
  numbers; do not lower the bar.

## Maintenance notes

- A new row height (a third kind of row) must update the spacer math in
  `resultList`.
- Deferred: icon rendering still runs on the main thread for visible rows.
  A worker that renders icons and redraws when one lands is the next step.
- Deferred: `list.count` runs about 13 times per build from `filterBar` and
  `filterOptions`. It is small; cache the counts in `setRows` if it shows
  up in a profile.
- Reviewer: scroll the list by trackpad and by held arrow key in the real
  app. Check for blank rows at the edges.
