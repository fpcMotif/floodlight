# Floodlight optimization opportunities

Audit date: 2026-09-02. Branch: `claude/optimization-opportunities-ca1e6d` at `936926b`.

Files in this folder:

- **`README.md`** (this file): scope, method, executive summary, top picks per section, Swift practice notes, suggested order of work.
- **`report.md`**: the full report. Sixteen sections, one per audit lens, each with a ranked table, one subsection per opportunity (where, evidence, mechanism, proposal, impact, effort/risk, how to verify on a Mac, reviewer caveats), and a "Rejected ideas" list.
- **`mac-todo.md`**: every experiment, measurement, and test to run on a Mac, as a checklist with exact commands.
- **`research-prompts.md`**: copy-paste prompts for an AI research assistant (web research mode) for facts that must be looked up before implementing.
- **`findings-index.md`**: one line per finding with ID, status, file:line, effort, and risk.

## Scope

1. Search speed (per-keystroke path: algorithmic, allocation, concurrency)
2. Cold start (launch to hotkey, to first panel, to first results, to settled index)
3. Responsiveness (main thread, SwiftUI, clipboard runtime)
4. Richer text (clipboard rich text capture, paste, preview; richer result rows)
5. Clipboard history management and power-user convenience
6. Beyond the five: build, memory, energy, indexing, testing, repo hygiene
7. Upstream: the FFF engine (Rust), fff-swift, and how Floodlight drives them

## Method and trust level

This audit ran on Windows. Nothing was compiled, run, or measured. Every claim comes from reading the code at the commit above, plus the upstream checkouts (fff-swift 0.2.1 with vendored fff 0.10.5, dmtrKovalenko/fff main at 0.10.6, vmg-dev/floodlight main).

Pipeline: lightweight explorers mapped every file; larger-model finders audited each area through 16 lenses; every finding was then attacked by two independent skeptics (one for accuracy against the code, one for value and feasibility); a writer per lens incorporated the skeptics' corrections.

| | Floodlight (F-series) | Upstream FFF (U-series) |
|---|---|---|
| Raw findings | 220 | 97 |
| After dedup | 172 | 88 |
| Confirmed (both skeptics accepted) | 119 | 26 |
| Plausible (split vote) | 35 | 24 |
| Refuted (both rejected; listed under "Rejected ideas") | 18 | 9 |
| Unreviewed (reviewers lost to a session limit; U60 to U88) | 0 | 29 |

Magnitudes ("~N ms", "~N allocations") are estimates from code reading. The Mac to-do list exists to replace them with measurements before anything is implemented. Several finder claims were scaled down by the reviewers (for example, the application catalog holds low hundreds of apps, not 1,500); the sections carry the corrected numbers.

## Executive summary

Floodlight's Swift search path is already lean for apps and settings. The latency and cold-start floor sits in three places: the clipboard subsystem (new, and doing disk and image work on the main thread), the FFF engine and how it is called (no file results until the whole home directory is walked; short queries scored against the entire index), and a handful of launch-time chores. The clipboard feature also makes several user-facing promises the code does not keep.

### The twelve highest-leverage opportunities

Statuses are the reviewers' verdicts. IDs link to `report.md` and `findings-index.md`.

