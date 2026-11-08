# Plan 015: History completion asks the store once per query, and the Full Disk Access poll backs off

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/panel.zig frontends/nanoui/src/permission.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and other plans edit `panel.zig` and `main.zig`.
> Line numbers will be off. Find each excerpt with `rg` by its text.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (run after plans 008, 009 and 014 if they are
  scheduled, because they edit `panel.zig`)
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher. Two
pieces of code run far more often than their inputs change.

1. Inline completion. The panel suggests the rest of a query from query
   history in SQLite. The lookup compiles a statement, scans up to 1,000
   history rows, and sorts them. It runs on every build of the view. A
   keystroke builds the view two to four times, and while the panel is
   open the blinking caret builds it twice a second. The query text did not
   change between those builds.
2. The Full Disk Access guide. When the app launches without Full Disk
   Access it shows a guide and polls twice a second. Each poll lists the
   screen's windows, checks the grant, and redraws the guide. If the user
   ignores the guide, the poll never stops.

After this plan the history lookup runs once per distinct query, and the
poll slows to once every 5 seconds after its first minute.

## Current state

Files:

- `frontends/nanoui/src/panel.zig` — the search panel.
- `frontends/nanoui/src/permission.zig` — the Full Disk Access flow.
- `frontends/nanoui/src/main.zig` — app shell; owns timers.
- `frontends/nanoui/src/clipboard.zig` — the store. Read only here.

The completion is recomputed in every build (`panel.zig`):

```zig
    fn syncFieldState(p: *Panel, c: *ui.Context, caret: usize) void {
        ...
        p.caret_at_end = at_end;
        p.composing = marked;
        const next = p.computeCompletion();
        if (!sameCompletion(p.completion, next)) {
            p.completion = next;
            c.changed = true;
        }
    }
```

`computeCompletion` (`panel.zig`). The two store calls are the cost:

```zig
    fn computeCompletion(p: *Panel) ?Completion {
        if (p.suppressed_by_backspace or !p.caret_at_end or p.composing) return null;
        const query = p.field.text();
        if (query.len == 0) return null;
        if (p.mode == .clipboard) {
            const store = p.store orelse return null;
            const match = store.completeQuery(&p.completion_buf, .clipboard, query, p.clock.now()) orelse return null;
            return .{ .suffix = match[query.len..], .source = .history };
        }
        if (hasLinkRow(p.list.rows)) return null;
        if (p.store) |store| {
            if (store.completeQuery(&p.completion_buf, .search, query, p.clock.now())) |match| {
                return .{ .suffix = match[query.len..], .source = .history };
            }
        }
```

`completeQuery` writes its answer into `p.completion_buf` and returns a
slice of it (`clipboard.zig`):

```zig
    pub fn completeQuery(s: Store, buf: []u8, scope: QueryScope, prefix: []const u8, now: f64) ?[]const u8 {
```

Query history changes in two places only: `store.recordQuery(...)`, called
from `Panel.recordActionQuery`, and `store.clearQueries()`. Find every
caller with
`rg -n 'recordQuery|clearQueries' frontends/nanoui/src --glob '!tests.zig'`.

The poll (`permission.zig`):

```zig
pub const poll_ms = 500;
...
    /// While guiding: the grant, or the panel presented again. Else nothing.
    pub fn poll(f: *Flow) void {
        if (f.phase != .guiding) return;
        if (f.effects.is_granted(f.effects.ctx)) {
            f.phase = .granted;
            f.effects.on_granted(f.effects.ctx);
            return;
        }
        f.effects.present(f.effects.ctx);
    }
```

and its timer (`main.zig`, in `present` and `pollTick`):

```zig
        if (!s.polling) {
            s.polling = true;
            nanoui.App.after(permission.poll_ms, s, pollTick);
        }
```

`Flow.begin` sets `phase = .guiding`. `Flow` has the fields `phase` and
`effects`.

Existing tests of the flow (`tests.zig`):
`test "polling keeps guiding until the grant, then stops"` and
`test "dismissing closes the panel and stops polling"`.

Conventions: comments say why, never what. Tests are named as sentences
about behavior.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |

## Scope

**In scope**:

- `frontends/nanoui/src/panel.zig` (`computeCompletion` and a small cache
  beside it; the callers of `recordQuery` and `clearQueries`)
- `frontends/nanoui/src/permission.zig` (`Flow`, `poll_ms`)
- `frontends/nanoui/src/main.zig` (the two `nanoui.App.after(permission.poll_ms, ...)`
  call sites)
- `frontends/nanoui/src/tests.zig`

**Out of scope**:

- `clipboard.zig`: do not change `completeQuery` or its SQL.
- `mac.keepLinkAtDisplayRate`. It keeps the display link at full rate while
  the panel is open. Its comment explains that it works around a stale
  frame bug in nanoui 0.9.2. Changing it needs that bug re-tested by hand;
  it is deferred.
