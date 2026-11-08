# Plan 011: Typing another character in the board filter narrows the rows in memory

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/clipboard.zig frontends/nanoui/src/board.zig frontends/nanoui/src/bench.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written. Plans 006 and 010 edit some of them first. Line
> numbers will be off. Find each excerpt with `rg` by its text.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/006-nanoui-benchmarks-cover-real-paths.md` and
  `plans/010-board-loads-thumbnails-on-demand.md` (same files)
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher with
Clipboard History in SQLite. The clipboard board has a filter field. Every
keystroke in it runs a query that, for each of up to 5,000 entries, builds
a concatenated copy of the text, lowercases it, and searches it. The work
grows with the total text stored, and it runs on the main thread.

Most keystrokes extend the previous query by one character. Every entry
that matches `meet` also matched `mee`. When the previous answer was
complete, the new answer is a subset of it and needs no database query.

After this plan a keystroke that extends the previous query filters the
rows already in memory. The cost of the first keystroke is measured, so a
follow-up can be decided on a number.

## Current state

Files:

- `frontends/nanoui/src/clipboard.zig` — Clipboard History store.
- `frontends/nanoui/src/board.zig` — the clipboard board.
- `frontends/nanoui/src/list.zig` — the shared list type. Read only.
- `frontends/nanoui/src/bench.zig` — latency benchmark.

The search query (`clipboard.zig`, `Store.list`):

```zig
        const q = std.mem.trim(u8, query, " ");
        const stmt = if (q.len == 0)
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE pinned_at IS NOT NULL OR id IN (...)" ++ board_order)
        else
            try s.prepare("SELECT " ++ columns ++ " FROM entries WHERE instr(lower(text || CASE kind WHEN 'image' THEN ' ' || width || '\u{00D7}' || height ELSE '' END), lower(?)) > 0" ++ board_order ++ " LIMIT " ++ std.fmt.comptimePrint("{d}", .{search_limit}));
```

Three facts about its meaning that the in-memory filter must match:

1. The haystack is the entry's `text`. For a picture entry it is the text,
   one space, the width, the character `×` (U+00D7), and the height.
2. SQLite's `lower()` folds ASCII letters only. `É` does not match `é`.
3. A query result holds at most `search_limit` rows. Find the constant with
   `rg -n 'search_limit' frontends/nanoui/src/clipboard.zig`. A result with
   exactly `search_limit` rows may be cut short.

An ASCII case-insensitive substring helper already exists
(`clipboard.zig`):

```zig
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
```

How the board asks the store (`board.zig`):

```zig
    pub fn refresh(b: *Board, query: []const u8) void {
        if (!b.list.needsQuery(query)) return;
        b.answer(query) catch |err| {
            std.log.err("clipboard history: {s}", .{@errorName(err)});
            b.list.fail();
        };
    }

    fn answer(b: *Board, query: []const u8) !void {
        const a = b.list.beginQuery(query);
        const rows = if (b.store) |s| try s.list(a, query) else &.{};
        try b.list.setRows(query, rows);
    }
```

The list (`list.zig`). `beginQuery` frees the previous rows' memory for
reuse, so rows must be copied out before it is called:

```zig
        pub fn beginQuery(l: *Self, query: []const u8) std.mem.Allocator {
            const same = l.stale and std.mem.eql(u8, query, l.query.items);
            l.kept = if (same) if (l.selection()) |x| keyOf(x) else null else null;
            _ = l.arena.reset(.retain_capacity);
            l.rows = &.{};
            l.visible = &.{};
            return l.arena.allocator();
        }