| # | IDs | Opportunity | Area | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | U43, U42, U39 | Commit the index progressively and serve file results during the initial walk; persist a snapshot so a warm launch is an mmap, not a rescan | Cold start, upstream | L | medium | U43, U42 confirmed; U39 plausible |
| 2 | U21, U22, U24, U23 | Stop scoring the whole index for 1-6 character queries: typo floor, 1-char full materialization, no top-k, single-threaded scoring loop | Search speed, upstream | M-L | medium | confirmed |
| 3 | F42, F72, F92, F52 | Move every clipboard write (text, files, 0-30 MB images) off the main thread; stop loading 1000 thumbnails at launch | Responsiveness, cold start | M | medium | confirmed |
| 4 | F68, F88, F163, F75 | Compute the Clipboard Inspector once per selection, not once per SwiftUI body; stop decoding full-size PNGs on the main thread | Responsiveness | M | medium | confirmed |
| 5 | F69, F6, F161, F100, F101, F116, F23 | Cap clipboard projection at the visible page; drop the per-row `stat`, JSON parse, and 32 KB string flattening | Responsiveness, search speed | M | low | confirmed |
| 6 | F95, F106, F127, F136, F135 | Make Return actually paste into the frontmost app (CGEvent ⌘V behind an Accessibility grant), fix the "Paste to App" label, implement or remove "Actions ⌘K", make ⌘C copy the image | Clipboard UX | L | medium | confirmed |
| 7 | F99, F103, F121 | Capture RTF/HTML alongside plain text, restore all types on paste, add paste-as-plain-text | Richer text | L | medium | confirmed |
| 8 | U1, U2, U4, F34 | Bound and cancel content search: the 35 ms grep budget is inert for 0/1-match queries, no abort token, unprefiltered grep during warm-up, stale greps still run | Search speed | S-M | low | confirmed (U3 serial-queue claim: plausible) |
| 9 | F53, F54, F55, F38, F56, F59 | Cold-start chores: cache the login `$PATH` (two `zsh -l` spawns per launch), persist the app and settings catalogs, stop re-syncing markers, defer SMAppService | Cold start | S-M | low | F53, F54, F55 confirmed; rest plausible |
| 10 | U47, U57, U58, U45, U48 | Cut the indexed set and the walk: ignore `~/Library/Developer` and library bundles by default, ship the zlob walker (with the 0.10.6 non-UTF-8 fix), fix the hidden-dir watcher rule, expose ignore patterns through the C API | Cold start, upstream | S-M | low-medium | confirmed; U48 plausible |
| 11 | F129, F131, F130, F124, F132 | Power-user keys: ⌘1-⌘9 quick paste (resolve the filter conflict), a dedicated clipboard hotkey, Ctrl-N/P, remembered filter, live updates | Clipboard UX | S-L | low | confirmed |
| 12 | F142, U61, U64, U65, U60, U66 | Size and hygiene: remove 48 tracked `.bc` files (8.6 MB), own the XCFramework build, `-dead_strip`, drop libgit2 and tracing, `panic=abort` | Beyond, upstream | S-M | low | F142 confirmed; U-items unreviewed |

### Correctness defects found on the way (all confirmed; fix regardless of performance)

- F89: "Forever" retention silently prunes at 30 days.
- F91: copying text from Numbers, Excel, or Keynote records a TIFF and discards the text.
- F128: "Exclude from Search" on a clipboard row poisons the local blocklist and breaks the mode.
- F136: ⌘C on an image entry copies the word "Screenshot", not the image.
- F119, F168: Quick Look writes full-resolution clipboard images to `/tmp` and never deletes them.
- F118: deleted and cleared clipboard content stays recoverable in the database and WAL.
- F117: "Clear all history" deletes pinned entries with no confirmation.
- F120: capture starts default-on before onboarding consent, with an empty password-manager exclusion list.
- F8: the character-mask prefilter silently disables substitution-typo matching for apps and settings.
- U54: `return` used where `continue` was meant in the bigram builder, skipping the rest of a 256-file chunk.
- U34: filename-bonus scoring uses a different needle than the one that matched.
- U8: `fff_track_query` records the raw query while search receives the path-translated one, so combo boost never fires for path queries.

### Ideas the reviewers rejected (do not re-investigate without new evidence)

The full list is in each section's "Rejected ideas". The ones most likely to be re-proposed: F73 (first keystrokes after the hotkey are not actually lost), F70 (splitting the monolithic `publication` property; row views are already `.equatable()`), F35 and U33 (cancellation bridging into the FFF dispatch queue; the generation guard already covers it), U29 (a pinned P-core pool for fuzzy search), F51 (opening the clipboard store is not on the pre-panel critical path as claimed), F114 (FTS text column design), F15 and F43.

### Top picks per section

