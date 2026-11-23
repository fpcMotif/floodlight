# Plan 012: A clipboard capture commits once, finds the newest entry through an index, and trims without rescanning

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/clipboard.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and the excerpts come from that working tree. Line
> numbers can be off. Find each excerpt with `rg` by its text. Plan 003
> edits `fn captures` in the same file; if both are scheduled, run 003
> first.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (run after `plans/003-bulk-file-copy-cap-and-nanoui-hourly-prune.md`
  if both are scheduled)
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher with
Clipboard History in SQLite. Every copy the user makes anywhere on the Mac
runs `Store.add` on the app's main thread. Today one `add` does this:

- finds the newest entry with a sort that no index can serve, so it reads
  every row;
- inserts the entry;
- runs a four-statement trim and a vacuum, even when nothing needs
  trimming;
- sums the stored bytes of every row, reading all text;
- when over the byte budget, deletes one entry and sums every row again,
  once per deleted entry.

Each statement commits on its own. Copying several files calls `add` once
per file and repeats all of it.

After this plan a capture is one transaction, the newest entry is found
through the `created_at` index, the entry-count trim runs only when the
count is over the limit, and the byte trim sums the table once.

## Current state

Files:

- `frontends/nanoui/src/clipboard.zig` — Clipboard History store.
- `frontends/nanoui/src/tests.zig` — all nanoui tests.

Schema and indexes (`clipboard.zig`):

```
CREATE INDEX IF NOT EXISTS entries_created ON entries(created_at DESC);
CREATE INDEX IF NOT EXISTS entries_pinned ON entries(pinned_at);
CREATE INDEX IF NOT EXISTS entries_hash ON entries(hash);
```

Budget (`clipboard.zig`):

```zig
pub const Budget = struct { bytes: u64 = 150 * 1024 * 1024, entries: u32 = 5000, queries: u32 = 1000 };
```

The newest-entry check (`clipboard.zig`):

```zig
    fn repeatsNewest(s: Store, kind: Kind, text: []const u8, hash: ?*const [32]u8) bool {
        const stmt = s.prepare("SELECT kind, text, hash FROM entries ORDER BY pinned_at IS NOT NULL, created_at DESC LIMIT 1") catch return false;
```

Its meaning: the newest unpinned entry; when no unpinned entry exists, the
newest pinned entry.

The byte total (`clipboard.zig`):

```zig
const stored_bytes_sql =
    "SELECT coalesce((SELECT sum(length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + coalesce(length(png), 0)) FROM entries), 0)" ++
    " + coalesce((SELECT sum(b) FROM (SELECT max(stored_bytes) AS b FROM entries WHERE image_format != '' GROUP BY hash, image_format)), 0)";
```

The second term counts each picture file once, however many entries share
its hash.

The trim (`clipboard.zig`):

```zig
    fn keepWithinBudget(s: Store) !void {
        try s.removeWhere("pinned_at IS NULL AND id NOT IN (SELECT id FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT ?)", .{@as(i64, s.budget.entries)});
        // The newest row is the copy `add` just reported stored: pinned bytes
        // alone can exceed the budget, and it must not go with the rest.
        while ((s.int(stored_bytes_sql, .{}) orelse 0) > s.budget.bytes) {
            const id = s.int("SELECT id FROM entries WHERE pinned_at IS NULL AND id != (SELECT max(id) FROM entries) ORDER BY kind != 'image', created_at LIMIT 1", .{}) orelse return;
            try s.removeWhere("id = ?", .{id});
        }
    }
```

`removeWhere` (`clipboard.zig`) runs four statements, unlinks picture
files, and vacuums:

```zig
    fn removeWhere(s: Store, comptime condition: []const u8, args: anytype) !void {
        try s.run("INSERT INTO released SELECT DISTINCT hash FROM entries WHERE (" ++ condition ++ ") AND hash IS NOT NULL AND image_format != ''", args);
        try s.run("DELETE FROM entries WHERE " ++ condition, args);
        {
            const stmt = try s.prepare("SELECT DISTINCT hash FROM released WHERE hash NOT IN (SELECT hash FROM entries WHERE hash IS NOT NULL AND image_format != '')");
            ...
                s.unlinkImage(hash, "png");
                s.unlinkImage(hash, "avif");
        }
        try s.run("DELETE FROM released", .{});
        _ = lite.sqlite3_exec(s.db, "PRAGMA incremental_vacuum", null, null, null);
    }
```

`add` ends with `try s.keepWithinBudget();`. `capture` calls `add` once per
captured item:

```zig
    pub fn capture(s: Store, arena: std.mem.Allocator, board: Pasteboard, app: App, now: f64) !bool {
        var stored = false;
        for (captures(arena, board, app.bundle_id)) |cap| stored = (try s.add(cap, app.bundle_id, app.name, now)) or stored;
        return stored;
    }
```

`prune` also calls `removeWhere` and `keepWithinBudget`. `delete` calls
`removeWhere`.

The store's helpers: `s.run(sql, args)` prepares, binds, steps and
finalizes one statement; `s.int(sql, args)` returns one integer or null;
`lite.sqlite3_exec` runs raw SQL. An existing transaction to model on is in
`classifyUnclassified` (find with
`rg -n 'BEGIN|COMMIT|ROLLBACK' frontends/nanoui/src/clipboard.zig`).

Conventions: comments say why, never what. Keep the existing comment in
`keepWithinBudget` with the code it describes. Domain terms from
`CONTEXT.md`: **Clipboard Capture**, **Clipboard History**,
**Clipboard Entry**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Query plan check | `sqlite3 <db> "EXPLAIN QUERY PLAN <sql>"` | see steps |

