# Plan 002: Web suggestions wait for a typing pause, skip one-letter queries, and are documented

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/main.zig frontends/nanoui/src/panel.zig frontends/nanoui/src/tests.zig README.md`
> **Extra check for this plan**: `main.zig`, `panel.zig` and `tests.zig` had
> uncommitted changes when this plan was written, and the excerpts below come
> from that working tree, not from commit `64cc313`. Line numbers can be off.
> Find each excerpt with `rg` by its text and confirm it before you edit.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: security (privacy)
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-10

## Why this matters

`frontends/nanoui` is Floodlight's Zig frontend, a Spotlight-style launcher.
In search mode it asks Google's suggestion endpoint for completions. Today a
request leaves on every keystroke, starting with the first letter, and the
feature is on by default. Typing a 12-letter file name sends up to 12 prefixes
of it to `suggestqueries.google.com`. No README section or ADR mentions this.

After this plan: a request leaves only after the user pauses typing for
150 ms, never for a query shorter than 2 bytes, and the README states what is
sent, when, and how to turn it off.

**Decided by the maintainer on 2026-11-10**: suggestions stay on by default.
Do not change the default.

## Current state

Files:

- `frontends/nanoui/src/panel.zig` — the panel model. Decides whether a query
  needs suggestions and calls a hook.
- `frontends/nanoui/src/main.zig` — the app shell. `Shell.suggest` is the hook
  implementation that performs the HTTP request.
- `frontends/nanoui/src/search.zig` — holds the URL (read only for this plan):
  `pub const web_suggest_url = "https://suggestqueries.google.com/complete/search?client=firefox&q=";`
- `frontends/nanoui/src/tests.zig` — all nanoui tests.

The panel calls the hook on each answered keystroke (`panel.zig`, in
`pub fn refresh`):

```zig
        p.completion = p.computeCompletion();
        if (need_fetch) {
            p.suggest_seq += 1;
            p.pending_suggest_seq = p.suggest_seq;
            p.pending_suggest_query.clearRetainingCapacity();
            p.pending_suggest_query.appendSlice(p.list.arena.child_allocator, text) catch {};
            p.hooks.suggest(p.hooks.ctx, p.pending_suggest_seq, text);
        }
```

The only gate on the query (`panel.zig`, `fn shouldSuggest`):

```zig
    fn shouldSuggest(p: *Panel, text: []const u8) bool {
        if (!p.web_suggestions_enabled or p.mode != .search) return false;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return false;
        if (isPathLike(text) or isPathLike(trimmed)) return false;
        return !hasLinkRow(p.base_rows);
    }