- **Search speed: algorithmic** (20 findings): F4 — Reorder the blocklist check after the mask guard on ApplicationCatalog's per-keystroke scan; F1 — Add a single initialMask bit per Application to prune the immediate-page scan before scoring, cutting scored candidates 3-8x on realistic app counts; F8 — Fix the character-mask prefilter so it does not kill substitution/insertion-typo matching.
- **Search speed: allocation and data layout** (13 findings): F23 — clipboard row rebuild (multi-KB snippets, main actor, per keystroke) plus a synchronous-stat regression; F21 — `characterMask` gate before the blocklist check; F30 — hoist the constant `id` string onto `Setting` at init.
- **Search speed: concurrency** (16 findings): F42 — clipboard capture decodes, hashes, and inserts up to ~30 MB on the main actor on every system-wide clipboard change; F41 — every space keypress eagerly evaluates a preview URL that can trigger a 15 MB SQLite blob read; F37 — PathNavigator enumerates directories synchronously on the main actor for path-shaped queries.
- **Cold start** (18 findings): F50 — gate panel construction and focus steal at login-item boot on the launch source; F54/F55 — persist the application catalog snapshot and stop the per-app marker `fileExists`; F52 — drop eager thumbnail-blob reads from the clipboard store's initial window.
- **Responsiveness: UI and main thread** (17 findings): F68 — memoize the `clipboardInspector` computed property; F69 — cap clipboard row projection; F72 — move ClipboardImageCapture's decode/thumbnail/SHA-256/blob-write pipeline off the 0.5 s main-thread timer and stop reading the full TIFF just to discard it.
- **Responsiveness: clipboard runtime** (14 findings): F91 — Numbers/Excel/Keynote copies recorded as TIFF; F89 — "Forever" retention is dead; F95 — "Paste to App" names the wrong app and never pastes.
- **Richer text** (17 findings): F106 — footer affordances are false; F115 — retention "Forever" ignored (same root as F89); F102 + F100/F101 — unbounded-body work per selection/keystroke, one shared bounded-prefix fix.
- **Clipboard history management** (11 findings): F120 — default-on capture before consent with an empty exclusion list; F117 — Clear all destroys pins without confirmation; F125 — the exclusion control is an exact-match bundle-ID box whose copy promises name matching.
- **Clipboard power-user convenience** (15 findings): F128 — Exclude from Search on a clipboard row poisons the blocklist; F127 — "Actions ⌘K" is dead and the chip performs ⌘C; F136/F135 — ⌘C on an image copies "Screenshot", Return on a URL copies instead of opening.
- **Beyond: build, testing, hygiene, docs** (19 findings): F147 — tests open the developer's real clipboard DB and UserDefaults; F146 — release.yml ships a notarized DMG with zero gates run; F144 + F143 — dead perf budgets (skipped index-scan bench, unrepresentative clipboard fixture).
- **Beyond: memory, energy, indexing** (12 findings): F168 — QuickLook previews leak to `$TMPDIR` forever; F167 — every space keypress does an uncached synchronous blob read; F161 — unbounded clipboard projection with a blocking per-row stat.
- **Upstream: how Floodlight drives the C API** (20 findings): U1 — the 35 ms grep budget is inert until 2 matches exist (one-line fix); U4 — content search runs unprefiltered during bigram warm-up because `is_warmup_complete` is never read; U2 — no cancel token for a stale live-grep.
- **Upstream: fff-core query path** (18 findings): U21 — typo floor of 2 makes short queries match essentially the whole index; U24 — no top-k, every match materialized then `select_nth` over all of them; U22 — 1-char queries score and materialize the entire index.
- **Upstream: scan, cold start, persistence** (18 findings): U47 — extend `IGNORED_DIRS` for `~/Library/Developer` and library bundles (keep CloudStorage and Mobile Documents); U40 — skip the redundant full-file read in binary sniffing for extension-flagged files; U45 — apply the hidden-dot-component rule in the watcher to stop repeated full rescans.
- **Upstream: build flags and toolchain** (18 findings, unreviewed): U66 — own the XCFramework build so flag changes are not blocked behind a third-party release; U57 + U58 — build with the zlob walker plus the 0.10.6 non-UTF-8 fix; U61 — link with `-dead_strip` and `-no_exported_symbols`.
- **Upstream: version drift and backports** (14 findings, mostly unreviewed): U76 — watcher directory registration walks ancestors under the picker write lock; U77 — missing `files_to_add.is_empty()` early return takes the write lock on every empty-directory event; U84 — `include_binary_files` is the largest slice of the vendor delta and a no-op in production.