- The clipboard capture timer (`captureTick`, every 500 ms). macOS has no
  pasteboard change notification, and an idle tick is one integer compare.

## Git workflow

- Branch: `advisor/015-fewer-idle-queries-and-wakeups`.
- Commit style: `perf(nanoui): history completion asks the store once per query`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Remember the last history answer

In `panel.zig` add a small cache to `Panel`:

- the query text it answers (an `ArrayList(u8)` owned by the panel's
  allocator, freed in `deinit`);
- the scope (`.search` or `.clipboard`);
- the answer: the length of the match stored in a second buffer, or "no
  match";
- a `valid: bool`.

Add `fn historyCompletion(p: *Panel, scope, query) ?[]const u8`. When the
cache is valid and holds the same scope and query, return the cached
answer. Otherwise call `store.completeQuery`, store the result, and return
it. Keep a "no match" answer too, so a query with no history is asked
once. Use this function in `computeCompletion` in place of both direct
`completeQuery` calls.

The cached answer must not live in `p.completion_buf` if another call can
overwrite that buffer; give the cache its own buffer of the same size.

**Verify**: `make test-nanoui` → exit 0.

### Step 2: Drop the answer when history changes

Set `valid = false` right after every `store.recordQuery(...)` and
`store.clearQueries()` call that `panel.zig` makes, and in the panel
functions that forget a session (`hide`, `expire`, or their equivalents;
find them with `rg -n 'pub fn (hide|expire|forget)' frontends/nanoui/src/panel.zig`).
If `clearQueries` is called from outside `panel.zig`, add a public
`pub fn historyChanged(p: *Panel) void` and call it there.

**Verify**: `make test-nanoui` → exit 0, and the new completion tests pass.

### Step 3: Back the poll off

In `permission.zig`:

- add `pub const slow_poll_ms = 5000;` and
  `pub const fast_polls = 120;` (one minute at 500 ms);
- add a `polls: u32 = 0` field to `Flow`;
- `begin` sets `polls = 0` when it enters `.guiding`;
- `poll` increments `polls` while guiding;
- add `pub fn pollDelayMs(f: *const Flow) u32` that returns `poll_ms` while
  `polls < fast_polls` and `slow_poll_ms` after.

In `main.zig`, use `s.flow.pollDelayMs()` at the call sites that pass
`permission.poll_ms` to `nanoui.App.after`.

**Verify**: `make test-nanoui` → exit 0, and the new flow tests pass.

## Test plan

Add to `tests.zig`.

Completion, using an existing completion test as the pattern (find one
with `rg -n 'completion' frontends/nanoui/src/tests.zig`). To count store
calls without changing `clipboard.zig`, compare behavior: change history
behind the panel's back and check which answer the panel shows.

- "history completion is asked once per query": record `calendar`, type
  `cal`, expect the suffix `endar`. Call `store.recordQuery` directly for
  `calculator` several times so it outranks `calendar`, build three frames
  without typing, and expect the suffix to stay `endar`.
- "a recorded query refreshes the completion": after the panel itself
  records a query through an action, type again and expect the new best
  match.
- "a query with no history is asked once": type `zzz`, expect no history
  completion; add `zzzz` to history directly; build a frame; expect still
  none; type `zzzz` minus one character again after clearing the field;
  expect the completion.
- "clearing history clears the completion": clear queries through the
  panel's own path, type `cal`, expect no history completion.

Flow, using `test "polling keeps guiding until the grant, then stops"` as
the pattern:

- "the poll slows after a minute of guiding": begin, expect
  `pollDelayMs() == 500`; poll 120 times; expect `5000`.
- "beginning again polls fast again": dismiss, begin, expect `500`.

Each new test must fail before its step and pass after it.

Verification: `make test-nanoui` → all pass, including 6 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] `rg -n 'completeQuery' frontends/nanoui/src/panel.zig` shows one call
      site, inside `historyCompletion`.
- [ ] `rg -n 'permission.poll_ms' frontends/nanoui/src/main.zig` returns no
      matches.
- [ ] `git status --short` lists only in-scope files.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `recordQuery` or `clearQueries` is called from a place that has no access
  to the panel.
- An existing completion test fails twice.
- The completion shows a stale suggestion after an action in manual or
  automated testing.

## Maintenance notes

- Any new code that writes query history must invalidate the cache.
- The ranking in `completeQuery` uses the current time. A cached answer can
  be slightly out of date in rank within one query; it is refreshed on the
  next change of text.
- Deferred: the display link runs at full refresh rate while the panel is
  open (`mac.keepLinkAtDisplayRate`). It is a workaround for nanoui 0.9.2.
  Revisit it when nanoui is upgraded.