```

`l.stale` is true when history changed under an unchanged query (a capture,
a pin). `l.answered()` returns the query the current rows answer. `l.rows`
holds all rows for that query, before the kind filter.

`Entry` (`clipboard.zig`) holds slices: `text`, `source`, `source_name`,
`thumbnail`, and a `content: Content` union whose variants can hold slices
(a link's domain, a path, a code language). Read the `Content` type before
copying an entry.

Conventions: comments say why, never what. Domain terms from `CONTEXT.md`:
**Clipboard History**, **Clipboard Entry**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Bench only | `cd frontends/nanoui && "$(. ../../scripts/tools.sh; resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)" build bench --release` | `FLOODLIGHT_BENCH` lines |

## Scope

**In scope**:

- `frontends/nanoui/src/clipboard.zig` (a new `Entry.matches`, a new
  `Entry.dupe`, making `search_limit` public if it is not)
- `frontends/nanoui/src/board.zig` (`answer`)
- `frontends/nanoui/src/bench.zig` (one new metric)
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- The SQL in `Store.list`. Do not change what matches.
- The schema. No new column, index, or full-text table.
- `list.zig`.
- `Sources/` (the Swift store; plan 005 covers its short-query matching).

## Git workflow

- Branch: `advisor/011-board-search-narrows-in-memory`.
- Commit style: `perf(nanoui): a longer board query narrows the rows in memory`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Measure a board keystroke

In `bench.zig` add `pub fn measureBoardKeystroke(gpa, runs) !Stats`. Open a
`:memory:` store, add 5,000 text entries of about 500 bytes each built from
a small word list so that the query `meet` matches about 5% of them, then
time `store.list(arena, q)` for the queries `m`, `me`, `mee`, `meet` in
turn, resetting the arena between samples. Use `runs=40`. Print it as
`metric=board_keystroke entries=5000`. Give it no budget yet.

**Verify**: bench command → a line starting
`FLOODLIGHT_BENCH metric=board_keystroke`. Record p50 and p99.

### Step 2: Add `Entry.matches`

In `clipboard.zig` add `pub fn matches(e: Entry, query: []const u8) bool`.
Trim spaces from `query` as `Store.list` does. For a picture entry, build
the haystack `"{text} {width}×{height}"` in a stack buffer (fall back to
checking the text and the dimension string separately if it does not fit).
Use `containsIgnoreCase`.

**Verify**: the test "in-memory matching agrees with the store" from the
test plan passes.

### Step 3: Add `Entry.dupe`

Add `pub fn dupe(e: Entry, arena: std.mem.Allocator) !Entry` that copies
every slice the entry holds, including the slices inside `content`.

**Verify**: `make test-nanoui` → exit 0.

### Step 4: Narrow in memory when the previous answer was complete

In `board.zig`, `answer`: before `beginQuery`, decide whether to narrow.
Narrow only when all of these hold:

- the list is not stale (`!b.list.stale`);
- the previous query is not empty after trimming;
- the new query starts with the previous query (`std.mem.startsWith`);
- the previous result had fewer than `search_limit` rows
  (`b.list.rows.len < clipboard.search_limit`).

When narrowing: copy the matching rows of `b.list.rows` into a temporary
arena with `Entry.dupe`, call `beginQuery`, copy them again into the
allocator it returns, and call `setRows`. Free the temporary arena.
Otherwise run the store query as today.

The previous empty query is excluded on purpose: its result is the newest
1,000 entries, not all entries, so it is not a superset.

**Verify**: `make test-nanoui` → exit 0, and the new tests pass.

### Step 5: Measure again and report

Add a second metric `board_keystroke_narrowed` that drives a `Board` (not
the store) through `m`, `me`, `mee`, `meet` and times each `refresh`.

**Verify**: the p50 of `board_keystroke_narrowed` is lower than the step 1
p50 of `board_keystroke`. Report both, and report the p50 for the query
`m` alone, which still runs the full scan.

## Test plan

Add to `tests.zig`, using `BoardFixture` as the pattern:

- "in-memory matching agrees with the store": add 30 mixed entries (texts
  with upper and lower case, a text with `É`, a picture entry 640×480, a
  file path). For each of the queries `me`, `ME`, `é`, `640`, `640×480`,
  `x48`, `tmp`, expect the set of ids from `store.list(q)` to equal the set
  of entries for which `matches(q)` is true.
- "a longer query narrows without asking the store": type `he`, then
  `hel`. Expect the same rows as a fresh `store.list("hel")`, in the same
  order.
- "a query that hit the limit asks the store again": seed more than
  `search_limit` matching entries, type `e`, then `en`. Expect the rows to
  equal `store.list("en")`.
- "history that changed is asked again": type `he`, add a matching entry,
  mark the list stale, type `hel`. Expect the new entry in the rows.
- "a shorter query asks the store again": type `hel`, then `he`. Expect
  the rows to equal `store.list("he")`.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including 5 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] The bench prints `board_keystroke` and `board_keystroke_narrowed`.
- [ ] `git diff 64cc313 -- frontends/nanoui/src/clipboard.zig | rg '^[-+].*instr\(lower'`
      prints nothing (the SQL is unchanged).
- [ ] `git status --short` lists only in-scope files.
- [ ] Your report gives the three p50 values from step 5.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Plans 006 or 010 have not landed and their files conflict with yours.
- The "agrees with the store" test fails for a query and you cannot make
  `matches` agree without changing the SQL.
- `Content` holds a pointer you cannot copy with `arena.dupe`.
- After step 5, the p50 for the single-character query exceeds 4 ms.
  Report it. The follow-up is a stored lowercase search column or a
  full-text index; that is a schema change and needs its own plan.

## Maintenance notes

- `Entry.matches` and the SQL in `Store.list` must stay in agreement. The
  "agrees with the store" test is the guard. Any change to what the board
  matches must change both.
- If the Swift app's short-query fix (plan 005) is ported to this store,
  `matches` must follow.
- Reviewer: type fast in the board filter with a large history and check
  that results match what a fresh open shows.