## Swift 6.4 practice notes (from reading the shell and engine)

These are patterns rather than single findings. Each points at the finding that carries the evidence.

- **Do not do I/O in computed properties of an `@Observable`.** `clipboardInspector` and `previewableSelectionURL` on `SearchCoordinator` hit SQLite, Launch Services, and the filesystem on every SwiftUI body evaluation. Make them stored properties updated when the selection changes (F68, F41, F167).
- **Keep the main-actor timer path free of decode and disk work.** The pasteboard poll runs on `Timer` + `MainActor.assumeIsolated`; the decode, thumbnail, hash, and SQLite insert belong in a `@concurrent nonisolated` function, the same pattern `FileIconCache.loadWorkspaceIcon` already uses (F42, F72, F92).
- **Prefer `SQLITE_TRANSIENT` (or `withCString`) over `(s as NSString).utf8String` with a nil destructor.** The bound pointer is autoreleased storage; it is only valid while the pool lives, and the binding happens inside `OSAllocatedUnfairLock.withLock`. The file already defines `sqliteTransient` for blobs; use it for text too (`ClipboardHistoryStore.swift:233`, `ClipboardHistorySQLite.swift:5`).
- **Do not copy large arrays out of an unfair lock on the main thread.** `search(query: "")` returns `pinnedEntries + recentEntries` (up to 1000 entries with thumbnail `Data`) under the lock, per keystroke, while the poll timer contends for the same lock (F93, F86).
- **Bound what enters a value type that SwiftUI diffs.** `SearchItem` carries `.thumbnail(Data)` and 32 KB texts, so `Equatable` on rows becomes a memcmp of payloads. Store an ID or a hash in the item and keep bytes in a cache (F28, F169).
- **Re-register observation only when the observed value changes at the boundary you care about.** `withObservationTracking` in `FloodlightPanelController` allocates a Task and re-registers on every keystroke though the height only changes at the empty/non-empty boundary (F80).
- **Cache formatters and Sets.** `DateFormatter`, `NumberFormatter`, `Calendar`, and extension `Set` literals are rebuilt per render or per call in `ClipboardInspector`, `Calculator`, `ResultShowcase`, and `SearchFilterChip` (F76, F113, F170, F83, F112).
- **`sha256Hex` builds 32 `String(format:)` values per hash.** A 16-entry lookup table into a preallocated buffer is the idiomatic replacement, and it sits on the same main-thread path as F42 (`ClipboardHistorySQLite.swift:171`).
- **`Task.detached(priority: .utility)` holding an exclusive lock invites priority inversion.** The launch-time prune runs at utility QoS while main-thread clipboard writes wait on the same `OSAllocatedUnfairLock` (F60, plausible).
- **The package already opts into `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`.** That is the right Swift 6.4 setting; the remaining isolation problems are architectural (I/O on the main actor), not annotation gaps.

## Suggested order of work

1. Run the global baselines in `mac-todo.md` so every later change has a before number.
2. One PR of confirmed small items: F142, F89, F136, F135, F127, F106, F53, F94, F76, F88, F4, F21, F30, F41, F167, F168, F119, U8, U75.
3. Clipboard runtime PR: #3, #4, #5 above, plus F164 (poll back-off) and F96/F162 (store one image representation).
4. Search-speed PR on the Floodlight side: F2, F1, F3, F9, F22, F25, F34, F37, F8.
5. Upstream, in this order: measurement first (U38, U70, U71), then U1/U4/U2, then build flags (U57 + U58, U59, U61, U63, U66), then the engine changes (#2), then progressive index and snapshot (#1). Each engine change is worth proposing to dmtrKovalenko/fff.
6. Clipboard UX and rich text (#6, #7, #11) once the runtime is solid.

Research prompts in `research-prompts.md` unblock the items that depend on a fact that must be looked up (FSEvents since-event semantics, mimalloc inside a static library consumed by Swift, `org.nspasteboard` conventions, and similar).
