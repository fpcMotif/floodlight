# Plan 010: The clipboard board loads thumbnails for rows in view only, and a delete does not reload the board

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/clipboard.zig frontends/nanoui/src/board.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and the excerpts come from that working tree. Line
> numbers can be off. Find each excerpt with `rg` by its text. Plans 003
> and 012 also edit `clipboard.zig`; run one at a time.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher with
Clipboard History in SQLite. The clipboard board lists up to 1,000 entries
and draws about 10.

Every time the board opens, and after every pin, delete, or capture while
it is open, the board runs one query that copies every row's thumbnail
PNG into memory. A history with 200 pictures at 25 KB each copies 5 MB per
open. The list's arena keeps its largest size for the session. Holding ⌘D
to delete several entries repeats the whole query once per entry.

After this plan the list query carries no thumbnails. The board fetches a
thumbnail when its row comes into view, and a delete removes the row from
the list in memory.

## Current state

Files:

- `frontends/nanoui/src/clipboard.zig` — Clipboard History store. `Entry`,
  `Store.list`, `Store.image`, `Store.delete`, `Store.togglePin`.
- `frontends/nanoui/src/board.zig` — the clipboard board. Draws rows and
  the inspector.
- `frontends/nanoui/src/list.zig` — the shared list type. Read only.

The column list and the row copy (`clipboard.zig`):

```zig
const columns = "id, kind, text, created_at, source, source_name, pinned_at, width, height, byte_count, thumbnail, content_kind, content_detail, sensitive";
```

```zig
                .byte_count = @intCast(lite.sqlite3_column_int64(stmt, 9)),
                .thumbnail = try arena.dupe(u8, columnBlob(stmt, 10)),
                .content = storedContent(columnText(stmt, 11), try arena.dupe(u8, columnText(stmt, 12))),
                .sensitive = lite.sqlite3_column_int64(stmt, 13) != 0,
```

`Entry` has the field `thumbnail: []const u8 = "",` (`clipboard.zig`).

A single-row fetch to model the new function on (`clipboard.zig`):

```zig
    /// The full image an entry holds, in `arena`'s memory.
    pub fn image(s: Store, arena: std.mem.Allocator, id: i64) ?[]const u8 {
        const stmt = s.prepare("SELECT hash, image_format, stored_bytes FROM entries WHERE id = ? AND image_format != ''") catch return null;
        defer _ = lite.sqlite3_finalize(stmt);
        bindAll(stmt, .{id});
        if (lite.sqlite3_step(stmt) != lite.row) return null;
```

Where the board reads a thumbnail (`board.zig`). The row icon:

```zig
        if (e.kind == .image and e.thumbnail.len > 0) {
            if (ui.image(c, .{ .key = c.print("clip.{d}", .{e.id}), .bytes = e.thumbnail, .max_width = size, .max_height = size, .radius = 6 })) return;
        }
```

The inspector preview. Note that the thumbnail and the full picture share
one image key:

```zig
        if (e.kind == .image) {
            const bytes = switch (b.payload) {
                .picture => |full| full,
                else => e.thumbnail,
            };
            mediaBox(c, c.print("clip.full.{d}", .{e.id}), bytes, width);
```

The UI library caches a decoded image by its key. While the selection
passes over an entry on a held arrow key, the thumbnail is drawn under
`clip.full.{id}` first, and the full picture loaded later uses the same
key.

Delete and pin reload the whole board (`board.zig`):

```zig
    pub fn delete(b: *Board) void {
        const e = b.list.selection() orelse return;
        const store = b.store orelse return;
        store.delete(e.id) catch return;
        const at = b.list.selected;
        b.list.markStale();
        b.refresh(b.list.answered());
        b.list.clampSelection(at);
    }
```

The board builds only the rows in view (`board.zig`, `historyList`), and it
owns an arena for the inspector, released by `releaseDetail` and `forget`:

```zig
    pub fn releaseDetail(b: *Board) void {
        b.detail_id = null;
        b.facts_id = null;
        _ = b.detail_arena.reset(.free_all);
    }
```

The list (`list.zig`) exposes `rows: []const Item`, `visible: []Item`,
`selected`, `replaceRows(rows)` and `allocator()`. `replaceRows` installs
rows allocated from `allocator()` for the query already answered and keeps
the selection.

Design record `docs/adr/0011-nano-clipboard-history.md`: "`facts(entry)`
makes one `stat`, and the board keeps the answer for the entry the
selection rests on. ... No `stat` and no read runs while the board draws."
A thumbnail fetch is a read. This plan keeps the rule by fetching each
thumbnail once and caching it, never once per frame.

Conventions: comments say why, never what. Domain terms from `CONTEXT.md`:
**Clipboard History**, **Clipboard Entry**, **Clipboard Inspector**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |

## Scope

**In scope**:

- `frontends/nanoui/src/clipboard.zig` (`columns`, `Store.list`, a new
  `Store.thumbnail`)
