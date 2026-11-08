# Plan 001: Clipboard retention runs hourly and deleted data leaves the database file

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- Sources/Floodlight/Search/ClipboardCaptureService.swift Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift Sources/Floodlight/App/OnboardingSession.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug (privacy)
- **Planned at**: commit `64cc313`, 2026-11-10

## Why this matters

Floodlight is a macOS menu-bar app that stays running for weeks (it enables
launch-at-login on first run). Its Swift app keeps a clipboard history in
SQLite and promises a retention window (default 30 days). Today the prune runs
once, when the app launches. A user who changes retention from 30 days to
1 day sees nothing deleted until the next relaunch.

Deleted rows also never leave the file. On the maintainer's machine the
database measured 1.15 GB, of which 618 MB (150,821 of 281,054 pages) was
free-list pages still holding deleted clipboard content. `PRAGMA auto_vacuum`
read 0.

After this plan: the prune runs at launch and then at most once per hour, and
each prune (and each "clear history") returns freed pages to the filesystem.

## Current state

Files:

- `Sources/Floodlight/Search/ClipboardCaptureService.swift` — `@MainActor`
  class that polls the pasteboard every 0.5 s and owns the prune schedule.
- `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift` — the store.
  One SQLite connection guarded by `stateLock` (an `OSAllocatedUnfairLock`).
- `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift` — schema
  and SQL helpers (an `enum` namespace of static functions).
- `Sources/Floodlight/App/OnboardingSession.swift` — settings model. Writes the
  retention default directly and calls `clipboardStore.clear()`.

The only prune call (`ClipboardCaptureService.swift:162-176`):

```swift
    func start() {
        guard timer == nil else { return }
        lastChangeCount = observer.changeCount

        pruneOnSchedule()

        let timer = Timer
            .scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
```

and (`ClipboardCaptureService.swift:277-282`):

```swift
    private func pruneOnSchedule() {
        let retention = retention
        Task.detached(priority: .utility) { [store] in
            store.prune(retention: retention)
        }
    }
```

The service initializer (`ClipboardCaptureService.swift:124-137`) takes
`store`, `observer`, `exclusions`, `defaults`, `pollInterval`.

The retention is read from UserDefaults each time through the `retention`
computed property (`ClipboardCaptureService.swift:154-160`), so a prune that
runs later picks up a changed setting with no extra wiring.

The store's prune entry point (`ClipboardHistoryStore.swift:570-575`):

```swift
    @discardableResult
    package func prune(retention: ClipboardRetention, now: Date = .now) -> Bool {
        guard let cutoff = retention.cutoffDate(from: now) else { return true }
        return prune(olderThan: cutoff)
    }
```

The schema preamble (`ClipboardHistorySQLite.swift:29-31`):

```swift
    private static let schemaSQL = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
```

`ClipboardHistorySQLite` has a private throwing helper
`exec(_ db: OpaquePointer, _ sql: String) throws` (lines 64-73). Its doc
comment says "Schema work only". Compaction is storage maintenance, not a row
mutation, so it may use `exec`.

Clear from settings (`OnboardingSession.swift:147-150`):

```swift
    func clearClipboardHistory() {
        guard clipboardStore.clear() else { return }
        clipboardVersion += 1
    }
```

Precedent inside this repo: the Zig frontend does the same one-time migration
on open (`frontends/nanoui/src/clipboard.zig:589-590`):
`PRAGMA auto_vacuum=INCREMENTAL; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);`
and runs `PRAGMA incremental_vacuum` after each delete (line 713).

Repo conventions that apply (from `CLAUDE.md`):

- A comment says **why**. `///` states the contract, `//` states the reason.
  Never describe the operation on the next line. Never leave commented-out code.
- Never hand-format. Run `make format`.
- `.swiftlint.yml` thresholds are a ratchet set at the current worst offender.
  Do not raise a threshold. If a file-length or function-length rule fails,
  that is a STOP condition for this plan.
