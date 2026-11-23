# State machines in the Zig app

## At a glance

The Zig app (`frontends/nanoui` over `core/`) runs eleven state machines.
Two are explicit enums: Presence and the grant flow. The rest are implicit,
spread over flags, counters, arenas and timers. The worst reachable bug was a
use-after-reset. The panel handed the shell an action that pointed into the
result list's memory. Any query between the ask and the shell's turn reused
that memory, so Return could paste or open a different item.

Four bugs are fixed, each with a regression test that failed before its fix.
Five findings stay open and are listed with their reason. The search ranking,
the file index protocol and the clipboard schema are unchanged.

Scope: Zig only. The Swift app in `Sources/` is out of scope. It is cited
where the Zig port copies its behaviour.

## How control reaches these machines

Everything except the file index scan runs on the main thread. "Concurrency"
here means interleaving on the main dispatch queue, not data races. A turn is
one main-queue work item or one frame. Turns interleave in this order:

```text
 frame (key, click)          main queue, FIFO-ish                 scan thread
┌──────────────────┐        ┌──────────────────────────────┐     ┌───────────┐
│ Panel.view       │──ask──▶│ applyPanel   (dispatch_async) │     │ rebuild() │
│  ask() sets      │        │ captureTick  (after 500 ms)   │◀────│ indexReady│
│  Panel.pending   │        │ landFiles    (after 0 ms)     │     └───────────┘
└──────────────────┘        │ indexLanded  (dispatch_async) │
                            │ pollTick, expireRetention ... │
                            └──────────────────────────────┘
```

A nested run loop also drains the queue mid-turn. The ⌘K menu
(`mac.popUpMenu`, called from `Shell.actionsMenu`) runs every timer while it
is open. So any machine whose transition is split across two turns can see
other transitions in between. Findings 1 and 2 come from that split.

## 1. Panel Presence (explicit)

`frontends/nanoui/src/presence.zig`. Phase: `hidden`, `entering`, `shown`.
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

`Panel.ask` (`panel.zig:888`) stores `Panel.pending` and calls the request
hook. `Shell.panelRequest` (`main.zig:228`) dispatches `applyPanel`
(`main.zig:241`) to a later turn. That turn runs the action, then
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

## 5. Staged file search (implicit)

`Panel.files_due`, `Shell.landing_files`, `Panel.landFiles`
(`panel.zig:544`), `Shell.landFiles` (`main.zig:153`). A query over the
4 ms budget answers apps first. Files land on a 0 ms timer.

| From | Event | To |
|---|---|---|
| idle | `answer` over budget | due, timer queued once (`landing_files`) |
| due | another keystroke over budget | due, no second timer |
| due | timer, mode search, text answered | idle, rows with files |
| due | timer, mode board or text changed | idle, files dropped (finding 7) |

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

`Shell.captureTick` (`main.zig:325`) compares the pasteboard change count
every 500 ms. `Store.add` (`clipboard.zig:766`) and `keepWithinBudget`
(`clipboard.zig:716`) keep history. A full image moves `png` → `avif` after
7 days through `compactOne` (`clipboard.zig:726`), which runs only while the
panel is hidden.

Invariants:

- Floodlight's own writes carry `own_write_type`, and `writeEntry` updates
  `change_count`, so they are never captured again.
- `change_count` advances before the capture runs. A capture that fails is
  never retried (finding 6).
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

`permission.zig:28`. Phase: `idle`, `guiding`, `granted`, `dismissed`. The
shell adds `polling` and `Guidance.dismissed` (`main.zig:462`).

Invariants: at most one poll timer is pending (`polling`). Polling runs only
while guiding.

| From | Event | Guard | To | Effects |
|---|---|---|---|---|
| any | `begin` | granted | granted | on_granted (rebuild index) |
| guiding | `begin` | not granted | guiding | present |
| idle, dismissed | `begin` | not granted | guiding | open_settings, present (poll armed) |
| guiding | poll | granted | granted | on_granted, linger 1.5 s |
| guiding | poll | not granted | guiding | present (poll rearmed) |
| granted | linger ends | | dismissed | close |
| any | ✕ on the card | | dismissed | close; polling stops (finding 8) |

## 10. File index rebuild (explicit protocol, real threads)

`core/src/file_index.zig:97`. Atomics `running`, `requested`, `ready`.
The scan runs on a detached thread. `adopt` runs on the main thread.

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
| D. Small main-queue races | 5, 6, 7 | State cleared before the step that needs it | Open |
| E. A grant after ✕ is not seen | 8 | Polling stops on dismissal, as in Swift | Open |

## Findings

Ranked by impact. "Fixed" findings have a test in
`frontends/nanoui/src/tests.zig` that failed before the fix.

| # | Machine | Invalid state | Reach | Impact | Status |
|---|---|---|---|---|---|
| 1 | Pending action, result list | Action bytes freed by a query before the shell runs it | Confirmed | Wrong item pasted or opened | Fixed |
| 2 | Presence | Settle on a hidden panel | Plausible | ⌘V into another app, a dismissed panel summoned again, a repeated exit | Fixed |
| 3 | History budget | `add` true, entry evicted | Confirmed | Every new copy lost while pins fill the budget | Fixed |
| 4 | Retention | Several expiry timers pending | Confirmed | Extra wakeups only | Fixed |
| 5 | Grant flow | ✕ undone by a poll tick | Plausible | Click ignored, about 1 in 100 by timing estimate | Open |
| 6 | Capture | Failed capture not retried; partial capture not shown | Confirmed by reading | One copy missing until the next refresh | Open |
| 7 | File staging | Files dropped when the 0 ms timer lands in board mode | Plausible, narrow | A restored query without file rows | Open |
| 8 | Grant flow | Grant after ✕ never detected | Confirmed, by design | Index without protected folders until relaunch | Open, matches Swift |
| 9 | History budget | Pins over the byte budget evict all other history | Confirmed | History one entry deep | Open, product decision |

### 1. Actions borrowed the result list's memory

Cause: `Action` carries slices (`open: []const u8`, `copy: Row`,
`paste: Entry`). They pointed into `list.arena`, which `beginQuery` resets
with `.retain_capacity`. The apply runs on a later turn (section 2). Three
turns can query between the ask and the apply:

- `captureTick` marks the board stale and refreshes it when another app
  copies. This includes the seconds the ⌘K menu stays open, because
  `popUpMenu` runs a nested run loop. `actionsMenu` then pastes `e`.
- `indexLanded` (`main.zig:531`), dispatched from the scan thread, marks the
  search list stale and refreshes it.
- `landFiles` reanswers the query with file rows.

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

### 5–9. Open

5. `Shell.present` sets `guidance.dismissed = false` (`main.zig:464`). A poll
   tick queued before `applyGuidance` clears the ✕ click. The window is the
   time between the frame and the queue drain, out of a 500 ms poll. The
   timing ratio is an estimate, not a measurement. The shell has no test
   seam, so this stays open.
6. `captureTick` advances `change_count` before `Store.capture`. A capture
   that errors (SQLite busy past 2 s, disk full) is lost. When the second of
   two files fails, the first is stored but the board is not marked stale.
7. `Panel.landFiles` clears `files_due` before it checks the mode. If the
   timer runs after a switch to the board, the retained search query restores
   later without its file rows, and `refresh` sees an unchanged query.
8. Both the Swift coordinator and the Zig port stop polling on ✕. A grant
   made afterwards is seen only at the next launch.
9. Fix 3 keeps the newest copy. With pins over the byte budget, every other
   unpinned entry still goes on each add. Whether pins count toward the byte
   budget is a product decision. Plan 001 defers byte budgets.
