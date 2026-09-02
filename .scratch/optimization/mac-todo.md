# Mac to-do: experiments, measurements, tests

Run these on a Mac. Nothing in the audit was measured, so baselines come first. Each item names the finding ID it confirms or refutes (see [`README.md`](README.md)).

## Prerequisites

```bash
xcode-select -p                      # Xcode 27 / Swift 6.4
make install-tools                    # pinned SwiftFormat, SwiftLint, ast-grep, Periphery
brew install hyperfine                # for wall-clock comparisons
rustup toolchain install stable       # only for the upstream FFF benches
```

Optional for the upstream section: `zig` 0.16 (for the `zlob` walker feature) and `cargo install cargo-instruments`.

## Global baselines (do once, keep the numbers)

- [ ] Release perf suite, record every `FLOODLIGHT_BENCH` line:

  ```bash
  make test-performance 2>&1 | tee .build/perf-baseline.log
  ```

- [ ] Cold start timeline with the existing signposts (`IndexStartup`, `SourceSearch`, `IndexedSourceSearch`, `ContentSourceSearch`, `ShowPanel`, `HidePanel`, `OpenSelection`, `ActivateRunningApplication`), subsystem `com.floodlight.app`:

  ```bash
  make bundle && open .build/Floodlight.app
  log stream --predicate 'subsystem == "com.floodlight.app"' --style compact
  ```

  Or profile in Instruments with the "App Launch" template plus the "os_signpost" instrument, then note: time to `ShowPanel` end, time to `IndexStartup` end.

- [ ] Dyld launch cost:

  ```bash
  DYLD_PRINT_STATISTICS=1 .build/Floodlight.app/Contents/MacOS/Floodlight
  ```

- [ ] Memory footprint after 5 minutes idle, and after copying 20 screenshots:

  ```bash
  footprint Floodlight
  ```

- [ ] Main-thread hangs: Instruments "Time Profiler" with "Hangs" track enabled, while (a) typing a 6-character query, (b) copying a 4K screenshot, (c) arrowing through 20 image entries in Clipboard mode.


# Search speed

## Search speed: algorithmic

## Search speed: algorithmic — Mac verification checklist

### Measure first (baseline)

- [ ] **Run existing perf suite cold, record every FLOODLIGHT_BENCH line as the pre-change baseline.**
  ```bash
  make test-performance
  ```
  Save the full output (especially `fast_application_search_us`, `filter_summary_us`, `top_ranked_selection_us`, `clipboard_history_search_us`). These numbers are machine-dependent (F18) so record them on the exact Mac you'll test changes on, not from CI.

- [ ] **Confirm real installed-app count on the test Mac** (bears on F1/F3/F4/F9/F18 sizing assumptions).
  ```bash
  find /Applications /System/Applications ~/Applications -maxdepth 1 -name '*.app' 2>/dev/null | wc -l
  ```
  Record the number. If it's 150-600 (expected), the reports' corrected "low hundreds" sizing is right and the original "~1,500" estimate should be discarded from any future write-up.

- [ ] **Cold-start / first-keystroke latency baseline** with Instruments Time Profiler: launch Floodlight, hold a single key (e.g. `a`) in the panel, capture a trace. Note which function is the top frame under `ApplicationCatalog.immediatePage` and `SystemCatalog.immediatePage`. [F1, F4, F17]

- [ ] **Confirm the app-search benchmark is currently measuring the runner's real catalog** (not a fixture) — read `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:18-20`, confirm no `discoveryProvider:` is passed, and note the actual candidate count the test exercises via a debug print. [F18]

- [ ] **Confirm blocklist state on the test machine**: check whether `UserDefaults.standard` has any Floodlight blocklist rules already (a prior manual test may have added some), since `BlocklistStore()`'s default reads that suite. [F4, F18]
  ```bash
  defaults read com.yourcompany.floodlight 2>/dev/null | grep -i block
  ```

- [ ] **Baseline clipboard search timing at realistic entry counts and sizes** — build/seed a 1,000-entry history with a handful of large (near 32,000-byte) text entries, time `store.search("a")`, `store.search("")`, `store.search("invoice")` separately (not averaged). [F5, F6, F20]

- [ ] **Baseline PathNavigator resolve cost** — in the panel, type a relative path-shaped query (e.g. `Doc` under a directory with a few hundred entries), Instruments File Activity template, confirm `getdirentries64`/`readdir` calls appear on the main thread. [F7]

### After implementing

- [ ] **F4 (blocklist reorder + normalizedName reuse)**: swap guard order in `ApplicationCatalog.immediatePage`; add `isBlocked(normalizedName:id:)`. Re-run `swift test --filter BlocklistStoreTests`. Add the empty-vs-blocklisted-comparison test described in the report; confirm the two numbers converge.
  ```bash
  swift test --filter BlocklistStoreTests
  make test-performance
  ```

- [ ] **F1 (initialMask prefilter)**: add `initialMask: UInt64` to `Application`, computed in `assignMarkerNames`; add `testApplicationCatalogInitialIndexBudget` with a synthetic 300-500 app fixture. Add the differential correctness test (indexed-mask path == full scan) over a 2,000-query corpus.
  ```bash
  swift test -c release --filter testApplicationCatalogInitialIndexBudget
  swift test --filter CatalogContractTests
  make test-performance
  ```
  Confirm `fast_application_search_us` for single-char queries drops meaningfully (target: 3-8x fewer scored candidates); confirm ranking output is unchanged.

- [ ] **F8 (typo-mask correctness fix)**: relax mask via `editBudget`-aware check or bypass for length≥3 queries. Add `CatalogTests` cases for `"chrone"→Chrome`, and a 4+ char settings typo case.
  ```bash
  swift test --filter CatalogTests
  make test-performance   # confirm no regression
  ```

- [ ] **F17 (SystemCatalog lock hoist)**: copy `allSettings` out of the lock before scoring; also hoist `replacement` construction out of the writer-side lock.
  ```bash
  make test-sanitizers
  swift test --filter SystemCatalogInvariantTests
  ```

- [ ] **F2 (skip redundant second immediatePage pass)** — implement with the generation-counter correctness fix, not just readiness+changed flags. Add `testSourceSearchSettledSnapshotCatalogCallCount` using `ScriptedCatalog`.
  ```bash
  swift test --filter SourceSearchEngineTests
  make test-performance
  ```

- [ ] **F3 (admission-heap materialization)**: implement materialize-on-heap-admission variant; keep `SearchItemRanking.topRankedInPlace` as the final ranker (do not add a bare `.sort()` in `ApplicationCatalog.swift` — verify with ast-grep).
  ```bash
  cd tools/ast-grep && sg scan --rule rules/search-path-no-full-sort.yml ../../Sources
  ```

- [ ] **F9 (reserveCapacity + optional unsafe-buffer rewrite)**: one-line `reserveCapacity(4)` first; add an ASCII-specific scoring budget test before deciding whether the unsafe-buffer rewrite is worth it.
  ```bash
  swift test --filter FuzzyMatcherDifferentialTests
  ```

- [ ] **F7 (PathNavigator literal-probe-first + casing recovery)**: implement literal `fileExists` probe with `.canonicalPathKey` casing recovery on hit. Re-run `PathNavigatorTests` specifically for the casing-preservation case.
  ```bash
  swift test --filter PathNavigatorTests
  ```
  Instruments File Activity: confirm `readdir`/`getdirentries64` disappears for the common case.

- [ ] **F6 (clipboard debounce + text-prefix truncation)**: add debounce to clipboard mode's `scheduleSearch` path; truncate text to 512 bytes before classification in `buildClipboardTextRow`. Verify history browsing (arrow-key navigation through full history) still works — do NOT ship a hard 80-row cap without scroll-triggered paging.
  ```bash
  swift test --filter SearchCoordinatorClipboardModeTests
  swift test --filter SearchResultProjectionClipboardTests
  ```

- [ ] **F5 (clipboard short-query + empty-query cap)**: apply `prefix(searchResultLimit)` cap to the <3-char branch, empty-query branch, and FTS-failure fallback.
  ```bash
  swift test --filter ClipboardHistoryStoreTests
  make test-performance
  ```

- [ ] **F10 (content-row score decrement)**: change `SearchItemRanking.content` assignment in `FFFIndex.swift:641` to `content - index`. Add a tied-score fixture to `SearchItemRankingPerformanceTests` before/after comparison.
  ```bash
  swift test --filter SearchModelInvariantTests
  ```

- [ ] **F18 (fix app-search benchmark fixture)**: rewrite with synthetic `discoveryProvider`, seeded `RecentStore`, populated `BlocklistStore`, temp `supportURL`. Split single-char query into its own bound.
  ```bash
  make test-performance
  ```
  Record new baselines; set bounds at ~3x observed release median.

- [ ] **F19 (add shell-projection budget tests)**: create `Tests/FloodlightTests/SearchProjectionPerformanceTests.swift` with the three budgets described. Hoist shared measurement helpers into `FloodlightTestSupport`.
  ```bash
  make test-performance
  ```

- [ ] **F20 (split clipboard benchmark)**: separate empty/short/FTS/on-disk variants, each with its own bound and result-count assertion.
  ```bash
  make test-performance
  ```

- [ ] **Final regression sweep** after all changes land:
  ```bash
  swift test
  make test-performance
  make test-sanitizers
  cd tools/ast-grep && sg scan --rule rules/ ../../Sources
  swiftlint --strict
  ```
  Then a full Instruments Time Profiler pass typing a representative query sequence (`a` → `ab` → `abc` → backspace ×3) in the live app, confirming `ApplicationCatalog.immediatePage`, `SystemCatalog.immediatePage`, and `PathNavigator.resolve` have dropped out of the top frames.

## Search speed: allocation and data layout

# Search speed: allocation and data layout — Mac verification checklist

## Measure first (baseline)

- [ ] **Run the existing perf suite cold, capture current numbers.**
  ```bash
  swift test -c release --filter SearchItemRankingPerformanceTests 2>&1 | grep FLOODLIGHT_BENCH
  swift test -c release --filter SearchPerformanceTests 2>&1 | grep FLOODLIGHT_BENCH
  ```
  Record every `FLOODLIGHT_BENCH ..._us=` line as the pre-change baseline. This is the number every change below must move (or must honestly fail to move — several findings below downgrade to "won't move a budget").

- [ ] **Confirm real catalog sizes** (several findings assumed 1,500 apps from a test constant; the real number changes expected impact). In the running app or a quick script: count `/Applications` + `/System/Applications` + `~/Applications` + CoreServices `.app` bundles, and count `SystemCatalog`'s built-in + discovered settings panes.
  What it confirms/refutes: F21, F22, F25, F30 — all had their "~1,500" premise corrected down to "a few hundred." Record the real number so effort/impact can be recalibrated once, for all four.

- [ ] **Instruments → Time Profiler, cold app launch → first keystroke → 6-character query, inverted call tree.** Look for `BlocklistStore.isBlocked`, `FuzzyMatcher.extractWordsASCII`, `String.split`, `NSString.trimmingCharacters`, `Calculator.evaluate`, `SearchItemRanking.ranksBefore` / `localizedStandardCompare`. Note relative % of each — this tells you which finding is actually worth doing first (several skeptic verdicts argue the ICU collation in ranking dwarfs everything in this list).
  Finding IDs: F21, F22, F25, F30, F33 (comparison baseline for all).

- [ ] **Instruments → Allocations, "Record reference counts," typing region (type 5 characters, hold pane open, backspace to empty).** Filter malloc sizes 16–128 B. Record total transient allocation count for one keystroke.
  Confirms/refutes: F22 (FuzzyMatcher word arrays), F32 (Set/array in buildLocalRows), F24 (visibleRows copy).

- [ ] **Seed a clipboard history with ~50 multi-KB text/code entries (paste large code snippets repeatedly), open clipboard mode, Instruments → Time Profiler, type 5 characters.** Look for `String.split`, `trimmingCharacters`, `JSONSerialization`, `FileManager.fileExists`.
  Confirms/refutes: F23 (parsing cost) and the stat-call regression called out in F23's corrections (`SearchResultProjection.swift:299` `FileManager.default.fileExists`) — check whether the file-exists stat, not the string parsing, dominates.

- [ ] **Toggle an explicit blocklist rule (block 5 apps) vs. none, run `immediatePage` benchmark both ways.**
  ```bash
  swift test -c release --filter ApplicationCatalog 2>&1 | grep FLOODLIGHT_BENCH
  ```
  Confirms/refutes F21: medians should differ by roughly one lock+hash pair × candidate count if the ordering bug is real; if a new benchmark doesn't exist yet, write it first (see "After implementing").

## After implementing

- [ ] **F21 — reorder characterMask gate above blocklist check** (`ApplicationCatalog.swift:182-188`, and the equivalent in `SystemCatalog`/`SearchCoordinator.swift:596` per the value-lens correction). Add `testApplicationImmediatePageBudget` with empty vs. 5-rule blocklist fixtures, print `FLOODLIGHT_BENCH application_immediate_page_us=… blocklist_rules=…`. Confirms F21 if medians converge; also check `SearchCoordinator.swift:596`'s per-publication blocklist filter, flagged by the value skeptic as a hotter, unmentioned site.