- Tests use Swift Testing (`import Testing`, `@Test func ...`, `#expect`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format | `make format` | exit 0 |
| Gates | `make check` | exit 0 |
| Tests | `make test` | exit 0, all pass |
| Focused tests | `swift test --filter ClipboardCaptureServiceTests` and `swift test --filter ClipboardHistoryStoreTests` | all pass |

## Scope

**In scope** (the only files you should modify):

- `Sources/Floodlight/Search/ClipboardCaptureService.swift`
- `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift`
- `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift`
- `Sources/Floodlight/App/OnboardingSession.swift`
- `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`
- `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift`

**Out of scope** (do NOT touch):

- `frontends/nanoui/**` — the Zig frontend has its own store. Plan 003 covers it.
- Any size budget for images. That is a separate product decision (see
  Maintenance notes).
- `PRAGMA secure_delete`. Do not add it.
- `.swiftlint.yml` thresholds.
- `docs/adr/**` and `README.md`.

## Git workflow

- The repository was on a detached `HEAD` with unrelated uncommitted changes
  when this plan was written. Do not stash, reset, or commit those files.
- Branch: `advisor/001-clipboard-retention-and-compaction`
- Commit style is Conventional Commits, for example
  `fix(nanoui): a cold summon reveals on its first presented frame`.
  Use `fix(clipboard): ...` here.
- Stage only the in-scope files by path. Do NOT push or open a PR.

## Steps

### Step 1: Add `compact` to the SQL helpers and the store

In `ClipboardHistorySQLite.swift`:

1. Insert `PRAGMA auto_vacuum = INCREMENTAL;` as the first line of `schemaSQL`,
   before `PRAGMA journal_mode = WAL;`. On a new database this takes effect
   because no table exists yet. On an existing database it is recorded and
   applied by the next `VACUUM`.
2. Add a static function:

```swift
    /// Returns freed pages to the filesystem. A database created before
    /// auto-vacuum was set is rebuilt once, which is the only way SQLite
    /// applies that setting to an existing file.
    static func compact(db: OpaquePointer) throws {
        if try autoVacuumMode(db: db) != 2 {
            try exec(db, "PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")
        } else {
            try exec(db, "PRAGMA incremental_vacuum;")
        }
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }
```

3. Add a private static `autoVacuumMode(db:) throws -> Int32` that prepares
   `PRAGMA auto_vacuum;`, steps once, and returns `sqlite3_column_int(stmt, 0)`.
   Throw `Failure` (the existing error type in this file) when prepare fails.

In `ClipboardHistoryStore.swift`, add next to `prune(retention:now:)`:

```swift
    /// Shrinks the database file after deletions. Holds the store's lock, so
    /// call it off the main thread.
    @discardableResult
    package func compact() -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }
            do {
                try ClipboardHistorySQLite.compact(db: db)
                return true
            } catch {
                Self.logFailure(operation: "compact", message: "\(error)")
                return false
            }
        }
    }
```

Do not bump `mutationVersion`: no entry changed.

**Verify**: `swift build` → exit 0.

### Step 2: Prune at most once per hour and compact after each prune

In `ClipboardCaptureService.swift`:

1. Add an initializer parameter `pruneInterval: TimeInterval = 3_600` after
   `pollInterval`, stored in a `private let pruneInterval`.
2. Add `private var lastPruneAt: Date?`.
3. Replace `pruneOnSchedule()` with:

```swift
    /// Starts a prune when none has run within `pruneInterval`, and returns
    /// its task so a test can wait for it. The retention is read now, so a
    /// changed setting takes effect at the next run without a relaunch.
    @discardableResult
    func pruneIfDue(now: Date = .now) -> Task<Void, Never>? {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < pruneInterval {
            return nil
        }
        lastPruneAt = now
        let retention = retention
        return Task.detached(priority: .utility) { [store] in
            store.prune(retention: retention, now: now)
            store.compact()
        }
    }
```

4. In `start()`, replace the `pruneOnSchedule()` call with `pruneIfDue()`.
5. In the timer closure in `start()`, call `self?.pruneIfDue()` before
   `self?.poll()`. The check is one date comparison per tick. It must run
   whether or not capture is enabled, so it must not go inside `poll()`.

**Verify**: `swift build` → exit 0, and
`rg -n "pruneOnSchedule" Sources Tests` → matches only inside comments in
`Tests/` (one doc comment mentions the old name; update that comment to say
`pruneIfDue`).

### Step 3: Compact after "clear history"

In `OnboardingSession.swift`, change `clearClipboardHistory()` so a successful
clear is followed by a background compaction:

```swift
    func clearClipboardHistory() {
        guard clipboardStore.clear() else { return }
        clipboardVersion += 1
        Task.detached(priority: .utility) { [clipboardStore] in
            clipboardStore.compact()
        }
    }
```

**Verify**: `swift build` → exit 0.

### Step 4: Write the tests (see Test plan), then run all gates

**Verify**: `make format && make check && make test` → all exit 0.

## Test plan

Add to `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`, inside
`struct ClipboardCaptureServiceTests`, using the existing `makeHarness()`
helper (it builds an in-memory store, a `ScriptedPasteboardObserver`, and a
private `UserDefaults` suite). The store's `record(text:sourceAppBundleID:date:)`
accepts a `date`, so tests can create old entries.

1. `pruneIfDueRunsOnceThenWaitsForTheInterval` — first call returns a task,
   a second call 10 seconds later returns `nil`, a call 3,601 seconds later
   returns a task.
2. `aRetentionChangedAfterLaunchIsEnforcedAtTheNextPrune` — record one entry
   dated 10 days before a fixed `now`. Call `pruneIfDue(now: now)` and `await`
   its `value`: the entry stays (default retention is 30 days). Set
   `harness.service.retention = .days(7)`. Call
   `pruneIfDue(now: now.addingTimeInterval(3_601))` and `await` it: the store
   is empty. This is the regression test for the bug.
3. `pruneIfDueRunsWhileCaptureIsDisabled` — set the service's `isEnabled`
   to `false`, then repeat the shape of test 2 with a 40-day-old entry and
   assert it is pruned.

Mark async tests `@Test func name() async`.

Add to `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift`. Use the
existing test `diskStorePersistsAndReloadsEntriesPinsAndFTS` (around line 265)
as the pattern for creating a store on disk in a temporary directory.

4. `compactShrinksTheFileAfterClear` — open a disk store, record 200 entries of
   30,000 bytes each with distinct text (for example a counter prefix followed
   by repeated letters), call `compact()` once and read the file size, then
   `clear()`, `compact()`, and read the file size again. Expect the second size
   to be less than a quarter of the first. Read sizes with
   `FileManager.default.attributesOfItem(atPath:)[.size]`.
5. `compactConvertsADatabaseCreatedWithoutAutoVacuum` — create a database file
   with the SQLite C API (`import SQLite3`; `sqlite3_open`, then
   `sqlite3_exec` of `CREATE TABLE seed(a);`, then `sqlite3_close`). Open it
   with `ClipboardHistoryStore(databaseURL:)`, call `compact()`, release the
   store, reopen the file with `sqlite3_open`, and expect
   `PRAGMA auto_vacuum;` to return 2.

Before writing the fix for test 2, confirm it fails against the old code path
if you still can (or reason from the old `start()`-only call); after the fix
all five must pass.

Verification: `make test` → exit 0, including 5 new tests.

## Done criteria

- [ ] `make check` exits 0
- [ ] `make test` exits 0; the 5 new tests exist and pass
- [ ] `rg -n "func pruneOnSchedule" Sources` returns no matches
- [ ] `rg -n "auto_vacuum = INCREMENTAL" Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift` returns 2 matches
- [ ] `git status --short` shows no modified files outside the in-scope list
      other than files that were already modified before you started
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" does not match the excerpts.
- `make check` fails on a SwiftLint length threshold (file, type body, or
  function length). Report which file and by how much. Do not raise the
  threshold and do not restructure the store on your own.
- `VACUUM` fails in test 5 with a "cannot VACUUM" error. That means a
  statement is still open on the connection, which this plan assumes cannot
  happen under `stateLock`.
- Test 4 cannot reach the expected shrink. Report the two sizes.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The first launch after this change rebuilds an existing database once. On a
  1 GB file that takes seconds and holds the store's lock, so a clipboard
  search on the main thread waits during that one run. It runs from a detached
  task after launch, not during window presentation. A reviewer should weigh
  that one-time stall.
- A lowered retention now deletes within one hour, not at the next launch.
  There is no undo. The hour is the only grace period.
- Deferred on purpose: the Swift store has no byte budget. It stores PNG and
  TIFF inline at up to 15 MB each (`ClipboardHistoryStore.swift:9`), while the
  Zig frontend caps history at 150 MB. Adding a budget is a product decision.
- Deferred on purpose: Quick Look preview files in the temporary folder
  (`ClipboardSearch.swift:271-288`) are never removed, including after the
  entry is deleted.
