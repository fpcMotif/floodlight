# Plan 005: One- and two-character CJK, emoji, and accented clipboard queries return matches

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift docs/adr/0009-clipboard-entry-classification.md`
> Plan 001 also edits `ClipboardHistoryStore.swift`. If it has landed, line
> numbers will differ, but the `search` excerpt below must still match by
> text. On a text mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `64cc313`, 2026-11-10

## Why this matters

The Swift app searches clipboard history two ways. Queries of three or more
characters go to an SQLite FTS5 index with the `trigram` tokenizer. Shorter
queries cannot be answered by a trigram index, so they scan an in-memory
window instead. The code decides "short" by counting UTF-8 **bytes**, but the
trigram tokenizer needs three **characters**. One Chinese, Japanese or Korean
character is 3 bytes and one emoji is 4 bytes, so those queries are sent to
the index, which returns nothing.

Measured with the `sqlite3` CLI against an FTS5 trigram table holding
`日本語のテキスト` and `hello 😀 world`: `MATCH '"日本"'` returns 0 rows,
`MATCH '"😀"'` returns 0 rows, `MATCH '"日本語"'` returns 1 row.

So a user who types `日本` into the clipboard board sees an empty list even
when matching entries exist. After this plan those queries use the in-memory
scan and return matches.

## Current state

Files:

- `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift` — the store;
  `search(query:)` picks the path.
- `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift` — store tests.
- `docs/adr/0009-clipboard-entry-classification.md` — records the short-query
  rule in bytes; must be corrected to match.

The branch in `search(query:)` (`ClipboardHistoryStore.swift:364-384`):

```swift
            if trimmed.isEmpty {
                return state.pinnedEntries + state.recentEntries
            }

            if trimmed.utf8.count < 3 {
                return Self.windowMatches(in: state, query: trimmed)
            }

            // FTS5 trigram search for queries of 3 or more characters
            let escaped = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if let matches = ClipboardHistorySQLite.fetchMatches(
                db: db,
                ftsQuery: escaped,
                limit: Self.searchResultLimit
            ) {
                return matches
            }

            // Fallback to in-memory filter if FTS query preparation fails
            return Self.windowMatches(in: state, query: trimmed)