- [ ] **F22 — add `words.reserveCapacity(4)` at `FuzzyMatcher.swift:315` and drop the `initials` array** (index `words[i].bytes.first` directly). Do NOT do the stack-buffer/24-word-cap rewrite or the catalog-side word cache without also adding an ASCII-path budgeted test — none exists today (`SearchItemRankingPerformanceTests.swift:122` only benches the String path). Add one before/after this change.

- [ ] **F23 — cap `previewTitle` output length (~200 chars) instead of pre-truncating input to parsers.** Do NOT truncate the input string fed to `parseLocalPath`/`parseCodeHint` (breaks their suffix/newline guards — run `Tests/FloodlightTests/SearchResultProjectionClipboardTests.swift` to confirm nothing regresses). Separately, address the `FileManager.fileExists` synchronous stat at `SearchResultProjection.swift:297/299` — cache or drop it; this is flagged by both skeptics as larger than the string-parsing cost.

- [ ] **F24 — alias `visibleRows = allRows` when `selectedFilter == .all`** in both `projectLocal` (`SearchResultProjection.swift:162`) and `projectClipboard` (`:203`). Purely a cleanup; do not expect a measurable benchmark delta (both skeptics: low/unmeasurable). Skip unless bundling with other edits to the same function.

- [ ] **F25 — consolidate the `.app` bundle filter into one helper**, but keep TWO variants: `isInsideApplicationBundle` (byte scan for `.app/`, used at the 4 `dropLast()` sites) and a second form for `searchDirectories` (`FFFIndex.swift:271`, which omits `dropLast()` and must keep rejecting a directory that IS itself a `.app`). Add a parity test seeding `Foo.app/Contents/MacOS/Foo` and a bare `Bar.app` directory before consolidating — none exists today.

- [ ] **F27 — do NOT implement as proposed.** Value-lens skeptic refuted it (realized rows ~7 via `FloodlightMetrics.maximumVisibleResults`, keyword strings are small-string-optimized, no heap traffic). Confirm on Mac with Instruments → SwiftUI template before spending any effort: if `KeywordEngineRegistry.parseAddress` doesn't show up in the "View Body" heaviest stack at all, drop this line item entirely.

- [ ] **F28 — do NOT implement the enum refactor (`.copyClipboardEntry(id:)`).** Refuted by value lens (LazyVStack realizes ~10-15 rows, not 200-1000; `id` short-circuits `==` before the payload compare). If anything, narrow `ResultRow.==` to compare `id/title/subtitle/kind/fileSize/modifiedAt` instead of the full `SearchItem`. Verify via the existing `SearchViewRenderingTests.swift:435-441` equatable guard test.