```

`pending_suggest_seq: u64 = 0` is a public field of `Panel`. It is 0 when no
request is wanted, and it changes on every new request and on cancel
(`fn cancelPendingSuggest` sets it to 0). The panel already drops a late
response whose `seq` differs (`pub fn receiveSuggestionsFor`).

The shell sends immediately (`main.zig`, inside `const Shell = struct`):

```zig
    const SuggestRequest = struct {
        shell: *Shell,
        seq: u64,
        query: []u8,
    };

    fn suggest(ctx: ?*anyopaque, seq: u64, query: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.headless) return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const url = search.webSuggestUrl(arena.allocator(), std.mem.trim(u8, query, " \t\r\n")) catch return;
        const q_copy = gpa.dupe(u8, query) catch return;
        const req = gpa.create(SuggestRequest) catch {
            gpa.free(q_copy);
            return;
        };
        req.* = .{ .shell = s, .seq = seq, .query = q_copy };
        nanoui.http.fetch(gpa, .{ .url = url }, req, onSuggest);
    }

    fn onSuggest(req: *SuggestRequest, res: nanoui.http.Response) void {
        defer {
            gpa.free(req.query);
            gpa.destroy(req);
        }
```

The shell already uses a one-shot timer for other work. The callback type and
call shape are (`main.zig`):

```zig
    fn captureTick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        defer nanoui.App.after(clipboard_poll_ms, s, captureTick);
```

Timer constants live at the top of `main.zig`, for example
`const clipboard_poll_ms = 500;`.

The opt-out exists already (`main.zig`, in `main`): the key `web_suggestions`
in `nanoui.kv.standard()` with value `0` or `false` calls
`shell.panel.setWebSuggestionsEnabled(false)`.

Tests use a spy hook, `SuggestSpy` in `tests.zig`, that records every query
the panel asks for in `spy.queries`. The existing test named
`"with the setting off, or for a Link Row, a path-like query, or Clipboard mode, the suggestion source receives no request"`
is the structural pattern: it builds a `Panel` with `spy.hooks()`, a
`ui.Tester`, calls `tester.typeText("weather")`, and asserts on
`spy.queries.items.len`.

Repo conventions that apply (from `CLAUDE.md`):

- A comment says **why**, never what the next line does. No commented-out code.
- Zig code is checked with `zig fmt --check`. Format with the repo's Zig, never
  by hand.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| nanoui tests, format check, bundle | `make test-nanoui` | exit 0 |
| Repo gates | `make check` | exit 0 |

`make test-nanoui` runs `scripts/test-nanoui.sh`, which runs
`zig fmt --check`, `zig build test --summary all`, a bench, and a bundle
build. If Zig is missing, `make install-zig` installs the pinned version.

## Scope

**In scope** (the only files you should modify):

- `frontends/nanoui/src/panel.zig`
- `frontends/nanoui/src/main.zig`
- `frontends/nanoui/src/tests.zig`
- `README.md` (one new short section; this plan authorizes that docs change)

**Out of scope** (do NOT touch):

- The default value `web_suggestions_enabled: bool = true` in `panel.zig`.
  The maintainer decided it stays on.
- `frontends/nanoui/src/search.zig` — the URL and response parsing stay as is.
- The suggestion cache (`suggestion_cache_ttl`, `cachedSuggestions`).
- `Sources/**` — the Swift app does not have this feature.
- `docs/adr/**`.

## Git workflow

- The repository was on a detached `HEAD` with unrelated uncommitted changes,
  including in the three Zig files above. Do not stash, reset, or discard
  them. Build on top of them.
- Branch: `advisor/002-web-suggestions-debounce`
- Commit style is Conventional Commits, for example
  `feat(nanoui): YouTube, X and Grok rows under Google (#151)`.
  Use `fix(nanoui): ...` here.
- Stage only your own hunks. If you cannot separate them from the pre-existing
  uncommitted changes in the same file, do not commit; report that instead.
- Do NOT push or open a PR.

## Steps

### Step 1: Skip queries shorter than 2 bytes

In `panel.zig`, add a public constant next to `suggestion_cache_ttl`:

```zig
/// One letter says almost nothing about what the user wants and would send
/// the first keystroke of every query off the machine.
pub const min_suggest_bytes = 2;
```

In `fn shouldSuggest`, replace `if (trimmed.len == 0) return false;` with
`if (trimmed.len < min_suggest_bytes) return false;`.

The unit is bytes on purpose: one CJK character is 3 bytes and still
qualifies.

**Verify**: `make test-nanoui`. Some existing tests may type a single
character and expect a suggestion request. For each such failure, change the
test's query to two or more characters if the test is about something other
than the minimum length. Do not weaken any assertion. Expected after fixes:
exit 0.

### Step 2: Delay the request by 150 ms and drop it if the query moved on

In `main.zig`:

1. Add near the other timer constants: `const suggest_debounce_ms = 150;`
2. Change `Shell.suggest` so it only records the request and arms a timer:

```zig
    fn suggest(ctx: ?*anyopaque, seq: u64, query: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.headless) return;
        const q_copy = gpa.dupe(u8, query) catch return;
        const req = gpa.create(SuggestRequest) catch {
            gpa.free(q_copy);
            return;
        };
        req.* = .{ .shell = s, .seq = seq, .query = q_copy };
        nanoui.App.after(suggest_debounce_ms, req, sendSuggest);
    }
```

3. Add `sendSuggest`, which sends only when this request is still the one the
   panel is waiting for:

```zig
    /// A request the panel has since replaced or cancelled never leaves the
    /// machine: only the query the user paused on is sent.
    fn sendSuggest(ctx: ?*anyopaque) callconv(.c) void {
        const req: *SuggestRequest = @ptrCast(@alignCast(ctx));
        const s = req.shell;
        if (req.seq != s.panel.pending_suggest_seq) {
            gpa.free(req.query);
            gpa.destroy(req);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const url = search.webSuggestUrl(arena.allocator(), std.mem.trim(u8, req.query, " \t\r\n")) catch {
            gpa.free(req.query);
            gpa.destroy(req);
            return;
        };
        nanoui.http.fetch(gpa, .{ .url = url }, req, onSuggest);
    }
```

Leave `onSuggest` unchanged. It already frees the request.

**Verify**: `make test-nanoui` → exit 0 (this compiles the bundle, which is
the only build that includes `main.zig`'s shell).

### Step 3: Add the panel tests (see Test plan)

**Verify**: `make test-nanoui` → exit 0, new tests listed as passed.

### Step 4: Document the behaviour in `README.md`

Find the README section that describes the nanoui frontend
(`rg -n -i "nanoui|Nanospot" README.md`). Add a short subsection titled
`Web suggestions` there. If the README has no nanoui section, add the
subsection at the end of the file. It must state, in plain sentences:

- In search mode the nanoui frontend sends the typed query to
  `suggestqueries.google.com` to show up to four suggestions.
- A request is sent after a 150 ms typing pause, for queries of 2 bytes or
  more. Paths, links, and Clipboard mode never send one.
- The feature is on by default. Setting the `web_suggestions` key to `0` or
  `false` in the app's key-value store turns it off.

Do not describe how to write that key unless you can confirm the mechanism
from `nanoui.kv` usage in the repository; state only the key and its values.

**Verify**: `rg -n "suggestqueries.google.com" README.md` → 1 match, and
`make check` → exit 0.

## Test plan

Add to `frontends/nanoui/src/tests.zig`, modeled on the test
`"with the setting off, or for a Link Row, a path-like query, or Clipboard mode, the suggestion source receives no request"`
(same setup: `search.Catalog`, `TmpStore`, `openMemory`, `SuggestSpy`,
`panel_mod.Panel.init`, `ui.Tester`).

1. `"a one-byte query asks for no suggestions, a two-byte query and a single CJK character do"`
   - type `"w"` → `spy.queries.items.len` is 0
   - reset the panel (`p.reset(); tester.frame();`), type `"we"` → the last
     entry in `spy.queries` is `"we"`
   - reset, type `"天"` → the last entry in `spy.queries` is `"天"`

The debounce lives in the shell, which tests cannot construct (`Shell.suggest`
returns early when headless). It is covered by the bundle build plus this
manual check, which you must perform and report:

2. Read `sendSuggest` once more and confirm each of its three exits either
   frees `req` or hands it to `nanoui.http.fetch`. State the result in your
   report.

Verification: `make test-nanoui` → exit 0, including 1 new test.

## Done criteria

- [ ] `make test-nanoui` exits 0
- [ ] `make check` exits 0
- [ ] `rg -n "min_suggest_bytes" frontends/nanoui/src/panel.zig` returns 2 matches
- [ ] `rg -n "suggest_debounce_ms" frontends/nanoui/src/main.zig` returns 2 matches
- [ ] `rg -n "fn sendSuggest" frontends/nanoui/src/main.zig` returns 1 match
- [ ] `rg -n "suggestqueries.google.com" README.md` returns 1 match
- [ ] `rg -n "web_suggestions_enabled: bool = true" frontends/nanoui/src/panel.zig` still returns 1 match
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- An excerpt in "Current state" cannot be found by its text.
- `nanoui.App.after` does not accept a `*SuggestRequest` as its context
  argument, or its callback type is not `fn (?*anyopaque) callconv(.c) void`.
  Report the compile error.
- `nanoui.http.fetch` turns out to keep the `url` slice after it returns (the
  current code frees the arena right after the call, so this plan assumes it
  copies).
- More than five existing tests fail after Step 1. That suggests a test helper
  types queries one character at a time and asserts on every request, which
  changes the size of this plan.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The maintainer decided on 2026-11-10 that suggestions stay on by default.
  If that is ever reversed, the change is the default of
  `web_suggestions_enabled` in `panel.zig` plus a setting surface, and several
  suggestion tests would need `p.setWebSuggestionsEnabled(true)`.
- A reviewer should check the lifetime of `SuggestRequest`: it is now owned by
  the timer for 150 ms, then by the HTTP fetch.
- The 5-minute suggestion cache still answers without a request, so a
  re-typed query shows suggestions with no delay.
- This behaviour is not recorded in any ADR. If the project wants the decision
  recorded, that is a separate docs task.