```

`windowMatches` does a case-folded substring scan over pinned entries plus the
most recent 1,000 (`ClipboardHistoryStore.swift:390-396`). It needs no change.

The index is declared with `tokenize='trigram'`
(`Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift:45-50`). The
tokenizer works on Unicode code points, so the right unit in Swift is
`unicodeScalars.count`, not `count` (grapheme clusters) and not `utf8.count`.
Example: `é` written as `e` plus a combining accent is one grapheme but two
scalars.

The ADR sentence to correct (`docs/adr/0009-clipboard-entry-classification.md`,
in the "What moved" list; find it with
`rg -n "under three UTF-8 bytes" docs/adr/0009-clipboard-entry-classification.md`):

> Short queries — under three UTF-8 bytes, which the trigram index cannot answer — scan a case-folded copy of each windowed entry's text …

The existing test to model on
(`ClipboardHistoryStoreTests.swift`, `shortQueriesFilterInMemoryWindowCaseInsensitively`):

```swift
    @Test func shortQueriesFilterInMemoryWindowCaseInsensitively() {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Xcode 16 beta")
        _ = store.record(text: "swift Concurrency")
        _ = store.record(text: "xctest runner")

        // 1 character query
        let xMatches = store.search(query: "x")
        #expect(xMatches.map(\.text) == ["xctest runner", "Xcode 16 beta"])
```

`search` returns newest first within the unpinned block.

Repo conventions that apply (from `CLAUDE.md`):

- A comment says **why**, never what the next line does. Existing comments
  stay as written; do not reword or delete them.
- Never hand-format Swift; run `make format`.
- Maintained documents describe the current state: rewrite the ADR sentence in
  place, do not append a correction note.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `swift test --filter ClipboardHistoryStoreTests` | all pass |
| Format | `make format` | exit 0 |
| Gates | `make check` | exit 0 |
| Tests | `make test` | exit 0 |

## Scope

**In scope** (the only files you should modify):

- `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift` (one line)
- `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift`
- `docs/adr/0009-clipboard-entry-classification.md` (one sentence; this plan
  authorizes that docs change)

**Out of scope** (do NOT touch):

- The FTS schema and tokenizer in `ClipboardHistorySQLite.swift`.
- `windowMatches`, `searchKey`, `fold`.
- `frontends/nanoui/**` — the Zig frontend searches with `instr(lower(...))`
  and does not have this bug.
- Performance tests and their budgets.

## Git workflow

- The repository was on a detached `HEAD` with unrelated uncommitted changes.
  Do not stash, reset, or commit those files.
- Branch: `advisor/005-short-cjk-clipboard-queries`
- Conventional Commits, for example `fix(clipboard): ...`.
- Stage only the three in-scope files by path. Do NOT push or open a PR.

## Steps

### Step 1: Write the failing test first

Add the test from the Test plan and run it.

**Verify**: `swift test --filter ClipboardHistoryStoreTests` → the new test
fails with empty results for the CJK and emoji queries. If it passes before
the fix, STOP.

### Step 2: Count Unicode scalars

In `search(query:)`, change

```swift
            if trimmed.utf8.count < 3 {
```

to

```swift
            if trimmed.unicodeScalars.count < 3 {
```

Change nothing else in the function.

**Verify**: `swift test --filter ClipboardHistoryStoreTests` → all pass.

### Step 3: Correct the ADR sentence

In `docs/adr/0009-clipboard-entry-classification.md`, replace the words
`under three UTF-8 bytes` with `under three Unicode scalars`. Leave the rest
of the sentence and the file unchanged.

**Verify**:
`rg -n "under three UTF-8 bytes" docs/adr/0009-clipboard-entry-classification.md`
→ no matches, and
`rg -n "under three Unicode scalars" docs/adr/0009-clipboard-entry-classification.md`
→ 1 match.

### Step 4: Run all gates

**Verify**: `make format && make check && make test` → all exit 0.

## Test plan

Add one test to `struct ClipboardHistoryStoreTests`, next to
`shortQueriesFilterInMemoryWindowCaseInsensitively`:

`shortQueriesAreMeasuredInCharactersNotBytes`

- record, in this order: `"日本語のテキスト"`, `"hello 😀 world"`, `"café menu"`,
  `"plain ascii"`
- `store.search(query: "日").map(\.text) == ["日本語のテキスト"]` (1 scalar, 3 bytes)
- `store.search(query: "日本").map(\.text) == ["日本語のテキスト"]` (2 scalars, 6 bytes)
- `store.search(query: "😀").map(\.text) == ["hello 😀 world"]` (1 scalar, 4 bytes)
- `store.search(query: "é ").map(\.text) == ["café menu"]` — the query is
  trimmed to `é`, 1 scalar and 2 bytes in precomposed form; this case already
  passes today and guards the old behaviour
- `store.search(query: "日本語").map(\.text) == ["日本語のテキスト"]` (3 scalars;
  goes to the trigram index and must still match)

The first three expectations are the regression. They must fail before Step 2
and pass after.

Verification: `make test` → exit 0, including 1 new test.

## Done criteria

- [ ] `make check` exits 0
- [ ] `make test` exits 0; `shortQueriesAreMeasuredInCharactersNotBytes` exists and passes
- [ ] `rg -n "utf8.count < 3" Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift` returns no matches
- [ ] `rg -n "unicodeScalars.count < 3" Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift` returns 1 match
- [ ] `rg -n "under three UTF-8 bytes" docs/adr` returns no matches
- [ ] `git status --short` shows no modified files outside the in-scope list
      other than files that were already modified before you started
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `search` excerpt does not match the live code by text.
- The new test passes before the fix is applied.
- A performance test in `make test` fails after the change. Report its name
  and numbers; do not adjust a budget.
- An edit to `docs/adr/` is blocked by a repository hook. Report the hook's
  message; the code and test changes can still be delivered.

## Maintenance notes

- Short queries only see pinned entries plus the newest 1,000. A two-character
  CJK query therefore does not find an older entry that a three-character
  query would. That limit already applies to Latin short queries.
- If the tokenizer is ever changed from `trigram`, this threshold must be
  revisited with it.
- A reviewer should confirm the ADR edit is a single phrase and nothing else.