- `frontends/nanoui/src/board.zig`
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- The `text` column. Paste and copy actions carry the `Entry` and use its
  full text, so the list must keep loading it.
- The search query in `Store.list` (plan 011) and `Store.add`,
  `keepWithinBudget`, `removeWhere` (plan 012).
- The schema. Add no column and no index.
- `list.zig`.
- `Sources/` (the Swift app has its own store).

## Git workflow

- Branch: `advisor/010-board-loads-thumbnails-on-demand`.
- Commit style: `perf(nanoui): the board loads thumbnails for rows in view`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Add `Store.thumbnail`

In `clipboard.zig` add
`pub fn thumbnail(s: Store, arena: std.mem.Allocator, id: i64) []const u8`.
It selects `thumbnail` for one `id`, copies the blob into `arena`, and
returns `""` when the row is missing or the blob is empty. Model it on
`Store.image`.

**Verify**: `make test-nanoui` → exit 0.

### Step 2: Cache thumbnails in the board

In `board.zig` add to `Board` a map from entry id to thumbnail bytes and an
arena that owns them. Add `fn thumbnailOf(b: *Board, e: Entry) []const u8`:
return the cached bytes, or fetch with `Store.thumbnail`, store, and
return. Cache an empty result too, so a missing thumbnail is fetched once.
Free the map and reset the arena in `forget`, and free both in `deinit`.
Cap the cache at 256 entries: when full, clear the map and reset the arena.

`iconView` is a function without `b`; pass the bytes in, or make it a
method.

**Verify**: `make test-nanoui` → exit 0.

### Step 3: Read thumbnails through the cache

Change the row icon and the inspector preview to call `thumbnailOf(e)` and
not `e.thumbnail`. Run
`rg -n '\.thumbnail' frontends/nanoui/src/board.zig frontends/nanoui/src/panel.zig`
and convert every reader.

In the preview, give the two pictures separate keys: `clip.{d}` while the
bytes are the thumbnail, `clip.full.{d}` once `b.payload` is `.picture`.

**Verify**: `make test-nanoui` → exit 0.

### Step 4: Drop the thumbnail from the list query

Remove `thumbnail` from `columns` and renumber the column indexes in
`Store.list`. Leave the `Entry.thumbnail` field in place with its default
`""`, because `Capture` code and tests construct entries with it. Run
`rg -n 'columns' frontends/nanoui/src/clipboard.zig` and confirm no other
query depends on the old positions.

**Verify**: `make test-nanoui` → exit 0, and the new tests pass.

### Step 5: Delete without reloading

Change `Board.delete`: after `store.delete(e.id)` succeeds, build new
`rows` without the deleted id, allocated from `b.list.allocator()`, and
install them with `b.list.replaceRows(...)`, then `clampSelection(at)`.
Remove the `markStale` and `refresh` calls from `delete` only. Leave
`togglePin` as it is: a pin changes the order, so it reloads. After step 4
that reload is cheap.

Also drop the deleted id from the thumbnail cache.

**Verify**: `make test-nanoui` → exit 0, and the delete tests pass.

## Test plan

Add to `tests.zig`, using `BoardFixture` and the test
`"the board lists history, inspects the selection, and filters"` as the
pattern. To add a picture entry, follow `seedMemoryHistory` in `main.zig`.

- "the list carries no thumbnails": add 3 picture entries, call
  `store.list`, expect every `thumbnail.len == 0`.
- "a picture row in view shows its thumbnail": show the board with one
  picture entry, expect `store.thumbnail` to return non-empty bytes and the
  board's cache to hold one entry after a frame.
- "rows out of view fetch no thumbnail": 60 picture entries, one frame,
  expect the cache to hold fewer than 20 entries.
- "deleting keeps the other rows and the selection's place": seed 5 texts,
  select the third, delete, expect 4 rows and the selection on the row that
  followed.
- "deleting does not ask the store for the list again": count calls with a
  store wrapper if one exists; otherwise assert `b.list.stale == false`
  right after `delete`.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including 5 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `rg -n '"id, kind, text' frontends/nanoui/src/clipboard.zig` shows a
      column list without `thumbnail`.
- [ ] `rg -n 'e\.thumbnail' frontends/nanoui/src/board.zig` returns no
      matches.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- A reader of `Entry.thumbnail` exists outside `board.zig` and tests, for
  example in an action that writes a picture back to the pasteboard.
- `replaceRows` resets the filter or the scroll position in a way an
  existing test rejects.
- The inspector shows the small thumbnail where it showed the full picture
  before, after step 3.
- A step's verification fails twice.

## Maintenance notes

- The list still copies every row's full text (up to 32,000 bytes each).
  Narrowing that needs paste and copy to load the text on demand; it is
  deferred.
- The `ORDER BY pinned_at IS NULL, pinned_at, created_at DESC` sort has no
  index. With thumbnails gone the sorted rows are much smaller. Measure
  before adding an expression index.
- Reviewer: open the board with many pictures, hold the down arrow, and
  check that thumbnails appear and the inspector shows the full picture.
