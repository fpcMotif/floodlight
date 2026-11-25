# State machines in Nanospot

## At a glance

Nanospot (`app/` over `core/`) runs eleven state machines.
Two are explicit enums: Presence and the grant flow. The rest are implicit,
spread over flags, counters, arenas and timers. The worst reachable bug was a
use-after-reset. The panel handed the shell an action that pointed into the
result list's memory. Any query between the ask and the shell's turn reused
that memory, so Return could paste or open a different item.

Six bugs are fixed, each with a regression test that failed before its fix.
Three findings stay open and are listed with their reason. The search ranking,
the file index protocol and the clipboard schema are unchanged.

Scope: `app/` and `core/`.

## How control reaches these machines

Everything except the file worker and file index scan runs on the main thread. "Concurrency"
here means interleaving on the main dispatch queue, not data races. A turn is
one main-queue work item or one frame. Turns interleave in this order:

```text
 frame (key, click)          main queue, FIFO-ish                 worker / scan
┌──────────────────┐        ┌──────────────────────────────┐     ┌──────────────┐
│ Panel.view       │──ask──▶│ applyPanel   (dispatch_async) │     │ FileSearcher │
│  ask() sets      │        │ captureTick  (after 500 ms)   │◀────│ runRebuild   │
│  Panel.pending   │        │ searchLanded (dispatch_async) │     └──────────────┘
└──────────────────┘        │ pollTick, expireRetention ... │
                            └──────────────────────────────┘
```

A nested run loop also drains the queue mid-turn. The ⌘K menu
(`mac.popUpMenu`, called from `AppShell.actionsMenu`) runs every timer while it
is open. So any machine whose transition is split across two turns can see
other transitions in between. Findings 1 and 2 come from that split.

## 1. Panel Presence (explicit)

`app/src/presence.zig`. Phase: `hidden`, `entering`, `shown`.
`entering` means the window is ordered in at alpha 0.01 and waits for its own
presented frame.

Invariants:

- `timers_fired <= entrances`. The nth fallback timer belongs to the nth
  entrance, so only the latest entrance's timer reveals.
- `summon_open` is true only from a show from hidden until the reveal or the
  hide. It brackets one signpost.
- `hidden` emits `hide_window` and `end_session` exactly once per session.
- A settled action never changes a hidden panel (fixed, finding 2).

| From | Event | Guard | To | Effects |
|---|---|---|---|---|
| hidden | `search`, `board`, `launched(!guiding)`, `reopened` | last frame valid | shown | note_paste_target, open_*, place, order_in_seen |
| hidden | same | last frame stale | entering | note_paste_target, open_*, place, order_in_unseen, start_entrance_timer |
| entering, shown | `search`/`board` | focused and same surface | hidden | hide_window, end_session |
| entering, shown | `search`/`board` | otherwise | unchanged | open_*, place, order_front |
| entering | `framePresented(true)` | | shown | reveal |
| entering | `entranceTimedOut` | `timers_fired == entrances` | shown | reveal |
| entering, shown | `focusLost(quick_look=false)` | | hidden | hide_window, end_session |
| entering, shown | `settle(open, reveal, copy, hide, board paste/open/reveal)` | | hidden | hide_window, end_session (+ deliver_paste for paste) |
| entering, shown | `settle(show_search)` | | unchanged | open_search, place, order_front |
| hidden | `settle(any)` | | hidden | none |

## 2. Pending action handoff (implicit)

`Panel.ask` (`panel.zig`) stores `Panel.pending` and calls the request
hook. `AppShell.onRequest` (`main.zig`) dispatches `applyPanel` to a later
turn, where `Shell.applyPending` (`shell.zig`) executes the action and
`Presence.settle`.