## Scope

**In scope**:

- `frontends/nanoui/src/clipboard.zig` (`repeatsNewest`, `keepWithinBudget`,
  `capture`, `add`, `prune`)
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- `fn captures` and the capture rules (plan 003, and design record
  `docs/adr/0011-nano-clipboard-history.md`).
- The schema, the budget values, and which entry is evicted first.
- `removeWhere`'s statements. Call it; do not rewrite it.
- `main.zig`, `mac.zig`, and the Swift store under `Sources/`.

## Git workflow

- Branch: `advisor/012-capture-writes-once`.
- Commit style: `perf(nanoui): a capture commits once and trims without rescanning`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Find the newest entry through the index

Rewrite `repeatsNewest` to run two statements in order and use the first
that returns a row:

1. `SELECT kind, text, hash FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT 1`
2. `SELECT kind, text, hash FROM entries ORDER BY created_at DESC LIMIT 1`

**Verify**: `make test-nanoui` → exit 0. With a store file from a test or
the memory seed,
`sqlite3 <db> "EXPLAIN QUERY PLAN SELECT kind, text, hash FROM entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT 1"`
→ the plan names `entries_created` and has no `USE TEMP B-TREE`.

### Step 2: Trim by count only when over the count

In `keepWithinBudget`, run the first `removeWhere` only when
`SELECT count(*) FROM entries WHERE pinned_at IS NULL` is greater than
`s.budget.entries`.

**Verify**: `make test-nanoui` → exit 0.

### Step 3: Sum the bytes once per trim

Replace the `while` loop's repeated full sum. Compute the total once with
`stored_bytes_sql`. In the loop, pick the entry to evict with the existing
query, delete it with `removeWhere("id = ?", ...)`, then recompute the
total with `stored_bytes_sql` **only every 16 evictions and once more when
the estimate drops under the budget**. Between recomputations, subtract an
estimate for the evicted row: read
`length(CAST(text AS BLOB)) + coalesce(length(thumbnail), 0) + stored_bytes`
for that id before deleting it. The estimate can overcount a shared picture
file; the final recomputation corrects it, and the loop continues if the
true total is still over the budget.

Keep the comment about the newest row.

**Verify**: `make test-nanoui` → exit 0, including the existing budget
tests (find them with `rg -n 'budget' frontends/nanoui/src/tests.zig`).

### Step 4: One transaction per capture

In `capture`: run `BEGIN IMMEDIATE` before the loop and `COMMIT` after it.
On any error from `add`, run `ROLLBACK` and return the error. Do the same
in `prune`. Do not open a transaction inside `add` itself, because `add` is
also called directly by tests and by the memory seed; SQLite rejects a
nested `BEGIN`.

`removeWhere` runs `PRAGMA incremental_vacuum` and unlinks files while the
transaction is open. A rollback after an unlink would leave an entry whose
picture file is gone. To avoid that, split the work: add a field or a
parameter so that, inside a transaction, `removeWhere` leaves the hashes in
the `released` temp table and skips the unlink, the `DELETE FROM released`
and the vacuum; after `COMMIT`, `capture` and `prune` call a new
`fn releaseFiles(s: Store) void` that does those three things. Outside a
transaction (`delete`), `removeWhere` behaves as today.

**Verify**: `make test-nanoui` → exit 0, and the new tests pass.

## Test plan

Add to `tests.zig`. Use the existing store tests as the pattern (find them
with `rg -n 'openMemory' frontends/nanoui/src/tests.zig`); `TmpStore` and
`openMemory` create a store with a picture folder.

- "a repeat of the newest unpinned entry is not stored again": add `a`,
  pin an older entry, add `a` again, expect false.
- "with only pinned entries, a repeat of the newest pinned one is not
  stored": add `a`, pin it, add `a`, expect false.
- "the entry count stays at the budget": budget of 5 entries, add 8 texts,
  expect 5 unpinned rows and the newest 5 kept.
- "the byte budget evicts the oldest first and keeps the newest": a small
  byte budget, add texts until over it, expect the newest entry present and
  the total under the budget. An existing test may already cover this;
  extend it and do not duplicate it.
- "a shared picture file survives while one entry still uses it": add the
  same picture twice with another entry between them, evict one, expect the
  file on disk.
- "a failed capture stores nothing": capture three items through a fake
  `Pasteboard` where the store fails on the third (for example close the
  db handle through a test hook, or pass a text over the cap if that
  errors). If no failure can be forced without changing production code,
  skip this test and say so in your report.

Each new test must fail before its step and pass after it, except tests of
behavior that already held; mark those as characterization tests in your
report.

Verification: `make test-nanoui` → all pass.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `rg -n 'ORDER BY pinned_at IS NOT NULL, created_at DESC' frontends/nanoui/src/clipboard.zig`
      returns no matches.
- [ ] `rg -n 'BEGIN IMMEDIATE' frontends/nanoui/src/clipboard.zig` shows
      matches in `capture` and `prune`.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- SQLite reports an error for `PRAGMA incremental_vacuum` or for a nested
  transaction that step 4's split does not remove.
- A caller of `add` other than `capture`, tests and `seedMemoryHistory`
  exists and would now run outside a transaction with different results.
- An existing budget or eviction test fails twice.
- Plan 003 is in progress on the same file.

## Maintenance notes

- The byte total still reads every row's text once per capture. A stored
  byte counter per row would remove that; it is a schema change and is
  deferred.
- Any new caller that deletes entries inside a transaction must call
  `releaseFiles` after its commit, or picture files leak until the next
  launch's stray-file cleanup.
- Reviewer: check the rollback path, and check that `delete` from the
  board still removes the picture file at once.