- [ ] **F30 — hoist `id: "setting:\(setting.pane)"` onto `Setting` at init time** (`SystemCatalog.swift:405`), verify against `Tests/FloodlightEngineTests/CatalogTests.swift:488,500` which pin the id format. Do NOT do the byte-range word-boundary rewrite (accuracy skeptic: `setting.words` is still read as Strings at `SystemCatalog.swift:392` for acronym subtitles) or the lock-snapshot change (both skeptics: the refresh's own critical section at `SystemCatalog.swift:288-298` is longer than the query's, so there's no real contention to relieve).

- [ ] **F32 — reserve capacity only** (`output.reserveCapacity(context.candidates.count + 4)` at `SearchResultProjection.swift:439`). Do NOT remove the `Set<SearchItem.ID>` dedup — value skeptic found it is load-bearing: `SearchCoordinatorStressTests.swift:330` and `SearchCoordinatorIntegrationTestsResults.swift:131` both feed duplicate ids through this exact path and assert de-duplication.

- [ ] **F33 — do NOT implement the `[UInt8]` parser rewrite.** Value skeptic found `looksLikeExpression` (`Calculator.swift:31`) accepts Unicode `Nd` digits, so the "ASCII by construction" premise is false and the rewrite changes behavior for non-ASCII numeric input (`CalculatorStressTests.swift:273-281`, `AdversarialCorpus.swift:30` already exercise this). If anything, replace the two `"...".contains($0)` literal scans (`Calculator.swift:6`, `:30`) with a `switch`/`Set<UInt8>` gate — S effort, no semantic change — and leave the `[Character]` buffer alone.

## Rejected — no Mac time needed
F26, F29, F31 (both skeptics refuted; see report's "Rejected ideas"). F27 and F28 are listed above only as "confirm-then-drop" checks, not implementation items.

## Search speed: concurrency, scheduling, cancellation

## Measure first (baseline)

- [ ] **Existing perf suite baseline.** Run `swift test -c release --filter SearchPerformanceTests` and `swift test -c release --filter SearchItemRankingPerformanceTests` and `swift test -c release --filter ClipboardHistoryPerformanceTests`. Record every printed `FLOODLIGHT_BENCH` line to a file before touching any code — this is the regression baseline for every change below. (enables all)

- [ ] **Cold-start / first-launch scan timing (F45).**
  ```bash
  rm -rf ~/Library/Application\ Support/Floodlight/FileIndex
  swift build -c release
  ```
  Launch, immediately summon (hotkey) and type an 8-char query at natural cadence. Record with Instruments (Time Profiler + Points of Interest attached to the release binary). What to record: whether `SourceSearch` signpost intervals span the entire home-directory scan duration, and how many suspended `execute` tasks are parked (count via `sample Floodlight 10` mid-scan). Confirms/refutes: whether F45's "one parked task per keystroke, unbounded wait" is real at the scale claimed.

- [ ] **Clipboard capture main-thread hitch (F42).** Copy a ~10MB screenshot with the panel closed, then again with the panel open while typing. Record Time Profiler both times. What to record: whether `sqlite3_step`/image-decode frames appear on the main thread under `ClipboardCaptureService.poll`, and whether typing visibly stutters only in the panel-open case. Confirms/refutes F42's magnitude claim (decode+hash+insert on main, ~0-30MB worst case).

- [ ] **Space-bar preview cost (F41).** Copy a large image, select it in clipboard mode, hold space while recording Time Profiler. What to record: `sqlite3_column_blob` frames under `handleKeyEvent`, and whether they appear once (intentional preview) or twice (the double-lookup bug). Confirms F41's before-state.

- [ ] **PathNavigator enumeration cost (F37).** Point search root at a Downloads folder with thousands of files (or seed one), type a relative path-shaped query character by character, record Time Profiler. What to record: `contentsOfDirectory`/`__getdirentries64` frames under `buildLocalRows` on the main thread, and rough per-keystroke ms. Confirms F37's "warm APFS, real cost" claim (as opposed to only the rare network-mount case).

- [ ] **Clipboard empty-query projection cost (F40).** Seed clipboard history to ~1,000+ entries (mix of text/files/images), open clipboard mode, then clear the query repeatedly. Record Time Profiler. What to record: whether `projectClipboard`/`buildClipboardTextRow` (with its `fileExists` stat) show up on the main thread proportional to entry count, not to the visible ~12 rows. Confirms F40's corrected diagnosis (uncapped empty-query projection, not thumbnail blobs).

- [ ] **Launch-time assistant CLI probe (F38/F39).** With `claude`/`codex` installed outside `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin` (e.g. via nvm/asdf), time from launch to when an "Ask Claude" keyword row becomes available. `hyperfine --warmup 2 --runs 5 'zsh -l -c "echo -n $PATH"'` gives the per-spawn cost on that machine for context. Confirms whether the no-PATH-cache defect is measurable on the maintainer's actual setup.

- [ ] **Warm-up list-flash (F44).** Launch, immediately summon and type, screen-record at 60fps (Cmd-Shift-5), step through frames during the first 1-2 seconds. What to record: whether the result list visibly blinks to empty/synthetic-only and back. Confirms F44's warm-up case (the changeScope/rebuild case is separately confirmed by code reading — trigger via Cmd-L scope change with a large tree indexing).

## After implementing

- [ ] **F34** — Add `Tests/FloodlightEngineTests/FFFIndexCancellationTests.swift`: fire 10 `searchContent` calls back to back without awaiting, then time an 11th `search` call; print `FLOODLIGHT_BENCH content_search_queue_head_of_line_ms=`. Given the corrected low-impact assessment, treat "no measurable change" as an acceptable/expected outcome, not a failure.

- [ ] **F37** — Extend `Tests/FloodlightEngineTests/PathNavigatorTests.swift` with `testPathNavigatorResolveBudget` (5,000-entry temp dir, 11 samples, median under a couple ms). Re-run the baseline PathNavigator Instruments trace from above; confirm enumeration frames are gone for the exact-case-match case.

- [ ] **F40** — Add an image-bearing corpus to `ClipboardHistoryPerformanceTests.swift` (today it's 100% text) and a new bench for the empty-query projection path at 1,000 entries; print `FLOODLIGHT_BENCH clipboard_empty_query_projection_us=`. Re-run the empty-query Instruments trace; confirm `fileExists`/full-projection frames scale with visible rows (~12), not with entry count.

- [ ] **F41** — Add a test-only `imageDataCallCount` on `ClipboardHistoryStore`; assert it stays at zero for a space keypress with a non-empty query, and equals 1 (not 2) for the intentional toggle path.

- [ ] **F42** — Add a case to `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` injecting a 10MB TIFF and asserting `poll()` returns within a low-ms budget on the main actor. Re-run the capture Instruments trace; confirm decode/hash/insert frames have moved off the main thread lane.

- [ ] **F44** — Add `testWarmUpRestartDoesNotEmptyPublishedRows` to `Tests/FloodlightTests/SearchCoordinatorIntegrationTests.swift`. Re-run the screen recording from baseline; confirm no visible flash during warm-up (changeScope/rebuild flash is expected to remain, by design — verify it does NOT also disappear, which would indicate the fix was applied too broadly).

- [ ] **F45** — Add `testQueriesDoNotBlockOnSlowStartup` to `Tests/FloodlightEngineTests/SourceSearchEngineTests.swift` with a `ScriptedFileSource(startDelay: .seconds(5))`. Re-run the cold-start Instruments trace; confirm `SourceSearch` intervals no longer span the full scan and `.file`/`.folder` settle progressively.

- [ ] **F38/F39** — Add a cache-hit test asserting `resolveExecutable` is called once per process lifetime for a given command across both the startup probe and an interactive run. Re-run the launch-time timing measurement from baseline; confirm assistant keyword availability latency drops to ~1x zsh-login instead of ~2x.

- [ ] **F49** — After adding the `Debounce`/`ContentDelay`/`Projection` signposts, re-run the Points of Interest trace from any of the above and confirm proper nesting inside the existing `SourceSearch` interval — this is the enabling step for measuring F36/F47 if the maintainer wants to revisit them later.


# Cold start

## Cold start

## Measure first (baseline)

- [ ] **Cold-launch overall.** `make bundle`, copy `.build/Floodlight.app` to `/Applications`. Run `xcrun xctrace record --template 'App Launch' --launch /Applications/Floodlight.app --output launch_baseline.trace`. Read the Time Profiler main-thread track from process start to `applicationDidFinishLaunching` return, and note whether QuickLook/ServiceManagement frameworks appear in the dyld phase. [F50, F59, F64, F65, F67]
- [ ] **Login-item boot specifically.** Enable Launch at Login (System Settings > General > Login Items), reboot, and capture with `xcrun xctrace record --template 'App Launch' --attach Floodlight` (attach fast — login items start immediately). Confirm the panel shows and steals focus (`NSApp.activate(ignoringOtherApps: true)`), and check whether `PanelInit`/`ShowPanel` signposts fire. [F50]
- [ ] **Existing budgeted tests still pass and give a baseline.** `swift test -c release --filter 'PerformanceTests'` (per `scripts/test-performance.sh`). Record all current `FLOODLIGHT_BENCH` lines as the pre-change baseline. [F61 baseline]
- [ ] **Clipboard store construction cost.** Populate `~/Library/Application Support/Floodlight/clipboard.sqlite3` with ~1,000 entries (mix of text and ~200-300 image entries with real captured thumbnails), then time `ClipboardHistoryStore(databaseURL:)` cold. Use `xcrun xctrace record --template Allocations --launch Floodlight.app` and read the heap-allocation delta during that call. [F52]
- [ ] **Assistant CLI resolution cost.** `hyperfine --warmup 2 '/bin/zsh -l -c "echo -n \$PATH"'` on the target Mac to get the real per-shell cost (expect tens of ms, not seconds, since `-l -c` does not source `.zshrc`). Then check whether `codex`/`claude` CLIs are installed and where — if in `/opt/homebrew/bin` or another `commonDirectories` entry, this finding's shell-spawn path never triggers at all. [F53, F58]
- [ ] **Application catalog walk cost.** `du -sh /Applications ~/Applications` and count `.app` bundles: `fd -e app -d 1 /Applications ~/Applications /System/Applications | wc -l`. Add `Tests/FloodlightEngineTests/ApplicationCatalogStartupPerformanceTests.swift` timing `FileManager.default.displayName(atPath:)` over the real bundle list (warm and after `sudo purge`), print `FLOODLIGHT_BENCH app_display_name_us_per_app=`. [F54]
- [ ] **Marker directory re-sync cost.** `sudo fs_usage -w -f filesys Floodlight | grep ApplicationIndex/Items | wc -l` during one launch, to count the redundant `stat` calls in `synchronizeMarkers`. [F55]
- [ ] **System settings discovery cost.** Signpost `discoverInstalledSettings()` (SystemCatalog.swift:455) and read via `xcrun xctrace record --template 'Points of Interest' --launch Floodlight.app`. Since this runs concurrently with file/app warm-up (`async let` in `ensureStarted()`), confirm whether it actually extends wall-clock time or is fully hidden. [F56]
- [ ] **Login-shell/launch-at-login XPC cost.** `log stream --predicate 'process == "Floodlight" OR process == "smd"' --style compact` during a fresh (never-configured) launch to see `SMAppService` round-trip timing. Separately, build an ad-hoc unsigned copy or run from `~/Downloads` to trigger the permanent-retry failure path and confirm it repeats every launch. [F59]
- [ ] **FFF index scan cost (production config).** Run the existing gated benchmark: `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`. Separately, watch `sudo fs_usage -w -f filesys Floodlight | wc -l` during a real cold launch with the default `~/Downloads` scope, `enableHomeDirectoryScanning: true`, `enableContentIndexing: true`, `includeBinaryFiles: true` to see actual I/O volume. First answer the persistence question: launch once, `du -sh ~/Library/Application\ Support/Floodlight/FileIndex`, quit, relaunch with `FLOODLIGHT_FFF_LOG=/tmp/fff.log FLOODLIGHT_FFF_LOG_LEVEL=debug`, and check whether the second launch rescans from scratch. [F62 — includes researchNeeded]
- [ ] **Clipboard prune priority inversion.** Populate a temp DB with 20,000 entries older than the 30-day cutoff. Launch, then immediately hotkey + Tab into clipboard mode while running `xcrun xctrace record --template 'System Trace' --launch Floodlight.app`; check the 'Thread State' track for main-thread blocking on `stateLock`. Also confirm `idx_clipboard_created_at` exists via `sqlite3 clipboard.sqlite3 '.schema clipboard_entries'` and check whether the DELETE is index-backed (should be near-zero cost on a same-day relaunch). [F60]
- [ ] **Menu bar icon decode cost.** Time Profiler on a cold launch, filtered to main thread, self-time on `NSImage(contentsOf:)` for the 418-byte SVG. Expect sub-millisecond; confirms whether this is worth touching at all. [F67]
- [ ] **Framework link cost.** `DYLD_PRINT_STATISTICS=1 Floodlight.app/Contents/MacOS/Floodlight 2>&1 | head -40` and `DYLD_PRINT_LIBRARIES=1 ... | grep -i quicklook` to see whether QuickLookUI/QuickLookThumbnailing/ServiceManagement are mapped at launch and their load cost (expect near-zero, dyld shared cache). [F65]

## After implementing

- [ ] **F50** — reboot with Launch at Login enabled; confirm the panel no longer appears/steals focus, and confirm `panelController` is still `lazy` and untouched until first hotkey press. Update `Tests/FloodlightTests/ApplicationPresentationCoordinatorTests.swift` to assert `launch(initialSetupRequired: false, presentsPanel: false)` emits `[.startSearch]` only, and that omitting `presentsPanel` (default `true`) preserves today's behavior.
- [ ] **F52** — re-run the clipboard store construction benchmark; confirm reduced allocation delta if `recentLimit` was lowered, or confirm icons still render (not falling back to the generic `photo` symbol) if a lazy-thumbnail path was attempted.
- [ ] **F53** — add `Tests/FloodlightEngineTests/AssistantResolutionPerformanceTests.swift` with a scripted runner counting shell spawns; assert at most one `/bin/zsh -l` spawn per process after memoization, covering both `isAvailable` and `run(command:)`.
- [ ] **F54/F55** — add a startup performance test measuring `ApplicationCatalog.start()` median across warm and post-`sudo purge` cold runs; confirm `synchronizeMarkers` no longer redoes per-app `fileExists` when nothing changed (fix from review: reuse the `existing` listing instead of a persisted signature).
- [ ] **F58** — add a test with `ScriptedFileSource` (2 s delay) and a fast `ScriptedAssistantRunner`; assert `keywordRegistry` (assistant rows) is applied before file/app warm-up completes.
- [ ] **F59** — with the deferred/bounded-retry version applied, confirm `makeConfiguration`'s toggle still reflects real `SMAppService.status` on the onboarding path (no stale "off" flash).
- [ ] **F61** — add the `AppLaunch` interval + `HotkeyRegistered` event; verify with `log show --predicate 'subsystem == "com.floodlight.app"'` that both fire on a real launch, in order.
- [ ] **F62** — after any FFF config change, re-run `testExpandedFFFIndexScanBenchmark` and confirm file-result correctness is unaffected (this is research-gated; do not ship without confirming index persistence semantics from FFFKit).
- [ ] **F60** — confirm a second `start()` within 24h (or whatever gate lands) performs zero DELETE statements via a stub-UserDefaults unit test; re-run the priority-inversion repro from the baseline list and confirm the stall is gone or bounded.


# Responsiveness

## Responsiveness: UI and main thread

## Measure first (baseline)

- [ ] **Baseline engine perf suite.** Run `make test-performance` on a clean checkout and save the `FLOODLIGHT_BENCH` lines to a file (`floodlight_bench_baseline.txt`). This is the existing budgeted-test harness (`Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift` and siblings) — confirms nothing regresses as fixes land. Relevant to all IDs below.

- [ ] **Cold clipboard-mode entry, Time Profiler.** Build release (`swift build -c release`), then:
  ```
  xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/Floodlight
  ```
  Press hotkey, type `clip` or Tab into clipboard mode with a history of 500+ entries seeded (mix of text/files/images, some pinned). Record the call tree for the first render. Look for: `sqlite3_prepare_v2` / `sqlite3_step`, `NSWorkspace urlForApplication`, `NSBitmapImageRep`, `DateFormatter init`, `FileManager fileExists`. **F68, F69, F71, F76.**

- [ ] **Arrow-key stress on image-heavy history.** With 50+ image entries (some >5 MB PNGs) in clipboard history, hold arrow-down for 3 seconds while Time Profiler is recording. Record: longest single frame duration, whether `sqlite3` blob reads or `NSImage(data:)` decodes appear on the main thread per arrow press. Confirms/refutes **F68** (inspector SQLite+blob+LaunchServices) and **F75** (thumbnail re-decode). Also note whether the *previous* image visibly persists for a frame or two when moving to a new entry — confirms/refutes **F84**.

- [ ] **Keystroke stress in clipboard mode with path-shaped entries.** Seed 300+ clipboard text entries whose content is a real file path (e.g. `/Users/x/Documents/foo.txt`) mixed with plain text and JSON blobs. Type one character in the search field while in clipboard mode, recording with:
  ```
  sudo fs_usage -w -f filesys Floodlight
  ```
  Count `stat64`/`lstat64` lines attributable to that single keystroke. Confirms/refutes **F69** magnitude (expect near-zero for 3+ character queries since FTS caps at 200; expect up to ~300 stats for 0–2 character queries).

- [ ] **Screenshot-to-hotkey race.** Take a full-screen screenshot (⇧⌘3, produces a large PNG on the pasteboard), then within 300–500 ms press the summon hotkey. Record with Time Profiler running continuously across the screenshot. Look for `NSBitmapImageRep(data:)` / `representation(using:.png)` / `CC_SHA256` frames on the main thread overlapping with panel-show latency. Confirms/refutes **F72**.

- [ ] **App-icon cache miss cost.** Build a clipboard history spanning 20+ distinct source apps (copy text/files from many different apps). Enter clipboard mode and arrow through it while Time Profiler runs; look for `_LSCopyApplicationURLsForBundleIdentifier` / `NSWorkspace icon(forFile:)` on the main thread. Confirms/refutes **F71** (expect: hits only on first-seen bundle ID per session, and repeats on any bundle ID Launch Services cannot resolve — check for repeat misses on one item held selected).

- [ ] **First-keystroke panel-resize collision (plausible, needs your read).** With an empty query, type one character while recording with:
  ```
  xcrun xctrace record --template 'Animation Hitches' --launch -- .build/release/Floodlight
  ```
  Read the hitch ratio and longest frame during the 60→521 pt resize (note: not 548 pt as originally estimated — see **F77** caveats). This finding was a split vote; use this measurement to decide whether it's worth the medium-risk restructure at all.

## After implementing

- [ ] **F68 — Clipboard inspector memoization.** After adding the memoized/stored inspector snapshot (see report for the corrected S/M approach — memoize in the getter rather than a full stored-property migration), add `Tests/FloodlightTests/ClipboardInspectorPerformanceTests.swift`: seed 1,000 entries (50 images, ~4 MB PNG each), warm up 5x, take 11 samples of 100 iterations of `_ = coordinator.clipboardInspector`. Print `FLOODLIGHT_BENCH clipboard_inspector_us=…`, assert `< 200` (cache hit) and separately time first-eval (cache miss) to confirm it dropped from multi-ms to microseconds. Run `make test-performance`. Re-run the arrow-key Time Profiler stress test above and confirm SQLite blob reads and Launch Services calls disappear from repeated selections of the same entry.

- [ ] **F69 — Clipboard row cap.** After capping `projectClipboard` output (cap post-filter, e.g. to 80, not truncating the store) add `Tests/FloodlightTests/ClipboardProjectionPerformanceTests.swift` with 1,000 entries (300 path-shaped, 100 JSON-ish). Warm up 5x, 11 samples of 20 iterations of `SearchResultProjection.project(.clipboard(context))`. Print `FLOODLIGHT_BENCH clipboard_projection_us=… entries=1000`, assert `< 3_000` µs (adjust threshold once baseline is known — the corrected magnitude is lower than originally estimated for 3+ char queries). Re-run the `fs_usage` stat-count test above and confirm stat count drops to bounded (≤80 vs ≤1000).

- [ ] **F71 — AppIconCache negative-cache + async path.** After adding negative-result caching and an async `icon(for:)` mirroring `FileIconCache`, re-run the 20-app history test above; confirm the XPC call fires at most once per bundle ID per session (including unresolvable ones).

- [ ] **F72 — ClipboardImageCapture: lazy TIFF read + ImageIO thumbnailing.** After making the TIFF pasteboard read lazy (only when PNG absent/oversized) and switching to `CGImageSourceCreateThumbnailAtIndex`, re-run the screenshot-to-hotkey race test above. Add a capture-time performance test feeding a 4000×3000 PNG fixture through `ClipboardImageCapture.payload(from:)`; print `FLOODLIGHT_BENCH clipboard_image_capture_us=…`; compare before/after. Confirm the 27 synchronous `poll()` assertions in `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` still pass unmodified (they should, since this fix stays synchronous per the corrected, narrower scope — full async offload is a separate, larger follow-up).

- [ ] **F75 — Clipboard thumbnail cache.** After adding a `ClipboardThumbnailCache` keyed by `item.id` (or `entryID`) and switching the inspector to render `thumbnailPNGData` (or an async full-res load), scroll a 50+ image clipboard history in Time Profiler; confirm `NSImage(data:)` / `CGImageSourceCreateImageAtIndex` no longer appear on the main thread on re-scroll of already-seen rows.

- [ ] **F76 — DateFormatter hoist.** Only pursue if bundled with F68 (memoizing the inspector snapshot removes this cost for free). If done standalone: hoist to `nonisolated(unsafe) static let` (per `RecentStore.swift:10` precedent, required under Swift 6 strict concurrency), add `testDetailedDateFormattingBudget`, 11×500 iterations, print `FLOODLIGHT_BENCH detailed_date_us=…`, assert `< 5` µs post-fix.

- [ ] **F84 — FileMediaPreview stale-thumbnail fix.** After adding `thumbnail = nil` on cache-miss and the `Task.isCancelled` guard, repeat the arrow-key stress test on an image/video-heavy clipboard history, screen-recording at 60 fps (⇧⌘5). Step through frames and confirm no frame shows a thumbnail that doesn't match the filename/metadata below it.

- [ ] **F77 (plausible — decide after baseline).** If the baseline "Animation Hitches" measurement above shows a real hitch during the first keystroke, prototype the "warm the expanded hierarchy off-screen in `FloodlightPanelController.init`" variant (safer than the mount-at-idle variant per skeptic corrections) and re-measure. If the baseline shows no measurable hitch, drop this item.

## Responsiveness: clipboard runtime

## Clipboard runtime — Mac verification checklist

### Measure first (baseline)

- [ ] **Full performance suite baseline.** `swift test -c release --filter ClipboardHistoryPerformanceTests` and `swift test -c release --filter ClipboardHistoryStoreTests`. Record every `FLOODLIGHT_BENCH clipboard_*` line printed. This is the before-number for F85, F86, F87, F93. (F85, F86, F87, F93)

- [ ] **Cold start with a seeded DB.** Seed `~/Library/Application Support/Floodlight/clipboard.sqlite3` with 1000 entries, 300 of them images with 128x128 PNG thumbnails (~10-20 KB each). Run `hyperfine --warmup 3 'open -Wn ./.build/release/Floodlight.app'`. Record median wall time. This confirms/refutes whether the synchronous 1000-row load with thumbnails is visible at the app-launch level. (F85)

- [ ] **Schema-init cost in isolation.** Wrap `ClipboardHistorySQLite.initializeSchema` in an `os_signpost` interval; capture with Instruments' os_signpost template on a warm launch (existing DB, no migration needed). Record the interval — expect low single-digit milliseconds; if it's larger, F94 is more important than assessed. (F94)

- [ ] **Confirm WAL is actually active.**
  ```
  sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 'PRAGMA journal_mode;'
  ```
  Expect `wal`; check `-wal`/`-shm` sidecar files exist. A silent fallback to rollback-journal would make every capture markedly more expensive — record which mode is active. (F94)

- [ ] **EXPLAIN QUERY PLAN on the FTS search — resolves the F87 split verdict.**
  ```
  sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 \
    "EXPLAIN QUERY PLAN SELECT id FROM clipboard_entries WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH '\"the\"') ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC LIMIT 200;"
  ```
  Record whether `USE TEMP B-TREE FOR ORDER BY` appears. This single check tells you whether F87 is worth pursuing at all before writing any code for it. (F87)

- [ ] **DB blob footprint today.**
  ```
  sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 \
    "SELECT SUM(LENGTH(png_data)), SUM(LENGTH(tiff_data)), SUM(LENGTH(thumbnail_png)), COUNT(*) FROM clipboard_entries;"
  ```
  Record all four numbers as the baseline for F96 (PNG+TIFF duplication) and F85 (thumbnail growth). (F85, F96)

- [ ] **Reproduce F91 manually — the correctness bug most worth confirming first.** Copy a Numbers cell range, a formatted Pages paragraph, and a Cmd-Shift-Ctrl-4 screenshot. Open Clipboard mode. Record: does the Numbers/Pages copy show up as "TIFF Image" with the text gone? This alone justifies the fix regardless of any benchmark. (F91)

- [ ] **Reproduce F89 manually.** In Settings, pick "Forever" for clipboard retention. Run `defaults read <bundle-id> clipboard-history-retention-days` — expect `-1`. Relaunch and check whether entries older than 30 days survived. (F89)

- [ ] **Reproduce F90's temp-file leak.** Enter Clipboard mode with an image entry selected, type a sentence containing spaces (not Space-to-preview), then `ls -la $TMPDIR/FloodlightClipboardPreviews`. Then delete that entry and clear history; confirm the file is still present. (F90)

- [ ] **Reproduce F95's paste flow.** In Clipboard mode with an item copied from App B while frontmost app is App A, select an entry from App B and press Return. Record: (1) does the footer say "Paste to App A" or "Paste to App B"? (2) does the text appear in App A's document, or only land in the pasteboard? (F95)

### After implementing

- [ ] **F91 fix regression test.** Add to `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`: `pasteboardTypes = [.string, .tiff]` with both payloads present -> assert `kind == .text` with the expected string; keep a `[.png, .tiff]`-no-string case asserting `kind == .image`. `swift test --filter ClipboardCaptureServiceTests`. Confirms the fix without regressing screenshot capture.

- [ ] **F89 fix regression test.** In `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`, set `service.retention = .forever`, read back, assert `.forever`; separately write `-1` to the raw defaults key and assert the same. `swift test --filter ClipboardCaptureServiceTests`.

- [ ] **F85/F94 cold-start delta.** Re-run the `hyperfine` launch benchmark against the same seeded DB from baseline. Record the new median; compute percent improvement. Add `Tests/FloodlightEngineTests/ClipboardStoreStartupPerformanceTests.swift` (11 samples, `getrusage`, `FLOODLIGHT_BENCH clipboard_store_open_us`) so this has a permanent budgeted test per the README rule.

- [ ] **F93/F86 search benchmark delta.** Re-run `swift test -c release --filter ClipboardHistoryPerformanceTests`, diff `FLOODLIGHT_BENCH clipboard_search_us` against baseline per-query (print one line per query — `""`, `"a"`, `"in"`, and a 3+ char FTS query — not one aggregate).

- [ ] **F96 storage delta.** Re-copy the same 4K screenshot 20 times interleaved with small text copies (to defeat consecutive dedup). Re-run the blob-footprint query above; compare PNG/TIFF sums to baseline.

- [ ] **F90 leak fix verification.** Delete a clipboard entry with a preview file on disk; confirm the file under `$TMPDIR/FloodlightClipboardPreviews` is gone. Quit and relaunch the app; confirm the whole directory is gone (per-launch UUID subdirectory approach).

- [ ] **F95 real-paste verification (if implemented).** With Accessibility permission granted, select a clipboard entry, press Return, and time (via screen recording) Return -> text appearing in the destination app. With Accessibility permission denied, confirm graceful fallback to copy-and-dismiss with no crash or hang.

- [ ] **Instruments Allocations pass.** With the F93/F85 fixes in place, filter Instruments' Allocations template on `ClipboardEntry`/`_ContiguousArrayStorage`/`NSBitmapImageRep` while holding a key down in Clipboard mode with an image-heavy history loaded. Confirm transient allocation counts dropped versus a baseline capture taken before any fixes.


# Richer text

## Richer text

### Measure first (baseline)

- [ ] `make test-performance` on a clean checkout — record every existing `FLOODLIGHT_BENCH` line as the baseline before any change lands. [applies to F100/F101, F111]
- [ ] Print `NSPasteboard.general.types` after copying from Notes, Pages, Slack, Safari, and Xcode (a scratch `swift repl` or a temp Swift file). Record which of the five carry `public.rtf`/`public.html`, and whether any lack `public.utf8-plain-text` entirely. This settles whether "rich-only pasteboards are dropped" is real. [F99]
- [ ] `git log -S "ClipboardRetention" --oneline` plus reading `Sources/FloodlightEngine/Utilities/ClipboardEntry.swift:91-103` and `Sources/Floodlight/Search/ClipboardCaptureService.swift:154-170` — confirm (as already verified this session) that `retention`'s getter returns `.days(30)` for any negative or zero stored value, so `.forever` (stored as `-1`) never round-trips. [F115]
- [ ] In Instruments (Allocations template), enter clipboard mode with a history containing a few 32 KB text entries (`pbcopy < largefile.txt` a few times), then type 2-3 characters. Note allocation volume attributed to `SearchResultProjection.buildClipboardTextRow` / `previewTitle` / `ClipboardInspector.parse*`. [F100, F101]
- [ ] Instruments Animation Hitches template: select a 32 KB clipboard text entry in the inspector and arrow through 20 entries. Note hitch count and longest main-thread commit. [F102]
- [ ] `make run`, copy a URL, a hex color, and a JSON blob into clipboard mode, open the inspector, and screenshot the "Format"/"Type" rows plus the footer bar text ("Paste to X", "Actions ⌘K") for a before/after comparison. [F106, F109, F111]
- [ ] Copy an image from Preview's Edit > Copy (TIFF-only, no PNG) and read the inspector's Format row — confirm it says "PNG Image" (the bug) rather than "TIFF Image". [F104]
- [ ] Copy a file with a `.svg` extension into clipboard history, open the inspector (expect an image badge) then check whether `FileThumbnailCache` actually renders a thumbnail (expect it does not). [F112]
- [ ] Type `1234000 + 0` in the calculator, press ⌘C, paste into Numbers or a plain-text editor — confirm the pasted value is the grouped string `1,234,000` rather than a plain number. [F113]
- [ ] Copy a screenshot into clipboard history, select the row, press ⌘C, and inspect the pasteboard (`pbpaste` or Console) — confirm it contains the literal string "PNG Image"/"Screenshot" rather than image data. [F110]
- [ ] In Settings, set clipboard retention to "Forever", quit and relaunch Floodlight (or just re-read `UserDefaults.standard.integer(forKey: "clipboard-history-retention-days")` — expect `-1`), then confirm entries older than 30 days are still pruned (or trust the code read above). [F115]

### After implementing

- [ ] Re-run `make test-performance`; confirm the new `FLOODLIGHT_BENCH` lines added per finding meet their asserted thresholds and no existing line regressed. [F100/F101, F102, F111]
- [ ] `swift test --filter ClipboardInspectorTests` after the imageFormatName fix — new case for a TIFF-only entry asserting `detail.format == "TIFF Image"`. [F104]
- [ ] `swift test --filter SearchResultProjectionClipboardTests` after the subtitle/truncation changes — update the literal-string assertions (`"Notes · 18m"`, `"2880×1800 · 2m"`, etc.) to the new grammar. [F105, F108]
- [ ] Repeat the Instruments Animation Hitches pass on the 32 KB entry after adding `previewBody`/truncation — confirm the hitch is gone. [F102]
- [ ] `make run`: press ⌘K in clipboard mode and confirm it either does something real or the button/label has been replaced with an existing bound shortcut (⌘. / ⌘D / ⌘Y). [F106]
- [ ] `swift test --filter Calculator` after fixing the copy payload — confirm `CalculatorAdversarialTests` (grouped-string assertions) still pass since only the copy target changes, not `Calculator.format`. [F113]
- [ ] Set retention to "Forever" again after the fix, force a prune, and confirm entries older than 30 days survive (or add a `ClipboardCaptureServiceTests` case asserting `retention == .forever` round-trips through `UserDefaults`). [F115]
- [ ] If rich-text capture (F99) is attempted: build the `ScriptedPasteboardObserver` extension with a `dataByType` dictionary (Tests/FloodlightTests/ClipboardCaptureServiceTests.swift), assert an RTF-only pasteboard still produces an entry with derived plain text, and add the `clipboard_db_bytes` budget test guarding total on-disk growth.
- [ ] If match highlighting (F107) is attempted: extend `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift` with a with-ranges variant, assert it stays within 1.3x the score-only median, and confirm ranges are only ever emitted for `.application`/`.systemSetting` rows (not files, which have no `MatchEvidence`).


# Clipboard history

## Clipboard history management

## Clipboard history management — Mac experiment checklist

### Measure first (baseline)

- [ ] Run `make test-performance` and record the current `ClipboardHistoryPerformanceTests` median (the existing test averages short and FTS queries together — note this dilutes the short-query signal). *(F126, F116)*
- [ ] Add a short-query-only case to `ClipboardHistoryPerformanceTests` (`queries = ["a", "in"]` over a window seeded with realistic multi-KB entries, not the ~70-char fixtures currently used) and record `FLOODLIGHT_BENCH clipboard_search_short_us=` before any change. *(F126)*
- [ ] Cross-check syscalls on a real history while typing in clip mode:
  ```
  sudo fs_usage -w -f filesys Floodlight | grep -c stat64
  ```
  Record the count for a single keystroke over a history containing several path-like clips. *(F116)*
- [ ] Confirm the default-on capture behavior on a fresh profile:
  ```
  FLOODLIGHT_FORCE_ONBOARDING=1 make run
  ```
  Copy something while the setup window is visible, then check clip mode — record whether it appears. This is the baseline consent gap. *(F120)*
- [ ] Confirm pins are destroyed by Clear all history today: seed a pinned entry, Settings → "Clear all history…", confirm the pin is gone with no prompt. *(F117)*
- [ ] Confirm deleted-content recoverability in the DB file:
  ```
  strings clipboard.sqlite3 clipboard.sqlite3-wal | grep -c FLOODLIGHT_SECRET_CANARY
  ```
  after recording a canary string and deleting its entry. Record disk size of `clipboard.sqlite3` before/after deleting a 10+ MB image entry with `ls -la`. *(F118)*
- [ ] Confirm the 32 KB drop is silent: copy a >32 KB text blob, open clip mode, confirm no row and no message appears. *(F122)*
- [ ] Confirm rich-text loss: copy a styled paragraph from Pages, restore it from clipboard history into TextEdit, confirm formatting is gone. *(F121)*
- [ ] Confirm Quick Look residue: `make run`, Space on an image entry, then:
  ```
  ls -la $TMPDIR/FloodlightClipboardPreviews
  ```
  Delete the entry from history, re-check the directory — file should still be there today. *(F119)*
- [ ] Confirm exclusion mismatch: add a bundle ID with wrong capitalization (e.g. `Com.Bitwarden.Desktop`), copy from that app, confirm it's still recorded (case-sensitive miss). *(F125)*

### After implementing

- [ ] Add `Tests/FloodlightTests/SearchResultProjectionClipboardPerformanceTests.swift` (1,000 mixed entries, 11×100 warm samples, `FLOODLIGHT_BENCH clipboard_projection_us=`, assert median < 3,000 µs). Re-run the `fs_usage` stat count from baseline — should drop to zero for the dropped `fileExists` call. *(F116)*
- [ ] Re-run the short-query-only performance case; compare against baseline median. *(F126)*
- [ ] Add `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift` cases for `clear(includingPinned: false/true)` against a reopened on-disk DB via `makeTemporaryDatabaseURL()`. *(F117)*
- [ ] Re-run the canary `strings` check after adding `secure_delete`/checkpoint — must be 0. Re-run the `ls -la` disk-size check after an image delete — file should shrink. *(F118)*
- [ ] Add a capture-service test asserting `isEnabled == false` during onboarding (fresh defaults + injected `shouldPresent() == true`), and `true` after onboarding completes. *(F120)*
- [ ] Add a 100 KB / 200 KB round-trip test in `ClipboardHistoryStoreTests` (records normally / records truncated with flag set). Re-run `make test-performance` with a handful of 100–128 KB entries seeded to catch preview-path regressions. *(F122)*
- [ ] Add a scripted-observer test asserting `.rtf` is captured and restored via a scratch `NSPasteboard(name:)`. Manually round-trip a styled paragraph through TextEdit. *(F121)*
- [ ] Manual: Space on an image, dismiss panel (Esc), confirm `$TMPDIR/FloodlightClipboardPreviews` is empty. *(F119)*
- [ ] Add exclusion-store test with mixed-case bundle IDs after the case-fold fix; manual check with the new running-apps picker. *(F125)*
- [ ] Extend `panelCommand` unit tests for the new delete/pin key mappings; manual VoiceOver pass over a pinned row confirming "<text>, pinned" announcement. *(F123)*
- [ ] `SearchMode.transition` tests for `"clipboard"`/`"history"` aliases; manual check that both global hotkeys register via `GlobalHotKeyRegistration`. *(F124)*

## Clipboard power-user convenience

# Clipboard power-user convenience — Mac test/measurement checklist

## Measure first (baseline)

- [ ] **Baseline test suite green.** `swift test` and `swift build -c release`. Confirms starting point compiles/passes before any of the changes below. (all)
- [ ] **Confirm ⌘K does nothing today.** Build release, `./.build/release/Floodlight`, enter Clipboard mode (`clip` + Tab), press ⌘K. Expect: no menu, no beep, no visible effect. Record: pass/fail. (F127)
- [ ] **Confirm the Actions chip performs ⌘C.** With a clipboard row selected and no text selected in the query field, click the "Actions ⌘K" chip; confirm the clipboard content is copied (paste elsewhere to verify) and the panel does not dismiss. (F127)
- [ ] **Reproduce the Exclude-from-Search mode corruption.** Right-click a clipboard text row → Exclude from Search. Record: does the panel show local/web rows while still in `.clipboard` mode? Then check Settings → excluded rules for a new entry derived from the clipboard row's title. (F128)
- [ ] **Reproduce web-mode variant of F128.** In local search, right-click a "Search Google for X" fallback row → Exclude. Confirm it also blocklists and republishes local rows (per the value-lens correction that `projectWeb` is equally affected).
- [ ] **Count keystrokes to reach the 3rd-most-recent clip.** Time/keystroke-count ↓↓Return today. Record baseline (expect 3 keystrokes / non-trivial latency). (F129)
- [ ] **Confirm ⌘5–⌘9 (and ⌘0) are swallowed in Clipboard mode.** Enter Clipboard mode, press ⌘5 through ⌘9 and ⌘0 one at a time; confirm no beep and no visible effect (dead keyspace, not a system beep). (F129)
- [ ] **Confirm ⌃N/⌃P do not move selection.** Type a query, press ⌃N and ⌃P; confirm caret moves within the field instead of the highlighted row changing. Also press ⌃1 with multiple Spaces configured in System Settings, to confirm the OS intercepts it (Mission Control) before this app ever sees it — this kills the F129 proposal's ⌃-digit idea and should redirect to ⌘⌥-digit. (F129, F130)
- [ ] **Confirm no second global hotkey is registrable today.** Read `GlobalHotKeyRegistration` — no code change — and note in Settings there is exactly one shortcut picker (Space-based). Time the `clip`+Tab path from another app: ⌘Space, c-l-i-p, Tab = 6 keystrokes. Record baseline. (F131)
- [ ] **Confirm filter does not persist across clipboard re-entry.** Enter Clipboard mode, press ⌘4 (Images), Escape, re-enter clipboard mode. Confirm it resets to All. (F132)
- [ ] **Drag-out test, pinned multi-line text.** Copy a 2-line snippet, pin it in Clipboard mode, drag the row into TextEdit. Record exact dropped text (expect pushpin emoji + newlines collapsed to spaces). (F133)
- [ ] **Drag-out test, image row.** Copy a screenshot, drag its clipboard row into Preview/Mail. Record what lands (expect the literal string "Screenshot", not image bytes). (F133)
- [ ] **⌘C on image row.** Select a screenshot's clipboard row, press ⌘C, then ⌘V into Preview or TextEdit. Record what pastes (expect the word "Screenshot" as text, not the image). Compare against Return on the same row (expect the actual image). (F136)
- [ ] **Return on a URL clipboard entry.** Copy `https://example.com`, select its row, press Return. Confirm it copies + dismisses rather than opening in a browser. Then press ⌘Return on the same row and confirm it no-ops (fileURL is nil for a plain URL text entry). (F135)
- [ ] **⌘. behavior in Clipboard mode.** Select a row, press ⌘. — confirm it pins the row rather than dismissing the panel (contrary to system-wide cancel convention). Also confirm ⌘D deletes with no confirmation dialog. Note neither appears in `docs/src/content/docs/guides/keyboard-shortcuts.mdx`. (F138)
- [ ] **Confirm no multi-select exists.** Try ⇧-click or ⌘-click on multiple clipboard rows; confirm only one row is ever selected (`SearchResultPublication.selection` is singular). (F139)
- [ ] **Confirm no keyword-addressed snippets.** Pin an entry, then from the *local* (non-clipboard) search field, try typing any word from the pinned entry's text plus Tab. Confirm nothing addresses it — only fuzzy substring matches appear, if any. (F140)
- [ ] **Confirm `from:`/`img:`/`file:` prefixes do nothing.** In Clipboard mode's search field, type `from:Safari` or `img:` and confirm it is treated as literal text against `entry.text`, not as a filter. (F141)
- [ ] **Run the existing performance test suite to get a baseline number to compare any new hot-path code against.** `swift test -c release --filter SearchItemRankingPerformanceTests` and record the printed `FLOODLIGHT_BENCH` lines — anything added under F140/F141 must not regress these.

## After implementing

- [ ] **F127 (Action menu / relabel).** Add/extend `Tests/FloodlightTests/FloodlightPanelTests.swift` keymap table: assert `panelCommand(for: "k", shiftHeld: false)` maps to the new command (or, if the minimal fix is chosen, assert the chip label now reads "Copy ⌘C" via a UI snapshot/manual check). `swift test --filter FloodlightPanel`. Manual: press ⌘K in Clipboard mode, confirm a menu opens (or confirm the label now matches the ⌘C behavior).
- [ ] **F128 (Exclude-from-Search guard).** Add to `Tests/FloodlightTests/SearchCoordinatorClipboardModeTests.swift`: enter clipboard mode, call `excludeFromSearch` on a clipboard row, assert `isClipboardMode` stays true, `results` unchanged, and `blocklistStore.rules` stays empty. Add the same for web mode (`case .local = mode` guard, not `!isClipboardMode`). `swift test --filter SearchCoordinatorClipboardMode`. Manual: right-click a clipboard row — Exclude should be absent or no-op.
- [ ] **F129 (quick-paste digit).** Table-test the pure keymap function (`quickPasteIndex` or equivalent) for the chosen modifier (⌘⌥-digit per corrected shortcut, not ⌃-digit). Coordinator test that `activateVisibleRow(at:)` performs select+action on the Nth row. `swift test --filter FloodlightPanel`. Manual: hold the chosen modifier, press 1–7 (capped at `FloodlightMetrics.maximumVisibleResults`), confirm the right row's action fires with no beep.
- [ ] **F130 (⌃N/⌃P selection movement).** Update `Tests/FloodlightTests/SearchFieldKeymapTests.swift`'s `unrelatedSelectorsFallThroughToTheFieldEditor` test to expect `.moveSelectionDown`/`.moveSelectionUp` for `moveDown(_:)`/`moveUp(_:)` instead of nil. `swift test --filter SearchFieldKeymap`. Manual: type a query, press ⌃N/⌃P, confirm the highlighted row moves.
- [ ] **F131 (second global hotkey).** Extend `Tests/FloodlightTests/GlobalHotKeyRegistrationTests.swift`: register two distinct shortcuts via the widened `firstIdentifier`-forwarding convenience init, assert each event only fires its own `onPressed`, and that no two registrations ever share a `GlobalHotKeyIdentifier.id`. `swift test --filter GlobalHotKeyRegistration`. Manual: set the new clipboard shortcut in Settings, trigger it from another app, verify Clipboard mode opens and ⌘Space still opens normal search; check Console.app for "Floodlight global hot-key failure" if the default (e.g. ⇧⌘V) is already claimed system-wide.
- [ ] **F132 (remember clipboard filter).** Add to `SearchCoordinatorClipboardModeTests`: select Images filter, leave clipboard mode (Escape), re-enter, assert `selectedFilter == .images` for the remainder of the process lifetime. If persisting to UserDefaults, add a case seeding a bogus rawValue and asserting fallback to `.all`. `swift test --filter SearchCoordinatorClipboardMode`.
- [ ] **F133 (drag payload fix).** Extract a pure `dragPayload(for:imageData:)`-style function and unit test in `Tests/FloodlightTests/SearchViewRenderingTests.swift`: pinned multi-line entry yields exact original text (with `\n`, no pushpin); local-path text row still drags as a file (regression guard per the accuracy-lens correction on ordering fileURL-first). Manual: drag a pinned 2-line snippet into TextEdit (expect both lines, no emoji); drag a captured screenshot into Preview (expect an actual image).
- [ ] **F135 (open URL on ⌘Return).** Add to `SearchCoordinatorClipboardModeTests` using `ScriptedActionEffects` extended with an `onOpen` hook: record an `https://…` entry, run the ⌘Return path, assert `onOpen` fired with that URL and `onWrite` did not. Add negative cases for `javascript:` and `file://` (must NOT open). `swift test --filter SearchCoordinatorClipboardMode`. Manual: select a URL clipboard row, ⌘Return, confirm it opens in the default browser; confirm plain Return still copies+pastes (do not break the primary paste gesture per the value-lens correction).
- [ ] **F136 (⌘C copies image bytes, or ships as one pasteboard item with both string and image).** Extend `Tests/FloodlightTests/SelectedResultActionPerformerTests.swift`: `copy(_:)` on a `.copyImage` row invokes the image-write path (or writes both string+image to one pasteboard item) and does not call `onDismiss`. `swift test --filter SelectedResultActionPerformer`. Manual: ⌘C a screenshot row, ⌘V into Preview — expect an image (or, if the multi-representation fix is chosen, expect Preview to get the image and TextEdit to get the display name).
- [ ] **F138 (rebind pin off ⌘.).** Update `Tests/FloodlightTests/FloodlightPanelTests.swift` and `FloodlightPanelStressTests.swift:50,57,66` for the new pin chord (e.g. ⌘P) and assert `"."` now falls through to `.unmatched` (so system cancel behavior resumes). Add every clipboard chord to `keyboard-shortcuts.mdx`. Manual: press ⌘. in Clipboard mode, confirm it dismisses the panel; confirm the new pin chord pins.
- [ ] **F139 (marking / paste-all, stage 1 only).** Table-test a pure mark-set value type: toggle idempotence, insertion-order preservation, join with separator, empty-set join. Coordinator test that Paste All writes entries in mark order via `ScriptedActionEffects.onWrite`. `swift test --filter ClipboardMark`. Manual: mark 3 clipboard entries, trigger Paste All, confirm the joined text lands in target app in mark order.
- [ ] **F140 (keyword snippets on pins).** Round-trip persistence test for a keyword across store close/reopen in `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift`; collision-rejection test against registry keywords; projection test that the exact first token (not substring) triggers the snippet row. Add a case to `SearchItemRankingPerformanceTests` with ~200 keyworded pins resident, assert added per-keystroke cost stays under budget, printing a new `FLOODLIGHT_BENCH` line. `swift test --filter ClipboardHistoryStore` then `-c release --filter SearchItemRankingPerformance`. Run `sg scan -c sgconfig.yml` to confirm `query-path-no-sync-disk-read` still passes (informational per accuracy-lens correction — the rule doesn't actually gate this file, but keep the in-memory-only invariant anyway).
- [ ] **F141 (from:/img:/file: prefix parsing).** Table-test `ClipboardQuery.parse` in `Tests/FloodlightEngineTests/`: bare text, each prefix, unknown prefix stays literal, `from:` with no value, a colon inside a URL not misread as a prefix (the adversarial case). Coordinator test that `img: shot` yields only image rows and auto-selects the Images chip without corrupting `clipboardFilterOptions` counts. If the `source_app_bundle_id` index + SQL-level `search(query:sourceApp:kind:)` overload is added (needed per the accuracy-lens correction — post-filtering after `LIMIT 200` is lossy), extend `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift` with a `from:`-filtered query and confirm `FLOODLIGHT_BENCH clipboard_search_us` stays under the existing bound. `swift test -c release --filter 'ClipboardQuery|ClipboardHistoryPerformance'`.


# Beyond the five

## Beyond the five: build, testing, hygiene, docs

## Measure first (baseline)

- [ ] **F142 — repo bloat baseline.** `git count-objects -vH | grep size-pack` and `du -sh .` on a fresh clone. Then `git ls-files "*.bc" | wc -l` (expect 48) and `git ls-files design` (expect `design/Floodlight.dmg`). Record pack size and working-tree size before touching `.gitignore`.
- [ ] **F143 — clipboard search budget baseline.** `swift test -c release --filter ClipboardHistoryPerformanceTests` and record the current `FLOODLIGHT_BENCH clipboard_search_us=` line (text-only, in-memory fixture). This is the number the new file-backed/image-heavy cases will be compared against.
- [ ] **F144 — index-scan benchmark baseline.** `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`, run 5×, record `expanded_fff_scan_ms` each time, take the max — this becomes the seed for the new `XCTAssertLessThan` bound (set at roughly 3× the max).
- [ ] **F145 — packaging baseline.** `make bundle dmg`, then `codesign --verify --deep --strict .build/Floodlight.app` and `hdiutil verify .build/Floodlight.dmg`. Record `stat -f%z .build/Floodlight.app/Contents/MacOS/Floodlight` as the initial size ceiling. Time it: `hyperfine --runs 3 'make bundle'`.
- [ ] **F146 — release provenance baseline.** Confirm `git merge-base --is-ancestor $(git rev-parse HEAD) origin/main; echo $?` works as expected on a green main commit and on a throwaway off-main commit (push a test tag to a fork, do not touch the real release).
- [ ] **F147 — hermeticity baseline (prove the leak).** `ls -l ~/Library/Application\ Support/Floodlight/clipboard.sqlite3*` and note mtimes. Run `swift test --filter OnboardingTests`. Re-check mtimes and the `-wal` file — confirm they changed. Also `defaults read com.floodlight.search` before/after to confirm real prefs are read.
- [ ] **F153 — ratchet ground truth.** Get SwiftLint's own numbers (not hand-counts): `.tools/bin/swiftlint lint --reporter json --config <(sed 's/warning: 665/warning: 1/' .swiftlint.yml) Sources | jq -r 'map(select(.rule_id=="file_length")) | .[] | "\(.file) \(.reason)"'` and repeat for `type_body_length`, `function_body_length`, `cyclomatic_complexity`. This resolves whether `ignore_comment_only_lines` also drops blank lines (decides 622 vs 701 for FFFIndex.swift).
- [ ] **F155 — Periphery arch check.** On Apple silicon: `ls -d .build/*/debug/index/store` to confirm the literal path in `.periphery.yml:13` matches. On an Intel Mac if available, confirm the path does NOT exist and observe whether `periphery scan` errors or silently reports zero findings — settles the `researchNeeded` question directly.
- [ ] **F157 — CI job duration baseline.** `gh run list --workflow CI --limit 10 --json databaseId` then `gh run view <id> --json jobs --jq '.jobs[] | {name, startedAt, completedAt}'` for each — get real per-job durations to size `timeout-minutes`.
- [ ] **F159 — engine/shell size split baseline (if pursued).** `nm -n .build/release/Floodlight | awk '{print $3}' | grep -c '16FloodlightEngine'` vs total, on the unstripped binary before `strip -u -r` runs in `scripts/bundle.sh`. Only pursue if F145's ceiling work is already in place.

## After implementing

- [ ] **F142.** `git rm --cached` the 48 `.bc` files and `design/Floodlight.dmg`, add `*.bc` and `*.dmg` to `.gitignore`. Confirm `git ls-files "*.bc" | wc -l` → 0. Run `make check && make test`. Re-measure `du -sh .` (expect ~11.6 MB smaller working tree). Compare "Check out Floodlight" step duration across two consecutive Actions runs.
- [ ] **F143.** Add file-backed and image-heavy (~4-8 KB thumbnail fixture, not the existing 32-byte `ClipboardImageTestData.thumbnail`) cases to `ClipboardHistoryPerformanceTests.swift`; print `clipboard_search_image_us` distinct from `clipboard_search_us`. Re-run `make test-performance` and compare — this is the number likely to blow past 2 ms.
- [ ] **F144.** After adding `XCTAssertLessThan(scanMilliseconds, <bound>)`, verify a deliberately slow injected delay makes the test fail (sanity check the assertion is live, not vacuous). Confirm the nightly `schedule:` workflow variant runs and posts to the step summary.
- [ ] **F145.** Add the `package` job to `ci.yml`. Confirm `binary_size_bytes` and `dmg_size_bytes` both land in `$GITHUB_STEP_SUMMARY`. Deliberately bump the size ceiling script's threshold down by 1 byte and confirm the job goes red, then restore.
- [ ] **F146.** Rehearse on a fork: tag a non-main-ancestor commit, confirm the new guard step fails before signing; tag a green main commit, confirm it passes end to end including `gh release create`.
- [ ] **F147.** After removing the defaulted stores, run `swift test` and confirm `~/Library/Application Support/Floodlight/clipboard.sqlite3` mtime is untouched. Add and run the new "Clear from Settings empties what the panel shows" test.
- [ ] **F148.** After writing `docs/adr/0008-clipboard-history.md`, `rg -c 'ConcealedType|is-sensitive' docs/adr/0008-clipboard-history.md` should be non-zero.
- [ ] **F150.** `head -1 Package.swift` and `rg -n '6\.4' README.md docs/src/content/docs/development/building.mdx` should agree. Temporarily bump the tools version and confirm the new `check-docs.sh` guard goes red.
- [ ] **F151.** `rg -n '^## ' docs/src/content/docs/guides/search.mdx | rg -i 'not currently'` confirms the real heading/anchor. After fixing, click the link from a rendered GitHub README preview.
- [ ] **F152.** After doc updates, run the app (`make bundle && open .build/Floodlight.app`), enter Clipboard mode, and confirm ⌘. and ⌘D behave as documented. Do NOT document a "Forever" retention option until F152's underlying getter bug (falls through to `.days(30)`) is separately fixed or confirmed intentional.
- [ ] **F153.** Set each of the four thresholds to the SwiftLint-reported observed maximum (from the baseline step above), update the comment block to name `FFFIndex.swift` (or the real worst offender) instead of the dead `SearchCoordinator.applyResults`, and confirm `make check-lint` is green with zero slack.
- [ ] **F154.** Pin all `uses:` lines in `pages.yml` to SHAs with `# vN` comments. `rg -n 'uses:' .github/workflows/` — every line should carry a 40-hex SHA afterward.
- [ ] **F156.** Rename a FLOODLIGHT_BENCH key in a test locally and confirm `./autoresearch.sh` now exits non-zero with a named missing-metric message instead of emitting a blank `METRIC` line.
- [ ] **F157.** After adding `timeout-minutes` and a `notarytool --timeout`, confirm via `gh run view` that jobs still complete within the new ceiling on a normal run.
- [ ] **F158.** Run `.tools/bin/periphery scan --project-root . --config .periphery-tests.yml --quiet | wc -l` once by hand to size the new report; cross-check a sample finding against `rg -n '<DeclName>' Tests/` before wiring it into the gate.
- [ ] **F160.** `make bundle && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/Floodlight.app/Contents/Info.plist` should print a `git describe`-derived value (not `0.1.0`). Confirm `git diff --exit-code Sources/Floodlight/Resources/Info.plist` (tracked file untouched) and `codesign --verify --deep --strict .build/Floodlight.app` still passes.

## Beyond the five: memory, energy, indexing

## Measure first (baseline)

- [ ] **Baseline release test suite.** `swift test -c release --filter Clipboard` and `swift test -c release --filter SearchItemRankingPerformanceTests` on the target Mac. Record every existing `FLOODLIGHT_BENCH` line as-is — this is your regression floor before any fix below. (Enables F161, F162, F163, F166, F169, F172.)

- [ ] **Baseline temp-disk state.** `du -sh "$TMPDIR/FloodlightClipboardPreviews"` after a normal week of use (or after manually previewing 20+ clipboard images with Space). Confirms F168's leak is real and sizes it before deleting anything. (F168)

- [ ] **Baseline clipboard DB size.** `du -sh "$HOME/Library/Application Support/Floodlight/FileIndex/clipboard.sqlite3"` and `sqlite3 clipboard.sqlite3 'SELECT SUM(LENGTH(png_data)), SUM(LENGTH(tiff_data)), COUNT(*) FROM clipboard_entries;'` after capturing 50 real screenshots. Confirms the dual-blob storage and its actual magnitude (may be less than 2x if TIFF is often dropped by the 15 MB cap). (F162)

- [ ] **Baseline main-thread stall while typing in clipboard mode.** Open a clipboard history of 500+ entries (mix of text, JSON blobs, local paths, images) in the release build, use Instruments' Time Profiler while typing a short query, and note whether `JSONSerialization`, `stat`/`fileExists`, `memcmp`/`Data.==`, or `Calendar`/ICU frames appear on the main thread. This single trace surfaces evidence for F161, F163, F166, F169, and F170 at once — run it before touching any of them. (F161, F163, F166, F169, F170)

- [ ] **Baseline space-keypress cost.** In clipboard mode with a non-empty query and an image entry selected, run `xcrun xctrace record --template 'File Activity' --launch -- .build/release/Floodlight`, type a space, and confirm a SQLite read (and possibly a temp-file write) occurs even though the query should block the preview. (F167, F168)

- [ ] **Baseline idle power draw.** `sudo powermetrics --samplers tasks --show-process-energy -n 3 -i 5000 | grep -i floodlight` while idle for 60s, both unlocked and immediately after locking the screen (⌃⌘Q). Confirms polling continues while locked; do not expect a large energy delta — the original F164 energy framing was mostly refuted. (F164)

- [ ] **Baseline image cache footprint.** Arrow through 100 clipboard file entries including at least one large (>4000px) photo that QuickLook fails to thumbnail, then `footprint -p $(pgrep -x Floodlight)`. Confirms whether the uncapped fallback at `FileThumbnailCache.swift:66` is reachable in practice. (F165)

- [ ] **Baseline FFF/LMDB memory footprint.** Point Floodlight at a ~200k-file source tree, let indexing settle, then `footprint -p $(pgrep -x Floodlight)` and `vmmap $(pgrep -x Floodlight) | grep -E 'mapped file|MALLOC_LARGE|VM_ALLOCATE' | head -40`. Cross-check against `.scratch/optimization/findings-index.md` U11/U18 before treating this as new work. (F171)

## After implementing

- [ ] **F168 — preview cleanup.** After adding delete-on-`deleteSelection()`/`clearHistory()` and a session-start sweep: `du -sh "$TMPDIR/FloodlightClipboardPreviews"` should be 0 right after deleting a previewed entry, and stay bounded across a session. Add and run `SearchCoordinatorClipboardModeTests.testPreviewFilesAreRemovedOnDelete`.

- [ ] **F167 — predicate/materializer split.** Run `FloodlightPanelTests.testSpaceDoesNotEvaluatePreviewWhenQueryNonEmpty` (counting autoclosure or predicate call count) — assert 0 SQLite reads when query is non-empty. Re-run the File Activity trace from the baseline step and confirm no read occurs before Space is pressed on an empty query.

- [ ] **F161 — capped, reordered clipboard projection.** Run `swift test -c release --filter ClipboardProjectionPerformanceTests` (new test), check `FLOODLIGHT_BENCH clipboard_projection_us=` — expect a large drop for the empty-query/panel-open case. Re-run the Time Profiler trace; `stat`/`fileExists` frames should be gone from the main thread. Manually verify filter chip counts still match visible rows after the cap (order-of-operations regression check).

- [ ] **F166 — parser trimming fix.** Extend the same projection benchmark with 100 JSON-shaped 30 KB entries; compare medians before/after — expect an order of magnitude improvement for that corpus shape.

- [ ] **F163 — inspector preview cache.** Repeat the Allocations trace (copy a full-screen Retina screenshot, arrow through it repeatedly) with `xcrun xctrace record --template 'Allocations' --launch -- .build/release/Floodlight`; compare the high-water mark to baseline. `footprint -p $(pgrep -x Floodlight)` immediately after inspecting a 6K screenshot should show a materially lower peak.

- [ ] **F162 — single-blob storage.** Re-run the clipboard DB size baseline query after recording the same 50 screenshots; compare `SUM(LENGTH(tiff_data))` — should trend toward 0 for new entries. Run updated `ClipboardHistoryStoreTests` and `ClipboardCaptureServiceTests` assertions.

- [ ] **F172 — new budgeted tests exist and are wired into CI.** `swift test -c release --filter Clipboard` should print three new `FLOODLIGHT_BENCH clipboard_*` lines (image search, projection, inspector). Confirm the CI config actually runs `-c release` for these (a debug-build timing assertion is meaningless).

- [ ] **F164 — screen-lock observer.** `log stream --predicate 'process == "Floodlight"' --info` while locking the screen; confirm no further capture events. Run the new `ClipboardCaptureServiceTests.testPausesOnScreenLockNotification`.

- [ ] **F165 — fallback downsampling.** Re-run the 100-file arrow-through baseline with the large photo included; `footprint` peak should drop relative to baseline. Run `FileThumbnailCacheTests.testDownsamplesFallbackImage`.


# Upstream FFF

## Upstream: how Floodlight drives the FFF C API

## Mac experiments — Upstream FFI section

Toolchain prerequisites: `rustup` (stable + the toolchain pinned in `Vendor/fff/rust-toolchain.toml` if present), `cargo-instruments` (`cargo install cargo-instruments`) for sampling profiles from the CLI, Xcode + Instruments for signpost work, `zig 0.16` only if you also want to exercise the opt-in `zlob` walker (not required for anything below).

### Measure first (baseline)

- [ ] `cd <fff-swift>/Vendor/fff && cargo bench -p fff-search --bench grep_bench` — record baseline grep latency distribution. (U1)
- [ ] `cargo run --release -p fff-nvim --bin grep_profiler -- --path $HOME` with one query matching 0 files and one matching exactly 1 file — record wall time; expect it to exceed the 35 ms budget today. This is the number U1's fix should collapse. (U1)
- [ ] Cold-launch Floodlight with a fresh `~/Library/Application Support/FFFKit` (rename/move the old one aside first, don't delete), immediately type a 4-char query, and use Instruments > Points of Interest to record "ContentSourceSearch" interval durations for the first 30s. Also set `FLOODLIGHT_FFF_LOG=/tmp/fff.log FLOODLIGHT_FFF_LOG_LEVEL=debug` and check the `prefiltered_count` field on `perform_grep`'s tracing span — expect it near the total file count (unprefiltered) during warmup. (U4)
- [ ] `cargo test -p fff-c` — confirm the vendored crate builds/tests clean before touching it. (U2)
- [ ] Instruments Points of Interest: overlay "ContentSourceSearch" and "IndexedSourceSearch" intervals (`SourceSearchEngine.swift:323-325`, `:289-296`) while typing continuously at a natural pace — confirm they never overlap today. (U3)
- [ ] `cargo run --release -p fff-nvim --bin fuzzy_search_bench` (or extend `crates/fff-nvim/benches/fuzzy_search_bench.rs`'s `thread_scaling` past 8) over a home-sized index, sweeping `{2, 4, hw.perflevel0.physicalcpu, hw.logicalcpu}` on whatever Mac(s) you have (note P/E core counts via `sysctl hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu`). Record median/p95 per thread count — **do this before writing any Swift code for U6**, the direction of the effect is unconfirmed and could regress base Apple silicon.
- [ ] `Tests/FloodlightEngineTests/FFFIndexTests.swift` — run existing suite once (`swift test --filter FFFIndexTests`) to have a clean baseline before any of the above Swift-side changes land.

### After implementing

- [ ] Re-run `cargo run --release -p fff-nvim --bin grep_profiler -- --path $HOME` with the `all_matches.len() > 1` clause removed from `grep.rs:610` — 0/1-match queries should now cap near 35 ms. Confirms/refutes U1.
- [ ] Re-run the cold-launch Instruments capture from above after adding `isWarmupComplete` gating to `searchContent` — "ContentSourceSearch" should show near-zero durations (early `[]` return) during the warmup window instead of multi-hundred-ms spikes. Confirms/refutes U4.
- [ ] `cargo test -p fff-c` plus a small harness: spawn a thread that flips a cancel token's flag after 10 ms mid-grep, assert wall time drops sharply versus an uncancelled call. Confirms/refutes U2.
- [ ] Add `testIndexedApplicationSearchPerformanceBudget`-style case (mirror `Tests/FloodlightEngineTests/SearchPerformanceTests.swift`) driving `FFFIndex.track` on a path-like query 3x then searching it — assert it now ranks first (combo boost engaged). Confirms/refutes U8.
- [ ] `hyperfine` is not directly applicable to in-process Swift calls; instead use `swift test --filter FFFIndexTests -c release` timing via `xcrun xctrace` or wrap the specific test in `Date()` deltas printed to stdout for a quick A/B on the `.app`-filter over-fetch change (U7) and the `exactPathItem` `resourceValues` change (U10).
- [ ] Instruments Points of Interest re-check for U3's queue split (only after U1+U2 land): overlay the same two intervals — after a *correct* concurrent-queue implementation they should overlap for a stale grep vs a fresh search, with no result-URL corruption (spot check by comparing returned URLs' root prefix against the currently active `rootURL`).
- [ ] `make test-performance` (if defined in the Floodlight Makefile) end-to-end after each Swift-side change, to catch any regression in the existing perf test suite.
- [ ] `cargo run --release -p fff-nvim --bin rescan_probe` against `$HOME` before/after U12's `rebuild()` change — confirm wall time for "rescan" vs "restart" and, more importantly, manually verify a search issued mid-rebuild returns the *previous* result set instead of an empty one.

## Upstream: fff-core query path (make it blazing fast)

placeholder

## Upstream: index scan, cold start, and persistence

# Mac To-Do — Index Scan, Cold Start, Persistence

## Prerequisites
- [ ] `rustup show` — confirm a stable toolchain matching `fff-swift/Vendor/fff/rust-toolchain*` is installed
- [ ] `cargo install cargo-instruments` (for `cargo instruments` profiling shortcuts) — optional
- [ ] zig 0.16 only if testing the opt-in `zlob` walker feature (not needed for the default ripgrep-backend items below)
- [ ] `cd fff-swift/Vendor/fff && cargo build --release -p fff-nvim --features rescan-stats` once, to confirm the bench/probe binaries compile

## Measure first (baseline)
- [ ] `FLOODLIGHT_FFF_LOG=/tmp/fff/fff.log FLOODLIGHT_FFF_LOG_LEVEL=info` + launch Floodlight with a fresh `~/Library/Application Support/Floodlight/FileIndex` and root=$HOME. Record: `walk_filesystem` span duration, the `SCAN: Walk completed in …` line, and `files_vec=…MB / chunked_store=…MB / FileItem={}B` from the SCAN log line. (U39, U42, U43, U56)
- [ ] `fd --hidden --no-ignore --type f . ~/Library/Developer/Xcode ~/Library/CloudStorage ~/Library/Mobile\ Documents 2>/dev/null | wc -l` and compare against total files the scan reports — quantifies the IGNORED_DIRS gap before touching code. (U47)
- [ ] `cd fff-swift/Vendor/fff && FFF_BENCH_REPO="$HOME" cargo bench -p fff-nvim --bench scan -- post_scan/post_scan_only` — baseline for the binary-sniff and bigram-build passes. (U40, U44)
- [ ] `cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- "$HOME" --seconds 300` — records admitted/throttled rescans per reason (RescanStats); note baseline OverflowCapacity/IndexUpdateRejected counts. Reproduce churn with a `yarn install` or Xcode build running concurrently. (U45)
- [ ] Instruments → File Activity on `rescan_probe -- "$HOME" --seconds 30` — baseline bytes read and syscall count during the post-scan window. (U40)
- [ ] `/usr/bin/time -l` on `rescan_probe -- "$HOME" --seconds 0` — baseline max RSS; also open Instruments → Allocations and histogram 16–64 byte allocations during the walk. (U56, U49-adjacent — informational only)
- [ ] `footprint -j $(pgrep Floodlight)` and Activity Monitor Memory column after the index settles — baseline steady-state RSS. (U52, U56)
- [ ] Instruments → Time Profiler + Points of Interest during cold start with root=$HOME: capture the existing `IndexStartup` signpost duration and note when file/app results actually first render. (U39, U43)

## After implementing
- [ ] Re-run the `IndexStartup`/file-render-time measurement above after bounding `waitForScanCompletion` with a deadline; confirm app/settings results are never held hostage by the walk. (U39)
- [ ] Re-run `FFF_BENCH_REPO="$HOME" cargo bench -p fff-nvim --bench scan -- post_scan/post_scan_only` after adding the `is_binary()` skip + NUL-break in `sniff_binary_for_non_indexable`; confirm read volume drops to near-zero for extension-known binaries. Re-run File Activity too. (U40)
- [ ] Re-run `rescan_probe --seconds 300` after the watcher hidden-dir fix; confirm OverflowCapacity/IndexUpdateRejected counts drop toward zero under the same churn workload. (U45)
- [ ] Re-run the walk-count `fd` comparison after extending `IGNORED_DIRS` with `Library/Developer` (replacing `Library/Developer/CoreSimulator`) plus `*.photoslibrary`/`*.musiclibrary`/`*.tvlibrary`; confirm indexed file count drops and `walk_filesystem` span shortens on a machine with Xcode/Photos data. Do NOT remove `Library/CloudStorage` or `Library/Mobile Documents` — verify iCloud Desktop/Documents and Dropbox files are still indexed (`follow_symlinks=false` makes those the only route in). (U47)
- [ ] `cargo test -p fff-search bigram` after changing `return` to `continue` in `build_bigram_index`; add the regression test described (zero-size file at position 0 in a chunk, assert a later file in the same 256-file chunk is still grep-matched). (U54)
- [ ] Re-run the LMDB frecency measurement: populate vs. freshly-deleted `frecency.lmdb`, diff `walk_filesystem` span time, after adding the empty-DB short-circuit and per-chunk `RoTxn` reuse. Confirm via Instruments Time Profiler that `mdb_txn_begin`/`mdb_txn_commit`/`blake3` frames disappear from `fff-bg-*` threads. (U41)
- [ ] `make test-performance` (Floodlight's own perf suite, if present) before/after any of the above — sanity check nothing regressed on the per-keystroke path.
- [ ] Re-check `footprint -j` steady-state RSS after the `FileItem` content-field shrink (`OnceLock<Mmap>` → `AtomicPtr<Mmap>`) and after dropping the `INLINE_CHUNKS=8` idea (confirm no regression from leaving `SmallVec<[u32;4]>` as-is). (U56)
- [ ] Re-run the cold-start signpost after surfacing `is_warmup_complete` in `FFFIndexProgress` and gating the "no results" UI state on it; confirm the first content search after launch never reports a false "no matches" while the bigram index is still building. (U55)

## Upstream: XCFramework build flags and toolchain

## Mac experiments — Upstream: XCFramework build flags and toolchain

### Toolchain prerequisites
- [ ] `rustup` present, `rustup target add aarch64-apple-darwin x86_64-apple-darwin`
- [ ] Zig 0.16.0 installed (`brew install zig` or `mlugg/setup-zig` equivalent) — required for `--features zlob` (U57); `crates/fff-core/build.rs:19-26` hard-fails with a clear message if missing, so this is self-diagnosing
- [ ] `cargo-instruments` or plain `xcrun xctrace` available for signpost/Time Profiler work (U70, U71)
- [ ] `bloaty` (`brew install bloaty`) for compile-unit size attribution (U61, U64, U65)
- [ ] `hyperfine` for build-time and CLI-driver A/Bs (U69, U72)
- [ ] Xcode CLT (provides libclang for `bindgen`, needed transitively by `zlob`'s dependency graph — U57)

### Measure first (baseline)
- [ ] `cd <fff-swift>/Vendor/fff && rustc --print cfg --target aarch64-apple-darwin | grep target_feature` — does the default already imply `dotprod`/`neon`? Answers U68 outright; record output verbatim.
- [ ] `cd <fff-swift> && lipo -info Artifacts/CFFF.xcframework/*/libfff_c.a` (or unzip a released `CFFF.xcframework.zip`) — confirm current build is arm64-only (U67 baseline).
- [ ] `swift build -c release -Xlinker -map -Xlinker /tmp/fl-base.map` in Floodlight; then:
  - `grep -c 'libfff_c.a' /tmp/fl-base.map`
  - `grep -c 'serde_json' /tmp/fl-base.map` (U61, U64 baseline)
  - `grep -cE 'tracing_subscriber|regex_automata|matchers|tracing_appender' /tmp/fl-base.map` (U65 baseline)
  - `grep -c FFFKit /tmp/fl-base.map` (U66 baseline)
- [ ] `ar t <fff-swift>/Vendor/fff/target/aarch64-apple-darwin/release/libfff_c.a | grep -c libgit2` (U64 baseline)
- [ ] `./autoresearch.sh` once on `main`, record `deliverable_size_bytes`, `binary_size_bytes`, `dmg_size_bytes`, `search_latency_us`, `selection_latency_us`, `fuzzy_scoring_us` — this is the before-number every change below diffs against.
- [ ] `cd <fff-swift>/Vendor/fff && CARGO_LOG=cargo::util::config=debug ./scripts/build-xcframework.sh 2>&1 | grep -i config` — confirm `.cargo/config.toml` is not read today (U59 baseline). Optionally poison `.cargo/config.toml` with `"-C","target-cpu=definitely-not-a-cpu"` and confirm the build still succeeds (proves it's ignored), then revert.
- [ ] `nm -gU <fff-swift>/Vendor/fff/target/aarch64-apple-darwin/release/libfff_c.a | grep -E ' T _(malloc|free|calloc|realloc|posix_memalign)$'` — must already be empty before touching mimalloc (U63 gate).
- [ ] `sample Floodlight 3 -f /tmp/fl.sample && grep -c 'rayon-' /tmp/fl.sample` while typing a query — confirm the unnamed global rayon pool exists today (U62 baseline).

### After implementing

**U66 — own the XCFramework**
- [ ] `swift package show-dependencies` shows no remote packages after switching to a local `binaryTarget`
- [ ] `make check && make test && make test-performance` green

**U57 + U58 — zlob walker + lossy-offset backport (land together)**
- [ ] From `<fff-swift>/Vendor/fff`: `cargo test -p fff-search --no-default-features --features zlob --lib walk` and full `cargo test -p fff-search --no-default-features --features zlob` — must pass, including the backported `tests/invalid_utf8_paths.rs`
- [ ] `cargo bench -p fff-search --bench glob_bench --no-default-features --features zlob` — record ns/iter
- [ ] Rebuild XCFramework, `swift package edit fff-swift --path <fff-swift>`, `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`; compare `expanded_fff_scan_ms` vs a ripgrep-built framework — confirms/refutes U57's core claim
- [ ] Instruments Points of Interest, signpost `IndexStartup`, before/after
- [ ] `sudo fs_usage -w -f filesys $(pgrep Floodlight) | grep -c stat64` during first scan, before/after
- [ ] `printf 'x' > "$(printf 'bad\xffname.txt')"` fixture, run `FFFIndexTests` against that root, assert name renders lossily without panicking — confirms U58

**U61 — dead_strip + no_exported_symbols**
- [ ] `swift build -c release -Xlinker -map -Xlinker /tmp/fl-strip.map`; diff `libfff_c.a`/`serde_json` symbol counts against baseline
- [ ] `./autoresearch.sh`; compare `deliverable_size_bytes`, `binary_size_bytes`, `dmg_size_bytes`
- [ ] `make bundle && open .build/Floodlight.app` — exercise hotkey, file search, content search, Quick Look
- [ ] `codesign --verify --deep --strict .build/Floodlight.app`

**U64 — libgit2 gating**
- [ ] `ar t .../target/.../libfff_c.a | grep -c libgit2` after — should drop to 0
- [ ] `./autoresearch.sh` deltas
- [ ] `cargo test -p fff-search --no-default-features --features zlob --lib --test rescan_regression`
- [ ] `cargo test --workspace --no-default-features --features zlob --exclude fff-nvim --exclude fff-python`, then `swift test`

**U65 — tracing gating**
- [ ] Apply step (a) `release_max_level_warn` alone first; `./autoresearch.sh`; isolate its delta
- [ ] Then step (b) feature-gate; re-run `./autoresearch.sh`
- [ ] `swift test --filter FFFIndexTests` still green

**U60 — panic=abort profile**
- [ ] `ls -l target/aarch64-apple-darwin/release/libfff_c.a` vs `target/aarch64-apple-darwin/xcframework/libfff_c.a`
- [ ] `./autoresearch.sh`; compare `deliverable_size_bytes`/`binary_size_bytes`
- [ ] `make test` (fff-swift), `swift test` (Floodlight)

**U69 — staticlib-only build**
- [ ] `hyperfine --runs 2 --prepare 'cargo clean --manifest-path Vendor/fff/Cargo.toml' './scripts/build-xcframework.sh'` before/after
- [ ] Confirm no `.dylib` in `target/.../release/`; `lipo -info`/`ar t` on `.a` unchanged

**U73 — toolchain pin + BUILDINFO**
- [ ] Build twice from clean, `shasum -a 256` both `.a`s, must match
- [ ] `rustc -V` matches pin; `./scripts/build-xcframework.sh | tail -3` shows BUILDINFO lines

**U59 — config/toolchain discovery fix**
- [ ] Re-run the poison-flag test post-fix: must now fail the build (proves discovery works)

**U63 — mimalloc global allocator**
- [ ] Re-run the `nm -gU ... malloc|free|...` symbol check — must stay empty
- [ ] `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`
- [ ] `footprint -p $(pgrep Floodlight)` 60s after `IndexStartup`, before/after
- [ ] `cargo bench -p fff-search --bench bigram_bench`

**U62 — SEARCH_THREAD_POOL for scoring**
- [ ] `sample Floodlight 3 -f /tmp/fl.sample && grep -c 'rayon-'` — should show fewer/no bare `rayon-N` threads after the mitigation or upstream fix
- [ ] Instruments Time Profiler + POI, 200 keystrokes, `RAYON_NUM_THREADS=12` vs unset
- [ ] `cargo bench -p fff-nvim --bench fuzzy_search --no-default-features --features zlob` with/without env var
- [ ] `powermetrics --samplers cpu_power -i 1000` while typing, before/after

**U71 — signposts**
- [ ] `xcrun xctrace record --template 'Points of Interest' --launch .build/Floodlight.app --output /tmp/fl-poi.trace`; type 20-30 queries; inspect `FFFSearchMixed`/`FFFLiveGrep`/`FFFCall` intervals

**U70 — profile.prof selectable**
- [ ] `CARGO_PROFILE=prof ./scripts/build-xcframework.sh`; `dwarfdump --file-stats .../prof/libfff_c.a | head` confirms symbols present
- [ ] `xcrun xctrace record --template 'Time Profiler' --launch .build/Floodlight.app`; confirm named Rust frames resolve

**U68 — target-cpu**
- [ ] Only proceed if the baseline `rustc --print cfg` step above shows dotprod/neon are NOT default
- [ ] `cargo bench -p fff-search --bench memmem_bench` with/without `RUSTFLAGS='-C target-cpu=apple-m1'`
- [ ] Smoke-launch on an actual M1 Mac (or `otool -h`) — portability gate

**U67 — universal binary**
- [ ] `lipo -info` on the fat `.a` must print `arm64 x86_64`
- [ ] `arch -x86_64 swift build -c release --arch x86_64 && make bundle && open .build/Floodlight.app` on an Intel Mac
- [ ] `RUSTFLAGS='-C target-cpu=x86-64-v3' cargo bench -p fff-search --bench memmem_bench --bench bigram_bench` vs unset (Intel slice only)

**U74 — cross-module-optimization / exclusivity**
- [ ] For each variant individually: `make test-performance` and `./autoresearch.sh`, 3 runs, medians
- [ ] For `-enforce-exclusivity=unchecked` only: `make test-sanitizers` must stay green; `nm .build/release/Floodlight | grep -c swift_beginAccess` should drop

**U72 — PGO**
- [ ] Confirm `-Cprofile-generate` composes with `lto=fat` + `staticlib` on this target before investing further (research prompt below)
- [ ] `FLOODLIGHT_RUN_INDEX_BENCH=1 FLOODLIGHT_BENCH_ROOT=$HOME swift test -c release --filter testExpandedFFFIndexScanBenchmark` and `swift test -c release --filter PerformanceTests`, PGO vs non-PGO
- [ ] `cargo bench -p fff-search --bench grep_bench --bench bigram_bench --bench memmem_bench`, both variants
- [ ] `hyperfine --warmup 3 --runs 50 '/tmp/fff_pgo_driver $HOME'`
- [ ] `./autoresearch.sh` — confirm size doesn't regress past what U60/U61 recovered

## Upstream: version drift, re-vendoring, and backports

# Mac experiments — Upstream: version drift, re-vendoring, and backports

Prereqs: `rustup` (stable, matching `Vendor/fff/rust-toolchain.toml` if present), Xcode 16+/Swift 6.4, `zig 0.16` (`brew install zig`) only for zlob-gated work, `cargo-instruments` optional, Instruments.app for signposts.

## Measure first (baseline)

- [ ] U75/U77: `cargo build --manifest-path fff-swift/Vendor/fff/Cargo.toml -p fff-c --release` then rebuild XCFramework (`fff-swift/scripts/build-xcframework.sh`); launch Floodlight, Instruments -> Blank template + os_signpost, subsystem `com.floodlight.app`, category Points of Interest, interval `IndexStartup`. Record median/p99 startup duration over 10 launches (cold, empty caches).
- [ ] U75: time `FFFFileSource.start()` directly — release `swift test -c release --filter FFFIndexTests` — record wall time; expect ~10-20ms attributable to the double idle-poll.
- [ ] U76/U77/U78/U79: `cargo test --manifest-path fff-swift/Vendor/fff/Cargo.toml -p fff-search --release -- watcher` baseline pass/timing. Then with Floodlight running and a home-directory scope, `git clone --depth 1 https://github.com/torvalds/linux big-repo` inside the scope; Instruments System Trace, look at the fff dispatch queue's blocked time and `IndexedSourceSearch` signpost p99 during the clone.
- [ ] U78/U79: build with `cargo build --manifest-path fff-swift/Vendor/fff/Cargo.toml --release -p fff-nvim --features rescan-stats` (if the feature exists in the vendored tree — confirm first with `rg rescan-stats fff-swift/Vendor/fff/crates/*/Cargo.toml`); script deep directory creation (`for i in {1..300}; do mkdir -p scratch/d$i/{a,b,c,d,e,f,g,h}; done`) and record rescan count/reason before any fix.
- [ ] U80: `diff -rq fff-swift/Sources/FFFKit fork/Sources/FloodlightEngine/Search` to confirm the only functional delta is `enableHomeDirectoryScanning`; `swift build -c release && ls -l .build/release/Floodlight` for baseline binary size (dead FFFKit code included).
- [ ] U81: Instruments os_signpost interval `ContentSourceSearch`; launch app, type immediately post-launch, record how many 0-match full-35ms-budget intervals occur before warmup completes.
- [ ] U82/U83: `git -C fff diff v0.10.5..v0.10.6 --stat` to confirm disjointness claim; `cargo build --manifest-path fff-swift/Vendor/fff/Cargo.toml -p fff-c --release 2>&1 | rg zlob` (expect empty) and `nm -gU fff-swift/Vendor/fff/target/*/release/libfff_c.a | rg -i zlob` (expect empty) to prove zlob is not linked today.
- [ ] U84: `cargo test --manifest-path fff-swift/Vendor/fff/Cargo.toml -p fff-search --release -- non_git_scan_respects_binary_filename_indexing_option`; then `swift test --filter CatalogTests` with `ApplicationCatalog.swift:69`'s `includeBinaryFiles` flipped to `true` and confirm identical results (proves the no-op claim).
- [ ] U85: `cargo run --manifest-path fff-swift/Vendor/fff/Cargo.toml --release -p fff-nvim --bin grep_profiler` and `--bin bench_grep_query` against `./big-repo`; record matches returned per 35ms slice vs `filtered_file_count`/`total_matched` on repeated same-query calls (proves the no-pagination ceiling).
- [ ] U86: `brew install zig` then `make -C fff-swift cargo-test-zlob` (target does not exist yet — expect failure; this documents the gap).
- [ ] U87: `cargo bench --manifest-path fff-swift/Vendor/fff/Cargo.toml -p fff-nvim --bench query_tracker` and `--bench fuzzy_search -- search`; record ns/op for the LMDB lookup path with `combo_boost_score_multiplier` at 0 vs 100.
- [ ] Baseline all: `make test-performance` in the Floodlight repo, save `.build/performance.log` FLOODLIGHT_BENCH lines as the "before" snapshot.

## After implementing

- [ ] U75: reapply signpost run from baseline; expect `IndexStartup` down by ~5-10ms, `changeScope`/`rebuild` down by ~10-20ms (double-wait on error path removed).
- [ ] U76/U77: rerun the `git clone`-during-search System Trace; expect no visible write-lock blocked-time spike, `IndexedSourceSearch` p99 flat during the clone.
- [ ] U78/U79: rerun deep-directory-creation script; expect zero rescans triggered (`rescan-stats` output), and add the regression test near `watcher_directory_event_registers_directory_and_ancestors` (file_picker.rs:2645) asserting no rescan for 300 depth-8 dirs.
- [ ] U80: after FFFKit swap, `make check && make test && make test-performance`; diff FLOODLIGHT_BENCH lines against baseline; confirm `swift build -c release` binary is smaller (dead FFFKit copy gone).
- [ ] U81: rerun `ContentSourceSearch` signpost capture; expect zero full-budget-empty intervals before warmup completes (they should simply not appear until `isWarmupComplete`).
- [ ] U82: `git subtree pull` to v0.10.6; `make -C fff-swift cargo-test && make -C fff-swift test`; confirm the two new upstream tests appear (skipped under default features) via `cargo test ... --no-default-features --features zlob -- invalid_utf8 dotdir_glob`.
- [ ] U84: after choosing option (a) upstream PR or (b) local removal, rerun `cargo-test` + `swift test` + `make test-performance`; confirm ABI version field removed/upstreamed and vendor diff line count dropped (target: -2/3).
- [ ] U85: after pagination wired, rerun `grep_profiler`/`bench_grep_query`; record matches-per-query across multiple keystrokes on the same query — expect monotonic growth instead of a flat ceiling at the 35ms slice size. Add a FLOODLIGHT_BENCH line to SearchPerformanceTests for matches-per-35ms tracked by `make test-performance`.
- [ ] U86: after adding `cargo-test-zlob` target and CI wiring, `make -C fff-swift cargo-test-zlob` should pass with both new upstream tests executing; `make -C fff-swift cargo-test` (ripgrep) still green.
- [ ] U87: rerun query_tracker/fuzzy_search benches with the `combo_boost_score_multiplier != 0` guard in place and ApplicationCatalog passing 0; expect the LMDB open/close cost gone from that path's profile.