States: `none`, `asked` (pending set, apply queued), `applying` (apply runs,
possibly inside the ⌘K menu's run loop).

Invariants:

- The bytes an action names stay valid from `ask` to the end of its apply.
  `Panel.action_arena` owns them, reset only by the next `ask` (fixed,
  finding 1).
- `Panel.hide` clears `pending`. An apply that finds `pending == null` only
  resizes.
- One slot: a second ask before the apply replaces the first. The second
  apply only resizes.

| From | Event | To | Notes |
|---|---|---|---|
| none | `ask(a)` | asked | copies `a` into `action_arena` |
| asked | `ask(b)` | asked | `b` replaces `a` |
| asked | `Panel.hide` | none | queued apply only resizes |
| asked | `applyPanel` | applying → none | runs the action, then settle |

## 3. Panel session and retention (implicit)

`panel.zig`. State: `mode` (`search`, `clipboard`) × `hidden` ×
`retained_search.hidden_at` × `retained_board.hidden_at` × `expiry_armed`.
See ADR 0015 for the retention rule.

Invariants:

- While shown, the active surface's `hidden_at` is null. `showSearch` and
  `showClipboard` consume it.
- After `hide` with retention on, a non-empty active surface has `hidden_at`.
  With retention off, `forget` runs and nothing is retained.
- `nextExpiryMs` is null exactly when nothing is retained.
- At most one shell expiry timer is pending: `armExpiry` returns a delay only
  when `expiry_armed` is false (fixed, finding 4).

| From | Event | To |
|---|---|---|
| shown(m) | `hide`, retention on, field or board state non-empty | hidden, surface m retained at now |
| shown(m) | `hide`, retention on, empty | hidden, surface m forgotten |
| shown(m) | `hide`, retention off | hidden, both forgotten, mode search |
| shown(search) | `showClipboard` | shown(clipboard), search retained at now |
| hidden or shown | `showSearch`/`showClipboard` with surface retained and not expired | shown, restored |
| hidden or shown | same, surface expired or not retained | shown, fresh surface |
| any | expiry timer fires | surfaces past `retention_seconds` forgotten; rearm if any remain |
| hidden, nothing retained | `endSession`, `expireRetention` | surface and icons released |

## 4. Result list (implicit)

`list.zig`, used for search rows and board history. State: `query` answered,
`stale`, `failed`, `kept` (selection key to find again).

Invariants:

- `rows` and `visible` live in `arena` until the next `beginQuery`. Nothing
  outside the list may keep a slice across a query (finding 1).
- `needsQuery(q)` is true when `stale` or `q != query`.
- `kept` is set only by a stale refresh of the same query, so a capture that
  adds rows keeps the selected entry selected.

| From | Event | To |
|---|---|---|
| answered(q) | `markStale` | stale(q) |
| answered or stale | `beginQuery(q')` | fetching (arena reset, rows empty) |
| fetching | `setRows(q', rows)` | answered(q'), selection restored by `kept` |
| fetching | `fail` | failed(q) — query unchanged, so the next refresh asks again |
| answered | `replaceRows` | answered, same query, selection kept by key |

## 5. Staged file search (explicit `Session` / `Poll`)

`search.Catalog` (`app/src/search.zig`), `Panel.poll` (`app/src/panel.zig`), and
`Shell.pollSearch` / `AppShell.searchLanded` (`app/src/shell.zig`,
`app/src/main.zig`). With its worker started, `Catalog.query` answers app and
web rows at once and submits the `FileIndex` query to the worker. `Catalog.poll`
drains the worker, adopts any finished `FileIndex` only when the worker is
idle, and resolves against `Session`.

| From | Event | To |
|---|---|---|
| idle | `query` with worker and mapped index | pending(`seq`, `query`), apps published |
| pending | newer `query` | pending(`seq+1`, `query'`), worker coalesces waiting queries |
| pending or idle | `poll` with finished index and idle worker | idle, index adopted; `.stale` if `live` or `retained` |
| pending | `poll(.live)` matching `query` | idle, `.merged` rows ranked while `View` is mapped |
| pending | `poll(.retained)` (hidden or board mode) | idle, `.stale` with zero allocations (fixed, finding 7) |
| pending | `cancel` or `poll(.idle)` | idle, rows dropped |

## 6. Web suggestions (implicit)

`Panel.suggest_seq`, `pending_suggest_seq`, `pending_suggest_query`,
`suggestion_cache`. `receiveSuggestionsFor` (`panel.zig:634`) accepts a reply
only when web suggestions are on, mode is search, the sequence matches, and
both the pending query and the field equal the reply's query.

Invariants: `pending_suggest_seq == 0` means no reply is wanted. A failed
fetch is never retried. The next new query asks again. A query typed again
within five minutes reads the cache.

| From | Event | To |
|---|---|---|
| idle | answer needs fetch | waiting(seq, q) |
| waiting | new query, mode change, forget | idle or waiting(seq+1, q') |
| waiting | matching reply | idle, rows and cache updated |
| waiting | late, mismatched or failed reply | unchanged |

## 7. Board detail (implicit)

`board.zig:162`. State: `detail_id`, `detail_loaded`, `detail_passing`,
`payload` in `detail_arena`, `facts_id`. A selection passing under a held
arrow key waits 0.15 s before it reads the payload.

Invariant: `payload` is read only after `loadDetail` for the same
`detail_id`. `releaseDetail` frees the arena and clears `detail_id`, so the
next `loadDetail` resets `payload` before `preview` reads it.

## 8. Clipboard capture and history (implicit)

`Shell.captureTick` (`shell.zig`) compares the pasteboard change count
every 500 ms. `Store.capture` (`clipboard/store.zig`) wraps multi-item writes in a
transaction (`BEGIN IMMEDIATE ... ROLLBACK`), and `keepWithinBudget` keeps
history. A full image moves `png` → `avif` after 7 days through `compactOne`,
which runs only while the panel is hidden.

Invariants:

- Nanospot's own writes carry `own_write_type` (`com.nanospot.own-write`), and `writeEntry` updates
  `change_count`, so they are never captured again.
- `change_count` advances only after `Store.capture` returns without error, so
  a transient error retries on the next tick (fixed, finding 6).
- An image file exists while any row names its hash and format.
  `removeWhere` unlinks a hash once no row names it in any format.
- `add` returning true means the entry is in history (fixed, finding 3).
- Pinned entries are outside the entry-count budget. They count toward the
  byte budget (finding 9).

| Image state | Event | Next |
|---|---|---|
| none | `add(image)` | png file, row `image_format='png'` |
| png, older than 7 days | `compactOne`, AVIF smaller | avif file, png unlinked, `compacted=1` |
| png | `compactOne`, not smaller or not opaque | png, `compacted=1` |
| any | last row naming the hash removed | file unlinked |

## 9. Full Disk Access grant flow (explicit)

`permission.zig` (`Grant`). Phase: `idle`, `guiding`, `granted`, `dismissed`. `Grant` owns `poll_armed`, `lingering`, `close_requested`, and `placed_card` windowless without shell flags.

Invariants: at most one poll timer is pending (`poll_armed`). Clicking `✕` latches `close_requested` inside `Grant` so a queued poll drains dismissal cleanly instead of re-presenting. Polling continues silently at `slow_poll_ms` (`5000 ms`) while `dismissed` and stops once `granted`.

| From | Event | Guard | To | Effects |
|---|---|---|---|---|
| any (not `granted`) | `begin` | granted | `granted` | `rebuild_index` (+ redraw, clear drag, linger 1.5 s if visible) |
| `guiding` | `begin` | not granted | `guiding` | show / anchor, arm poll if unarmed |
| `idle`, `dismissed` | `begin` | not granted | `guiding` | `open_settings`, show / anchor, arm poll (`500 ms`) |
| `guiding` | `poll` | `close_requested` | `dismissed` (or `granted`) | hide, clear drag, arm `slow_poll_ms` (or `rebuild_index` if granted) |
| `guiding` | `poll` | granted | `granted` | `rebuild_index`, clear drag, redraw, linger 1.5 s |
| `guiding` | `poll` | not granted | `guiding` | move past jitter (`4 pt`), rearm poll (`500 ms` -> `5000 ms`) |
| `dismissed` | `poll` | not granted | `dismissed` | rearm silent poll (`5000 ms`, no anchor read) |
| `dismissed` | `poll` | granted | `granted` | `rebuild_index` silently (no window show or linger) |
| `granted` | `lingerTimedOut` | `visible` | `granted` | hide, clear drag (polling stays stopped) |
| `guiding` | ✕ on the card (`applyPending` / `poll`) | | `dismissed` | hide, clear drag; silent `5000 ms` poll armed |

## 10. File index rebuild (explicit protocol, real threads)

`core/src/file_index.zig:97` and `app/src/search.zig`. Atomics `running`, `requested`, `ready`.
The scan runs on a joinable thread owned by `Catalog`. `adopt` runs inside `Catalog.poll` on the main thread once the search worker is idle.

Invariants:

- At most one scan runs. A request during a scan costs one more scan.
- A request is never lost. Each caller adds to `requested` before it tries to
  run. The runner reads `requested` after it clears `running`.
- `ready` holds at most one finished index. A newer one closes the older.
- `busy()` is true from a request until the last scan notifies.

The existing core tests cover a burst of requests, eight threads at once, a
failed scan, and `busy` timing. No bug was found here.

## 11. Entrance timers

Covered under Presence: `entrances` and `timers_fired`. Timers share one
delay, so they fire in start order. A show from hidden with a valid frame
starts no timer and does not count.

## Issues

The findings group by cause. Each issue is fixed in one change.

| Issue | Findings | Cause | Status |
|---|---|---|---|
| A. A panel action runs a turn after its ask | 1, 2 | The ask and the apply sit in different main-queue turns | Fixed |
| B. History budget drops what it just stored | 3, 9 | Pinned bytes count toward the byte budget | 3 fixed, 9 open |
| C. Retention arms a timer per hide | 4 | No record of the pending timer | Fixed |
| D. Small main-queue races | 5, 6, 7 | State cleared before the step that needs it | Fixed |
| E. A grant after ✕ is not seen | 8 | Polling stopped on dismissal | Fixed |

## Findings

Ranked by impact. "Fixed" findings have a test under `app/src/tests/` that
failed before the fix.

| # | Machine | Invalid state | Reach | Impact | Status |
|---|---|---|---|---|---|
| 1 | Pending action, result list | Action bytes freed by a query before the shell runs it | Confirmed | Wrong item pasted or opened | Fixed |
| 2 | Presence | Settle on a hidden panel | Plausible | ⌘V into another app, a dismissed panel summoned again, a repeated exit | Fixed |
| 3 | History budget | `add` true, entry evicted | Confirmed | Every new copy lost while pins fill the budget | Fixed |
| 4 | Retention | Several expiry timers pending | Confirmed | Extra wakeups only | Fixed |
| 5 | Grant flow | ✕ undone by a poll tick | Confirmed | Click ignored when a poll precedes `applyPending` | Fixed |
| 6 | Capture | Failed capture not retried | Confirmed | Copy skipped on transient store error | Fixed |
| 7 | File staging | Files dropped when worker lands in board mode | Confirmed | A restored query without file rows | Fixed |
| 8 | Grant flow | Grant after ✕ never detected | Confirmed | Index without protected folders until relaunch | Fixed |
| 9 | History budget | Pins over the byte budget evict all other history | Confirmed | History one entry deep | Open, product decision |

### 1. Actions borrowed the result list's memory

Cause: `Action` carries slices (`open: []const u8`, `copy: Row`,
`paste: Entry`). They pointed into `list.arena`, which `beginQuery` resets
with `.retain_capacity`. The apply runs on a later turn (section 2). Three
turns can query between the ask and the apply:

- `captureTick` marks the board stale and refreshes it when another app
  copies. This includes the seconds the ⌘K menu stays open, because
  `popUpMenu` runs a nested run loop. `actionsMenu` then pastes `e`.
- `searchLanded` (`main.zig`) calls `Panel.poll`, which either merges worker
  file rows or marks the search list stale and refreshes it when a fresh
  `FileIndex` is adopted.

Evidence: before the fix, the test "a board action keeps the entry it named
when a copy lands before the shell runs it" found `a copy from another app,`
where it expected `the entry the user chose`. The paste would have written
the other app's copy. The search test found garbage bytes in place of
`https://grok.com/?q=cal`.

Change: `ask` copies the action into `Panel.action_arena`
(`ownedAction`, `panel.zig:1282`).

### 2. A late settle acted on a hidden panel

Cause: `settle` ran its effects whatever the phase. The panel can hide
between the ask and the apply: a focus loss, a hot key, or anything during
the ⌘K menu. Then `.paste` sent ⌘V to whichever app was now in front,
`.show_search` summoned a panel the user dismissed, and the hiding actions
ran `end_session` a second time.

Reach: the unit test proves the transition. A live reproduction needs an
event between two main-queue turns, so it is marked plausible.

Change: `settle` returns at once when hidden (`presence.zig:97`). The shell
still carries out the action itself. Only the panel's response is skipped.

### 3. The byte budget evicted the copy it had just stored

Cause: `keepWithinBudget` evicts the oldest unpinned row while total bytes
exceed the budget, and pinned bytes count. With pins over budget, it evicted
every unpinned row, including the one `add` had just inserted. `add` still
returned true.

Evidence: the test "a copy stored while pinned entries alone fill the byte
budget stays in history" found 4 rows instead of 5 before the fix.

Change: the eviction query skips the newest row (`max(id)`).

### 4. Each hide armed another expiry timer

Cause: `endSession` scheduled `expireRetention` on every hide, with no
record of the pending one. Each timer rescheduled itself. N hides within the
retention window left N chains.

Change: `Panel.armExpiry` and `Panel.disarmExpiry` keep one timer
(`panel.zig:346`). The test "hiding again within the retention window arms
no second expiry timer" covers it.

### 5. Late file results were dropped outside search mode (finding 7)

Cause: `Panel.landFiles` cleared `files_due` before checking `p.mode`. When the
worker landed after a switch to the clipboard board, the retained search query
restored later without its file rows, and `refresh` saw an unchanged query.

Change: `Panel.poll` passes `Session.retained` whenever a search session is
retained while hidden or in board mode. `Catalog.poll(.retained)` returns
`.stale` with zero allocations, so `showSearch` re-queries on return.

### 6. A failed capture advanced `change_count` (finding 6)

Cause: `Shell.captureTick` updated `change_count` before calling
`Store.capture`. A transient store error (`SQLITE_BUSY` or I/O failure) rolled
back the transaction in `Store.capture`, yet skipped retrying the pasteboard on
the next tick.

Change: `Shell.captureTick` (`shell.zig`) now advances `change_count` only
after `Store.capture` returns without error.

### 7. ✕ clicked right before a poll tick (finding 5)

Cause: `AppShell.present` unconditionally cleared `guidance.dismissed = false`, so a poll tick queued ahead of `applyGuidance` erased a clicked `✕`.

Change: `Grant` (`app/src/permission.zig`) owns both the view click flag (`close_requested`) and `poll`. `poll` drains `close_requested` via `dismiss` first so a queued poll completes dismissal instead of re-presenting.

### 8. Full Disk Access granted after ✕ dismissal (finding 8)

Cause: `Flow.dismiss` stopped polling, so granting access in System Settings after closing the floating card never rebuilt `FileIndex` until relaunch.

Change: `Grant.dismiss` hides the panel and clears the drag rect immediately while keeping a single silent `slow_poll_ms` (`5000 ms`) timer running without reading window anchors. When `poll(true)` observes the grant while `dismissed`, `Grant` moves to `granted`, emits `rebuild_index` once without showing the window, and stops polling.

### 9. Open

9. Fix 3 keeps the newest copy. With pins over the byte budget, every other
   unpinned entry still goes on each add. Whether pins count toward the byte
   budget is a product decision. Plan 001 defers byte budgets.
