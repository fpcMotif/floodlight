# Floodlight optimization report: full sections

See [README.md](README.md) for scope, method, status legend, and the executive summary. Sections are grouped by area; each section is one audit lens. Status per opportunity: confirmed (both reviewers accepted), plausible (split vote, disagreement summarized), unreviewed (U60 to U88 only: reviewers did not run). Refuted ideas are listed at the end of each section.

# Search speed

## Search speed: algorithmic

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F4 | Reorder blocklist check after the mask guard; snapshot the blocklist instead of locking per app | Low (but near-zero cost) | XS | Low | Confirmed |
| 2 | F1 | Word-initial index (or a single `initialMask` bit) to prune app candidates before scoring | Medium | S (mask variant) / M (posting-list variant) | Low–Medium | Confirmed |
| 3 | F8 | Character-mask prefilter kills substitution-typo matching for apps/settings | Medium (correctness) | S | Low–Medium | Confirmed |
| 4 | F17 | SystemCatalog holds its lock across the whole scoring loop | Low | S | Low | Confirmed |
| 5 | F2 | SourceSearchEngine reruns the full app+settings immediate scan a second time per keystroke | Low (structural correctness risk if cached wrong) | S | Low–Medium | Confirmed |
| 6 | F3 | immediatePage builds a full SearchItem for every match before top-K | Low–Medium | S (cheap variant) | Low | Confirmed |
| 7 | F9 | FuzzyMatcher re-extracts word boundaries/initials per candidate per keystroke | Low | S (reserveCapacity) / M (full precompute) | Low | Confirmed |
| 8 | F7 | PathNavigator.resolve does synchronous directory listing on the main actor, several times per keystroke | Medium | S (literal-probe first) / M (full fix) | Low–Medium | Confirmed |
| 9 | F6 | projectClipboard builds a row (with a conditional `fileExists`) for every entry, uncapped, on the main actor | Medium | M | Medium (browse-truncation regression risk) | Confirmed |
| 10 | F5 | Clipboard short-query (<3 char) search does an uncapped locale-aware scan | Low–Medium | S (cap only) / M (folded key) | Low–Medium | Confirmed |
| 11 | F10 | ranksBefore falls to `localizedStandardCompare` on every score tie; content rows all tie | Low | S (step 1 only) | Low | Confirmed |
| 12 | F12 | Query normalized/masked independently by each catalog, 4–5x per keystroke | Low | M | Low | Confirmed (low value; keep only as prerequisite/DRY) |
| 13 | F13 | Shell re-runs the blocklist filter over already-filtered candidates | Low | XS | Low | Plausible (refuted by value skeptic; keep only as tidy-up) |
| 14 | F14 | Calculator/keyword/path rows rebuilt on each of 2–4 projections | Low | XS (micro-fixes only) | Low | Plausible (memoization proposal refuted; keep only NumberFormatter/host hoists) |
| 16 | F16 | Exact-path dedupe recomputes `standardizedFileURL` inside the loop | Negligible | XS | Low | Plausible (refuted on value; trivial hoist only) |
| 18 | F18 | App-search benchmark measures the CI runner's real catalog, not a realistic fixture | Testing gate | S | Low | Confirmed |
| 19 | F19 | No budgeted test for shell-side projection (main-actor work) | Testing gate | M | Low | Confirmed |
| 20 | F20 | No budget/cap for clipboard capture-to-row latency at realistic sizes | Testing gate | M | Low | Confirmed |

Ranked by impact/effort as revised by both skeptics — several findings the raw report called "high impact" are demoted to low/medium once real candidate counts (low hundreds of apps, not 1,500; tens of ms already spent sleeping) and existing prefilters (SystemCatalog's word-prefix gate, the character mask) are accounted for. F11 (RecentStore.boostMap rebuild) is dropped from the ranked list — the value skeptic refuted it outright (empty store in the shipped benchmark, tens of entries in practice) and only its trivial sub-part (hoist `boostMap()` once in `indexedItems`) survives; folded into F1/F2 write-ups below as an aside, not its own row.

### F1 — Prune app candidates with a first-byte index instead of the presence-only character mask

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:182-190` (loop), `:186` (mask guard), `:453-479` (`assignMarkerNames`/mask build)

**Evidence**
```swift
for application in currentApps {
    if blocklistStore.isBlocked(name: application.name, id: application.id) {
        continue
    }
    guard application.characterMask & queryCharacterMask == queryCharacterMask else {
        continue
    }
    guard let score = Self.score(...) else { continue }
```

**Why it costs / what is missing**: `characterMask` only rejects a candidate when a query character is entirely absent — for a 1–2 char query almost every app passes. All five `FuzzyMatcher` shapes (`exact`, `namePrefix`, `wordPrefix`, `acronym`, `typo`) require the query's first normalized byte to equal the candidate's first byte or some word's first byte (`FuzzyMatcher.swift:100,104,144,177-178,235,242`). For short queries `editBudget` is 0 (`FuzzyMatcher.swift:265-271`), so no Damerau-Levenshtein runs anyway — the cost being paid per rejected candidate is one `extractWordsASCII` allocation plus two `starts(with:)` calls, not "fuzzy scoring."

**Proposal**: Add a stored `initialMask: UInt64` per `Application`, built in `assignMarkerNames` next to the existing `characterMask` (`ApplicationCatalog.swift:467`), from `normalized.first` plus every byte following a `FuzzyMatcher.isSeparatorByte`. Guard in `immediatePage` as `application.initialMask & queryInitialBit == queryInitialBit`. This is a single extra `UInt64` and one AND, not a `[UInt8: [Int32]]` posting list — same selectivity, no new data structure, no explicit non-ASCII fallback needed (non-alphanumeric/non-ASCII first scalar maps to bit 0, which passes open). Drop the SystemCatalog half of the original proposal entirely: `SystemCatalog.swift:348-361` already applies a *stricter* full word-prefix filter for every query under 4 bytes, and `setting.words` splits on a different boundary rule than `FuzzyMatcher.isSeparatorByte`, so it is not safely reusable as an initials source.

```swift
// assignMarkerNames, alongside `let mask = characterMask(normalized)`
let initialMask = characterMask(String(normalized.prefix(1)))
    | words.dropFirst().reduce(UInt64(0)) { $0 | characterMask(String($1.first.map(String.init) ?? "")) }
```

**Expected impact**: 3–8x fewer candidates reach `extractWordsASCII`/scoring on a realistic Mac (low hundreds of apps, not 1,500 — `discoverApplications` walks a handful of roots with `skipDescendants()`). Removes one allocation per rejected candidate. Medium, not high — this shows up in a microbenchmark, not as user-perceptible latency (existing budget is <1000 µs/query).

**Effort/Risk**: S / Low with the mask variant (both skeptics preferred it over the posting-list). Land the blocklist reorder (F4) first — it is a free win on the same loop and both skeptics flagged it as higher-value-per-line than this one.

**How to verify on Mac**:
```bash
swift test -c release --filter testApplicationCatalogInitialIndexBudget   # add this test first
make test-performance
swift test --filter CatalogContractTests
```
Seed a fixture `discoveryProvider` with 300–500 synthetic apps (not 1,500 — match the corrected estimate), warm up, take 11×80-sample medians, print `FLOODLIGHT_BENCH app_immediate_page_us=`. Add a differential test asserting the indexed-mask path returns byte-identical results to the unindexed scan over a 2,000-query corpus (catches any unsoundness from an initials-derivation bug). Confirm with Instruments Time Profiler (type `a`, `ab`, `abc` repeatedly) that `extractWordsASCII` allocation count drops.

**Caveats from review**: Both skeptics confirmed the mechanism is exactly match-preserving but corrected the scale: "~1,500 apps" is an unsupported assumption (real count is low hundreds); for 1–2 char queries no typo/Damerau work exists to save, only allocations; the SystemCatalog half of the original proposal is redundant with an existing, stricter prefilter and uses an incompatible word-boundary definition. One skeptic identified a cheaper, equally-sound alternative (a single `initialMask` bit reusing the existing `characterMask` machinery) over the proposed `[UInt8:[Int32]]` posting list — adopted above. Also flagged: reordering the blocklist check (F4) below the mask guard is a smaller, zero-risk change that plausibly removes more per-candidate work than this prune by itself.

---

### F4 — Move the blocklist check after the cheap mask guard; stop taking a lock per candidate

**Where**: `Sources/FloodlightEngine/Utilities/BlocklistStore.swift:144-146` (`isBlocked`), `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:183` (call site, ahead of the mask guard at `:186`)

**Evidence**
```swift
package func isBlocked(name: String, id: String) -> Bool {
    state.withLock { $0.isBlocked(name: name, id: id) }
}
```

**Why it costs / what is missing**: `isBlocked` is called first in the loop, before the mask guard. `State.isBlocked` (`BlocklistStore.swift:72-82`) starts with `blockedIDs.contains(id)` with no `isEmpty` short-circuit — every candidate pays a lock acquire/release plus a string hash even with an empty blocklist. Worse: any user who has ever hidden one app (`SearchCoordinator.hide` always writes both a `.name` and `.id` rule, `SearchCoordinator.swift:392-393`) pays a per-candidate ICU `folding(options:locale:)` call (`BlocklistStore.swift:75-78`) forever after, doubled by the two `immediatePage` calls per execution (see F2).

**Proposal**: Two independent, cheap changes. (1) Swap the guard order in `ApplicationCatalog.immediatePage` — put `application.characterMask & queryCharacterMask == queryCharacterMask` (or the F1 `initialMask` guard) before `blocklistStore.isBlocked(...)`, since both are pure filters and order doesn't matter for correctness. (2) Add `isBlocked(normalizedName:id:)` taking the already-folded `application.normalizedName` (`ApplicationCatalog.swift:464`, `FuzzyMatcher.normalized` — byte-identical fold options to `BlocklistStore.swift:50-53`) so survivors skip re-folding. Do not build a `BlocklistSnapshot` value type — once (1) lands there are only a handful of calls per query and a snapshot buys nothing extra.

**Expected impact**: For the common empty-blocklist case, removes ~150–500 (post-F1) or ~300–600 (pre-F1) lock round-trips per keystroke — real but sub-microsecond-per-call, so tens of microseconds total. For any user with a `.name` rule, removes the per-candidate ICU fold — this is the case actually worth fixing (~1ms-class before the fix, on every keystroke, forever).

**Effort/Risk**: XS / Low. Five-line diff, no new types, no behavior change.

**How to verify on Mac**: Extend the F1/F18 fixture benchmark with a variant that installs `blocklistStore.block(name: "Fixture App 7")` plus 20 id rules and print both `app_immediate_page_us` and `app_immediate_page_blocklisted_us`; before the fix the second number should be visibly larger (ICU fold per app), after the fix they should be within noise. Keep `swift test --filter BlocklistStoreTests` green.

**Caveats from review**: Both skeptics agreed the mechanism is real but that "~1,500 hashes even when empty" overstates it — `Set.contains` on an empty set is cheap, and the guarded name-fold branch (`!normalizedBlockedNames.isEmpty`) is the actual cost center, not the id check. One skeptic noted the proposed `BlocklistSnapshot` type is unnecessary once the reorder lands — adopted (dropped from the proposal above). The "SearchCoordinator applies this a third time over merged candidates" sub-claim in the original finding was refuted: that filter runs over tens of already-paged items, not 1,500.

---

### F8 — The mask prefilter silently disables substitution-typo matching (correctness, not speed)

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:186`, `Sources/FloodlightEngine/Search/SystemCatalog.swift:353`

**Evidence**
```swift
guard application.characterMask & queryCharacterMask == queryCharacterMask else {
    continue
}
```

**Why it costs / what is missing**: The mask demands every alphanumeric query character exist somewhere in the candidate. That's unsound for the `typo` shape, whose entire purpose (`FuzzyMatcher.swift:190-223`, edit budget 1 for length 3-5 / 2 for 6+, `:265-271`) is to tolerate a character the candidate lacks. `chrone` (vs `chrome`) needs a `n` that "google chrome" doesn't contain, so it's rejected by the mask before `Self.score` ever runs — one of the five matcher shapes is effectively dead on both catalogs for substitution/insertion typos introducing a novel character. Deletions and transpositions still work; only typos introducing an absent character are lost, so "substitution typos never match" is too strong — restate as "typos introducing a novel alphanumeric character are dropped." SystemCatalog's identical gate matters less: its `requiresWordPrefix` gate (`SystemCatalog.swift:348-360`) already kills typo matching under 4 bytes for an unrelated reason, and its mask is built over name+keywords, which is rarely saturated enough to matter. This is effectively dead on `FuzzyMatcherStressTests` too, since the matcher's own typo tests all use deletion typos ("gogle", "safri", "chrme"), which pass the mask.

**Proposal**: Relax the mask to be sound for typo too: `(queryCharacterMask & ~application.characterMask).nonzeroBitCount <= editBudget(forQueryLength:)`. This is provably sound — edit distance k leaves at most k query characters unmatched. Requires promoting `FuzzyMatcher.editBudget` from `private` to `package`. Simpler alternative: skip the mask entirely when `editBudget(forQueryLength:) > 0` (i.e., query length ≥ 3) — candidate counts here are small enough (low hundreds) that the extra scan cost is negligible next to the correctness win.

**Expected impact**: Restores typo tolerance for one-character substitutions/insertions in application search — a launcher's single most visible fuzzy-match behavior — for queries ≥3 chars, at no measurable scan-cost increase. Medium impact (behavioral, not a benchmark number); this is a correctness fix mis-filed under "speed," and pairing it with F1's mask change (if F1's `initialMask` is adopted) requires re-deriving the relaxed check against `initialMask` too, or keeping this as a separate secondary filter.

**Effort/Risk**: S / Low-Medium. Risk is restoring previously-invisible matches into a 12-item page, which can shift what's visible — expect to touch `CatalogContractTests`.

**How to verify on Mac**: Add a case to `CatalogTests.swift` with an injected `discoveryProvider` containing "Google Chrome", "Notes", asserting `catalog.immediatePage(for: "chrone").items.first?.title == "Google Chrome"` and similarly for a 4+ char settings query (settings needs length ≥4 to bypass `requiresWordPrefix`). Confirm it fails on the current tree first: `swift test --filter CatalogTests`. Re-run `make test-performance` to confirm `fast_application_search_us` doesn't regress.

**Caveats from review**: Both skeptics confirmed the mechanism exactly but corrected: (1) the claim is overstated — only typos introducing a genuinely absent character are lost, not all substitutions; (2) the SystemCatalog impact is much smaller than claimed because of the pre-existing `requiresWordPrefix` gate; (3) `ApplicationCatalog.indexedItems` runs `Self.score` without the mask, so a typo could in principle survive there on the second (indexed) pass, though FFF's own fuzzy matching is unlikely to surface a substitution typo; (4) this is a correctness/UX finding, not a speed win — recategorize accordingly, as both skeptics did.

---

### F17 — SystemCatalog holds its lock across the entire scoring loop

**Where**: `Sources/FloodlightEngine/Search/SystemCatalog.swift:349-415`

**Evidence**
```swift
let matches = settings.withLock { allSettings -> [SearchItem] in
    var matches: [SearchItem] = []
    matches.reserveCapacity(min(limit * 2, 32))
    for setting in allSettings {
```

**Why it costs / what is missing**: The whole scoring loop — mask test, fuzzy match, subtitle string construction, `SearchItem` init — runs inside `OSAllocatedUnfairLock.withLock`, serializing against a concurrent `refreshIfNeeded` (`@concurrent`, `SystemCatalog.swift:261`). `ApplicationCatalog` does it correctly: `let currentApps = state.withLock { $0.applications }` (`ApplicationCatalog.swift:176`) copies the COW array reference out and scores unlocked. The loop only reads `allSettings`, so hoisting the copy is behavior-preserving.

**Proposal**:
```swift
let allSettings = settings.withLock { $0 }   // O(1) COW retain
// scoring loop runs unlocked, matching ApplicationCatalog.swift:176
```
Apply the same treatment to the writer side (`SystemCatalog.swift:288-298`), which currently builds `replacement` (a dedup Set + filter + three `map`/`==` array comparisons) inside the lock too — build it outside and take the lock only for the final compare-and-swap.

**Expected impact**: Low in absolute terms — the settings table is ~39 built-ins plus a handful of discovered prefPanes, mask-gated, so the critical section is microseconds either way, and refresh is throttled to once per 2s (`Catalog.swift:41`) and usually short-circuits on a fingerprint check before touching the lock at all. The real value is removing a rare priority-inversion tail and making the two catalogs structurally symmetric (which `CatalogContractTests` already asserts behaviorally).

**Effort/Risk**: S / Low. One-line hoist for the reader side; slightly more for the writer side.

**How to verify on Mac**: Add `testSettingsSearchUnderConcurrentRefreshBudget`: start a background `Task` looping `refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)` with an injected `discoveryProvider`, measure foreground `immediatePage` latency (11×500 samples), `print("FLOODLIGHT_BENCH settings_search_under_refresh_us=...")`, assert it stays within 3x of the quiet-state number. Run `make test-sanitizers` afterward since this touches locking shape.

**Caveats from review**: Both skeptics agreed the fix is correct and free but the impact is low, not the implied "stalls a keystroke" — discovery I/O already happens outside the lock (`SystemCatalog.swift:276-283`); only the small in-lock scoring/comparison work is at stake. One skeptic pointed out `OSAllocatedUnfairLock` does participate in priority-inversion avoidance despite the name "unfair" (fairness refers to wakeup ordering, not priority donation) — drop that part of the original rationale. The writer-side lock hold (building `replacement`) is arguably larger than the reader-side hold the finding targeted; fix both.

---

### F2 — SourceSearchEngine reruns the full app+settings immediate scan a second time per keystroke

**Where**: `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:244-245` (first pass), `:286-287` (second pass)

**Evidence**
```swift
// Both real catalogs can acquire their first snapshot in start(), and
// refresh may replace it again. Never carry the pre-start pages into
// an indexed or settled snapshot.
let currentAppPage = applications.immediatePage(for: query, limit: 12)
let currentSettingsPage = settings.immediatePage(for: query, limit: 24)
```

**Why it costs / what is missing**: `execute()` computes `appPage`/`settingsPage` at `:244-245`, then unconditionally recomputes both after a 15–20ms sleep and `ensureStarted()`/refresh calls, even in the steady state where neither catalog's readiness nor its `refreshIfNeeded` result changed. `warmUp()` in the same file already has the pattern needed to detect that: it captures `readinessBefore` and diffs against `refreshes.N.changed` (`SourceSearchEngine.swift:100-113`).

**Proposal**: Capture readiness before `ensureStarted()`; reuse phase-1 pages when nothing changed:
```swift
let appPageChanged = !wasApplicationsReady || refreshes.0.changed
let currentAppPage = appPageChanged ? applications.immediatePage(for: query, limit: 12) : appPage
```
Same for settings. **Correctness caveat both skeptics flagged as a real hole**: `changed == false` does not prove the catalog is unchanged — `refreshIfNeeded` can return `false` early via `refreshGuard.reserve` failing while a concurrent discovery mutates state anyway (`ApplicationCatalog.swift:89`, enqueued discovery runs on an uncancellable `DispatchQueue` continuation at `:249-253`). A correct implementation needs a monotonic snapshot-generation counter on each catalog compared before/after, not just the readiness+changed flags — bump it inside `state.withLock` in `ApplicationCatalog.swift:265-271` and `SystemCatalog.swift:288-298`, and reuse the pages only when the generation is unchanged.

**Expected impact**: Low, not high. The recompute sits after a deliberate 15-20ms `Task.sleep` (`:267`), before a multi-ms FFF indexed scan (`:290`) — it is not on the first-paint path, and the catalog's own budget is <1000µs/query. No existing benchmark reaches line 286 (the only one that touches it takes a snapshot and cancels before then). This is a correctness-hygiene item more than a latency win.

**Effort/Risk**: S / Low-Medium (medium if the generation-counter correctness fix is skipped — plain readiness+changed flags can go stale under the discovery race described above).

**How to verify on Mac**: Add `testSourceSearchSettledSnapshotCatalogCallCount` using `ScriptedCatalog`'s `recordedQueries` — assert one call when the scripted catalog reports no change, two when `refreshReportsChange` is set. Add a new `testSourceSearchSettledSnapshotBudget` (`source_settled_snapshot_ms`) but expect it to move by low single-digit milliseconds at most, since it's dwarfed by the sleep.

**Caveats from review**: Both skeptics independently downgraded this from the implied high impact to low, and one flagged a real correctness gap: the proposed readiness/changed flags can mask a stale-refresh race that today's unconditional rescan happens to absorb. One skeptic proposed a strictly better and cheaper alternative worth doing first regardless: move `blocklistStore.isBlocked` below the mask guard in `ApplicationCatalog.immediatePage` (see F4) — smaller diff, no staleness risk, comparable or larger saving.

---

### F3 — immediatePage materializes a full SearchItem for every match before top-K

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:179-207` (build), `:197` (best anchor — the `SearchItem` construction)

**Evidence**
```swift
var matches: [SearchItem] = []
matches.reserveCapacity(min(currentApps.count, 64))
for application in currentApps {
    ...
    matches.append(SearchItem(id: ..., title: ..., subtitle: ..., kind: .application,
                               action: .open(application.url), score: score + boost, fileURL: application.url))
}
return SearchItemRanking.page(matches, limit: limit)
```

**Why it costs / what is missing**: Every scored match becomes a full 11-field `SearchItem` (3 Strings + an enum carrying a URL + `fileURL`) before `SearchItemRanking.page` throws all but 12 away. But the claim of "~1,000+ constructions, 99% discarded" is wrong by an order of magnitude: `SearchItem` is built only after `Self.score` returns non-nil, i.e. only for genuine matches (tens-to-low-hundreds for a short query, not mask survivors). The "topRanked copies the array again" sub-claim is also false — Swift COW means the `count > limit` branch in `topRankedInPlace` (`Catalog.swift:104-134`) never mutates `matches`, so no second copy occurs; the heap walk is the only pass. The real per-candidate allocation is `extractWordsASCII` inside the matcher (see F9), not the `SearchItem` struct itself.

**Proposal**: Score into a bounded max-heap of `(score, index)` pairs sized to `limit`, materializing a `SearchItem` only when a candidate beats the current heap root — one construction per improvement, not per match. Comparator must reproduce `SearchItemRanking.ranksBefore`'s tie-break (`(score, name, id)`) exactly. Final ordering must still go through `SearchItemRanking.topRankedInPlace` — a local `heap.sort()` inside `ApplicationCatalog.swift` would trip `tools/ast-grep/rules/search-path-no-full-sort.yml`. Drop the SystemCatalog half of the original proposal — its candidate set (~44 curated panes) is too small for this to matter there; the one allocation worth removing in `SystemCatalog.immediatePage` is `id: "setting:\(setting.pane)"` at `SystemCatalog.swift:405`, a separate one-line fix.

**Expected impact**: Low-medium — tens of microseconds per keystroke (retain/release + array-growth memcpy of ~100-byte structs, not 1,000 heap allocations), against the existing 1,000µs budget. As a bonus, a score/index-pair heap also removes most `localizedStandardCompare` (ICU) tie-break calls (see F10), since ties are compared far less often on the smaller candidate set reaching the heap.

**Effort/Risk**: S (materialize-on-heap-admission variant, not the full precomputed-heap rewrite) / Low.

**How to verify on Mac**: Reuse the F1 fixture-catalog benchmark; additionally run under Instruments' Allocations template (or `MallocStackLogging=1` + `heap`) to count total allocations per query before/after. Guard correctness with a property test asserting the admission-heap path returns exactly `SearchItemRanking.topRanked(allScoredItems, limit:)` for randomized fixtures.

**Caveats from review**: Both skeptics refuted the headline magnitude (candidate count and "second array copy" claims) and pointed to `extractWordsASCII` (F9) as the actually larger allocation source in the same loop. Downgrade from the original "removes ~1,000 constructions" framing to "tens of microseconds, benchmark-visible only." The SystemCatalog half of the proposal was called near-worthless by both skeptics — dropped above.

---

### F9 — FuzzyMatcher re-extracts word boundaries and initials per candidate per keystroke

**Where**: `Sources/FloodlightEngine/Utilities/FuzzyMatcher.swift:108` (call site), `:312-333` (`extractWordsASCII`, no `reserveCapacity` unlike its Unicode twin at `:289-292`), `:174` (second allocation in `findAcronymASCII`)

**Evidence**
```swift
private static func extractWordsASCII(
    from bytes: [UInt8]
) -> [(offset: Int, bytes: ArraySlice<UInt8>)] {
    var words: [(offset: Int, bytes: ArraySlice<UInt8>)] = []
    var currentWordStart: Int?
    for (index, byte) in bytes.enumerated() {
```

**Why it costs / what is missing**: `matchASCII` calls this for every candidate that isn't an exact/prefix hit, on every keystroke, with no cache — word boundaries are a property of the candidate alone and never change. `findAcronymASCII` allocates a second array (`initials = words.compactMap(\.bytes.first)`) on top. The consumers are narrow: only `ApplicationCatalog` and `SystemCatalog` call `FuzzyMatcher` (files go through FFFKit, not this matcher), so the realistic candidate count is a few hundred app names (1-3 words each) after the F1 prefilter, not "~2,000 allocations."

**Proposal**: Cheapest first: add `words.reserveCapacity(4)` to `extractWordsASCII` (`FuzzyMatcher.swift:315`) matching its Unicode twin — removes most growth-reallocation cost in one line. If a new ASCII-scoring benchmark shows more is needed, make the word scan allocation-free using `withUnsafeTemporaryAllocation` (the file's own idiom at `FuzzyMatcher.swift:353`) writing offset/length pairs into a stack buffer instead of `[(offset:, bytes: ArraySlice<UInt8>)]`, removing both the array allocation and per-element ArraySlice ARC traffic. This needs no change to `ApplicationCatalog`/`SystemCatalog` and no cross-module cache.

**Expected impact**: Low. A few hundred short-string word scans is tens of microseconds against a 1,000µs immediatePage budget; not user-visible, benchmark-visible only after a new ASCII-specific test is added (the existing `testFuzzyMatcherScoringBudget` exercises the String path, not `scoreASCII`).

**Effort/Risk**: XS (reserveCapacity) to S (unsafe-buffer rewrite) / Low.

**How to verify on Mac**: Add a new `scoreASCII`-specific budget test (none exists today) before claiming any win — extend `SearchItemRankingPerformanceTests.swift` with `fuzzy_matcher_ascii_scoring_us`, then `fuzzy_matcher_ascii_scoring_reservecapacity_us`, compare. Guard with `FuzzyMatcherDifferentialTests` across the adversarial corpus.

**Caveats from review**: Both skeptics rejected the original `PrecomputedCandidate` cross-module-cache proposal as heavier than the problem — one estimated the saving at "tens of microseconds" and flagged a Periphery dead-code risk (`exclude_tests: true`) for a test-only allocating overload without a `// periphery:ignore`. Both suggested the `reserveCapacity` one-liner as the right first (and possibly only) step. The "~2,000 allocations per keystroke" estimate was refuted — files never reach this matcher; only apps and ~45 settings do.

---

### F7 — PathNavigator.resolve does synchronous directory listing on the main actor for relative path-shaped queries

**Where**: `Sources/FloodlightEngine/Search/PathNavigator.swift:159-166` (`findCaseInsensitiveMatch`), `:112-137` (`generateCandidatePaths`, the branch that reaches it), called from `Sources/Floodlight/Search/SearchResultProjection.swift:454`

**Evidence**
```swift
guard let contents = try? fileManager.contentsOfDirectory(atPath: parent.path)
else { return nil }
let lower = name.lowercased()
if let match = contents.first(where: { $0.lowercased() == lower }) {
    return parent.appendingPathComponent(match)
}
```

**Why it costs / what is missing**: For a *relative* path-shaped query (e.g. `docs/report` — one containing `/` but not starting with `~` or `/`), `generateCandidatePaths` calls this twice (once under `rootURL`, once under `homeURL`), each doing a full `readdir` plus a `lowercased()` allocation per entry until a match. Scope correction: `~/x` and `/x` queries return early (`PathNavigator.swift:94,109`) and cost only 1-2 `fileExists` stats — the listing only fires on the narrower relative-path branch, which also catches non-path queries that merely contain a slash ("12/25") and scan to completion finding nothing. This runs on `@MainActor` (`SearchCoordinator` is `@MainActor`), called 2-4 times per keystroke (once per projection pass — stale-while-revalidate plus up to three snapshots).

**Proposal**: Probe the literal path with `fileExists` first (macOS default APFS volumes are case-insensitive, so this succeeds in the common case) and only fall back to the directory listing on a miss. **Casing-safety caveat both skeptics flagged**: do not just use the literal-casing result — recover on-disk casing with one `resourceValues(forKeys: [.canonicalPathKey])` stat after the literal `fileExists` hit, or `PathNavigatorTests.swift:82-96` (which asserts `title == "Downloads/"` for a lowercase query) breaks and the item id (`"folder:\(url.path)"`) silently changes casing, disrupting dedup. Drop the proposed `volumeSupportsCaseSensitiveNamesKey` startup probe and mtime-keyed listing cache — `rootURL` mutates at runtime (`SearchCoordinator.changeRoot`) and root/home can be on different volumes, so "detect once at startup" is the wrong shape; the literal probe already degrades gracefully to the existing listing on a case-sensitive volume. For the 2-4x-per-keystroke repeat, resolve once in `scheduleSearch` for the new query and carry the `ResolvedPath?` through `LocalContext`, rather than adding a static cache inside the stateless `PathNavigator` enum.

**Expected impact**: Medium. Removes one or two full directory reads plus O(entries) allocations from the main thread for relative path-shaped queries, and cuts the per-keystroke repeat from up to 4x to 1x. Warm-cache local APFS cost is modest (~0.5-3ms/keystroke for tens of entries); the value is the tail — cold name cache, network volumes, or a `rootURL` pointed at a wide directory.

**Effort/Risk**: S (literal probe + casing recovery, drop the volume-detection and TTL-cache sub-parts) / Low-Medium (medium if the casing recovery is skipped).

**How to verify on Mac**: Add `Tests/FloodlightEngineTests/PathNavigatorPerformanceTests.swift`: temp root with 500 sibling directories, resolve `"deep-dir-250/child"`, 11×200 samples, `print("FLOODLIGHT_BENCH path_navigator_resolve_us=...")`. Count `contentsOfDirectory` calls via a FileManager subclass injected through the existing `fileManager:` parameter — assert 0 on the case-insensitive-hit path. Re-run `PathNavigatorTests.swift` (especially `caseInsensitiveTrailingSlashResolution`) to confirm casing is preserved. In Instruments (File Activity, main thread filter), confirm typing `~/Doc` produces no `getdirentries64` — note `~/Doc` itself takes the early-return branch, so use a relative query like `Doc` under a populated root to actually exercise the listing.

**Caveats from review**: Both skeptics narrowed the trigger condition (only the relative-path branch, not "any query containing `/`") and one caught a correctness bug in the literal-probe proposal as originally stated (breaks on-disk casing recovery, fails an existing test). Both agreed the ast-grep `query-path-no-sync-disk-read` rule's function-name matching (`immediatePage`/`indexedItems`) genuinely misses this helper — its own comment calls this gap "rung 2." Widening that rule was suggested but one skeptic noted the call site is in the shell target (`SearchResultProjection.swift`), outside the rule's `files:` glob, so only `PathNavigator` itself could ever be caught by it.

---

### F6 — projectClipboard builds a row for every returned entry (up to ~1,020), with a conditional stat per path-shaped row, on the main actor

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:196-213` (`projectClipboard`), `:299` (`FileManager.default.fileExists`)

**Evidence**
```swift
private static func projectClipboard(_ context: ClipboardContext) -> SearchResultPublication {
    let rows = context.entries.enumerated().map { index, entry in
        buildClipboardRow(entry: entry, index: index, now: context.now)
    }
```

**Why it costs / what is missing**: Local mode caps rows at `maxResultsLimit = 80` (`SearchResultProjection.swift:436,465`); clipboard mode has no cap. `publishClipboardModeResults` runs synchronously on `@MainActor` per keystroke with no debounce (`SearchCoordinator.swift:503-508`). Corrections to the original claim: `fileExists` (`:299`) only fires when `ClipboardInspector.parseLocalPath` matches a `/`, `~/`, or `file://`-prefixed single-line string (`ClipboardInspector.swift:236-250`) — not per row unconditionally. The dominant cost is actually string work: up to four whole-string `trimmingCharacters` passes per row (`parseLocalPath`, `parseURL`, `parseHexColor`, `parseCodeHint`) plus `previewTitle`'s split+join, over text up to `maxTextByteCount = 32,000` bytes, times up to ~1,020 entries (pinned + `inMemoryRecentWindowLimit = 1,000`). **Regression risk both skeptics flagged**: clipboard mode with an empty query is a *browse-the-whole-history* view, arrow-navigable in a scrollable `LazyVStack` — a hard 80-row cap silently truncates history browsing, unlike local mode where ranking already narrowed results before the cap.

**Proposal**, in order of value (per the value skeptic, who ranked these above the row-cap):
1. Debounce clipboard mode the way local mode is debounced — `SearchCoordinator.swift:502-507` currently short-circuits the debounce entirely, so the full cost lands on every character.
2. Truncate text once before classifying: `String(text.prefix(512))` at the top of `buildClipboardTextRow`, fed to `previewTitle`/`parseURL`/`parseHexColor`/`parseCodeHint` — removes the 32KB scans without changing displayed output.
3. Then page the row build — but as *paging for scroll*, not a hard 80-row truncation: filter `context.entries` by `entry.kind` first (chips at `:233-260` must agree with the visible list), build rows for the first N (e.g. 200), and grow on scroll/selection reaching the tail, preserving full history browsing.
Drop the "cache classification on `ClipboardEntry` at capture time" idea — `ClipboardEntry` lives in `FloodlightEngine`, `ClipboardInspector` in the shell; crossing that boundary is L-effort, not M. If memoization is wanted, key it by `entry.id` in a shell-side dictionary instead.

**Expected impact**: Medium. The megabyte-scale repeated string scanning across ~1,020 entries is the real headline, more than the stat syscalls. Debounce alone (step 1) cuts total work by the keystroke rate for free.

**Effort/Risk**: M / Medium — the naive 80-row cap is a UX regression (history-browsing truncation); the scroll-paged version is safer but more work.

**How to verify on Mac**: Add `Tests/FloodlightTests/SearchProjectionPerformanceTests.swift` `testClipboardProjectionBudget`: 1,000 `ClipboardEntry` fixtures, half path-shaped text, call `SearchResultProjection.project(.clipboard(...))`, 11×100 samples, `print("FLOODLIGHT_BENCH clipboard_projection_us=...")`. Also bound the store side — `search` still scans all ~1,000 entries for 1-2 char queries (see F5) regardless of projection capping. In Instruments, File Activity template while typing in clipboard mode; confirm `stat64` calls track only path-shaped entries, not row count.

**Caveats from review**: Both skeptics corrected the "up to 1,000 stat syscalls" and "thumbnail data copy" claims (COW retain, not a copy) and redirected the dominant-cost story to string scanning over up to 32KB text per entry. One skeptic explicitly refuted the hard-cap proposal as a silent browse-truncation regression and proposed debounce + text-prefix-truncation as strictly better, lower-risk first steps — adopted as the primary recommendation above.

---

### F5 — Clipboard short-query (<3 char) search does an uncapped locale-aware substring scan

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:353-361` (branch), `:406` (`matchesSearch`)

**Evidence**
```swift
if trimmed.utf8.count < 3 {
    let pinnedMatches = state.pinnedEntries.filter { Self.matchesSearch($0, query: trimmed) }
    let recentMatches = state.recentEntries.filter { Self.matchesSearch($0, query: trimmed) }
    return pinnedMatches + recentMatches
}
```

**Why it costs / what is missing**: The FTS5 index is trigram-tokenized, so 1-2 char queries fall back to `entry.text.localizedCaseInsensitiveContains(query)` over the in-memory window (up to `inMemoryRecentWindowLimit = 1,000` entries), and this branch ignores `searchResultLimit` entirely — unlike the FTS branch, which binds `LIMIT searchResultLimit` (200). Correction: text is hard-capped at `maxTextByteCount = 32,000` bytes at capture time (`ClipboardCaptureService.swift:280-281`, re-checked at `ClipboardHistoryStore.swift:285`), so "megabytes per entry" is wrong — worst case is 1,000×32KB, typical is far smaller. This also isn't unique to short queries: the empty-query branch (`:349-351`) returns `pinnedEntries + recentEntries` uncapped too, on every clipboard-mode open.

**Proposal**: Cap in place with minimal change: `state.recentEntries.lazy.filter { Self.matchesSearch($0, query: trimmed) }.prefix(Self.searchResultLimit - pinnedMatches.count)` — for 1-2 char queries almost everything matches, so this stops early instead of scanning to completion, and bounds the downstream row build immediately. If per-entry scan cost still needs bounding, `entry.text.prefix(2_000).localizedCaseInsensitiveContains(query)` costs nothing extra (Substring is a view) and preserves current locale semantics — prefer this over the originally-proposed `.diacriticInsensitive`-folded cached key, which silently changes match behavior. Apply the same `prefix(searchResultLimit)` cap to the empty-query branch (`:349-351`) and the FTS-failure fallback (`:387-393`), which share the identical uncapped problem.

**Expected impact**: Low-medium. Realistic history (hundreds of entries, mostly well under 1KB) is a sub-millisecond scan already; the value is capping the *result count* consistently across all three code paths (today typing a 3rd character silently shrinks 1,000 results to 200), not raw scan speed.

**Effort/Risk**: S (cap only) / Low. The originally-proposed folded-cached-key approach is M effort and higher risk (behavior change, `ClipboardEntry` equality/hashing implications) — skip it unless a benchmark shows the scan itself matters after capping.

**How to verify on Mac**: `testClipboardHistoryShortQuerySearchBudget`: seed 1,000 entries (50 with 32KB text bodies — the real worst case), query `["a","in","e"]`, `print("FLOODLIGHT_BENCH clipboard_short_query_search_us=...")`, assert `results.count <= ClipboardHistoryStore.searchResultLimit` after the cap lands. Run `make test-performance`.

**Caveats from review**: Both skeptics refuted the "megabytes / hundreds of KB per entry" sizing — the 32,000-byte cap is enforced at capture time. Both preferred a minimal `prefix()`-based cap over the proposed folded-and-cached search key, citing behavior-change risk (locale semantics) and unnecessary complexity for a sub-millisecond realistic cost. Both noted the empty-query and FTS-fallback branches have the identical uncapped defect and should be fixed together.

---

### F10 — ranksBefore falls to localizedStandardCompare on every score tie; content rows all share one score

**Where**: `Sources/FloodlightEngine/Search/Catalog.swift:78-84`, tie source at `Sources/FloodlightEngine/Search/FFFIndex.swift:641` (formerly cited as 634)

**Evidence**
```swift
package static func ranksBefore(_ lhs: SearchItem, _ rhs: SearchItem) -> Bool {
    guard lhs.score == rhs.score else { return lhs.score > rhs.score }
    let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
    return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
}
```

**Why it costs / what is missing**: `localizedStandardCompare` bridges to NSString and does a locale/numeric-aware ICU comparison. Content rows all get the literal score `SearchItemRanking.content` (1,000) with no per-row decrement, so every content-search cluster (up to 16 rows) ties and hits ICU on every internal comparison. The candidate set the shell sorts is hard-bounded at ~76-79 items (12+12+24+12+16, per `SourceSearchEngine.swift` limits), so `Catalog.swift`'s heap-vs-sort branch always takes the full `items.sort(by: ranksBefore)` path — but at that size the total cost is ~450 comparisons, of which only ~50-150 hit ICU. Against a pipeline that already sleeps 15+20+30ms deliberately, this is order 0.05-0.3ms — low impact, not the "hundreds of ICU comparisons" framing implied.

**Proposal**: Ship only step 1: give content rows a decreasing score (`SearchItemRanking.content - index`), mirroring the existing precedent in `SearchResultProjection.swift:307` for clipboard rows. This stays within the content score band (985...1000, far below `setting` = 50,000) so no ranking-band invariant breaks, and removes the largest tie cluster for near-zero cost. **Drop step 2** (a stored ASCII collation key on `SearchItem`) — both skeptics rejected it: `SearchItem` is a `Hashable` struct copied through every snapshot/publication; a stored `[UInt8]` key adds allocation and ARC traffic per copy for hundreds of items per keystroke to save ~100 comparisons, and risks breaking the strict-weak-ordering invariant `ranksBeforeIsTransitive` asserts. If the settings score collision (`SystemCatalog.swift:410`, `SearchItemRanking.setting + evidence.score`) still causes ties after step 1, de-tie there too with a per-row decrement — same pattern, same cost.

**Expected impact**: Low. Benchmark-visible only, and note the existing benchmark (`SearchItemRankingPerformanceTests.swift:130`, `score: (index*17)%2048`) never exercises the tie-break path at all since 17 is odd and every score is distinct — a new fixture with a realistic tie profile is needed before any number can be claimed.

**Effort/Risk**: S (step 1 only) / Low. Note this changes content-row *ordering* visibly (relevance order instead of alphabetical) — a real behavior change worth calling out to the maintainer, not just a perf tweak.

**How to verify on Mac**: Add a `makeCandidates`-style fixture with 79 items, 16 sharing one score, and a `FLOODLIGHT_BENCH top_ranked_tied_selection_us` test comparing before/after step 1. Extend `SearchModelInvariantTests.ranksBeforeIsTransitive`/`Asymmetric` coverage if any score-band change is made.

**Caveats from review**: Both skeptics independently downgraded impact from the original framing to low and both rejected the collation-key structural fix as disproportionate machinery for the value; both endorsed the one-line content-score-decrement as the only piece worth shipping. One skeptic noted the existing ranking benchmark cannot see this defect at all (distinct scores by construction) — a new fixture is a prerequisite to claiming any win.

---

### Lower-priority / keep-as-tidiness items (F12, F13, F14, F16)

These four were rated **plausible** (split skeptic verdicts) or confirmed-but-refuted-on-value; keep only their trivial sub-parts, do not invest further:

- **F12** (query normalized/masked 4-5x per keystroke by each catalog): mechanism confirmed, but both skeptics independently estimated the saving at single-digit microseconds — five short-string ICU foldings against four full catalog scans. The proposed `NormalizedQuery` protocol carrier is M-effort for a benchmark-invisible win. **Keep only**: hoist the duplicated four-line preamble into one `FuzzyMatcher.normalizedQueryKey(_:)` helper called by all three sites (S effort, no protocol change), which also deduplicates the byte-identical `characterMask` implementations in `ApplicationCatalog.swift:435-449` and `SystemCatalog.swift:437-449`. **Better use of the same effort** (per the value skeptic): eliminate the redundant second `immediatePage` pass at `SourceSearchEngine.swift:286-287` (F2) instead — roughly 100x the saving at comparable effort.

- **F13** (shell re-runs blocklist filter over already-filtered candidates): value skeptic refuted outright — candidate set is ~40-80 items, cost is ~1 microsecond, and the proposed API split (`reproject(from:)`) adds surface area for no measurable gain. **Keep only** if touching this code anyway: delete the manual re-filter in `excludeFromSearch` (`SearchCoordinator.swift:394-397`, redundant with the filter `projectLocal` already applies) and pass `publication.sourceCandidates` straight through. Do not remove the filter from the stale-while-revalidate or `selectFilter` re-projection sites — the blocklist can be mutated from `OnboardingSession.swift:119-128` between projections, so removing it there would delay a newly-blocked app's disappearance.

- **F14** (calculator/keyword/path rows rebuilt on each of 2-4 projections): value skeptic refuted the memoization-cache proposal — most of the claimed cost (`Calculator.evaluate`, `PathNavigator.resolve`) already short-circuits before doing real work unless the query actually looks like an expression or a path; the `SyntheticRows` cache would need a generation counter on a mutable `keywordRegistry` with no identity to key on. **Keep only** two one-line hoists, both strictly dominant: `Calculator.format`'s per-call `NumberFormatter` → `private static let` (`Calculator.swift:21`); `KeywordEngine.host` → computed once in `init` and stored (`KeywordEngine.swift:83`) instead of re-parsed on every access including `webModeResults`/`searchSubtitle`. The path-navigator disk-I/O half is fully subsumed by F7.

- **F16** (exact-path dedupe recomputes `standardizedFileURL` in the loop): value skeptic refuted the array size assumption (production limit is 12, not 60 — `SourceSearchEngine.swift:290`) and the "two stat syscalls" sub-claim (Swift's `if let` short-circuits; the double-call scenario is unreachable in the way described). **Keep only** the one-line hoist: `exactItem.url` is already standardized (`FFFIndex.swift:531,569`), so compare `$0.url.standardizedFileURL == exactItem.url` directly, dropping the redundant second `.standardizedFileURL` call — not worth a dedicated benchmark.

---

### Testing-gate findings (F18, F19, F20)

**F18 — App-search benchmark measures the runner's real catalog, not a representative fixture**
`Tests/FloodlightEngineTests/SearchPerformanceTests.swift:18-20` constructs `ApplicationCatalog` with no `discoveryProvider`, so `fast_application_search_us` reflects whatever `.app` bundles exist on the CI runner (or developer Mac) — not comparable run-to-run, and it never exercises `RecentStore.boostMap` (empty isolated `UserDefaults`, short-circuits at `RecentStore.swift:50-51`) or `BlocklistStore`'s ICU-folding path (default `UserDefaults.standard`, which is itself machine-dependent rather than guaranteed-empty). **Fix**: inject a synthetic ~300-500-app `discoveryProvider` (matching the corrected realistic count, not 1,500) with multi-word/mixed-case/diacritic names via the existing `deferDiscovery:`/`discoveryProvider:` init parameters (already used deterministically elsewhere, e.g. `CatalogTests.swift:261-262`); seed `RecentStore` by writing its encoded payload directly into an isolated `UserDefaults` suite before construction (not via `record()`, which is async); pass an explicit isolated `BlocklistStore` with 5 name rules + 20 id rules. Use a temp `supportURL:` — `prepare()` calls `synchronizeMarkers` which writes one marker file per app under the real Application Support directory if `supportURL` is left `nil`, and a 500-app synthetic provider would litter/wipe the developer's real index. Split the pathological single-char query into its own bound rather than averaging with `"terminal"`. Effort S, Risk Low.

**F19 — No budgeted test covers the shell-side projection (main-actor work between keystroke and repaint)**
Every `FLOODLIGHT_BENCH` line today comes from `Tests/FloodlightEngineTests`; nothing in `Tests/FloodlightTests` has a `*PerformanceTests` type. Correction from review: the two heaviest CPU components inside `projectLocal` are *already* budgeted elsewhere — `SearchItemRanking.topRankedInPlace` (`SearchItemRankingPerformanceTests.swift:20-60`) and `SearchFilterCounts` (`SearchPerformanceTests.swift:68,115`) — and the blocklist re-filter actually lives in `SearchCoordinator.swift:596`, not in `SearchResultProjection` itself, so a test targeting `SearchResultProjection.project` alone won't cover it. **Fix**: add `Tests/FloodlightTests/SearchProjectionPerformanceTests.swift` with `testLocalProjectionBudget` (80 candidates, plain query), `testLocalProjectionPathQueryBudget` (path-shaped query against a temp root, to pin F7's behavior), `testClipboardProjectionBudget` (1,000 entries, per F6/F20) — and separately, since `Tests/FloodlightTests` is 100% swift-testing while the engine's perf suites are XCTest, either drive `SearchCoordinator.projectLocal` directly (it's `@MainActor`) for full blocklist coverage, or explicitly scope the test to exclude that filter. Hoist the duplicated `measureCPU`/`median`/`processCPUTime` helpers into `FloodlightTestSupport` while here. Effort M, Risk Low.

**F20 — No budget/cap on clipboard capture-to-row latency at realistic sizes**
The one clipboard budget (`ClipboardHistoryPerformanceTests.swift:34-78`) averages 8 queries into a single 2ms bound, diluting the two pathological cases (empty query, sub-trigram query) with six cheap FTS hits; fixtures are all short single-line text with no image payload, so the SQLite thumbnail-blob read path is never exercised, and the store is `inMemory()` so the real WAL/prepare-per-call SQLite path is never timed. **Fix**: split into `testClipboardSearchEmptyQueryBudget`, `testClipboardShortQuerySearchBudget` (50 large-text entries, pairs with F5), `testClipboardFTSQueryBudget`, and a file-backed variant with a temp `databaseURL`. Assert result-count caps alongside timing once F5/F6's caps land. The statement-caching sub-proposal (avoid `sqlite3_prepare_v2`/`finalize` per call) is a smaller win than framed — the in-memory FTS queries already run comfortably under 2ms, so the untimed cost is disk/WAL I/O, not SQL compilation. Effort M, Risk Low.

### Rejected ideas

- **F15** — FFF result marshalling allocates a split array + lowercased String per path component to reject `.app` bundles: refuted. The reject already runs before URL/result construction at every site (not after, as claimed); the application-search hot path (`ApplicationCatalog.swift:133 → searchFiles`) scans a *flat* marker directory where `relativePath` is a single component, so the claimed `lowercased()` call never even fires there; and the proposed shared byte-scan helper would change semantics at `FFFIndex.swift:280`, which deliberately omits `dropLast()` to exclude bundle directories from `searchDirectories` — a shared helper would silently regress that and ship untested (no test covers the negative case).

- **F11** (was ranked but effectively refuted on value) — RecentStore.boostMap rebuild per immediate pass: the value skeptic showed the shipped benchmark's isolated `UserDefaults` makes `boostMap` provably free today (empty dict, early `guard !dict.isEmpty` return), and in production the map is sized to launched-*applications* only (tens of entries, not the full history) — single-digit-microsecond cost, invisible to any existing or proposed budget. Do not build the proposed 60-second-staleness cache. The one surviving sub-part — hoist `let boosts = recentStore.boostMap()` once above `ApplicationCatalog.indexedItems`'s compactMap instead of calling `boost(for:)` per indexed hit (`ApplicationCatalog.swift:158`) — is folded into the F1 write-up as a one-line aside, not a standalone finding.

## Search speed: allocation and data layout

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F21 | Blocklist check runs before the cheap mask gate, plus a lock per candidate | Low | S | Low | Confirmed |
| 2 | F30 | Settings catalog rebuilds a constant id String per matched setting | Low | S | Low | Confirmed |
| 3 | F25 | `.app` bundle filter split+lowercases every FFF path component, duplicated 5x | Low | S | Low-Med | Confirmed |
| 4 | F22 | FuzzyMatcher allocates word/acronym arrays per non-exact candidate | Low-Med | S (partial) / M (full) | Low / Med | Confirmed |
| 5 | F23 | Clipboard rows re-parse full text 5x per row per keystroke | Medium | S (partial) / M (full) | Low / Med | Confirmed |
| 6 | F24 | `visibleRows` copies the row array even under the `.all` filter | Negligible | S | Low | Plausible (both skeptics: low/unmeasurable, one refuted the memory claim) |
| 7 | F32 | `buildLocalRows` re-dedups an already-deduped candidate list | Negligible | S (reserveCapacity only) | Low | Plausible (dedup-removal half refuted — it's load-bearing) |
| 8 | F33 | Calculator gate/normalize does several string walks per projection | Negligible | S (partial only) | Low | Plausible (full rewrite refuted — breaks Unicode-digit handling) |
| 9 | F27 | tabCompletionHint re-parses query per row per render | Negligible | — | — | Plausible → refuted by value lens; verify-then-drop |
| 10 | F28 | SearchItem equality walks full clipboard payload | Negligible | — | — | Plausible → refuted by value lens; do not implement as proposed |

Three findings from the same pass were dropped outright — see **Rejected ideas**.

### F21 — Blocklist check runs before the cheap mask gate, plus a lock per candidate

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:182-188`, `Sources/FloodlightEngine/Utilities/BlocklistStore.swift:72-146`, and (per review) `Sources/Floodlight/Search/SearchCoordinator.swift:596`

**Evidence**:
```swift
for application in currentApps {
    if blocklistStore.isBlocked(name: application.name, id: application.id) {
        continue
    }
    guard application.characterMask & queryCharacterMask == queryCharacterMask else {
        continue
    }
```
```swift
package func isBlocked(name: String, id: String) -> Bool {
    state.withLock { $0.isBlocked(name: name, id: id) }
}
```

**Why it costs / what is missing**: The blocklist test runs on every application in `currentApps` before the two-instruction `characterMask` gate that rejects most candidates — the expensive check does the cheap check's job. Each `isBlocked` call takes an `OSAllocatedUnfairLock` and, for the common empty-blocklist case, still does `blockedIDs.contains(id)` on `id = "application:\(url.path)"`. The name half is already short-circuited (`BlocklistStore.swift:74` guards `!normalizedBlockedNames.isEmpty`), so only the lock + one `Set<String>.contains` remain per candidate. `SystemCatalog.swift:353` already puts the mask gate first — this is the one place that doesn't follow that convention. Separately, `SearchCoordinator.swift:596` filters the *entire* candidate list through `blocklistStore.isBlocked` on every publication, on the UI path, and was not in the original finding.

**Proposal**: Move the `characterMask` guard to the top of the loop body at `ApplicationCatalog.swift:186-188`, ahead of the blocklist call — a one-line reorder, zero new API. Add `package var isActive: Bool { state.withLock { !$0.blockedIDs.isEmpty || !$0.normalizedBlockedNames.isEmpty } }` to `BlocklistStore`, hoist `let blocklistActive = blocklistStore.isActive` above the loop, and guard the call with `if blocklistActive && blocklistStore.isBlocked(...)` — one lock acquisition per `immediatePage` instead of one per candidate. Apply the same `isActive` hoist at `SearchCoordinator.swift:596`, which is at least as valuable as the catalog site. Skip the originally proposed `Sendable` `snapshot()` type — more API surface than the win justifies, and skip touching `indexedItems` (`ApplicationCatalog.swift:138-144`) — it only walks the ~24 FFF results, already cheap.

**Expected impact**: Low. Removes a lock+hash per candidate on a catalog of a few hundred apps (not the ~1,500 the original estimate assumed — that number came from a test fixture constant, `SearchItemRankingPerformanceTests.swift:24`). Tens of microseconds off an actor-isolated call, not the main thread.

**Effort/Risk**: S / Low.

**How to verify on Mac**:
```bash
swift test -c release --filter ApplicationCatalog 2>&1 | grep FLOODLIGHT_BENCH
```
Add a variant with 0 vs. 5 blocklist rules on a realistic (not 1,500-app) fixture; medians should converge after the fix. Instruments → Time Profiler, invert the call tree while typing 6 characters, confirm `BlocklistStore.isBlocked`/`Set.contains` leave the top of the profile. Keep an existing/added test that a blocked app is absent from `immediatePage`.

**Caveats from review**: Both skeptics confirmed the mechanism but downgraded impact from the original "high" to "low": the real catalog is a few hundred apps, not 1,500; the name-check half was already guarded; whether an empty `Set` skips hashing entirely is an unverified stdlib detail (see research prompt); `indexedItems` scope was wrong in the original finding (bounded at ~24, not the full catalog). The value-lens skeptic identified the bigger, unlisted site at `SearchCoordinator.swift:596` and argued the simpler one-line reorder is the load-bearing half of the fix, with the `snapshot()`/`isActive` type being the smaller, optional half.

---

### F30 — Settings catalog rebuilds a constant id String per matched setting

**Where**: `Sources/FloodlightEngine/Search/SystemCatalog.swift:349-416`

**Evidence**:
```swift
matches.append(SearchItem(
    id: "setting:\(setting.pane)",
    title: setting.name,
    subtitle: subtitle,
```

**Why it costs / what is missing**: `pane` is an immutable stored field of `Setting`; `"setting:\(setting.pane)"` is a constant for that setting's lifetime but gets rebuilt via string interpolation on every match, every keystroke. `url` is already precomputed and stored on `Setting` at init (`SystemCatalog.swift:39`) — the id was simply missed.

**Proposal**: Add `id` as a stored property on `Setting`, computed once at init beside `url`, and reference it directly at line 405.

**Expected impact**: Low. ~40 built-in settings plus discovered panes, so this is on the order of a few dozen small-string allocations removed per keystroke (settings `immediatePage` runs twice per search execution — `SourceSearchEngine.swift:245,287` — not the four times the original finding claimed).

**Effort/Risk**: S / Low. The id format is already pinned by `Tests/FloodlightEngineTests/CatalogTests.swift:488,500`.

**How to verify on Mac**:
```bash
swift test -c release --filter SystemCatalog 2>&1 | grep FLOODLIGHT_BENCH
swift test --filter CatalogTests
```
Confirm the `settings_search_us` bench line in `SearchPerformanceTests.swift:100-124` (budget: `XCTAssertLessThan(settingsMicroseconds, 1_000)`) doesn't regress and ideally ticks down slightly.

**Caveats from review**: Original finding bundled three separate changes; both skeptics kept only this one (id hoist) as worth doing. Rejected sub-proposals: (a) replacing `words: [String]` with byte ranges — `setting.words[wordIndex]` is still read as a String at `SystemCatalog.swift:392` for acronym subtitles, so the array can't be fully removed; words are also short enough to be small-string-optimized already, so grapheme-level `hasPrefix` is not the claimed cost. (b) Snapshotting the settings array outside the lock to "unblock" a filesystem-walking refresh — factually backwards: `refreshIfNeeded`'s filesystem walk happens *outside* the lock (`SystemCatalog.swift:276-287`); the lock is held only for the array swap, and that swap's own critical section (three `map` calls + a `Set` build, lines 288-298) is longer than the query's scoring loop. There is no contention to relieve. Also: "×4 passes" in the original finding should read "×2" per search execution.

---

### F25 — `.app` bundle filter split+lowercases every FFF path component, duplicated 5x

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:151-153, 223-225, 271-272, 389-391, 556-558`

**Evidence**:
```swift
let components = relativePath.split(separator: "/")
if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
    return nil
}
```

**Why it costs / what is missing**: The same predicate is duplicated five times (not four — `search`, `searchFiles`, `searchDirectories`, `searchContent`, `exactPathItem`), each allocating a Substring array plus a fresh lowercased String per path component, purely to answer a yes/no question, before any result is otherwise filtered. Runs entirely on the FFF background queue (`dev.vmg.fff-swift`, `FFFIndex.swift:7`), never the main thread. Production call volume is smaller than the original finding assumed: `search` is called with `limit: 12` (`SourceSearchEngine.swift:290`), `searchFiles` with `limit: max(limit*2, limit)` ≈ 24 (`ApplicationCatalog.swift:133`), `searchContent` defaults to `limit: 16` and only runs conditionally (query ≥ 3 UTF-8 bytes, fewer than 12 indexed hits, after a 30ms delay). `searchDirectories` has no production caller at all — test-only.

**Proposal**: Add one shared `static func isInsideApplicationBundle(_ relativePath: String) -> Bool` that scans `relativePath.utf8` for the ASCII-case-insensitive byte sequence `.app/`, no splitting, no allocation. Use it at the four `dropLast()` sites. Keep `searchDirectories` (`FFFIndex.swift:271`) as a *separate* predicate — it deliberately omits `dropLast()` to also reject a directory that is itself a `.app` bundle; a `.app/`-substring scan is not equivalent there and would silently let `Foo.app` itself through as a folder result. Add a parity test before consolidating (none exists today: no test in `FFFIndexTests.swift` asserts `.app` filtering).

**Expected impact**: Low. Roughly 50 candidate paths per keystroke (not ~180), so the saving is a few dozen small allocations, not several hundred. It's a background-queue cost sitting right after a native fuzzy search over the whole home index with a 35–100ms time budget — a rounding error next to that.

**Effort/Risk**: S / Low-Medium (medium only if the two variants get collapsed into one without the parity test).

**How to verify on Mac**:
```bash
swift test --filter FFFIndexTests
```
Add a fixture with `Foo.app/Contents/MacOS/Foo` (interior file — should be filtered by `search`/`searchFiles`/`searchContent`) and a bare `Bar.app` directory (should be filtered only by `searchDirectories`'s stricter variant, if that code path is ever given a production caller). Instruments → Allocations filtered to the FFF queue during typing, before/after.

**Caveats from review**: Both skeptics confirmed the code but corrected the site count (5, not 4) and the volume estimate (~50/keystroke, not ~180, since `searchDirectories` has no caller and the other three limits are 12/24/16, not 60 each). The accuracy skeptic flagged that Swift's `lowercased()` has an ASCII fast path and short path components are small-string-optimized, so "grapheme-aware lowercasing" overstates the cost. The value skeptic flagged a real, separate, larger issue found in passing: `exactPathItem` (`FFFIndex.swift:545-560`) does synchronous `FileManager.fileExists`/`attributesOfItem` on the query path and is not caught by the `query-path-no-sync-disk-read` ast-grep rule (scoped only to functions literally named `immediatePage`/`indexedItems`) — worth a follow-up finding, not part of this one's scope.

---

### F22 — FuzzyMatcher allocates word/acronym arrays per non-exact candidate

**Where**: `Sources/FloodlightEngine/Utilities/FuzzyMatcher.swift:169-174, 312-333`

**Evidence**:
```swift
private static func extractWordsASCII(
    from bytes: [UInt8]
) -> [(offset: Int, bytes: ArraySlice<UInt8>)] {
    var words: [(offset: Int, bytes: ArraySlice<UInt8>)] = []
    var currentWordStart: Int?
```
```swift
guard words.count > 1 else { return nil }
let initials = words.compactMap(\.bytes.first)
```

**Why it costs / what is missing**: `extractWordsASCII` builds its array with no `reserveCapacity`, while the Unicode twin at line 292 reserves 4 — an inconsistency, not a design choice. `findAcronymASCII`'s `initials` array is guarded by `words.count > 1`, so single-word app names (a large share of a real catalog: "Safari," "Xcode," "Ghostty") never pay that second allocation — the original finding's "two arrays per candidate" is really "one array always, a second only for multi-word names." Both run for every candidate past the exact/prefix early-outs in `matchASCII` (`:90-113`), reached from `ApplicationCatalog.immediatePage` and `SystemCatalog.immediatePage`, twice per search execution.

**Proposal**: Two-step. (1) Now: add `words.reserveCapacity(4)` at line 315 to match the Unicode path, and delete `initials` — index `words[i].bytes.first` directly in the acronym comparison loop instead of building a separate array. This is provably equivalent (every word from `extractWordsASCII` is non-empty by construction, so `.first` never returns nil and no index shifts). (2) Later, only behind a new ASCII-path budgeted test (none exists — the only matcher benchmark, `SearchItemRankingPerformanceTests.swift:122`, exercises the String path): consider a stack-allocated range buffer via `withUnsafeTemporaryAllocation` and hoisting word-boundary computation onto `Application`/`Setting` at catalog-build time. Do not cap word count at 24 as originally proposed — that silently drops a wordPrefix match past word 24 and must be mirrored in the Unicode path or `FuzzyMatcherDifferentialTests` breaks.

**Expected impact**: Low-Medium. One allocation per candidate always, a second for multi-word names, on a catalog of a few hundred apps (not 1,500) — a real but small win, mostly valuable as the free `reserveCapacity` + `initials`-removal step (step 1), which is unambiguous and cheap.

**Effort/Risk**: S for step 1 (reserveCapacity + drop `initials`), Low risk. M and Medium risk for step 2 (stack buffer + catalog-side caching) — deferred.

**How to verify on Mac**:
```bash
swift test -c release --filter testFuzzyMatcherScoringBudget 2>&1 | grep FLOODLIGHT_BENCH
```
Add a fixture of multi-word non-prefix candidates ("Login Items & Extensions," "Activity Monitor") with acronym queries ("lie," "am") — the path that actually allocates. Instruments → Allocations with "Record reference counts," filter to 32–64 B mallocs during typing.

**Caveats from review**: Both skeptics agreed the code is accurate but the "two arrays always" framing is wrong (one, sometimes two) and the 1,500-app / 2,000-3,000-allocation figures are unsupported by anything in the repo. Both independently proposed the same narrower fix (reserveCapacity + drop `initials`) as the S-effort, low-risk piece worth doing now, while downgrading the stack-buffer/catalog-caching rewrite to a separate, larger, riskier follow-up that needs its own budgeted test first per the README rule.

---

### F23 — Clipboard rows re-parse full text 5x per row per keystroke

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:277-324, 396-401`

**Evidence**:
```swift
private static func previewTitle(for text: String) -> String {
    let singleLine = text.split(whereSeparator: \.isNewline)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    return singleLine.isEmpty ? "(Empty text)" : singleLine
}
```

**Why it costs / what is missing**: `buildClipboardTextRow` calls `previewTitle` plus four `ClipboardInspector.parse*` functions on the same full `entry.text` (up to `ClipboardHistoryStore.maxTextByteCount` = 32,000 bytes), each opening with its own `trimmingCharacters` call. `previewTitle`'s grapheme-level `split`+`joined` is the genuinely O(n) cost (`trimmingCharacters` itself only scans leading/trailing whitespace runs, not the whole string — the original finding overstated this as "five full-length copies"). `parseCodeHint` runs up to seven `contains(...)` scans and, for `{...}`/`[...]` blobs, `JSONSerialization` over the whole text. This is on `SearchCoordinator`'s `@MainActor`, synchronous, no debounce (`scheduleSearch` → `publishClipboardModeResults()`, `SearchCoordinator.swift:502-507`). Row count is capped at 200 for queries ≥3 UTF-8 bytes (`ClipboardHistoryStore.searchResultLimit`) but *uncapped* (up to `inMemoryRecentWindowLimit` = 1,000) for 1–2 character queries or an empty query — so the worst case is entering/exiting clipboard mode or backspacing to empty, not steady typing. A larger, unrelated cost on the same path: `SearchResultProjection.swift:297` does a synchronous `FileManager.default.fileExists(atPath:)` stat per path-like row per keystroke, uncaught by the `query-path-no-sync-disk-read` ast-grep rule (scoped to `Sources/FloodlightEngine/**`, not the shell target).

**Proposal**: (a) Long-term: compute a bounded `previewText` and a `contentHint` enum once at capture time in `ClipboardCaptureService`, persisted by `ClipboardHistorySQLite` — entries are immutable, so this moves the cost from "once per keystroke per row" to "once per copy." (b) Now: trim once in `buildClipboardTextRow`, add a single `ClipboardInspector.classify(trimmed:) -> ContentHint` that makes one pass and returns path/url/color/code/plain, replacing the four independent parsers. Cap `previewTitle`'s *output* length (~200 chars) rather than pre-truncating the *input* — truncating input breaks `parseCodeHint`'s `hasSuffix("}")`/`hasSuffix(">")` gates and `parseLocalPath`'s `!contains("\n")` guard, and contradicts an existing test asserting multi-line clipboard previews join all lines (`SearchResultProjectionClipboardTests.swift:43`). Separately, cache or drop the `fileExists` stat at line 297/299 — flagged by both skeptics as a likely-larger cost than the string parsing.

**Expected impact**: Medium. Real for histories of multi-KB code/text snippets during the 1–2 char / empty-query window (up to ~1,000 rows); negligible for typical short clipboard entries (the repo's own bench fixture uses ~70-byte entries). The `fileExists` stat is a wildcard — on a network or ejected volume it costs milliseconds per row, dwarfing the string work.

**Effort/Risk**: S for the output-cap + `fileExists` fix; M for the full `classify()` consolidation or the capture-time schema migration. Risk Low for (b)'s safe half, Medium if visible titles or icon classification change.

**How to verify on Mac**:
```bash
swift test --filter SearchResultProjectionClipboardTests
```
Add `ClipboardProjectionPerformanceTests`: seed 500 entries of 4KB code-snippet text, benchmark row-building, print `FLOODLIGHT_BENCH clipboard_rows_us=… entries=500 avg_bytes=4096`. In the app: open clipboard mode with a large history, Instruments → Time Profiler, type five characters at the 1–2 char boundary (largest row count), check whether `String.split`/`trimmingCharacters` or `FileManager.fileExists` dominates the stack.

**Caveats from review**: Both skeptics kept this confirmed but corrected the cost model (trimming is not full-length; the dominant O(n) costs are the grapheme split and `parseCodeHint`'s scans) and the row-count bound (200 capped for real searches, up to 1,000 uncapped only for very short/empty queries). Both independently found and flagged the `FileManager.fileExists` synchronous stat at line 297/299 as a materially larger, unaddressed cost on the same path that escapes the sync-disk-read ast-grep gate because that rule only matches engine-target functions named `immediatePage`/`indexedItems`. The value-lens skeptic explicitly rejected proposal (b)'s original "truncate input" framing as a correctness regression against an existing test.

---

### F24 — `visibleRows` copies the row array even under the `.all` filter

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:162, 203`

**Evidence**:
```swift
let visibleRows = allRows.filter(selectedFilter.includes)
```

**Why it costs / what is missing**: `.all` is the default filter and `includes` returns `true` unconditionally under it, yet `filter` still allocates a second ~80-element array. Rows are capped at `maxResultsLimit = 80`, so this is one ~10KB buffer copy plus retains on ~5 refcounted fields per row — microseconds, inside a function that already does strictly heavier O(n) work (Set-based dedup, `topRankedInPlace`'s sort).

**Proposal**: `let visibleRows = selectedFilter == .all ? allRows : allRows.filter(selectedFilter.includes)`, same at line 203.

**Expected impact**: Negligible — keep as a free correctness-neutral cleanup, not a performance line item.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Fold into any existing `buildLocalRows` unit test; not worth a dedicated benchmark.

**Caveats from review**: Both skeptics downgraded impact to low/negligible and refuted two supporting claims outright: (1) the SwiftUI-equality "fast path" argument is wrong — `SearchResultPublication.==` compares old-vs-new publication, never `allRows` against `visibleRows` of the same publication, so aliasing doesn't help there; (2) "halves resident row memory" is wrong — `SearchItem`'s String/URL/Data payloads are refcounted and shared regardless; only the ~10KB array buffer is duplicated. One skeptic pointed at `SearchCoordinator.swift:596`'s full-candidate blocklist filter as the same bug at much larger scale (see F21).

---

### F32 — `buildLocalRows` re-dedups an already-deduped candidate list

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:457-470`

**Evidence**:
```swift
output.append(contentsOf: context.candidates)

var seen = Set<SearchItem.ID>()
output.removeAll { !seen.insert($0.id).inserted }
```

**Why it costs / what is missing**: `SourceSearchEngine.merge` already dedups by id before candidates reach here — so in the *normal* pipeline the only possible collisions are the ≤3 synthetic rows prepended just above (calculator, keyword-addressed, path navigator). But the dedup here is not actually redundant in general: two tests feed duplicate ids directly into the projection, bypassing `merge` entirely (`SearchCoordinatorStressTests.swift:330`, and a 300-run property test in `SearchCoordinatorIntegrationTestsResults.swift:131` that asserts `ids.count == Set(ids).count`). Removing the `Set` would break both.

**Proposal**: Keep the dedup. The only safe, worthwhile change is `output.reserveCapacity(context.candidates.count + 4)` before the appends, and reserve the `seen` set similarly if kept.

**Expected impact**: Negligible — a tidiness change, not a measurable perf win. ~60-item lists, single-digit microseconds either way.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Not worth a dedicated benchmark; fold into any existing local-projection test as a non-regression check.

**Caveats from review**: The value-lens skeptic refuted the core proposal (removing the dedup) outright — it's a tested invariant, not belt-and-braces, and deleting it breaks two named tests. The `seen` set is also reused at line 467 (`!seen.contains(fallback.id)`) to suppress a duplicate web-search fallback; any replacement must preserve that. Both skeptics agreed the "removeAll rewrites the array" framing is wrong — `removeAll(where:)` runs in place with no element moves when nothing is removed. Net: only the `reserveCapacity` addition survives review.

---

### F33 — Calculator gate/normalize does several string walks per projection

**Where**: `Sources/FloodlightEngine/Utilities/Calculator.swift:4-13, 30-31, 39-40`

**Evidence**:
```swift
guard source.contains(where: { "+-*/%^()×÷−".contains($0) }) else { return nil }
let normalized = source
    .replacingOccurrences(of: "×", with: "*")
    .replacingOccurrences(of: "÷", with: "/")
    .replacingOccurrences(of: "−", with: "-")
    .trimmingCharacters(in: .whitespacesAndNewlines)
```

**Why it costs / what is missing**: `Calculator.evaluate` runs on every local projection for any query containing an operator character, including hyphens common in filenames. The gate and `looksLikeExpression` scan an 11-character literal per query character but both short-circuit early on non-expression input, so the real recurring cost is the chain of `replacingOccurrences` calls (3–4 short-String allocations), not "4-6 full walks" as originally estimated. This sits in the same function as a `Set<SearchItem.ID>` dedup and an ICU-backed `localizedStandardCompare` sort (`Catalog.swift:80`) over the same candidate list — both strictly more expensive.

**Proposal**: Replace the two `"...".contains($0)` literal scans (lines 6 and 30) with a `switch`/`Set<UInt8>` gate over `Character`/`Unicode.Scalar` — removes the String-literal comparisons with no semantic change. Do not attempt the `[UInt8]` parser-buffer rewrite: `looksLikeExpression` (line 31) accepts any `Character.isNumber`, which includes non-ASCII Unicode digits (Arabic-Indic, fullwidth, vulgar fractions) — so `normalized` is not guaranteed ASCII, and a `[UInt8]` buffer would silently change behavior for those inputs. `CalculatorStressTests.swift:273-281` and `AdversarialCorpus.swift:30` already exercise this. Leave the `[Character]` buffer as-is. If hoisting `NumberFormatter` to a shared instance, it must be `nonisolated(unsafe) static let` under this package's Swift 6 complete-concurrency mode — and it's only constructed once per successful calculator result anyway, so this is not worth doing.

**Expected impact**: Negligible. Two to three orders of magnitude below the `localizedStandardCompare` sort in the same function; no benchmark or user would notice.

**Effort/Risk**: S for the literal-scan replacement only; do not attempt the parser rewrite (would be M effort, Medium-High risk given the Unicode-digit correctness issue).

**How to verify on Mac**: Not worth a dedicated benchmark — verify only that `CalculatorStressTests` and `CalculatorDifferentialTests` (which pin Foundation/Swift Unicode-whitespace and digit disagreements) still pass after the literal-scan change.

**Caveats from review**: Both skeptics independently found the same disqualifying fact for the `[UInt8]` rewrite (non-ASCII `Character.isNumber` passing the gate) and both proposed the identical narrower fix (switch/Set gate on the literal scans only, leave the buffer as `[Character]`). One skeptic also flagged that a shared `NumberFormatter` needs a concurrency annotation the original proposal didn't account for, undermining its own "risk: low" claim.

---

### F27 — tabCompletionHint re-parses query per row per render (verify-then-drop)

**Where**: `Sources/Floodlight/UI/SearchView.swift:421`, `Sources/FloodlightEngine/Search/KeywordEngine.swift:306-349`

**Why it does not clear the bar**: The mechanism is real (O(rows) work to produce at most one non-nil result, no memoization), but the value-lens skeptic refuted the impact: realized rows are ~7 (`FloodlightMetrics.maximumVisibleResults`), not the 12–20 assumed, and the typed keyword strings involved are almost always under Swift's 15-byte small-string threshold — meaning `.lowercased()` and the keyword substring are heap-free. The accuracy skeptic separately found a single-token early exit (`KeywordEngine.swift:327-328`) that skips `.lowercased()` entirely for queries without a space — the common case while typing a first token. Estimated real cost: microseconds, not the "100-200 allocations per keystroke" originally claimed.

**Recommendation**: Confirm with Instruments → SwiftUI template (per the Mac todo list) before spending any effort. If `KeywordEngineRegistry.parseAddress` doesn't appear in the "View Body" heaviest stack, drop this line item.

---

### F28 — SearchItem equality walks full clipboard payload (do not implement as proposed)

**Where**: `Sources/FloodlightEngine/Models/SearchItem.swift:259-278`, `Sources/Floodlight/UI/ResultRow.swift:27-33`

**Why it does not clear the bar**: The value-lens skeptic refuted the core premise: rows render in a `LazyVStack`, so only ~10-15 realized rows are ever diffed, not 200-1,000; the synthesized `==` compares `id` first and short-circuits before touching the payload for any row that changed; `.thumbnail(Data)` is a 128×128 PNG (a few KB), not full image bytes; and no `Set<SearchItem>`/`Dictionary` keyed by `SearchItem` exists anywhere in the repo, refuting the "unsuitable for Set/Dictionary uses" claim entirely. The proposed `.copyClipboardEntry(id:)` enum refactor is L-effort for an unmeasurable gain and fans out into `SelectedResultActionPerformer`, `ClipboardInspector`, and their tests.

**Recommendation**: If anything, narrow `ResultRow.==` (not `SearchItem`'s synthesized conformance) to compare `id/title/subtitle/kind/fileSize/modifiedAt` — XS effort, no engine API churn. Do not touch `SearchItem`'s `Hashable` conformance; it's a `package` type used across the engine and its tests.

### Rejected ideas

- **F26** (SourceSearchEngine.merge rebuilds dedup Set/dictionary 3x per keystroke) — refuted: merged sets are tiny and hard-capped (~76 items worst case), most keystrokes trigger only one merge (later phases gated by cancellation checks), the provenance dictionary claim was wrong (later publishes overwrite, not accumulate), and the proposed accumulator would re-admit stale pre-start rows the code deliberately discards.
- **F29** (Clipboard thumbnails/file icons re-decoded every render) — refuted: rows are wrapped in `.equatable()` with a hand-tested `ResultRow.==`, so unchanged rows never re-run `ResultIcon.init`; thumbnails are hard-capped at 128×128px, and the clipboard row path never populates `fileURL`, so the file-icon cache claim doesn't even apply.
- **F31** (Every snapshot builds a `[SearchItemKind: Int]` dictionary) — refuted: the dictionary has ≤4 keys, `totals` runs on an actor never touching the main thread, and the same code path already pays far heavier costs (a `Set<SearchItem.ID>` plus a `[SearchItem.ID: Provenance]` dictionary over String ids) that dwarf the ~180 enum hashes being described.

## Search speed: concurrency, scheduling, cancellation

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F42 | Clipboard capture decode/hash/insert runs on main actor every 0.5s poll | medium | M | medium | confirmed |
| 2 | F41 | Space keypress eagerly evaluates a preview URL that can read a 15MB blob | medium | S | low | confirmed |
| 3 | F37 | PathNavigator does sync directory enumeration/stat on the main actor per keystroke | medium | M | medium | confirmed |
| 4 | F34 | `searchContent` lacks the generation guard the other three search entry points have | low | S | low | confirmed |
| 5 | F40 | Clipboard search runs full FTS5 + uncapped row projection on the main actor, no debounce | low-medium | S-M | low-medium | confirmed |
| 6 | F44 | Invalidating an in-flight search on scope-change/rebuild blanks the list for the whole rebuild | low | S | low | confirmed |
| 7 | F49 | No signpost/budget covers the coordinator prologue or the debounce phases | medium (enabling) | S | low | confirmed |
| 8 | F45 | First-launch home-directory scan blocks every query with no deadline, no cancellation bridge | medium | M | medium | confirmed |
| 9 | F36 | Coordinator's stale-while-revalidate pre-projection plus engine's immediate snapshot double-project | low | - | - | plausible (disputed) |
| 10 | F38 | Assistant CLI discovery probes codex/claude serially on the main actor at launch | low | S | low | plausible (disputed) |
| 11 | F39 | Ask Claude/Codex spawns the CLI process on the main actor, no PATH cache | low | S | low | plausible (disputed) |
| 12 | F47 | 15-30ms sleeps in `execute` don't coalesce keystrokes (superseded by narrower F34 fix) | low | S | low | plausible (mostly refuted) |

Ranking is by impact/effort after incorporating skeptic corrections, not by the original confidence scores. Several items both skeptics rated "confirmed" turned out low-impact once the corrections were applied (F34, F44); they are ranked low but are still worth landing because they are near-zero-risk, near-zero-effort consistency fixes.

### 1. F42 — Clipboard capture decode/hash/insert runs on the main actor every 0.5s poll

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:232` (poll), `:266` (payload extraction), `Sources/Floodlight/Search/ClipboardImageCapture.swift:51-107` (decode+thumbnail), `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:176-258` (recordImage)

**Evidence**:
```swift
func poll() {
    guard isEnabled, !isPaused else { return }
    let currentChangeCount = observer.changeCount
    guard currentChangeCount != lastChangeCount else { return }
```
```swift
let timer = Timer
    .scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
    }
```

**Why it costs / what is missing**: `ClipboardCaptureService` is `@MainActor`. The `changeCount` early-exit is cheap and correct, but once a change is detected the whole capture pipeline runs inline on main: `ClipboardImageCapture.payload` reads TIFF/PNG off the pasteboard, fully decodes via `NSBitmapImageRep`, redraws and re-encodes a thumbnail through `NSGraphicsContext`, then `ClipboardHistoryStore.recordImage` computes `sha256Hex` over the full payload and does a synchronous SQLite blob insert capped at `maxImageByteCount = 15MB` for **both** PNG and TIFF representations (so worst case ~30MB moves through main). This fires on every system-wide copy, not just while Floodlight is focused, and stalls typing if the panel happens to be open. The timer also runs unconditionally regardless of whether clipboard history is enabled, re-reading `isEnabled` every tick.

**Proposal**: Keep the `NSPasteboard` reads (`pngData()`/`tiffData()`) on main — they must be, `NSPasteboard` is main-only — but move everything downstream (decode, thumbnail render, hash, insert) into a single serial off-main consumer (an `actor ClipboardCaptureWorker`, not a fresh `Task` per capture — a fresh task per capture races consecutive-copy dedup logic in `recordImage`/`insert`, which today relies on main-actor serialization). Also: replace the AppKit decode/redraw path in `ClipboardImageCapture` with `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailFromImageAlways` (ImageIO), which never materializes the full bitmap and is safely usable off-main — this alone removes most of the CPU cost regardless of threading. Gate timer creation on `isEnabled` and cache it in a stored property updated from the setter instead of reading UserDefaults every tick (this part is a minor win — UserDefaults reads are in-memory-cached, not disk).

```swift
// Off-main worker, fed by the main-actor poll() after cheap gates:
actor ClipboardCaptureWorker {
    func process(_ raw: PasteboardPayload) async -> ClipboardEntryDraft { ... }
}
```

**Expected impact**: Removes a 0-30MB decode+hash+insert from the main thread on every clipboard change system-wide. Medium, not high — the hitch is confined to Floodlight's own main thread and is only user-visible when the panel is open and being typed into during a large image copy.

**Effort/Risk**: M / medium — correctness hinges on preserving capture ordering and consecutive-duplicate dedup, which today is implicit in main-actor serialization; moving to an async worker needs an explicit serial queue, not a `Task` per event.

**How to verify on Mac**: Extend `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` with a case injecting a 10MB TIFF and asserting `poll()` returns within a low-ms budget on the main actor (the insert completing asynchronously). Record a Time Profiler trace while copying a large screenshot with the panel open and typing; before the fix, `sqlite3_step`/`CGImageDestination` frames appear on the main thread under `poll`; after, they don't. `powermetrics --samplers tasks -i 5000` with clipboard history off, before/after the timer-gating change, for the idle-wakeup claim (secondary).

**Caveats from review**: Both skeptics confirmed the mechanism but corrected the framing significantly. The `stateLock`/capture-vs-search contention claim in the original F42 evidence (shared with F40) does not apply here — `ClipboardCaptureService` polls on the main actor, so it cannot contend with a keystroke on the same thread; that's a different (and smaller) problem than stated. Thumbnails are small (a few KB, 128x128); the real cost is the full-size decode/hash/insert of the *original* payload, not the thumbnail. Effort should include replacing the AppKit decode path, which is a bigger and more valuable change than the pure threading move, and can be landed independently at lower risk (S, not part of the actor restructuring).

---

### 2. F41 — Space keypress eagerly evaluates a preview URL that can read a 15MB blob

**Where**: `Sources/Floodlight/App/FloodlightPanel.swift:291-295` (eager argument evaluation), `Sources/Floodlight/Search/SearchCoordinator.swift:418-433` (`previewableSelectionURL`), `:445-450` (write, guarded)

**Evidence**:
```swift
case 49:
    if Self.shouldHandleSpaceAsPreview(
        isClipboardMode: model.isClipboardMode,
        query: model.query,
        hasPreviewableSelection: model.previewableSelectionURL != nil
    ) {
```

**Why it costs / what is missing**: Swift evaluates all call arguments before dispatch, so `model.previewableSelectionURL` runs on **every** space keypress the panel's `NSEvent` monitor sees — including a space typed mid-query in any mode, not only clipboard mode — even though `shouldHandleSpaceAsPreview` immediately discards the result when the query is non-empty. When the selected row is a clipboard image, the getter calls `clipboardStore.imageData(for:)`, which SELECTs both `png_data` and `tiff_data` (up to 15MB each) under `stateLock`. The file write at `SearchCoordinator.swift:448-450` is guarded by `fileExists`, so it's once-per-entry, not once-per-keypress — the recurring cost is the SQLite blob read plus a directory-create syscall, every space bar press. `togglePreview()` then calls `previewableSelectionURL` a second time on the intentional-preview path, doubling the read for the case that matters.

**Proposal**: Reorder to check cheap gates first and compute the URL once:
```swift
case 49:
    if Self.shouldConsiderSpaceAsPreview(isClipboardMode: model.isClipboardMode, query: model.query),
       let url = model.previewableSelectionURL {
        quickLook.toggle(url)
        return nil
    }
```
Keep `shouldHandleSpaceAsPreview(isClipboardMode:query:hasPreviewableSelection:)` as a thin wrapper so existing unit tests keep compiling. Fold the second `togglePreview()` lookup into the same call so the intentional path also reads the blob once, not twice.

**Expected impact**: Removes a synchronous SQLite blob read (0-30MB combined PNG+TIFF) plus a directory-create syscall from every space keypress typed with a clipboard image row selected, in any mode. Medium, not high — it's a three-line reorder with a real but bounded win.

**Effort/Risk**: S / low.

**How to verify on Mac**: Add a test-only call counter on `ClipboardHistoryStore` (`imageDataCallCount`); pump a space `NSEvent` through `handleKeyEvent` with a non-empty query and assert the counter stays at zero. Manually: copy a 10MB screenshot, select it in clipboard mode, hold space while recording Time Profiler — before the fix `sqlite3_column_blob` appears under `handleKeyEvent` on every repeat; after, only on the toggle.

**Caveats from review**: Both skeptics confirmed but corrected magnitude: the write is not per-keypress (guarded by `fileExists`), 15MB is a cap not a typical payload (screenshots are usually 0.5-5MB and often warm in the page cache), and the "stat on every space with any clipboard text row" claim is wrong — `parseLocalPath` only touches disk for path-shaped text. The async/off-main half of the original proposal (make `clipboardImagePreviewURL` async) was rejected by one skeptic as unnecessary churn touching a synchronous property with six test call sites — dropped from this writeup in favor of the cheaper reorder.

---

### 3. F37 — PathNavigator does sync directory enumeration/stat on the main actor per keystroke

**Where**: `Sources/FloodlightEngine/Search/PathNavigator.swift:112-135` (relative-path branch, two enumerations), `:154-162` (`findCaseInsensitiveMatch`), `Sources/Floodlight/Search/SearchResultProjection.swift:453-454` (call site inside `buildLocalRows`, main actor)

**Evidence**:
```swift
private static func findCaseInsensitiveMatch(
    name: String, under parent: URL, fileManager: FileManager
) -> URL? {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: parent.path)
    else { return nil }
```

**Why it costs / what is missing**: `SearchCoordinator` is `@MainActor`; `buildLocalRows` -> `PathNavigator.resolve` runs there synchronously, 4-5 times per keystroke (one stale-while-revalidate pre-projection plus each yielded snapshot). For a *relative* path-shaped query (contains `/`, not `~/`-prefixed or absolute — those branches return early with only 1-2 stats), `resolve` does two full `contentsOfDirectory` enumerations (search root and home directory) plus a `fileExists` stat per candidate, all blocking I/O on the thread that draws the panel. The default search root is `~/Downloads` (`SearchCoordinator.swift:164`), so on a populated Downloads folder this is ~1-3ms per enumeration x 2 dirs x up to 4-5 projections per keystroke even on a warm APFS cache — real, measurable main-thread cost, separate from the network/cold-mount tail. The repo's `query-path-no-sync-disk-read` ast-grep gate does not catch this: it deliberately scopes to functions literally named `immediatePage`/`indexedItems` and explicitly declines widening into "discovery code" per its own rule comment.

**Proposal**: Cheapest, safest fix — reorder so the exact-case `appendingPathComponent` candidate is `fileExists`-stat'd **first**; `findCaseInsensitiveMatch` (and its two enumerations) runs only on a miss. Since APFS is case-insensitive by default, the exact stat already succeeds for any casing in the common case, making the enumerations pure waste today. Also: skip `findCaseInsensitiveMatch` when the remainder contains `/` (a single path component from `contentsOfDirectory` can never match a multi-component name), and dedupe candidate parents when `rootURL == homeURL`. These are all local to `PathNavigator.swift`, no protocol/actor changes. A larger, separate option (path navigation as a fourth actor-side provenance in `SourceSearchEngine.execute`) targets the genuine cold/network-mount hang tail but is L effort and not needed for the common-case win above.

**Expected impact**: Removes essentially all of the per-keystroke enumeration cost in the common (warm APFS, case-matches) case — the dominant, benchmarkable cost. Converts the separate stale-SMB-mount tail into a background latency issue only if the L-effort provenance work is also done. Medium.

**Effort/Risk**: S for the stat-order fix (low risk); M-L for moving path resolution off-main entirely (medium risk — new `Provenance` case, README requires a budgeted test for a new hot path).

**How to verify on Mac**: Add `testPathNavigatorResolveBudget` to `Tests/FloodlightEngineTests/PathNavigatorTests.swift`: temp directory with 5,000 entries, warm up 5x, 11 samples of `PathNavigator.resolve(query: "fixture/x", rootURL: temp)`, print `FLOODLIGHT_BENCH path_navigator_resolve_us=`, assert median under a couple ms. For the cold-mount tail: mount a network share, set search scope to it, type a path-shaped query, and record Time Profiler — look for `__getdirentries64`/`_stat` under `buildLocalRows`.

**Caveats from review**: Both skeptics agreed the mechanism is real but scoped down the blast radius: enumeration only happens on the *relative* branch (`~/` and absolute queries pay only 1-2 stats), `homeDirectoryForCurrentUser` is a getpwuid call not disk I/O, and the claim that the ast-grep gate "fails its own intent" is wrong — the gate's own comment explicitly declines to widen into discovery code, so don't propose widening it. One skeptic identified the stat-reordering fix as strictly better and cheaper than either original proposal option; that's promoted to the primary recommendation here.

---

### 4. F34 — `searchContent` lacks the generation guard the other three search entry points have

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:341-350` (missing guard), compare `:101-106` (`search`, has it)

**Evidence** (verified against source):
```swift
package func search(_ query: String, limit: UInt32 = 60) async throws -> [FFFSearchResult] {
    let requestGeneration = reserveSearchGeneration()
    return try await perform {
        guard self.isLatestSearch(requestGeneration) else {
            throw CancellationError()
        }
        ...
```
```swift
package func searchContent(
    _ query: String, limit: UInt32 = 16, timeBudgetMilliseconds: UInt64 = 35
) async throws -> [FFFContentMatch] {
    try await perform {
        guard let handle = self.handle else { ... }
        guard !query.isEmpty else { return [] }
```
`searchContent` has no `reserveSearchGeneration()`/`isLatestSearch` pair.

**Why it costs / what is missing**: `search`, `searchFiles`, and `searchDirectories` all self-abandon at the head of the serial `dev.vmg.fff-swift` queue when superseded. `searchContent` doesn't, so a grep already past `SourceSearchEngine`'s own cancellation guard (the 30ms cancellation-aware `Task.sleep` at `SourceSearchEngine.swift:321` followed by `guard isCurrent(token), !Task.isCancelled`) will run to completion even if its execution is dead by the time it reaches the queue.

**Proposal**: Add the same two lines the other three have:
```swift
package func searchContent(_ query: String, limit: UInt32 = 16, timeBudgetMilliseconds: UInt64 = 35) async throws -> [FFFContentMatch] {
    let requestGeneration = reserveSearchGeneration()
    return try await perform {
        guard self.isLatestSearch(requestGeneration) else { throw CancellationError() }
        ...
```
`SourceSearchEngine.isolated` already maps `CancellationError` to an empty non-degraded result, so nothing downstream changes.

**Expected impact**: Low, not the originally-claimed "N-1 of N greps removed." Both skeptics independently showed the outer execute task is already cancelled per keystroke and the cancellation-aware sleep at `SourceSearchEngine.swift:321` catches almost all stale greps before they ever reach the queue — plus `SourceSearchEngine`'s file-search path uses `FFFIndex.search` (not `searchFiles`, which belongs to the separate `ApplicationCatalog` index on its own queue), so app/settings results were never actually blocked by a content grep. Realistic ceiling: one grep's residual ~35ms occasionally, often zero.

**Effort/Risk**: S / low.

**How to verify on Mac**: Add `Tests/FloodlightEngineTests/FFFIndexCancellationTests.swift`: fire several `searchContent` calls back to back without awaiting against a real `FFFIndex` over a temp tree, then time an immediately-following `search` call; print `FLOODLIGHT_BENCH content_search_queue_head_of_line_ms=`. Given the small expected effect, treat this as consistency hardening that a benchmark is unlikely to move rather than a headline perf fix.

**Caveats from review**: Both skeptics confirmed the code gap is real and the fix is correct and cheap, but both independently refuted the magnitude claim — the "several greps resident, N-1 removed" framing does not survive reading `SourceSearchEngine.execute`'s existing cancellation checks. Land it for consistency and to close the actual (narrow) window, not for a measurable latency win. Drop the proposal's suggestion of a second content-specific generation counter — unnecessary, since `searchDirectories` has no production caller and `search` is fully awaited before `contentItems` within a pass.

---

### 5. F40 — Clipboard search runs full FTS5 + uncapped row projection on the main actor, no debounce

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:657-668` (`publishClipboardModeResults`), `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:349-361` (empty/short-query in-memory path, up to 1,000 entries), `Sources/Floodlight/Search/SearchResultProjection.swift:196-208, 299` (`projectClipboard`, per-row `fileExists` stat)

**Evidence**:
```swift
fileprivate func publishClipboardModeResults(...) {
    searchTask?.cancel()
    searchTask = nil
    publication = SearchResultProjection.project(
        .clipboard(.init(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            entries: clipboardStore.search(query: query),
```

**Why it costs / what is missing**: Clipboard mode gets none of local mode's staging — every keystroke calls `clipboardStore.search` synchronously on the main actor with no debounce, no actor hop. Two costs, corrected from the original write-up: (1) `entryColumns` does include `thumbnail_png`, but thumbnails are small (a few KB, 128x128 PNG); the "up to 200 thumbnail blobs / megabytes" framing is overstated. (2) The real dominant cost, missed in the original evidence: the empty/short-query branch (`ClipboardHistoryStore.swift:349-361`) returns pinned entries plus up to `inMemoryRecentWindowLimit = 1,000` recent entries, and `SearchResultProjection.projectClipboard` builds a full row (parsing local paths, URLs, hex colors, code hints) for **every one** of them, uncapped — on clipboard-mode entry, every pin/delete, and every filter change, not just on typed queries. Additionally, `SearchResultProjection.swift:299` does a synchronous `fileExists` stat per path-shaped text row on the main actor, on every clipboard keystroke — this is exactly the pattern the engine-side `query-path-no-sync-disk-read` gate forbids, but it escapes the gate because it lives in the shell target, not the engine.

**Proposal**: (1) Cap the empty/short-query projection to `searchResultLimit` (200) instead of the full 1,000-entry in-memory window — one-line change in `ClipboardHistoryStore.search` or `projectClipboard`, largest win for least effort. (2) Drop the `exists` probe in `buildClipboardTextRow` (`SearchResultProjection.swift:299`) or resolve it lazily only for visible rows. (3) Run `clipboardStore.search` off the main actor in the `searchTask` (the store is `@unchecked Sendable` with its own lock) — do **not** add a debounce matching local mode's cadence, since local mode's sleeps are inter-pass staging, not an input debounce, and clipboard mode currently has no such latency to begin with. (4) Do not attempt to narrow `stateLock` around `sqlite3_step` loops — SQLite already opens with `SQLITE_OPEN_FULLMUTEX`, and the lock also guards `deinit`'s close of the handle; narrowing it risks a use-after-free race.

**Expected impact**: Low-medium — the existing `ClipboardHistoryPerformanceTests.swift` already benchmarks `store.search` at under 2ms median at 1,000 entries, so the store call itself is not the bottleneck; the uncapped per-entry projection and the per-row `fileExists` stat are.

**Effort/Risk**: S for items (1) and (2); M for item (3) if pursued. Risk low-medium.

**How to verify on Mac**: Extend `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift` with entries that include image rows (the existing corpus is 100% text) and add a projection-cost bench covering the empty-query path at 1,000 entries; print `FLOODLIGHT_BENCH clipboard_search_us=` and a new `clipboard_empty_query_projection_us=`. `swift build -c release`, open clipboard mode with a large history, Time Profiler while typing and while clearing the query — watch for `buildClipboardTextRow`/`fileExists` on the main thread.

**Caveats from review**: Both skeptics rejected the original evidence's headline claims (200 thumbnail blobs, `stateLock` contention with capture — capture is also main-actor and can't contend with a keystroke) but independently found a bigger, cheaper-to-fix cost the original finding missed: the uncapped empty-query projection and the per-row `fileExists` stat. This writeup replaces the original proposal with the corrected, higher-value one.

---

### 6. F44 — Invalidating an in-flight search on scope-change/rebuild blanks the list for the whole rebuild

**Where**: `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:512-523` (`invalidateActiveExecution`), triggers at `:115` (`warmUp`), `:172` (`changeScope`), `:198` (`rebuild`)

**Evidence**:
```swift
private func invalidateActiveExecution() -> (token: UInt64, query: String, immediate: Bool)? {
    guard let execution else { return nil }
    execution.task?.cancel()
    self.execution?.task = nil
    self.execution?.continuation.yield(SearchSnapshot(
        candidates: [],
        totalMatches: [:],
        pendingKinds: [.application, .file, .folder, .systemSetting],
        isDegraded: false
    ))
    return (execution.token, execution.query, execution.immediate)
}
```

**Why it costs / what is missing**: This yield undoes the shell's own stale-while-revalidate design (documented at `SearchCoordinator.swift:519-526`, written specifically to avoid a list-collapse regression). Both skeptics agreed the severity is inverted from the original write-up: `warmUp()` fires once per launch and restarts synchronously, so its flash is at most one frame (possibly coalesced away by the stream's buffering). The durable case is `changeScope`/`rebuild`, where `restart(active)` only runs after the index mutation task fully completes — the list stays empty (down to synthetic rows) for the entire rebuild duration, which can be seconds, not a frame.

**Proposal**: Do not clear candidates for the warm-up case. The minimal fix: in the shell, when a snapshot has empty candidates and `!isSettled` (i.e. mid-invalidation, not a genuine zero-result settle), keep `publication.sourceCandidates` instead of overwriting — no `SearchSnapshot` field change needed for this narrow case. For `changeScope`/`rebuild`, keep the clearing behavior (preserving old-scope candidates there would let the user open a file from the wrong root while the new scope is still indexing — a correctness bug, not polish).

**Expected impact**: Eliminates a visible flash after cold launch during the warm-up window. Low — narrower than originally claimed, since the persistent-collapse case (`changeScope`/`rebuild`) is intentionally *not* fixed by the same mechanism.

**Effort/Risk**: S / low.

**How to verify on Mac**: Add `testWarmUpRestartDoesNotEmptyPublishedRows` to `Tests/FloodlightTests/SearchCoordinatorIntegrationTests.swift`: with a `ScriptedCatalog` reporting a change on warm-up, record `publication.visibleRows.count` across the restart and assert no drop to the synthetic-only baseline. Visually: launch, immediately summon and type during the cold-start window, screen-record at 60fps and step through frames.

**Caveats from review**: One skeptic flagged that literally applying the shell-side "keep previous candidates" fix to `changeScope` would be an actual regression (stale-scope files remain selectable). The proposal above is scoped to avoid that — restrict the fix to the warm-up path only.

---

### 7. F49 — No signpost/budget covers the coordinator prologue or the debounce phases

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:8-15` (`query.didSet` -> `scheduleSearch`, uninstrumented), `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:267, 321` (uninstrumented sleep phases — corrected: the phases *after* the sleeps already have signposts at `:239, :289, :323`)

**Evidence**:
```swift
/// The convention, for whoever adds the next hot path: a new one is not done
/// until it has a budgeted test here. Warm up, take many samples, take the
/// median, and assert against a bound with enough margin to survive a shared
/// CI runner
```

**Why it costs / what is missing**: Corrected from the original claim — `Tests/FloodlightEngineTests/SearchPerformanceTests.swift` already budgets `engine.search(...)` to first snapshot at under 5ms, and signposts already exist for `SourceSearch`, `IndexedSourceSearch`, `ContentSourceSearch`. What is genuinely missing: no interval covers `query.didSet` (the coordinator's own synchronous pre-projection, `SearchCoordinator.swift:527`) to the first publication, and nothing counts publications or `immediatePage` calls per keystroke — so the double-projection question in F36 and the debounce-tuning question in F47 are both unfalsifiable on the maintainer's machine without new instrumentation.

**Proposal**: Add `Debounce` and `ContentDelay` signposts around the two `Task.sleep` sites (`SourceSearchEngine.swift:267, 321`) and a `Projection` interval around `SearchResultProjection.project`. Add a swift-testing-style test (matching `Tests/FloodlightTests`' existing style, not XCTest) that counts publications per keystroke and `immediatePage` calls per settled execution deterministically, rather than asserting a wall-clock bound in the `@MainActor` shell target (flakier than the engine's CPU-time benchmarks).

**Expected impact**: Enabling, not a perf win itself — but every scheduling-side finding in this section (F36, F44, F47) depends on this instrumentation existing to be measured on the maintainer's machine rather than argued from code reading. Medium value for that reason.

**Effort/Risk**: S / low.

**How to verify on Mac**: `swift test -c release` and check for the new `FLOODLIGHT_BENCH` lines. `swift build -c release`, launch, Instruments with Points of Interest + Time Profiler, type an 8-character query, confirm `Debounce`/`ContentDelay`/`Projection` intervals nest correctly inside the existing `SourceSearch` signpost.

**Caveats from review**: Both skeptics independently found the original finding overstated the gap (claiming no keystroke-latency budget exists at all, when `SearchPerformanceTests.swift` already has one) and got the concrete proposed assertion numbers wrong (`immediatePage` is called twice per catalog per execution, not once; publications per keystroke are 4, not ≤3, once the coordinator's own pre-projection is counted). Scope this narrowly to the coordinator prologue and the two sleep phases, not a full re-litigation of what's already measured.

---

### 8. F45 — First-launch home-directory scan blocks every query with no deadline, no cancellation bridge

**Where**: `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:270` (`await ensureStarted()`), `:390-394` (`await startup.task.value`, not cancellation-aware), `Sources/FloodlightEngine/Search/FFFIndex.swift:677-687` (`waitForScanCompletion`, no deadline), `:704` (`enableHomeDirectoryScanning: true`)

**Evidence**:
```swift
guard isCurrent(token), !Task.isCancelled else { return }
var degraded = await ensureStarted()
```
```swift
private func waitForScanCompletion() async throws {
    var consecutiveIdlePolls = 0
    while consecutiveIdlePolls < 2 {
        try Task.checkCancellation()
        let progress = try await index.progress()
        ...
```

**Why it costs / what is missing**: `execute()` publishes the immediate app/settings page, then blocks on `ensureStarted()`, which fans out to `startFiles()` — awaiting a non-throwing `Task<Result, Never>`'s `.value`, which is not cancellation-aware. `waitForScanCompletion` polls with no deadline against an index scanning the whole home directory. Corrected from the original framing: this does **not** mean the panel shows nothing — the immediate app/settings snapshot still publishes per keystroke — but `.file`/`.folder` stay pending indefinitely with no degradation signal during the first-launch scan, and every keystroke during that window parks a suspended `execute` task that cannot be released by cancellation, only by the scan finishing.

**Proposal**: Make file/folder readiness non-blocking on the query path: if `filesReady` is false, kick `startFiles()` without awaiting, publish immediate/indexed-minus-files with `.file`/`.folder` still in `pendingKinds`, and let `warmUp()`'s existing restart-on-ready mechanism (already implemented at `SourceSearchEngine.swift:109-117`) deliver the file results when the scan finishes. Give `waitForScanCompletion` a deadline (e.g. 30s via `ContinuousClock`) scoped to the initial `start()` path only — not `changeScope`/`rebuild`, which have a different, stricter contract (a query must not see a mismatched root) documented at `FFFIndex.swift:674-676`. If a deadline is added, surface it as `isDegraded`, not a silent success.

**Expected impact**: Medium, scoped to first launch / post-rebuild cold start (the mmap index cache means warm launches are fast). Turns "spinner never settles during first-launch scan, one suspended task parked per keystroke" into "results and settlement arrive progressively as sources become ready."

**Effort/Risk**: M (touches `SourceSearchEngine`'s readiness bookkeeping, not L as one path — the riskier "cancellation-aware await" half of the original proposal was flagged as actively dangerous by one skeptic, since readiness bookkeeping lives in the *awaiter*, not the startup Task, so unwinding early awaiters can skip the `filesReady = true` flip entirely). Risk medium.

**How to verify on Mac**: Add `testQueriesDoNotBlockOnSlowStartup` to `Tests/FloodlightEngineTests/SourceSearchEngineTests.swift` with a `ScriptedFileSource(startDelay: .seconds(5))`: assert the first and second snapshots arrive within 200ms with `.file` still pending, and that repeated queries during the delay leave at most one live execution. For the real cold start: delete the FFF index cache under Application Support, launch, summon and type immediately, record Instruments — `SourceSearch` intervals should not span the entire scan duration after the fix.

**Caveats from review**: Both skeptics agreed the mechanism is real but rejected the "spinner forever, no results" framing (apps/settings do appear) and the "thundering herd" secondary claim (parked tasks are cheap suspended continuations, not a measurable cost). One skeptic specifically warned against implementing the cancellation-aware-await half of the original proposal as written — it can skip readiness bookkeeping. Scope the fix to non-blocking kick-off plus a `start()`-only deadline; drop the `changeScope`/`rebuild` deadline idea entirely (breaks their correctness contract).

---

### 9. F36 — Coordinator's pre-projection and engine's immediate snapshot double-project (disputed)

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:527` (pre-projection), `:540-548` (Task + engine hop), `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:244-264` (immediate snapshot)

**Status**: plausible, split verdict. Both skeptics agreed the mechanical observation (two projections, two `@Observable` writes per keystroke) is true, but both independently refuted the core proposal: the two projections are **not** duplicate work — the first projects the *previous* query's stale candidates (deliberately, per the comment at `SearchCoordinator.swift:519-526`, to avoid a documented list-collapse regression) while the second projects the new query's actual candidates. Deleting the pre-projection as proposed would remove the only synchronous paint of the just-typed character (calculator/keyword/web-fallback rows) and, per one skeptic, could blank the list entirely during a `rebuild()`/`changeScope()` because `search()` itself can suspend on `sourceMutation`. Magnitude was also corrected down by both skeptics: `PathNavigator.resolve` does no I/O for non-path queries, and the projection cost over ≤80 rows is tens of microseconds, not the implied fraction of a frame.

**Verdict for the report**: Do not delete the pre-projection or change the `SourceSearching.search` contract as proposed. The one piece both skeptics left standing as independently useful: `SearchResultPublication` is already `Equatable` — but one skeptic also showed a naive `guard next != publication` would do an O(240)-element deep compare on every publish for a check that almost never fires (progress/pendingKinds differ by construction), so even that narrow guard isn't a clear win. **No action recommended for this section beyond what F49 enables (instrumentation to actually measure it before touching it).**

---

### 10. F38 — Assistant CLI discovery probes codex/claude serially on the main actor at launch (disputed)

**Where**: `Sources/FloodlightEngine/Search/KeywordEngine.swift:459-472` (serial loop), `Sources/FloodlightEngine/Search/AssistantProcessRunner.swift:124-152` (`resolveExecutable`, no cache)

**Status**: plausible, split verdict. One skeptic refuted the headline "~600ms of main-actor occupancy" claim outright: `process.run()` is a `posix_spawn` that returns immediately, and the actual wait happens via `process.terminationHandler` resuming a continuation from a background drain queue — the main actor is free for the whole zsh-login duration. The real main-actor cost is a handful of `stat`s plus 1-2 `posix_spawn` calls (single-digit ms), and this doesn't gate panel presentation (`ApplicationPresentationCoordinator.launch` shows the panel synchronously before the startup task body runs).

**Verdict for the report**: The genuine, uncontested defect both skeptics kept: `resolveExecutable` re-derives the login `$PATH` from scratch on every miss with **no cache**, so two assistant commands not found in the four hardcoded fast-path directories (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`) cost two full serial zsh-login spawns before assistant keyword rows become available — worst case up to 2x the 5s timeout. **Recommendation**: skip the `@concurrent`/`withTaskGroup` restructuring (low value, per both skeptics); instead memoize the resolved executable URL (or the login PATH) in an `OSAllocatedUnfairLock`-guarded store on `AssistantProcessRunner`, populated once and reused by both the startup probe and later `run` calls. Effort S, risk low, and it's the fix with real (if narrow) user-visible value: assistant keywords currently can take up to ~2x zsh-login time to appear after launch on machines where the CLI lives outside the four fast-path dirs.

---

### 11. F39 — Ask Claude/Codex spawns the CLI process on the main actor, no PATH cache (disputed)

**Where**: `Sources/FloodlightEngine/Search/AssistantProcessRunner.swift:112` (`run`), `:124` (`resolveExecutable`, `package static`, not private), `Sources/Floodlight/Search/AssistantRunSession.swift:64-71` (`Task { @MainActor }`)

**Status**: plausible, split verdict. Confirmed mechanism (isolation inheritance under `NonisolatedNonsendingByDefault` really does put `stat`s, `Process`/`Pipe` setup, and `posix_spawn` on the main actor per explicit "Ask Claude" activation) but both skeptics rejected "up to a full login-shell resolution from the main thread" — the shell spawn's runtime is `await`ed, off-main; only the spawn itself (plus warm stats) is synchronous, low single-digit ms, once per user-initiated activation, not per keystroke.

**Verdict for the report**: This is the same root cause as F38 (no PATH/executable-URL cache), and fixing that once fixes both. The `@concurrent` isolation annotation is a legitimate free-rider on the same PR but is not the headline value — one skeptic noted it may need to go on the protocol requirements (`AssistantProcessRunning.run`/`isAvailable` at lines 12/17), not just the concrete struct, for dispatch through `any AssistantProcessRunning` to actually change. **Recommendation**: fold into the F38 fix — one memoized executable-URL/PATH cache on `AssistantProcessRunner`, shared by startup probe and interactive run. Do not treat as two separate line items in effort estimation.

---

### 12. F47 — 15-30ms sleeps in `execute` don't coalesce keystrokes (mostly refuted, superseded by F34)

**Where**: `Sources/FloodlightEngine/Search/SourceSearchEngine.swift:266-269, 306, 320-321`

**Status**: plausible, one skeptic refuted outright. The core observation (the sleeps are within-execution staging, not an input debounce, and every keystroke does allocate a Task/actor hop/AsyncStream) is correct, but the claimed impact — "9 file searches and up to 9 content greps against a serial queue, of which only the last matters" — is refuted by the same generation-guard mechanism discussed in F34: `search`/`searchFiles`/`searchDirectories` already discard superseded work before any FFI call, so stale file searches cost near-zero. The instrumentation half of the proposal is also moot — `SourceSearch`/`IndexedSourceSearch`/`ContentSourceSearch` signposts already exist. The one real residual cost, per one skeptic, is exactly F34's gap: `searchContent` has no generation guard, so a superseded grep (when `contentEligible` — rare, gated at `query.utf8.count >= 3 && indexedFiles.count < 12`) does burn its FFI budget.

**Verdict for the report**: Do not pursue the L-effort restructuring proposed (execution reuse across keystrokes, or a shell-side trailing debounce — the latter would delay the instant application-row paint on every final keystroke, a regression). **F34's two-line fix supersedes this finding entirely.** No separate action.

### Rejected ideas

- **F35** — "FFFIndex.perform never bridges task cancellation onto the dispatch queue": the proposed fix (bump the search generation on cancel) already exists via `reserveSearchGeneration()`, called before every search enqueue; queued stale work already self-abandons in microseconds. The only unmitigated case (searchContent's missing guard) is covered separately by F34.
- **F43** — "Dismissing the panel never cancels the engine's execution": `reset()`'s `searchTask?.cancel()` already terminates the `AsyncStream` and triggers `finishActiveExecution()` within microseconds via the existing `onTermination` -> `cancel(token:)` path; the proposed fix has identical latency to what already happens and would only serve to keep a otherwise-dead protocol method alive.
- **F46** — "ApplicationCatalog's async methods run on the actor while SystemCatalog's don't": `ApplicationCatalog.refreshIfNeeded` already offloads its heavy work to its own serial discovery queue via a checked continuation; it doesn't need SystemCatalog's `@concurrent` treatment because, unlike SystemCatalog, it isn't doing inline work on the actor to begin with. `indexedItems`'s on-actor epilogue is bounded to ≤24 rows (microseconds).
- **F48** — "Startup work runs at the same priority as keystrokes": the cited Tasks contain only await-glue; all actual work already runs on explicit-QoS DispatchQueues that Task priority cannot change. Startup and query-time readiness checks are the *same* coalesced work (both await the same shared `startup.task`), not competing work — there's no priority inversion to fix, and demoting the discovery queue as proposed would actively delay first-query app results.


# Cold start

## Cold start

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F55 | Marker directory `fileExists` loop is redundant against data already in hand | low | XS | low | confirmed (split — see review) |
| 2 | F50 | Panel built and shown (with focus steal) on every login-item boot | medium | XS–S | low–medium | confirmed |
| 3 | F52 | Clipboard startup window reads every image thumbnail blob eagerly | low | S–M | low–medium | confirmed |
| 4 | F53 | Assistant CLI resolution can spawn two uncached login shells | low | S | low | confirmed |
| 5 | F63 | Application Support directory resolved twice on the construction path | low | XS | low | plausible (mostly refuted, one real line survives) |
| 6 | F58 | Resolved keyword registry waits on the slower of two concurrent awaits | low | S | low | confirmed |
| 7 | F54 | Application catalog re-walks and re-names every app, uncached, on every launch | medium (first-launch-after-boot) | M | medium | confirmed |
| 8 | F61 | No cold-start signposts or budgeted test exist | medium (diagnostic) | XS–S | low | confirmed |
| 9 | F59 | SMAppService status/register run synchronously on main, retry forever on failure | low (medium for broken installs) | S | low–medium | plausible |
| 10 | F60 | Clipboard prune runs at every launch, single lock shared with clipboard search | low | S | low | plausible (largely refuted — see review) |
| 11 | F56 | System settings discovery builds a Bundle per appex, uncached | low | S | low | plausible (largely refuted) |
| 12 | F67 | Menu bar icon SVG decode sits ahead of hotkey registration | low | XS | low | plausible (mostly refuted) |
| 13 | F65 | QuickLook/ServiceManagement frameworks linked eagerly | low | S | low–medium | plausible (mostly refuted) |
| 14 | F66 | Clipboard poll timer arms even when the feature is disabled | low | — | — | refuted as proposed (do not implement as written) |
| 15 | F64 | SwiftUI App lifecycle + empty Settings scene at launch | low | — | — | refuted (do not implement) |
| 16 | F62 | FFF index configured for home-dir scan + content indexing + binaries | unknown, needs research | M | high | confirmed mechanism, unresolved value |

Ranking is by realistic impact/effort after review corrections, not by the original confidence scores — several findings both skeptics downgraded to "low" survive only as cheap, safe cleanups; two survive only as correctness fixes (focus steal, priority inversion) rather than measurable speed wins.

### 1. Marker directory `fileExists` loop is redundant against data already in hand

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:496-501` (loop), `:265-277` (the `changed` gate that forces it on every launch)

**Evidence**:
```swift
let changed = state.withLock { current in
    current.applicationDirectoryFingerprint = fingerprint
    return !current.isPrepared
        || Self.signature(of: current.applications) != Self.signature(of: marked)
}
guard changed else { return false }
Self.synchronizeMarkers(applications: marked, markerRoot: markerRoot, fileManager: fileManager)
```

**Why it costs / what is missing**: `isPrepared` starts `false` in every process, so `changed` is forced `true` on the first `prepare()` of every launch, running `synchronizeMarkers`. That function already lists the marker directory once (`existing`, for its delete pass) but then does a separate `fileManager.fileExists(atPath:)` per application to decide what to create — a second, redundant filesystem probe against data it already holds in an array.

**Proposal**: Build `let existingNames = Set(existing.map(\.lastPathComponent))` from the listing already taken, and change the per-app check to `if !existingNames.contains(application.markerName)`. Leave `!current.isPrepared` in the `changed` expression alone — it is load-bearing for populating in-memory state on a fresh process, and a persisted-signature variant (the original proposal) would remove the only self-healing path for a partially-deleted marker directory.

**Expected impact**: Deletes N redundant `stat` calls per launch (N = installed app count, ~100-300 typical, not the originally claimed ~800). Sub-millisecond to low-single-digit ms; not the "tens vs hundreds of ms" originally claimed, because the dominant cost in `prepare()` is the `discoverApplications()` walk (LaunchServices `displayName` per app), which this does not touch.

**Effort/Risk**: XS / low. Three-line change, no new persistence, no behavior change to `prepare()`'s return contract.

**How to verify on Mac**: `sudo fs_usage -w -f filesys Floodlight | grep ApplicationIndex/Items | wc -l` during a launch, before and after — expect the count to roughly halve (one listing instead of listing + N stats).

**Caveats from review**: Both skeptics converged on rejecting the original persisted-signature proposal (it destroys the self-healing property when the marker directory is deleted out-of-band, and changes `prepare()`'s return semantics that gate `index.rescan()`) and independently proposed this exact `existingNames` set fix instead. Original impact estimate (N≈800, "tens vs hundreds of ms") was overstated by both — real N is ~100-300 and the walk in `discoverApplications()` dominates regardless.

---

### 2. Panel built and shown (with focus steal) on every login-item boot

**Where**: `Sources/Floodlight/App/ApplicationPresentationCoordinator.swift:53-54` (the `launch` method), `Sources/Floodlight/App/AppDelegate.swift:35,37`, `Sources/Floodlight/App/LaunchAtLogin.swift:57`

**Evidence**:
```swift
func launch(initialSetupRequired: Bool) {
    guard !initialSetupRequired else {
        showConfiguration(from: .initialSetup)
        return
    }
    ensureSearchStarted()
    showSearch()
}
```

**Why it costs / what is missing**: `showSearch()` unconditionally calls `effects.showSearch()` → `panelController.show()`, forcing the `lazy var panelController` (`FloodlightPanelController.init`, `FloodlightPanel.swift:36-102`) to build the NSPanel, run `applyGlassSlabState()` (NSHostingController + SwiftUI first layout + optional NSGlassEffectView), register a local NSEvent monitor and two notification observers, then `show()` (`:196-204`) does `positionOnActiveScreen()`, `NSApp.activate(ignoringOtherApps: true)`, and `makeKeyAndOrderFront`. `LaunchAtLogin.enableOnFirstRun()` (`AppDelegate.swift:35`) is enabled by default, so this runs at every login boot — nobody is waiting for the panel at that moment, and it steals focus.

**Proposal**: Read `notification.userInfo?[NSApplication.launchIsDefaultLaunchUserInfoKey] as? Bool ?? true` in `applicationDidFinishLaunching` and pass it through: `presentation.launch(initialSetupRequired:presentsPanel:)`, defaulted to `true` so the existing double-click-the-app behavior and `ApplicationPresentationCoordinatorTests.swift:8-19` keep working unchanged. When `false`, call `ensureSearchStarted()` only, skip `showSearch()`, and leave the panel to build lazily on the first hotkey/`applicationShouldHandleReopen`. Do NOT add a deferred prewarm — it just moves the same work back onto the first hotkey press, which is the app's headline latency.

```swift
func launch(initialSetupRequired: Bool, presentsPanel: Bool = true) {
    guard !initialSetupRequired else {
        showConfiguration(from: .initialSetup)
        return
    }
    ensureSearchStarted()
    if presentsPanel { showSearch() }
}
```

**Expected impact**: The reliable win is behavioral, not millisecond: no unwanted `NSApp.activate(ignoringOtherApps: true)` focus steal and no panel flash at every login. The 60-200ms figure in the original finding is unmeasured — there is no cold-start benchmark in this repo, and `ensureSearchStarted()` → `SearchCoordinator.start()` already does its warm-up inside an async `Task`, so it was never main-thread boot cost. Treat this as a correctness/UX fix with a plausible but unverified latency side-benefit.

**Effort/Risk**: XS (default-parameter change, test already exists to extend) / low-medium (only risk is misreading the launch-source key and regressing the intentional double-click-to-show path).

**How to verify on Mac**: Enable Launch at Login, reboot, and watch with `log stream --predicate 'subsystem == "com.floodlight.app"' --style compact` — confirm no panel-show signpost fires and no focus steal happens. Add a unit test in `Tests/FloodlightTests/ApplicationPresentationCoordinatorTests.swift` asserting `launch(initialSetupRequired: false, presentsPanel: false)` emits `[.startSearch]` only.

**Caveats from review**: Both skeptics confirmed the mechanism but rejected the ms-range impact claim as unmeasured and self-cancelling with the "pair with a prewarm" suggestion in the original finding (a prewarm just moves the cost to the first hotkey press, which the search-summon latency budget cannot absorb). One skeptic flagged that `effects.hideSearch()` in `showConfiguration`/`searchDidDismiss` also touches `panelController`, so any deferral must not be defeated by an early `hide()`. `OnboardingSession.shouldPresent()` still wins over the new flag, so a login boot with onboarding pending still opens configuration — decide explicitly whether that is wanted.

---

### 3. Clipboard startup window reads every image thumbnail blob eagerly

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift:8-11,63,79,154` (columns and read), `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:69-72` (the call site with the 1,000-row limit)

**Evidence**:
```swift
static let entryColumns = """
id, text, created_at, source_app_bundle_id, pinned_at, kind, \
image_hash, image_width, image_height, image_byte_count, thumbnail_png
"""
```
and (`readEntry`, line 154): `thumbnailPNGData: readBlob(stmt, index: 10) ?? Data()`

**Why it costs / what is missing**: `ClipboardHistoryStore.init` loads up to 1,000 recent rows plus *all* pinned rows (no LIMIT on the pinned query) at construction, and for every `kind == .image` row it copies the thumbnail PNG blob into a heap `Data`. This is reached from `AppDelegate.applicationDidFinishLaunching` → `clipboardCapture.start()` → the lazy `model` (`SearchCoordinator`) construction, on the main thread, at every launch.

**Proposal**: Thumbnails are a fixed 128×128 RGBA PNG (~3-15 KB each, `ClipboardImageCapture.swift:7-8,61`), not the originally-estimated 10-40 KB, and only image-kind rows pay anything — text rows never touch `readBlob`. Two options, in order of preference:
1. **Lower `inMemoryRecentWindowLimit`** (currently 1,000, `ClipboardHistoryStore.swift:10`) to ~200 for the initial load, and page the rest in on first clipboard-mode entry. This removes both the thumbnail cost and the larger (and previously unnoticed) eager `text` read — up to 32 KB per row × 1,000 rows.
2. **Or** defer the whole `ClipboardHistoryStore` construction off `applicationDidFinishLaunching` entirely, so nothing is paid until clipboard capture or clipboard-mode search is actually used.
Do NOT split `entryColumns` into a metadata-only variant with a lazy `thumbnailData(for:)` fetch as originally proposed — `SearchResultProjection.swift:376` and `SearchCoordinator.swift:439,666` read `entry.image?.thumbnailPNGData` for every projected clipboard row on every keystroke (clipboard-mode search reads pinned + all recent rows for an empty query), so a lazy fetch would move up to 1,000 synchronous SQLite blob reads onto the per-keystroke path — worse, not better — and since `thumbnailPNGData` is non-optional, a partial split silently degrades every image row to the generic `photo` icon.

**Expected impact**: Realistic saving is ~0.3-2 MB of resident memory and heap allocation typical, ~4 MB worst case (not the originally claimed 2-8 MB) — this is resident-memory/login-time cost for an `.accessory` launch-at-login agent, not first-frame latency, since the panel isn't shown at launch and the hotkey installs before clipboard capture starts.

**Effort/Risk**: S (lower the limit) to M (defer construction) / low-medium.

**How to verify on Mac**: Populate a temp DB with 1,000 entries (300 image, real 128×128 thumbnails), measure `ClipboardHistoryStore(databaseURL:)` median wall time and heap delta via `xcrun xctrace record --template Allocations --launch Floodlight.app`. Confirm parity with `ClipboardHistoryStoreTests` image round-trip tests after the change.

**Caveats from review**: Both skeptics rejected the primary lazy-fetch proposal as counterproductive (moves cost to the hot per-keystroke path) and corrected the magnitude down substantially (fixed 128×128 thumbnails, image-only rows, not "every row"). Both independently pointed out the eager `text` column (32 KB cap × 1,000 rows) is a comparable or larger uncounted cost in the same code path — worth fixing together. Note `ClipboardHistoryStore.swift:366-372` already re-reads `entryColumns` including thumbnails from SQLite on every ≥3-char keystroke, so this is not launch-only.

---

### 4. Assistant CLI resolution can spawn two uncached login shells

**Where**: `Sources/FloodlightEngine/Search/AssistantProcessRunner.swift:124-152` (`resolveExecutable`, `static func`, no memoization)

**Evidence**:
```swift
guard let loginPath = try? await run(
    executableURL: URL(fileURLWithPath: "/bin/zsh"),
    arguments: ["-l", "-c", "echo -n \"$PATH\""],
    timeout: .seconds(5),
    maxOutputBytes: 64 * 1_024
) else {
    return nil
}
```

**Why it costs / what is missing**: `resolveExecutable` is a bare `static func` with no caching. Both `isAvailable(command:)` and `run(command:)` route through it, so every command miss on the four hardcoded directories re-spawns a fresh login shell — once during `KeywordEngineCatalog.availableRegistry` at startup (looping sequentially over `codex`/`claude`), and again on every actual "Ask Claude"/"Ask Codex" invocation, since `run(command:)` re-resolves too.

**Proposal**: Memoize the login `$PATH` once per process — a `static let pathTask: Task<String?, Never>` (or a small actor) inside `AssistantProcessRunner`, awaited from the shell-spawn site. This is the whole win; both skeptics agreed it should ship alone. Do NOT add UserDefaults persistence across launches (introduces staleness after a CLI install/uninstall for a once-per-login cost) and do NOT switch the `availableEngines` loop to `withTaskGroup` (once the path is memoized, the second lookup is a single `isExecutableFile` stat, and a task group would need re-sorting to preserve the ordered-list assertion in `KeywordEngineInjectionTests.swift:483-492`).

**Expected impact**: `zsh -l -c` is a non-interactive login shell — it does not source `.zshrc`, so oh-my-zsh/starship/nvm/rbenv init blocks (which live in `.zshrc`) never run here; only `.zshenv`/`.zprofile`/`.zlogin` do. Realistic cost is ~30-80 ms per shell on a typical `.zprofile`, not the originally claimed 300ms-2s. This resolution runs concurrently with file/app warm-up (`async let` in `SearchCoordinator.start()`) and gates only the "Ask Claude"/"Ask Codex" keyword rows, not web-mode tabs (those are seeded synchronously from `KeywordEngineCatalog.initialRegistry`). The bigger practical win is on `run(command:)`: a user pressing Enter on an assistant query can pay a login shell before the CLI even starts, which is a warm-path latency issue, not just cold-start.

**Effort/Risk**: S / low.

**How to verify on Mac**: `hyperfine --warmup 2 '/bin/zsh -l -c "echo -n \$PATH"'` for the real per-shell cost. Add `Tests/FloodlightEngineTests/AssistantResolutionPerformanceTests.swift` with a scripted runner counting shell spawns; assert exactly one spawn for N `isAvailable`/`run` calls after the fix.

**Caveats from review**: Both skeptics corrected the magnitude down heavily (non-interactive shell skips `.zshrc`) and both rejected the persistence and `withTaskGroup` parts of the original three-part proposal as unnecessary complexity for negligible additional gain. Neither skeptic found this on any latency-visible path for typed queries — it only delays the two assistant keyword rows appearing.

---

### 5. Application Support directory resolved twice on the construction path

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:173-178`, `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:51-61`

**Evidence**:
```swift
let indexStorage = (try? fileManager.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
).appendingPathComponent("Floodlight", isDirectory: true))
    ?? fallbackStorage
```

**Why it costs / what is missing**: `SearchCoordinator`'s convenience init resolves `applicationSupportDirectory` once; `ApplicationCatalog.init`'s `defaultSupport` computes the same thing again, unconditionally, before its `supportURL ?? defaultSupport` fallback even runs (`ApplicationCatalog.swift:51-61`) — because `defaultSupport` is a `let`, not lazy. `ApplicationCatalog` already accepts a `supportURL: URL? = nil` parameter (used by `CatalogTests.swift:110`) but `SearchCoordinator.swift:190-194` doesn't pass it. Two of the four sites in the original finding do not actually run on this path: `ClipboardHistoryStore`'s resolution branch is dead here (an explicit `databaseURL` is always passed), and `FFFIndex.swift:57-63`'s `??` short-circuits because `storageURL` is always non-nil in both call sites, and it runs on FFFIndex's own background queue during `start()`, not during construction.

**Proposal**: One-line fix — pass the already-existing parameter: `ApplicationCatalog(recentStore: recentStore, blocklistStore: blocklistStore, supportURL: indexStorage, deferDiscovery: true)` at `SearchCoordinator.swift:190-194`.

**Expected impact**: Low. A warm `FileManager.url(...create: true)` call is a search-path lookup plus a stat — microseconds, not the originally claimed "a few ms." The real value is correctness/consistency: today a resolution failure sends the coordinator's file index to a hardcoded fallback (`~/Library/Application Support/Floodlight`) while `ApplicationCatalog`'s failure fallback is `temporaryDirectory/Floodlight` — the two engines could silently disagree about where the app index lives.

**Effort/Risk**: XS / low.

**How to verify on Mac**: `sudo fs_usage -w -f filesys Floodlight | grep -c 'Application Support'` during a launch, before and after — expect one fewer resolution.

**Caveats from review**: One skeptic refuted the finding's headline ("three separate times") outright — only two resolutions actually execute on the construction path, not three or four, and the proposed `FloodlightStorage` type is unnecessary ceremony for a one-line fix. The other skeptic reached the same conclusion independently. Keep this only as a small correctness/consistency cleanup, not a perf item.

---

### 6. Resolved keyword registry waits on the slower of two concurrent awaits

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:225-241`

**Evidence**:
```swift
async let sourceWarmUp: Void = sourceSearch.warmUp()
async let resolvedKeywordRegistry = KeywordEngineCatalog
    .availableRegistry(runner: assistantRunner)
await sourceWarmUp
guard !Task.isCancelled else { return }
sourceWarmUpComplete = true
...
let resolvedRegistry = await resolvedKeywordRegistry
```

**Why it costs / what is missing**: The two `async let`s run concurrently, but `await sourceWarmUp` at line 228 is consumed and its effects applied before `await resolvedKeywordRegistry` — so an assistant registry that resolved quickly sits unapplied until the file/app warm-up finishes, even if the reverse ordering would have been faster.

**Proposal**: Apply each result as soon as it lands, using a structured `withTaskGroup` (not two bare `Task{}` handles, which would lose cancellation via `startupTask?.cancel()`) so the registry assignment doesn't wait on warm-up. Keep the existing `if !query.trimmed.isEmpty { scheduleSearch(immediate: true) }` re-search logic in the warm-up branch — it must not be dropped.

**Expected impact**: Low, and narrower than originally claimed. Web-mode keyword rows and the web-mode tab list are never delayed — they're seeded synchronously from `KeywordEngineCatalog.initialRegistry` at `SearchCoordinator.swift:136`. Only "Ask Claude"/"Ask Codex" rows are affected, and only if the user types the keyword plus a remainder during the launch-time warm-up window. The reorder only helps when CLI resolution is the faster leg (see F53) — when resolution falls back to two serial login shells, it's the slower leg and reordering saves nothing; fixing F53's memoization first is the larger and more certain win.

**Effort/Risk**: S / low.

**How to verify on Mac**: Add a test in `Tests/FloodlightTests` using `ScriptedFileSource` with a 2s indexed delay and a `ScriptedAssistantRunner` that resolves immediately; assert assistant rows are present before the file source completes.

**Caveats from review**: Both skeptics corrected the "web-mode tabs missing" claim as false and flagged that the real fix is F53 (cache the login-shell `$PATH`) since that's what makes the registry leg slow in the worst case; this reorder alone helps only the already-fast case.

---

### 7. Application catalog re-walks and re-names every app, uncached, on every launch

**Where**: `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:333` (`discoverApplications`), `:421-433` (`appendApplication`)

**Evidence**:
```swift
let standardized = url.standardizedFileURL
let canonicalPath = standardized.resolvingSymlinksInPath().path
guard seen.insert(canonicalPath).inserted else { return }
let displayName = fileManager.displayName(atPath: standardized.path)
    .replacingOccurrences(of: ".app", with: "")
```

**Why it costs / what is missing**: `State` is in-memory only; nothing persists across launches. `prepare()` unconditionally re-runs `discoverApplications()` — a `FileManager.enumerator` walk of every app root (`/Applications`, `/System/Applications`, `~/Applications`, all `.applicationDirectory` domain URLs, CoreServices, Finder's embedded apps) — and for every hit does a `realpath` (`resolvingSymlinksInPath()`) plus `FileManager.displayName(atPath:)`, one of Foundation's more expensive per-path calls, then sorts the whole list. This runs off the main thread on a private `discoveryQueue`, but `SourceSearchEngine.execute` publishes its immediate snapshot from `applications.immediatePage` *before* awaiting `ensureStarted()` — so a user typing an app name right after launch can genuinely see it published empty, then filled in on the delayed second snapshot.

**Proposal**: Persist a `Codable` snapshot — `[(name, urlPath)]` in discovery order plus the `applicationDirectoryFingerprint` — to `<AppSupport>/Floodlight/ApplicationIndex/catalog.json`, loaded in `init` (not `start()`, since `execute()` reads `immediatePage` before awaiting `ensureStarted()`). Do NOT persist `markerName`/`id`/`subtitle` — they are pure, order-dependent functions of `(name, url)` computed in `assignMarkerNames`; recompute them on load to avoid drift. Guard against staleness: only trust the snapshot if the marker root exists and its child count roughly matches, else discard and fall back to a full walk — otherwise a cleared `ApplicationIndex/Items` directory with a surviving `catalog.json` would silently leave `indexedItems` permanently empty. Keep the existing walk as the cold path (no valid snapshot) and as the `forceDiscovery`/Rebuild-Index path.

**Expected impact**: Medium, concentrated on first-launch-after-boot (cold page cache) rather than warm relaunches — a normal Mac has ~150-300 `.app` bundles, and warm `displayName` calls are tens of microseconds each, so the warm-launch cost is plausibly 20-60 ms, not the originally claimed "several hundred ms to seconds." The snapshot read is itself a cold-disk read for a single small file versus thousands of stats, so it still wins, just less dramatically on a warm system. Loading in `init` (not `start()`) is required to actually close the race with the first typed query.

**Effort/Risk**: M / medium (as scoped above — smaller than the original L estimate because derived fields are recomputed, not persisted). Chief risk: stale snapshot surfaces an uninstalled app until the walk replaces it, or a marker-directory mismatch is not guarded.

**How to verify on Mac**: Add `Tests/FloodlightEngineTests/ApplicationCatalogStartupPerformanceTests.swift` timing `displayName(atPath:)` over the real `/Applications` contents (`FLOODLIGHT_BENCH app_display_name_us_per_app=`) and a full `ApplicationCatalog.start()` before/after, 5 warmups / 9 samples. Purge cache between runs with `sudo purge` to simulate post-boot conditions.

**Caveats from review**: Both skeptics agreed the mechanism and gap are real but corrected the magnitude down (100-300 apps typical, not 300-1,500; warm cost overstated by roughly an order of magnitude) and reframed the win as concentrated on cold boot rather than every launch. Both independently flagged the same two implementation fixes: persist only `(name, url)` and recompute derived fields (cuts effort from L to M), and load in `init` not `start()` to avoid racing the immediate-page publish at `SourceSearchEngine.swift:238` vs. the `ensureStarted()` await at line 265. One skeptic suggested a cheaper partial fix first: publish `state.applications` before marker sync (`synchronizeMarkers`'s filesystem writes) rather than after, for a fraction of the effort — worth doing regardless of whether the full snapshot lands.

---

### 8. No cold-start signposts or budgeted test exist

**Where**: `Sources/Floodlight/App/AppDelegate.swift:30-38`

**Evidence**:
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installMenu()
    installStatusItem()
    installGlobalHotKey()
    LaunchAtLogin.enableOnFirstRun()
    clipboardCapture.start()
    presentation.launch(initialSetupRequired: OnboardingSession.shouldPresent())
}
```

**Why it costs / what is missing**: `FloodlightPerformance` signposts already exist and are more complete than a first read suggests: `ShowPanel` (`FloodlightPanel.swift:197`), `IndexStartup` (`SearchCoordinator.swift:221-223`), `ApplicationDiscovery`/`ApplicationRefresh` (`ApplicationCatalog.swift:92,109`). What's genuinely missing is (a) an enclosing `AppLaunch` interval spanning `applicationDidFinishLaunching` so those existing sub-signposts can be attributed to a cold start rather than a later refresh, and (b) a marker after `installGlobalHotKey()` for "hotkey now live." There is no `FloodlightPerformance.event(_:)` helper (only `begin`/`end` exist) and no budgeted test for the synchronous share of launch — every existing `FLOODLIGHT_BENCH` line measures steady-state per-keystroke search cost, not startup.

**Proposal**: Add `FloodlightPerformance.event(_:)` next to `begin`/`end`. Wrap `applicationDidFinishLaunching` in an `AppLaunch` interval and emit a `HotkeyRegistered` event after `installGlobalHotKey()`. Do not add `CoordinatorConstructed`/`PanelVisible`/`ApplicationsSearchable` markers — those durations are already recoverable from the existing `IndexStartup`/`ShowPanel`/`ApplicationDiscovery` signposts once `AppLaunch` gives them a common origin.

**Expected impact**: Diagnostic leverage, not a runtime win — makes the synchronous share of launch visible in Instruments and gives every other finding in this section a way to be confirmed or refuted on the maintainer's own machine. A full `ColdStartPerformanceTests.swift` (constructing `SearchCoordinator()` with isolated UserDefaults/support directory) is not straightforward as originally proposed: the live convenience init has no injection seam for UserDefaults or the support directory (hardcodes `UserDefaults.standard` and the real Application Support path), so a naive test would mutate the developer's real Floodlight state. Treat the full test suite as a follow-up requiring API surgery first, not part of this small change.

**Effort/Risk**: XS (signposts) / low. The full test-harness version is M and lower priority.

**How to verify on Mac**: `xcrun xctrace record --template 'App Launch' --launch Floodlight.app --output launch.trace`, read the Points of Interest lane for `AppLaunch`/`HotkeyRegistered`. `log stream --predicate 'subsystem == "com.floodlight.app"' --style ndjson` while launching to get scripted timestamps.

**Caveats from review**: Both skeptics corrected the finding's implication that nothing is signposted — three of four proposed markers already exist. One skeptic pointed out the README's budgeted-test rule is explicitly scoped to per-keystroke engine work, not cold start, so this is a nice-to-have, not a policy violation. Both flagged the proposed test as harder than S effort due to missing injection seams in `SearchCoordinator`'s live init.

---

### 9. SMAppService status/register run synchronously on main, retry forever on failure

**Where**: `Sources/Floodlight/App/LaunchAtLogin.swift:57-77`

**Evidence**:
```swift
func enableOnFirstRun() {
    guard !defaults.bool(forKey: Self.configuredKey) else { return }
    switch service.status {
    case .enabled, .requiresApproval:
        markConfigured()
        return
    case .notRegistered, .notFound:
        break
    @unknown default:
        break
    }
    do {
        try service.register()
        try requireEnabledStatus()
        markConfigured()
    } catch {
        logError(error.localizedDescription)
    }
}
```

**Why it costs / what is missing**: `enableOnFirstRun()` runs synchronously on main between hotkey registration and the panel. The `configuredKey` guard means a *successful* registration costs one UserDefaults read on every subsequent launch — zero XPC. The real cost is confined to (a) the true first launch, and (b) environments where registration permanently fails (unsigned dev builds, app run from `~/Downloads`, MDM-removed item) — the deliberate no-`markConfigured()`-on-failure behavior (documented at `LaunchAtLogin.swift:52-56`, locked by `LaunchAtLoginControllerTests.swift:20-30`) means those environments pay `status` + `register()` + `status` again on every single launch, forever.

**Proposal**: Do not move the call to a background thread naively — `LaunchAtLoginService`/`LaunchAtLoginController` are `@MainActor`, so `Task { @MainActor in ... }` only defers into a later main-actor turn, still blocking main, possibly mid-typing. If pursued, defer only on the non-onboarding launch branch and only until after `showSearch()`, never before `makeConfiguration` seeds the toggle from `LaunchAtLogin.launchesAtLogin` (`AppDelegate.swift:321`) or the onboarding UI shows a stale "off" state. Add a bounded retry policy (attempt counter/timestamp alongside `configuredKey`, stop retrying after N consecutive failures or within 24h) — this changes documented, test-covered behavior, so update `LaunchAtLoginControllerTests.swift` alongside.

**Expected impact**: Low for the shipped, successfully-registered case (already near-zero cost). Medium only for permanently-failing dev/unsigned installs, which is not the shipped user path.

**Effort/Risk**: S / low-medium (the bounded-retry half is a product-behavior change, not a pure perf fix — treat it separately from any deferral).

**How to verify on Mac**: `log stream --predicate 'process == "Floodlight" OR process == "smd"' --style compact` during a fresh (never-configured) launch. Reproduce the failing path by running from `~/Downloads` or an ad-hoc-signed build and confirm the retry repeats every launch.

**Caveats from review**: One skeptic fully refuted the "every launch, forever" framing for the success case (the `configuredKey` guard already makes it near-free) and flagged that `Task { @MainActor in }` doesn't actually move work off main. Both flagged that the bounded-retry policy is a deliberate, tested behavior change requiring `LaunchAtLoginControllerTests.swift` updates, not a drop-in perf fix.

---

### 10. Clipboard prune runs at every launch, single lock shared with clipboard search

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:287-292`, `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:512-527`

**Evidence**:
```swift
private func pruneOnSchedule() {
    let retention = retention
    Task.detached(priority: .utility) { [store] in
        store.prune(retention: retention)
    }
}
```

**Why it costs / what is missing**: `pruneOnSchedule()` runs unconditionally at every `start()` with no persisted last-prune record. `prune` holds the store's single `OSAllocatedUnfairLock` across a `DELETE ... WHERE pinned_at IS NULL AND created_at < ?` (firing FTS5 delete triggers) plus a `SELECT COUNT(*)`. The same lock is taken by `search(query:)` on the main-actor `SearchCoordinator`, so a user entering clipboard mode during the prune blocks briefly behind it. However: `idx_clipboard_created_at` exists, so the DELETE is an index range scan, not a full-table scan — on any relaunch within the retention window it matches zero rows and fires zero triggers. `os_unfair_lock` (which `OSAllocatedUnfairLock` wraps) *does* provide priority donation via kernel thread tracking, so this is a bounded stall from a kernel-boosted background thread, not the "textbook unbounded priority inversion" originally claimed.

**Proposal**: Gate on a persisted `clipboard-last-prune-date` in the existing `defaults`, skip if pruned within 24h, and move the call out of `start()`. Skip the lock-splitting/batching part of the original proposal — not worth the effort for a cost this small. Note a correctness gap the finding surfaces: since prune only runs from `start()`, retention is never enforced while a long-lived login-item process keeps running — consider piggy-backing a periodic prune on the existing 0.5s poll timer at a low frequency instead of only skipping at launch.

**Expected impact**: Low. On same-day relaunch the DELETE already matches ~zero rows; the only unconditional per-launch cost is the `SELECT COUNT(*)`, sub-millisecond to low-millisecond on a bounded 30-day history. The genuinely bigger main-thread clipboard cost is elsewhere: `store.record(text:sourceAppBundleID:)` runs synchronously from the 0.5s main-run-loop poll (`ClipboardCaptureService.swift:283`) on every clipboard change, under the same lock, doing a SQLite insert plus FTS trigram trigger over up to 32 KB of text — a recurring cost, not a once-per-launch one.

**Effort/Risk**: S / low.

**How to verify on Mac**: Populate a temp DB with 20,000 entries older than the cutoff, launch, immediately hotkey + Tab into clipboard mode while running `xcrun xctrace record --template 'System Trace'`; check the Thread State track. Confirm `idx_clipboard_created_at` exists via `sqlite3 clipboard.sqlite3 '.schema clipboard_entries'`.

**Caveats from review**: One skeptic refuted the "unfair lock offers no priority donation" claim outright — it does, by design. Both corrected "full-table DELETE" to "index-backed range scan, typically zero rows." One skeptic identified the recurring `store.record` call on the main poll thread as the actually-larger, previously-uncounted cost in the same file. Impact downgraded to low by both; the lock-splitting/batching half of the original proposal is not worth the M/L effort it would take.

---

### Lower-priority items (largely refuted or minor)

**F56 — System settings discovery builds a Bundle per appex (`SystemCatalog.swift:471`)**: Mechanism real, but `refreshIfNeeded` runs off the main thread concurrently with file/app warm-up, so it costs background CPU/resident memory, not perceived latency; and `shouldIndex` filters before the expensive `localizedInfoDictionary` read, so only a few dozen bundles (not "several hundred") pay the full cost. Built-in settings are seeded synchronously at construction, so "searchable immediately" barely applies. If touched at all, replace `Bundle(url:)` + `bundleIdentifier` with a direct `Info.plist` read (`NSDictionary(contentsOf:)`) before the `shouldIndex` filter — effort S, framed as memory hygiene, not a cold-start win.

**F67 — Menu bar icon SVG decode (`FloodlightMenuBarIcon.swift:6`)**: The asset is 418 bytes with two paths; decode cost is tens of microseconds, unmeasurable. The hotkey already registers third of six launch steps, before every genuinely expensive call. Reordering `installGlobalHotKey()` first is harmless but doesn't remove work — it just shifts the (larger) `SearchCoordinator` construction earlier. Not worth a dedicated change.

**F65 — QuickLook/ServiceManagement frameworks linked eagerly (`Package.swift:50-56`)**: All four frameworks live in the dyld shared cache (pre-mapped); the `.linkedFramework` lines are redundant with Swift's own autolinking from the `import` statements, so removing them changes nothing. `ServiceManagement` actually IS touched at launch (via `LaunchAtLogin.enableOnFirstRun()`), contradicting the original framing. The one cheap, safe experiment: add `-Xlinker -dead_strip` next to the existing `-dead_strip_dylibs` and re-measure `FLOODLIGHT_BENCH binary_size_bytes` — keep only if it measurably shrinks the binary; this affects binary size, not launch time (unreferenced code is never faulted in).

**F62 — FFF index configured for home-directory scan + content indexing + binaries (`FFFIndex.swift:699-709`)**: Genuinely the largest-magnitude unknown in this section, but the actual value depends entirely on unresolved facts about FFFKit 0.2.1's internals (does the index persist across launches? does content indexing eagerly read file bytes at scan time, or only at query time via `fff_live_grep`?) that cannot be answered by reading this repo — FFFKit ships as a binary/source dependency with no vendored sources here. The proposed "lazily enable content indexing on first content-eligible query" is very likely infeasible: options are only applied at instance creation (`fff_create_instance_with`), and the only rescan primitive (`fff_restart_index`) takes a path, not options — flipping a flag live would mean tearing down and rebuilding the whole index, which is worse than doing nothing. Do not implement any specific fix here before the research below resolves the open questions; if anything is tried in the interim, prefer not blocking on the scan (publish partial file results while `progress().isScanning`) over reconfiguring flags blindly.

### Rejected ideas

- **F51** (clipboard capture forces SearchCoordinator + SQLite onto main before the panel): the causal chain was wrong — `installGlobalHotKey()` already forces `SearchCoordinator` construction one line *before* `clipboardCapture.start()`, so the proposed fix (defer clipboard's store dependency) is a no-op for cold start. The underlying SQLite-open cost is real but must be attacked at the coordinator's construction site, not here.
- **F57** (FFF progress poll loop blocks "first results searchable" for up to 2s): refuted — app/settings results already publish from `immediatePage` before any `ensureStarted()` await, so typed queries are never blocked by this poll; the polled index here is a small marker directory (tens of files), not the user's file tree, so the loop finishes in single-digit ms in practice, and the 200×10ms figure is an unreached safety ceiling.
- **F66** (clipboard poll timer arms even when disabled): refuted as proposed — the disabled branch already short-circuits in `poll()` before touching the pasteboard, so the cost is already near-zero; worse, the proposed fix routes through a dead setter (`isEnabled`'s setter has zero callers — the real toggle, `OnboardingSession.clipboardHistoryEnabled`, writes UserDefaults directly and never sees the service instance), so implementing it as written would silently break re-enabling the feature without a relaunch.
- **F64** (SwiftUI App lifecycle + empty Settings scene at launch): refuted — the `Settings { EmptyView() }` scene body is never evaluated since the window is never opened, and `AppDelegate` overwrites the entire SwiftUI-merged menu with its own hand-built `NSMenu` anyway, so the "wasted work" is negligible allocations. The proposed `main.swift` rewrite is riskier than stated: 30+ test files `@testable import Floodlight`, and changing the entry point changes how SwiftPM links the test target.


# Responsiveness

## Responsiveness: UI and main thread

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F68 | Memoize `clipboardInspector` (SQLite + full-res blob + Launch Services on every body eval) | High (image entries) / Medium (others) | S–M | Low–Medium | Confirmed |
| 2 | F69 | Cap clipboard row projection instead of mapping up to 1,000 rows per keystroke | Medium | S | Low | Confirmed |
| 3 | F72 | Move image-capture decode/thumbnail/hash/blob-write off the main-thread poll timer | Medium | S (partial) / M (full) | Low–Medium | Confirmed |
| 4 | F84 | Fix stale thumbnail flash in `FileMediaPreview` (no nil-on-miss, no cancellation guard) | Medium | S | Low | Confirmed |
| 5 | F75 | Cache decoded clipboard thumbnails; stop feeding the inspector full-res PNG | Medium | S (row cache) / M (inspector) | Low | Confirmed |
| 6 | F71 | Async + negative-cache `AppIconCache` (blocking Launch Services call in SwiftUI body) | Low–Medium | S | Low | Confirmed |
| 7 | F76 | Hoist `DateFormatter`s in `ClipboardInspector.formattedDetailedDate` | Low | S | Low | Confirmed (fold into F68) |
| 8 | F77 | Mount results container before first keystroke to avoid resize-animation collision | Unmeasured | M | Medium–High | Plausible (split vote) |
| 9 | F79 | Precompute byte-count/date strings for `ResultRow` instead of formatting per render | Low | — | — | Plausible (refuted by both skeptics) |
| 10 | F81 | Move context-menu/accessibility-string construction behind row `.equatable()` | Low | — | — | Plausible (refuted by both skeptics) |
| 11 | F82 | Drop `Array(model.results.enumerated())` on macOS 14/15 | Low | — | — | Plausible (refuted by both skeptics) |
| 12 | F83 | Precompute filter-chip count strings, make chip `.equatable()` | Low | — | — | Plausible (refuted by both skeptics) |

Ranking is by impact/effort with confirmed findings first. F79/F81/F82/F83 are kept in the table because they were formally "plausible" (not dropped), but both skeptics on each converged on "real mechanism, negligible value" — treat them as low priority, not as a to-do.

---

### F68 — Memoize the clipboard inspector snapshot

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:646-655`

**Evidence**:
```swift
var clipboardInspector: ClipboardInspector? {
    guard isClipboardMode, let selectedItem, let entryID = clipboardEntryID(from: selectedItem)
    else {
        return nil
    }
    guard let entry = clipboardStore.entry(id: entryID) else { return nil }
    let png = entry.kind == .image ? clipboardStore.imageData(for: entryID)?.png : nil
    return ClipboardInspector.snapshot(for: entry, imagePNG: png)
}
```

**Why it costs / what is missing**: This is an unmemoized computed property, read from two places in the view tree (`ClipboardInspectorPane`, `SearchView.swift:220`, and `ClipboardFooterBar.targetAppName`, `SearchView.swift:470`) — so at least twice per body pass, and `@Observable` invalidates it on every keystroke and arrow key in clipboard mode via `selectedItem` → `publication`. Each call does, synchronously on the main actor: an unfair-lock + linear-scan-then-SQLite `entry(id:)`; for images, `imageData(for:)` — which issues an **uncached, unprepared** `sqlite3_prepare_v2`/`finalize` `SELECT` that materializes **both** `png_data` and `tiff_data` (up to two ~15 MB blobs, one discarded by the caller); `ClipboardInspector.snapshot`'s unconditional `NSWorkspace.shared.urlForApplication` (Launch Services XPC) and two `DateFormatter` allocations, run **before** the kind switch — so every entry kind pays these, not just images; plus, for text entries, three full O(n) scans (`text.count`, `countWords`, `countLines`) over up to 32 KB.

**Proposal**: Skip the full stored-property/async-image rearchitecture (the second skeptic showed the refresh-site list is incomplete — `publication` is reassigned at 13 sites, not 4). Instead, memoize inside the getter:
```swift
@ObservationIgnored private var inspectorCache: (entryID: String, generation: Int, value: ClipboardInspector)?

var clipboardInspector: ClipboardInspector? {
    guard isClipboardMode, let selectedItem, let entryID = clipboardEntryID(from: selectedItem) else { return nil }
    if let c = inspectorCache, c.entryID == entryID, c.generation == clipboardGeneration { return c.value }
    guard let entry = clipboardStore.entry(id: entryID) else { return nil }
    let png = entry.kind == .image ? clipboardStore.imageData(for: entryID)?.png : nil
    let snapshot = ClipboardInspector.snapshot(for: entry, imagePNG: png)
    inspectorCache = (entryID, clipboardGeneration, snapshot)
    return snapshot
}
```
Bump `clipboardGeneration` in `togglePin`/`delete`/`clear`/capture. Add `var clipboardSourceAppName: String?` (or read from the cached snapshot) so `ClipboardFooterBar` doesn't need its own recompute. For the image byte cost specifically: never fetch the full-resolution blob for the metadata half — render `entry.image?.thumbnailPNGData` in the inspector's preview (it's already capped at 180pt / 360px on Retina, so raise `thumbnailPointSize` if fidelity matters, don't silently downgrade to the 128px thumbnail as originally proposed) or load the full PNG asynchronously in a `Task` gated on `entryID != lastInspectedEntryID`.

**Expected impact**: For image entries: removes up to two ~15 MB SQLite blob reads, an uncached prepare/finalize, and an `NSImage` decode per selection-change render — potentially tens of ms. For all entries: removes one Launch Services XPC round trip and 2 `DateFormatter` allocations per body eval (was previously mis-scoped to image entries only — it hits every kind). Non-image entries were already sub-millisecond; don't oversell impact there.

**Effort/Risk**: S–M / Low–Medium. Two existing tests read `clipboardInspector` synchronously right after a selection change (`Tests/FloodlightTests/SearchCoordinatorClipboardModeTests.swift:425-441`, `SearchViewRenderingTests.swift:165`) — the memoized-getter approach keeps this synchronous and satisfies them without changes; a stored-property/async approach would not.

**How to verify on Mac**:
```
xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/Floodlight
```
Enter clipboard mode, hold arrow-down through 30+ entries including several 4+ MB screenshots. Look for `sqlite3_step`/`NSWorkspace urlForApplication` frames on the main thread — should collapse to one per newly-selected entry, zero on repeat.

Add `Tests/FloodlightTests/ClipboardInspectorPerformanceTests.swift`: seed 1,000 entries (50 images, ~4 MB PNGs), warm up 5x, 11 samples of 100 iterations of `_ = coordinator.clipboardInspector` for a fixed selection (cache-hit path). Print `FLOODLIGHT_BENCH clipboard_inspector_us=…`, assert `< 200`.

**Caveats from review**: Both skeptics confirmed the mechanism; corrections folded in above are (1) two blobs read, not one; (2) uncached prepared statement; (3) Launch Services/DateFormatter cost hits every entry kind, not just images, but the "tens of ms" estimate applies only to image entries — non-image cost is sub-millisecond and dominated by the DateFormatter, not disk I/O; (4) the "never fetch full-res, only use 128px thumbnail" sub-proposal was flagged as a visible regression (inspector renders at up to 360px Retina) and is corrected above; (5) the `@concurrent nonisolated` plumbing suggestion is unnecessary — `ClipboardHistoryStore` is already callable off-main; (6) the original stored-property refresh-site list (4 sites) is incomplete (actually 13) — the memoized-getter approach sidesteps this entirely and is the recommended path.

---

### F69 — Cap clipboard row projection

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:196-199` (root cause); `:299-300` (one symptom — the `fileExists` stat)

**Evidence**:
```swift
private static func projectClipboard(_ context: ClipboardContext) -> SearchResultPublication {
    let rows = context.entries.enumerated().map { index, entry in
        buildClipboardRow(entry: entry, index: index, now: context.now)
    }
    ...
```
and, inside `buildClipboardTextRow`:
```swift
let exists = FileManager.default.fileExists(atPath: localURL.path)
```

**Why it costs / what is missing**: `ClipboardHistoryStore.search(query:)` returns `pinnedEntries + recentEntries` **uncapped** for the empty query and for 1–2 character queries (up to `inMemoryRecentWindowLimit = 1_000`); only 3+ character queries hit the FTS path, which is capped at `searchResultLimit = 200`. `publishClipboardModeResults` calls this synchronously on the main actor on every keystroke (no debounce, unlike the local-search path which hops to a `Task`), and `projectClipboard` maps a `SearchItem` for every returned entry, not just the ~7 visible. Each text row that parses as a local path pays a synchronous `stat(2)`. The dominant *string* cost per row is not JSON parsing (that's guarded by cheap prefix checks) but repeated full-string `trimmingCharacters` calls (`parseLocalPath`, `parseURL`, `parseHexColor`, `parseCodeHint`, each re-trimming up to 32 KB) plus `previewTitle`'s split/join. The whole `pinnedEntries + recentEntries` array is also copied under a lock before projection even starts.

**Proposal**: Filter by the selected filter **first**, then cap to the existing `maxResultsLimit` (already 80, used by the local-search path) before building rows — not the store's empty-query return, and not a 7-row cap (the list is scrollable and `clipboardFilterOptions` needs the *full* entry set for accurate counts, so don't truncate the source array, only the mapped-row output). Drop the `fileExists` call from the query path — `buildClipboardFileRow` already sets `fileURL` unconditionally with no existence check; make `buildClipboardTextRow` consistent (downstream consumers, e.g. `ResultRow`'s async `.task`, are already tolerant of a stale/missing path). Trim each entry's text once per row and pass the trimmed string into the parse helpers instead of each one re-trimming.

**Expected impact**: Per-keystroke clipboard-mode work becomes bounded (≤80 rows) instead of proportional to history size (≤1,000) for empty/short queries. Removes hundreds of synchronous stats in that regime; 3+ character queries were already capped at 200 by the store, so the win there is smaller.

**Effort/Risk**: S / Low (downgraded from the original M/medium — a per-entry-id memoization cache was proposed originally but adds invalidation complexity — `isPinned` and `now` both feed into cached fields — for little extra benefit once the row count is bounded; skip it).

**How to verify on Mac**: Seed 1,000 clipboard entries (300 real paths, 100 ~20 KB JSON blobs). Type one character in clipboard mode with:
```
sudo fs_usage -w -f filesys Floodlight
```
Count `stat64` lines per keystroke before/after. Add `Tests/FloodlightTests/ClipboardProjectionPerformanceTests.swift`: 11×20 iterations of `SearchResultProjection.project(.clipboard(context))`, print `FLOODLIGHT_BENCH clipboard_projection_us=… entries=1000`.

**Caveats from review**: Both skeptics confirmed the mechanism but corrected the magnitude sharply: the ~1,000-row worst case applies only to empty and 1–2 character queries, not to every keystroke (3+ chars are already capped at 200). "~1,000 JSON-parse attempts" was refuted — JSON parsing is prefix-guarded and rare; the real per-row cost is redundant string trimming. One skeptic flagged the original memoization-cache proposal as having a subtly wrong invalidation rule (title/icon depend on `isPinned`) and recommended the simpler cap-and-trim-once fix instead, which is what's proposed above. A larger, separate cost was flagged in passing: `clipboardStore.search` itself runs a synchronous SQLite FTS prepare/step loop under a lock on the main actor for 3+ character queries — worth its own investigation if this fix doesn't fully resolve keystroke latency in clipboard mode.

---

### F72 — Move clipboard image capture off the main-thread poll timer

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:266-277` (call site); `Sources/Floodlight/Search/ClipboardImageCapture.swift:19-23, 51-107` (actual cost)

**Evidence**:
```swift
if let image = ClipboardImageCapture.payload(from: observer) {
    store.recordImage(
        pngData: image.png,
        tiffData: image.tiff,
        thumbnailPNGData: image.thumbnailPNGData,
        ...
    )
    return
}
```

**Why it costs / what is missing**: `poll()` runs on `RunLoop.main` in `.common` mode every 0.5s; `ClipboardImageCapture` is `@MainActor`. On an image copy, `payload(from:)` unconditionally reads **both** `pngData()` and `tiffData()` from the pasteboard before capping — for a full-screen Retina screenshot this means an ~80 MB uncompressed TIFF is pulled across the pasteboard on the main thread only to be discarded by the 15 MB cap. Then: `NSBitmapImageRep(data:)` full decode, an offscreen `NSGraphicsContext` draw to 128×128, PNG encoding, a SHA-256 over the full primary blob, and a synchronous SQLite `INSERT` binding up to two ~15 MB blobs — all inline, all before `poll()` returns.

**Proposal**: Two-part fix, ordered by leverage:
1. **(S, do first)** Make the TIFF pasteboard read lazy — only fetch `tiffData()` when `png` is nil or oversized. This alone likely removes the largest single main-thread transfer (the discarded 80 MB TIFF) with zero behavior change; existing tests (`pollRecordsTIFFWhenPNGIsAbsent`, `pollKeepsTheValidRepresentationWhenTheOtherExceeds15MB`) already only exercise the png-absent/oversized paths.
2. **(M)** Replace `NSBitmapImageRep` + `NSGraphicsContext` with ImageIO: `CGImageSourceCopyPropertiesAtIndex` for width/height (no decode), `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways` + `kCGImageSourceThumbnailMaxPixelSize: 128` for the thumbnail (never decodes the full-resolution image). This is documented thread-safe, sidestepping the main-actor-vs-background question. Then offload only the residual SHA-256 + SQLite insert to a background `Task` (`ClipboardHistoryStore` is already `@unchecked Sendable` with its own lock) — this needs an injectable completion seam since 27 call sites in `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` assert against the store synchronously right after `poll()`.

Do **not** pursue the original proposal's UserDefaults-caching sub-fix — in-process reads are effectively free and caching risks going stale against `OnboardingSession`'s independent writes to the same key.

**Expected impact**: Removes a worst-case tens-of-milliseconds main-thread stall on every image copy (this is a hitch, not a steady-state cost — `poll()` early-exits on unchanged `changeCount`). Directly improves worst-case hotkey-to-first-frame latency when a screenshot and a summon land within ~500ms of each other.

**Effort/Risk**: S (lazy TIFF) then M (ImageIO + offload) / Low then Medium — the offload's risk is concentrated in the test-seam change, not the imaging logic.

**How to verify on Mac**:
```
xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/Floodlight
```
Take a full-screen screenshot (⇧⌘3), wait 1s, inspect the main thread around the poll for `NSBitmapImageRep`/`representation(using:.png)`/`CC_SHA256` frames and their duration; repeat after each fix stage. Add a capture-time performance test feeding `ClipboardImageCapture.payload(from:)` a 4000×3000 PNG fixture, 11×5 iterations, print `FLOODLIGHT_BENCH clipboard_image_capture_us=…`. No budgeted test currently exists for this hot path — add one per the README's "not done until it has a budgeted test" rule.

**Caveats from review**: Both skeptics confirmed the mechanism. Corrections: the finding originally said "two multi-megabyte blobs" for one image — actually up to ~30 MB (png + tiff) can be bound in the INSERT. The main-thread pasteboard transfer itself is uncapped until *after* the data crosses the boundary — the original "hand raw Data to a `@concurrent nonisolated` function" proposal doesn't fix this by itself, which is why the lazy-TIFF-read fix is now sequenced first. One skeptic identified the ImageIO rewrite as a better fix than moving the existing AppKit code off-main, since it avoids the full-resolution decode entirely rather than just relocating it, and sidesteps thread-safety questions around `NSGraphicsContext.current`. This is a per-image-copy hitch, not a per-keystroke cost — impact is medium, not high.

---

### F84 — Fix stale thumbnail flash in FileMediaPreview

**Where**: `Sources/Floodlight/UI/ClipboardInspectorPane.swift:290-301` (task); `:299` (the unguarded assignment)

**Evidence**:
```swift
.task(id: url) {
    let ext = url.pathExtension.lowercased()
    let videoExtensions: Set = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg",
    ]
    isVideo = videoExtensions.contains(ext)
    if let cached = FileThumbnailCache.shared.cachedThumbnail(for: url) {
        thumbnail = cached
    } else {
        thumbnail = await FileThumbnailCache.shared.thumbnail(for: url)
    }
}
```

**Why it costs / what is missing**: When `url` changes, SwiftUI cancels the old task and starts a new one, but `@State thumbnail` retains the previous image for the whole `QLThumbnailGenerator` round trip on a cache miss — so arrowing through image/video clippings shows the *previous* entry's picture attached to the *new* entry's filename and metadata. There's also no `Task.isCancelled` guard, so a slow generation that resolves after the user has moved on overwrites a correct, newer thumbnail with a stale one. `ResultIcon` (`ResultRow.swift:218-231`) already gets this right: nil-on-miss, cancellation check before assigning.

**Proposal**: Mirror `ResultIcon`'s shape — set `thumbnail = nil` before awaiting on a cache miss, and `guard !Task.isCancelled else { return }` before assigning the loaded image. Separately (not for perf, for correctness): drop the locally-rebuilt `videoExtensions` set entirely — `ClipboardInspector.FileDetail` already carries a classified `isVideo`; pass it in instead of reconstructing extension sets in three places (this file, `ClipboardInspector.swift:218-225`, `FileThumbnailCache.swift:40-46`), which also fixes a latent bug where `ClipboardInspector` treats `.svg` as an image extension but `FileThumbnailCache` doesn't, leaving SVG clippings permanently blank.

**Expected impact**: Removes a visible stale-image flash on every clipboard selection change (a mismatch a user can act on — e.g. Quick Look or drag the wrong file) and a last-write-wins race on slow QuickLook generations.

**Effort/Risk**: S / Low.

**How to verify on Mac**: With clipboard history containing several large images and videos, hold arrow-down and screen-record (⇧⌘5) at 60fps; step through frames looking for the preview image disagreeing with the filename below it. After the fix, the preview should go blank momentarily rather than show stale content.

**Caveats from review**: One skeptic corrected the original proposal's secondary suggestion (an in-flight-request coalescing table in `FileThumbnailCache`) as unnecessary — only one `FileMediaPreview` exists at a time, so there's no real concurrent-duplicate-request problem, just the overlap of one cancelled request. Keep the fix scoped to the nil-on-miss + cancellation guard plus the extension-set consolidation.

---

### F75 — Cache decoded clipboard thumbnails; fix inspector full-res read

**Where**: `Sources/Floodlight/UI/ResultRow.swift:193-197` (row decode); `Sources/Floodlight/Search/SearchCoordinator.swift:653` (inspector's sync blob read — the higher-severity half)

**Evidence**:
```swift
case let .thumbnail(data):
    if let image = NSImage(data: data) {
```
and, in the inspector path:
```swift
let png = entry.kind == .image ? clipboardStore.imageData(for: entryID)?.png : nil
```

**Why it costs / what is missing**: `ResultIcon.body` decodes the row's 128×128 PNG thumbnail with `NSImage(data:)` on every body evaluation with no cache (contrast the `.inferred` branch on the same file, which does go through `FileIconCache` async). This recurs on scroll-in under `LazyVStack` and whenever the clipboard projection rebuilds a row (e.g. its relative-time subtitle changes). The costlier half, flagged by both skeptics as the actual severity driver, is the inspector: `SearchCoordinator.swift:653` performs a synchronous SQLite blob read of the **full-resolution** PNG on every `clipboardInspector` body evaluation (see F68), which `ClipboardInspectorPane.swift:145` then decodes for a view capped at 180pt — i.e. this finding and F68 describe the same root cause from two angles and should be fixed together.

**Proposal**: Add a small `@MainActor NSCache<NSString, NSImage>`-backed `ClipboardThumbnailCache` keyed by `item.id` (no engine model change needed — rows already carry `id: "clipboard:\(entry.id)"`), and have `ResultIcon` resolve `.thumbnail` through it with a `@concurrent nonisolated` decode loader, mirroring `FileIconCache`. Do **not** change `SearchItemIconSource.thumbnail(Data)` to carry an id instead of bytes — `Data` is COW, so the claimed array-copy savings don't materialize, and it would require touching the engine model and existing tests for no gain. For the inspector, fix via F68's memoization (which removes the full-res read entirely on repeat selections) rather than as a separate change.

**Expected impact**: Removes N PNG decodes per clipboard-list scroll (small — single-digit rows, cheap 128px decodes) and, via F68, removes the large full-resolution decode from the inspector's repeat-render path. Treat the row-level fix as low-impact polish; the inspector half is where the real cost is, and it's already covered by F68.

**Effort/Risk**: S (row cache, standalone) / already covered by F68 (inspector half). Low risk either way.

**How to verify on Mac**: Enter clipboard mode with ≥50 image entries, scroll the list while recording Time Profiler; `NSImage(data:)` on the main thread should drop to zero for already-decoded rows. Confirm the inspector fix via F68's verification steps.

**Caveats from review**: Both skeptics identified the same priority inversion: the finding leads with the row decode (minor) when the inspector's synchronous full-res SQLite read (major) is the real defect and is better captured by F68. Two claims in the original finding were refuted outright: "shrinks every projection array copy" (false — `Data` is COW, no copy cost) and "removes multi-kilobyte memcmps from `SearchItem ==`" (real but immaterial, ~1µs). Recommend tracking this as a small addendum to F68 rather than a separate work item.

---

### F71 — Async + negative-cache AppIconCache

**Where**: `Sources/Floodlight/UI/AppIconCache.swift:14-27`; call site `Sources/Floodlight/UI/ClipboardInspectorPane.swift:245`

**Evidence**:
```swift
func icon(for bundleID: String?) -> NSImage? {
    guard let bundleID, !bundleID.isEmpty else { return nil }
    let key = bundleID as NSString
    if let cached = cache.object(forKey: key) {
        return cached
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else {
        return nil
    }
    let image = NSWorkspace.shared.icon(forFile: appURL.path)
```

**Why it costs / what is missing**: `AppIconCache` is the only one of the three UI icon/thumbnail caches (`FileIconCache`, `FileThumbnailCache` being the other two) with no async path — it's called directly from `ClipboardInspectorPane.sourceAppValue`, a view-builder method, so a cache miss blocks the frame drawing the inspector with a synchronous Launch Services XPC call plus an icns decode. The compounding issue both skeptics converged on: **a failed lookup is never cached** — for any bundle ID Launch Services can't resolve (uninstalled/relocated app), the blocking call re-runs on **every** body evaluation, and since `clipboardInspector` (F68) is read on every keystroke/arrow-key in clipboard mode, an unresolvable bundle ID re-pays the XPC cost continuously, not just once per newly-seen app.

**Proposal**: Add a negative-cache marker (e.g. `NSNull` sentinel) so an unresolvable bundle ID is looked up once, not repeatedly. Give `AppIconCache` the same shape as `FileIconCache`: a synchronous `cachedIcon(for:)` fast path plus an `async icon(for:)` with a `@concurrent nonisolated static` loader; extract `sourceAppValue`'s icon rendering into a small `SourceAppIcon: View` struct that seeds `@State` from `cachedIcon` and fills in via `.task(id: bundleID)`, mirroring `ResultIcon` (`ResultRow.swift:183-231`) — necessary because `sourceAppValue` today is a method, not a `View` struct, so it cannot hold `@State` directly. Skip the originally-proposed `NSBitmapImageRep` rasterization, `totalCostLimit`, and `countLimit` bump to 256 — none of these are supported by measurement and they're inconsistent with the `FileIconCache` precedent, which caches un-rasterized `NSImage`s successfully at `countLimit = 256` already.

**Expected impact**: Removes one blocking Launch Services XPC + icns decode from the inspector's first frame per newly-seen source app, and — the higher-value part — stops an unresolvable bundle ID from re-paying that XPC call on every keystroke/arrow-key while it's selected.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Build a clipboard history spanning 20+ distinct source apps (include one from an app you then uninstall, to exercise the negative-cache path), enter clipboard mode, arrow through it with Time Profiler running; `_LSCopyApplicationURLsForBundleIdentifier` should appear at most once per bundle ID for the whole session, including the unresolvable one.

**Caveats from review**: Both skeptics agreed the mechanism is real but the originally-stated "500x memory" and "countLimit thrash" justifications don't hold up (`NSWorkspace.icon(forFile:)` returns a lazily-backed multi-rep image; a realistic clipboard history rarely spans >64 distinct apps). The negative-caching gap was flagged independently by the second skeptic as the actually-repeating cost the original finding missed — it's the highest-value part of this fix and is included above.

---

### F76 — Hoist DateFormatters in formattedDetailedDate

**Where**: `Sources/Floodlight/Search/ClipboardInspector.swift:310-325`

**Evidence**:
```swift
static func formattedDetailedDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm:ss"
    ...
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MMM d, yyyy 'at' HH:mm:ss"
```

**Why it costs / what is missing**: One or two fresh `DateFormatter`s per call, unconditional on every `snapshot` call (i.e. 2–4 times per clipboard-mode body eval via the same uncached-computed-property mechanism as F68). Real, but both skeptics agreed it's a minor rider on a call that's already doing far more expensive work in the same function (`FileManager.fileExists`, `resourceValues` stat, and — for images — a synchronous multi-MB SQLite blob read).

**Proposal**: Fold this into F68's fix rather than treating it standalone — memoizing the inspector snapshot removes this cost along with the disk stat and blob read in one place. If done standalone anyway, hoist to `private nonisolated(unsafe) static let` (a plain `static let DateFormatter` fails Swift 6 strict concurrency under this package's `swift-tools-version: 6.4`; precedent exists at `RecentStore.swift:10`), and keep the hardcoded 24-hour format — do **not** switch to `Date.FormatStyle(date:.omitted, time:.standard)` as originally suggested, since that silently changes output to a locale-dependent 12-hour string.

**Expected impact**: Low standalone; effectively free once bundled with F68.

**Effort/Risk**: S / Low (if bundled with F68); Low–Medium if standalone (concurrency-safety caveat above).

**How to verify on Mac**: Covered by F68's verification; no separate benchmark needed.

**Caveats from review**: Both skeptics downgraded standalone impact to low and recommended folding into F68. One skeptic flagged the original proposal's secondary claim about `ResultShowcase.formattedModifiedDate` as factually wrong — that function has zero production callers (only referenced from tests), so there's no per-row cost there to fix; drop it from scope entirely.

---

### F77 — Mount results container before first keystroke (plausible — split vote)

**Where**: `Sources/Floodlight/UI/SearchView.swift:182-192`

**Evidence**:
```swift
var body: some View {
    if !model.query.isEmpty || model.isClipboardMode {
        Divider().opacity(0.45)
        if showsFilterBar {
            SearchFilterBar(model: model)
        }
        resultsContent
            .frame(height: resultsHeight)
    }
}
```

**Why it costs / what is missing**: While idle, this whole subtree — including the `ScrollView`/`LazyVStack` backing views — doesn't exist. The first keystroke simultaneously triggers the first projection, starts the panel's resize animation (60→521pt, not 548pt as the original estimate had it — `FloodlightMetrics.expandedPanelHeight`), and forces SwiftUI to construct the scroll views and filter bar for the first time, all in the same window the resize animation is running.

**Why this is contested**: One skeptic accepted the mechanism as real but noted the resize is dispatched via a `Task { @MainActor in }` hop, not literally the same run-loop turn — "competition" survives, "one turn" doesn't. The other skeptic **refuted the value**: the proposal's own fallback ("keep `resultsContent` gated on `model.results.isEmpty`") means at idle `resultsContent` resolves to `EmptyResultsView`, not `ResultList` — so the actual `ScrollView`/`LazyVStack`/row hierarchy would **still** be built on the first keystroke under the proposed fix; only the filter bar (a handful of chips) would be pre-mounted. That skeptic also flagged accessibility risk (the pre-mounted filter bar would need `.accessibilityHidden` to avoid VoiceOver reading phantom elements on the 60pt idle capsule) and an animation-interaction risk (a new SwiftUI height-animation racing the NSWindow resize, since `SearchResultsSection` has no `transaction { $0.animation = nil }` of its own).

**Proposal**: Before investing in a restructure, measure first (see mac-todo). If the baseline shows a real hitch, prefer the safer variant explicitly offered as an alternative in the original finding: warm the expanded-state hierarchy once off-screen in `FloodlightPanelController.init`, before the first `show()`, rather than mounting a zero-height live container at idle. This prewarms the real `ResultList` (not just the filter bar) and doesn't touch the live view's gating logic or accessibility tree.

**Expected impact**: Unmeasured. Do not commit effort here without the baseline "Animation Hitches" measurement.

**Effort/Risk**: M / Medium–High (raised from the original Medium given the accessibility and animation-interaction risks identified in review).

**How to verify on Mac**: See mac-todo — `xcrun xctrace record --template 'Animation Hitches'`, type one character from idle, read hitch ratio and longest frame.

**Caveats from review**: Split vote. One skeptic confirmed the mechanism with corrections (60→521pt not 60→548pt; resize is a separate main-thread turn via `Task`, not literally the same turn). The other skeptic refuted the *value* of the proposal as originally written — it doesn't prewarm what it claims to (the results list stays gated on `results.isEmpty`, so `ResultList` still builds on the first keystroke either way) — and flagged real accessibility and animation-racing risks in the mount-at-idle approach. Recommendation: measure before implementing either variant; if pursued, use the off-screen-prewarm variant, not the mount-at-idle one.

---

### Rejected ideas

- **F70** — "One monolithic `publication` property invalidates filter bar/inspector/footer on every arrow key": refuted — the cited savings don't exist. `clipboardInspector` and the footer's app name are *inherently* selection-dependent (they read the SQLite entry for the selection), so splitting the observable surface changes nothing about their cost; `ResultList` reads `selectedID` directly regardless of `publication`'s granularity; and the residual saving (a `ForEach` over ~5 filter chips) is immaterial next to the restructuring risk (12+ `publication = ...` assignment sites would need a new sync invariant).
- **F73** — "Search field becomes first responder two run-loop hops late, dropping first keystrokes after hotkey": refuted — the panel is never actually closed (`hide()` only calls `orderOut`), so the text field retains first-responder status across hide/show cycles from the second summon onward; the described defer only matters on first launch or a rare content-controller rebuild, and even then is dwarfed by `NSApp.activate`'s own async activation.
- **F74** — "FileIconCache stores full-resolution icons with no downsample/cost-limit/coalescing": refuted — `NSWorkspace.icon(forFiles:)` returns a lazily-backed multi-rep image (not a forced 512px raster), the list is capped at 7 visible rows so there's no long scroll surface, and the proposal's "drop the redundant second `cachedIcon` probe" would actively introduce an icon-flicker regression.
- **F78** — "AssistantRunSession.cancel() writes nil-over-nil every keystroke, firing a spurious Observation mutation": refuted — the query mutation's own observation registration is already consumed before `cancel()`'s write lands in the same call stack, and the same keystroke already triggers a full publication reassignment regardless, so the "fix" saves a registrar lock, not a render.
- **F80** — "Panel-height Task/observation re-registers every keystroke though height rarely changes": refuted — `resize(to:)` already early-returns on its very first line (a 0.5pt frame-delta guard) before the expensive accessibility read the finding worried about, so the described cost doesn't reach the accessibility call on non-boundary keystrokes; residual cost (one Task alloc, one hop) is noise next to the same-keystroke's full search projection.
- **F79, F81, F82, F83** — kept as "plausible" in the input but both skeptics on each converged on real-mechanism/negligible-value verdicts (sub-microsecond ICU costs already cached by Foundation, ≤8 visible rows, or proposals that don't compile/don't survive target boundaries as written). Not worth separate implementation effort; see table above for one-line status.

## Responsiveness: clipboard runtime

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F91 | Office-app copies (Numbers/Excel/Keynote/Word) recorded as TIFF, text silently discarded | High | S | Medium | confirmed |
| 2 | F89 | "Forever" retention setting is unreachable — silently prunes at 30 days | Medium | S | Low | confirmed |
| 3 | F96 | Every image copy stores both PNG and TIFF, doubling DB growth | Medium | S (core) / M (migration) | Low / Medium | confirmed |
| 4 | F90 | Space in Clipboard mode reads a multi-MB blob and leaks temp files forever | Medium | S | Low | confirmed |
| 5 | F92 | Multi-file copy: N transactions, no dedup, can't be restored as a unit | Medium | S (batch) / L (redesign) | Low / Medium-high | confirmed |
| 6 | F95 | "Paste to <App>" names the wrong app and never actually pastes | High | S (label) / L (real paste) | Low / Medium | confirmed |
| 7 | F88 | Inspector snapshot: uncached LaunchServices lookup + DateFormatter + double stat per render | Medium | S / M (Swift 6 Sendable) | Low | confirmed |
| 8 | F85 | Every clipboard row read pulls the thumbnail BLOB, including the 1000-row launch load | Medium | M | Medium | confirmed |
| 9 | F94 | Every launch reruns 8 ALTER TABLEs and drops/recreates FTS triggers unconditionally | Low | S | Low | confirmed |
| 10 | F93 | Empty-query clipboard search copies the full 1000-entry array on every keystroke | Low-Medium | S / M | Low / Medium | confirmed |
| 11 | F86 | Every clipboard SQL call re-prepares its statement | Low | M | Medium | confirmed |
| 12 | F98 | Clipboard search silently degrades on FTS failure; `clear()` ignores its own error | Low | S | Low | confirmed |
| 13 | F87 | FTS search sorts the full match set before LIMIT 200 | Low-Medium | S / M | Low / Medium | plausible (split) |

---

### 1. F91 — Office-app copies recorded as TIFF, text discarded

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:258` (routing), `:266` (the decisive image branch)

**Evidence**:
```swift
let filePaths = observer.filePaths().compactMap(ClipboardFileReference.canonicalize)
if !filePaths.isEmpty { ... }
if let image = ClipboardImageCapture.payload(from: observer) { store.recordImage(...); return }
// Rule 5: Text exceeds 32,000 UTF-8 bytes -> skip entirely
guard let text = observer.string(forType: .string), !text.isEmpty else { return }
```

**Why it costs / what is missing**: `poll()` routes files -> image -> text, unconditionally. `ClipboardImageCapture.payload` (`ClipboardImageCapture.swift:19-35`) is satisfied by any decodable `.png` or `.tiff` blob under 15 MB and never checks whether `.string`/`.rtf` is also present. Numbers, Excel, Word, Keynote, and most rich-text editors put a rendered TIFF on the pasteboard *alongside* plain text, so copying a table cell or paragraph from those apps records an entry titled "TIFF Image" and the actual text is gone — permanently, since the branch `return`s before the text check ever runs. `payload` also fetches both `pngData()` and `tiffData()` unconditionally, forcing a lazy-promise render from the source app even when only one representation is needed.

**Proposal**: Prefer text when it's declared. In `ClipboardImageCapture.payload` (or the `poll()` call site), skip the image branch when `observer.pngData()` is nil (i.e., only a TIFF exists) **and** a `.string`/`.rtf` representation is present — that isolates the Numbers/Excel/Word case (TIFF-only decoration + text) without breaking real image copies (screenshots, image-editor copies, Preview) which declare no string, or browser image copies which are covered by keeping the "PNG present" branch as image. Keep the PNG->TIFF fallback for size-capped cases (`cappedImageData`) — don't remove the TIFF fetch outright, since `pollKeepsTheValidRepresentationWhenTheOtherExceeds15MB` (`Tests/FloodlightTests/ClipboardCaptureServiceTests.swift:373-389`) depends on it.

```swift
// ClipboardImageCapture.payload — sketch
let hasText = observer.string(forType: .string)?.isEmpty == false
if hasText, observer.pngData() == nil { return nil } // TIFF-only + text present -> let text branch win
```

**Expected impact**: Restores text capture for the entire office-app copy-paste workflow and stops writing multi-MB bitmaps for a line of text.

**Effort/Risk**: S (a guard before the existing image branch, covered by existing test fixtures) / Medium (behavior change on a well-exercised path — verify against `ClipboardCaptureServiceTests` fixtures for both TIFF-only-with-text and TIFF-only-without-text).

**How to verify on Mac**: Copy a Numbers cell range, a Pages paragraph, and a Cmd-Shift-Ctrl-4 screenshot; open Clipboard mode and confirm the first two are text entries, the screenshot is an image. Add cases to `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`: `pasteboardTypes = [.string, .tiff]` with both payloads present -> assert `kind == .text`; `[.png, .tiff]` with no string -> assert `kind == .image`. `swift test --filter ClipboardCaptureServiceTests`.

**Caveats from review**: Both skeptics confirmed the mechanism and impact (high). Corrections: anchor the fix at line 266, not 258 (258 is just the file-routing branch that starts the chain, already correct). The "type-order" variant of the proposal is unreliable — `NSPasteboard.types` order is not a guaranteed API contract — use "TIFF-only + string present" instead of ordering. Watch for a false negative: Safari/Chrome image copies put a URL/alt-text string alongside a PNG; the "PNG present -> still image" branch handles this correctly, but do not extend the text-preference rule to also cover PNG-plus-string cases.

---

### 2. F89 — "Forever" retention silently prunes at 30 days

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:154-170`

**Evidence**:
```swift
var retention: ClipboardRetention {
    get {
        let days = defaults.integer(forKey: Self.retentionDaysDefaultsKey)
        if days > 0 { return .days(days) }
        return .days(30)
    }
    set {
        switch newValue {
        case let .days(days): defaults.set(days, forKey: Self.retentionDaysDefaultsKey)
        case .forever: defaults.set(-1, forKey: Self.retentionDaysDefaultsKey)
        }
    }
}
```

**Why it costs / what is missing**: The setter writes `-1` for `.forever` (and `OnboardingView.swift:319` offers exactly that: `Text("Forever").tag(-1)`, round-tripped faithfully by `OnboardingSession.clipboardRetentionDays`, `OnboardingSession.swift:55-59`). But the getter maps *any* non-positive value, including `-1`, back to `.days(30)`. `.forever` is write-only. `pruneOnSchedule()` (`ClipboardCaptureService.swift:286-292`) reads this property every `start()` and calls `store.prune(retention:)`, so a user who explicitly chose "Forever" still loses unpinned history older than 30 days, silently.

**Proposal**: Make the getter symmetric:
```swift
let days = defaults.integer(forKey: Self.retentionDaysDefaultsKey)
if days > 0 { return .days(days) }
if days == -1 { return .forever }
return .days(30)
```
Better: eliminate the duplicated sentinel decoding entirely — both `OnboardingSession` and `ClipboardCaptureService` hand-decode the same key. Add one `static func retention(fromDefaultsValue:) -> ClipboardRetention` and have both call sites use it, so the two decoders can't drift again.

**Expected impact**: Stops silent deletion of unpinned clipboard history for every user who opted for "Forever." No runtime cost — this is a once-per-launch correctness fix, not a hot path.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Add to `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`: set `service.retention = .forever`, read it back, assert `.forever`; write `-1` directly to the defaults key and assert the same. `swift test --filter ClipboardCaptureServiceTests`. Manual: pick "Forever" in Settings, `defaults read <bundle-id> clipboard-history-retention-days` (expect `-1`), relaunch, confirm entries older than 30 days survive.

**Caveats from review**: Both skeptics confirmed the bug at very high confidence (0.92) but downgraded impact from high to medium: `prune(olderThan:)` (`ClipboardHistoryStore.swift:512-516`) is `WHERE pinned_at IS NULL AND created_at < ?`, so pinned entries are exempt — the loss is bounded to unpinned history, not "everything." Also noted: the `.forever` branch of the *setter* currently has no caller anywhere in `Sources/` besides the Onboarding path, so today the asymmetry is purely between `OnboardingSession` and this getter.

---

### 3. F96 — Every image copy stores both PNG and TIFF

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:186-188, 246-248`

**Evidence**:
```swift
let png = Self.cappedImageData(pngData)
let tiff = Self.cappedImageData(tiffData)
guard let primary = png ?? tiff else { return nil }
...
ClipboardHistorySQLite.bindBlob(stmt, index: 11, data: png)
ClipboardHistorySQLite.bindBlob(stmt, index: 12, data: tiff)
```

**Why it costs / what is missing**: `ClipboardImageCapture.payload` fetches both `observer.pngData()` and `observer.tiffData()` (`ClipboardImageCapture.swift:20-21`) and `recordImage` persists both, each capped at 15 MB. Only `png ?? tiff` is ever used for hash/byte-count/thumbnail, and `writeImage` (restore path) tolerates a nil TIFF — so the second blob is dead weight most of the time. Nothing vacuums the DB (`ClipboardHistorySQLite.swift:15-16` sets only `WAL`/`synchronous=NORMAL`, no `auto_vacuum`), so freed pages never shrink the file. This also forces a lazily-promised TIFF render from the source app on every image copy on the main-actor poll timer.

**Proposal**: Skip `observer.tiffData()` when a PNG is already present:
```swift
guard png == nil else { /* store tiff_data as NULL */ }
```
Keep the existing fallback for TIFF-only sources. Do NOT transcode TIFF->PNG at capture time (would add a 100ms+ main-thread stall on the MainActor poll path — a regression under this exact lens). Follow with a one-time migration `UPDATE clipboard_entries SET tiff_data = NULL WHERE png_data IS NOT NULL` plus a full `VACUUM` off the main actor (no `incremental_vacuum` available since `auto_vacuum` was never enabled at table creation).

**Expected impact**: Cuts the dominant blob for mid-size images (TIFF is typically 5-20x the PNG) and removes one forced pasteboard render per image copy. Large/Retina screenshots already lose their TIFF to the 15 MB cap today, so the saving is concentrated on everyday screenshots, not full-screen grabs.

**Effort/Risk**: S for the core capture-side guard (covered by existing `ClipboardHistoryStoreTests.swift:396-576`) / M for the migration + VACUUM. Risk Low (core) / Medium (migration on a live user DB).

**How to verify on Mac**: `sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 "SELECT SUM(LENGTH(png_data)), SUM(LENGTH(tiff_data)) FROM clipboard_entries;"` before/after. Add a `ClipboardHistoryStoreTests` case: record an image with both PNG and TIFF available, assert `tiff_data IS NULL` and `imageData(for:)` still returns a usable PNG.

**Caveats from review**: Both skeptics downgraded impact from high to medium and corrected the mechanism: the 15 MB cap already discards TIFF for large screenshots (so "up to 30 MB per screenshot" is wrong), and `writeObjects(NSImage)` on restore was explicitly rejected — commit 936926b already fixed a duplicate-pasteboard-item bug from that exact approach; keep `setData(png, forType: .png)` as-is. Drop the CGImageDestination transcode idea entirely (main-thread stall risk). The dedup-by-hash sub-proposal (widen beyond `recentEntries.first`) is a separate, riskier change — no index exists on `image_hash`, and "move to top" mutates `created_at`, affecting retention/pin ordering; track it independently if pursued.

---

### 4. F90 — Space in Clipboard mode reads a multi-MB blob and leaks temp files

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:435-458`; guard order at `Sources/Floodlight/App/FloodlightPanel.swift:291-295`

**Evidence**:
```swift
private func clipboardImagePreviewURL(for id: String) -> URL? {
    guard let payload = clipboardStore.imageData(for: id) ?? clipboardStore.entry(id: id)
    ...
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let fileURL = tempDir.appendingPathComponent("\(id).\(ext)")
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        try? data.write(to: fileURL)
    }
    return fileURL
```

**Why it costs / what is missing**: `FloodlightPanel.handleKeyEvent` evaluates `model.previewableSelectionURL != nil` eagerly as a plain argument before the cheap `isClipboardMode && query.isEmpty` guard runs, so it recomputes on every keyCode-49 (Space) event, not just an actual preview press. That call chain reads a full SQLite blob (up to 15 MB) and performs `createDirectory`/`fileExists`/`write` synchronously on the main thread. The write is idempotent (guarded by `fileExists`), so it isn't re-written per keystroke, but the blob read and directory stat are. Separately: nothing ever deletes files under `NSTemporaryDirectory()/FloodlightClipboardPreviews/` — `deleteSelection()` and `clearHistory()` only touch the DB row, so images the user believes erased persist on disk indefinitely.

**Proposal**: (1) Reorder the guard — check `isClipboardMode && query.trimmed.isEmpty` before computing the preview URL (`@autoclosure` on the parameter, or reorder the boolean expression). (2) Add one memoized `(entryID, ClipboardImagePayload)` cache in `SearchCoordinator`, invalidated on selection change and delete/clear, shared by both `clipboardImagePreviewURL` and `clipboardInspector` (see F88 — they do the identical uncached blob read). (3) Write into a per-launch UUID subdirectory and `removeItem` it in `AppDelegate.applicationWillTerminate`; also remove the specific file in `deleteSelection`/`clearHistory`. Dismiss any active QuickLook panel before unlinking a file it may be displaying.

**Expected impact**: Removes a per-render multi-MB main-thread blob read for selected image entries and stops cleared clipboard images from persisting in `/tmp`.

**Effort/Risk**: S / Low-Medium.

**How to verify on Mac**: Enter Clipboard mode with an image selected, type a sentence with spaces, then `ls -la $TMPDIR/FloodlightClipboardPreviews`. `sudo fs_usage -w -f filesys Floodlight` while typing to see main-thread write/open syscalls. Add a test that `clearHistory()` leaves the preview directory empty.

**Caveats from review**: Both skeptics corrected "decrypted image" to plain "persists on disk" — there is no encryption anywhere in `Sources/`. The write is guarded by `fileExists`, so it fires at most once per entry per temp-dir lifetime, not on every Space press — what repeats per keystroke is the blob read + stat, not the write. Both flagged the bigger, unmentioned sibling cost: `SearchCoordinator.clipboardInspector` does the identical uncached full-blob `imageData(for:)` read on every selection change (arrow-key move), not just Space — fix both through the same cache.

---

### 5. F92 — Multi-file copy: N transactions, no dedup, can't be restored as a unit

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:258-264`

**Evidence**:
```swift
if !filePaths.isEmpty {
    for path in filePaths {
        store.recordFile(path: path, sourceAppBundleID: bundleID)
    }
    return
}
```

**Why it costs / what is missing**: Each `recordFile` takes the store lock, prepares a fresh INSERT, commits its own implicit WAL-append transaction, fires the FTS trigram trigger, and does an `insert(at: 0)` into the 1000-entry window. For a realistic N (2-20 files) this is sub-millisecond; even 200 files is likely low-tens-of-milliseconds under WAL/`synchronous=NORMAL`, not "several hundred milliseconds" as originally estimated. The real cost is product-level: one Finder selection floods the entire visible 1000-entry history with N rows; dedup only compares against the single most-recent entry (`ClipboardHistoryStore.swift:292-296`), so re-copying the same N-file selection re-inserts all N rows every time; and `SearchResultProjection.swift:356` emits `.copyFiles([path])` — a single path — even though `writeFiles(_ paths: [String], ...)` (`SelectedResultActionPerformer.swift:48`) already accepts an array, so a multi-file copy can never be restored as the selection the user actually made. Also note: `ClipboardFileReference.paths(from:)` already canonicalizes each path (`ClipboardCaptureService.swift:36-38, 93-100`) before `poll()` canonicalizes it *again* at line 258 — a one-line redundant-work fix, independent of everything else here.

**Proposal**: (1) Cheap batching: one `stateLock` acquisition, one `BEGIN`/`COMMIT`, one reused prepared statement, one `insert(contentsOf:at:)` — `ClipboardHistoryStore.recordFiles(paths:sourceAppBundleID:date:)`. (2) Delete the redundant double-canonicalize at line 258. (3) Bigger, separate change: store an N-file selection as one history entry (new `kind` or JSON path-list payload) so `SearchItemAction.copyFiles` can restore the whole selection; cap unbounded pasteboards with `filePaths.prefix(n)` rather than a synthetic "summary" entry.

**Expected impact**: Batching alone is a small, low-risk win. The bigger value is correctness/UX: multi-file copies become restorable, and one selection stops flooding the visible history.

**Effort/Risk**: S / Low for batching + the canonicalize fix; L / Medium-High for the multi-path-entry redesign (schema + `ClipboardEntryKind` + projection + inspector + tests).

**How to verify on Mac**: `Tests/FloodlightEngineTests/ClipboardRecordFilesPerformanceTests.swift` — 11 samples of recording 200 paths, `getrusage`, `print("FLOODLIGHT_BENCH clipboard_record_files_ms=…")`. Manual: select 200 files in Finder, Cmd-C with the panel open, watch for a beachball. Add a `ClipboardCaptureServiceTests` case: copy the same 3-file selection twice, assert row count and restorability.

**Caveats from review**: Both skeptics corrected the headline estimate down sharply (WAL + `synchronous=NORMAL` means no fsync per commit; realistic cost is 5-30ms for 200 files, sub-millisecond for typical 2-20 file copies) — this is not primarily a perf finding, it's a correctness/UX one (flooding, missing dedup, non-restorable multi-file copy). Recategorize accordingly. Split effort/risk as above rather than treating it as one M/medium item.

---

### 6. F95 — "Paste to <App>" names the wrong app and never pastes

**Where**: `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:156-163`; label at `Sources/Floodlight/UI/SearchView.swift:469-486`

**Evidence**:
```swift
func activate(_ item: SearchItem, query: String) {
    switch item.action {
    case let .copy(value):
        guard effects.writeToClipboard(value) else { logClipboardFailure(for: item); return }
        onDismiss()
```

**Why it costs / what is missing**: `ClipboardFooterBar` renders `Text("Paste to \(targetAppName)")` where `targetAppName` = `model.clipboardInspector?.sourceApp` — the app the content was copied *from*, not the app the user is returning to paste into. The action itself, for `.copy`/`.copyFiles`/`.copyImage` alike, only writes the pasteboard and dismisses. No `CGEvent`/`AXIsProcessTrusted`/synthetic-keystroke code exists anywhere in the repo. So the promised one-keystroke paste is copy-then-dismiss-then-manual-Cmd-V, with a label naming the wrong application. This is the primary flow for a clipboard manager and the exact feature competitors (Raycast, Alfred, Paste) provide.

**Proposal**: Split into two changes. (a) **Label fix (cheap, do first)**: capture `NSWorkspace.shared.frontmostApplication` immediately before the panel activates (`FloodlightPanel.swift`, `show()`), expose it to the coordinator, and use it — not `sourceApp` — for the footer label. (b) **Real paste (larger)**: after `writeToClipboard` + `onDismiss()`, wait for `NSWorkspace.didActivateApplicationNotification` for the recorded app (don't fire immediately — there's an activation race), then post `CGEvent(keyboardEventSource:virtualKey: kVK_ANSI_V, keyDown:)` with `.maskCommand` on `.cghidEventTap`. Gate behind a preference explaining the Accessibility (`AXIsProcessTrustedWithOptions`) requirement; fall back to today's copy-and-dismiss when the permission is absent. Keep the `.floodlightOwnWrite` marker so the re-paste isn't re-captured by the clipboard poller.

**Expected impact**: (a) alone fixes a visibly wrong label with zero risk. (b) turns the headline Clipboard-mode action from three user steps into one.

**Effort/Risk**: (a) S / Low — ships independently. (b) L / Medium — the risk is the activation race and the TCC permission UX, not the CGEvent call itself (no sandbox entitlements block it; the app has none).

**How to verify on Mac**: Manual timing: screen recording at 60fps, Return -> characters appearing in TextEdit, before/after. `Tests/FloodlightTests` via the `ScriptedActionEffects` seam: assert the performer calls a new `pasteToFrontmost()` effect only when the Accessibility permission is reported present.

**Caveats from review**: Both skeptics confirmed at high confidence (0.85-0.92). Corrections: `NSApp.activate` is at `FloodlightPanel.swift:201`, not 212. The fallback app name when no inspector snapshot exists is literally the string "App" (`SearchView.swift:470`), worth calling out as its own bug. `FloodlightPanelController.hide()` already relies on macOS restoring focus to the previous app on dismiss — explicit re-activation is a robustness measure, not the core mechanism; the real hazard is timing the CGEvent after the target app is actually frontmost. Recommend shipping the label fix (a) immediately and separately from (b).

---

### 7. F88 — Inspector snapshot: uncached LaunchServices, DateFormatter, double stat

**Where**: `Sources/Floodlight/Search/ClipboardInspector.swift:94-99, 310-322, 360-362`

**Evidence**:
```swift
private static func sourceAppDisplayName(for bundleID: String?) -> String {
    guard let bundleID, !bundleID.isEmpty else { return "Clipboard" }
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
```

**Why it costs / what is missing**: `snapshot(for:imagePNG:)` is called from the un-memoized `clipboardInspector` getter (`SearchCoordinator.swift:647-655`), read from two independent views per render pass (`SearchView.swift:220` and `:470`). Every call does an uncached `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` LaunchServices lookup, allocates one or two `DateFormatter`s (one of Foundation's more expensive routine constructions), and for file entries does `FileManager.fileExists` twice plus `resourceValues(forKeys:)` and `hasDirectoryPath` — three filesystem touches, all on the main thread.

**Proposal**: Memoize the whole snapshot in `SearchCoordinator`, keyed on selected entry id — this removes the double-per-pass evaluation and every sub-cost in one change, rather than patching each callee. If done at the callee level instead: use `Date.FormatStyle`/`date.formatted(...)` rather than a hoisted `DateFormatter` static (a bare `static let` `DateFormatter()` will not compile under Swift 6 language mode — not Sendable); add a bundle-id -> display-name cache to `AppIconCache` (making it `@MainActor`, alongside the icon cache it already has); collapse the file-entry stats into one `resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey])` call.

**Expected impact**: A few hundred microseconds per selection change in the warm case (LaunchServices caches its own DB after first hit); low-tens-of-milliseconds on a cold hit or a file entry on a network volume.

**Effort/Risk**: S if memoizing the snapshot; S/M if instead touching `AppIconCache`/`DateFormatter` individually (Swift 6 Sendable plumbing). Risk Low.

**How to verify on Mac**: `Tests/FloodlightTests/ClipboardInspectorPerformanceTests.swift` — 11×200 iterations of `snapshot(for:)` across text/JSON/image/file fixtures, `getrusage`, `FLOODLIGHT_BENCH clipboard_inspector_snapshot_us`. Instruments Time Profiler while holding Down-arrow in Clipboard mode; confirm `-[DateFormatter init]` and `_LSCopyApplicationURLsForBundleIdentifier` frames drop out.

**Caveats from review**: Both skeptics confirmed mechanism and impact (medium, not the originally implied high — LaunchServices is usually warm). The proposed bare `static let timeFormatter = DateFormatter()` will not compile under this repo's Swift 6.4 language mode (non-Sendable global); use `Date.FormatStyle` instead. This finding substantially overlaps F90's "same uncached blob read on every selection change" — fix both through one memoized per-entry cache in `SearchCoordinator` rather than two separate patches.

---

### 8. F85 — Thumbnail BLOB read on every clipboard row load

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:69` (synchronous 1000-row load in `init`), `:366` (search re-read); shared column list at `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift:8-11`

**Evidence**:
```swift
static let entryColumns = """
id, text, created_at, source_app_bundle_id, pinned_at, kind, \
image_hash, image_width, image_height, image_byte_count, thumbnail_png
"""
```

**Why it costs / what is missing**: `entryColumns` always includes `thumbnail_png`; `readEntry` copies it into a fresh `Data` for every image row. `ClipboardHistoryStore.init` opens the DB, migrates, and loads 1000 rows — including thumbnails — synchronously on the main thread during `applicationDidFinishLaunching` (via `SearchCoordinator`'s convenience init, forced by `clipboardCapture.start()`). Per keystroke, `search` only re-reads SQLite for queries >=3 UTF-8 bytes (shorter/empty queries use the resident in-memory arrays with no copy), and only image rows carry a blob — so the "200 thumbnails per keystroke" worst case requires 200 image rows matching one FTS query. The bigger, steady-state cost the finding under-weighted: the 1000-entry in-memory window holds every image's thumbnail `Data` resident for the process lifetime, and `text` (up to 32 KB/row × 1000) is unconditionally loaded too — that's RSS, not just copy cost.

**Proposal**: Split `entryColumns` into a lean set (no `thumbnail_png`) for `search`/`loadInitialWindow`, and load thumbnails lazily through a `@MainActor` cache keyed by entry id (like `FileIconCache`) when a row actually renders. Move store construction off the launch path (`Task` + `await` in `ClipboardCaptureService.start()`), or at minimum open with `SQLITE_OPEN_NOMUTEX` since the store already serializes with `OSAllocatedUnfairLock`.

**Expected impact**: Removes up to 1000 thumbnail copies from launch and up to 200 per matching search; cuts steady-state resident memory for image-heavy histories. On an all-image 200-entry history with ~10 KB thumbnails, ~1-3 MB per search (revised down from the original 2-4 MB estimate).

**Effort/Risk**: M / Medium.

**How to verify on Mac**: `Tests/FloodlightEngineTests/ClipboardStoreStartupPerformanceTests.swift` — seed 1000 entries (300 images, 16 KB thumbnails), close, 11 samples of `ClipboardHistoryStore(databaseURL:)` construction via `getrusage`, `FLOODLIGHT_BENCH clipboard_store_open_us`. `hyperfine --warmup 3 'open -Wn ./.build/release/Floodlight.app'` against a seeded DB. Extend `ClipboardHistoryPerformanceTests` to include image entries with real thumbnails (today it's text-only, so this cost is invisible to the existing budget).

**Caveats from review**: Both skeptics downgraded impact to medium and corrected scope: `entry(id:)` short-circuits on the in-memory pinned/recent arrays first, so drop it from the hot-path list; blobs are copied only for `kind == .image` rows, so a text-dominated history pays nothing; `.thumbnail(Data)` values are not re-copied per publication (same COW buffer). One skeptic flagged a larger unmentioned cost: `text` at up to 32 KB × 1000 rows likely dominates thumbnails for a text-heavy history — trimming `inMemoryRecentWindowLimit` or paging the window may be higher-value than the blob-table split.

---

### 9. F94 — Every launch rewrites the schema unconditionally

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift:50-52, 220-264`

**Evidence**:
```swift
sqlite3_exec(db, schemaSQL, nil, nil, nil)
migrateImageColumns(db: db)
recreateFTSTriggers(db: db)
```

**Why it costs / what is missing**: `initializeSchema` runs unconditionally on every open, on the main thread during launch: the multi-statement schema script (which `CREATE TRIGGER IF NOT EXISTS`s three triggers immediately dropped by `recreateFTSTriggers`), 8 `ALTER TABLE ADD COLUMN`s expected to fail on any already-migrated DB, then a DROP+CREATE of all three FTS triggers. No `PRAGMA user_version` gate exists anywhere. `PRAGMA journal_mode = WAL` is issued inside a batched `sqlite3_exec` with a discarded return, so a silent fallback to rollback-journal mode (e.g. on a network volume) is invisible.

**Proposal**: Delete the dead `CREATE TRIGGER IF NOT EXISTS` blocks from `schemaSQL` — they're always immediately dropped, at zero risk, zero migration-version bookkeeping. Separately, issue `PRAGMA journal_mode = WAL` as its own prepared statement and log via `os.Logger` (already imported) if the returned mode isn't `wal`. Leave the 8 `ALTER TABLE`s alone — a failed duplicate-column ALTER fails at parse time (no write lock, no schema-version bump), so they cost microseconds, not the write-lock cost originally claimed.

**Expected impact**: Low single-digit milliseconds saved, dwarfed by the `loadInitialWindow` thumbnail load next to it (see F85) — the honest value here is deleting genuinely dead code and making a silent WAL fallback observable, not cold-start latency.

**Effort/Risk**: S / Low for the dead-trigger deletion and WAL check. A `PRAGMA user_version` gate around the whole migration path is riskier (medium) — `recreateFTSTriggers` exists specifically to overwrite triggers `schemaSQL` itself installs, so a version gate that's off-by-one leaves stale triggers silently. Skip the version-gate half unless profiling shows it matters.

**How to verify on Mac**: `sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 'PRAGMA journal_mode;'` should print `wal`; check `-wal`/`-shm` sidecars exist. Wrap `initializeSchema` in an os_signpost and read it in Instruments on a warm launch.

**Caveats from review**: Both skeptics downgraded impact from the implied medium to low and corrected the mechanism: duplicate-column ALTERs fail at prepare/parse, not after taking a write lock, and there's no prepared-statement cache in this fresh connection to invalidate. Both independently pointed at `loadInitialWindow`'s 1000-row thumbnail load (F85) as the dominant cold-start cost on this same path — fix that first.

---

### 10. F93 — Empty-query clipboard search copies the full 1000-entry array

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:349-351`; real cost at `Sources/Floodlight/Search/SearchResultProjection.swift:196-212, 299`

**Evidence**:
```swift
if trimmed.isEmpty {
    return state.pinnedEntries + state.recentEntries
}
```

**Why it costs / what is missing**: This concat allocates a fresh ~1000-element buffer and retains every `ClipboardEntry` reference on every keystroke that leaves the query empty, and again on release. But both skeptics independently found this is dwarfed by what runs immediately after: `SearchResultProjection.projectClipboard` builds a `SearchItem` for every one of ~1000 entries per publish, and `buildClipboardTextRow` does a synchronous `FileManager.default.fileExists(atPath:)` disk stat per path-like entry (`SearchResultProjection.swift:299`) — that's a real syscall per row, on the query path, versus nanosecond-scale ARC traffic for the concat.

**Proposal**: Cap the empty and sub-3-character branches at `Self.searchResultLimit` (200) for parity with the FTS branch — a one-line consistency fix that does not break `clipboardFilterOptions`' full-history kind counts (those must stay computed over the unbounded set). Replace `localizedCaseInsensitiveContains` in `matchesSearch` with an ASCII fast path for the 1-2 character branch (this is the one sub-fix that will actually move `FLOODLIGHT_BENCH clipboard_search_us`, since "a"/"in" in the existing benchmark run ~1000 ICU comparisons each). Separately, get `FileManager.fileExists` off `SearchResultProjection.swift:299` — resolve existence lazily in the inspector or cache it.

**Expected impact**: The ARC/concat fix alone is unmeasurable. The ASCII fast path and removing the per-row stat are what will actually move the benchmark and real keystroke latency.

**Effort/Risk**: S for the ASCII fast path and the searchResultLimit cap / M for de-syncing the file-exists stat from the row-build path. Risk Low / Medium (bounding must happen after kind-filtering, not before, or filter badge counts break).

**How to verify on Mac**: `swift test -c release --filter ClipboardHistoryPerformanceTests`, print one `FLOODLIGHT_BENCH` line per query (not one aggregate) so the empty/"a"/"in" cases are visible separately. Instruments Allocations template filtered on `ClipboardEntry`/`_ContiguousArrayStorage` while holding a key down in Clipboard mode.

**Caveats from review**: Value-lens skeptic downgraded impact and redirected the fix: the store-level `+` concat is a single exact-size allocation already (proposal (3), `reserveCapacity`, was rejected as a no-op or regression). Accuracy-lens skeptic rejected the original truncate-in-store proposal outright — it would corrupt `clipboardFilterOptions` counts and the post-projection `visibleRows` filter. Both agree the ASCII fast path for `matchesSearch` is the one change worth keeping as originally proposed.

---

### 11. F86 — Every clipboard SQL call re-prepares its statement

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:372-376` (and 8 more call sites: 135, 228, 268, 312, 419, 446, 482, 518)

**Evidence**:
```swift
var stmt: OpaquePointer?
if sqlite3_prepare_v2(db, ftsSQL, -1, &stmt, nil) == SQLITE_OK {
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, (escaped as NSString).utf8String, -1, nil)
    sqlite3_bind_int(stmt, 2, Int32(Self.searchResultLimit))
```

**Why it costs / what is missing**: `search`, `insert`, `recordImage`, `entry(id:)`, `imageData(for:)`, `pin`, `unpin`, `delete`, and `prune` each prepare fresh SQL and finalize it per call — no statement cache exists anywhere. `search` is on the per-keystroke path (undebounced, main-actor). But the parse+plan cost for this single-table-plus-FTS-subquery plan is single-digit-to-low-tens of microseconds — an order of magnitude below the original estimate — and it's dwarfed by the same call's row materialization (thumbnail BLOB copies, per F85). `entry(id:)` rarely reaches prepare at all; it short-circuits on the in-memory pinned/recent arrays first.

**Proposal**: If pursued, cache only the single `search` statement (not the full set) to limit surface area, using `sqlite3_reset`/`sqlite3_clear_bindings` instead of finalize. This raises correctness stakes: every early-return path (there are several between `step` and `finalize`) must still reset before reuse, or a cached statement left un-reset under WAL pins an open read snapshot and blocks checkpointing — worse than the microseconds saved. Also required, not optional: replace `(x as NSString).utf8String` + `nil` (SQLITE_STATIC) binding with `withCString` + `SQLITE_TRANSIENT` — the current `nil`-destructor pattern is only safe because `step` happens before the autorelease pool drains in the same call; once a statement is merely `reset` and reused later, that assumption breaks.

**Expected impact**: Low — a benchmark would notice (the existing `ClipboardHistoryPerformanceTests` budget test would show it), a user would not.

**Effort/Risk**: M / Medium (reset-discipline correctness is a real hazard, not a formality) — do this after the thumbnail-column fix (F85), not before, since it can't be validated as a win until the dominant cost is removed.

**How to verify on Mac**: `swift test -c release --filter ClipboardHistoryPerformanceTests` before/after, diff `FLOODLIGHT_BENCH clipboard_search_us`. Instruments Time Profiler; confirm `sqlite3Prepare`/`sqlite3RunParser` frames shrink.

**Caveats from review**: Both skeptics downgraded impact to low and corrected the evidence: `search` binds one text + one int, not "~5 NSString bridges" (the multi-bind sites are `insert`/`recordImage`, which run once per pasteboard change, not per keystroke). Both flagged risk as understated (medium, not low) due to the reset-discipline hazard across ~9 early-return sites and the WAL-pinned-snapshot failure mode. `clear()` correctly uses `sqlite3_exec` and needs no caching — don't include it.

---

### 12. F98 — Silent SQL failure fallback and ignored `clear()` error

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:387-394` (fallback), `:503` (`clear()`)

**Evidence**:
```swift
// Fallback to in-memory filter if FTS query preparation fails
let pinnedMatches = state.pinnedEntries.filter { Self.matchesSearch($0, query: trimmed) }
let recentMatches = state.recentEntries.filter { Self.matchesSearch($0, query: trimmed) }
return pinnedMatches + recentMatches
```

**Why it costs / what is missing**: If `sqlite3_prepare_v2` on the FTS query fails, `search` silently degrades to an in-memory scan of only the 1000-entry resident window — no logging, nothing surfaced. The same silence covers the other `guard sqlite3_prepare_v2(...) == SQLITE_OK else { return }` sites; a failed INSERT just never records. `clear()` discards `sqlite3_exec`'s return value and empties the in-memory caches regardless, so a failed delete leaves the DB and cache disagreeing until next launch resurrects everything the user thought they cleared. A sharper, previously-missed variant: `sqlite3_step` returning `SQLITE_ERROR` inside the FTS loop (as opposed to prepare failing) is indistinguishable from `SQLITE_DONE` and yields silent *empty* results, not this fallback — reachable today because the length guard is `trimmed.utf8.count < 3` (bytes) while the trigram tokenizer needs 3 *characters*, so a 2-character CJK query or a single multi-byte character can silently return nothing.

**Proposal**: Add `os.Logger(subsystem: "com.floodlight.app", category: "clipboard")` (the file already imports `os`) and log `sqlite3_errmsg(db)` at every prepare/step failure, including the FTS step loop. Check `sqlite3_exec`'s return in `clear()` and only empty the caches on `SQLITE_OK`. Do not attempt an automatic `INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')` repair — this is an external-content FTS table whose triggers index `text || ' ' || width || 'x' || height`; a rebuild would silently drop the image-dimension search tokens.

**Expected impact**: Observability only — makes a silent correctness cliff visible; no steady-state perf cost.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Corrupt `clipboard_fts_data` on a DB copy, point the store at it, search, confirm a log line via `log stream --predicate 'subsystem == "com.floodlight.app" AND category == "clipboard"' --level debug`. Add a test asserting `clear()` on a read-only database leaves `count` unchanged.

**Caveats from review**: Both skeptics confirmed the mechanism but corrected the attributed cause — the quote-escaping at line 364 is valid FTS5 syntax and cannot trigger the prepare-failure fallback (the MATCH term is a bound parameter); the real uncovered gap is the `sqlite3_step` SQLITE_ERROR-vs-SQLITE_DONE ambiguity in the loop, and the byte-vs-character length-guard mismatch. Drop the "rebuild" auto-repair from the proposal entirely — it would regress existing dimension-search test coverage.

---

### 13. F87 — FTS search sorts the full match set before LIMIT 200 (plausible — split verdict)

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:365-371`

**Evidence**:
```swift
let ftsSQL = """
SELECT \(ClipboardHistorySQLite.entryColumns)
FROM clipboard_entries
WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?)
ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC
LIMIT ?;
"""
```

**Why it costs / what is missing**: The `ORDER BY` leading key is an expression (`pinned_at IS NOT NULL DESC`), so neither existing index (`idx_clipboard_created_at`, `idx_clipboard_pinned_at`) can satisfy it — SQLite needs a sorter. The two skeptics split here. Accuracy lens: confirmed the sorter is real but noted SQLite bounds an `ORDER BY ... LIMIT N` sorter to N resident records (not a full O(matches log matches) sort as claimed), so impact is medium, not high, and the dominant per-row cost is still the thumbnail BLOB in `entryColumns` (shared root cause with F85), not the sort itself. Value lens: refuted the fix as likely ineffective — the query is planner-driven by `rowid IN (SELECT … MATCH ?)`, and splitting into two `LIMIT`-ed statements is not guaranteed to make SQLite switch to an index-ordered scan; if it does flip, a very selective query could regress into scanning the whole `created_at` index looking for 200 matches — a real risk the original "low risk" rating missed. Both agree the query has no `EXPLAIN QUERY PLAN` harness anywhere in the repo to validate the fix's premise, which cannot be checked from this Windows host.

**Proposal (contested)**: If pursued: split into two index-friendly halves (pinned/unpinned) wrapped in a single outer `LIMIT 200` (not two separate `LIMIT` halves — that changes result cardinality). Verify with `EXPLAIN QUERY PLAN` that `USE TEMP B-TREE FOR ORDER BY` disappears before committing to this. Given the split verdict, the lower-risk alternative both skeptics prefer is to fix the shared root cause instead: drop `thumbnail_png` from the search projection (same fix as F85) and, since `pinnedEntries` is already fully resident, filter pinned matches in memory and let SQL only do `WHERE ... AND pinned_at IS NULL ORDER BY created_at DESC LIMIT ?` — one statement, no non-indexable leading term, no plan-dependent risk.

**Expected impact**: Uncertain pending a real `EXPLAIN QUERY PLAN` check on Mac — could range from a meaningful cut for a large multi-thousand-row history to no measurable change if the planner doesn't take the index path either way.

**Effort/Risk**: S/Low for the "drop thumbnail_png + filter pinned in memory" alternative; M/Medium for the two-statement ORDER BY split, contingent on plan verification this environment cannot perform.

**How to verify on Mac**: `sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 "EXPLAIN QUERY PLAN SELECT id FROM clipboard_entries WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH '\"the\"') ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC LIMIT 200;"` — look for `USE TEMP B-TREE FOR ORDER BY` before and after any rewrite. Add a 20,000-entry scale test to `ClipboardHistoryPerformanceTests` with broadly-matching queries ("the", "com").

**Caveats from review**: This is the one finding in the section with a genuine skeptic disagreement, not just corrections — accuracy lens said plausible/medium-impact-confirmed, value lens said refuted/low-impact/fix-may-not-work. Do not implement the two-statement split without first running the `EXPLAIN QUERY PLAN` check above; if it still shows a temp B-tree, prefer the shared-root-cause fix (drop `thumbnail_png` from the search columns) which both skeptics agree is safe.

---

### Rejected ideas

- **F97** ("recordFile/record recompute mostRecentEntry with an O(pinned) max() and pay an O(n) insert(at: 0) per capture") — refuted by both skeptics. The `pinnedEntries.max { … }` fallback only evaluates when `recentEntries` is empty (an autoclosure behind `??`), not per capture; the `insert(at: 0)` memmove is ~120 bytes/entry with no ARC traffic (~10-15 microseconds for 1000 entries) sitting inside the same lock as a synchronous SQLite INSERT + FTS trigger write that costs 100-1000x more — noise against its own neighbor. The proposed "newest-last + reverse on publish" refactor would also invert a load-bearing ordering contract consumed at 15+ call sites and tests, for no measurable gain. Do not re-investigate.


# Richer text

## Richer text

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F106 | Clipboard footer advertises "Paste to \<App\>" and "Actions ⌘K" — neither is true | Medium | S | Low | Confirmed |
| 2 | F102 | Inspector lays out the entire unbounded clipboard body on every selection | Medium | S | Low | Confirmed |
| 3 | F100+F101 | `buildClipboardRow` rescans the full entry body (title, 3 parsers, a JSON parse) per row per keystroke | Medium | S/M | Low | Confirmed |
| 4 | F115 | "Forever" clipboard retention is silently ignored — always prunes at 30 days | Medium | S | Low | Confirmed |
| 5 | F111 | Code badge recognizes 3 languages ("JSON"/"Code"/"HTML"); syntax highlighting is a separate, larger step | Medium | S (badge) / L (highlighting) | Low / Medium | Confirmed |
| 6 | F104 | `imageFormatName` hardcodes "PNG Image" for every image entry, ignoring both its arguments | Low | S | Low | Confirmed |
| 7 | F108 | Path and code subtitles tail-truncate, hiding the identifying suffix | Low–Med | XS | Low | Confirmed |
| 8 | F105 | Clipboard subtitle prints the timestamp twice; grammar differs across the three entry kinds | Low | S | Low | Confirmed |
| 9 | F109 | Row's app name diverges from the inspector's resolved name for the same entry | Low | S | Low | Confirmed |
| 10 | F112 | `.svg` classifies as an image in the inspector but the thumbnail generator's copy of the list omits it | Low | S | Low | Plausible |
| 11 | F113 | Calculator row's ⌘C copies the grouped (comma-separated) string, not the raw number | Low | S | Low | Plausible |
| 12 | F110 | ⌘C on an image clipboard row copies its display-name string ("PNG Image"), not the image | Low | S | Low | Plausible |
| 13 | F99+F103 | Clipboard capture/restore never touches RTF/HTML — formatting is destroyed at capture, restore is plain-text only | Low–Med | L | Medium | Confirmed |
| 14 | F107 | No matched-character highlighting in result rows (feasible only for app/setting rows today) | Medium | L | Medium | Confirmed |

### 1. Clipboard footer advertises actions it doesn't perform (F106)

**Where**: `Sources/Floodlight/UI/SearchView.swift:469-471, 482-518`, `Sources/Floodlight/App/FloodlightPanel.swift:368-387, 313-317, 401`

**Evidence**:
```swift
private var targetAppName: String {
    model.clipboardInspector?.sourceApp ?? "App"
}
...
Text("Paste to \(targetAppName)")
...
Button { model.copySelection() } label: {
    HStack(spacing: 5) { Text("Actions"); ...; Text("⌘"); Text("K") }
}
```

**Why it costs / what is missing**: Three mismatches in one bar. (a) `sourceApp` is the app the entry was copied *from* (`ClipboardInspector.swift:94`), so copying from Notes and selecting in Xcode reads "Paste to Notes". (b) `openSelection()` never pastes — it writes the pasteboard and dismisses (`SelectedResultActionPerformer.swift:157-163`); the user still presses ⌘V themselves. (c) ⌘K is not in `FloodlightPanel.panelCommand`'s table (c, l, r, y, Return, `.`, d) and is swallowed nowhere else — the button under that label calls `copySelection()`, which is ⌘C. With no selection the label degrades further, to the literal "Paste to App".

**Proposal**: Rename to "Copy ↵" (or "Restore ↵"). Replace the ⌘K button with real bound shortcuts rendered through the existing `KeyChip` component — ⌘. pin, ⌘D delete, ⌘Y preview — instead of inventing a new binding. If actual paste-into-frontmost-app is wanted later, that's a separate accessibility-permission feature (synthetic ⌘V via CGEvent) and the label should not imply it until it exists.

**Expected impact**: Removes three false affordances from the only chrome in clipboard mode. Users currently press ⌘K and nothing happens.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `make run`, enter clipboard mode, press ⌘K, confirm something happens once bound (or that the button is gone). Add a `SearchCoordinatorClipboardModeTests` case for `FloodlightPanel.panelCommand(for: "k", ...)`; add a `SearchViewRenderingTests` case asserting the footer label no longer interpolates `sourceApp`.

**Caveats from review**: Both skeptics confirmed (also independently found by two other review lenses — highest corroboration in this section). Corrections: `targetAppName` falls back to the literal "App", not just the wrong app, when there's no selection. The footer hand-rolls its own chip styling instead of reusing `KeyChip` — fix that too. Building an actual ⌘K actions *menu* (rather than relabeling to existing shortcuts) is M effort, not S — scope the S estimate to the relabel-only fix.

### 2. Inspector lays out the entire unbounded clipboard body on selection (F102)

**Where**: `Sources/Floodlight/UI/ClipboardInspectorPane.swift:99-127`

**Evidence**:
```swift
case .text, .image, .video, .file:
    Text(detail.body)
        .font(.system(size: 12.5, weight: .regular))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
```

**Why it costs / what is missing**: `.link` caps at `.lineLimit(6)`; `.code` and plain `.text` have no cap at all. `detail.body` is the entry's full text — up to `ClipboardHistoryStore.maxTextByteCount = 32_000` bytes (`ClipboardHistoryStore.swift:8`) — laid out with `.textSelection(.enabled)` (forces a selectable TextKit backing store) inside a 340pt pane (`FloodlightMetrics.clipboardInspectorWidth`), roughly 550-600 lines for a full-size entry. This runs on the main thread on every selection move onto a large entry.

**Proposal**: Add `ClipboardInspector.TextDetail.previewBody` holding the first ~4,000 characters (and cap by *lines* too, e.g. `.lineLimit(200)`, since layout cost tracks lines not characters) plus `bodyIsTruncated: Bool`; keep `body` for the copy path. Render `previewBody`, and when truncated show a quiet footer: "Showing first 4,000 of \(characterCount) characters." Apply the same cap to the `.code` branch (line 110), not only `.text`.

**Expected impact**: Bounds inspector layout at a constant instead of scaling with the largest entry in history; removes the hitch when arrowing onto a large captured document.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Copy a ~32 KB text file, enter clipboard mode, hold the down-arrow through 20 entries while recording Instruments' Animation Hitches template; confirm the hitch disappears after the fix. Add a case asserting `previewBody.count <= 4_000` and `bodyIsTruncated == true` for a 32 KB entry.

**Caveats from review**: The claim "again on every keystroke" is wrong — `TextDetail` is `Equatable`, so SwiftUI skips re-layout when the selected entry doesn't change; the real cost is per *selection move onto a different large entry*, not every keystroke. The "~1,000 laid-out lines" estimate was high; corrected to ~550-600 given the pane's actual width and font size. The `.code` branch (line 110) needs the same fix, not just `.text`/line 122. Drop the NSAttributedString/rich-preview tack-on from this fix — it's a separate, larger change; don't bundle it here.

### 3. `buildClipboardRow` rescans the full entry body per row per keystroke (F100 + F101)

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:282-336` (top of `buildClipboardTextRow`); `Sources/Floodlight/Search/ClipboardInspector.swift:236-298` (`parseLocalPath`, `parseURL`, `parseHexColor`, `parseCodeHint`)

**Evidence**:
```swift
// SearchResultProjection.swift:396-401
private static func previewTitle(for text: String) -> String {
    let singleLine = text.split(whereSeparator: \.isNewline)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    return singleLine.isEmpty ? "(Empty text)" : singleLine
}
// SearchResultProjection.swift:318-328
} else if ClipboardInspector.parseURL(text) != nil {
} else if ClipboardInspector.parseHexColor(text) != nil {
} else if ClipboardInspector.parseCodeHint(text) != nil {
```

**Why it costs / what is missing**: For every text row, `buildClipboardTextRow` calls `parseLocalPath` (:282), `previewTitle` (:396), then `parseURL`/`parseHexColor`/`parseCodeHint` (:320-325) — each of the four parsers independently `trimmingCharacters(in: .whitespacesAndNewlines)`s the *whole* body (`ClipboardInspector.swift:236, 256, 264, 273`), and `parseCodeHint` additionally runs `JSONSerialization.jsonObject(with: Data(trimmed.utf8))` over the entire body plus up to seven `contains` scans (`ClipboardInspector.swift:273-296`) purely to answer a yes/no classification question. This runs per row, per keystroke, with no memoization, on the `@MainActor` `SearchCoordinator` with no debounce for clipboard mode (`SearchCoordinator.swift:502-507`).

**Proposal**: Do one bounded scan (~200-4KB prefix) per row that answers all four questions at once — leading-trimmed head, first-newline offset, line count, all-whitespace flag — and feed the classifiers from that instead of the full body. In `parseCodeHint`, replace the `JSONSerialization` round trip with a structural check on the first/last ~512 bytes (balanced opener/closer); it's a badge hint, not a validator. Keep a cheap check of the *original* string's last character for the `}`/`]`/`>` suffix tests, since truncating the input would silently downgrade real JSON/HTML detection. Use the discarded line-count/first-line info to build a better subtitle (e.g. `"Notes · 42 lines · <time>"`) instead of throwing it away.

**Expected impact**: Turns several O(total bytes of entry) passes per row into one bounded O(1) pass. Real magnitude is capped, not runaway: `searchResultLimit = 200` (`ClipboardHistoryStore.swift:11`) bounds rows for queries of 3+ characters — the up-to-1,000-row case applies only to clipboard-mode entry and the first two keystrokes — and each entry is capped at 32,000 bytes. Still a real, unbounded-per-row cost with a cheap, complete fix.

**Effort/Risk**: S/M (S for the row scan; M if bundled with persisting a `content_kind` column, which is a separate, larger change touching FloodlightEngine's schema). / Low.

**How to verify on Mac**: Add a `SearchResultProjectionClipboardPerformanceTests` case: 1,000 fixtures where every tenth entry has a 32 KB multi-line body, project with an empty query, 11 samples × 20 iterations, print `FLOODLIGHT_BENCH clipboard_projection_us=…`, assert a large improvement post-fix. Instruments Time Profiler while typing five characters in clipboard mode — confirm no `JSONSerialization` frames under `buildClipboardTextRow`.

**Caveats from review**: Both source findings (F100 row-title, F101 JSON parse) hit the same function and the same underlying defect (repeated full-body scans); merged here since one fix addresses both. Corrected magnitude: NOT "1,000 rows on every keystroke" — only on mode entry, empty query, and queries under 3 UTF-8 bytes; 3+ character queries are capped at 200 via FTS5 (`ClipboardHistoryStore.swift:11, 376`). Text is capped at 32,000 bytes, so the JSON-parse worst case is bounded, not unbounded. A higher-priority sibling issue in the same function: `FileManager.default.fileExists(atPath:)` at `SearchResultProjection.swift:299` is a synchronous disk stat per row on the main-actor query path — exactly the pattern `tools/ast-grep/rules/query-path-no-sync-disk-read.yml` exists to forbid, escaping only because that rule is scoped to `Sources/FloodlightEngine/**`. Worth raising as its own follow-up. `ClipboardHistoryStore.matchesSearch`'s `localizedCaseInsensitiveContains` over full entry text for 1-2 character queries is also comparable-or-larger cost and out of scope here. The persisted-`content_kind`-column variant of the fix is L effort in practice (classifier logic lives in the shell target, `ClipboardEntry`/schema live in the engine), not the M implied in the original proposal — land the bounded-scan fix first, treat persistence as optional follow-up.

### 4. "Forever" clipboard retention is silently ignored (F115 — replaces the original speculative privacy-toggle proposal)

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:154-170`, `Sources/FloodlightEngine/Utilities/ClipboardEntry.swift:91-103`

**Evidence**:
```swift
var retention: ClipboardRetention {
    get {
        let days = defaults.integer(forKey: Self.retentionDaysDefaultsKey)
        if days > 0 { return .days(days) }
        return .days(30)
    }
    set {
        switch newValue {
        case let .days(days): defaults.set(days, forKey: Self.retentionDaysDefaultsKey)
        case .forever: defaults.set(-1, forKey: Self.retentionDaysDefaultsKey)
        }
    }
}
```

**Why it costs / what is missing**: `OnboardingView.swift:319` offers `Text("Forever").tag(-1)`, and the setter correctly persists `-1` for `.forever`. But the getter only special-cases `days > 0`; any non-positive stored value (including `-1`) falls through to `.days(30)`. `ClipboardRetention.cutoffDate(from:)` (`ClipboardEntry.swift:95-102`) returns `nil` only for `.forever`, which would make `prune(retention:)` (`ClipboardHistoryStore.swift:529-531`) skip pruning entirely — but since the getter never actually returns `.forever`, that branch is unreachable in practice. A user who explicitly picks "Forever" in Settings still has their unpinned clipboard history pruned at 30 days, silently, with no error and no indication anything is wrong.

**Proposal**: Fix the getter to round-trip the sentinel: `if days == -1 { return .forever }; if days > 0 { return .days(days) }; return .days(30)`. Add a `ClipboardCaptureServiceTests` case asserting `retention == .forever` survives a set/get round trip through `UserDefaults`.

**Expected impact**: Fixes silent, unexpected data loss for any user who opts into unlimited clipboard retention — a real correctness bug, not a polish item, hiding behind three lines of code.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Set retention to "Forever" in Settings, inspect `UserDefaults.standard.integer(forKey: "clipboard-history-retention-days")` (expect `-1`), then check whether an entry older than 30 days survives a prune cycle before vs. after the fix.

**Caveats from review**: This replaces F115's original proposal (a privacy toggle for RTF/HTML capture and an app picker for exclusions), which both skeptics substantially refuted — RTF/HTML capture doesn't exist anywhere in the codebase, so a settings toggle gating it would be dead UI for a hypothetical feature, and the app-picker mechanism was mis-described (RootPicker is folder-only, not app-only). Their read of the surrounding code surfaced this "Forever" bug as the real, concrete defect in that area; verified independently this session by reading the cited lines directly. The original finding's smaller true claims (the "Record clipboard history" subtitle says "text" but files/images are also captured; the exclusion caption mentions "names" that the matcher doesn't actually support) are minor copy fixes, worth bundling in but not the headline.

### 5. Code badge recognizes three languages; syntax highlighting is separate (F111)

**Where**: `Sources/Floodlight/UI/ClipboardInspectorPane.swift:99-119`, `Sources/Floodlight/Search/ClipboardInspector.swift:272-298`

**Evidence**:
```swift
case .code:
    if let lang = detail.codeLanguage {
        Text(lang) // .font(size: 10, bold), capsule badge
    }
    Text(detail.body)
        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
```

**Why it costs / what is missing**: `parseCodeHint` returns exactly "JSON", "Code", or "HTML" (`ClipboardInspector.swift:278, 284, 289, 295`) — else `nil`, meaning unrecognized text (SQL, Python, shell) gets no badge at all, and a Swift function, a shell command, and a JS module all land on the identical "Code" label. Note the badge is often pure duplication today: the info section separately prints `infoRow(label: "Type", value: detail.contentType.rawValue)` (`ClipboardInspectorPane.swift:178`), which is the same literal string.

**Proposal**: Two independent phases — do the first alone; it captures most of the value.
1. (S, Low) Widen detection to a small signature table keyed to real language names: `SELECT|INSERT|UPDATE`→SQL, `func |struct |import Foundation`→Swift, `def |import `→Python, leading `$`/`git `/`npm `→Shell, `<?xml`/`<!DOCTYPE`→XML/HTML, `#!/`→named interpreter. Evaluate over a bounded prefix (reuses the bounded-scan work from Finding 3). Drop the badge as redundant if `codeLanguage == contentType.rawValue`, or repurpose the "Type" row instead.
2. (L, Medium) A small single-pass lexer (comments/strings/numbers/keywords per language) producing an `AttributedString`, capped at the truncated `previewBody` from Finding 2 so cost stays bounded. Sequence this after any RTF/HTML rich-preview work (Finding 13) so both share one rendering path.

**Expected impact**: Phase 1 alone turns a near-meaningless badge into a real, useful classification for developer-heavy clipboard content — for zero rendering-engine work. Phase 2 makes the inspector's code view actually readable.

**Effort/Risk**: S (phase 1) / L (phase 2, full highlighting). Low / Medium.

**How to verify on Mac**: Add `ClipboardInspectorTests` cases, one per supported language, using the existing perf-fixture strings at `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:11-22` as ready-made inputs. For phase 2, add `Tests/FloodlightTests/ClipboardSyntaxHighlightPerformanceTests.swift`: 11 samples × 100 highlights of a 4 KB Swift snippet, `FLOODLIGHT_BENCH clipboard_highlight_us=…`, assert median < 500µs. `swift build -c release && size .build/release/Floodlight` before/after to confirm no material binary growth (target ships `-Osize`).

**Caveats from review**: Both skeptics confirmed the gap is real and not implemented elsewhere. Recommend landing phase 1 alone first — it's S/Low and captures most of the visible win; phase 2 is a genuinely separate, larger project (new AppKit text-rendering surface, light/dark theming, no highlighting dependency allowed per CDN/binary-size constraints — write ~150 lines by hand, don't pull in a library) and should not share one effort/risk estimate with phase 1.

### 6. `imageFormatName` hardcodes "PNG Image" for every image (F104)

**Where**: `Sources/Floodlight/Search/ClipboardInspector.swift:327-329`, rendered at `Sources/Floodlight/UI/ClipboardInspectorPane.swift:213`

**Evidence**:
```swift
private static func imageFormatName(width: Int, height: Int) -> String {
    "PNG Image"
}
```

**Why it costs / what is missing**: Both parameters are dead; the function is a constant dressed as a computation. TIFF-only captures are a real, already-tested case (`ClipboardImageCapture.payload` takes `png ?? tiff`, `ClipboardImageCapture.swift:22`; covered by `pollRecordsTIFFWhenPNGIsAbsent` in `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift:340`). For such an entry the inspector's own title (`entry.text` = "TIFF Image") contradicts its Format row ("PNG Image") one screen apart.

**Proposal**: `SearchCoordinator.clipboardInspector` (`SearchCoordinator.swift:653`) already fetches the full `ClipboardImagePayload` (both PNG and TIFF via `ClipboardHistoryStore.imageData(for:)`) and currently discards the TIFF half — thread that payload (or a derived format string) into `ClipboardInspector.snapshot`, then delete `imageFormatName` and its dead parameters. Report "PNG + TIFF" when both variants exist, since `writeImage` already restores both (`SelectedResultActionPerformer.swift:64-78`).

**Expected impact**: Removes a hardcoded falsehood from the one panel whose job is describing what an entry actually is. Zero runtime cost.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Copy a TIFF-only image (Preview → Edit → Copy on a selection), open the inspector, confirm the Format row now says "TIFF Image". Add a `ClipboardInspectorTests` case building a TIFF-only entry and asserting `detail.format == "TIFF Image"`.

**Caveats from review**: Do not use `format: entry.text` as the "cheapest fix" — `entry.text` is "Screenshot" for screen captures or `"{w}×{h}"` when the display name is blank (`ClipboardHistoryStore.swift:190-191`), not a format string. No byte-sniffing or schema migration is needed; the PNG/TIFF presence is already fetched by the existing `imageData(for:)` call.

### 7. Path and code subtitles tail-truncate, hiding the identifying suffix (F108)

**Where**: `Sources/Floodlight/UI/ResultRow.swift:67-87`

**Evidence**:
```swift
HStack(spacing: 6) {
    Text(item.subtitle)
        .lineLimit(1)
    ...
}
.font(FloodlightMetrics.Typography.rowSubtitle)
```

**Why it costs / what is missing**: No `.truncationMode` is set, so SwiftUI defaults to `.tail`. For a path subtitle (file/folder rows: `relativePath`, `SearchItem.swift:336`; clipboard file rows: absolute path, `SearchResultProjection.swift:354`), the tail is the least informative end — deep intermediate directories, not the identifying filename (which is already the row's *title*, so the practical loss is smaller than it first appears, mattering mainly when two same-named files compete).

**Proposal**: The single highest-value, lowest-cost fix: add `.truncationMode(.middle)` at `ResultRow.swift:69`. Stop there for most benefit at near-zero cost. A fuller `SubtitleStyle` enum (`.plain`/`.path`/`.code`) with per-case monospacing is a legitimate but separate, larger follow-up — and for the `.code` (content-match) case, `.middle` truncation is actually wrong (it would eat the snippet's informative start), so that case needs its own two-`Text` treatment, not a blanket style flag.

**Expected impact**: Bounded, real, presentational-only improvement to file/folder/clipboard-file rows.

**Effort/Risk**: XS (single-line fix) / Low.

**How to verify on Mac**: Search for a file nested six directories deep; confirm the parent path reads sensibly with `…` in the middle rather than at the end.

**Caveats from review**: Both skeptics found the original evidence claim "arrives unsanitized" (about code-snippet leading whitespace) to be false — `FFFIndex.swift:395-396` already trims it; drop that part of the proposal, it's a no-op. The application-row case (subtitle is `/Applications` or similar) never overflows and doesn't need this treatment. Reduce scope to the one-line `.middle` fix on the general subtitle; treat the code-snippet and monospacing enhancements as optional, separate follow-ups.

### 8. Clipboard subtitle timestamp is duplicated; grammar differs by kind (F105)

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:315-338`, `Sources/Floodlight/UI/ResultRow.swift:76-79`

**Evidence**:
```swift
let subtitle = "\(app) · \(time)"
...
return SearchItem(..., subtitle: subtitle, ..., modifiedAt: entry.createdAt)
```

**Why it costs / what is missing**: `ResultRow.swift:76-79` unconditionally appends `ResultShowcase.formattedModifiedDate(modifiedAt)` after the subtitle whenever `modifiedAt` is set — so every clipboard text row reads "Notes · 5m · Today at 3:45 PM", the same instant twice in two vocabularies. The three kinds then disagree: file rows set no `modifiedAt` (no time shown at all), image rows set `fileSize` but no `modifiedAt`.

**Proposal**: Drop `· \(time)` from the projected subtitle strings; keep `modifiedAt: entry.createdAt` on all three kinds so `ResultRow` supplies one consistent time. Add `modifiedAt` to file and image rows too. Keep file rows' subtitle as the full path (needed as the only disambiguator once the title is just the leaf name) — don't replace it with the source app as originally proposed.

**Expected impact**: One time, one vocabulary, across all three clipboard row kinds.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `make run`, copy text/a file/a screenshot, enter clipboard mode, confirm each row states the time exactly once.

**Caveats from review**: A fourth grammar variant exists in the local-path branch of `buildClipboardTextRow` (`SearchResultProjection.swift:282-311`) that also double-prints — cover it too. Don't add a per-row file-size stat to file rows as originally proposed; that would add a synchronous disk stat per row on the keystroke path, the same anti-pattern flagged in Finding 3. Five to six test assertions in `Tests/FloodlightTests/SearchResultProjectionClipboardTests.swift` and `SearchCoordinatorClipboardModeTests.swift` need updating for the new grammar.

### 9. Row app name diverges from the inspector's resolved name (F109)

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:403-409`, `Sources/Floodlight/Search/ClipboardInspector.swift:360-370`

**Evidence**:
```swift
private static func appDisplayName(for bundleID: String?) -> String {
    guard let bundleID, !bundleID.isEmpty else { return "Clipboard" }
    if let lastComponent = bundleID.split(separator: ".").last, !lastComponent.isEmpty {
        return String(lastComponent)
    }
    return bundleID
}
```

**Why it costs / what is missing**: The row uses the last dot-component of the bundle ID (`com.tinyspeck.slackmacgap` → "slackmacgap"), while the inspector resolves the actual Launch Services display name via `NSWorkspace.urlForApplication` (`ClipboardInspector.swift:362`, "Slack"). Selecting a row changes what the app is called on screen.

**Proposal**: Resolve the name once per bundle ID and share it — thread a pre-resolved `[bundleID: String]` map or closure from the `@MainActor` `SearchCoordinator` into the (nonisolated, pure, test-driven) `SearchResultProjection`, and have `ClipboardInspector.sourceAppDisplayName` read the same source so the two surfaces can't drift.

**Expected impact**: One name for one app, across row and inspector.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Add a test asserting the row's app name equals the inspector's for the same bundle ID (`com.microsoft.VSCode` should read identically in both places).

**Caveats from review**: Drop the icon half of the original proposal (rendering the source app's real icon as the row icon) — `SearchItem` carries no bundle ID field, so this needs an engine model change or a per-row NSImage→PNG encode on the main thread per keystroke; not S effort, not low risk. Scope this finding to the name-consistency fix only. `SearchResultProjection.project` is a nonisolated pure function driven directly by tests — don't wire `AppIconCache`/`NSWorkspace` into it directly; pass resolved names in from the coordinator instead.

### 10. `.svg` classifies as an image in the inspector but never gets a thumbnail (F112)

**Where**: `Sources/Floodlight/Search/ClipboardInspector.swift:217-231`, `Sources/Floodlight/UI/FileThumbnailCache.swift:40-46`, `Sources/Floodlight/UI/ClipboardInspectorPane.swift:292-294`

**Evidence**:
```swift
let imageExtensions: Set = [
    "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif", "bmp", "avif", "ico",
    "icns", "svg",
]
```

**Why it costs / what is missing**: The same extension lists are hand-copied in three places and have diverged: `ClipboardInspector`'s image set includes `svg`/`ico`/`icns`; `FileThumbnailCache`'s does not. A copied `.svg` file therefore classifies as an image (gets the image badge/preview branch) but can never produce a thumbnail from `FileThumbnailCache`.

**Proposal**: This is a correctness/DRY issue, not a perf one (the sets are tiny ASCII literals — no measurable allocation cost, and two of the three call sites are cold: one runs inside `.task(id: url)`, the other inside an already-async thumbnail generator before a QuickLook IPC round trip). Add one shell-local `enum MediaExtensions { static let image, video: Set<String> }` under `Sources/Floodlight` (not on the engine's `SearchResultFilter`, which is `fileprivate`, models a different concept — search filter chips — and has no video notion) and have all three sites read it.

**Expected impact**: Fixes the visible svg-classifies-but-never-thumbnails inconsistency. No measurable perf change.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Copy an `.svg` file into clipboard history, confirm the inspector shows an image badge, and confirm whether a thumbnail actually renders — before/after the fix.

**Caveats from review**: Status is Plausible — the perf-allocation framing was refuted by both skeptics (all literals are small-form Swift strings, no heap allocation; call frequency is far lower than claimed, since `classifyFile` only runs for the single selected entry, not per row). The correctness defect (svg divergence) survives and is the actual value here — retitled and rescoped accordingly.

### 11. Calculator row copies the grouped string, not the raw number (F113)

**Where**: `Sources/FloodlightEngine/Utilities/Calculator.swift:20-27`, `Sources/Floodlight/Search/SearchResultProjection.swift:440-449`

**Evidence**:
```swift
package static func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}
```

**Why it costs / what is missing**: The calculator row's `action: .copy(answer)` copies the *grouped* display string (e.g. "1,234,000"), so pasting into a spreadsheet cell lands as text, not a number. This only fires for queries containing an operator (`Calculator.swift:6`), not on every keystroke generally.

**Proposal**: Split the payload — keep the grouped string as the display `title`, but set `action: .copy(rawAnswer)` using the ungrouped value. Do not touch `Calculator.format` or add a cached/locked `NumberFormatter` — the perf argument for that (an ICU formatter per keystroke) doesn't survive: it's once per operator-bearing query, unmeasurable against a 16ms frame budget, and no benchmark exists that would show a delta.

**Expected impact**: Fixes a real paste hazard for a common calculator use case.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Type `1234000 + 0`, press ⌘C, paste into Numbers; confirm it lands as a number after the fix.

**Caveats from review**: Status is Plausible — the accuracy skeptic refuted the "again through copyValue" perf claim outright (false: `SelectedResultActionPerformer.swift:240-243` reads the already-computed string, no second format call occurs) and the "⌘C on 1234567" example (a bare number has no operator and produces no calculator row at all). The formatter-caching half of the original proposal is dropped; only the copy-payload bug survives, and it needed a different example query to be valid.

### 12. ⌘C on an image clipboard row copies its display name, not the image (F110)

**Where**: `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:240-247`

**Evidence**:
```swift
case .copyImage:
    item.title.hasPrefix("📌 ") ? String(item.title.dropFirst(2)) : item.title
```

**Why it costs / what is missing**: `copyValue`'s `.copyImage` case returns the row's *title* string — which for an image entry is its display name ("PNG Image", "TIFF Image", "Screenshot") — so ⌘C on a screenshot row puts that literal string on the pasteboard instead of image data.

**Proposal**: Route through the existing `clipboardImagePayload` closure (already used by `activate`'s `.copyImage` case at `SelectedResultActionPerformer.swift:172-179`) instead of `item.title`.

**Expected impact**: Fixes a copy path that currently produces a literally useless pasteboard value for every image entry.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Copy a screenshot into clipboard history, select the row, press ⌘C, paste into Preview or check the pasteboard directly — confirm image data lands, not text.

**Caveats from review**: Status is Plausible — this survives as the one concrete bug out of a larger original proposal ("content kinds are detected but produce no typed actions," including a "Return opens URLs" idea). The Return-opens-URL half was refuted: it would break the clipboard-mode invariant that Return always restores-and-dismisses reversibly, substituting an irreversible app launch, and no keyboard-binding room exists for a secondary action without redesigning the panel's key map. Scope this finding to the ⌘C image-copy bug only; rewrite the existing test fixture in `SelectedResultActionPerformerTests.swift:128` whose title ("AppMockup_Dark_v2.png") is unreachable in production (real image entries never have arbitrary titles like that).

### 13. Clipboard capture/restore never touches RTF/HTML (F99 + F103)

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:6-14, 280-284` (capture); `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:30-46` (restore)

**Evidence**:
```swift
// Capture — ClipboardCaptureService.swift:280
guard let text = observer.string(forType: .string), !text.isEmpty else { return }
// Restore — SelectedResultActionPerformer.swift:42-46
static func writeString(_ value: String, to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    pasteboard.setData(Data(), forType: .floodlightOwnWrite)
    return pasteboard.setString(value, forType: .string)
}
```

**Why it costs / what is missing**: `PasteboardObserving` exposes only `string(forType:)`, `filePaths()`, `pngData()`, `tiffData()` — no `.rtf`/`.rtfd`/`public.html` accessor exists anywhere, so a copy out of Pages, Notes, Slack, Safari, or Xcode has its formatting discarded at capture, before any downstream code could act on it. Symmetrically, restore writes only `.string` — files and images already round-trip natively (`writeFiles`, `writeImage`), text is the one kind that doesn't. Whether rich-only pasteboards (no plain-text flavour at all) are dropped entirely, versus merely flattened, is an open question — see the research prompt below; Cocoa apps typically publish plain text alongside rich flavours, so the more common effect is formatting loss, not data loss.

**Proposal**: Add `func data(forType:) -> Data?` to `PasteboardObserving`; read `.rtf`/`public.html` in `poll()` alongside `.string`. Follow the lazy-loading pattern the image feature already uses (`ClipboardEntry` carries only a thumbnail; heavy blobs are fetched by id via `ClipboardHistoryStore.imageData(for:)`) — do **not** put RTF/HTML data directly on `ClipboardEntry`, or the 1,000-entry in-memory window (`inMemoryRecentWindowLimit`) could hold hundreds of MB resident on launch. Add `rtf_data`/`html_data` BLOB columns via the existing `ALTER TABLE` migration pattern (`ClipboardHistorySQLite.swift:207-217`), capped separately (e.g. 256 KB per variant; RTF for the same prose runs 5-20x the plain-text byte count). Gate the whole thing behind a settings toggle defaulting off, since HTML can carry tracking markup and embedded images. On restore, mirror `writeImage`'s shape: write `.rtf`/`public.html` richest-first, `.string` last, through a new `writeRichTextToClipboard`.

**Expected impact**: A genuine feature addition (CONTEXT.md's Clipboard Entry is currently defined as exactly three kinds: text, file, image — this expands the domain model, it isn't fixing a defect). Recovers formatting on restore for the first time. Cost: a 30-day/2,000-entry history could grow from ~1MB to 10-30MB of SQLite; the cap and the toggle are load-bearing, not optional.

**Effort/Risk**: L / Medium.

**How to verify on Mac**: Run the pasteboard-flavour research prompt below first. Then extend `ScriptedPasteboardObserver` with a `dataByType` dictionary and add `Tests/FloodlightTests/ClipboardRichTextCaptureTests.swift` asserting an RTF-only pasteboard still produces an entry with derived plain text. Add a `clipboard_db_bytes` budget test (1,000 entries × 40 KB RTF payload) asserting total size stays under a fixed ceiling.

**Caveats from review**: Both original findings (capture-side F99, restore-side F103) were merged since F103 has no effect without F99 landing first — restoring rich data that was never captured is a no-op. Both value-lens skeptics substantially downgraded impact: this unblocks *no* currently-planned feature (no rich preview, no paste-with-formatting UI exists to consume it), so shipping capture alone changes nothing a user sees until restore also lands — hence L effort bundling both halves rather than treating capture as a small win on its own. One skeptic identified a more valuable, much smaller adjacent bug worth fixing first regardless of this feature's fate: `ClipboardCaptureService.poll()` checks for an image payload (`ClipboardImageCapture.payload`) *before* checking for text, and that check never verifies text is absent — so an app that publishes both an image and a formatted-text selection on the same pasteboard (Office is the classic case) gets recorded as an unsearchable image entry instead of text. Consider fixing that ordering bug independently of, and before, any rich-text work.

### 14. No matched-character highlighting in result rows (F107)

**Where**: `Sources/Floodlight/UI/ResultRow.swift:45-53`, `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:227-244`, `Sources/FloodlightEngine/Search/SystemCatalog.swift:377-401`, `Sources/FloodlightEngine/Utilities/FuzzyMatcher.swift:6-21`

**Evidence**:
```swift
Text(item.title)
    .font(isTopHit ? FloodlightMetrics.Typography.topHitTitle : FloodlightMetrics.Typography.rowTitle)
    .foregroundStyle(.primary)
    .lineLimit(1)
```

**Why it costs / what is missing**: Every row title renders flat. `FuzzyMatcher.MatchEvidence` already carries shape and offset (`.namePrefix`, `.wordPrefix(offset:)`, `.acronym(offset:)`, `.typo(edits:offset:)`) but `SearchItem` carries only title/subtitle/score — the evidence is computed and thrown away. Coverage is narrower than it first appears: `ApplicationCatalog.score(of:)` calls `FuzzyMatcher.score`/`scoreASCII`, which return only an `Int?`, discarding the shape entirely — evidence would need to be plumbed through the application hot path too. File/folder rows come from FFFKit's own opaque score with no evidence available at all. Only `SystemCatalog` (settings) already reasons over evidence, and even there, offsets are into `normalized("\(name) \(keywords)")`, not the display title — `.acronym(offset:)` is a *word index* into `initials`, not a character offset, and `normalized()`'s case/diacritic folding is not guaranteed length-preserving.

**Proposal**: Scope to `.application` and `.systemSetting` rows only (the only two kinds with any evidence available). Switch `ApplicationCatalog`'s hot path from `score`/`scoreASCII` to `match`/`matchASCII` so shape is preserved. Add `package let matchedRanges: [Range<Int>]` to `SearchItem`. Gate `SystemCatalog` ranges on its existing `isTitleMatch` check (`SystemCatalog.swift:377-384`) so offsets into the keyword blob don't get misapplied to the title. Leave `.typo` unhighlighted. Render matched runs with `.semibold` weight against `.secondary` elsewhere (not a background wash, for Increase Contrast compatibility). Build the `AttributedString` in the projection/engine layer, not "cached on the row" — `ResultRow` re-evaluates `body` on hover via `@State private var isHovered`, so `Equatable` conformance doesn't prevent rebuilds as originally assumed.

**Expected impact**: Makes ranking legible for the two row kinds where it's feasible today (apps, settings) — a real but narrower win than "the single most common launcher complaint," since the largest result category (files) can't be covered without an FFFKit change.

**Effort/Risk**: L (touches the just-optimized ApplicationCatalog ASCII/mask hot path; needs a new budgeted perf test per the README rule) / Medium.

**How to verify on Mac**: Extend `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift`'s scoring-budget test with a ranges-materializing variant; print `FLOODLIGHT_BENCH fuzzy_match_with_ranges_us=…`; assert it stays within 1.3x the score-only median, computed only for candidates that reach a visible row (at most 7, `FloodlightMetrics.maximumVisibleResults`), not for every candidate scored. Add `FuzzyMatcher` unit cases per shape.

**Caveats from review**: Effort raised from the original M to L — the accuracy skeptic showed the flagship "vsc → Visual Studio Code" example requires converting `ApplicationCatalog`'s scoring path from `score` to `match`, not merely reading evidence that "already exists" (it's discarded even for applications, not just decoratively unused). Offset semantics need real work: `.acronym(offset:)` is a word index requiring a mapping back to character positions, and `SystemCatalog`'s combined name+keywords candidate means naive highlighting would mark positions past the visible title.

### Rejected ideas

- **F114 — FTS5 trigram index built over a text column that won't contain rich variants**: Premise is speculative (no rich-text capture exists anywhere in the codebase to motivate this), the claimed pre-existing bug can't occur (image capture and its FTS trigger landed in the same commit, so no row predates the trigger), and the proposed repair (`INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')`) is technically wrong for an external-content FTS5 table — it would strip the dimension suffix from every image row, actively causing the drift it claims to fix.


# Clipboard history

## Clipboard history management

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F120 | Capture starts before consent; exclusion list ships empty | High (split: high/medium) | M | Low | confirmed |
| 2 | F117 | "Clear all history…" destroys pins with no confirmation | Medium | S | Low | confirmed |
| 3 | F125 | Exclusion UI is a raw bundle-ID box whose copy promises name matching | Medium | S/M | Low | confirmed |
| 4 | F118 | Deleted/cleared clipboard content survives in DB pages and WAL | Medium | S/M | Low–Med | confirmed |
| 5 | F126 | 1–2 char clipboard queries run locale-aware scan over the full window | Medium | S | Low | confirmed |
| 6 | F123 | Pin/delete keys are non-idiomatic, undocumented, invisible | Medium | S/M | Low | confirmed |
| 7 | F116 | Projection stats disk + JSON-parses every row on every keystroke | Medium | M | Low | confirmed |
| 8 | F122 | Copies over 32 KB are silently dropped, no entry, no message | Medium | M | Low–Med | confirmed |
| 9 | F124 | Clipboard mode has one obscure entry point, resets on dismiss | Medium | M/L | Low | confirmed |
| 10 | F121 | Rich text is discarded on capture and restore | Medium | M/L | Medium | confirmed |
| 11 | F119 | Quick Look leaves full-res clipboard images in /tmp | Low | S/XS | Low | confirmed |

### F120 — Capture starts before consent; exclusion list ships empty

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:139-152` (real defect), `Sources/Floodlight/App/AppDelegate.swift:36` (call ordering, secondary), `Sources/Floodlight/Search/ClipboardExclusionStore.swift:9-18` (empty seed)

**Evidence**:
```swift
LaunchAtLogin.enableOnFirstRun()
clipboardCapture.start()
presentation.launch(initialSetupRequired: OnboardingSession.shouldPresent())
```
```swift
// ClipboardCaptureService.isEnabled
// returns true when the defaults key is unset
```

**Why it costs / what is missing**: A fresh install records everything copied to disk before onboarding is shown, because `isEnabled` defaults to `true` when unset (`ClipboardCaptureService.swift:141-143`) and `poll()` only gates on `isEnabled`/`isPaused`. `ClipboardExclusionStore` seeds an empty set (`ClipboardExclusionStore.swift:16`), so the only first-run protection is the pasteboard-type check (`org.nspasteboard.ConcealedType` / `TransientType` / `com.apple.is-sensitive`). Matching is against `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (`ClipboardCaptureService.swift:48-50, 253-256`), so browser-extension password managers (Bitwarden, LastPass, Dashlane) have the *browser* frontmost and are never excluded regardless of seeding. There is no menu-bar pause and no "ignore next copy."

**Proposal**: Don't bother reordering `start()` — onboarding already shows the clipboard toggle live (`OnboardingView.swift:281-395`) and `poll()` re-reads `isEnabled` every 0.5 s. Instead: (1) make the unset-default `false` while `OnboardingSession.shouldPresent()` is true, keeping `true` as the migration default for users who already completed onboarding — change `ClipboardCaptureService.swift:141-143` and the mirrored getter in `OnboardingSession.swift:40-52` together. (2) Seed `ClipboardExclusionStore` with well-known native bundle IDs, versioned (`clipboard-exclusions-seed-v1`) so existing users get it too, and label it clearly as "native app copies only" — it does not cover browser-extension password fills. (3) Add "Pause clipboard capture" and "Ignore next copy" to the status menu, wired through `isEnabled` (not `pause()`/`resume()`, which are already owned by the session-lock observers at `ClipboardCaptureService.swift:188-206` and would be clobbered on unlock).

**Expected impact**: Converts an invisible, default-on recorder into a consented one for the first-run window, and gives users a working manual escape hatch. Does not solve the browser-extension password-manager gap — no code-only fix covers that.

**Effort/Risk**: M / Low.

**How to verify on Mac**: `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` — fresh `UserDefaults(suiteName:)` combined with an injected `shouldPresent() == true` yields `isEnabled == false`; after onboarding completion it flips to `true`. Manual: `FLOODLIGHT_FORCE_ONBOARDING=1 make run`, copy something during setup, confirm the history stays empty. Add a menu-bar pause test that toggles `isEnabled` and confirms `poll()` skips a copy.

**Caveats from review**: Both skeptics agree on the mechanism; they disagree on where the value is. The accuracy pass rates this high impact (silent default-on secret capture). The value pass argues moving `start()` past onboarding is nearly worthless since onboarding is shown in the same run-loop turn and already re-polls `isEnabled` — the real fix is the unset-default itself. Native-app exclusion seeding misses the dominant password-manager usage path (browser extensions); state that limitation rather than imply the seed list closes the gap.

### F117 — "Clear all history…" destroys pins with no confirmation

**Where**: `Sources/Floodlight/UI/OnboardingView.swift:391`

**Evidence**:
```swift
Button("Clear all history…") {
    session.clearClipboardHistory()
}
.buttonStyle(.bordered)
```

**Why it costs / what is missing**: The ellipsis promises a confirmation sheet that does not exist anywhere in the shell (the only `NSAlert` is unrelated, `AppDelegate.swift:91`). The handler runs straight to `ClipboardHistoryStore.clear()` (`ClipboardHistoryStore.swift:499-508`), a synchronous `DELETE FROM clipboard_entries` that also wipes `pinnedEntries` in memory — pins included, no undo. `prune(olderThan:)` already has the `pinned_at IS NULL` predicate this needs (`ClipboardHistoryStore.swift:516`), so there's no engine-side reason pins get swept.

**Proposal**: Add `clear(includingPinned: Bool)` to `ClipboardHistoryStore`, reusing the `WHERE pinned_at IS NULL` clause already in `prune`. Make "Clear unpinned history…" the primary Settings button; put "Clear everything, including pinned" behind an `NSAlert` naming counts (`state.totalCount`, `pinnedEntries.count` are already tracked, `ClipboardHistoryStore.swift:107-111`). Recompute `state.totalCount` from `queryTotalCount(db:)` after the unpinned delete rather than zeroing it.

**Expected impact**: Removes an irreversible data-loss path from one misclick in Settings; gives users the routine "flush noise, keep pins" gesture.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift` — seed 5 entries, 2 pinned; `clear(includingPinned: false)` leaves exactly 2 rows after reopening the on-disk DB via `makeTemporaryDatabaseURL()`; `clear(includingPinned: true)` leaves zero. `make test`.

**Caveats from review**: Drop the proposal's "wire the same pair into the panel as a ⌘K action" — the footer's "Actions ⌘K" chip (`SearchView.swift:501-521`) actually calls `copySelection()`; there is no ⌘K handler and no actions menu anywhere (`rg` for `kVK_ANSI_K` finds nothing). That's a separate, larger (M+) defect — building an actions palette — and shouldn't be folded into this S-effort fix. Anchor line is 391, not 390 (the finding's original citation).

### F125 — Exclusion UI is a raw bundle-ID box whose copy promises name matching

**Where**: `Sources/Floodlight/Search/ClipboardExclusionStore.swift:44-48` (matching semantics), `Sources/Floodlight/UI/OnboardingView.swift:331,337-364` (mismatched copy and bare-text UI)

**Evidence**:
```swift
func isExcluded(bundleID: String) -> Bool {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return exclusions.withLock { $0.contains(trimmed) }
}
```

**Why it costs / what is missing**: Matching is exact, case-sensitive string equality, but the settings copy at `OnboardingView.swift:331` says "Nothing copied from these app bundle IDs or names will be recorded" — names never match anything. The only input is a free-text field (`OnboardingView.swift:340-343`) with no validation, completion, or picker, so "1Password" or wrong-case "com.1Password.1Password" produces a chip that looks correct and protects nothing. Chips render only the raw ID (`OnboardingView.swift:362-364`), so a typo is invisible afterward. This is the app's only privacy control.

**Proposal**: Replace free text with a `Menu` populated from `NSWorkspace.shared.runningApplications` (filtered to `.regular` activation policy) resolving to `bundleIdentifier` — keyboard-navigable, no file panel needed. Keep the text field as an always-visible fallback for apps not currently running (not behind a disclosure triangle). Render chips with `AppIconCache.shared.icon(for:)` (already exists, `AppIconCache.swift:14-28`) and a resolved display name. Fold case on both write and read — fold at decode time too so already-persisted entries aren't broken by only fixing the comparison. Fix the subtitle to say "bundle IDs only."

**Expected impact**: Makes the app's only clipboard privacy control usable by someone who doesn't know what a bundle ID is; removes a class of silently-ineffective exclusions.

**Effort/Risk**: S (copy fix + case-fold) plus M (running-apps menu + icon chips) — ship the S core first / Low.

**How to verify on Mac**: `Tests/FloodlightTests` — `exclude(bundleID: "Com.Bitwarden.Desktop")` then `isExcluded(bundleID: "com.bitwarden.desktop") == true` after the fold fix, including a case where the stored set already has mixed-case entries from before the change. Manual: `make run` → Settings → Clipboard History → pick a running app, confirm the chip shows icon+name and copying from it records nothing.

**Caveats from review**: Both skeptics reject the NSOpenPanel-to-/Applications idea (mouse-first, wrong tool for a keyboard-first app) in favor of a running-apps menu. Case-folding must apply to the already-persisted `Set<String>` on decode, not just future writes, or existing exclusions silently stop matching once the comparison is fixed.

### F118 — Deleted/cleared clipboard content survives in DB pages and WAL

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistorySQLite.swift:14-16` (pragma gap); `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:476` (delete), `:499` (clear), `:512` (prune)

**Evidence**:
```swift
let schemaSQL = """
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS clipboard_entries (
```

**Why it costs / what is missing**: `secure_delete` is off (SQLite default) and there's no `auto_vacuum`/`VACUUM` anywhere in the repo, so `delete(id:)`, `prune`, and `clear()` only mark pages free — bytes stay until reused, and a deleted 15 MB image (both `png_data` and `tiff_data` are stored, so up to ~30 MB per entry) never shrinks the file. WAL mode means recent rows also sit in `clipboard.sqlite3-wal` until checkpointed, and `clear()`'s bare `sqlite3_exec` return value is discarded, so a failed DELETE can leave the UI showing empty over a populated file.

**Proposal**: Set `PRAGMA secure_delete = ON` every open (already re-issued via `initializeSchema` on each connection). For new databases only, set `PRAGMA auto_vacuum = INCREMENTAL` before the first table create — retrofitting existing DBs needs a one-time `VACUUM`, which should run off the launch path (gated on `PRAGMA auto_vacuum` returning 0), not inside `ClipboardHistoryStore.init`. After `delete`/`clear`/`prune`, coalesce (don't fire per keystroke-delete) a `PRAGMA incremental_vacuum` plus `sqlite3_wal_checkpoint_v2(..., SQLITE_CHECKPOINT_TRUNCATE, ...)`, checking the result since TRUNCATE can return `SQLITE_BUSY` with a live reader. Pair with restrictive posix permissions (0600 file / 0700 dir) on `~/Library/Application Support/Floodlight/clipboard.sqlite3` — currently unset — since that's the cheaper fix for the bigger exposure (the DB is plaintext, unencrypted, readable by any process running as the same user).

**Expected impact**: Deleted entries stop being readable via `sqlite3`/hex dump of the DB file; disk is reclaimed after image deletion. Does not make data forensically unrecoverable (freed disk extents remain filesystem-recoverable) — don't oversell it as "erasure."

**Effort/Risk**: S/M (the VACUUM migration and its scheduling push it past pure-S) / Low–Medium (TRUNCATE can be busy; must check result).

**How to verify on Mac**: Build a temp store, record a distinctive string, delete it, close the store, `strings clipboard.sqlite3 clipboard.sqlite3-wal | grep -c FLOODLIGHT_SECRET_CANARY` — nonzero today, must be 0 after. `ls -la` the DB before/after deleting an image entry to confirm reclamation. Add as an XCTest reading the raw file via `Data(contentsOf:)`.

**Caveats from review**: Category is privacy/hygiene, not correctness (except the unchecked `sqlite3_exec` in `clear()`, which is a genuine correctness bug since `prune` already self-corrects `totalCount` but `clear()` doesn't). `secure_delete` is per-connection, not persisted in the file header — must be reissued every open. `delete(id:)` — the exact "deleted a leaked password" scenario in the finding's own framing — needs the same WAL-checkpoint treatment as `clear`/`prune`, which the original proposal omitted.

### F126 — 1–2 char clipboard queries run locale-aware scan over the full window

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:353` (unbounded filter), `:405-409` (`matchesSearch`)

**Evidence**:
```swift
private static func matchesSearch(_ entry: ClipboardEntry, query: String) -> Bool {
    if entry.text.localizedCaseInsensitiveContains(query) { return true }
    guard let image = entry.image else { return false }
    return "\(image.width)×\(image.height)".localizedCaseInsensitiveContains(query)
}
```

**Why it costs / what is missing**: For queries under 3 UTF-8 bytes, `search(query:)` filters `pinnedEntries` (uncapped) plus up to 1,000 `recentEntries` with `localizedCaseInsensitiveContains`, an `NSString` bridge doing locale-aware Unicode folding per call, on the main actor, synchronously, with no result cap (unlike the FTS path's `LIMIT 200`). This runs on the first two keystrokes of every clipboard search.

**Proposal**: Don't add a precomputed 1 KB folded key (it changes match semantics — a query would stop matching past 1 KB while the FTS path for 3+ chars scans the full text, so lengthening a query could grow the result set). Instead: (1) stop the scan at `searchResultLimit = 200` matches like the FTS path already does, ending most scans early; (2) for pure-ASCII queries, scan `entry.text.utf8` directly with a byte-level case-fold comparison — Swift strings have a contiguous UTF-8 view, no `NSString` bridge, no new per-entry state — falling back to `localizedCaseInsensitiveContains` only for non-ASCII queries (rare at this length gate, since UTF-8 length < 3 is nearly always ASCII).

**Expected impact**: Bounds the scan to ~200 matches and removes the `NSString` bridge for the common ASCII case; medium rather than the originally-claimed "1,000 bridges" since bridging cost per short ASCII string is small and realistic clip text is hundreds of bytes, not the 32 KB cap.

**Effort/Risk**: S (capped scan + ASCII byte-fold) / Low. The alternative cached-key design is M–L / Medium (needs index-aligned invalidation across record/pin/unpin/delete/clear).

**How to verify on Mac**: Add a case to `ClipboardHistoryPerformanceTests` isolating only `"a"`/`"in"` queries (not diluted across the 8-query average the existing test uses) over a window seeded with realistic multi-KB entries; print `FLOODLIGHT_BENCH clipboard_search_short_us=`. `make test-performance`.

**Caveats from review**: Both skeptics converge on rejecting the precomputed-key approach as a semantics regression and recommend the capped-scan + byte-fold instead, which is simpler, lower risk, and needs no new per-entry state.

### F123 — Pin/delete keys are non-idiomatic, undocumented, invisible

**Where**: `Sources/Floodlight/App/FloodlightPanel.swift:368` (`panelCommand`)

**Evidence**:
```swift
static func panelCommand(for characters: String?, shiftHeld: Bool) -> PanelCommand {
    switch characters {
    case "c": .copySelection
    case ".": .togglePin
    case "d": .deleteSelection
    default: .unmatched
    }
}
```

**Why it costs / what is missing**: ⌘. is macOS's cancel idiom; ⌘D is duplicate/bookmark; the platform delete idiom is ⌘⌫, used by every competitor. Neither shortcut appears in `docs/src/content/docs/guides/keyboard-shortcuts.mdx` or the clipboard section of `guides/search.mdx`. The clipboard row's context menu is the file-mode menu (`SearchView.swift:434-449`) offering "Exclude '<title>' from Search," which writes the clip's preview text into the *file/app* blocklist (`SearchCoordinator.swift:391-393`) — meaningless, and can accidentally block a real file whose name matches the copied text. Pin state is signaled by prefixing the title with an emoji (`SearchResultProjection.swift:285,314,348,369`), which VoiceOver reads as part of the item name; a separate `pin.fill` icon already exists too (`:290-291,318`) but the title prefix is redundant and accessibility-hostile.

**Proposal**: Bind ⌘⌫ to delete (keep ⌘D as alias), ⌘P to pin (keep ⌘.); document both in the keyboard-shortcuts page's Clipboard section. Drop the `"📌 "` title prefix (the icon swap already exists) and set `.accessibilityValue("Pinned")` instead. Give clipboard rows their own context menu (Copy, Pin/Unpin, Delete, Copy Path, Reveal) and drop "Exclude from Search." For destructive-delete safety, add a confirm-before-delete specifically for pinned entries rather than a full ⌘Z undo — a real Edit-menu Undo already exists (`AppDelegate.swift:261-265`) for text-field editing, and a competing ⌘Z would conflict with it while typing a filter.

**Expected impact**: Makes the mode's only two management verbs discoverable and platform-idiomatic; removes a nonsense destructive menu item; stops VoiceOver announcing an emoji as part of every pinned item's name.

**Effort/Risk**: S–M (drop the undo mechanism, which was the L-effort part) / Low.

**How to verify on Mac**: Extend `panelCommand` unit tests: keyCode for delete maps to `.deleteSelection`, `"p"` maps to `.togglePin`. Add a `SearchResultProjectionClipboardTests` case asserting a pinned entry's title no longer contains "📌". Manual VoiceOver check: `make run`, VO on, arrow through a pinned row, confirm announcement is "<text>, pinned."

**Caveats from review**: Drop the ⌘Z undo — it collides with the real Edit-menu Undo used by the search field editor, and mechanically requires a new package-level restore API in the engine plus holding deleted blobs in memory (image entries), pushing effort to L. The pin-glyph half of the proposal is smaller than described: the icon swap to `pin.fill` already exists; only the title-prefix removal and accessibility fix are new work.

### F116 — Projection stats disk + JSON-parses every row on every keystroke

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:299` (the `fileExists` call, the most expensive single line), entry point at `:282`

**Evidence**:
```swift
if let localURL = ClipboardInspector.parseLocalPath(text) {
    ...
    let exists = FileManager.default.fileExists(atPath: localURL.path)
    return SearchItem(
```

**Why it costs / what is missing**: `publishClipboardModeResults` runs on every keystroke with no debounce (`SearchCoordinator.swift:502-508`), projecting every entry with no cap: pinned + up to 1,000 recent on an empty query, capped at 200 for a typed query (`ClipboardHistoryStore.swift:349-353,370-373`). Every path-like text row gets a synchronous `FileManager.fileExists` stat — including pinned rows, since `fileExists` sits outside the pinned short-circuit at `:290,309`. Non-path rows run `parseURL`/`parseHexColor`/`parseCodeHint`, each independently calling `trimmingCharacters(in:)` on the full (up to 32 KB) text — up to four full-string copies per row per keystroke — and `parseCodeHint` runs `JSONSerialization.jsonObject` when the text is brace/bracket-delimited. All on the main actor.

**Proposal**: Compute one bounded trimmed prefix (`text.prefix(2048)`) once in `buildClipboardTextRow` and feed it to all four parsers, collapsing the repeated full-string `trimmingCharacters` copies into one. Drop the per-row `fileExists` at `:299` entirely — existence is already re-checked at preview time (`SearchCoordinator.swift:427-429`) and in the inspector (`ClipboardInspector.swift:107`); render a missing-file badge there instead. Also fix `previewTitle` (`SearchResultProjection.swift:396-400`), which splits and rejoins the full 32 KB text per text row — likely costlier than the classification work this finding targets.

**Expected impact**: Removes O(rows) syscalls per keystroke and cuts string-copy overhead in the classification path from ~4x full-text to 1x bounded-prefix. Medium rather than the original "zero I/O" claim, since clipboard search already runs an SQLite FTS5 query on the main actor every keystroke regardless (`SearchCoordinator.swift:666`, `ClipboardHistoryStore.swift:363-385`) — the projection was never going to be zero-I/O.

**Effort/Risk**: M / Low. (The schema-column classification-cache variant from the original proposal is not worth it: existing rows would still need a parse fallback with no backfill, and it pushes UI vocabulary from the shell across into the engine store.)

**How to verify on Mac**: Add `Tests/FloodlightTests/SearchResultProjectionClipboardPerformanceTests.swift` seeding 1,000 mixed entries (URLs, JSON blobs, `/Users/...` paths, plain text), warm up, 11 samples × 100 iterations, median via `getrusage`, print `FLOODLIGHT_BENCH clipboard_projection_us=`, `XCTAssertLessThan(median, 3_000)`. `make test-performance`. Cross-check with `sudo fs_usage -w -f filesys Floodlight | grep -c stat64` while typing in clip mode, before/after.

**Caveats from review**: The real hazard isn't syscall count (bounded at ~200/keystroke, single-digit ms on local SSD) — it's a path-like clip pointing at a stale network/unmounted volume, where one `fileExists` blocks the main actor for seconds and freezes the panel. Fix that (drop the stat) before worrying about aggregate stat count.

### F122 — Copies over 32 KB are silently dropped, no entry, no message

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:8` (the `maxTextByteCount = 32_000` constant, consumed at both drop sites), duplicate gate at `Sources/Floodlight/Search/ClipboardCaptureService.swift:281`

**Evidence**:
```swift
guard text.utf8.count <= Self.maxTextByteCount else {
    return nil
}
```

**Why it costs / what is missing**: 32,000 bytes (~5,000 words) discards a long email, mid-sized source file, or JSON response — twice over, once at capture (`ClipboardCaptureService.swift:281`, commented "Rule 5: skip entirely") and again in the store. No row, no truncation, no message; the user just doesn't find the clip in history. Two existing tests hard-code the 32,000 boundary (`ClipboardHistoryStoreTests.swift:60`, `ClipboardHistoryStorePropertyTests.swift:12`), so raising the cap requires updating the documented capture rules, not just a constant.

**Proposal**: Raise the cap modestly (~128 KB, not 256 KB — every `recentEntries` window entry is held in memory up to `inMemoryRecentWindowLimit = 1,000`, so an 8x cap raise multiplies worst-case resident memory 8x). Truncate at the capture site (`ClipboardCaptureService.swift:281`) instead of rejecting, store a `truncated INTEGER` column, badge the row and the inspector's Information section. Before raising anything, cap the per-row preview work that would otherwise scale with the new limit: `previewTitle` (`SearchResultProjection.swift:396-401`) must operate on a `text.prefix(N)`, and `parseCodeHint`'s `JSONSerialization` call must refuse to run past a few KB.

**Expected impact**: Converts silent, unexplained data loss into either a stored or an explicitly-truncated clip. Medium rather than high — this is a UX-polish/correctness fix, not a hot-path win, and the storage/perf side effects need their own guardrails (see proposal).

**Effort/Risk**: M (schema migration + rewritten capture-rule tests + preview-path prefix caps) / Low–Medium (a truncated entry pasted back delivers silently partial data unless the truncated flag also blocks or flags the paste action, not just the inspector display).

**How to verify on Mac**: `Tests/FloodlightEngineTests/ClipboardHistoryStoreTests.swift` — a 100 KB string records and round-trips through a reopened on-disk store; a 200 KB string records as `truncated` with the flag set and a bounded stored length. Re-run `make test-performance`, seeding the existing suite with a handful of 100–128 KB entries to catch the preview-path regression.

**Caveats from review**: Anchor the finding at the shared constant (`ClipboardHistoryStore.swift:8`), not just one of the two call sites that reads it — raising the constant fixes both drops at once. Don't raise the cap without capping the preview/classification work first, or clipboard-mode projection cost scales with the new limit for every row, not just the large ones.

### F124 — Clipboard mode has one obscure entry point, resets on dismiss

**Where**: `Sources/FloodlightEngine/Search/SearchMode.swift:92-100`

**Evidence**:
```swift
if let token = parseTokenAndRemainder(query),
   token.typedKeyword.lowercased() == "clip"
{
    let context = ClipboardContext(
        typedKeyword: token.typedKeyword,
        queryAtEntry: token.remainder
    )
    return (.clipboard(context), token.remainder)
```

**Why it costs / what is missing**: The only way in is typing exactly `clip` then Tab; `clip` isn't a `KeywordEngine` entry, so it produces no ranked row and no "⇥ Search…" hint (`tabCompletionHint` only consults the keyword registry, `SearchCoordinator.swift:292-302`) — typing "clipboard" gets nothing. The status menu has no Clipboard History item (`AppDelegate.swift:141-192`). `FloodlightPanel.hide()` calls `model.reset()` (`FloodlightPanel.swift:211`), which resets `mode = .local`, so the round trip is retyped every time. There's no dedicated global hotkey (`GlobalHotKeyRegistration` supports exactly one registration). Settings does have a Clipboard History section (`OnboardingView.swift:281-300`), so the feature isn't totally undiscoverable, but nothing there states the `clip`+Tab entry gesture.

**Proposal**: Split into three independently-shippable legs. (1) S: accept `clipboard`/`history` as aliases in `SearchMode.entered`, emit a ranked local clipboard row for prefixes of those words, add "Clipboard History" to the status menu. (2) M: a second, user-configurable global hotkey via `GlobalHotKeyRegistration` — currently built around one `activeRegistration`/one `onPressed` closure, so this needs a second defaults key, recorder UI, and multi-registration bookkeeping. (3) S: a shell-side change callback from `ClipboardCaptureService` into the coordinator so the list republishes on a new capture while `isClipboardMode` — drive it from the capture service (which already knows when it recorded), not from a new engine-side generation token.

**Expected impact**: Medium — turns a genuinely obscure entry point into a discoverable one. The "live-update" leg is lower value than it sounds: the panel already hides on `NSApplication.didResignActiveNotification` (`FloodlightPanel.swift:76-86`), so a copy made in another app dismisses and resets the panel before staleness would even be visible; only an in-panel copy or a background/scripted copy while the panel stays open triggers the stale-list symptom.

**Effort/Risk**: M–L overall (S+M+S across the three legs) / Low.

**How to verify on Mac**: `Tests/FloodlightEngineTests` — `SearchMode.transition` accepts "clipboard" and "history". `SearchCoordinatorClipboardModeTests` — enter clip mode, `store.record(text:)` a new entry, assert `coordinator.results` grows with no query change. Manual: `make run`, check `GlobalHotKeyRegistration` reports both registrations.

**Caveats from review**: Don't claim "no way to discover without reading the docs" — Settings does have a Clipboard History section; the actual gap is that neither Settings nor any in-app hint states the `clip`+Tab gesture. Alias caution: `exitClipboardFieldText` hardcodes `"clip"` (`SearchMode.swift:145`) as the canonical spelling and must become alias-aware too, or Esc/Shift-Tab restores the wrong text when the user entered via an alias.

### F121 — Rich text is discarded on capture and restore

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:280` (capture, `.string`-only); `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:42-46` (`writeString`, restore, `.string`-only)

**Evidence**:
```swift
guard let text = observer.string(forType: .string), !text.isEmpty else { return }
guard text.utf8.count <= ClipboardHistoryStore.maxTextByteCount else { return }
store.record(text: text, sourceAppBundleID: bundleID)
```

**Why it costs / what is missing**: Capture reads only `.string`; RTF, HTML, and `public.url` flavors on the same pasteboard item are dropped. Restoring writes only `.string` back. Copying a styled paragraph and restoring it from history silently degrades it to plain text. Note: because restore is *already* plain-text-only unconditionally, the finding's "no paste-as-plain-text" framing is backwards — plain-text-on-paste is the current universal behavior, not a missing escape hatch; the real gap only appears once rich capture is added (then you need an opt-in "Copy with formatting," not a plain-text alias).

**Proposal**: Read `.rtf`/`.html` in `poll()`, store in nullable BLOB columns via the ALTER-TABLE migration path already used for image columns (`ClipboardHistorySQLite.swift:207-216`), with their own size cap (HTML from Word/Google Docs commonly exceeds the 32 KB text cap even for a short paragraph — don't reuse `maxTextByteCount`). Restore rich flavors alongside `.string` in `writeString` for a default rich paste; add a separate, explicit "Copy plain text" action for when the user wants formatting stripped. Must also resolve: dedup currently keys on `text` alone (`ClipboardHistoryStore.swift:285`), so a formatting-only change would be swallowed as a duplicate; and the image branch runs before the text branch (`ClipboardCaptureService.swift:266-278`), so any rich copy carrying a TIFF/PNG snapshot is already routed to the image path and never reaches text capture at all.

**Expected impact**: Medium. Stops silent formatting loss on rich round-trips through history — real, but scoped to text entries only (images and files already round-trip correctly).

**Effort/Risk**: M/L (new columns, new cap, dedup-key fix, capture-ordering fix, plus a keybinding for the plain-text/rich-copy toggle whose exact combo needs picking — ⇧⌘V is blocked by `performSearchTextEditingCommand`'s shift-blind `"v"` case at `FloodlightPanel.swift:401`, and ⌥⌘C is indistinguishable from ⌘C since `panelCommand` doesn't currently receive the option flag) / Medium.

**How to verify on Mac**: `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` — a scripted observer offering `.string` + `.rtf` records both; `writeString` on a scratch `NSPasteboard(name:)` puts both types back, assert `pasteboard.data(forType: .rtf) != nil`. Sanity-check the round trip by hand in TextEdit with `make run`.

**Caveats from review**: Drop "no paste-as-plain-text" as an independent motivation — restore is already plain-only today. Reverse the binding: keep plain-text as the default `⌘C`, add an opt-in richer copy, rather than adding a plain-text escape from a rich default. Neither proposed keybinding (⇧⌘V, ⌥⌘C) works without widening `panelCommand`'s dispatch signature to carry the option/shift modifier — that's part of the effort, not a footnote.

### F119 — Quick Look leaves full-res clipboard images in /tmp

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:451` (`clipboardImagePreviewURL`)

**Evidence**:
```swift
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let fileURL = tempDir.appendingPathComponent("\(id).\(ext)")
if !FileManager.default.fileExists(atPath: fileURL.path) {
    try? data.write(to: fileURL)
}
```

**Why it costs / what is missing**: Pressing Space on an image entry writes the full original blob to `NSTemporaryDirectory()/FloodlightClipboardPreviews/<id>.<ext>`; nothing ever deletes these files. `deleteSelection`/`clearHistory` only touch the SQLite rows. Note the security framing in the original write-up doesn't hold up: `NSTemporaryDirectory()` on macOS is the per-user, mode-0700 `/var/folders/.../T`, not "world-readable," and the app's own DB is already unencrypted plaintext at the same trust level — so this isn't a privilege escalation, and macOS's dirhelper periodically sweeps TMPDIR by atime, so growth isn't literally "forever." What does survive: an image the user explicitly deletes for privacy keeps its full-resolution bytes on disk for up to a few days.

**Proposal**: Skip the URL-tracking-plus-launch-sweep design in the original proposal — it's more machinery than needed. Instead, write to a fixed filename (`preview.png`/`preview.tiff`) that gets overwritten each time, and `removeItem(at:)` it from `QuickLookController.close()`, which `FloodlightPanel.hide()` already calls before `model.reset()` (`FloodlightPanel.swift:209,211`). That caps accumulation at one file and clears residue on every panel dismiss with no new coordinator state.

**Expected impact**: Low. Stops one image's worth of full-resolution residue from persisting past the preview session; doesn't close a "plaintext leak outside app storage" (there isn't one) and doesn't matter for typical usage given macOS's own TMPDIR sweep.

**Effort/Risk**: XS (fixed filename + delete-on-close) / Low.

**How to verify on Mac**: `make run`, enter clip mode, Space on an image, `ls -la $TMPDIR/FloodlightClipboardPreviews` — confirm exactly one file, and confirm it's removed after dismissing the panel (Esc).

**Caveats from review**: Both skeptics independently reject the original proposal's `QLPreviewingController` suggestion as infeasible (that protocol is for a Quick Look *app extension*, not a way to feed `QLPreviewPanel` in-memory bytes — `QLPreviewItem` is URL-only here) and reject the 0600-permissions step as pointless inside an already-0700 directory. Reclassify from "correctness"/security to minor privacy hygiene; drop "world-readable" and "forever" from the framing.

### Rejected ideas

None — all eleven findings for this section were confirmed by both skeptic passes (with corrections incorporated above); none were refuted.

## Clipboard power-user convenience

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F128 | Exclude-from-Search on a clipboard/web row corrupts mode + poisons blocklist | Medium | S | Low | Confirmed |
| 2 | F136 | ⌘C on an image row copies "Screenshot" text, not the image | Medium | S | Low | Confirmed |
| 3 | F135 | Return on a URL clipboard entry copies instead of opening it | Medium | S | Low | Confirmed |
| 4 | F133 | Drag-out drops pinned/multi-line text and images to a mangled title string | Medium | S | Low | Confirmed |
| 5 | F127 | Footer advertises ⌘K "Actions"; unbound, chip does ⌘C instead | Medium | S (relabel) / M (real menu) | Low | Confirmed |
| 6 | F138 | ⌘. pins instead of canceling; ⌘. and ⌘D undocumented | Medium | S | Low | Confirmed |
| 7 | F132 | Clipboard type filter always resets to All on mode entry | Low | S | Low | Confirmed |
| 8 | F130 | ⌃N/⌃P do not move selection (field command map has no moveUp/moveDown) | Medium | S | Low | Confirmed |
| 9 | F129 | No quick-paste digit shortcut; ⌘5–⌘9(+⌘0) are dead keyspace | Medium | S–M | Low | Confirmed |
| 10 | F134 | No text transforms on paste (trim/case/JSON/quotes/URL-extract) | Medium | M | Low | Confirmed |
| 11 | F141 | Source app captured but unsearchable; no `img:`/`file:`/`from:` prefix syntax | Medium | M–L | Low | Confirmed |
| 12 | F131 | No dedicated global hotkey for Clipboard mode; registration class holds only one | Medium | M (real blocker is narrower than filed) | Medium | Confirmed |
| 13 | F140 | Pins are permanent but unaddressable — no keyword expansion for snippets | Medium | L | Medium | Confirmed |
| 14 | F139 | No multi-select — paste stack / paste-all-joined structurally impossible | Medium | M (stage 1) | Medium | Confirmed |

Ranking rationale: items 1–6 are correctness/trust defects with S effort and immediate payoff — fix first. Items 7–10 are cheap ergonomic wins. 11–14 are net-new features, correctly larger in scope; F131 and F140 in particular are larger than their findings claim once the real blockers (identified by review) are accounted for.

### F128 — Exclude from Search corrupts clipboard/web mode and poisons the blocklist

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:391` (root cause), `Sources/Floodlight/UI/SearchView.swift:434-448` (actual defect site — the unconditional context menu)

**Evidence**:
```swift
func excludeFromSearch(_ item: SearchItem) {
    blocklistStore.block(id: item.id)
    blocklistStore.block(name: item.title)
    let updatedCandidates = publication.sourceCandidates.filter {
        !blocklistStore.isBlocked(name: $0.title, id: $0.id)
    }
    publication = projectLocal(
        candidates: updatedCandidates,
        selectedFilter: selectedFilter,
        selection: publication.selection?.id == item.id ? nil : publication.selection,
        progress: publication.progress
    )
}
```

**Why it costs / what is missing**: The row context menu attaches the same `.contextMenu` (with a destructive Exclude item) to every row regardless of mode. `excludeFromSearch` has no mode guard and always republishes via `projectLocal`. `projectClipboard` **and** `projectWeb` both return `sourceCandidates: []`, so `updatedCandidates` is empty and the coordinator swaps in a local publication (calculator/keyword/web-fallback rows) while `mode` stays `.clipboard` or `.web` — the two-pane clipboard board or web-fallback UI keeps rendering, now showing the wrong rows. Separately, `block(name: item.title)` persists the clipboard row's title (pinned rows carry the "📌 " prefix) into the UserDefaults-backed blocklist, permanently hiding any real file/app whose name equals that title.

**Proposal**: Guard the root cause and the surface. In `excludeFromSearch`, `guard case .local = mode else { return }`. In `SearchView.swift`'s `.contextMenu`, only show the Exclude item when `mode` is `.local`; give clipboard rows their own verb set (Pin/Unpin, Copy, Copy Path, Reveal, Delete). Add a regression test that `excludeFromSearch` in clipboard or web mode leaves mode/rows/blocklist untouched.

**Expected impact**: Removes a one-click path that corrupts mode state and silently, persistently degrades local search results (recoverable only via Settings → excluded rules, so undiscoverable rather than truly permanent).

**Effort/Risk**: S / Low.

**How to verify on Mac**: Extend `Tests/FloodlightTests/SearchCoordinatorClipboardModeTests.swift`: enter clipboard mode, call `excludeFromSearch` on a row, assert `isClipboardMode` stays true, rows unchanged, `blocklistStore.rules` empty. Add the same case for web mode. `swift test --filter SearchCoordinatorClipboardMode`. Manual: right-click a clipboard entry, choose Exclude, observe today's swap to local/web rows; check Settings' blocklist list for the spurious entry.

**Caveats from review**: Both skeptics confirmed the mechanism but corrected severity and scope. (1) Web mode is equally affected (`projectWeb` also returns `sourceCandidates: []`) — the finding under-scoped the bug to clipboard only; the fix must be `guard case .local = mode`, not `!isClipboardMode`. (2) The mode-corruption half is self-healing on the next keystroke or filter click (both re-enter the clipboard/web branch and republish correctly) — the *lasting* damage is the blocklist entry, not the rendered-mode glitch. (3) The blocklist match is exact-string (folded), not substring — "hides every file named Invoice containing the word" is wrong; the real hazard is a clipboard row whose title exactly equals a real file/app name (e.g. a copied "Invoice.pdf"). (4) It's recoverable via Settings → blocklist (`OnboardingSession.unblockRule`), not undiscoverable-forever. (5) Any new clipboard context-menu verbs must call `model.select(item)` first since the coordinator's mutation methods act on `selectedItem`, not the right-clicked row — this is a pre-existing latent bug shared with "Show in Finder" today.

---

### F136 — ⌘C on an image entry copies the word "Screenshot", not the image

**Where**: `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:246-247`

**Evidence**:
```swift
case .copyImage:
    item.title.hasPrefix("📌 ") ? String(item.title.dropFirst(2)) : item.title
```

**Why it costs / what is missing**: `copy(_:)` (the "put on pasteboard without dismissing" verb, used by ⌘C, ⌥Return, and the footer "Actions" chip) routes all kinds through `copyValue(for:)`, which for images returns the row's **display name** — literally `"Screenshot"` for a screen capture (`ClipboardImageCapture.displayName`), not the bytes. `activate` (the Return verb) does the right thing for images via `writeImageDataToClipboard`, so the same entry behaves inconsistently depending on which key the user presses.

**Proposal**: Route `copyValue`'s `.copyImage` case through the same `clipboardImagePayload(id)` + `writeImageDataToClipboard` path `activate` already uses (minus `onDismiss()`). Cheaper alternative worth considering first: write **both** the display-name string and the PNG/TIFF data onto the same pasteboard item, so text-only and image-aware paste targets each get something useful without reversing the documented design.

**Expected impact**: Makes the copy verb behave consistently for all three clipboard entry kinds; removes a surprise on the exact feature (image capture) the last several commits targeted.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Extend `Tests/FloodlightTests/SelectedResultActionPerformerTests.swift`: `copy(_:)` on a `.copyImage` row invokes the image-write path and does not call `onDismiss`. `swift test --filter SelectedResultActionPerformer`. Manual: copy a screenshot, `clip`+Tab, select it, ⌘C, then ⌘V into Preview — expect the image.

**Caveats from review**: This is more contested than most items in this section — it is a deliberate, documented design decision, not an oversight. `docs/adr/0005-selected-result-action-execution.md:38` states the policy explicitly ("`.copyImage` uses the image display name … so Return can paste Finder-ready file references or PNG/TIFF bytes while Option-Return / ⌘ C still copy a path or display-name string"), and `Tests/FloodlightTests/SelectedResultActionPerformerTests.swift:127` (`clipboardImageCopyWritesTheDisplayNameWithoutDismissing`) locks it in. The doc citation in the original finding (search.mdx:28-29) is wrong — it's at search.mdx:67-68. Both skeptics still judged the current behavior low-value (a generated placeholder string like "Screenshot" is not a useful text payload for any paste target) and recommended reversing or supplementing the ADR rather than treating it as an untouched bug — but doing so requires amending the ADR and rewriting the named test, not just the switch arm. Effort bumped from a bare "one switch arm" to include the doc/ADR/test update.

---

### F135 — Return on a URL clipboard entry copies it; there is no way to open the link

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:334` (the `action: .copy(text)` argument; the `SearchItem` initializer spans lines 326-338)

**Evidence**:
```swift
return SearchItem(
    id: "clipboard:\(entry.id)",
    title: title,
    subtitle: subtitle,
    kind: .clipboard,
    action: .copy(text),
    iconSource: iconSource,
    score: SearchItemRanking.calculator - index,
    modifiedAt: entry.createdAt
)
```

**Why it costs / what is missing**: Three lines above this, the projection already detects the row is a link (`ClipboardInspector.parseURL(text) != nil` picks the link icon), and the inspector renders the domain. But the action is unconditionally `.copy(text)`. Return copies + dismisses; ⌘Return maps to `revealSelection()`, which no-ops because `fileURL` is nil for a URL text entry (`reveal`'s first line is `guard let url = item.fileURL, url.isFileURL else { return }`). To open a link from clipboard history you must copy, dismiss, focus a browser, and paste — four steps for a case the UI visually flags as a link.

**Proposal**: Route ⌘Return by content instead of rebinding plain Return (which is the mode's primary "Paste to `<App>`" gesture and must not change). In `SearchCoordinator.revealSelection()`, before delegating to the file-reveal path, check whether the selected item is a clipboard row whose text parses as an http(s) URL (`ClipboardInspector.parseURL`); if so, call the existing `open(_:for:query:)` path (currently `private` — expose a narrow entry point) instead of reveal. Add "Open" as a real context-menu action for link rows (today's "Open" menu item calls `model.activate`, which for a clipboard row just copies again — fix that at the same time). Do the same for path-row text entries that have a real `fileURL` but no open affordance today.

**Expected impact**: Turns clipboard history into a usable link history; removes a keyboard-consistency gap on a brand-new feature (Return already means "obvious action" everywhere else per the docs).

**Effort/Risk**: S / Low.

**How to verify on Mac**: Add to `SearchCoordinatorClipboardModeTests` (extend `ScriptedActionEffects` with an `onOpen` hook): record `"https://example.com/a?b=1"`, run the ⌘Return path, assert `onOpen` fired with exactly that URL and `onWrite` did not. Negative cases: `javascript:alert(1)`, `file:///etc/passwd` must NOT open (`parseURL` already requires http/https, pin that guarantee). `swift test --filter SearchCoordinatorClipboardMode`.

**Caveats from review**: Do not adopt the finding's "better still" alternative of moving Return itself to `.open(url)` for link rows — `ClipboardFooterBar` labels Return "Paste to `<targetAppName>`" as the mode's primary gesture; rebinding it for link rows breaks the single most common clipboard-manager action (grab a URL, paste it where you were). Keep the fix scoped to ⌘Return (and the context menu). Also: `SelectedResultActionPerformer.reveal` is not the only `fileURL` consumer as originally stated — QuickLook and drag-out also depend on it, so any "Open" addition should sit alongside those, not replace reveal.

---

### F133 — Dragging a text clipboard entry out drops the row title, not the payload

**Where**: `Sources/Floodlight/UI/SearchView.swift:450-456`

**Evidence**:
```swift
.onDrag {
    guard let url = item.fileURL else {
        return NSItemProvider(object: item.title as NSString)
    }
    return NSItemProvider(contentsOf: url)
        ?? NSItemProvider(object: url.path as NSString)
}
```

**Why it costs / what is missing**: For non-path text rows and all image rows, `item.fileURL` is nil, so drag falls back to `item.title` — which for text is the space-joined, newline-destroyed, pushpin-prefixed *preview* (`previewTitle(for:)` joins lines with a space), not the real payload (`item.action` carries `.copy(text)` unused here). For images, the title is a generated placeholder ("Screenshot", "PNG Image"), so dragging a screenshot drags that literal string, not image bytes. Local-path text rows and `.copyFiles` rows already drag correctly because they do have `fileURL`.

**Proposal**: Keep the existing `fileURL`-first branch (it already handles path-backed rows correctly), and add a fallback that reads `item.action` instead of `item.title`: `.copy(text)` → `NSItemProvider(object: text as NSString)`; images → reuse `SearchCoordinator.clipboardImagePreviewURL(for:)` (the same temp-file materialization QuickLook already uses; currently `private`, needs a narrow public accessor) with `NSItemProvider(contentsOf:)`.

**Expected impact**: Makes drag-out lossless for multi-line/pinned text and functional at all for images.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Extract a pure `dragPayload(for:imageData:)`-style function, unit test in `Tests/FloodlightTests/SearchViewRenderingTests.swift` — a pinned multi-line entry must yield the exact original text including `\n`, not the title. Manual: pin a two-line snippet, drag from the Clipboard list into TextEdit (expect both lines, no pushpin); drag an image entry into Preview (expect an image).

**Caveats from review**: Scope is narrower than the finding implies — local-path text rows and `.copyFiles` rows already drag correctly today (they have `fileURL`); only plain non-path text and image rows are broken. Keep the `guard let url = item.fileURL` check *first*, not switch on `item.action` first as originally sketched — action-first would regress the already-working local-path text row. The image fix should reuse the existing `clipboardImagePreviewURL` temp-file machinery rather than building a new `UTType.png` data provider from scratch — one path, already exercised by QuickLook. Deferring the "move pin state out of the title into a real `isPinned` field" refactor is fine; it's a larger, separate cleanup (touches the engine `SearchItem` struct's memberwise init, all projection builders, and test fixtures).

---

### F127 — Footer advertises ⌘K for "Actions"; ⌘K is bound to nothing and the button copies instead

**Where**: `Sources/Floodlight/UI/SearchView.swift:501-513` (button), `Sources/Floodlight/App/FloodlightPanel.swift:368-386` (`panelCommand`, no `k` case)

**Evidence**:
```swift
Button {
    model.copySelection()
} label: {
    HStack(spacing: 5) {
        Text("Actions")
            .font(.system(size: 11.5, weight: .medium))
        HStack(spacing: 2) {
            Text("⌘")
            Text("K")
        }
```

**Why it costs / what is missing**: `panelCommand(for:shiftHeld:)` maps only `c`, `l`, `r`, `y`, Return, `.`, `d` — no `k`; no menu builder registers a ⌘K equivalent either. Pressing ⌘K in Clipboard mode is a genuine no-op. The chip's click handler is `model.copySelection()` (⌘C's action) — the same keystroke on the field editor, via `performSearchTextEditingCommand`, can also shadow this when text is selected, so chip and ⌘C agree only when no query text is selected. This is a keyboard-first launcher visibly documenting a shortcut that does not exist, in the one place a user goes looking for shortcuts.

**Proposal**: Ship the minimal honest fix first — relabel the chip "Copy ⌘C" and keep `copySelection()`, since that's zero-risk and makes the two things agree today. Build the real action menu as a separate, larger follow-on: a SwiftUI `Menu`/`.contextMenu` on the chip (no AppKit plumbing needed) populated with the clipboard verb list, with `⌘K` wired in later via a new `panelCommand` case once the state to back it exists.

**Expected impact**: Eliminates a shortcut that's documented in the UI and dead in code.

**Effort/Risk**: S (relabel) or M (real menu) / Low.

**How to verify on Mac**: Table-test `panelCommand` over every character the footer/docs advertise, failing when UI copy names a chord the keymap lacks. Manual: press ⌘K in Clipboard mode, confirm either the new menu opens or (minimal fix) the chip label now reads "Copy ⌘C".

**Caveats from review**: Both skeptics preferred the relabel-first ordering over building the full menu immediately: routing `⌘K` into a SwiftUI popover from AppKit's `handleCommandKeyEquivalent` needs new observable state on `SearchCoordinator`, which is already near the `file_length: 665` SwiftLint ratchet (currently ~687 lines) — landing the menu as originally scoped would also force a file split. The relabel is S effort and ships the fix for the actual defect (label lies about behavior) without that cost.

---

### F138 — ⌘. for pin fights the macOS cancel convention; ⌘. and ⌘D are undocumented

**Where**: `Sources/Floodlight/App/FloodlightPanel.swift:380-383`

**Evidence**:
```swift
case ".":
    .togglePin
case "d":
    .deleteSelection
```

**Why it costs / what is missing**: ⌘. has meant "cancel" system-wide since before OS X, and this codebase itself treats `cancelOperation(_:)` as Escape in the search field. Because `performKeyEquivalent` runs before the responder chain, the panel's binding wins — a user pressing ⌘. expecting to dismiss instead silently pins the selected row. Neither ⌘. nor ⌘D appears in `keyboard-shortcuts.mdx`; ⌘D is destructive (delete) with no confirmation.

**Proposal**: Move pin to ⌘P (genuinely free — no `p` case anywhere, no Print menu item), dropping ⌘. as the pin binding (system convention wins over an app-local one). Document every clipboard chord in `keyboard-shortcuts.mdx` under a new "Clipboard mode" section. For ⌘D, add a confirmation for pinned entries, since delete writes straight through to SQLite with no tombstone.

**Expected impact**: Stops a system-convention keystroke from performing a silent state mutation while in Clipboard mode; makes existing chords discoverable.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Update the keymap table tests in `FloodlightPanelTests.swift` and `FloodlightPanelStressTests.swift` (lines ~50, 57, 66 reference the current bindings) for the new pin chord, and assert `"."` now falls through to `.unmatched`. Manual: press ⌘. in Clipboard mode, confirm it dismisses rather than pinning.

**Caveats from review**: The collision is scoped to Clipboard mode only — both `.togglePin` and `.deleteSelection` are already guarded by `guard model.isClipboardMode else { return false }`, so ⌘. behaves normally (cancels) everywhere outside Clipboard mode; the finding read as if the binding always steals ⌘., which overstates it. The pin state change is also visible (pushpin icon + re-sort), not fully silent, and reversible with one more keystroke — so impact is medium, not high. A related, arguably bigger discoverability bug found in the same area: the footer's "Actions ⌘K" chip (F127) has no real binding either — fix both in the same documentation/keymap pass.

---

### F132 — Entering Clipboard mode always resets the type filter to All

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:321-322`

**Evidence**:
```swift
if enteringClipboard {
    publishClipboardModeResults(selectedFilter: .all, selection: nil)
}
```

**Why it costs / what is missing**: Every other clipboard republish (typing, pin, delete) preserves `selectedFilter`; only mode-entry hard-codes `.all`. A user who lives in the Images filter (the exact use case the image-capture work targeted) has to re-press ⌘4 every time they re-enter Clipboard mode.

**Proposal**: Add an in-memory `lastClipboardFilter` on `SearchCoordinator`, set it in `selectFilter(_:)` when in clipboard mode (after the existing early-return-on-unchanged guard), and use it instead of the `.all` literal on entry. Treat cross-launch persistence via UserDefaults as an optional follow-on, not required for the core fix — restoring a filter across a relaunch can make the history look empty on first glance, which is its own (small) UX cost.

**Expected impact**: Removes one keystroke per clipboard *session* for anyone who uses a type filter (within a session it already sticks; only re-entry costs the keystroke).

**Effort/Risk**: S / Low.

**How to verify on Mac**: Extend `SearchCoordinatorClipboardModeTests`: select Images, Escape, re-enter, assert `selectedFilter == .images`.

**Caveats from review**: Both skeptics downgraded impact from the filed "medium" to low — the reset only costs one keystroke per re-entry, not per keystroke, and `reset()`'s wipe on dismissal is via the shared `idleLocalPublication()` default, not a separate assignment. Recommend shipping in-memory-only first; skip the UserDefaults persistence unless the maintainer specifically wants cross-launch memory.

---

### F130 — ⌃N/⌃P do not move the selection

**Where**: `Sources/Floodlight/UI/FloodlightTextField.swift:37-57`

**Evidence**:
```swift
switch commandSelector {
case #selector(NSResponder.insertNewline(_:)),
     #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
    ...
case #selector(NSResponder.cancelOperation(_:)):
    .cancel
...
default:
    nil
}
```

**Why it costs / what is missing**: `fieldCommand` has no case for `moveUp(_:)`/`moveDown(_:)`. Since the query field is always focused, arrow-key selection movement exists only via raw `NSEvent` keyCode handling in the panel's local monitor (keyCodes 125/126) — the emacs-style ⌃N/⌃P chords AppKit would otherwise translate into `moveDown:`/`moveUp:` selectors fall through unhandled to the field editor and just move the text caret.

**Proposal**: Add `case #selector(NSResponder.moveDown(_:)): .moveSelectionDown` and the `moveUp` twin, plus matching `FieldCommand` cases and `onMoveDown`/`onMoveUp` closures wired to `model.moveSelection(by: 1/-1)`.

**Expected impact**: Adds home-row selection movement for touch typists / emacs-binding users at near-zero cost. Arrow keys already work today, so this is parity, not a missing capability.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `Tests/FloodlightTests/SearchFieldKeymapTests.swift` currently has a test (`unrelatedSelectorsFallThroughToTheFieldEditor`) that explicitly asserts `moveUp:`/`moveDown:` return nil — that test must be rewritten, not just extended. `swift test --filter SearchFieldKeymap`. Manual: type a query, press ⌃N/⌃P, confirm the highlighted row moves.

**Caveats from review**: The current nil-mapping is intentional and locked by an existing test (`SearchFieldKeymapTests.swift:78-88`) — this change reverses a prior deliberate decision, not merely fills a gap; update that test as part of the change. Drop the proposal's ⌘↑/⌘↓ "bonus" — the panel's raw-keyCode monitor consumes all modifier combinations on the arrow keys before the field editor ever sees `moveToBeginningOfDocument:`/`moveToEndOfDocument:`, so it wouldn't work as described without separate plumbing in the monitor itself. Impact is medium, not high, since arrow keys already work.

---

### F129 — No quick-paste digit shortcut; ⌘5–⌘9 (and ⌘0) are dead keyspace

**Where**: `Sources/Floodlight/App/FloodlightPanel.swift:319-330` (consume-all), `:443` (`filterShortcutIndex` caps at 5)

**Evidence**:
```swift
if Self.commandDigit(for: characters) != nil {
    if let index = Self.filterShortcutIndex(for: characters) {
        let options = model.filterOptions
        if options.indices.contains(index) {
            model.selectFilter(options[index].filter)
        }
    }
    // Consume every command-digit combination, including currently
    // unused slots, so it never reaches the field editor and beeps.
    return true
}
```

**Why it costs / what is missing**: `filterShortcutIndex` only recognizes digits 1–5; `commandDigit` accepts any digit 0–9 and the surrounding code unconditionally consumes it. So ⌘6–⌘9 (and ⌘0) are swallowed and discarded in every mode, and in Clipboard mode (only 4 chips) ⌘5 is dead too. Reaching, say, the third-most-recent clip costs 3+ keystrokes (↓↓Return) with no direct-addressing shortcut, while a chunk of the ⌘-digit keyspace sits unused.

**Proposal**: Do not reuse ⌘-digit for quick-paste (it's spoken for by the filter contract and the ⌘1-5 docs). Bind quick-paste to a modifier combo that has no system or in-app claim, and reuse `SearchCoordinator.activate(_:)` (already select+performAction) as `activateVisibleRow(at:)`. Render a trailing digit chip on the first `FloodlightMetrics.maximumVisibleResults` (7) rows when `item.kind == .clipboard`.

**Expected impact**: Cuts "grab one of the last few clips" from 3+ keystrokes to 1; reclaims dead keyspace.

**Effort/Risk**: S–M / Low.

**How to verify on Mac**: Table-test a pure quick-paste-index function; coordinator test that `activateVisibleRow(at:)` performs the Nth row's action. Manual: hold the chosen modifier, press 1–7, confirm the right entry lands with no beep.

**Caveats from review**: The originally proposed ⌃1–⌃9 binding is wrong and must not be used — Control+digit is macOS's default "Switch to Desktop N" Mission Control shortcut, intercepted by the WindowServer before any app-local event monitor sees it, so it would be silently dead for anyone with multiple Spaces. Both skeptics recommend ⌘⌥-digit instead, which has no system or in-app claim. `activateVisibleRow` needs no new coordinator machinery — `SearchCoordinator.activate(_:)` already is select+performAction, so effort is closer to S than the M originally filed.

---

### F134 — No text transforms on paste

**Where**: `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:158` (Return/paste path) and `:240` (`copyValue`, the ⌘C/⌥Return path)

**Evidence**:
```swift
private func copyValue(for item: SearchItem) -> String {
    switch item.action {
    case let .copy(value):
        value
    ...
```

**Why it costs / what is missing**: Every paste returns stored bytes verbatim — no trim, case change, JSON pretty/minify, quote-strip, or URL-extract. These are the handful of transforms a developer clipboard-manager audience reaches for hourly, and none exist. ("Paste as plain text" is a non-issue — capture only ever stores plain strings, so there's no rich-formatting-to-strip.)

**Proposal**: Put transforms in the engine as a pure `package enum ClipboardTextTransform` (trim, lowercase/uppercase/titleCase, jsonPretty/jsonMinify, stripQuotes, extractURLs) — no UI import, satisfies `engine-no-ui-frameworks`, fully unit-testable. Surface via the existing row context menu (there is no ⌘K action menu today — correct the wiring target) as a "Paste as…" submenu, and consider a modifier chord for the last-used transform.

**Expected impact**: Removes a round-trip to a scratch editor for common clipboard chores.

**Effort/Risk**: M / Low.

**How to verify on Mac**: `Tests/FloodlightEngineTests/ClipboardTextTransformTests.swift` with a table per case including adversarial inputs (empty, whitespace-only, 8KB minified JSON, invalid JSON returning nil, CRLF, non-ASCII title-case). `swift test --filter ClipboardTextTransform`.

**Caveats from review**: Both skeptics found the proposal's UI target wrong — there is no ⌘K action menu anywhere in the codebase (the footer's "Actions ⌘K" chip is the F127 defect, not a real menu); attach "Paste as…" to the existing generic row `.contextMenu` instead, and make it clipboard-aware since it currently is not. The suggested ⇧⌘Return chord is not free either — `FloodlightTextField.fieldCommand` currently lumps Shift+Return into the same case as plain Return with no shift check, so it already resolves to a specific existing behavior (reveal-in-Finder-adjacent); claiming it repurposes an existing alias and needs a docs update, not a green-field binding. Scope v1 down to trim/case/jsonPretty-minify/stripQuotes; skip "last-used transform" persistence for the first cut.

---

### F141 — Source app is captured but unsearchable; no type-prefix query syntax

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:343` (`search(query:)`), `:405` (`matchesSearch`, text-only)

**Evidence**:
```swift
package func search(query: String) -> [ClipboardEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return stateLock.withLock { state -> [ClipboardEntry] in
        guard let db = state.db else { return [] }
        if trimmed.isEmpty {
            return state.pinnedEntries + state.recentEntries
        }
        ...
```

**Why it costs / what is missing**: `ClipboardCaptureService.poll()` records `sourceAppBundleID` on every entry and the inspector displays it, but `matchesSearch`/the FTS5 index cover only `entry.text`. "The URL I copied out of Safari an hour ago" is only findable by remembering its contents. There is also no `img:`/`file:`/`txt:` prefix for touch typists — though this half is smaller than filed, since ⌘1–⌘4 already provide a keyboard path to the same four filters (documented in `keyboard-shortcuts.mdx`).

**Proposal**: Add a pure `ClipboardQuery.parse(_ raw: String)` recognizing `from:<app>` (the genuinely new capability) and optionally `img:`/`file:`/`txt:` as chip-selecting synonyms (not new filtering — auto-select the existing chip rather than filtering the entries array directly, which would corrupt the chip counts computed from that array). For `from:` combined with residual text, add `search(query:sourceApp:)` at the SQL level with a new index on `source_app_bundle_id` — post-filtering after the store's internal 200-row limit is applied would silently drop matches.

**Expected impact**: Makes an already-captured dimension (source app) searchable; the type-prefix half is a nice-to-have synonym for an existing binding, not new capability.

**Effort/Risk**: M–L / Low.

**How to verify on Mac**: Table-test `ClipboardQuery.parse`: bare text, each prefix, unknown prefix stays literal, `from:` with no value, a colon inside a URL not misread as a prefix. If the SQL overload + index are added, extend `ClipboardHistoryPerformanceTests.swift` and confirm the printed `FLOODLIGHT_BENCH clipboard_search_us` median stays under the existing bound.

**Caveats from review**: Drop "gives the type filters a keyboard path" from the expected impact — ⌘1–⌘4 already do this per the docs; the `img:`/`file:`/`txt:` prefixes are at best a discoverable synonym. The `from:` fix must not post-filter after the store's internal result-count limit (200) is applied, or deep matches silently vanish — push the app filter into the SQL WHERE clause. Do not filter the `entries` array before it reaches the projection's filter-count computation, or the chip counts (All/Text/Files/Images) go wrong.

---

### F131 — No dedicated global hotkey for Clipboard mode

**Where**: `Sources/Floodlight/App/GlobalHotKeyRegistration.swift:277` (single-registration dispatch gate), `:357` (hard-coded `kVK_Space`)

**Evidence**:
```swift
private func allocateIdentifier() -> GlobalHotKeyIdentifier? {
    guard let id = nextIdentifier else { return nil }
    nextIdentifier = id == UInt32.max ? nil : id + 1
    return GlobalHotKeyIdentifier(
        signature: GlobalHotKeyIdentifier.floodlightSignature,
        id: id
    )
}
```

**Why it costs / what is missing**: Reaching Clipboard mode from another app costs ⌘Space, `c`,`l`,`i`,`p`, Tab — six keystrokes for the second-most-used surface, with no status-menu entry or global hotkey as a shortcut. `GlobalHotKeyRegistration` dispatches by equality against one `activeRegistration`, and `CarbonGlobalHotKeySystem.register` hard-codes `kVK_Space`, so a second, independently-keyed hotkey isn't expressible today without changes.

**Proposal**: The real blockers, once corrected, are narrower than the finding states (see caveats) — forward `firstIdentifier` through the production convenience initializer to avoid the identifier collision, add a `keyCode` to a *new*, separate hotkey value type (not `FloodlightShortcut`, which is a two-case radio-button enum baked into the onboarding picker UI), parameterize the UserDefaults preference key so a second hotkey doesn't clobber the first's persisted choice, and register a default (e.g. ⇧⌘V, user-changeable, off-by-default-on-registration-failure since it collides with "Paste and Match Style" in many apps) whose handler calls a new `SearchCoordinator.enterClipboardMode()`.

**Expected impact**: Six keystrokes to one for the clipboard entry point.

**Effort/Risk**: M (once correctly scoped) / Medium.

**How to verify on Mac**: Extend `Tests/FloodlightTests/GlobalHotKeyRegistrationTests.swift` with two distinct registrations, asserting each event fires only its own handler and no two registrations share an identifier. Manual: set the new shortcut in Settings, trigger from another app, verify Clipboard mode opens and ⌘Space still works; check Console.app for hot-key failure logs if the default collides.

**Caveats from review**: This finding's diagnosis is only half right and its effort is overstated in one direction, understated in another. (1) The single-`activeRegistration` dictionary refactor the finding proposes is NOT required — the designated initializer already accepts a `firstIdentifier` parameter; only the production convenience initializer fails to forward it, so a much smaller fix (forward that parameter) avoids the identifier collision without touching the dispatch architecture. This drops effort from L toward M. (2) Reusing `FloodlightShortcut` for the new hotkey (as the original proposal suggested) would be a real bug — that type is a `CaseIterable` two-case radio-button enum wired directly into the onboarding picker UI (`displayName`, `ShortcutPreview`, a total `fallback` function), and adding a case breaks all of that; use a separate type instead. (3) A second, smaller blocker the finding missed: `FloodlightShortcut.preferenceKey` is a single hardcoded UserDefaults key shared by save/load, so a second hotkey using the same type would clobber the first's persisted choice — needs its own key. (4) Blast radius on tests/docs is wider than filed (~170 references across four test files plus the keyboard-shortcuts doc page). (5) A cheaper partial alternative exists and should be priced first: a "Clipboard History" item with a key equivalent in the status menu, or a ranked `clip` keyword row so Return works instead of requiring Tab — neither gives a true global (from-any-app) entry point, but both are much cheaper.

---

### F140 — Pinned entries are permanent but unaddressable — no keyword expansion for snippets

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:512-516` (`prune` spares pins); `ClipboardHistorySQLite.swift:65` (pins loaded unconditionally into memory)

**Evidence**:
```swift
package func prune(olderThan cutoff: Date) {
    stateLock.withLock { state in
        guard let db = state.db else { return }
        let sql = "DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?;"
```

**Why it costs / what is missing**: Pinning already gives permanence (spared from pruning, all pinned entries cached in memory at startup) — structurally, pins are saved snippets. But they're reachable only by entering Clipboard mode and scrolling/filtering. `KeywordEngineRegistry` already implements keyword-addressed search for `yt`/`claude`; nothing wires pins into it, so an email signature or PR template sits in history findable only by fuzzy match against its own contents.

**Proposal**: Add a nullable `keyword` column (the ALTER TABLE migration pattern already exists for image columns) plus a `setKeyword(id:keyword:)` store method rejecting collisions with registry keywords. Resolution belongs in `SearchCoordinator` (which owns `clipboardStore`), not in `SearchResultProjection` (a pure value-context enum with no store access) — pass a resolved snippet match into the local context, consulted alongside the existing `addressedResult(for:)` call, scanning only the already-resident `pinnedEntries` array (no disk I/O on the query path). Restrict keyword matching to text-kind entries — an image entry's "text" is a placeholder/dimensions string, not useful as a snippet body.

**Expected impact**: Turns the existing pin mechanism into a real snippet system reachable in two keystrokes from the main field.

**Effort/Risk**: L / Medium.

**How to verify on Mac**: Round-trip persistence test for a keyword across store close/reopen; collision-rejection test; projection test that the exact first token (not substring) triggers the row. Add a case to `SearchItemRankingPerformanceTests` with ~200 keyworded pins resident and confirm added per-keystroke cost stays under budget, printing a new `FLOODLIGHT_BENCH` line.

**Caveats from review**: The proposal's placement was wrong in the original filing — `SearchResultProjection` is pure over value contexts with no store access; resolution must happen in `SearchCoordinator`. The cited `query-path-no-sync-disk-read` ast-grep rule doesn't actually gate this (it's scoped to specific FloodlightEngine indexing functions), but the in-memory-only design is still correct practice. Effort is L-to-XL, not plain L, once accounted for: the panel has exactly one text input, so assigning a keyword to a pin needs a net-new keyboard-first interaction design, plus a CONTEXT.md domain-language update (Keyword-Addressed Search currently means destination-selection, not snippet-expansion) and docs updates.

---

### F139 — No multi-select: paste stack and paste-all-joined are structurally impossible

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:4-11`

**Evidence**:
```swift
struct SearchResultPublication: Equatable {
    let sourceCandidates: [SearchItem]
    let allRows: [SearchItem]
    let visibleRows: [SearchItem]
    let filterOptions: [SearchFilterOption]
    let selectedFilter: SearchResultFilter
    let selection: SearchResultSelection?
    let progress: SearchResultProgress
```

**Why it costs / what is missing**: `selection` is a single optional; every mutation path (`selecting(_:)`, `moveSelection(by:)`, `reconcile(_:in:)`) assumes exactly one selected row. Assembling something from several clips (spreadsheet columns, a set of file paths, commit-message fragments) needs N full summon/pick/paste cycles today.

**Proposal**: Ship additive marking (not true multi-select) as a self-contained stage: an in-memory ordered array of marked entry IDs on `SearchCoordinator` (no `OrderedSet` dependency — the package has no swift-collections), a numbered badge per row, a footer count, and a "Paste All" that joins marked entries' text with a separator and runs the existing single-payload paste. This touches neither `SearchResultPublication` nor the projection, so ranking/reconciliation invariants are untouched. Treat a real paste-stack (queue + pop-per-⌘V) as a separate, higher-risk follow-on blocked on synthesizing paste events (CGEvent + Accessibility permission), which the codebase has no precedent for today.

**Expected impact**: Collapses N summon/paste cycles into one for multi-clip text/path assembly — a narrower, real use case.

**Effort/Risk**: M (stage 1 only) / Medium.

**How to verify on Mac**: Table-test a pure mark-set value type (toggle idempotence, insertion-order preservation, join-with-separator, empty-set join). Coordinator test that Paste All writes in mark order via `ScriptedActionEffects.onWrite`.

**Caveats from review**: `OrderedSet` is unavailable — the package depends only on fff-swift; use a plain `[String]`. Drop the ⌥-click marking trigger from the original proposal (adds new modifier-aware click plumbing for no benefit in a keyboard-first app); use a dedicated chord instead — note ⌘K is already spoken for (falsely) by the F127 footer chip, so don't reuse it. Image rows have no text payload to join — either exclude them from marking or skip silently in the join, and say which explicitly rather than leaving it implicit. The "paste stack" stage 2 is not merely "medium risk" as filed — with zero existing paste-synthesis code in the app, it requires a new Accessibility-permission-gated capability, which is a materially different, higher-risk feature; file it separately.

---

### Rejected ideas

- **F137 — `clearHistory()` has no caller, so history can't be wiped from the panel.** Refuted: a "Clear all history…" button already exists and is wired in the settings/onboarding window (`OnboardingView.swift` → `OnboardingSession.clearClipboardHistory()`), operating on the same store instance the panel uses. `SearchCoordinator.clearHistory()` is a genuinely dead, redundant duplicate (only referenced by a test) — worth deleting as routine cleanup, but there is no missing user-facing capability here.


# Beyond the five

## Beyond the five: build, testing, hygiene, docs

19 opportunities, all independently confirmed by code (17) or split-vote plausible (2, both explained below). Ranked by impact/effort; every impact figure below is the skeptic-adjusted one, not the original submission's.

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F147 | Shell tests open the real clipboard DB and UserDefaults on every construction | medium | S–M | low | confirmed |
| 2 | F146 | release.yml ships a notarized DMG with zero gates run | medium | S | low | confirmed |
| 3 | F143 | Clipboard search budget measured against unrepresentative in-memory/text-only fixture | medium | S | low | confirmed |
| 4 | F144 | FFF index-scan benchmark permanently skipped, asserts no bound | low–medium | S | low | confirmed |
| 5 | F156 | autoresearch.sh silently drops/blanks metrics on a parse miss | low | S | low | confirmed |
| 6 | F150 | Contributor build docs say Swift 5.10; manifest requires 6.4 | low | S | low | confirmed |
| 7 | F145 | CI never runs `make bundle`; packaging scripts untested until release | medium | S | low | confirmed |
| 8 | F153 | SwiftLint complexity ratchet has drifted — stale offenders, dead symbol, real slack | low | S | low | confirmed |
| 9 | F152 | Shipped clipboard shortcuts (⌘. pin, ⌘D delete) and Settings pane undocumented | medium | S | low | confirmed |
| 10 | F149 | README Features/architecture/privacy sections omit clipboard, keyword engines, assistant CLI | medium | S | low | confirmed |
| 11 | F148 | No ADR for Clipboard History despite CONTEXT.md terms and 8-file footprint | medium | S | low | confirmed |
| 12 | F154 | pages.yml uses floating action tags while ci.yml/release.yml pin by SHA | medium | S | low | confirmed |
| 13 | F151 | README links to a dead docs anchor (`#sources-not-yet-integrated`) | low | S | low | confirmed |
| 14 | F157 | No CI job has `timeout-minutes`; notarytool wait is unbounded | low | XS–S | low | confirmed |
| 15 | F142 | 48 stray .bc files + a DMG (11.6 MB) sit untracked-by-gitignore in repo root | medium | S | low | confirmed |
| 16 | F158 | Periphery excludes all of Tests/ (20.6k lines, 62% of the Swift tree) from the dead-code gate | medium | S | low | confirmed |
| 17 | F160 | Every non-release build reports version 0.1.0 build 1 | low | S | low | confirmed |
| 18 | F155 | Periphery's index-store path is hardcoded to arm64 | low | S | low | confirmed |
| 19 | F159 | Engine gets no optimization/CMO settings of its own; split never measured | low | S | medium | plausible |

---

### F147 — Shell tests are not hermetic: real clipboard DB and UserDefaults leak into every test run

**Where**: `Sources/Floodlight/App/OnboardingSession.swift:93-98` (also `Sources/Floodlight/Search/SearchCoordinator.swift:101-103`, `Sources/Floodlight/UI/FloodlightConfigurationWindowController.swift:41-44`)

**Evidence**:
```swift
blocklistStore: BlocklistStore = BlocklistStore(),
clipboardExclusionStore: ClipboardExclusionStore = ClipboardExclusionStore(),
clipboardStore: ClipboardHistoryStore = (try? ClipboardHistoryStore()) ??
    ClipboardHistoryStore.inMemory(),
```

**Why it costs / what is missing**: The no-arg `ClipboardHistoryStore()` resolves to `~/Library/Application Support/Floodlight/clipboard.sqlite3` (`ClipboardHistoryStore.swift:36-52`), creating the directory on the way. `BlocklistStore()` and `ClipboardExclusionStore()` default to `UserDefaults.standard`. All 17 `OnboardingSession(...)` constructions in `OnboardingTests.swift` and `OnboardingSessionStressTests.swift`, plus `ApplicationConfigurationWindowControllerTests.swift:316-325`, pass an isolated `defaults:` suite for shortcut/launch keys but silently fall through to the real store for these three. The blast radius is larger than the original finding stated: `SearchCoordinator.swift:101-103` carries the identical default, and `SearchCoordinatorStressTests.swift:14`, `EndToEndSearchTests.swift:55`, `SearchCoordinatorRunningApplicationTests.swift:23`, `SearchResultProjectionTestSupport.swift:8`, `SearchCoordinatorIntegrationTests.swift:33`, `SearchCoordinatorTests.swift:352`, and `SearchCoordinatorWebModeTests.swift:28` all omit the override too — well over 20 real-DB opens per `swift test` run. Nothing calls `clear()` today (`DELETE FROM clipboard_entries`, `ClipboardHistoryStore.swift:503`), so no damage has happened yet — but `clearClipboardHistory()` has exactly one caller, the Clear button in `OnboardingView.swift:392`, and it has zero test coverage. One new test for that button wipes a real developer's clipboard history, invisibly to CI.

**Proposal**: Remove the three defaulted stores from `OnboardingSession.init`, `SearchCoordinator.init`, and `FloodlightConfigurationWindowController.init` — production is unaffected since `AppDelegate.swift:318-325` already supplies all three explicitly. Add a shared test helper in `Tests/FloodlightTests` (not `FloodlightTestSupport`, which depends only on the engine and cannot import the shell-only `ClipboardExclusionStore`) that returns an in-memory `ClipboardHistoryStore` plus exclusion/blocklist stores over a `UserDefaults(suiteName:)` clone. Route all ~24 call sites through it — this also lets it absorb the `makeDefaults()` copy-pasted privately in five other test files. Do not add an env-guard fallback (`FLOODLIGHT_TEST_ISOLATION`); it fights the codebase's existing constructor-injection style. Then add the missing test: Clear from Settings empties what the panel shows.

**Expected impact**: Makes `swift test` side-effect-free on a developer machine; unblocks writing tests for Clear/retention/exclusion, which cannot be written safely today.

**Effort/Risk**: S–M (mechanical, precedent already exists in `ClipboardHistoryStoreTests`/`SearchCoordinatorClipboardModeTests`, which already thread `.inMemory()` explicitly) / low.

**How to verify on Mac**:
```bash
ls -l ~/Library/Application\ Support/Floodlight/clipboard.sqlite3*
swift test --filter OnboardingTests
ls -l ~/Library/Application\ Support/Floodlight/clipboard.sqlite3*   # mtime + -wal changed today
defaults read com.floodlight.search   # before/after — confirm real prefs untouched after fix
```

**Caveats from review**: Both skeptics confirmed the mechanism and raised the same correction — the blast radius extends to `SearchCoordinator.init` and ~7 more test files beyond the 17 originally cited, so the fix must cover that constructor too. One skeptic downgraded effort from M to S/M given the existing `.inMemory()` precedent in the suite; both rejected the env-guard fallback as inconsistent with the codebase's DI style. Impact downgraded from the original framing to medium — today's actual damage is zero (nothing calls `clear()`), the severity is latent.

---

### F146 — release.yml publishes a notarized DMG without running a single gate or test

**Where**: `.github/workflows/release.yml:16` (single job, no `needs:`), build step at `:67-68`, publish at `:207-218`

**Evidence**:
```yaml
      - name: Build Floodlight
        run: make bundle
      - name: Import the Developer ID certificate
      - name: Publish the GitHub Release
        run: |
          gh release create "$GITHUB_REF_NAME" \
            .build/Floodlight.dmg \
            --verify-tag --generate-notes --latest \
            --title "Floodlight $version"
```

**Why it costs / what is missing**: The release job's only steps are: validate tag, validate secrets, stamp plist, `make bundle`, sign, DMG, notarize, publish. No `make check`, `make test`, `make test-performance`. `ci.yml:11-15` triggers only on `pull_request`/`push:main`, so a tag on a hotfix branch, a cherry-pick, or an amended commit ships a signed, notarized, `--latest` DMG that no gate has ever seen. `ci.yml:8-9` states the decoupling is deliberate for lint policy ("shipping stays decoupled from lint policy") — reasonable for lint, not for tests or the latency budgets. `make bundle` → `swift build -c release` (`Makefile:44-45,66`) does mean a non-compiling commit can't ship, and `codesign --verify --deep --strict` + `spctl --assess` run inside `bundle.sh`/`release.yml`, so it's not *entirely* unverified — but no test, no SwiftLint/ast-grep/architecture/Periphery gate, no perf budget ever runs.

**Proposal**: Add a cheap provenance guard rather than a full `needs: verify` job (which roughly doubles release wall-clock): assert the tagged SHA is an ancestor of `origin/main` and that a green CI run exists for it.
```bash
git fetch --no-tags origin main   # checkout is depth-1; need history first
git merge-base --is-ancestor "$GITHUB_SHA" origin/main
gh run list --commit "$GITHUB_SHA" --workflow CI --status success --json databaseId --jq 'length'
```
Check first whether `environment: release` (`release.yml:18`) already carries GitHub environment protection rules (required reviewers, branch/tag restrictions) in repo settings — if so this guard is partly redundant, but still adds the missing "tests actually ran" check that environment rules can't express.

**Expected impact**: Removes the path by which an untested commit becomes the `--latest` public download.

**Effort/Risk**: S / low.

**How to verify on Mac**: Not a latency change — verify by rehearsal on a fork. Push a tag on a non-main-ancestor commit and confirm the new guard fails before signing; tag a green main commit and confirm it passes. Locally: `git merge-base --is-ancestor $(git rev-parse HEAD) origin/main; echo $?`.

**Caveats from review**: Both skeptics confirmed the gap but softened "no gate has ever seen it" to "no test/lint/perf gate" — a release-config compile plus codesign/spctl does run. One skeptic flagged that `release.yml:22`'s default depth-1 checkout means `git merge-base --is-ancestor` needs `fetch-depth: 0` or an explicit fetch first, or it fails for the wrong reason — folded into the proposal above. Both noted `environment: release` may already carry invisible protection rules worth checking before adding redundant guards. Impact adjusted from the original to medium.

---

### F143 — Clipboard search budget is measured against an unrepresentative fixture

**Where**: `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:8,23-32`

**Evidence**:
```swift
func testClipboardHistorySearchPerformanceBudget() throws {
    let store = ClipboardHistoryStore.inMemory()
```

**Why it costs / what is missing**: `inMemory()` opens `:memory:` (`ClipboardHistoryStore.swift:22-25`), never exercising the file-backed store production actually opens at `indexStorage/clipboard.sqlite3` with WAL (`SearchCoordinator.swift:201-205`, `ClipboardHistorySQLite.swift:15-16`). More importantly, the fixture inserts 1,000 pure-`.text` entries, so the `if kind == .image` branch that reads `thumbnail_png` blobs (`ClipboardHistorySQLite.swift:145-155`) never runs — yet the FTS SELECT uses `entryColumns`, which includes `thumbnail_png`, for up to `searchResultLimit = 200` rows (`ClipboardHistoryStore.swift:365-376`). A user with 200 matching screenshots gets 200 thumbnail blobs materialized per keystroke, synchronously on the main actor (`SearchCoordinator.swift:5-7,666`), and the 2 ms budget has never seen that shape. One skeptic further noted 3 of the 8 benchmark queries (`""`, `"a"`, `"in"`) are under the 3-UTF-8-byte threshold and bypass SQLite entirely (`ClipboardHistoryStore.swift:352-361`), diluting the measured median further — so the actual coverage gap is worse than the raw description suggests.

**Proposal**: Add an image-heavy case to the existing test: seed 1,000 entries of which 200 are `.image`, using a new multi-KB fixture (production thumbnails are 128×128 PNGs from `thumbnailPointSize = 64`/`thumbnailScale = 2`, `ClipboardImageCapture.swift:7-8,61` — realistically a few KB; note `Tests/FloodlightTestSupport/ClipboardImageTestData.swift:9` is currently `Data(repeating: 0xEF, count: 32)`, 32 opaque bytes, NOT a realistic thumbnail, so this fixture must be created new). Print a distinct `clipboard_search_image_us` FLOODLIGHT_BENCH key. Do NOT add a separate disk-backed (`ClipboardHistoryStore(databaseURL:)`) case — both skeptics agreed WAL/`synchronous=NORMAL` govern writes, not the read path being measured, and 1,000 rows fit the default page cache after warm-up, so it would be a near-duplicate number for no signal. Do NOT drop `thumbnail_png` from the search SELECT as the original proposal suggested — `SearchResultProjection.swift:376-382` renders every clipboard row's icon from `entry.image?.thumbnailPNGData`, so lazy-by-id fetching would push a synchronous per-row SQLite read onto the main actor during projection, violating `tools/ast-grep/rules/query-path-no-sync-disk-read.yml`. If the new test shows a real stall, fix by capping stored thumbnail bytes or lowering `searchResultLimit` for image-heavy results, not by restructuring the SELECT.

**Expected impact**: Makes the one budget guarding a per-keystroke SQLite query cover the shape that actually ships; likely reveals the image-heavy case sitting well above 2 ms.

**Effort/Risk**: S (narrowed from the original M once the disk-backed case and SELECT change are dropped) / low.

**How to verify on Mac**: `make test-performance` and read the new `clipboard_search_image_us` line. Allocation angle: `swift test -c release --filter ClipboardHistoryPerformanceTests` under Instruments' Allocations template, watching bytes attributed to `ClipboardHistorySQLite.readBlob`.

**Caveats from review**: Both skeptics confirmed the core mechanism (untested thumbnail-decode path at 200-row scale). Both independently flagged that `ClipboardImageTestData.thumbnail` is 32 bytes, not a realistic thumbnail, so the proposal's claim that the fixture "already exists" was wrong. One skeptic explicitly recommended dropping the disk-backed variant and the SELECT-restructuring rider as unjustified/risky; both are removed above. Effort downgraded S→S (was M in the original) with those two pieces cut.

---

### F144 — FFF index-scan benchmark is permanently skipped and asserts no latency bound

**Where**: `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:161-163` (gate), `:211` (the assertion that exists instead of a budget)

**Evidence**:
```swift
guard ProcessInfo.processInfo.environment["FLOODLIGHT_RUN_INDEX_BENCH"] == "1" else {
    throw XCTSkip("Set FLOODLIGHT_RUN_INDEX_BENCH=1 to run the filesystem benchmark.")
}
...
XCTAssertEqual(indexedFiles, 2_500)   // scanMilliseconds is printed above, never asserted
```

**Why it costs / what is missing**: `FLOODLIGHT_RUN_INDEX_BENCH` is set nowhere — not in `Makefile`, `scripts/`, `.github/workflows/ci.yml`, or `autoresearch.sh` — so the test always skips. Even run manually, `scanMilliseconds` is computed and printed but the only assertion is a correctness check on file count. `autoresearch.sh:39-42` also doesn't parse `expanded_fff_scan_ms` (confirmed at line 207, not 203 as first drafted), nor two other emitted keys, `filter_summary_us` and `settings_search_us` (`SearchPerformanceTests.swift:115`). Both skeptics corrected the framing sharply: `rescan()`'s only production caller is `ApplicationCatalog.refreshIfNeeded` (`ApplicationCatalog.swift:79-105`), a non-blocking, mtime-conditional background refresh — NOT the path behind ⇧⌘R or scope changes, which go through `changeRoot`/`fff_restart_index` (`FFFIndex.swift:417-431,647-668`) instead. So this is not "the gate on every rebuild," it's an unbudgeted background-refresh cost. It's also not the only unbudgeted hot path: `testSourceSearchImmediateSnapshotBudget` uses `ScriptedFileSource()`, a test double, so real FFF query latency has no budget either.

**Proposal**: Do not invert the env gate to run-by-default — that contradicts the suite's own documented philosophy (`scripts/test-performance.sh:9-12`: "Tightening [budgets] below runner noise makes the gate flaky, which costs more than the regression it would catch") and this test builds 2,500 real files plus 7 full rescans. Instead: (1) add `XCTAssertLessThan(scanMilliseconds, <order-of-magnitude bound>)` at line 211 — the `waitForScan` helper (`:288-298`) polls at 1 ms granularity, so only a coarse bound is measurable; (2) add a nightly `schedule:` workflow that sets the env var, runs the test, and appends the FLOODLIGHT_BENCH line to the step summary; (3) add `expanded_fff_scan_ms` (and the two other missing keys) to `autoresearch.sh`'s parse list, sequenced after the test actually runs somewhere.

**Expected impact**: Restores regression detection on the background application-catalog rescan path — real but narrower than "gates every keystroke."

**Effort/Risk**: S / low.

**How to verify on Mac**:
```bash
FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark
# repeat 5x, record max, set bound ≈ 3× max
hyperfine --warmup 1 'FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark'
```

**Caveats from review**: Both skeptics independently traced `rescan()`'s single caller and concluded the "gates ⇧⌘R and scope change" claim is wrong — it gates a background app-catalog refresh instead. Both rejected the "run by default, opt out" inversion as contradicting the repo's own noise-tolerance philosophy; the nightly-schedule fallback (already in the original proposal) should be primary, not secondary. One skeptic noted `testSourceSearchImmediateSnapshotBudget` also uses a scripted double, so this isn't uniquely "the only unbudgeted hot path." Impact downgraded accordingly.

---

### F156 — autoresearch.sh drops metrics on the floor and fails at the worst moment

**Where**: `autoresearch.sh:39-42`

**Evidence**:
```bash
APP_SEARCH_US=$(grep "fast_application_search_us=" "$PERF_LOG" | sed -E 's/.*fast_application_search_us=([0-9.]+).*/\1/' | head -n 1)
```

**Why it costs / what is missing**: Two real defects, one overstated claim. (1) Three FLOODLIGHT_BENCH keys the test suite emits are never parsed: `clipboard_search_us` (`ClipboardHistoryPerformanceTests.swift:72`), `expanded_fff_scan_ms` (`SearchPerformanceTests.swift:207`), and `filter_summary_us` (`SearchPerformanceTests.swift:115`). (2) Each assignment is a pipeline ending in `head -n 1`, whose exit status is always 0 — so `set -eu` cannot catch a renamed key, and a miss silently produces `METRIC search_latency_us=` with no value. (3) Line 44 feeds `STARTUP_MS` straight into `python3 -c "print(f'{(float(\"${STARTUP_MS}\")*1000):.3f}')"`; an empty capture raises `ValueError` and, under `set -e`, aborts the whole script *after* the gates and `make bundle` have already run — the one failure mode that does fire, fires at the worst possible time with a traceback instead of a diagnosis. The original finding's "no size assertion" framing is wrong: `binary_size_bytes` (line 51) is already emitted from `stat -f%z` at line 32, and `deliverable_size_bytes` (the `.app` bundle, line 47) is autoresearch's actual primary metric, not `binary_size_bytes` as originally stated — only `unstripped_binary_size_bytes`/`saved_strip_bytes` from `bundle.sh:27` are genuinely unharvested.

**Proposal**: Extract a `metric()` helper that fails loudly on a miss:
```bash
metric() {
  value=$(sed -nE "s/.*$1=([0-9.]+).*/\1/p" "$PERF_LOG" | head -n 1)
  [ -n "$value" ] || { echo "autoresearch: metric $1 not found in $PERF_LOG" >&2; exit 1; }
  printf '%s' "$value"
}
```
Route all parses through it. Add the three missing keys. Skip restructuring the size-capture path (line 19) — `bundle.sh`'s size numbers are already duplicated elsewhere and not worth the churn.

**Expected impact**: Makes the metric pipeline fail fast with a named cause instead of emitting blanks or a late traceback.

**Effort/Risk**: S / low.

**How to verify on Mac**:
```bash
PERF_LOG=/dev/null sh -c 'V=$(grep "nope=" /dev/null | sed -E "s/.*nope=([0-9.]+).*/\1/" | head -n 1); echo "METRIC x=$V"'
# prints METRIC x= today — confirms the silent-blank bug
```
After the fix, rename a FLOODLIGHT_BENCH key in a test and confirm `./autoresearch.sh` exits non-zero with a named metric.

**Caveats from review**: Both skeptics corrected the `set -eu` mechanism — the actual cause is the trailing `head -n 1` (always exit 0), not "command substitution in assignments is exempt" (which is false; `VAR=$(false)` does trip `set -e`). Both flagged that autoresearch.sh is a standalone single-commit harness referenced by nothing in `Makefile`/`scripts/`/`.github/workflows` — it is not the project's CI dashboard, which independently already surfaces every FLOODLIGHT_BENCH line via the step summary. Impact downgraded from the original to low as a result.

---

### F150 — Contributor build docs say Swift 5.10; manifest requires 6.4

**Where**: `docs/src/content/docs/development/building.mdx:11`

**Evidence**:
```
- Xcode command-line tools with Swift 5.10 or later
```

**Why it costs / what is missing**: `Package.swift:1` is `// swift-tools-version: 6.4`; `Package.swift:85` sets `swiftLanguageModes: [.v6]`; two upcoming features are tied by comment to "Approachable Concurrency in Xcode 27 / Swift 6.4." `README.md:35` gets it right ("Xcode 27 or newer (Swift 6.4)") and all CI jobs pin `runs-on: xcode-27`. A contributor following the docs page gets a manifest parse failure before a single file compiles. The same page's step 2 is bare `make test`, with no mention of `make install-tools` or `make check` anywhere under `docs/src/content/docs` — the gate CI actually runs (`ci.yml:55,66`) is invisible to a new contributor. `docs/src/content/docs/development/` contains only this one file, so there's no second page carrying the missing steps.

**Proposal**: Change the requirement line to "Xcode 27 or newer (Swift 6.4)." Insert `make install-tools` between clone and build, and add `make check` alongside `make test` in step 2 with one line naming what it runs (per `README.md:72-84`). Add a cheap drift guard: a grep asserting the substring "6.4" appears in both `README.md` and `building.mdx` (not an exact `swift-tools-version` token match, since the phrasing differs), wired into `make check`.

**Expected impact**: Removes the most likely first-five-minutes failure for a new contributor.

**Effort/Risk**: S / low.

**How to verify on Mac**: `head -1 Package.swift` and `rg -n '6\.4' README.md docs/src/content/docs/development/building.mdx` should agree. Temporarily bump the tools version and confirm the new guard goes red.

**Caveats from review**: Both skeptics confirmed every fact; one softened impact to low ("docs-only, one confusing manifest-parse error, nothing more"), the other to medium (contributor-facing gate). Reported here as low given it's purely a first-run friction cost with no runtime effect.

---

### F145 — CI never runs `make bundle`; packaging is first exercised by a release tag

**Where**: `.github/workflows/ci.yml:25,68,104` (three jobs, none packages)

**Evidence**:
```yaml
  test:
    name: Tests
    runs-on: xcode-27
      - name: Run tests
        run: make test
      - name: Run performance budgets
        run: make test-performance
```

**Why it costs / what is missing**: `ci.yml` has exactly `check`, `test`, `sanitizers` — none invokes `make bundle`/`icons`/`dmg`. The first CI execution of `scripts/bundle.sh`, `scripts/build-app-icon.sh`, `scripts/create-dmg.sh` is `release.yml:68`, inside the tag-triggered, certificate-importing, notarizing job. A break in any of the three — a `strip` flag change, a missing resource, an `sips`/`iconutil` behavior change on a new Xcode image — surfaces as a failed release after the tag is public. Note `make test-performance` already runs `swift test -c release`, so a release-config *compile* break is already caught on PR; only the packaging layer (strip, resource copy, icon generation, codesign, hdiutil) is uncovered. One concrete latent bug this exposed: `scripts/build-app-icon.sh:149` references an unbound variable `b` in its hand-rolled Paeth-filter PNG encoder (the encode half at `:178-180` uses `b_val`) — a `NameError` under `set -eu` for certain source pixel rows, currently untested anywhere in CI.

**Proposal**: Add a `package` job to `ci.yml` running `make dmg` (which depends on `bundle`, so `make icons` separately is redundant) — ad-hoc signing needs no secrets (`bundle.sh:9,35-41` falls back to `--sign -`). `bundle.sh:52` already runs `codesign --verify --deep --strict` under `set -e`, so no extra verify step is needed; add `hdiutil verify .build/Floodlight.dmg`. Append both `binary_size_bytes` and `dmg_size_bytes` FLOODLIGHT_BENCH lines (`bundle.sh:27`, `create-dmg.sh:46`) to `$GITHUB_STEP_SUMMARY`. Add a size ratchet comparing the parsed `binary_size_bytes` against a committed ceiling — start generous or summary-only, since size moves with toolchain/SDK updates on `xcode-27`, not just the diff. Do not run `make install-tools` in this job — `release.yml` never does either, so matching that means taking the pure-Python icon-encoder branch, which is exactly where the `b`/`b_val` bug lives.

**Expected impact**: Moves packaging failures from "discovered at release" to "discovered on the PR."

**Effort/Risk**: S (package job) / low — but note it adds a full cold `-Osize` release build to every PR unless it reuses/scopes the existing cache key (`ci.yml:80`).

**How to verify on Mac**: `make bundle dmg && codesign --verify --deep --strict .build/Floodlight.app && hdiutil verify .build/Floodlight.dmg`; `hyperfine --runs 3 'make bundle'` to size the new job's cost; record the current `stat -f%z .build/Floodlight.app/Contents/MacOS/Floodlight` as the ceiling seed.

**Caveats from review**: Both skeptics confirmed the gap and found the same corroborating bug independently (`build-app-icon.sh:149`, undefined `b`). Both flagged `make icons` and a redundant `codesign --verify` step as unnecessary since `make dmg`/`bundle.sh:52` already cover them. Both cautioned the size ratchet will be noisy on a shared/toolchain-updated runner — start advisory. Impact downgraded from the original to medium (build hygiene, not runtime).

---

### F153 — SwiftLint complexity ratchet has drifted: named offenders no longer exist or no longer sit at threshold

**Where**: `.swiftlint.yml:75-88` (invariant statement + offender table)

**Evidence**:
```
# Each number is set at *exactly* the tree's current worst offender... These
# only ever move down... Today's offenders, all of which want splitting:
#   file_length           665  Sources/Floodlight/Search/SearchCoordinator.swift
#   function_body_length  119  SearchCoordinator.applyResults
#   cyclomatic_complexity  13  SearchCoordinator.applyResults
```

**Why it costs / what is missing**: Confirmed directly in this pass: `rg -n "applyResults" Sources Tests` returns **zero hits** — the function two of the four thresholds are attributed to no longer exists anywhere in the tree. `SearchCoordinator.swift` is now under 665 lines on every counting convention (raw/excl-comments/excl-comments-and-blanks), so it no longer sits at its own named threshold. `Sources/FloodlightEngine/Search/FFFIndex.swift` is now the largest file in the tree (714 raw) and is unmentioned. Since the ratchet's enforcement is entirely social — a reviewer reading this comment and lowering the number — a stale block silently disables it while still looking like a live gate.

**Proposal**: Re-measure and re-set in one commit using SwiftLint's own numbers, not hand counts (the `ignore_comment_only_lines` behavior around blank lines is ambiguous from reading the YAML alone):
```bash
.tools/bin/swiftlint lint --reporter json \
  --config <(sed 's/warning: 665/warning: 1/' .swiftlint.yml) Sources \
  | jq -r 'map(select(.rule_id=="file_length")) | .[] | "\(.file) \(.reason)"'
```
Repeat for the other three rules. Set each threshold to the observed maximum, name the real offenders (start with `FFFIndex.swift`, since `SearchCoordinator.applyResults` is dead). Longer term, add `scripts/check-ratchet.sh`: run the shadow config (duplicating `.swiftlint.yml`'s `excluded:` list so it doesn't lint `.build`/`.tools`, and without `--strict` since a threshold-1 config always exits non-zero), extract the JSON reporter's "currently contains N" values, and fail when any configured threshold exceeds the observed maximum.

**Expected impact**: Restores the only mechanism preventing complexity drift; converts "a reviewer remembers to lower it" into a gate.

**Effort/Risk**: S for the re-measure-and-rename commit (both skeptics downgraded from the original M once they confirmed `applyResults` is simply gone); M if the automated `check-ratchet.sh` script is also built / low.

**How to verify on Mac**: Run the SwiftLint JSON-reporter command above for all four rules on the actual Mac toolchain (this cannot be resolved by reading code alone — it requires the pinned `swiftlint` binary). Set each threshold to the maximum reported and confirm `make check-lint` is green with zero slack.

**Caveats from review**: I independently re-verified `applyResults` is dead (0 hits) in this pass, confirming both skeptics' strongest correction. Both skeptics agreed the file_length slack could not be resolved by hand-counting because `ignore_comment_only_lines`'s treatment of blank lines is ambiguous without running SwiftLint itself — this is now the primary open question, listed in the Mac todo. Impact downgraded to low: it's a lint-gate correctness issue with a working (if loosened) numeric ceiling still in place, not a broken gate.

---

### F152 — Shipped clipboard controls are undocumented: pin, delete, retention, exclusions, clear, enable toggle

**Where**: `docs/src/content/docs/guides/keyboard-shortcuts.mdx:30` (missing Clipboard-mode block); `Sources/Floodlight/UI/OnboardingView.swift:280-400` (undocumented Settings section)

**Evidence**:
```swift
// FloodlightPanel.swift:376-381
case ".": .togglePin
case "d": .deleteSelection   // both gated on model.isClipboardMode
```

**Why it costs / what is missing**: Neither shortcut appears anywhere in the docs — `keyboard-shortcuts.mdx`, `filters.mdx`, or the Clipboard-history section of `search.mdx:51-71` (seven bullets, no pin/delete). `OnboardingView.swift:280-400` renders a full "Clipboard History" settings section — record on/off toggle, retention-days control (7/30/90/Forever), a bundle-ID exclusion list with placeholder `com.1password.1password`, and a Clear-history button — documented nowhere. Pin is load-bearing: `WHERE pinned_at IS NULL AND created_at < ?` (`ClipboardHistoryStore.swift:516`) means pinning is the only way an entry survives retention pruning. A latent bug both skeptics found matters here: the "Forever" retention option is **not honored by the pruner** — `ClipboardCaptureService.swift:154-161` does `if days > 0 { return .days(days) }; return .days(30)`, so the `-1` sentinel Forever writes falls through to a silent 30-day default. Documenting Forever as working would ship a false privacy guarantee; document only what the pruner actually does, or fix the getter first.

**Proposal**: Add a Clipboard-mode block to `keyboard-shortcuts.mdx` (⌘. pin/unpin, ⌘D delete). Add a "Clipboard settings" section covering: the record toggle, retention days (7/30/90, and Forever only once/if the pruner bug above is fixed), per-app exclusion with a worked bundle-ID example, Clear history, the automatic skip rules (concealed/transient/`is-sensitive` marker types, 32,000-byte text cap, 15 MiB image cap, Floodlight's own writes — `ClipboardHistoryStore.swift:8-9`, `ClipboardCaptureService.swift:244-283`), and where the database lives. State explicitly that pinned entries are exempt from retention pruning.

**Expected impact**: Makes two shipped shortcuts and an entire settings pane discoverable; turns privacy filtering from an invisible implementation detail into a documented guarantee.

**Effort/Risk**: S / low.

**How to verify on Mac**: `rg -n 'case "' Sources/Floodlight/App/FloodlightPanel.swift` lists every command shortcut — cross-check each against `keyboard-shortcuts.mdx`. Run `make bundle && open .build/Floodlight.app`, enter Clipboard mode, confirm ⌘. and ⌘D. Separately confirm the Forever-retention bug: set retention to Forever, check that pruning still runs at 30 days.

**Caveats from review**: Both skeptics independently found the same latent defect — Forever retention doesn't work as the UI implies — and flagged it as the one correction that changes what should actually be documented. One skeptic corrected the text cap to 32,000 bytes (not "32 KB") and noted the shortcuts are unambiguously scoped to Clipboard mode with no conflict risk against AppKit's default ⌘. cancel binding.

---

### F149 — README's Features list and architecture diagram omit clipboard history, keyword engines, and the assistant CLI

**Where**: `README.md:13` (Features), `:166` (architecture block), `:201` (privacy section)

**Evidence**:
```
## Features
- Global ⌘Space invocation...
- FFF fuzzy search across files and folders
... (16 bullets, zero mentions of clipboard/assistant/keyword)
```

**Why it costs / what is missing**: `rg -in "clipboard|assistant|keyword|codex|claude" README.md` returns nothing across the entire file. The architecture block (`:166-178`) draws `FloodlightPanelController → SearchCoordinator → SourceSearchEngine/Calculator/SelectedResultActionPerformer` with no `ClipboardCaptureService`, `ClipboardHistoryStore`, or `AssistantRunSession` node. The privacy section (`:201`) names "Persistent FFF history, frecency data, and private app markers" and omits the clipboard database — the most sensitive thing the app writes: it's on by default, defaults to 30-day retention, lives unencrypted at `~/Library/Application Support/Floodlight/clipboard.sqlite3`, and has skip rules for password-manager/concealed content that are a selling point currently invisible.

**Proposal**: Add three Features bullets (clipboard history with filters/inspector/pin/delete/retention; keyword-addressed search engines with correct ADR citation — `docs/adr/0006-keyword-engine-registry.md` for keywords, `docs/adr/0003-assistant-run-session.md` for the assistant, not both under "0006" as first drafted; local assistant CLI asks — note this row only appears when the CLI is installed, per `KeywordEngine.swift:427,436` shelling out to `codex exec`/`claude -p`). Extend the architecture block with `ClipboardCaptureService → ClipboardHistoryStore (SQLite + FTS5)` and `AssistantRunSession`. Extend the privacy section with the DB path, default retention, unencrypted-at-rest status, and the skip rules — framed as a feature, not a caveat.

**Expected impact**: Closes the gap between what ships and what the front page claims; makes the clipboard privacy story legible before a user enables it.

**Effort/Risk**: S / low.

**How to verify on Mac**: `rg -o '^## ' docs/src/content/docs/guides/search.mdx` — every searchable family listed there should have a README bullet.

**Caveats from review**: Both skeptics corrected the ADR attribution (0006 is keyword engines only; 0003 is the assistant). Both noted neither feature has its own dedicated docs page — they're sections inside `search.mdx` — so the README gap is the primary disclosure surface, strengthening rather than weakening the finding. One skeptic added the CLI-availability caveat for the assistant bullet.

---

### F148 — No ADR for Clipboard History despite four CONTEXT.md terms and an eight-file footprint

**Where**: `CONTEXT.md:70,74,78,82`

**Evidence**:
```
**Clipboard History**: The local, privacy-filtered record of text, files,
folders, and images copied across macOS...
```

**Why it costs / what is missing**: `docs/adr/` has exactly 0001–0007; none is about clipboard. The feature spans 8 files (`ClipboardEntry`, `ClipboardHistoryStore`, `ClipboardHistorySQLite` in the engine; `ClipboardCaptureService`, `ClipboardExclusionStore`, `ClipboardImageCapture`, `ClipboardInspector` in the shell; `ClipboardInspectorPane` in the UI) and defines four CONTEXT.md terms. Both skeptics corrected the original framing: "every other module seam got an ADR before shipping" is false — all seven existing ADRs came from three refactor commits documenting deep-module extractions, not feature launches, and other CONTEXT.md terms (Global Hot-Key Registration, Degraded Search) have no ADR either. The gap is real regardless; it's just not a violated norm. What's genuinely unrecoverable from code: why 0.5s `Timer` polling rather than an `NSPasteboard` observer; why SQLite+FTS5 trigram rather than the in-memory approach every other source uses; why the store lives in the engine while capture lives in the shell; that the DB is unencrypted at rest; that retention is time-only (`ClipboardHistoryStore.swift:529`) with no row-count bound. The seven numbered skip-rule comments in `ClipboardCaptureService.swift:234-283` are already legible in code, so "the feature's whole justification" oversells that part.

**Proposal**: Write `docs/adr/0008-clipboard-history.md` matching the house format actually used (YAML frontmatter `status`/`date`, then an imperative title, prose, `## Considered options`, `## Consequences` — not an invented Status/Context/Decision template). Cover the module boundary, storage decision and consequences, the privacy contract, and the retention gap. Add `docs/adr/README.md` as an index — ADRs live outside the Starlight content root (`docs/src/content/docs`) with no `title` frontmatter, so they were never site pages; a plain index is the achievable win, not a sidebar entry.

**Expected impact**: Fills the largest documentation gap tied to the newest feature; makes the privacy rules reviewable as a decision.

**Effort/Risk**: S / low.

**How to verify on Mac**: `ls docs/adr/` shows 0008; `rg -c 'ConcealedType|is-sensitive' docs/adr/0008-clipboard-history.md` is non-zero.

**Caveats from review**: Both skeptics refuted "every other module seam got an ADR" as an overstated premise — the ADRs record refactor extractions, not feature launches — while agreeing the gap itself is real. Both corrected the house-format description and the poll()-line-range/rule-count details. Impact downgraded to medium (docs-only, no runtime effect).

---

### F154 — pages.yml uses floating action tags with `pages:write`/`id-token:write`, while ci.yml/release.yml pin by SHA

**Where**: `.github/workflows/pages.yml:11-14,25,28,46`

**Evidence**:
```yaml
permissions:
  contents: read
  pages: write
  id-token: write
      - uses: actions/checkout@v6
      - uses: withastro/action@v6
      - uses: actions/deploy-pages@v5
```

**Why it costs | mechanism**: `ci.yml` and `release.yml` pin every action to a full SHA with a `# vN` comment; `pages.yml` pins nothing, including a third-party action. `pages.yml` is also the highest-privilege workflow of the three — the only one holding `pages: write` and `id-token: write` (an OIDC token identifying the repo). No `.github/dependabot.yml` exists anywhere in the repo.

**Proposal**: Pin all three actions to SHAs with `# vN` comments, matching the existing convention. For the third-party `withastro/action`, add a comment recording who reviewed the pin and when. Drop the "add a paths filter" idea from the original proposal — `pages.yml:6-8` already has one (`docs/**`, `.github/workflows/pages.yml`). Add `.github/dependabot.yml` with `package-ecosystem: github-actions` as a net-new file (none exists today) so future pins get bumped deliberately.

**Expected impact**: Closes the one unpinned execution path in the repo, and the one with the most privilege.

**Effort/Risk**: S / low.

**How to verify on Mac**:
```bash
gh api repos/actions/checkout/git/ref/tags/v6 --jq .object.sha
rg -n 'uses:' .github/workflows/   # every line should carry a 40-hex SHA
```

**Caveats from review**: Both skeptics confirmed the asymmetry and privilege claim exactly. Both corrected the proposal: the paths filter already exists (drop that suggestion); a link-check-style CI gate for this belongs in `ci.yml`, not `pages.yml`, since the latter only triggers on `docs/**` changes. Impact downgraded to medium since the deploy job sits behind a `github-pages` environment.

---

### F151 — README links to a docs anchor that does not exist

**Where**: `README.md:211`

**Evidence**:
```
See [sources not yet
integrated](docs/src/content/docs/guides/search.mdx#sources-not-yet-integrated)
```

**Why it costs / what is missing**: The target heading is `## Not currently searchable` at `docs/src/content/docs/guides/search.mdx:116`, slug `#not-currently-searchable`. `#sources-not-yet-integrated` matches nothing. Both skeptics corrected the original's "systemic" framing: repo-relative `.mdx` links elsewhere in the README (`:156`, `:162`) resolve fine on GitHub — only the fragment is dead. Switching all links to the published `floodlight.vmg.dev` site is a style preference, not a fix, and no other file in the repo references that domain except `SITE_URL` in `pages.yml:33`.

**Proposal**: Fix the anchor to `#not-currently-searchable`. Skip the site-URL conversion. If a link checker is added, it must live in `ci.yml` (which has no docs gate today), not `pages.yml` — the latter's `paths:` filter would skip a README-only change entirely. A grep-and-slugify script is more reliable than `lychee` here, since `lychee` needs `--include-fragments` and has uncertain `.mdx` heading support.

**Expected impact**: Fixes one broken link; a link checker over ~10 mdx pages runs in seconds.

**Effort/Risk**: S / low.

**How to verify on Mac**: `rg -n '^## ' docs/src/content/docs/guides/search.mdx | rg -i 'not currently'`.

**Caveats from review**: Both skeptics agreed on the exact fix and both corrected the "systemic" claim and the CI-placement detail above. Anchor line corrected to 211 (not 210, which is just where the sentence starts). Impact downgraded to low — cosmetic, no build/runtime effect.

---

### F157 — No CI job has `timeout-minutes`; notarytool wait is unbounded

**Where**: `.github/workflows/ci.yml:25,68,104` plus `pages.yml:21,37` and `release.yml:16` — seven jobs total, not the three or four originally counted

**Evidence**:
```yaml
jobs:
  check:
    runs-on: xcode-27
  test:
    runs-on: xcode-27
  sanitizers:
    runs-on: xcode-27
```

**Why it costs / what is missing**: No workflow sets `timeout-minutes` anywhere, so every job inherits GitHub's 360-minute default. The concrete unbounded risk is `xcrun notarytool submit --wait` (`release.yml:167-171`) against an Apple service with no client-side deadline — an outage pins a runner (and an unlocked signing keychain, `security set-keychain-settings -lut 21600`, `release.yml:106`) for six hours. Both skeptics independently found the original's third proposal item — "give polling helpers a hard deadline" — is already done: `Tests/FloodlightTests/EndToEndSearchTests.swift:70-83`'s `waitUntil` already computes a wall-clock deadline and calls `Issue.record(...)` on timeout. The genuine test-side gap is different: no test anywhere carries a Swift Testing `.timeLimit` trait, so a test that deadlocks *inside* its condition closure (rather than merely polling slowly) never reaches that deadline check. Also, `runs-on: xcode-27` is a custom/self-hosted label, not a GitHub-hosted `macos-*` runner, so the "most expensive class, billed per minute" framing is unsupported — the real cost is starving a small custom runner pool, not billing.

**Proposal**: Add `timeout-minutes` to all seven jobs, sized from observed durations plus headroom. Add `--timeout 1800` to the `notarytool submit` call so a release fails with a clear message instead of hanging. Drop the redundant polling-helper-deadline proposal; optionally add a `.timeLimit` trait to catch genuine deadlocks instead.

**Expected impact**: Bounds worst case from 6 hours per wedged job to the configured ceiling.

**Effort/Risk**: XS–S / low.

**How to verify on Mac**: `gh run list --workflow CI --limit 10 --json databaseId`, then `gh run view <id> --json jobs --jq '.jobs[] | {name, startedAt, completedAt}'` to size real timeouts.

**Caveats from review**: Both skeptics found the polling-deadline proposal was already implemented and corrected the file's location (`Tests/FloodlightTests/`, not `FloodlightEngineTests/`). Both rejected the "most expensive runner class"/billing framing since `xcode-27` isn't a GitHub-hosted label. Both expanded the job count from 3–4 to 7. Impact downgraded to low.

---

### F142 — 48 tracked LLVM bitcode files (8.5 MiB) plus a 3.0 MB DMG sit in repo root, ungitignored

**Where**: `.gitignore:15` (last line, `*.xcuserstate`)

**Evidence**: confirmed directly this pass — `git ls-files "*.bc" | wc -l` → 48, `.gitignore` tail ends at `*.xcuserstate` with no `*.bc`/`*.dmg` entry.

**Why it costs / what is missing**: `git check-ignore -v` exits 1 for both artifact classes — neither is ignored, so a re-add is unguarded. Names map 1:1 onto real Swift sources (`SearchCoordinator.bc`, `FuzzyMatcher.bc`, `TestDoubles.bc`), confirming accidental compiler output, attributed by `git log --diff-filter=A` to a single path-navigation feature commit (3f568c7) alongside `design/Floodlight.dmg`. Nothing references either — `rg '\.bc\b' Makefile scripts .github Package.swift` is empty, and the real DMG build path (`scripts/create-dmg.sh:7`) writes to the already-ignored `.build/Floodlight.dmg`. Corrected sizes: 8,885,328 bytes (8.5 MiB) of `.bc` + 3,040,244 bytes (2.9 MiB) DMG = 11.36 MiB combined, matching the original "~11.6 MB" within rounding.

**Proposal**: Add `*.bc` and `*.dmg` to `.gitignore`, then `git rm --cached` both in one commit. `git rm --cached` does not shrink the pack — only `git filter-repo` would, and that's a separate, disruptive decision — so frame this as a working-tree win, not a clone-bandwidth win, unless filter-repo is pursued too.

**Expected impact**: Removes 11.4 MB from every checkout and worktree going forward.

**Effort/Risk**: S / low.

**How to verify on Mac**: `git count-objects -vH | grep size-pack` before/after; `git ls-files "*.bc" | wc -l` should read 0 after; `du -sh .` should drop ~11.4 MB; `make check && make test` should stay green.

**Caveats from review**: Both skeptics confirmed every fact and corrected the byte counts to the precise figures above (cosmetically different from the original "~11.6 MB"/"8.6 MB"). Both downgraded impact from the original framing to medium/low — this is pure hygiene with zero runtime effect, and the CI wire-savings claim is weaker than stated since checkout transfers a compressed pack (bitcode compresses well) and `git rm --cached` alone doesn't shrink history.

---

### F158 — Periphery excludes all of Tests/ (20.6k lines, 62% of the Swift tree) from the dead-code gate

**Where**: `.periphery.yml:18` (`exclude_tests: true`), `:28-34` (FloodlightTestSupport exclusion)

**Evidence**:
```yaml
index_exclude:
  - "**/Tests/FloodlightTestSupport/**"
  # A regular SwiftPM target shared only by the two excluded test targets.
strict: true
```

**Why it costs / what is missing**: `exclude_tests: true` plus the `FloodlightTestSupport` exclusion together mean nothing under `Tests/` is ever scanned — not just the 1,456-line `FloodlightTestSupport` target (both skeptics corrected the original's "~1,900 lines" estimate down to this figure: `AdversarialCorpus.swift` 210 + `ClipboardImageTestData.swift` 14 + `PropertyTesting.swift` 502 + `SearchFixtures.swift` 282 + `TestDoubles.swift` 448), but the entire `Tests/` tree — 20,621 lines, 62% of the repo's 33,442 Swift lines. `FloodlightTestSupport` is a plain `.target` (not `.testTarget`, `Package.swift:62-67`), so `exclude_tests` alone doesn't cover it; the explicit `index_exclude` entry is what does. One concrete instance found by a skeptic: `Tests/FloodlightTestSupport/PropertyTesting.swift:62` declares `package func mapShrinking<Mapped>(...)` with zero call sites anywhere — a dead generator combinator the compiler can't flag (it's `package`-visible across a module boundary) and Periphery is told to skip.

**Proposal**: Add a second Periphery invocation, not a change to the first. Keep `.periphery.yml` as-is for production. Add `.periphery-tests.yml` with `exclude_tests: false`, no `FloodlightTestSupport` exclusion, and `index_exclude: ["**/Sources/**"]` so its findings are disjoint from the production scan (both skeptics flagged that without this, scan 2 just re-reports scan 1's findings). Set `skip_build: true` — the debug index store Periphery already builds for scan 1 (`swift build --build-tests`) already contains the test-target units, so scan 2 adds analysis time only, not a second build; this drops effort from the original M estimate to S. Report the two scans under separate headings since they answer different questions (dead production code vs. unused test scaffolding). Start it gating from the start, not advisory — Periphery 3.8.0 (pinned, `scripts/tool-versions.env:15`) understands both XCTest and swift-testing `@Test` roots, so the "may need to be advisory first" hedge from the original isn't warranted.

**Expected impact**: Extends the no-baseline dead-code discipline to the majority of the Swift tree it currently exempts; prevents unused test doubles from reading as coverage.

**Effort/Risk**: S / low.

**How to verify on Mac**:
```bash
.tools/bin/periphery scan --project-root . --config .periphery-tests.yml --quiet | wc -l
rg -n '<DeclName>' Tests/   # cross-check a sample: zero non-definition hits = real dead code
```

**Caveats from review**: Both skeptics corrected the line count (1,456, not ~1,900) and the "a fifth of the codebase" framing (TestSupport alone is 4.4%; the real blind spot, all of `Tests/`, is 62% — understated, not overstated, once corrected). One skeptic found the concrete dead-declaration example above and flagged that `retain_public: false` in the proposed second config is a no-op (nothing under `Tests/` is `public`; the architecture gate already forbids that under `Sources/`). Both agreed effort drops from M to S once `skip_build: true` and the `index_exclude` scoping are added.

---

### F160 — Every non-release build reports version 0.1.0 build 1

**Where**: `Sources/Floodlight/Resources/Info.plist:19-22`

**Evidence**:
```xml
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
```

**Why it costs / what is missing**: `release.yml:58-65` stamps this plist in place with PlistBuddy from the tag and run number but never commits the result, so the tracked file stays at 0.1.0/1 forever — confirmed by `git tag` listing v0.1.0 through v0.1.4 while the plist never moved. `scripts/bundle.sh:29` copies it verbatim into every dev build, so `make bundle`, `make install`, and everything `autoresearch.sh` measures self-identifies as 0.1.0 build 1. Both skeptics corrected a factual overreach in the original: Floodlight has **no About panel** — it's `LSUIElement` (`Info.plist:25-26`) with no `orderFrontStandardAboutPanel` call anywhere in `AppDelegate.swift` — so the version is only observable via Finder Get Info, `mdls`, `defaults read`, or a crash report, not an About box.

**Proposal**: Stamp the *copy* in `scripts/bundle.sh` after the `cp` (never the tracked source), between the copy and the `codesign` call. Use a numeric `git describe`-derived or commit-count value for `CFBundleVersion`; do **not** put a raw `git describe --tags --always --dirty` string (e.g. `v0.1.1-89-g936926b`, confirmed by running it in this worktree) into `CFBundleShortVersionString` — it's not a valid three-integer version and can fail notarization/validation. Keep the numeric field numeric; put the descriptive git string in `CFBundleVersion` or a custom key instead.

**Expected impact**: Makes every build self-identifying at zero runtime cost.

**Effort/Risk**: S / low.

**How to verify on Mac**:
```bash
make bundle && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/Floodlight.app/Contents/Info.plist
git diff --exit-code Sources/Floodlight/Resources/Info.plist   # tracked file untouched
codesign --verify --deep --strict .build/Floodlight.app
```

**Caveats from review**: Both skeptics independently ran `git describe` and got a non-numeric string, correcting the original proposal's exact recipe. Both flagged the About-panel claim as false. Impact downgraded to low — maintainer/dev-workflow convenience only, no user-facing effect since there's no updater or crash-reporting SDK in the app.

---

### F155 — Periphery's index-store path is hardcoded to arm64

**Where**: `.periphery.yml:13`

**Evidence**:
```yaml
index_store_path: ".build/arm64-apple-macosx/debug/index/store"
```

**Why it costs / what is missing**: `swift build` writes its index store under a triple-specific path; on Intel the real path is `.build/x86_64-apple-macosx/debug/index/store`, which the config doesn't name. `scripts/install-tools.sh:23-36` and `scripts/tool-versions.env` do carry x86_64 digests, though via a `*)` catch-all rather than an explicit arm — so "the project explicitly supports x86_64 everywhere except here" overstates the existing policy. All three CI jobs run on `xcode-27` (arm64), so this never bites in the merge path; it's latent for a local Intel contributor. Both skeptics rejected the dramatic "gate passes by scanning nothing" framing as unevidenced speculation — Periphery validates the store it's pointed at and the `check-dead-code.sh` wrapper propagates any non-zero exit, so the realistic failure is a confusing hard error, not a silent pass.

**Proposal**: Delete the hardcoded key; derive the path in `scripts/check-dead-code.sh` instead: `index_store="$(cd "$PROJECT_DIR" && swift build --show-bin-path)/index/store"` (matching the pattern already used in `bundle.sh:6`/`run.sh:6`), pass it as `--index-store-path` on the command line. Do not add an unconditional pre-flight existence assertion — `make check-dead-code` run standalone has no populated `.build` yet on a clean checkout (Periphery builds it itself), so the assertion would fail before the scan runs; only assert after, if at all.

**Expected impact**: Makes the dead-code gate work on Intel Macs.

**Effort/Risk**: S / low.

**How to verify on Mac**: On Apple silicon, `ls -d .build/*/debug/index/store` confirms the derived path matches. On Intel (if available), confirm the literal path doesn't exist and observe whether Periphery errors or reports zero findings — resolves the open question directly rather than by research.

**Caveats from review**: Both skeptics rejected the "silent vacuous pass" framing as unevidenced and corrected the proposed derivation command (the original's `sed` extraction dropped the `debug` path component and would break on arm64 too). Both downgraded impact to low.

---

### F159 — The engine gets no optimization settings of its own; the size/speed split has never been measured (plausible — split verdict)

**Where**: `Package.swift:13-15` (shell gets `-Osize`), `:39` (engine gets bare `upcoming`)

**Evidence**:
```swift
let shellSettings: [SwiftSetting] = upcoming + [.unsafeFlags(["-Osize"])]
...
.target(name: "FloodlightEngine", ..., swiftSettings: upcoming)
```

**Why it costs / what is missing — and why this is plausible, not confirmed**: The asymmetry is real and unmeasured at the per-target level — no per-target size attribution exists anywhere in `scripts/bundle.sh` or `autoresearch.sh`. But the two skeptics split on whether cross-module optimization is a live lever here. One skeptic accepted the framing as reasonable to investigate. The other traced every shell→engine call site and found the "opaque calls, can't inline" claim doesn't hold up: `rg "FuzzyMatcher\." Sources/` returns zero hits inside `Sources/Floodlight` — every call to `FuzzyMatcher`/`scoreASCII` is *internal to the engine*, where whole-module optimization already inlines. The only shell→engine ranking call is a single `SearchItemRanking.topRankedInPlace(&output, limit:)` per keystroke (`SearchResultProjection.swift:466`), wrapping an O(n) loop that lives entirely inside the engine — inlining one outer frame per keystroke is noise, not a hot path. So the CMO half of the proposal has no identified target; the size-attribution half stands on its own as a smaller, well-scoped ask.

**Proposal**: Do not build the three-way build matrix (baseline / engine `-Osize` / engine `-cross-module-optimization`) as originally proposed — the CMO arm has no evidence behind it. Instead, add only a per-target size breakdown to `scripts/bundle.sh`, using `nm` on the unstripped binary (Swift symbol mangling already carries the module name, e.g. `$s16FloodlightEngine…` vs `$s10Floodlight…`), emitting `engine_text_bytes=`/`shell_text_bytes=` as diagnostic secondary metrics alongside the existing `binary_size_bytes` line. If that reveals the engine is a disproportionate share of the binary, revisit `-Osize` on the engine specifically — measured, not sketched.

**Expected impact**: Turns an unexamined build-flag asymmetry into a measured one, without the untargeted CMO speculation. Low — diagnostic only, unlikely to change a build-flag decision on its own.

**Effort/Risk**: S (size breakdown only) / low — down from the original M/medium once the CMO matrix is dropped.

**How to verify on Mac**:
```bash
nm -n .build/release/Floodlight | awk '{print $3}' | grep -c '16FloodlightEngine'
# run on the unstripped binary before scripts/bundle.sh's strip -u -r
```

**Caveats from review**: One skeptic accepted the finding with corrections (medium/low impact, S effort, note `deliverable_size_bytes` not `binary_size_bytes` is the actual primary metric). The other refuted the CMO half specifically, tracing every cross-module call site and finding no hot path it would help — this is the disagreement behind the "plausible" status. Both agreed the plain per-target size breakdown is worth doing regardless of the CMO question; that's what's carried into the proposal above.

### Rejected ideas

None — no findings in this section's input were dropped as refuted by both skeptics.

## Beyond the five: memory, energy, indexing

All twelve items below live in the Clipboard History feature (last ~8 commits) except F171, which is on the shared FFF indexing layer. Nine are **confirmed** (both skeptics accepted the mechanism, with corrections). Three (F169, F170, F171) are **plausible** — split verdicts — and are ranked low with the disagreement explained inline; none were dropped outright by both skeptics, so there is no "both-refuted" rejection list this round.

| Rank | ID | Opportunity | Impact | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| 1 | F168 | Clipboard QuickLook previews leak to `$TMPDIR` forever; eager blob read gates every space keypress | Medium | S | Low | Confirmed |
| 2 | F167 | Space keypress unconditionally evaluates `previewableSelectionURL`, doing a sync SQLite blob read | Medium | S | Low | Confirmed |
| 3 | F161 | Clipboard projection builds all history rows + a sync `stat` per path row, on every keystroke | Medium | S–M | Low | Confirmed |
| 4 | F166 | Four parsers each re-trim clipboard text; JSON/URL/hex/code classification reruns every keystroke | Medium | S (interim) / M (full) | Low | Confirmed |
| 5 | F163 | Inspector re-reads full image blob from SQLite and decodes it on every body pass | Medium | S–M | Low | Confirmed |
| 6 | F162 | Screenshots stored twice (PNG + TIFF) with no size budget on the clipboard DB | Medium | S | Medium | Confirmed |
| 7 | F172 | No budgeted perf test covers clipboard image capture, projection, or inspector | Medium (enabling) | M | Low | Confirmed |
| 8 | F164 | Clipboard poller never pauses for screen lock (energy claims mostly refuted; privacy gap real) | Low–Medium | S | Low | Confirmed (narrowed) |
| 9 | F165 | Thumbnail/icon NSCaches have no byte budget (real risk is one uncapped fallback line, not the caches generally) | Low | S | Low | Confirmed (narrowed) |
| 10 | F169 | `SearchItem` equality/hashing walks embedded thumbnail `Data` | Low | M | Medium | Plausible (split) |
| 11 | F170 | Row date formatting rebuilds `Calendar`/`FormatStyle` per row per render | Low | S | Low | Plausible (mostly refuted) |
| 12 | F171 | Two FFF/LMDB instances run with zero-valued cache budgets, semantics unstated | Low | S (research first) | Low | Plausible (largely duplicate) |

---

### 1. F168 — Clipboard QuickLook previews leak to `$TMPDIR` forever

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:436` (`clipboardImagePreviewURL(for:)`), write at `:450-458`.

**Evidence**:
```swift
let ext = payload.png != nil ? "png" : "tiff"
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let fileURL = tempDir.appendingPathComponent("\(id).\(ext)")
if !FileManager.default.fileExists(atPath: fileURL.path) {
    try? data.write(to: fileURL)
}
```

**Why it costs / what is missing**: Every QuickLooked image writes up to a 15 MB copy of its payload into `$TMPDIR/FloodlightClipboardPreviews/<id>.<ext>` and nothing ever deletes it — a repo-wide search for `FloodlightClipboardPreviews` finds only this one site. macOS only sweeps per-user temp dirs after days of non-access. Worse: `deleteSelection()`/`clearHistory()` (`SearchCoordinator.swift:635-641`) only touch the SQLite store — the temp copy outlives an entry the user explicitly deleted, which is a privacy leak, not just disk growth.

**Proposal**: Track written URLs in a small set on the coordinator; delete the matching file inside `deleteSelection()`/`clearHistory()`. Bound session growth with one `try? FileManager.default.removeItem(at: tempDir)` at `start()` before the first `createDirectory` call — simpler than an hourly age-sweep. Pair with the F167 fix below: split `previewableSelectionURL` into a cheap predicate (no I/O, used by the key-event gate) and a materializer (does the SQLite read + write, called only from `togglePreview()`).

**Expected impact**: Bounds temp-disk growth to the current session; makes entry deletion actually delete the bytes (closes a real privacy gap).

**Effort/Risk**: S / Low.

**How to verify on Mac**:
```bash
du -sh "$TMPDIR/FloodlightClipboardPreviews"   # before/after previewing 20 screenshots + dismissing
```
Add `SearchCoordinatorClipboardModeTests.testPreviewFilesAreRemovedOnDelete` asserting the file for a deleted entry is gone; `swift test --filter SearchCoordinatorClipboardModeTests`.

**Caveats from review**: Recategorize from "memory" to temp-disk hygiene + privacy — this is not a resident-memory issue. Drop the "clear cache in `FloodlightPanelController.hide()`" idea from the original proposal: the panel hides on every dismissal, so this would force a filesystem+SQLite round trip on every re-selection, a net loss. Better anchor is the whole function at `SearchCoordinator.swift:436`, not just the write at `:450`.

---

### 2. F167 — Space keypress eagerly evaluates `previewableSelectionURL`

**Where**: `Sources/Floodlight/App/FloodlightPanel.swift:290-297` (gate), `SearchCoordinator.swift:435-459` (`clipboardImagePreviewURL`).

**Evidence**:
```swift
case 49:
    if Self.shouldHandleSpaceAsPreview(
        isClipboardMode: model.isClipboardMode,
        query: model.query,
        hasPreviewableSelection: model.previewableSelectionURL != nil
    ) {
```

**Why it costs / what is missing**: Swift evaluates all three arguments before the gate inside `shouldHandleSpaceAsPreview` runs, so `model.previewableSelectionURL` (line 294) executes on every space keypress in the panel regardless of mode or query. For a selected clipboard image it calls `clipboardStore.imageData(for:)` (`ClipboardHistoryStore.swift:263-277`) — an uncached, synchronous SQLite point query under a shared lock that materializes **both** `png_data` and `tiff_data` into `Data`, up to 15 MB each. For a selected text entry it runs `FileManager.default.fileExists` (line 428).

**Proposal**: Split the property. Add a cheap `hasPreviewableSelection: Bool` that checks only the selected item's action case (`.copyImage`/previewable file) with no I/O, used at the key-event gate. Keep `previewableSelectionURL`/`clipboardImagePreviewURL` as the materializer, called only from `togglePreview()`. If a minimal patch is preferred, change the parameter to `hasPreviewableSelection: @autoclosure () -> Bool` so `shouldHandleSpaceAsPreview`'s existing `&&` short-circuits — the four call sites in `FloodlightPanelTests.swift:39-57` keep compiling.

**Expected impact**: Removes an uncached multi-MB SQLite blob read from every space keypress in clipboard mode when a non-empty query should have blocked it.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Add `FloodlightPanelTests.testSpaceDoesNotEvaluatePreviewWhenQueryNonEmpty` with a counting autoclosure, assert it stays at 0 when `query` is non-empty. In-app: open clipboard mode, select an image row, type `a b c d`, confirm no SQLite/file activity via `xcrun xctrace record --template 'File Activity' --launch -- .build/release/Floodlight` until Space is pressed on an empty query.

**Caveats from review**: Drop the "multi-megabyte disk write per space" framing — `SearchCoordinator.swift:456` guards the write with `fileExists`, so it fires at most once per entry id, not per keystroke. The real per-keypress cost is the SQLite blob read. Also note `togglePreview()` re-evaluates `previewableSelectionURL` a **second** time on the accepted path (`FloodlightPanel.swift:232`), so a legitimate preview toggle pays the blob read twice — the `@autoclosure` patch alone doesn't fix that; the predicate/materializer split does.

---

### 3. F161 — Clipboard projection is uncapped, with a main-thread `stat` per path row

**Where**: `Sources/Floodlight/Search/SearchResultProjection.swift:196-212` (`projectClipboard`), `:299` (`fileExists`); `SearchCoordinator.swift:503-508, 657-671`.

**Evidence**:
```swift
private static func projectClipboard(_ context: ClipboardContext) -> SearchResultPublication {
    let rows = context.entries.enumerated().map { index, entry in
        buildClipboardRow(entry: entry, index: index, now: context.now)
    }
```
```swift
let exists = FileManager.default.fileExists(atPath: localURL.path)
```

**Why it costs / what is missing**: `publishClipboardModeResults()` runs on the main actor on every keystroke, undebounced. `projectClipboard` maps every returned entry into a `SearchItem` with no cap — unlike the local-search path's `maxResultsLimit = 80` (line 436) — then `rows.filter` builds a second array, and `clipboardFilterOptions(entries:)` walks the full entry list a third time. Each single-line, path-shaped text row (`ClipboardInspector.parseLocalPath`) also pays a blocking `fileExists` stat. The panel only ever shows 7 rows.

**Proposal**: Cap `rows` to a `maxClipboardRows` constant (200, matching the existing FTS `LIMIT`), but compute filter counts from the **full** `context.entries` first, then filter, then `prefix(maxClipboardRows)`, then build rows from that slice — order matters, or a filter chip's count can disagree with what it shows. Drop the `fileExists` call; always emit `fileURL: localURL` and let the row resolve existence asynchronously via `.task(id:)`, the same pattern `FileIconCache` already uses.

**Expected impact**: Bounds row construction to O(200) instead of O(history) on panel-open/short-prefix queries; removes blocking `stat` calls from the main thread (real cost on iCloud/network-mounted paths).

**Effort/Risk**: S (cap + reorder) plus a follow-on S for the async-exists change / Low.

**How to verify on Mac**: Add `Tests/FloodlightTests/ClipboardProjectionPerformanceTests.swift` — 1,000 synthetic entries, warm up, 11×50 samples via `getrusage`, print `FLOODLIGHT_BENCH clipboard_projection_us=`, assert median < 3,000µs and row count ≤ cap. `swift test -c release --filter ClipboardProjectionPerformanceTests`. For the stat specifically: history containing paths on a network/iCloud volume, `xcrun xctrace record --template 'File Activity' --launch -- .build/release/Floodlight`, confirm zero main-thread `stat` events while typing.

**Caveats from review**: The "uncapped 1,000-row" case is narrower than "every keystroke" — it hits an empty query or 1-2 character queries only; 3+ character queries already go through FTS with `LIMIT searchResultLimit = 200` (`ClipboardHistoryStore.swift:11, 373-377`). The `fileExists` cost is bounded to single-line text starting with `/`, `~/`, or `file://` — not every text row. Dropping the `exists` check changes visible behavior (stale paths now show "Show in Finder"/drag actions until async resolution catches up) — needs a test update in `SearchResultProjectionClipboardTests.swift`. Note `previewTitle(for:)` (line ~396) splits/joins the **full** entry text (up to 32 KB) per row unconditionally — likely a bigger per-row cost than the stat; bound its input with `text.prefix(200)` while making this change.

---

### 4. F166 — Four text parsers re-trim and rescan clipboard text every keystroke

**Where**: `Sources/Floodlight/Search/ClipboardInspector.swift:272` (`parseCodeHint`); call site `SearchResultProjection.swift:320-325`.

**Evidence**:
```swift
static func parseCodeHint(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
        (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    {
        if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
```

**Why it costs / what is missing**: `buildClipboardTextRow` calls `parseLocalPath`, `parseURL`, `parseHexColor`, and `parseCodeHint` purely to pick an icon, for every text row, on every keystroke, on the main actor. Each of the four independently calls `text.trimmingCharacters(in:)` — four full-string copies per row — and `parseCodeHint` runs roughly ten `contains(...)` substring scans over the whole (up to 32 KB) body before the JSON branch even applies. `JSONSerialization` itself only fires for text that both starts and ends with braces/brackets, so it is not the dominant cost the title implies — the repeated trimming and scanning is.

**Proposal**: Interim (S, shell-only): trim once in `buildClipboardTextRow`, pass the trimmed `Substring` into all four parsers, and give `parseCodeHint` a size cutoff (skip `JSONSerialization` above a few KB). Durable fix (M): classify once at capture time — add a `contentType`/`ClipboardTextShape` column computed in `ClipboardCaptureService.poll` before `store.record`, with a nullable migration and parse-on-the-fly fallback for pre-existing rows, then have projection and inspector read the stored value.

**Expected impact**: Removes O(history × text length) string copying/scanning from every keystroke in clipboard mode; the durable fix moves classification to once per copy.

**Effort/Risk**: S (interim) / M (durable) / Low.

**How to verify on Mac**: Extend the F161 projection benchmark with 100 entries holding a valid 30 KB JSON document each; compare `FLOODLIGHT_BENCH clipboard_projection_us=` before/after — expect an order of magnitude. Time Profiler on the release app while typing in clipboard mode: `JSONSerialization`/string-copy frames should shrink on the main thread.

**Caveats from review**: Retitle mentally from "JSON parsing" to "repeated trimming/scanning" — that's the real dominant cost. Row-count bound is worse than "a dozen": empty/1-2 character queries project up to `inMemoryRecentWindowLimit = 1,000` in-memory entries; only 3+-character FTS queries are capped at 200. This sits behind two larger main-actor costs on the same keystroke worth fixing together: the SQLite FTS query itself (`clipboardStore.search`, called from `SearchCoordinator.swift:666`) and the `fileExists` stat from F161 (`SearchResultProjection.swift:299`).

---

### 5. F163 — Inspector re-reads the full image blob and decodes it on every body pass

**Where**: `Sources/Floodlight/Search/SearchCoordinator.swift:653` (root cause) → `Sources/Floodlight/UI/ClipboardInspectorPane.swift:143-149` (symptom).

**Evidence**:
```swift
if let data = detail.previewPNG, let image = NSImage(data: data) {
    Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: 180)
```

**Why it costs / what is missing**: `model.clipboardInspector` is a **computed** property (`SearchCoordinator.swift:653`) that unconditionally fetches `clipboardStore.imageData(for:)?.png` for image entries — a synchronous SQLite `SELECT png_data, tiff_data` under a lock, materializing up to ~30 MB of `Data`. `SearchView.swift:220` reads this property from `body`, so it reruns on every keystroke and every arrow-key selection change while an image entry is selected. `ClipboardInspector` is `Equatable` and holds that `Data`, so SwiftUI's diff also does a memcmp of it. `NSImage(data:)` at line 145 then builds the representation, but the ~80 MB RGBA decode for a large screenshot happens lazily at draw time, not at that call — so the "20-100ms decode" is a worst-case-at-draw figure, not a guaranteed per-body cost.

**Proposal**: Keep only the entry id/hash in the `ImageDetail` snapshot — not the raw PNG. Resolve a cached, downsampled `NSImage` in a `.task(id: entryID)` via a new `ClipboardImagePreviewCache`, mirroring the existing pattern at `Sources/Floodlight/UI/FileThumbnailCache.swift:32-36` (`@concurrent nonisolated static func … async` + `NSCache` + `.task(id:)`). Use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize: 360 * scale` and `kCGImageSourceCreateThumbnailFromImageAlways`, off the main actor.

**Expected impact**: Removes the SQLite blob read + `Equatable` memcmp from every inspector body pass (guaranteed cost) and the large decode from the redraw path (worst-case cost).

**Effort/Risk**: S–M (template already exists in-repo) / Low.

**How to verify on Mac**: Copy a full-screen Retina screenshot, open clipboard mode, arrow through it repeatedly while running `xcrun xctrace record --template 'Allocations' --launch -- .build/release/Floodlight`; compare high-water mark before/after. `footprint -p $(pgrep -x Floodlight)` immediately after inspecting a 6K screenshot.

**Caveats from review**: Update `Tests/FloodlightTests/ClipboardInspectorTests.swift:72,82`, which asserts `detail.previewPNG == png`. Impact is confined to Clipboard mode with an image entry selected — real but not on the primary local-search hot path, hence Medium not High.

---

### 6. F162 — Screenshots stored twice (PNG + TIFF), no size budget on the DB

**Where**: `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:186-188, 246-248`.

**Evidence**:
```swift
let png = Self.cappedImageData(pngData)
let tiff = Self.cappedImageData(tiffData)
guard let primary = png ?? tiff else { return nil }
```

**Why it costs / what is missing**: When the pasteboard declares both `public.png` and `public.tiff` (common for screenshots/Preview/browser copies), the store persists both blobs independently capped at `maxImageByteCount = 15 MiB` each — up to 30 MB per entry, two encodings of identical pixels. The only size bound is time-based (`prune(retention:)`, default 30 days), fired once from `start()` — a long-running session never prunes again. Cost is disk/page-cache, not resident memory: `entryColumns` excludes the blob columns from the in-memory window; only `imageData(for:)` reads them on demand, and it reads both.

**Proposal**: One-line fix — drop TIFF when PNG is present: `let tiff = png == nil ? Self.cappedImageData(tiffData) : nil` at line 187. Every consumer already tolerates `tiff == nil` (`SelectedResultActionPerformer.swift:64-77`, `SearchCoordinator.swift:448-450`, `imageData(for:)` itself). Separately, add a size budget using the column already populated at capture time — `SUM(image_byte_count)` over non-null-payload rows, not a fresh `SUM(LENGTH(png_data))` scan — and delete whole rows past budget rather than nulling blobs in place (a payload-less row silently breaks paste and full-size preview).

**Expected impact**: Up to ~50% disk/page-cache reduction on entries where the source declared both representations. A retina screenshot's uncompressed TIFF often already exceeds the 15 MB cap and is dropped today, so the duplication mainly affects small/medium images, not the worst case cited.

**Effort/Risk**: S (one line + one test update) / Medium — `SelectedResultActionPerformer.writeImage` writes both types back to the pasteboard today, so dropping `tiff_data` changes what's offered to TIFF-only consumers; `ClipboardHistoryStoreTests.swift:603` and `ClipboardCaptureServiceTests.swift:355,389` need updating.

**How to verify on Mac**: Record 50 real screenshots, `ls -l "$HOME/Library/Application Support/Floodlight/FileIndex/clipboard.sqlite3"` and `sqlite3 clipboard.sqlite3 'SELECT SUM(LENGTH(png_data)), SUM(LENGTH(tiff_data)) FROM clipboard_entries;'` before/after.

**Caveats from review**: Reject the original proposal's "transcode TIFF-only entries to PNG" idea — it burns a full-size PNG encode on the `@MainActor` capture path to save nothing (TIFF-only rows already store exactly one blob). Reject "roughly halves" as a general claim — it's an upper bound reachable only for dual-representation entries under the size cap.

---

### 7. F172 — No budgeted test covers the clipboard image path, projection, or inspector

**Where**: `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:11-32`.

**Evidence**:
```swift
let sampleTexts = [
    "https://github.com/fpcMotif/floodlight/pull/42",
    "func performSearch(query: String) async throws -> [SearchItem]",
...
for index in 0..<1_000 {
    let base = sampleTexts[index % sampleTexts.count]
    let entry = try XCTUnwrap(store.record(
        text: "\(base) #\(index)",
```

**Why it costs / what is missing**: The one clipboard budget test seeds text-only entries — never `store.recordImage(...)`. It never exercises the thumbnail-blob read path (`ClipboardHistorySQLite.swift:154`), `projectClipboard`'s per-row work, or `clipboardInspector`. README's own rule — "a new hot path is not done until it has a budgeted test" — is unmet for the newest feature's three hottest paths, which is exactly why F161/F163/F166 could land unnoticed. Correctness tests exist (`SearchResultProjectionClipboardTests.swift`, `ClipboardInspectorTests.swift`) but use `#expect`, not timing.

**Proposal**: Three budgeted tests in the `SearchItemRankingPerformanceTests` idiom (warm-up, many samples, median, `FLOODLIGHT_BENCH` line, generous `XCTAssertLessThan`): `ClipboardHistoryPerformanceTests.testImageHistorySearchBudget` (1,000 entries, 300 with real thumbnails); `ClipboardProjectionPerformanceTests` over `SearchResultProjection.project(.clipboard(...))` with a mixed 1,000-entry corpus including a 30 KB JSON entry; `ClipboardInspectorPerformanceTests` over repeated `model.clipboardInspector` reads on an image selection.

**Expected impact**: Locks in every fix above; makes the next regression on the clipboard hot path fail in CI instead of on a user's Mac.

**Effort/Risk**: M / Low.

**How to verify on Mac**: `swift test -c release --filter Clipboard`, confirm three new `FLOODLIGHT_BENCH clipboard_*` lines; set `XCTAssertLessThan` bounds at ~5× the maintainer's observed median.

**Caveats from review**: None substantive — both skeptics confirmed the gap and the feasibility (all needed APIs are `package`-visible, no new production code required). Do this in tandem with F161/F163/F166 so the fixes land with the tests that prove them.

---

### 8. F164 — Clipboard poller never pauses for screen lock (narrowed from an energy claim to a privacy one)

**Where**: `Sources/Floodlight/Search/ClipboardCaptureService.swift:178-186` (timer), `:188-206` (observers).

**Evidence**:
```swift
let timer = Timer
    .scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
    }
timer.tolerance = 0.2
```

**Why it costs / what is missing**: The only pause condition registered is `NSWorkspace.sessionDidResignActiveNotification` — fast user switching, not screen lock or display sleep. `AppDelegate.swift:36` starts the timer at launch and only stops it at termination, so a 0.5 Hz poll runs for the whole session, including while the screen is locked.

**Proposal**: Add `DistributedNotificationCenter.default()` observers for `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked`, calling the existing `pause()`/`resume()`. That's the only piece of the original three-part proposal that survives review.

**Expected impact**: Stops clipboard capture while the screen is locked — a privacy-hygiene fix, not a measurable energy win.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `log stream --predicate 'process == "Floodlight"' --info` while locking the screen (⌃⌘Q), confirm polling stops. Add `ClipboardCaptureServiceTests.testPausesOnScreenLockNotification` using the existing `ScriptedPasteboardObserver` double.

**Caveats from review — significant downgrade**: Both skeptics refuted most of the original finding. (1) Caching `isEnabled`/`retention` buys nothing — `UserDefaults` reads are in-process cached, not IPC; `retention` isn't even on the tick path (only read once in `pruneOnSchedule()` from `start()`). (2) Raising `tolerance` is a near no-op — it's already 0.2 on a 0.5s interval, 40% slack. (3) "Zero wakeups while asleep" is vacuous — the run loop doesn't fire during real system sleep regardless. (4) The proposed adaptive backoff to 2s is a **correctness regression, not a low-risk win**: `poll()` only ever sees the pasteboard's current `changeCount`-diffed state, so widening the interval means two rapid copies inside one window silently lose the first — this breaks clipboard history's core promise and should not be built. Note `resume()` re-baselines `lastChangeCount`, so anything copied while locked (including a Universal Clipboard push) is silently dropped, not deferred — that's a deliberate policy call worth a test, not a silent side effect.

---

### 9. F165 — Image caches lack a byte budget (narrowed: real risk is one uncapped fallback)

**Where**: `Sources/Floodlight/UI/FileThumbnailCache.swift:12` (corrected from the finding's fabricated line 79 — the file is 72 lines total), `:66` (the actual hazard).

**Evidence**:
```swift
private init() {
    cache.countLimit = 128
}
...
} catch {
    if imageExtensions.contains(ext), let image = NSImage(contentsOf: url) {
        return image
    }
```

**Why it costs / what is missing**: `countLimit = 128` bounds entry count but not bytes, and NSCache does purge under real system memory pressure even without a `cost:` set (the finding's claim that it "effectively never evicts" is false). The genuine unbounded hazard is the QuickLook-failure fallback at line 66: `NSImage(contentsOf: url)` loads at full resolution, ignoring `maxDimension` entirely — a single large photo can be ~96 MB decoded and gets cached uncapped. The cache's only consumer is `FileMediaPreview` (`ClipboardInspectorPane.swift:296,299`), one thumbnail per selected inspector entry — not a per-keystroke cost.

**Proposal**: Downsample the line-66 fallback to `maxDimension * scale` before caching. Optionally add `cache.totalCostLimit` (~32 MB) with a real per-image `cost:` derived from `(rep as? NSBitmapImageRep)?.pixelsWide * pixelsHigh * 4` (use `as?`, never `as!`, per `tools/ast-grep/rules/sources-no-force-cast.yml`), with a conservative fallback estimate when the cast fails.

**Expected impact**: Caps the one genuinely uncapped decode path; low overall impact since typical residency is already a few MB.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Open clipboard mode over 100 copied image/video files including at least one large (>4000px) photo that fails QuickLook generation; `footprint -p $(pgrep -x Floodlight)` before/after the fix. `FileThumbnailCacheTests.testDownsamplesFallbackImage` asserting the cached image's pixel dimensions stay bounded.

**Caveats from review**: Drop `FileIconCache`/`AppIconCache` from scope — they hold icon-sized images (16–256px), not a megabyte-scale risk. Drop the "clear cache in `FloodlightPanelController.hide()`" idea from the original proposal — the panel hides constantly; this would force a QuickLook XPC round trip on every re-selection, a net loss.

---

### 10. F169 — `SearchItem` equality/hashing walks thumbnail bytes (plausible, split)

**Where**: `Sources/FloodlightEngine/Models/SearchItem.swift:259-268`; `ResultRow.swift:27-28`; `SearchView.swift:423`.

**Evidence**:
```swift
package enum SearchItemIconSource: Hashable, Sendable {
    case inferred
    case engine(symbol: String, tint: SearchItemIconTint)
    case thumbnail(Data)
}
```

**Why it costs / what is missing**: `SearchItem` is `Hashable` with no custom `==`/`hash(into:)`, so Swift synthesizes both over `iconSource`, including the embedded thumbnail `Data`. `ResultRow`'s `.equatable()` (`SearchView.swift:423`) drives its diff through `lhs.item == rhs.item`. The accuracy skeptic confirmed the mechanism is real and unmitigated on the FTS hot path (fresh `Data` read from SQLite blobs each search, so no buffer-identity fast path applies).

**Proposal (if pursued)**: Change to `case thumbnail(id: String)` and resolve id → `NSImage` via the shell's thumbnail cache, keeping identity O(1).

**Expected impact**: Low — see caveats.

**Effort/Risk**: M / Medium.

**How to verify on Mac**: `SearchItemRankingPerformanceTests`-style micro-benchmark: 200 `SearchItem`s with 20 KB thumbnails, 11×1,000-iteration `==` comparisons, `FLOODLIGHT_BENCH search_item_equality_us=`.

**Caveats from review — this is why it's ranked low despite a confirmed mechanism**: The value lens refuted the impact claim on four independent grounds: (1) real thumbnails are ~128×128px (a few KB, not the cited 10-40 KB); (2) the result list is virtualized (`LazyVStack`), so only ~8-12 visible rows are ever diffed at once, not "every image row"; (3) no `Set`/`Dictionary` anywhere keys on `SearchItem`, so the synthesized `hash(into:)` is dead weight, not a hot-path cost; (4) `SearchResultPublication.Equatable` has no active call site — publication is reassigned unconditionally, never compared via `==`, so the "multiplies across the publication" framing is unsupported. No `ClipboardHistoryStore.thumbnailPNGData(for:)` accessor exists yet, so building the proposed fix is more than the stated M effort. Recommend only as an opportunistic cleanup if the F163 fix (which already touches this data shape) is undertaken — not as a standalone item.

---

### 11. F170 — Row date formatting rebuilds `Calendar`/format styles per row (plausible, mostly refuted)

**Where**: `Sources/Floodlight/UI/ResultShowcase.swift:30-65`; caller `ResultRow.swift:76-79`.

**Evidence**:
```swift
static func formattedModifiedDate(
    _ date: Date,
    now: Date = .now,
    calendar: Calendar = .current
) -> String {
```

**Why it costs / what is missing**: `formattedModifiedDate` does two `startOfDay` calls, a `dateComponents` call, and a `.formatted()` call whenever `item.modifiedAt != nil`, with no caching. The accuracy skeptic confirmed this runs uncached on every `ResultRow.body` pass for rows with `modifiedAt` set.

**Proposal (if pursued)**: Stop duplicating the time display — clipboard text rows already show `formattedRelativeTime` in the subtitle, so drop `modifiedAt: entry.createdAt` from those two call sites rather than building caching machinery.

**Expected impact**: Low — a readability fix, not a measurable perf win.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Not benchmark-worthy per the value skeptic; if measured anyway, `ResultShowcaseTests`-style: 11×5,000 calls to `formattedModifiedDate`, `FLOODLIGHT_BENCH formatted_modified_date_us=`.

**Caveats from review — mostly refuted**: The value lens refuted the core impact claim: (1) `modifiedAt` is set only in two branches of `buildClipboardTextRow` (~lines 309, 337) — `buildClipboardImageRow` never sets it, so "every clipboard text and image row" is wrong, it's text-only; (2) the "Calendar is a lock plus a copy" claim is unsubstantiated — `Calendar.current` is a cheap cached accessor on Apple platforms; (3) the visible list is virtualized to roughly 10 rows, so the aggregate cost is sub-millisecond and won't move any benchmark; (4) the proposed static-`Calendar`/memoization machinery conflicts with an existing test that deliberately injects a custom calendar (`ResultShowcaseStressTests.swift:156-160`). What survives is a one-line de-duplication of the displayed time on clipboard text rows — a copy-editing fix, not a performance item. Do not build the caching/memoization half of the original proposal.

---

### 12. F171 — Two FFF instances run with zero-valued cache budgets (plausible, largely duplicate)

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:77-89` (verified verbatim); file-index construction is at `FFFIndex.swift:690-708` inside `package extension SourceSearchEngine` — **not** `SourceSearchEngine.swift:701-707` as originally cited (`SourceSearchEngine.swift` is only 547 lines and has no `FFFIndex(` call).

**Evidence**:
```swift
options.enable_mmap_cache = true
options.enable_content_indexing = self.enableContentIndexing
options.watch = self.watch
options.ai_mode = false
...
options.cache_budget_max_files = 0
options.cache_budget_max_bytes = 0
options.cache_budget_max_file_size = 0
```

**Why it costs / what is missing**: Both the file index (content indexing on) and the application catalog's marker index (`ApplicationCatalog.swift:65-73`, content indexing off) construct `FFFIndex` with `enable_mmap_cache = true` and all three `cache_budget_*` fields at 0, with no stated intent and nothing in-repo measuring the resident cost.

**Proposal**: Establish the C-ABI semantics of `cache_budget_max_*` from the vendored `fff-c` source before changing anything; only then set explicit budgets.

**Expected impact**: Low priority as filed.

**Effort/Risk**: S (research) / Low.

**How to verify on Mac**: `footprint -p $(pgrep -x Floodlight)` and `vmmap … | grep -E 'mapped file|MALLOC_LARGE'` on a large tree (~200k files) before/after any change.

**Caveats from review — largely duplicate, both skeptics pushed back**: This repo already has its own prior research on exactly this question: `.scratch/fff-search-bench/research/fff-engine-landscape.md:104` states `start()` hardcodes "cache budgets `0,0,0` (engine defaults)", and `.scratch/optimization/findings-index.md` already tracks this as **U18** (`FFFIndex.swift:83`, medium confidence 0.62, "cache_budget_* are all 0 (auto) and re-auto-sized on every scan, with no hysteresis at the bucket boundary") and the two-LMDB-instance observation as **U11** (`ApplicationCatalog.swift:65`, confidence 0.85) — I confirmed both files and both entries exist verbatim. F171 restates U11+U18 as a new, more uncertain either/or ("unlimited vs. disabled") without citing this existing research. Treat F171 as answered by / duplicate of U11/U18 rather than a new finding; if the maintainer wants certainty beyond the scratch notes, the research prompt below asks for the actual vendored `fff-c` source confirmation, not another restatement.

---

### Rejected ideas

None dropped by both skeptics in this batch. Three items (F169, F170, F171) had one skeptic confirm the underlying mechanism and one skeptic substantially refute the practical impact — these are kept above as **plausible, ranked low**, with the specific refutations spelled out in each Caveats section rather than removed, per the input's split-vote handling rule.


# Upstream FFF

## Upstream: how Floodlight drives the FFF C API

| Rank | ID | Opportunity | Layer | Impact | Effort | Risk | Status | Upstreamable |
|---|---|---|---|---|---|---|---|---|
| 1 | U1 | `fff_live_grep` time budget inert until 2 matches exist | fff-core | medium | S | low | confirmed | yes |
| 2 | U4 | Content search runs unprefiltered during bigram warmup | floodlight | medium | S | low | confirmed | no |
| 3 | U2 | No cancel token for a stale live-grep | fff-c | medium | M | low | confirmed | yes |
| 4 | U8 | `fff_track_query` key mismatch kills combo boost for path queries | floodlight | low (ranking) | S | low | confirmed | no |
| 5 | U12 | Manual rebuild uses full restart instead of rescan | floodlight | low (availability, not speed) | S | low | plausible — split | no |
| 6 | U3 | Single serial FFI queue head-of-line-blocks searches | floodlight | low–medium, disputed | M | medium | plausible — split | partial |
| 7 | U6 | `max_threads=0` gives fuzzy search every logical core | floodlight | unknown, needs Mac data | S | low–medium | plausible — split | yes, if validated |
| 8 | U7 | `.app`-bundle filter runs after engine truncation | floodlight | low | XS | low | plausible — mostly refuted | no |
| 9 | U5 | No `fff_track_access`; access frecency permanently 0 | fff-c / floodlight | low (ranking) | S (Swift alt) / M (Rust) | low / medium | plausible — value lens prefers Swift-only fix | partial |
| 10 | U10 | `exactPathItem` uses two `FileManager` calls | floodlight | low | XS | low | plausible — mostly refuted | no |
| 11 | U11 | ApplicationCatalog opens two unused LMDB stores | floodlight | negligible (hygiene) | S | low | plausible — mostly refuted on perf | no |
| 12 | U14 | File/folder chip counts undercount from truncated page | floodlight | none (cosmetic) | S | low | plausible — refuted as perf | no |
| 13 | U16 | `FffMixedItem` allocates an unused `git_status` string | fff-c | negligible | M | low | plausible — refuted on value | yes, low priority |
| 14 | U19 | Query-history LMDB is written, never read | floodlight | none (perf); product-only | M | low | plausible — refuted as perf | no |
| 15 | U20 | Don't regress: mixed-search defaults are already correct | fff-core / floodlight | n/a | XS (docs) | low | plausible — mostly refuted as action | no |

### U1 — `fff_live_grep`'s time budget is inert until 2 matches exist

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/grep/grep.rs:606-618`; call site `Sources/FloodlightEngine/Search/FFFIndex.swift:353-366`.

**Evidence**
```rust
if local_idx % 8 == 0 {
    let mut need_abort = ctx.abort_signal.load(Ordering::Relaxed);
    if !need_abort
        && let Some(budget) = time_budget
        && all_matches.len() > 1
        && search_start.elapsed() > budget
    {
        need_abort = true;
    }
    if need_abort {
        budget_exceeded.store(true, Ordering::Relaxed);
        return None;
    }
}
```

**Why it costs** `all_matches` is the outer accumulator, only appended between rayon chunks — it is empty during the first chunk, so the 35 ms budget Floodlight passes to `fff_live_grep` cannot fire until a *previous* chunk already flushed 2+ matches. For the common case of a query that matches 0 or 1 file, `perform_grep` walks the whole prefiltered candidate set with no time bound. `abort_signal` is hardcoded `None` (see U2), so nothing else stops it either. Skeptics narrowed this from "any 0-match query" to two concrete regimes: queries whose bigrams are individually common but whose literal matches 0-1 files, and patterns under 2 bytes that bypass the bigram index entirely (blocked in practice by Floodlight's `query.utf8.count >= 3` gate). `SourceSearchEngine.swift:306`'s `indexedFiles.value.count < 12` gate means content search fires almost exactly in the regime where `all_matches` stays at 0-1, so exposure is concentrated, not incidental.

**Proposal** Delete the `all_matches.len() > 1` conjunct so the deadline is unconditional; do not add the redundant outer-loop break the original finding proposed — `grep.rs:676`'s existing `if page_filled || budget_exceeded` break already covers it. If "always return at least a couple of results" is the intent, express it as an explicit `min_results_before_budget: usize` field on `GrepSearchOptions` (default 0) rather than the current implicit bypass — `git log -S` on the vendored fff shows this clause was deliberately added in upstream commit `c2d76b5` ("fix: Indexing on root dirs consumes a lot of CPU and memory (#332)"), so frame the upstream PR as replacing an implicit guarantee with an explicit opt-in.

**Expected impact** Bounds the content-search stage from unbounded to ~35 ms for the narrower-but-still-common 0/1-match regime. Pair with resumption: Floodlight currently discards `next_file_offset`/`has_more` (`fff-c/include/fff.h:1264`), so a hard cutoff silently drops a genuine deep single-match hit — consider a background follow-up `fff_live_grep` at the returned offset, off the keystroke path.

**Effort/Risk** S / low — one-line deletion in the already-forked `Vendor/fff/crates/fff-core/src/grep/grep.rs`.

**How to verify on Mac**
```
cd <fff-swift>/Vendor/fff
cargo run --release -p fff-nvim --bin grep_profiler -- --path $HOME
cargo bench -p fff-search --bench grep_bench
```
Compare median time for a 0-match query ("zzqqxxnomatch") and a 1-match query before/after removing the clause; both should now cap near 35 ms. In-app: Instruments > Points of Interest, subsystem `com.floodlight.app`, interval "ContentSourceSearch" (`SourceSearchEngine.swift:323-325`), histogram while typing a nonsense query in a home-directory scope.

**Caveats from review** GrepMode::Fuzzy has a separate budget path (`grep/fuzzy_grep.rs:104-156`) not covered by this fix — Floodlight only uses `mode=0` (PlainText) so this is fine today but don't generalize the claim to `fff_live_grep` overall. Do not ship the fix without also addressing resumption (see above) or genuine long-tail single-match hits silently vanish.

### U4 — Content search runs unprefiltered during bigram-index warmup

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:677` (`waitForScanCompletion`) and `FFFModels.swift:70-73` (`FFFIndexProgress`).

**Evidence**
```swift
private func waitForScanCompletion() async throws {
    var consecutiveIdlePolls = 0
    while consecutiveIdlePolls < 2 {
        try Task.checkCancellation()
        let progress = try await index.progress()
        consecutiveIdlePolls = progress.isScanning ? 0 : consecutiveIdlePolls + 1
        ...
```
```c
// fff.h:305-310 — the 4th field exists but Floodlight never reads it
typedef struct FffScanProgress { uint64_t scanned_files_count; bool is_scanning; bool is_watcher_ready; bool is_warmup_complete; }
```

**Why it costs** `is_scanning` flips false at `scan.rs:228` — files become searchable — *before* `run_post_scan` builds the bigram index (`scan.rs:240`, `scan.rs:325-334`). `is_warmup_complete` (`!enable_content_indexing || bigram_index.is_some()`, `file_picker.rs:1437-1438`) is exactly the readiness signal, and it's already in the C struct — Floodlight just drops the field. During the whole warmup window, `fff_live_grep` runs with `bigram_candidates = None`, which sends `prefilter_files` down the fallback branch: materialize every non-binary file under `max_file_size` into a `Vec<&FileItem>` and sort the *entire* vector by frecency (`grep/prefilter.rs:149-175`) before greping — the worst possible shape for a budget that (per U1) doesn't even bind reliably. One correction from review: `run_post_scan` does not warm mmaps (that code path is commented out at `scan.rs:357-360`, "Skipped as potentially unsafe") — the cost here is purely the bigram build plus binary sniff, and it is not warmup-exclusive: any regex query whose HIR decomposes to "match anything" (`candidates.rs:80-82`) hits the identical unprefiltered path permanently, not just at cold start.

**Proposal** Add `isWarmupComplete: Bool` to `FFFIndexProgress` (`FFFModels.swift:70-79`), populate from `progress.pointee.is_warmup_complete` in `FFFIndex.progress()` (`FFFIndex.swift:333-337`). Read it *inside* `searchContent`'s own `perform { }` closure (not a separately cached/polled flag — `progress()` shares the same serial queue and would queue behind the very grep it's meant to prevent) and return `[]` early when false. Re-check per query, not once: `commit_new_sync` replaces `sync_data` wholesale on every rescan (`file_picker.rs:1499-1502`), so `bigram_index` goes back to `None` after any scope change, `rebuild()`, or watcher-driven rescan. Do NOT extend `waitForScanCompletion` to wait on warmup — that delays first-query readiness by the full content-index build. Also clear `pendingKinds: [.file]` for that snapshot so the UI doesn't show a pending file affordance that resolves to nothing (`SourceSearchEngine.swift:315`).

**Expected impact** Eliminates the pathological full-scan-plus-sort grep during the entire cold-start/post-rescan warmup window (can be seconds to minutes on a large home directory). Zero effect once warmup completes — this is a cold-start-only fix, not a steady-state one.

**Effort/Risk** S / low — pure Swift, no Rust or XCFramework change (field already exists in the pinned fff-swift 0.2.1 header and is populated in `crates/fff-c/src/ffi_types.rs:779`).

**How to verify on Mac** Instruments > Time Profiler + Points of Interest: cold-launch with a fresh `~/Library/Application Support/FFFKit`, type a 4-char query immediately, record "ContentSourceSearch" interval durations for the first 30s before/after. Cross-check with `FLOODLIGHT_FFF_LOG=/tmp/fff.log FLOODLIGHT_FFF_LOG_LEVEL=debug` and grep for the `prefiltered_count` field on `perform_grep`'s `#[tracing::instrument]` (`grep.rs:542-546`) — pre-fix it should equal the whole file count.

**Caveats from review** Confirmed by both skeptics, impact adjusted to medium (bounded to the warmup window, not "the first minute of use" universally — exposure also depends on `contentEligible`'s `< 12` gate, which is live during warmup too since filename search works immediately). Implementation must sample the flag from inside `searchContent`'s own dispatch, not a background poller, or it goes stale after a rescan.

### U2 — C API never exposes a cancel signal for live-grep

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/lib.rs:672` (`fff_live_grep`) and `:754` (`fff_multi_grep`).

**Evidence**
```rust
let options = fff::GrepSearchOptions {
    max_file_size: default_u64(max_file_size, 10 * 1024 * 1024),
    ...
    abort_signal: None,
};
let result = picker.grep(&parsed, &options);
```

**Why it costs** `fff-core` already supports per-call cancellation (`Option<Arc<AtomicBool>>`, checked every 8th file at `grep.rs:607`), but both grep entry points hardcode `None` and the header exports no cancel symbol at all (`rg -in "cancel" fff.h` → zero hits). `searchContent` (`FFFIndex.swift:341`) also never reserves a generation counter, unlike `search`/`searchFiles`/`searchDirectories`. So a stale grep from keystroke N runs to completion and queues ahead of keystroke N+1's `fff_search_mixed` on Floodlight's single serial `DispatchQueue`. Review correction: abort granularity is not "within 8 files" as originally claimed — the check is gated by `local_idx % 8 == 0` *per rayon worker within a chunk*, and the outer loop only breaks at chunk boundaries, which grow to `max(base_chunk*256, 8*1024)` under a weak prefilter (`grep.rs:579-586`). Realistic abort latency is up to thousands of files late in a weak-prefilter scan, not 8.

**Proposal** Add an opaque cancel token to fff-c:
```rust
#[unsafe(no_mangle)]
pub extern "C" fn fff_cancel_token_new() -> *mut c_void { ... }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fff_cancel_token_cancel(t: *mut c_void) { /* store(true, Release) */ }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fff_cancel_token_free(t: *mut c_void) { /* drop */ }
```
plus `fff_live_grep_cancellable(..., cancel_token: *mut c_void)` setting `abort_signal: Some(Arc::clone(token))`, applied to both `fff_live_grep` and `fff_multi_grep`. In Floodlight, `FFFIndex.searchContent` allocates a token per call, stores it behind a lock, and `reserveSearchGeneration()` cancels the previous token before enqueuing the next search.

**Expected impact** Turns a stale content search from "runs to completion, blocking the next keystroke" into "aborts within one chunk". Real but smaller than originally framed once U1 lands — with the budget unconditional, a stale grep already self-terminates near 35 ms regardless of cancellation, so the marginal win of this item shrinks once U1 ships. Land U1 first; U2 is the complement for the remaining tail.

**Effort/Risk** M / low — cross-layer (fff-c + header + XCFramework rebuild + Swift wrapper).

**How to verify on Mac**
```
cd <fff-swift>/Vendor/fff && cargo test -p fff-c
cargo run --release -p fff-nvim --bin grep_profiler -- --path $HOME
```
Add a thread that flips the abort flag after 10 ms; assert wall time drops sharply versus an uncancelled run. In-app: Instruments Points of Interest, gap between consecutive "SourceSearch" begin events while typing at ~40 ms/keystroke.

**Caveats from review** Do this after U1, not instead of it — U1 is a 1-line fix with most of the same payoff for the dominant 0/1-match case. `fuzzy_search`/`fff_search_mixed` has no abort check at all today; threading the same token through it (as the original proposal suggested) is a materially larger core change, not a follow-on line-item.

### U8 — `fff_track_query` records the raw query while `fff_search_mixed` uses the path-translated one

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:440` (`track`) vs. `:111-127` (`search`).

**Evidence**
```swift
// search(): translated query
let resolvedQuery = Self.resolvePathQuery(query, rootURL: self.rootURL, homeURL: self.homeURL)
let envelope = resolvedQuery.fffQuery.withCString { fff_search_mixed(handle, $0, nil, 0, 0, limit, 100, 3) }
// track(): raw query
let envelope = query.withCString { qp in selectedURL.path.withCString { pp in fff_track_query(handle, qp, pp) } }
```

**Why it costs** `resolvePathQuery` rewrites `~/code/foo` and `/Users/me/code/foo` into the root-relative `code/foo`. `QueryTracker::create_query_key` hashes `project_path + "::" + query` (`query_tracker.rs:144-155`), so write and read keys never collide for any in-root path query. The combo boost (`get_last_query_entry`, `file_picker.rs:1093-1105`, awarded at `score.rs:794-816`) is dead for exactly the path queries where "you picked this file for this query before" matters most. A second, smaller gap: `SourceSearchEngine.search` passes the *trimmed* query (`SourceSearchEngine.swift:125,159`) while `trackSelection` forwards the untrimmed one (`:232`).

**Proposal**
```swift
let resolved = Self.resolvePathQuery(query, rootURL: self.rootURL, homeURL: self.homeURL)
let key = resolved.fffQuery.isEmpty ? nil : resolved.fffQuery  // skip tracking when search short-circuited
if let key {
    let envelope = key.withCString { qp in selectedURL.path.withCString { pp in fff_track_query(handle, qp, pp) } }
}
```
Pass the already-trimmed `normalized` (computed at `SourceSearchEngine.swift:229`) into `files.track` instead of the raw `query`. Fix the scope guard on the line above too: `selectedURL.path.hasPrefix(self.rootURL.path)` (`FFFIndex.swift:436`) false-matches `/Users/f/code2` against root `/Users/f/code`; compare against `rootURL.path + "/"` (careful with `rootURL.path == "/"`).

**Expected impact** Restores the combo-match boost for path-like queries repeated 3+ times (Floodlight's `min_combo_count = 3`, `FFFIndex.swift:126`). Reviewers note the dead zone is narrower than "any `~/` or leading `/` query": `resolvePathQuery` only translates in-root paths, and it never applies at all when the query ends in `/` (`fuzzy_search_mixed`'s `dirs_only` branch skips `fuzzy_search`/the combo lookup entirely for trailing-slash queries — `file_picker.rs:1224-1240`). Ranking-quality fix, no latency effect.

**Effort/Risk** S / low — Swift-only.

**How to verify on Mac** Add a `Tests/FloodlightEngineTests/FFFIndexTests.swift` case: `track(query: "~/Projects/report", selectedURL:)` three times, then assert `search("~/Projects/report")` ranks it first. Cross-check with `FLOODLIGHT_FFF_LOG=/tmp/fff.log FLOODLIGHT_FFF_LOG_LEVEL=debug` and the query-key hash debug line at `query_tracker.rs:365`.

**Caveats from review** Confirmed by both lenses; corrected line for the combo lookup is `file_picker.rs:1093-1105` inside `fuzzy_search` (not `fuzzy_search_mixed`). Existing-path queries already get pinned to slot 0 by `FFFIndex.swift:173-179` regardless of the combo boost, so the practical payoff is narrower than "the class of query where this matters most" — it helps typo'd/partial path queries repeated 3+ times, not exact existing-path queries.

### U12 — Manual "Rebuild index" tears down the whole picker instead of rescanning

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:664` (`FFFFileSource.rebuild`).

**Evidence**
```swift
func rebuild() async throws {
    let currentRoot = state.withLock { $0.rootURL }
    try await index.changeRoot(to: currentRoot)   // → fff_restart_index, full picker teardown
    try await waitForScanCompletion()
}
// the cheap path already exists and is used by ApplicationCatalog:
package func rescan() async throws { try Self.requireSuccess(fff_scan_files(handle)) }
```

**Why it costs** `changeRoot` → `fff_restart_index` takes `picker.write()`, drops the whole `FilePicker`, and constructs a new one — new watcher, new bigram index (rebuilt either way, see below), fresh cache-budget state. `fff_scan_files` re-walks into the *existing* picker. Review corrected the original framing on two points: (1) the content/bigram index is rebuilt from scratch on the cheap rescan path too (`ScanJob::new_rescan` inherits `content_indexing`, `scan.rs:88-90`), so there is no warmup saved; (2) the real, previously-unstated benefit is *availability* — `fff_restart_index` publishes an empty picker before the walk begins (`file_picker.rs:966-971`), so search returns nothing for the entire rebuild, whereas `fff_scan_files` keeps serving the old snapshot until `commit_new_sync`. This is a UX fix, not a latency fix, and it's a rare, menu-triggered path (not per-keystroke, not cold start).

**Proposal**
```swift
func rebuild() async throws {
    try await index.rescan()
    try await waitForScanCompletion()
}
```
But do not do this unconditionally: `rescan()`'s `ScanJob::new_rescan` sets `install_watcher: false` (`scan.rs:91`, "the watcher is independent of rescan, it is not restarting EVER") — it never recreates `BackgroundWatcher`. If "Rebuild index" exists partly to recover a dead FSEvents stream, keep a restart fallback for that case (e.g. only restart if the watcher never reported ready), or split the menu into "Rescan" (cheap, default) and "Reset index" (hard restart).

**Expected impact** Search stays usable during a manual rebuild instead of going empty; the exclusive-write-lock window shrinks to a pointer swap. No measurable change to per-keystroke or cold-start latency.

**Effort/Risk** S / low.

**How to verify on Mac** `cd <fff-swift>/Vendor/fff && cargo run --release -p fff-nvim --bin rescan_probe` against `$HOME` for the rescan-vs-restart cost split. In-app: os_signpost around the rebuild menu action; confirm searches issued mid-rebuild still return results (today they return empty, or nothing, until restart completes).

**Caveats from review** Value-lens reviewer refuted the original latency framing outright (both branches walk the identical filesystem; the only removed work is picker allocation + one FSEvents stream setup — milliseconds against a multi-second walk) but confirmed the availability benefit as the real, previously unstated payoff. Ship it for that reason, reframed, and keep the watcher-recovery fallback.

### U3 — Single serial FFI queue can head-of-line-block the next keystroke

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:7`.

**Evidence**
```swift
private let queue = DispatchQueue(label: "dev.vmg.fff-swift", qos: .userInitiated)
// fff-c is concurrent-read safe: fff-c/src/lib.rs:564 picker.read() (RwLock);
// only fff_restart_index/fff_destroy need picker.write()
```

**Why it costs** All of `search`, `searchContent`, `progress`, `track`, `rescan`, `changeRoot` funnel through one serial queue, but the FFI itself is concurrent-read safe (`parking_lot::RwLock`, exclusive only for restart/destroy). A stale content search can therefore block the next keystroke's fuzzy search even though nothing in the Rust layer requires it.

**Proposal** The originally proposed three-queue split is unsafe as written — `FFFIndex` is `@unchecked Sendable` and relies on the single serial queue for exclusive access to `self.handle` and `self.rootURL` (both plain vars, written in `start()`/`changeRoot`, read from every search path). Splitting queues without a lock introduces a data race on those two properties, potentially emitting result URLs under the wrong root. If pursued, use one `DispatchQueue(attributes: .concurrent)` with search/progress/track submitted normally and `start`/`changeRoot`/`rescan`/`destroy` submitted with `.barrier` — this mirrors the Rust `RwLock` semantics and needs `handle`/`rootURL` moved behind a lock or made per-operation snapshots.

**Expected impact** Disputed. One skeptic accepted a conditional medium impact (narrowed to queries with few filename matches, since `contentEligible` only fires when `indexedFiles.count < 12`). The value-lens skeptic refuted it outright: with U1 fixed, the grep is bounded at ~35 ms and the timing usually doesn't overlap the next keystroke anyway (grep runs ~t=50-85ms, next indexed stage starts ~t=115-120ms at typical typing cadence); splitting queues without fixing U1 first just moves contention onto the same P-cores at the same QoS rather than removing it.

**Effort/Risk** M / medium — real correctness risk if the lock discipline isn't done carefully.

**How to verify on Mac** Instruments > Points of Interest: overlay "ContentSourceSearch" and "IndexedSourceSearch" intervals while typing continuously — today they never overlap; after a *correct* change they should, with no result-URL corruption. Add an XCTest firing `searchContent` and `search` concurrently on one `FFFIndex` over a temp tree, asserting `search` completes in <5 ms while grep runs.

**Caveats from review** Do U1 and the `searchContent` generation-counter fix first (cheap, safe) and re-measure before attempting the queue split — the value-lens skeptic's position is that the split is unneeded once the grep is properly bounded and cancellable, and that a naive split is an availability/correctness risk for a benefit that mostly evaporates.

### U6 — `max_threads=0` gives fuzzy search every logical core

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:126,201,258`.

**Evidence**
```swift
fff_search_mixed(handle, $0, nil, 0, 0, limit, 100, 3)   // arg 4 = max_threads = 0
// resolves to std::thread::available_parallelism() (file_picker.rs:1064-1070)
// while grep is deliberately P-core-sized (parallelism.rs) — but fuzzy search has no such pool
```

**Why it costs** `SEARCH_THREAD_POOL` is P-core-sized and QoS-pinned, but only installed around grep/multi_grep — never around `fuzzy_search`/`fuzzy_search_mixed`, which take `max_threads` straight into `neo_frizbee::match_list_parallel*`. `0` means every logical core, including E-cores, on the exact per-keystroke path over the whole home-directory index.

**Proposal** Compute P-core count via `sysctlbyname("hw.perflevel0.physicalcpu", ...)` once in Swift and pass it explicitly at the three `fff_search*` call sites. **Do not land without measuring first** — see caveats.

**Expected impact** Unknown, disputed. The finder's ~20% figure (16 threads vs 13, 6.2s→4.9s) is a `grep` measurement whose stated cause (per-`open()` VFS-lock contention on file-heavy I/O) does not transfer to fuzzy matching, which is pure in-memory SIMD with no syscalls. On base Apple silicon (4P+4E), `hw.perflevel0.physicalcpu` is 4 — capping fuzzy search there could *regress* a bandwidth-bound scan from 8 threads to 4. The engine's own reference client (fff-nvim's Lua binding) hardcodes `max_threads = 4` regardless of core topology, which is a better-supported default than "P-core count" if a fixed value is wanted without measurement.

**Effort/Risk** S / low-to-medium — cheap to implement, risk is in getting the number wrong for base-tier Macs.

**How to verify on Mac** Extend `crates/fff-nvim/benches/fuzzy_search_bench.rs`'s `thread_scaling` bench (currently stops at 8) to sweep `{2, 4, P-core count, logical-core count}` on both a 4P+4E and a 12P+4E machine over a home-sized index, before touching Swift. In-app: Instruments Points of Interest, "IndexedSourceSearch" interval median over 200 keystrokes, home scope, before/after whichever value the bench picks.

**Caveats from review** Both skeptics push back hard on the magnitude claim and one flags a plausible regression on base Apple silicon. Treat this purely as "measure on the target Mac before choosing a constant" — do not ship a P-core-count cap on the finder's evidence alone.

### U7 — `.app`-bundle filter runs in Swift after the engine already truncated the page

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:151` (and 4 duplicate sites).

**Evidence**
```swift
let components = relativePath.split(separator: "/")
if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) { return nil }
// engine already truncated to `limit` before this filter runs (file_picker.rs:1327-1329)
```

**Why it costs** `fff_search_mixed` is asked for exactly 12 items, then Floodlight deletes some post-hoc, so a query touching a `.app` bundle's internals can silently return fewer than 12 rows — which then flips `contentEligible` and fires an unneeded live-grep. Review found the allocation-cost half of the original finding (~7 allocations/result, ~100/keystroke) overstated 3-4x: `dropLast()` on an array is a non-allocating slice, and `lowercased()` on short path components uses Swift's inline small-string form. Half the 12-24 results/keystroke (the ApplicationCatalog instance) never even reach this code path since its marker paths are single-component.

**Proposal** Drop the byte-scan micro-optimization and the `extra_ignore_globs`/ABI-version-bump upstream proposal (L effort, requires a fork-vendored ABI change plus static XCFramework rebuild, and the payoff — shrinking the home index by `.app` internals — barely applies since most `.app` bundles live in `/Applications`, already largely covered by existing `ignore.rs` excludes). Keep only the one-line over-fetch: `fff_search_mixed(handle, $0, nil, 0, 0, limit + 8, 100, 3)` then `Array(items.prefix(Int(limit)))` after Swift's post-filter — cheap because `fuzzy_search_mixed` already runs `internal_limit = (offset+limit)*2` internally.

**Expected impact** Fixes the page-starvation/spurious-live-grep correctness nit at near-zero cost. Not a meaningful allocation win.

**Effort/Risk** XS / low.

**How to verify on Mac** Add a regression case to `Tests/FloodlightEngineTests/FFFIndexTests.swift`: a temp tree with `Foo.app/Contents/MacOS/needle` plus 20 other matches should return 12 non-bundle rows.

**Caveats from review** Both skeptics refuted the byte-scan and ignore-glob halves of the original proposal; the surviving fix is the over-fetch line only. Note `searchDirectories` intentionally omits `.dropLast()` (so a directory whose own name ends `.app` is filtered) — a shared byte-scan helper must not be applied uniformly across all five call sites.

### U5 — No `fff_track_access`; file-open frecency is permanently zero

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/lib.rs:1001` (`fff_track_query`, writes only the query tracker).

**Evidence**
```rust
// fff_track_query writes only inst.query_tracker — never inst.frecency
// FrecencyTracker::track_access is reachable only from fff-nvim's Lua binding
// and from the watcher in AI mode; Floodlight sets ai_mode = false (FFFIndex.swift:80)
```

**Why it costs** `access_frecency_score` is always 0 because nothing ever calls `track_access`. Review found this less severe than framed: Floodlight already gets a live repeat-open signal via the *combo boost* (`get_last_query_entry`, tied to the exact query string, multiplier 100, min_combo_count 3), so "files I open often is structurally dead" is too strong — what's actually missing is generalization across *varying* queries for the same file.

**Proposal (preferred, Swift-only)** Floodlight already has `Sources/FloodlightEngine/Utilities/RecentStore.swift` (launch counts + last-opened, currently boosting only app results). Drop the `isApplication` gate in `SelectedResultActionPerformer.swift:214,227` so file/folder selections record too, and add the boost when constructing file `SearchItem`s in `FFFIndex.swift:157-169` (mirroring `ApplicationCatalog.swift:177`). No Rust, no XCFramework rebuild, ships today.

**Proposal (upstream, optional)** If directory-level frecency (`DirItem.max_access_frecency`) is also wanted, add `fff_track_access` to fff-c mirroring `fff-nvim/src/lib.rs:532-586`, called from `FFFIndex.track` after `fff_track_query`.

**Expected impact** Low-to-medium ranking quality improvement; zero latency effect either way.

**Effort/Risk** S (Swift path) / M (Rust path, requires vendored-crate change + release + checksum bump since fff-swift ships a prebuilt checksummed XCFramework) — low / medium risk.

**How to verify on Mac** Extend `Tests/FloodlightEngineTests/FFFIndexTests.swift`/RecentStore tests: open file B five times, assert B outranks a lexically-better A for a shared prefix.

**Caveats from review** Value-lens skeptic refuted the Rust-first proposal specifically because a strictly simpler, already-shipped equivalent (`RecentStore`) exists in-repo; do the Swift path first and treat `fff_track_access` as optional follow-up, not the primary fix.

### U10 — `exactPathItem` does two `FileManager` calls on the FFI queue

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:551,560`.

**Evidence**
```swift
guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
```

**Why it costs** Every path-shaped query does a `stat` plus a full `attributesOfItem` dictionary build (owner/group name lookups included) inside `perform { }` on FFFIndex's queue, though only `.modificationDate` and `.size` are used. Review found the "double stat" claim false (the two call sites are mutually exclusive branches of one `if`) and the proposed `lstat` replacement a correctness regression: `FileManager.fileExists` follows symlinks, `lstat` doesn't, so a symlinked directory under `~` would mis-report its kind and a broken symlink would surface as a bogus top result.

**Proposal** Replace both calls with one `URL.resourceValues(forKeys:)` call, which keeps symlink-following semantics and collapses to one `getattrlist`:
```swift
let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
guard let values, values.isDirectory != nil else { return nil }
```

**Expected impact** Small — removes one dictionary build and the owner/group-name lookups `attributesOfItem` performs; the network-mount stall scenario the original finding raised is not actually fixed by this (the hotter, more exposed synchronous FileManager calls are in `PathNavigator.swift`, out of scope for this section).

**Effort/Risk** XS / low.

**How to verify on Mac** Instruments > File Activity while typing `~/Doc` character by character; count `getattrlist` calls per keystroke before/after.

**Caveats from review** Value-lens skeptic refuted this as a "correctness gate violation" — no such rule exists in the codebase, and synchronous FileManager calls on the keystroke path are the established pattern elsewhere too. Treat as a small tidiness fix, not a latency fix.

### U11 — ApplicationCatalog's second FFF instance opens two unused LMDB stores

**Where** `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:65`.

**Evidence**
```swift
index = FFFIndex(rootURL: markerRoot, storageURL: .../"Database", enableContentIndexing: false, watch: false, ...)
// FFFIndex.start() unconditionally opens frecency.lmdb and history.lmdb regardless
```

**Why it costs** The app index's own FFF-computed scores are entirely discarded and recomputed in Swift (`ApplicationCatalog.swift:138-151`), yet `FFFIndex` still opens two LMDB envs and spawns two GC threads for it, and every `fff_search` call takes a query-tracker read lock. Review found the perf claim overstated: the per-keystroke LMDB read is one transaction against a 10 MB map — microseconds, not a meaningful cost — and the proposed `enableMmapCache: false` companion fix targets dead code (`need_complex_rebuild` has zero callers in the vendored tree; mmap warmup is commented out).

**Proposal** Add `enablePersistentRanking: Bool = true` to `FFFIndex.init`, honor it in `start()` by passing `nil` for both DB paths when false, and set it false for the ApplicationCatalog instance. Delete `ApplicationCatalog.track` (dead write path; recency for apps already comes from `RecentStore`). Drop the `enableMmapCache: false` sub-proposal — it targets dead code.

**Expected impact** Negligible performance change; genuine value is removing two unused files and a real robustness bug: `fff_create_instance_with` hard-errors if either LMDB fails to open, so a corrupt frecency/history DB the app catalog never uses can currently prevent application search from starting at all.

**Effort/Risk** S / low.

**How to verify on Mac** Instruments Points of Interest: "ApplicationDiscovery"/"IndexStartup" interval durations at cold launch, before/after (expect no meaningful change, confirming this is a hygiene fix).

**Caveats from review** Both skeptics downgraded the perf claim; keep the change for the startup-failure-mode argument, not a speed argument.

### U14 — File/folder match counts undercount from the truncated page

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:139`.

**Evidence** `result.pointee.total_matched` and `.total_files` are computed by the engine (`file_picker.rs:1298-1300`) and cross the FFI boundary already, but Floodlight reads only `.count` — files/folders report the visible-row count instead of a true total, unlike apps/settings.

**Why it costs** Cosmetic: filter chips under-report file matches. Review refuted the perf framing entirely (no runtime cost either way) and found the proposal partly unimplementable as described — `total_matched` is a single files+dirs sum, not splittable into separate `.file`/`.folder` overrides, and `total_files` is index size, not a match count. The consuming UI (`SearchResultProjection.filterOptions`) doesn't even route `.files`/`.folders` through the totals dict today, so wiring the value through `SourceSearchEngine` alone would be a no-op.

**Proposal** Not worth doing as an optimization. If pursued as a UX fix, first add real paging for the file/folder filter chip (re-query with a larger limit when that chip is selected) before showing a total the user can't reach; otherwise display a saturating "12+" rather than a precise but unreachable number.

**Expected impact** None on latency; cosmetic UI accuracy only.

**Effort/Risk** S / low — but low priority given no functional payoff.

**How to verify on Mac** N/A (correctness-only; no Mac experiment needed).

**Caveats from review** Refuted as a performance item by both angles; keep only if product wants the UX fix, and scope it as described above.

### U16 — `FffMixedItem` allocates a `git_status` string Floodlight never reads

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/ffi_types.rs:673`.

**Evidence** `git_status: cstring_new(format_git_status(file.git_status))` for files, `cstring_new("")` for dirs — Floodlight reads only `display_name`/`relative_path`.

**Why it costs** Extra heap allocations per result (review found the true count is ~5 per item, not 3 — `relative_path`/`file_name` already build an owned Rust `String` before `cstring_new` copies it into a `CString`), on a struct with no length fields so Swift must `strlen` every conversion. But at ~12-24 items/keystroke this is single-digit microseconds against a millisecond-scale fuzzy search — both skeptics refuted this as a measurable win. The value-lens reviewer also found the proposed `relative_path_len`/`display_name_offset` struct fields are **not** ABI-compatible as claimed: `FffMixedItem` is stride-indexed (`result.items.add(index)`, `lib.rs:1571-1583`) with no version field (unlike `FffCreateOptions`), so any size change breaks every consumer compiled against the old header — this needs a coordinated header + XCFramework rebuild, not an append-only change.

**Proposal** Deprioritize. If touched at all, do the ABI-free half only: null `git_status` when unmodified (accessor already null-checks) and have `cstring_new` write directly into the CString buffer instead of via an intermediate `String`. The much larger, ABI-free win is on the Swift side: replace `relativePath.split(separator: "/")` + `.lowercased()` (U7's `.app` filter) with an ASCII byte scan — same technique already landed for app search — which dominates this entire finding and needs no Rust change.

**Expected impact** Negligible; redirect effort to U7's Swift-side fix instead.

**Effort/Risk** M / low — but not worth the effort given the measured magnitude.

**How to verify on Mac** Not recommended as a standalone experiment; if curious, `cargo bench` a `FffMixedSearchResult::from_core` case over a 60-item result 10k times.

**Caveats from review** Both skeptics refuted the ABI-compatibility claim and the magnitude; keep this low on the list.

### U19 — Query-history LMDB is written on every selection, never read

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:433` (`track`); no call site for `fff_get_historical_query` anywhere.

**Evidence** `fff_track_query` appends to `query_history_db` (capped at 128 entries, `query_tracker.rs:12`) on every selection; `fff_get_historical_query` exists in the header (`fff.h:749`) and is never called. `SourceSearchEngine.swift:142` returns nothing at all for an empty query.

**Why it costs** A zero-keystroke "recent searches" affordance is already fully persisted and unused. Review refuted this as a perf finding (write cost is one extra `put` inside an existing transaction; the *read* path that IS exercised per keystroke, `query_file_db`'s combo lookup, is unrelated and already live) and found a better data source already in-repo: `RecentStore.swift` tracks actual opened items (openable rows with icons) versus `fff_get_historical_query`'s bare query strings (which still require a re-search). The FFI read is also O(N×128) — each offset call re-deserializes the whole 128-entry deque (`query_tracker.rs:199-226`).

**Proposal** If pursued, build the empty-query suggestion list from `RecentStore` (zero FFI work, ships today) rather than `fff_get_historical_query`. Only reach for the FFI history if the specific desired affordance is "re-run a past query string," and then batch it (a single `fff_get_query_history(handle, limit)` returning a deduped list would be the right upstream shape, not per-offset calls).

**Expected impact** Product/UX value only; no latency effect.

**Effort/Risk** M / low — but reclassify as a feature request, not an optimization.

**How to verify on Mac** N/A for this section (no latency claim to verify).

**Caveats from review** Refuted as a performance finding by the value lens; keep as a product note if the maintainer wants a "recent searches" empty state, sourced from `RecentStore` instead.

### U20 — Don't regress: three "obvious improvements" are already correct

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1238` (`dirs_only` detection), `score.rs:1021-1034` (partial sort), `grep.rs:639` (`max_matches_per_file`).

**Evidence** `fuzzy_search_mixed` already detects a trailing `/` and skips the file search; `page_size=12` (→`internal_limit=24`) is what engages `select_nth_unstable_by`'s partial sort instead of a full sort; `max_matches_per_file=1` at `FFFIndex.swift:353` is a genuine per-file early stop (`grep.rs:129`, the sink returns `false` to halt that file's scan), not a post-filter.

**Why it costs (of "fixing" it)** Raising `page_size` toward the engine default would only disable the partial sort once `total_matched > 400` (review corrected the finder's `> 200` threshold), and even then `sort_with_buffer` still runs afterward — so the claimed "no-full-sort gate" doesn't fully exist either way; the risk is entirely on the "don't touch this" side. Raising `max_matches_per_file` would both slow the grep and add extra rows per file, not dedupe them (review corrected "duplicate rows" — Floodlight's result id embeds the line number, so extra matches are distinct rows, just noisier).

**Proposal** No code change. Add source comments at the three call sites recording *why* the constants are what they are, so they aren't "tidied" later:
- `FFFIndex.swift:126` — small `limit` keeps `use_partial_sort` engaged (break-even ~`total_matched > 4× limit`, not a hard 200).
- `FFFIndex.swift:353` — `max_matches_per_file: 1` is a per-file early-exit optimization, not a display cap.
- `searchDirectories` (`FFFIndex.swift:244-301`): has no production call site (only ~10 test references in `FFFIndexTests.swift`, including seeded-folder-move watcher-coherence coverage) — mark it test-only rather than deleting it; removing it loses that coverage for no runtime benefit.

**Expected impact** Prevents future regressions; zero present-day change.

**Effort/Risk** XS (comments) / low.

**How to verify on Mac** Not applicable as an active change; if validating the partial-sort claim for documentation purposes, `cargo run --release -p fff-nvim --bin bench_search_only` with `page_size` 12 vs 100 over a large checkout, comparing broad two-letter queries.

**Caveats from review** Both skeptics corrected specific numeric claims (threshold, default `limit` value at other call sites) but did not dispute the core "don't touch this" recommendation.

### Rejected ideas

- **U9** — grep snippet unbounded `String(cString:)` allocating megabytes: refuted, `MAX_LINE_DISPLAY_LEN = 512` already truncates every grep match before it crosses the FFI boundary (`grep/sink.rs:5-7`); real worst case is ~24 KB/query, not 10 MiB.
- **U13** — ApplicationCatalog reimplements scan-waiting with a race: refuted, the vendored fff already pre-arms `scanning = true` before `fff_create_instance_with` returns (`file_picker.rs:951-961`), specifically to close this race.
- **U15** — `contentEligible` should use `total_matched`/`next_file_offset` instead of page count: refuted, `total_matched` counts pre-filter matches across the whole index including hidden `.app` internals, so the proposed gate would suppress live-grep more often, not less; the existing grep is already time-budgeted (mode 0, 35 ms).
- **U17** — unread `regex_fallback_error`/`literal_fallback` flags mask a degraded search: refuted, `regex_fallback_error` is unreachable under Floodlight's `mode=0` (plain text), `literal_fallback` isn't even in the C struct, and the consuming `isDegraded` flag has zero UI consumers today.
- **U18** — zeroed cache-budget options cause churn/hysteresis at bucket boundaries: refuted, `ContentCacheBudget` owns no mmaps (rescan wipes cache state regardless of budget), the home-directory workload sits far above the bucket boundaries, and the proposed patch values would actually reduce grep recall (4 MB file-size cap) and 6x memory (30,000-file default via the all-or-nothing `from_overrides`).

## Upstream: fff-core query path (make it blazing fast)

All items patch `fff-swift/Vendor/fff/crates/fff-core` (the vendored fork of `dmtrKovalenko/fff` at 0.10.5) unless noted. Landing any of them means: edit the vendored crate, add an entry to `Vendor/fff/UPSTREAM.md`, rebuild via `fff-swift/scripts/build-xcframework.sh`, re-pin in Floodlight. None of this can be built/benched on this (Windows) host — every number below is read from code, not measured; treat all "expected impact" figures as hypotheses to confirm on the Mac.

### Ranked opportunities

| Rank | ID | Opportunity | Layer | Impact | Effort | Risk | Status | Upstreamable |
|---|---|---|---|---|---|---|---|---|
| 1 | U21 | `max_typos` floor of 2 makes short queries match ~the whole index | fff-core | High (root cause) | S | Medium | Confirmed | Yes |
| 2 | U24 | No top-k: full match set materialized, `select_nth` over all of it | fff-core | Medium-High | M | Medium | Confirmed | Yes |
| 3 | U22 | 1-char queries score/materialize the entire file+dir index | fff-core / Floodlight FFI usage | Medium | M | Low | Confirmed | Yes |
| 4 | U23 | Post-match scoring loop is single-threaded over every match | fff-core | Medium | M | Medium | Confirmed | Yes |
| 5 | U26 | Dir search allocates `Vec<&DirItem>` over the whole table, serially | fff-core | Low-Medium | M | Low | Confirmed | Yes |
| 6 | U27 | Dir scoring copies the full path into a buffer just for a length | fff-core | Medium | S | Low | Confirmed | Yes |
| 7 | U25 | `fuzzy_search_mixed` computes highlight offsets and discards them | fff-core | Low | S | Low | Confirmed | Yes |
| 8 | U30 | `combo_match_boost` recomputes loop-invariant work per match | fff-core | Low-Medium | S | Low | Confirmed | Yes |
| 9 | U35 | Watcher batch holds picker write-lock across an uncapped file read | fff-core | Low (tail latency) | S | Low | Confirmed | Yes |
| 10 | U38 | No benchmark covers Floodlight's actual query shape | fff-core / Floodlight testing | Medium (enabling) | S | Low | Plausible | Yes |
| 11 | U31 | `FileItem` is ~96 B but the matcher reads ~33 of them | fff-core | Low (footprint) | L | Medium | Confirmed | Yes |
| 12 | U34 | Filename bonus scores against the wrong needle for multi-part queries | fff-core | Low (correctness) | S | Low | Confirmed | Yes |
| 13 | U28 | Fallback-rematch thread count formula is transposed (dead branch) | fff-core | Low | S | Low | Plausible | Yes |
| 14 | U32 | No incremental narrowing across keystrokes (prefix-cache candidate) | fff-core | Speculative | L | High | Plausible | Yes |
| 15 | U36 | Mixed search runs dir/file sequentially with symmetric 2x limit | fff-core | Low | S | Low | Plausible | Yes |
| 16 | U37 | Overflow-then-base result vec is built via `extend` (one extra copy) | fff-core | Low | S | Low | Plausible | Yes |

### 1. U21 — `max_typos` floor of 2 makes short queries match ~the whole index

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1091` (files), `:1178` (dirs)

**Evidence**
```rust
// small queries with a large number of results can match absolutely everything
let max_typos = (effective_query.len() as u16 / 4).clamp(2, 6);
```

**Why it costs**: `max_typos` counts needle characters allowed to go unmatched (confirmed by fff's own comment at `grep/fuzzy_grep.rs:262-265` and its existing monotone, zero-floored formula there, `(len/3).min(2)`). With a floor of 2, a query of length 2-11 requires matching only `len-2` characters against the *full relative path*, not the filename. Every downstream stage in this report — the serial scoring loop (U23), the 72-byte-per-match Vec (U24), `select_nth_unstable_by` over the result, the 15k fallback cutoff — is sized by how many files survive this filter. This is the constant that decides whether everything else is cheap or expensive.

**Proposal**: Replace the clamp with a monotone-non-decreasing, zero-floored budget, shared between the files and dirs call sites:
```rust
#[inline]
pub(crate) fn typo_budget(query_len: usize) -> u16 {
    match query_len {
        0..=3 => 0,
        4..=6 => 1,
        7..=11 => 2,
        _ => ((query_len / 4) as u16).min(6),
    }
}
```
Minimal/lower-risk alternative (mirrors the existing clamp at `score.rs:99`, `t.min(part.len())`): `max_typos = (len/4).clamp(2,6).min((len as u16).saturating_sub(1))` — removes only the degenerate `budget >= needle_len` case, keeps typo tolerance for 4-6 char queries, smaller diff to upstream. Apply to both `file_picker.rs:1091` and `:1178`, and to `fuzzy_match_byte_offsets_for_page` (`file_picker.rs:1132` → `score.rs:175,208`) so highlight offsets use the same budget. If upstream wants short-query typo tolerance preserved as a behavior, expose `FuzzySearchOptions.typo_budget: Option<u16>` and thread a matching `FffCreateOptions` field through fff-c so Floodlight can opt in without forking.

**Expected impact**: Skeptic-corrected: not the "20-100x, 1-5% of index" originally claimed (the haystack is the *full path*, not the filename, so even the minimal-length variant still matches a large fraction of a home index) — realistically ~2-5x fewer `path_matches` for 2-4 char queries. Still the single largest lever because it shrinks the input to every other stage in this report. Note a side effect: `score.rs:668` skips the filename-fallback pass when `path_matches.len() > 15_000`; shrinking matches re-enables that extra pass for exactly the queries being optimized — benchmark net, not just match count.

**Effort/Risk**: S / Medium (the minimal variant is lower risk than the full step function; ranking tests will shift either way since `score.rs:1315`'s test helper hardcodes the current formula).

**How to verify on Mac**:
```
git clone --depth 1 https://github.com/torvalds/linux crates/fff-nvim/big-repo
cargo bench -p fff-nvim --bench fuzzy_search -- search_scalability
cargo run --release -p fff-nvim --bin search_profiler   # compare Matches column, two_char/short_common/partial_word
```
Then Instruments Time Profiler + os_signpost on `IndexedSourceSearch` while typing `d`,`do`,`doc`,`docu` in Floodlight.

**Caveats from review**: Affected range is 2-7 chars, not 1-6 (1-char queries never reach frizbee — `score.rs:628` gates `t.len() >= 2`). Must patch both files and dirs clamps. Impact magnitude was downgraded from "high" to "medium" by the value-lens skeptic because the path haystack (not filename) blunts the win, and because the filename-fallback re-enablement (`score.rs:668`) partially offsets the gain. Confirm neo_frizbee 0.11's exact semantics before tuning the table (external crate, not vendored — see research prompt below).

### 2. U24 — No top-k: full match set materialized, then `select_nth` over all of it

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:1021` (`sort_and_paginate`); construction at `score.rs:709`

**Evidence**
```rust
let items_needed = offset.saturating_add(limit).min(total_matched);
let use_partial_sort = items_needed < total_matched / 2 && total_matched > 100;
if use_partial_sort {
    results.select_nth_unstable_by(items_needed - 1, |a, b| {
        b.1.total.cmp(&a.1.total).then_with(|| b.0.modified.cmp(&a.0.modified))
    });
    results.truncate(items_needed);
}
```
`Score` (types.rs:809-822) is 64 B; `(&FileItem, Score)` is 72 B.

**Why it costs**: Floodlight asks for 12 results; `fuzzy_search_mixed` doubles it to `internal_limit = 24` (`file_picker.rs:1242`). Every match still gets a full `Score` built and stored (72 B), then `select_nth_unstable_by` partitions the *entire* match Vec to find 24 items. fff-c links no mimalloc (unlike `fff-nvim`/`fff-mcp`), so this is a fresh mmap + page-fault storm on libmalloc per keystroke.

**Proposal**: Skeptic-corrected minimal version (not the full parallel-fold sketch, which breaks the loop's stateful `next_filename_match_cursor`/scratch-buffer sequencing): keep computing full `Score` per match (bonuses aren't cheaply separable — every bonus in `score.rs:846-854` needs the full breakdown), but fold into a bounded `BinaryHeap` keyed `(total, modified, Reverse(original_index))` of size `offset+limit`, falling back to full sort when `limit == 0`. This is sequential first (S/M effort); parallelizing requires restructuring the fallback cursor (`score.rs:704, 739-750`) into a per-chunk binary search — treat that as a separate, higher-risk follow-up. Apply the identical pattern to `sort_and_paginate_dirs` (`score.rs:564-598`).

**Expected impact**: Original claim overstates: `into_iter().unzip()` cost is already bounded to `items_needed` (truncated at `score.rs:1033` before the unzip), so drop that from the estimate. Real win: removes the O(n) 72-byte-per-element Vec and its `select_nth` partition traffic. On 500k matches, expect several ms and a large transient-allocation removal, but an O(n) allocation upstream of it (`path_matches`, `fallback_indices`) still remains — so this doesn't reach "sub-millisecond."

**Effort/Risk**: M (sequential heap) — L only if parallelized. Risk: medium (tie-break semantics must be preserved: `modified` secondary key, `limit==0` "return everything" fallback).

**How to verify on Mac**:
```
cargo bench -p fff-nvim --bench fuzzy_search -- result_limits   # sweeps limit 10/50/100/500 on "mod"
/usr/bin/time -l cargo run --release -p fff-nvim --bin search_profiler   # peak RSS
```
Acceptance test: today all four limits cost about the same; after the fix, limit=10 should be markedly cheaper than limit=500.

**Caveats from review**: The parallel `par_chunks().fold()` sketch as originally proposed is broken — it does not compile as written and misindexes the filename-fallback cursor. Land the sequential heap first. Don't expect this to remove the O(n) scoring pass itself (that's U23/U21's job) — this only removes the post-scoring materialization/select overhead.

### 3. U22 — 1-char queries score and materialize the entire index

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:627-632` (files fall-through), `:421-436` (dirs)

**Evidence**
```rust
let fuzzy_parts: &[&str] = match &parsed.fuzzy_query {
    FuzzyQuery::Text(t) if t.len() >= 2 => std::slice::from_ref(t),
    FuzzyQuery::Parts(parts) if !parts.is_empty() => parts.as_slice(),
    _ => { return score_filtered_by_frecency(&working_files, context, arena); }
};
```
`score_filtered_by_frecency` does `s.par_iter().filter_map(...).collect()` over every live `FileItem` (score.rs:954-960); the dir sibling (`score_dirs_by_frecency`, score.rs:542-558) does the same **serially**.

**Why it costs**: Any 1-char query (or multi-token query where every token is <2 chars) falls through to scoring the whole live index with plain frecency, allocating `(&FileItem, Score)` at 72 B/item — ~72 MB transient on a 1M-file index, doubled by rayon's per-thread collect-then-reduce. Floodlight's `SourceSearchEngine.swift:290` calls `files.indexedItems(for: query, limit: 12)` with no minimum length; the only length gate (`>= 3`) is on content search, not this path.

**Proposal**: Two changes. (1) Rust: bound both frecency paths with a top-k fold instead of full materialization (share the mechanism with U24's heap); make `score_dirs_by_frecency` use `par_iter` like the file side already does — cheap, standalone. (2) Floodlight-side, zero Rust changes: skip `files.indexedItems` for queries under 2 UTF-8 bytes in `SourceSearchEngine.swift:290` — the apps/settings immediate page already covers 1-char input, and the frecency-only result list is query-independent noise anyway.

**Expected impact**: Skeptic-corrected magnitude: a real home index (after `.gitignore`/hidden exclusions in `walk/ripgrep.rs:23-24`, `ignore.rs:5-63`) is more like 100k-400k live items than 1M, so this is a 7-29 MB allocation, 14-58 MB peak — not 72-144 MB — and top-k gets ~2-4x, not sub-millisecond (the fold still touches every `FileItem`). The Floodlight-side 2-line gate is the higher-leverage move: it removes the file-side cost for that keystroke immediately, with no Rust rebuild.

**Effort/Risk**: M (Rust top-k + dir par_iter) / S (Floodlight-side gate). Risk: low.

**How to verify on Mac**:
```
cargo bench -p fff-nvim --bench fuzzy_search -- search_scalability/broad_a   # query "a"
/usr/bin/time -l cargo run --release -p fff-nvim --bin search_profiler       # maximum resident set size, single_char case
```
Floodlight: Instruments Allocations, filter to `dev.vmg.fff-swift` queue, type a single char with the home index warm.

**Caveats from review**: `score_filtered_by_frecency` ignores query text entirely — every sub-2-char query returns an identical list, which makes it memoizable to O(1) with a generation counter, a better fix than top-k alone (higher plumbing risk, land after the payload shrink). The Floodlight-side gate is a product behavior change (1-char stops returning files), not a pure win — call it out as such.

### 4. U23 — Post-match scoring loop is single-threaded over every match

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:709` (`match_and_score_in_arena`)

**Evidence**
```rust
let results: Vec<_> = path_matches.into_iter().enumerate()
    .map(|(match_idx, path_match)| { /* 10 bonus computations, string writes, read_to_buf */ })
    .collect();
```
The match stage above it uses `neo_frizbee::match_list_parallel_resolved` with `context.max_threads`.

**Why it costs**: After a parallel SIMD match, every surviving candidate is scored on one thread. With U21 unfixed this can be 10^5-10^6 iterations; adding cores does nothing for this stage.

**Proposal**: Chunk with `par_chunks`, giving each chunk its own scratch buffers and a binary-searched starting cursor into `filename_fallback_matches` (not `fallback_indices` — the skeptic caught this indexing error in the original sketch: the cursor indexes the frizbee-filtered subset, so the correct seed is `filename_fallback_matches.partition_point(|m| (fallback_indices[m.index as usize] as usize) < base_idx)`). Prefer `par_iter().enumerate().map_init(|| (dir_buf, fname_buf, path_buf), ...)` over `flat_map_iter` — it's an indexed parallel iterator so rayon collects into one output buffer instead of a linked-list-of-Vecs reduce. Apply the same treatment to the directory scoring loop (`score.rs:396`), which has the identical serial shape and is also on the mixed-search path.

**Expected impact**: Downgraded from the original "4-8x, dominates short-query latency": in Floodlight's actual call (`current_file = nil`, `FFFIndex.swift:126`), the expensive branches (`write_dir_str`, distance penalty, `read_to_buf`) are mostly dead — the residual work is bandwidth-bound random `FileItem` access plus an occasional filename copy. Realistic: ~2-3x on the stage, memory-bandwidth-bound, not near-linear with core count.

**Effort/Risk**: M / Medium — sequence this *after* U21/U24 land, since a mis-parallelized cursor silently corrupts ranking rather than crashing.

**How to verify on Mac**:
```
cargo bench -p fff-nvim --bench fuzzy_search -- thread_scaling   # sweeps max_threads 1/2/4/8 on "controller"
RUST_LOG=fff_search=debug cargo run --release -p fff-nvim --bin search_profiler
```
Instruments CPU Counters: confirm `match_and_score_in_arena` samples spread across threads, not piled on one.

**Caveats from review**: `path_buf` is 1 KB on macOS (`libc::PATH_MAX`), not 4 KB (that's the Windows branch) — corrects the original memory-footprint claim. `par_chunks` uses rayon's global pool, ignoring `context.max_threads` — a behavior change worth noting even though Floodlight passes 0. Land this after candidate-count reduction; if U21 lands first this stage may already be sub-millisecond and the change becomes pure risk for little gain.

### 5. U26 — Directory search allocates `Vec<&DirItem>` over every live dir, serially

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:408-418`

**Evidence**
```rust
let working_dirs: Vec<&DirItem> = if parsed_query.constraints.is_empty() {
    dirs.iter().filter(|d| !d.is_deleted()).collect()
} else { ... };
```
Compare files, which use `FileItems::All(files)` (score.rs:613-624) and skip tombstones inside the resolver instead.

**Why it costs**: Every mixed query walks the entire dir table serially before matching starts (~0.2-0.6 ms on a 100k-dir index — corrected down from the original 1-3 ms estimate, since `DirItem` is ~40 B and the dir table is roughly 10x smaller than the file table). It also forces the matcher onto `&[&DirItem]` (extra pointer indirection) instead of a contiguous slice.

**Proposal**: Add a `DirItems<'a>` enum mirroring `FileItems`, with an `All(&'a [DirItem])` arm, and make `resolve_dir_chunks` skip tombstones (`if dir.is_deleted() { return None; }`) the way `resolve_file_chunks` already does. Bigger win in the same finding: make `score_dirs_by_frecency` (score.rs:542-558) use `par_iter` — it's currently serial while the file-side frecency path already parallelizes (score.rs:955), and this is the path every 1-2 char query hits (see U22).

**Expected impact**: Modest for the fuzzy path alone (~0.2-0.6 ms). The `par_iter` change on the frecency path is the higher-value, lower-risk piece — land it first, standalone.

**Effort/Risk**: M (full `DirItems` enum) / S (par_iter alone). Risk: low, but the `All` arm must filter tombstones itself (mirroring `score_filtered_by_frecency`) or ghost dirs leak into frecency-only results.

**How to verify on Mac**: No existing bench covers dirs — add a `dirs` group to `crates/fff-nvim/benches/fuzzy_search_bench.rs` calling `fuzzy_search_directories` with limit 24 on `"sr"`,`"src"`,`"driv"`; `cargo bench -p fff-nvim --bench fuzzy_search -- dirs`. Point at a home-shaped tree via `ln -s "$HOME" crates/fff-nvim/big-repo`.

**Caveats from review**: Impact was downgraded from 1-3 ms to ~0.2-0.6 ms — the collected `Vec<&DirItem>` is an ascending, prefetch-friendly pointer array, not the scattered-access problem the finding implied; the real random access is arena chunk resolution, unaffected by this change.

### 6. U27 — Directory scoring copies the full path into a buffer just to learn a length

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:489-497`

**Evidence**
```rust
dir.write_dir_name(dir_arena, &mut dirname_buf);
let dirname_len = dirname_buf.len();
let is_exact_dirname = is_dirname_match && main_needle_len as usize == dirname_len && ...;
```
`write_dir_name` (types.rs:188-199) reads the *entire* path via `read_to_buf` before slicing the tail.

**Why it costs**: Called unconditionally per dir match, but the length is already derivable from `path.byte_len - last_segment_offset`. With U21 unfixed this runs 10^4-10^5 times per keystroke.

**Proposal**:
```rust
let dirname_len = (dir.path.byte_len as usize).saturating_sub(dir.last_segment_offset() as usize);
let is_exact_dirname = is_dirname_match && main_needle_len as usize == dirname_len && {
    dir.write_dir_name(dir_arena, &mut dirname_buf);
    main_needle.eq_ignore_ascii_case(dirname_buf.as_bytes())
};
```
`byte_len` and `last_segment_offset()` are both already public. Skeptic finding (important correctness note): dir paths are stored **with** their trailing separator, so `write_dir_name` yields e.g. `"components/"` — meaning `main_needle_len == dirname_len` can basically never hold for an ordinary query, so this short-circuit eliminates ~100% of `write_dir_name` calls in practice, not "a handful."

**Expected impact**: Corrected from "4 KB buffer" (that's the Windows-only branch; macOS is `libc::PATH_MAX` = 1KB) — the real cost is a chunked ~16-byte-per-chunk gather plus a `String::push_str` per match, into an already-hoisted, reused buffer (no per-match heap allocation unless a dirname exceeds 32 bytes). Realistic saving: ~0.5-2 ms on a 20-40k-dir home index, ~3-6 ms at 100k dirs.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Same `dirs` bench group as U26; Instruments Time Profiler — `DirItem::write_dir_name` / `ChunkedString::read_to_buf` frames should drop out of the hot path.

**Caveats from review**: Floodlight passes `current_file = nil`, so `write_dir_name` is the *only* arena read in this loop for Floodlight's calls — makes this a clean, unusually safe win. The full "hot/cold split" (read only tail chunks) needs a new `ChunkedString::write_segment_from` accessor since `write_filename_to`'s existing fast path doesn't apply to dirs (`filename_offset == byte_len` for dirs).

### 7. U25 — `fuzzy_search_mixed` computes highlight offsets and discards them

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1131-1132`

**Evidence**: `fuzzy_search` unconditionally calls `fuzzy_match_byte_offsets_for_page`; `fuzzy_search_mixed` (`file_picker.rs:1295-1310`) and `MixedSearchResult` (`types.rs:891-898`) never touch the result. `FffMixedItem`/`FffFileItem` (fff-c ffi_types.rs) have no match-range field either — the whole C ABI has no channel for fuzzy highlight offsets.

**Why it costs**: Per page item this allocates a `String` for the full relative path, builds a fresh `neo_frizbee::Matcher` per query part, and collects a per-CHARACTER `Vec` in `char_indices_to_byte_offsets` — all pure waste since it can never cross the FFI on this path or on `fff_search`/`fff_glob`.

**Proposal**: Split `fuzzy_search` into a private `fuzzy_search_inner(.., compute_offsets: bool)` plus an additive `fuzzy_search_no_highlights`; have `fuzzy_search_mixed` and `glob` call the latter, and have fff-c's `fff_search` call it too. No `FuzzySearchOptions` field, no `fff.h`/ABI change needed — offsets are dead for every fff-c consumer today. Separately, make `char_indices_to_byte_offsets` walk the string once instead of collecting a per-character Vec (benefits the consumers, e.g. grep/nvim, that do use offsets).

**Expected impact**: Corrected down from "50-200 µs" to "tens of µs per keystroke, ~1-3% of engine time" — real, strictly subtractive, but small against a 15-20 ms debounce.

**Effort/Risk**: S / Low.

**How to verify on Mac**: `cargo run --release -p fff-nvim --bin search_profiler` (uses `fuzzy_search` limit 100) — set `compute_match_offsets`/use the new no-highlights entry point and diff the avg µs column.

**Caveats from review**: Don't add a `FuzzySearchOptions` field or a C ABI bool as originally proposed — mis-scoped and unnecessary churn; the additive-function approach touches nothing at the FFI boundary.

### 8. U30 — `combo_match_boost` recomputes loop-invariant work per match

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:796-806`, `:725-727`

**Evidence**
```rust
let last_same_query_match = context.last_same_query_match.as_ref().filter(|m| {
    let file_path_str = m.file_path.to_string_lossy();   // loop-invariant
    ...
    file.write_relative_path_from_arena(arena, &mut dir_buf);
    file_path_str.ends_with(dir_buf.as_str())
});
```
and `if context.current_file.is_some() || context.last_same_query_match.is_some() { file.write_dir_str(arena, &mut dir_buf); }` — dead when `current_file` is nil (Floodlight's case) but `last_same_query_match` is set.

**Why it costs**: `to_string_lossy()` re-validates UTF-8 once per match instead of once per query; `write_relative_path_from_arena` builds the full path per candidate; line 725's write is pure dead work whenever only `last_same_query_match` is set. This block only activates when `min_combo_count` (Floodlight: 3) is met for the *exact* raw query string — a real but narrower trigger than "every previously-selected query."

**Proposal**: Hoist the `to_string_lossy()` once above the loop; change line 725 to `if context.current_file.is_some() { ... }` only; add an O(1) last-byte reject (needs a small new `ChunkedString` accessor) before doing any string materialization, falling back to the existing `ends_with` check only for candidates that pass length + last-byte.

**Expected impact**: Downgraded from "several ms on repeat queries" — because the tracked path is absolute and the candidate path is relative, the existing length-prefilter is nearly a no-op, so the real win is the last-byte reject plus the loop-invariant hoist. Realistic: sub-ms to ~1-2 ms on the final keystroke of a repeated query. The `if context.current_file.is_some()` fix alone (line 725) is free and provably safe — land it separately first.

**Effort/Risk**: S / Low.

**How to verify on Mac**: Existing benches pass `query_tracker: None` (coverage gap — see U38); add a bench variant seeding a `QueryTracker`, then `cargo bench -p fff-nvim --bench fuzzy_search -- combo`. In Floodlight: select a result for "doc", retype "doc", compare `IndexedSourceSearch` signposts against a never-selected query.

**Caveats from review**: The proposed `as_deref()` snippet as originally written doesn't compile (borrows a temporary); bind the `Cow` first. A nonexistent `last_path_byte` accessor needs to be added — it's trivial but is new code, not an existing call.

### 9. U35 — Watcher batch holds the picker write-lock across an uncapped file read

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1686` (inside `handle_file_modify`), lock taken at `watcher/background_watcher.rs:543`

**Evidence**
```rust
if in_indexable && let Ok(content) = std::fs::read(path) {   // no size cap
    overlay.write().modify_file(pos, &content);
}
```
The index-build path *does* cap this: `let want = (file.size as usize).min(MAX_INDEXABLE_FILE_SIZE);` (2 MB).

**Why it costs**: `parking_lot::RwLock` blocks new readers once a writer is queued. Every search takes `inst.picker.read()` for the query's duration; the watcher takes `.write()` for a whole batch. The narrower, verified trigger: `in_indexable` requires the file to have been ≤2 MB and non-binary *at last scan time* — so the unbounded read fires specifically for a file that has *grown* past 2 MB since indexing (a log, a growing export/download), not any large modified file.

**Proposal**: Cap the read to match the build path (`MAX_INDEXABLE_FILE_SIZE`), and re-check `!file.is_binary()` after the 16 KB re-classification before reading (currently absent — a file just reclassified as binary is still read whole). Splitting the batch into a lock-free "prepare" phase (stat + classify + capped read) and a short "apply" phase (picker write lock) is the fuller fix but is riskier — `scan.rs` writers can replace the picker between phases, invalidating prepared indices; if pursued, keep all picker lookups/mutations inside one guard and move only the syscalls out.

**Expected impact**: Downgraded from "high, recurring p99 spike" — the walker's own git/hidden-dir exclusions (`walk/ripgrep.rs:23-24`, `ignore.rs:5-63`) already skip Library/Caches, node_modules, DerivedData, browser caches, etc., so realistic batches are small text-file diffs. This is a tail-latency safety fix (bounds an unbounded worst case), not a p50/p95 win.

**Effort/Risk**: S (cap only) / Low. The uncapped-read cap alone is safe and independent of the lock-hold restructuring.

**How to verify on Mac**: Reproduce with a warm index: `cargo run --release -p fff-nvim --bin search_profiler` in one terminal, `dd if=/dev/urandom of=$HOME/big.bin bs=1m count=500` in another (note: to actually trigger the *uncapped-read* bug, grow an already-indexed small file past 2 MB rather than creating a new large file) — watch avg-µs spike, then confirm it disappears after the cap.

**Caveats from review**: Truncating the read to 2 MB is a deliberate recall trade for grep matches beyond the truncation point — consistent with what the base index already does, but state it explicitly rather than as a pure win.

### 10. U38 — No benchmark covers Floodlight's actual query shape

**Where**: `fff-swift/Vendor/fff/crates/fff-nvim/benches/fuzzy_search_bench.rs:150`

**Evidence**: Every bench/bin calls `fuzzy_search`, never `fuzzy_search_mixed`; `query_tracker: None` everywhere; hardcoded `./big-repo` (linux kernel clone, ~80k files, deep uniform paths) instead of a home-directory shape.

**Why it costs**: None of the findings above can be validated against the workload they target without this. (Skeptic correction: the "limit always 100" and "shortest query 3 chars" sub-claims in the original write-up are false — limit 10 and query "a" are both already benched — the real gaps are `fuzzy_search_mixed` and a live `query_tracker`.)

**Proposal**: Skeptic-preferred target: add `testMixedSearchLatencyBudget` to `Tests/FloodlightEngineTests/SearchPerformanceTests.swift`, next to the existing `testExpandedFFFIndexScanBenchmark` — a synthetic wide-and-shallow tree, queries `"d"`/`"do"`/`"doc"`, limit 12, through `FFFIndex.search`, emitting a `FLOODLIGHT_BENCH` line that CI's `make test-performance` already harvests. This exercises the shipped XCFramework plus the FFI/DispatchQueue serialization that a Rust-only criterion bench can't see, and is S effort (most of the harness already exists). If a Rust-side bench is still wanted, put it in `fff-core/benches/` (no `mlua`/LuaJIT dependency, unlike `fff-nvim`), seeded with a `QueryTracker` and `MixedSearchConfig`.

**Expected impact**: Enabling, not a latency win by itself — but it's what makes U21-U30 measurable and regression-guarded (note: no fff workspace CI runs any cargo bench today, so a Rust bench alone guards nothing automatically; the Swift-side test does run in CI via `make test-performance`).

**Effort/Risk**: S (Swift-side) / Low.

**How to verify on Mac**: `make test-performance` (Floodlight) after adding the test; `cargo bench -p fff-core --bench <new>` if the Rust-side variant is also added.

**Caveats from review**: Original proposal put the bench in `fff-nvim`, which pulls in LuaJIT for no reason relevant to this function — prefer `fff-core/benches/` or the Floodlight Swift test.

### 11. U31 — `FileItem` is ~96 bytes but the matcher reads ~33 of them

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/types.rs:248`

**Evidence**
```rust
pub struct FileItem {
    pub size: u64, pub modified: u64,
    pub access_frecency_score: i16, pub modification_frecency_score: i16,
    pub git_status: Option<git2::Status>,
    pub(crate) path: ChunkedString,        // ~32 B
    pub(crate) parent_dir_index: u32,
    flags: AtomicU8,
    content: OnceLock<memmap2::Mmap>,      // ~24 B, grep-only
}
```

**Why it costs**: The matching stage (`resolve_file_chunks`) reads only `flags` and `path`. The other ~63 bytes stream into cache for nothing on every full-index scan.

**Proposal**: Move `content: OnceLock<Mmap>` out of `FileItem` into a side table on `FileSync` keyed by index, allocated only when `enable_mmap_cache` is on. This shrinks `FileItem` to ~72 B (corrected from the original "64 B" claim — `git_status` can't be removed, it's exported per-result through the FFI at `ffi_types.rs:156,382,677`). A full SoA hot/cold split (separate 28 B `PathEntry` array) is a larger, riskier follow-up.

**Expected impact**: Reframed as a memory-footprint win (~24 MB off resident set per 1M files), not a latency win — end-to-end per-keystroke effect is likely below noise (~0.1 ms) against a 15-35 ms budget; only a match-stage microbenchmark would show it.

**Effort/Risk**: L / Medium — the `OnceLock<Mmap>` is currently owned inside an `Arc`'d snapshot handed to callers under a documented "hold the picker read lock" safety contract (`types.rs:687-698`); a side table must reproduce that ownership/drop discipline exactly or risks a use-after-unmap on the grep path.

**How to verify on Mac**: `cargo test -p fff-search item_size -- --nocapture` (confirm actual size on the target toolchain); Instruments CPU Counters template on `search_profiler`, comparing L2/LLC miss counts before/after.

**Caveats from review**: Treat this as a footprint/hygiene item for a menu-bar app, not a latency lever — don't lead with it in a perf pitch to the maintainer.

### 12. U34 — Filename bonus scores against the wrong needle for multi-part queries

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:664`

**Evidence**
```rust
let main_needle = fuzzy_parts[0].as_bytes(); // safe
```
but matching used `valid_parts[0]` (parts filtered to `len() >= 2`, `score.rs:53-57`). The dir path does it correctly: `let main_needle = valid_parts[0].as_bytes();` (score.rs:462).

**Why it costs**: For a query like `"a doc"`, matching runs against `"doc"` but every downstream use of `main_needle` (filename-bonus window, exact-filename comparison, fallback re-match needle) uses `"a"` — a correctness bug, not a perf one. Confirmed as an oversight by the dir path already doing it right.

**Proposal**: Compute `valid_parts` once, share it with `match_fuzzy_parts`, use `valid_parts[0]` everywhere `main_needle` is derived, including at line 689. Also fix `has_uppercase` (score.rs:636) and `query_contains_path_separator` (score.rs:641), which read unfiltered `fuzzy_parts` the same way. Add the `valid_parts.is_empty()` → frecency-fallback arm (matches the single-part short-query behavior) instead of returning `vec![]`.

**Expected impact**: Ranking correctness fix, not a latency win — skeptic corrected the original perf claim (it's actually a small perf *loss*: the bug currently narrows the fallback re-match window, so fixing it slightly widens it).

**Effort/Risk**: S / Low.

**How to verify on Mac**: Unit test in `score.rs`'s existing `mod tests`: assert `"a doc"` and `"doc"` produce the same top result on a fixture; assert `"a b"` returns frecency-ranked results, not empty. `cargo test -p fff-search score::tests`.

**Caveats from review**: Reclassify as correctness/upstream-hygiene, not a perf item — no measurable latency change. Consider landing it upstream directly rather than adding a fifth local delta to the vendored fork for a query pattern Floodlight users rarely trigger.

### 13. U28 — Fallback filename re-match thread-count formula is transposed (plausible — split vote)

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:693`

**Evidence**: `context.max_threads.div_ceil(2048)` — with `max_threads` a core count (8-16 on Apple Silicon), this always evaluates to 1, so the "parallel" branch is dead.

**Why it costs**: Looks like a transposed operand (should derive thread count from *work size*, capped by available threads), but the value-lens skeptic refuted the perf claim: the fallback stage is capped at ≤15,000 matches (`score.rs:668-670`) and is preceded/followed by serial work (Cow allocation, sort), so even a correct fix caps at ~2x on a stage that's already a small fraction of total time.

**Proposal**: `fallback_filenames.len().div_ceil(2048).min(context.max_threads).max(1)` — correctness-of-intent cleanup, safe to land, but present it as upstream hygiene rather than a latency win.

**Expected impact**: Low — accuracy-lens confirmed the bug is real; value-lens found it's inside a bounded, already-cheap stage. Status: plausible (split verdict).

**Effort/Risk**: S / Low.

**How to verify on Mac**: `cargo bench -p fff-nvim --bench fuzzy_search -- thread_scaling`; add a temporary `tracing::debug!` to confirm the branch actually changes thread count post-fix.

**Caveats from review**: Land as a correctness cleanup for upstream; don't budget latency savings against it.

### 14. U32 — No incremental narrowing across keystrokes (plausible — speculative, high risk)

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:142`

**Evidence**: The multi-part cascade already narrows candidates within one query (`score.rs:97-135`); nothing carries a survivor set across separate keystrokes.

**Why it costs (if it worked)**: Floodlight's flow is a prefix chain (`d`→`do`→`doc`). If candidate sets were provably nested by prefix, later keystrokes could scan a shrinking survivor set instead of the whole index.

**Proposal**: A `QueryCache` on `FilePicker` keyed by query/`max_typos`/index-epoch, reusing the previous survivor set when the new query extends the cached one and the typo budget is monotone in the safe direction.

**Why this is risky/speculative**: The accuracy-lens skeptic found the guard direction in the original proposal was backwards (`max_typos >= c.max_typos` admits unsafe reuse; must be `<=`), and the value-lens skeptic refuted the impact model entirely: with `max_typos` floored at 2 (pre-U21), a 2-4 char query matches nearly the whole index, so there's *nothing* to narrow for exactly the keystrokes this targets — narrowing only starts around 7-9 characters, where costs are already lowest. Also unverifiable from this checkout: the superset property depends on `neo_frizbee` 0.11's internal semantics (external crate, not vendored).

**Expected impact**: Speculative/low pending research. Do not implement before landing U21 and confirming the monotonicity property empirically.

**Effort/Risk**: L / High. Confidence 0.6 even before the skeptic corrections.

**How to verify on Mac**: A differential/proptest in `crates/fff-core/tests/`: for random path corpora and query chains, assert cached-incremental result == from-scratch result, across many corpora, before ever shipping this.

**Caveats from review**: Prefer the simpler, already-proposed U21 fix first; only revisit this if U21 alone doesn't hit target latency and the neo_frizbee monotonicity property is confirmed by direct source reading.

### 15. U36 — Mixed search runs dir and file search sequentially with symmetric 2x limit (plausible — mostly refuted)

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1242`

**Evidence**: `let internal_limit = page_offset.saturating_add(page_limit).saturating_mul(2);` applied independently to both dir and file sub-searches, run one after the other.

**Why the parallelism half is refuted**: `neo_frizbee` 0.11.0 has zero dependencies (not rayon-based) — it manages its own threads via an explicit `max_threads` argument. Wrapping the two searches in `rayon::join` would not overlap the actual hot matching phase (which already uses most cores per side) and risks 2x thread oversubscription.

**Proposal**: Drop the `rayon::join` idea. Keep only the internal-limit correction: since both sides are sorted descending by the same score before merging, `offset + limit` per side (not `(offset+limit)*2`) is provably sufficient for a correct merge. This is nearly free (removes an O(n log n) sort of ~48 items in favor of ~24, and a modest per-side scoring-loop trim) but was found by the value-lens skeptic to save only nanoseconds — the dominant per-side cost (`select_nth_unstable_by`) is `O(total_matched)`, independent of `items_needed`.

**Expected impact**: Low. The real win hiding in this area is the already-covered dir-side `par_iter` fix (U26).

**Effort/Risk**: S / Low.

**How to verify on Mac**: Add a `mixed` bench group calling `fuzzy_search_mixed` at limit 12; diff before/after the internal_limit change (expect near-zero difference, confirming the refutation).

**Caveats from review**: Present as a tidy-up, not a parallelism win. Any `rayon::join` framing should be dropped from the pitch.

### 16. U37 — Overflow-then-base result vec built via `extend` (plausible — mostly refuted)

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:155`

**Evidence**: `results.extend(match_and_score_in_arena(&files[..base_count], ...))` after building the (small, ≤1024-item) overflow-region Vec first — grows the buffer to hold the full base match set.

**Why it's mostly refuted**: The branch only fires when the watcher has appended files since the last scan (bounded, throttled), not on every query. In the regime where match counts are large enough for the copy to matter (10^5+), the already-dominant cost is the serial per-element scoring closure (U23), not this one extra copy — the value-lens skeptic estimated the copy at a few percent of an already-multi-ms query.

**Proposal**: If pursued, fold into the U24 top-k rewrite (a bounded heap sidesteps the extend/copy question entirely) rather than treating this as a standalone fix. A naive `Vec::with_capacity(estimate)` is not viable — match count is unknown pre-match, and sizing to `files.len()` worst-case would regress selective queries.

**Expected impact**: Low, and subsumed by U24 once that lands.

**Effort/Risk**: S / Low — but low value on its own.

**How to verify on Mac**: `/usr/bin/time -l cargo run --release -p fff-nvim --bin search_profiler`, comparing maximum resident set size before/after — expect the change to be in the noise unless combined with U24.

**Caveats from review**: Don't implement standalone; fold into U24's top-k work.

### Rejected ideas

- **U29** — "Fuzzy search doesn't install `SEARCH_THREAD_POOL`, runs on global rayon pool across E-cores": refuted — `neo_frizbee` has zero dependencies and isn't rayon-based; it parallelizes via its own `max_threads` argument, so wrapping fuzzy search in the pool's `.install()` would be a no-op for the actual matching work. The one real rayon call on this path (`score_filtered_by_frecency`, single-char queries) wants *more* threads, not P-core pinning.
- **U33** — "Fuzzy search has no abort signal, so a stale keystroke blocks the next one": refuted — Floodlight's serial-queue design already caps head-of-line delay at exactly one in-flight query (generation check happens at dequeue time, not enqueue time), which is the property the proposal claimed to add. The proposed "cheap interim" (second DispatchQueue for content search) is also unsafe as written — it would race on mutable `handle`/`rootURL` state.

## Upstream: index scan, cold start, and persistence

| Rank | ID | Opportunity | Layer | Impact | Effort | Risk | Status | Upstreamable |
|---|---|---|---|---|---|---|---|---|
| 1 | U47 | `IGNORED_DIRS` misses `~/Library/Developer/Xcode` (DerivedData etc.) | fff-core | High (dev Macs) / Med (general) | S | Low | confirmed | Yes |
| 2 | U40 | Binary sniff reads whole file even when extension already says "binary" | fff-core | Medium | S | Low | confirmed | Yes |
| 3 | U45 | Watcher admits dotfiles the walker excludes → overflow → forced rescans | fff-core | Medium | S | Low | confirmed | Yes |
| 4 | U54 | `return` where `continue` was meant — silently drops 255 files from bigram index | fff-core | Low (preventive) | S | Low | confirmed | Yes |
| 5 | U56 | `FileItem` carries a dead `OnceLock<Mmap>` on 99% of files + `SmallVec` heap spill | fff-core | Medium | S (pointer fix) / L (full redesign) | Medium | confirmed | Yes |
| 6 | U55 | Scan-progress poll takes the picker lock; `is_warmup_complete` is dropped by Floodlight | fff-c + Floodlight | Low (UX correctness) | S | Low | plausible | Partial |
| 7 | U41 | Walk opens/commits one LMDB read txn per file for frecency | fff-core | Medium (cold start only) | S (short-circuit) / M (snapshot) | Low | confirmed | Yes |
| 8 | U39 | `FFFFileSource.start` blocks all publish stages on the full `$HOME` walk | Floodlight | Low–Medium | S (bound the wait) / M (decouple) | Low–Medium | plausible | No |
| 9 | U42 | No on-disk index snapshot; full walk repeats every launch | fff-core | High (contested) | L | Medium | confirmed | Yes |
| 10 | U43 | Index commits all-at-once; nothing searchable until the walk finishes | fff-core | Contested (per-launch only) | L | Medium–High | confirmed* | Yes |
| 11 | U44 | Post-scan bigram build has no cancellation and no I/O budget | fff-core | Medium | S (cancel token) / M (budget) | Low–Medium | plausible | Yes |
| 12 | U48 | No FFI knob for extra ignore patterns | fff-c | Low (redundant with #1) | M | Low | plausible | Yes |
| 13 | U46 | `commit_new_sync` drops the old index under the write lock | fff-core | Low | S | Low | plausible | Yes |
| 14 | U50 | Default walker uses `pathdiff::diff_paths` instead of `strip_prefix` | fff-core | Low | S | Low | plausible | Yes |
| 15 | U53 | Initial scan capped at half the cores, same as a rescan | fff-core | Low (contested) | M | Medium | plausible | Yes |
| 16 | U52 | `hint_allocator_collect` is a no-op on Floodlight's system allocator | fff-core | Low (speculative) | S | Low | plausible | Yes |

\* U43's accuracy is solid but the value review split (see caveats) — the win is real only for the single search-panel presentation right after process launch, not steady state.

---

### U47 — `IGNORED_DIRS` misses the `~/Library` subtrees that dominate a macOS dev machine

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/ignore.rs:25-52`

**Evidence**
```rust
#[cfg(target_os = "macos")]
"Library/Application Support",
#[cfg(target_os = "macos")]
"Library/Caches",
#[cfg(target_os = "macos")]
"Library/Developer/CoreSimulator",
```

**Why it costs** `hidden(!is_git_repo)` only strips leading-dot components; it never consults macOS `UF_HIDDEN`, so everything under `~/Library` not on this list gets walked, indexed, watched, and (with Floodlight's default `includeBinaryFiles=true`) content-sniffed. `Library/Developer/Xcode/DerivedData`, `iOS DeviceSupport`, and `Archives` are absent — routinely 100k+ churning files on a developer Mac — while the much smaller `Library/Developer/CoreSimulator` already has an entry.

**Proposal** Replace the single `"Library/Developer/CoreSimulator"` entry with `"Library/Developer"` — it subsumes DerivedData, iOS DeviceSupport, Archives, UserData, and CoreSimulator in one line. Separately add the photo/music bundle patterns, which live under `~/Pictures`/`~/Music`, not `~/Library`: `"*.photoslibrary"`, `"*.musiclibrary"`, `"*.tvlibrary"` (the leading-`*` strip is already implemented at `ignore.rs:87`). Also safe to add: `"Library/Mail"`, `"Library/Safari"`, `"Library/Autosave Information"`, `"Library/Application Scripts"`, `"Library/Suggestions"`, `"Library/Accounts"`.

**Do NOT add** `"Library/CloudStorage"` or `"Library/Mobile Documents"`. Floodlight sets `options.follow_symlinks = false` (`FFFIndex.swift:88`), and with iCloud Desktop & Documents enabled, `~/Desktop` and `~/Documents` are symlinks *into* `Library/Mobile Documents/com~apple~CloudDocs/`; Dropbox/OneDrive/Google Drive live directly under `Library/CloudStorage`. Excluding either directory deletes the user's most-searched files from a Spotlight replacement. Drop the "make all of `~/Library` opt-out" fallback for the same reason.

**Expected impact** On an Xcode-heavy home directory this is plausibly the single largest reduction in indexed file count, cutting walk time, RSS, bigram-build I/O, and watcher event rate together. On a non-developer Mac the photo/music bundle patterns are the larger win. Conditional on machine class — not universal.

**Effort/Risk** S / Low. One-line change to a compile-time const array already forked in `fff-swift/Vendor/fff`; requires an XCFramework rebuild.

**How to verify on Mac** `fd --hidden --no-ignore --type f . ~/Library/Developer/Xcode ~/Library/CloudStorage ~/Library/Mobile\ Documents 2>/dev/null | wc -l` before, then diff the SCAN log's file count and `chunked_store=…MB` after (`RUST_LOG=fff_search=info cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- "$HOME" --seconds 0`).

**Caveats from review** Both skeptics agreed the walker-side gap is real and unfixed upstream. The accuracy reviewer flagged that `is_non_code_directory` is a linear substring scan per watcher event, so a long entry list has its own cost — favor one `"Library/Developer"` entry over four. The value reviewer's correction (CloudStorage/Mobile Documents must stay indexed) is load-bearing and has been folded into the proposal above.

---

### U40 — Post-scan binary sniff reads every non-indexable file end-to-end, serially

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/types.rs:561-589` (reader), `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:905-931` (caller)

**Evidence**
```rust
pub(crate) fn detect_binary_per_byte(&self, path: &Path, chunk: &mut [u8]) {
    ...
    loop {
        match file.read(chunk) {
            Ok(0) => break,
            Ok(n) => { if detect_binary_content(&chunk[..n]) { self.set_binary(true); } }
            ...
        }
    }
}
```

**Why it costs** `sniff_binary_for_non_indexable` has no `if file.is_binary() { continue }` guard, so every extension-flagged binary (images, dylibs, archives) — already known to be binary — gets opened and read cover-to-cover a second time, purely to reconfirm a flag it already has. `detect_binary_per_byte` also never breaks after the first NUL or after one chunk, contrary to the doc comment on the 16 KB chunk size it's handed. This runs the instant `scanning` clears (`scan.rs:228`), i.e. exactly when Floodlight issues its first `fff_live_grep`.

**Proposal** Two changes, both safe: (1) `if file.is_binary() { continue }` at the top of the per-file loop in `sniff_binary_for_non_indexable` — zero semantics change, since `set_binary` can only ever add the flag. (2) `break` out of `detect_binary_per_byte`'s loop as soon as `detect_binary_content` returns true. **Reject** truncating the read to 16 KB before that — it contradicts the documented "first 2 MB will always contain an invalid text sequence" design (`bigram_filter.rs:872-877`) and would reclassify some large binaries as text. **Reject** parallelizing with `par_chunks` — after the skip the residual set is small and not worth the added complexity.

**Expected impact** Removes essentially all read I/O for extension-known binaries (images, dylibs, archives — the bulk of the non-indexable partition on a home directory) in the first seconds after the index goes live.

**Effort/Risk** S / Low. Pure Rust, no ABI change.

**How to verify on Mac** `cd fff-swift/Vendor/fff && FFF_BENCH_REPO="$HOME" cargo bench -p fff-nvim --bench scan -- post_scan/post_scan_only`; Instruments → File Activity on `rescan_probe --features rescan-stats -- "$HOME" --seconds 30`.

**Caveats from review** Both skeptics confirmed the mechanism; both independently converged on the same narrowed fix (skip + single-NUL-break, no truncation, no parallelization). Also found a sibling bug worth fixing alongside: `add_new_file` (`file_picker.rs:1719-1725`) calls `detect_binary_per_byte` on every new watcher-created file with no `is_binary()` guard and no size cap.

---

### U45 — Watcher admits dotfiles the walker excludes, driving overflow-triggered rescans

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/watcher/background_watcher.rs:870-889`

**Evidence**
```rust
None => crate::ignore::is_non_code_directory(
    path.strip_prefix(self.base_path).unwrap_or(path),
),
```

**Why it costs** The initial walk skips dotfiles on a non-git root (`walk_builder.hidden(!is_git_repo)`), but the watcher's `IgnoreFilter` has no equivalent rule — on `$HOME` (no git repo) it falls back to a plain substring match with no hidden-component check. Writes under `~/.cache`, `~/.local/share`, `~/.config`, `~/.docker`, `~/.ollama`, `~/.vscode` therefore consume the 1024-slot overflow buffer; once it fills, a full rescan is requested, admitted every 30 s by the throttle.

**Proposal** In `IgnoreFilter::is_ignored`, when both `rules` and `repo` are `None`, also reject any base-relative path with a component starting with `.` — mirror `hidden(!is_git_repo)` exactly by threading `picker.has_git_repo()` into `IgnoreFilter::new` instead of inferring it. Apply the same predicate in `index_new_directory` (`background_watcher.rs:749-760`), which has the identical gap for newly created dot-directories.

**Expected impact** Removes result-hygiene pollution (dotfile paths appearing between rescans) and cuts burst-driven overflow rescans on active developer machines; reduces picker-write-lock contention against per-keystroke search during those rescans.

**Effort/Risk** S / Low. One added predicate, reused at two call sites already in the vendored fork.

**How to verify on Mac** `cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- "$HOME" --seconds 300`, printing admitted/throttled rescans per reason; expect OverflowCapacity/IndexUpdateRejected counts near zero after the fix. Force churn with a concurrent `yarn install` or Xcode build.

**Caveats from review** Both skeptics confirmed the mechanism but downgraded severity: most macOS churn directories (Library/Caches, Application Support, Containers, etc.) are already excluded, so the residual leak is a narrower set of dotdirs; sustaining the loop needs >1024 *distinct new* paths per 30 s window, not any write. Reject the finding's secondary proposal to key the 5-minute large-index rescan throttle off "non-git root" — that would impose a 5-minute staleness floor on every small non-git scope, a real regression. Also add the `should_index_path` predicate is a separate binary-extension filter, not a duplicate of this fix — don't touch it.

---

### U54 — `build_bigram_index` uses `return` where it means `continue`

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:856-858`

**Evidence**
```rust
for (offset, file) in chunk.iter().enumerate() {
    let file_idx = base_idx + offset;
    if file.is_binary() || file.size == 0 {
        return;
    }
```

**Why it costs** The `return` exits the whole 256-file (`BIGRAM_CHUNK_FILES`) per-chunk closure, not just the current iteration, so one binary or zero-length file silently drops the rest of its chunk from the content index — a silent live-grep recall regression with no error. Currently masked because `files[..indexable_count]` is pre-partitioned to exclude binaries/empty files before this runs — but `build_bigram_index` runs off the picker lock by design while a watcher event can mutate `FileItem.size`/binary flags concurrently, so the race is live today, not purely latent for future changes.

**Proposal** Change `return` to `continue`. One character; the sibling function three lines away (`sniff_binary_for_non_indexable`) already uses `continue` for the identical guard shape, confirming intent.

**Expected impact** Removes a silent-recall-loss trap now (via the documented off-lock watcher race) and forecloses it for any future change to the indexable slice (frecency reordering, budgeted builds, partial commits — several proposed elsewhere in this audit).

**Effort/Risk** S / Low.

**How to verify on Mac** `cd fff-swift/Vendor/fff && cargo test -p fff-search bigram`. Add a unit test with a zero-size file at position 0 in a chunk; assert a later file in the same chunk is still grep-matched — fails before the fix, passes after.

**Caveats from review** Both skeptics confirmed verbatim. One flagged the same `return`-as-abort bug also skips `file.set_binary(...)` for abandoned files, leaving their binary classification stale.

---

### U56 — Every `FileItem` carries a dead `OnceLock<Mmap>`, plus `SmallVec` heap spill for long paths

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/types.rs:248-259`, `fff-swift/Vendor/fff/crates/fff-core/src/simd_path.rs:9-12`

**Evidence**
```rust
pub struct FileItem {
    ...
    #[cfg(not(target_os = "windows"))]
    content: OnceLock<memmap2::Mmap>,
}
// 4 chunks = 64 bytes inline, covers ~85% of paths without heap fallback.
const INLINE_CHUNKS: usize = 4;
```

**Why it costs** Floodlight passes all three cache-budget knobs as 0 (`FFFIndex.swift:83-85`), so the picker auto-sizes `cache_budget.max_files` to 5,000 once the index exceeds 50k files — meaning ~99% of `FileItem`s at home-directory scale can never populate their `OnceLock<Mmap>` (~24 wasted bytes each, ~12 MB at 500k files). Separately, a home directory's long paths (`Library/Developer/Xcode/DerivedData/App-abcdef/Build/Products/...`) routinely exceed the 64-byte inline budget, so a large share of files trigger an individual heap allocation during the walk (and a corresponding free under the write lock at commit).

**Proposal** (1) Shrink the mmap field: `content: AtomicPtr<memmap2::Mmap>` (8 bytes, null = empty) with a manual `Drop` and a `Clone` that nulls it — recovers 16 of ~24 bytes, keeps the returned `&[u8]` sound since a boxed `Mmap` has a stable address, no lock or index plumbing needed. (2) **Reject** bumping `INLINE_CHUNKS` to 8 — `SmallVec<[u32;8]>` is 40 bytes vs 24, adding 16 bytes to *every* `FileItem` to save one scan-time malloc for the long-path minority; net regression against the goal. A flat `Vec<u32>` + `(offset,len)` per-sync redesign is the right fix but is L effort and touches `DirItem` too — file separately.

**Expected impact** Shrinks the per-file struct (RSS) and the bandwidth every keystroke's fuzzy-match pass streams over the full file vector; reduces commit-time free cost.

**Effort/Risk** S for the `AtomicPtr` swap / L for the full chunk-index redesign. Medium risk — touches a struct with an existing documented lock invariant (`get_cached_content`'s `&self`-borrow contract).

**How to verify on Mac** `RUST_LOG=fff_search=info cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- "$HOME" --seconds 0` — read `FileItem={}B` from the SCAN log; `/usr/bin/time -l` for max RSS; Instruments → Allocations histogram of 16–64 byte allocations during the walk. Add `const _: () = assert!(std::mem::size_of::<FileItem>() <= N);` to lock the win in.

**Caveats from review** Both skeptics confirmed the two mechanisms independently but rejected both original proposed fixes: the accuracy reviewer noted `get_cached_content` returns `&[u8]` borrowed from `&self`, ruling out a simple side-table `RwLock<HashMap>`; the value reviewer proposed the `AtomicPtr` alternative used above. Note the mmap-cache field is also present on `DirItem`'s `ChunkedString`, so the chunk-index redesign benefits both.

---

### U55 — Scan-progress poll takes the picker lock; Floodlight discards the warmup flag it needs

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/lib.rs:829-847` (poll), `Sources/FloodlightEngine/Search/FFFModels.swift:70-80` (dropped field)

**Evidence**
```rust
let guard = match inst.picker.read() { Ok(g) => g, Err(e) => ... };
let result = Box::into_raw(Box::new(FffScanProgress::from(picker.get_scan_progress())));
```

**Why it costs** The value review refuted the original latency framing: Floodlight's search path is already suspended on the same startup task the poll drives, and every search takes the identical picker read lock the poll does, so removing the lock from the poll changes nothing measurable. What *is* real: `signals.scanning` clears (`scan.rs:228`, "file are searchable") **before** the bigram index is built (`scan.rs:328-334`), and Floodlight's readiness gate (`waitForScanCompletion`, `FFFIndex.swift:677-687`) reads only that flag. `FffScanProgress.is_warmup_complete` already exists in the C struct (`fff.h:309`) to distinguish these two states, but Floodlight's `FFFIndexProgress` drops it (`FFFModels.swift:70-80`). Result: the first content search after cold start can run with no bigram prefilter, return nothing under the 35 ms budget, and get reported as a completed empty search rather than "still indexing."

**Proposal** Add `isWarmupComplete` to `FFFIndexProgress` and read `progress.pointee.is_warmup_complete`. When it's false, keep `.file` in `pendingKinds` so the UI reads as "still searching" rather than "no matches," and re-run the content stage once for the current query after the flag flips (poll it via a coarse 250–500 ms background task after `waitForScanCompletion()` returns — not on every content query). **Reject** the original proposal's lock removal from `fff_get_scan_progress` and its 10 ms→100 ms poll backoff — the backoff would delay readiness detection (two consecutive idle polls required) by up to ~200 ms to save microseconds.

**Expected impact** Fixes a UX correctness gap (false "no results" during the post-scan bigram-build window), not query latency.

**Effort/Risk** S / Low. Pure Swift — the field is already in the shipped C header, no XCFramework rebuild needed for the Floodlight side.

**How to verify on Mac** Cold-start with root=$HOME; watch whether the first content query issued right after `waitForScanCompletion()` returns reports "no matches" vs. "searching" before/after the fix.

**Caveats from review** The value lens fully refuted the lock/latency framing (search and poll are not actually contending in the cold-start case that matters, and the write locks on the scan path are all short moves). Keep only the `is_warmup_complete` surfacing, which both reviewers agree is real and cheap.

---

### U41 — One LMDB read transaction per file to score frecency during the walk

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2126-2137`, `fff-swift/Vendor/fff/crates/fff-core/src/dbs/frecency.rs:195-217`

**Evidence**
```rust
files.par_iter_mut().for_each(|file| {
    let _ = file.update_frecency_scores(frecency, arena, base_path, mode);
});
// dbs/frecency.rs:195
let rtxn = self.env.read_txn()...;
let result = self.db.get(&rtxn, &key_hash)...;
rtxn.commit()...;
```

**Why it costs** Every walked file pays: absolute-path build, blake3 hash, LMDB read-txn open/commit, B-tree lookup. The frecency DB holds a few thousand entries at most (10 MiB map size; ~560 KiB after years of use per the code's own comment), so >99.9% of these are misses. The env uses `MDB_NOTLS`, so N background threads also contend on the process-shared reader-table mutex for every file.

**Proposal** Simplest first (S effort): short-circuit the whole `par_iter_mut` pass with a single `db.len(&rtxn) == 0` check — safe because during the walk `git_status` is always `None`, so `get_modification_score` is 0 regardless, and this covers a fresh install or any user who's never opened files through fff. If non-empty: reuse one `RoTxn` per `par_chunks_mut(8192)` block instead of one per file (`RoTxn` is `Send` under the existing `MDB_NOTLS` mode) — removes the reader-mutex contention without a new snapshot data structure. **Drop** the finding's git-status half of the proposal (`file_picker.rs:1516-1549`) — that loop is bounded by git-dirty-file count (tens to hundreds), single-threaded, and never fires for Floodlight's non-git `$HOME` scope.

**Expected impact** Cold-start only; removes N LMDB txn round trips and reader-mutex contention from the walk. Not the single largest walk cost (two full `par_sort_unstable` passes over the same file vector run in the same region) — but a real, cheap win.

**Effort/Risk** S (short-circuit + chunked txn) / M (full per-key snapshot). Low risk, pure Rust.

**How to verify on Mac** `FLOODLIGHT_FFF_LOG=/tmp/fff/fff.log FLOODLIGHT_FFF_LOG_LEVEL=info` — compare `walk_filesystem` span time with a populated vs. freshly-deleted `frecency.lmdb`; Instruments → Time Profiler filtered to `fff-bg-*` threads for `mdb_txn_begin`/`commit`/`blake3` frames before/after.

**Caveats from review** Both skeptics confirmed the mechanism but rejected "largest remaining CPU cost" — the two full-array sorts in the same function are plausibly as large. Citation correction: `update_frecency_scores` is at `file_picker.rs:514`, not `types.rs:514` as originally cited.

---

### U39 — `FFFFileSource.start` blocks every downstream publish stage on the full walk

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:622-626, 677-687`

**Evidence**
```swift
func start() async throws {
    try await index.start()
    try await waitForScanCompletion()
    state.withLock { $0.hasStartedIndex = true }
}
```

**Why it costs** `waitForScanCompletion` polls every 10 ms with **no deadline and no cap** until two consecutive idle polls, and `SourceSearchEngine.ensureStarted()` awaits it as part of a tuple with the app/settings startups — so a slow file walk gates all three, not just file results. The value review found the practical blast radius smaller than first framed (app/settings already have content on screen from the immediate page; the block mostly self-heals via `warmUp`), but the missing deadline is a genuine, unbounded-worst-case bug: `isScanning` is re-armed on every rescan, so on a churning `$HOME` this loop could in principle never terminate — unlike its sibling in `ApplicationCatalog.start`, which caps at 200×10ms = 2 s.

**Proposal** Bound the wait with a deadline matching `ApplicationCatalog`'s (~2 s), and log on expiry:
```swift
private func waitForScanCompletion() async throws {
    var consecutiveIdlePolls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while consecutiveIdlePolls < 2, ContinuousClock.now < deadline {
        ...
    }
}
```
Do not decouple readiness from scan completion (the originally proposed `isIndexReady`) — the value review showed this yields the same empty-file-results snapshot the block already produces, and introduces a real regression: an unbounded live-grep-against-empty-index flash of "no results" where today there is a spinner.

**Expected impact** Removes an unbounded worst-case stall; no measurable change to the common-case timeline.

**Effort/Risk** S (bounded wait) / Low. The full decouple variant is M / Medium and not recommended without also adding the scanning flag to `SearchSnapshot`.

**How to verify on Mac** Instruments → Points of Interest: add begin/end around `waitForScanCompletion`; launch with a fresh index root=$HOME under simulated watcher churn (concurrent file writes) and confirm the wait now terminates within the deadline instead of indefinitely.

**Caveats from review** The two skeptics split hard on this one: accuracy confirmed the blocking mechanism and found it worse than stated (repeats on every launch, not just first — `enable_mmap_cache` doesn't persist a file list). Value refuted the performance framing entirely (blocked stages carry near-zero unique payload; the real defect is UX — a spinner instead of results — not latency) and specifically flagged the proposed fix's own regression. Presented above per the value lens's narrower, safer recommendation.

---

### U42 — No on-disk index snapshot; full walk repeats every launch

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2186-2202`

**Evidence**
```rust
Ok(FileSync {
    files: StableVec::from_vec_with_reserve(files, MAX_OVERFLOW_FILES),
    ...
    chunked_paths: Some(Arc::new(chunked_paths)),
    ignore_rules,
})
```

**Why it costs** The only persistence in fff-core is LMDB for frecency and query history; the file list, path arena, dir table, and bigram index are all rebuilt from the filesystem on every process start. `enable_mmap_cache` is content-only (grep caching) and its warmup path is commented out. For a resident menu-bar launcher this means every login/relaunch pays a full `$HOME` walk before file results exist.

**Proposal** Add an optional snapshot format to fff-core: a versioned header + raw path-arena bytes + flat per-file records, mmapped read-only on load and reconstituted into `FileSync`. Commit the snapshot and clear `scanning` before the real walk starts, then swap in the walk's result when it completes.

**Expected impact** Time-to-first-file-result on a warm profile drops from full-walk duration to roughly 100–500 ms (materialization cost, not a pure mmap — `ChunkedString`'s `SmallVec` heap-allocates for ~15% of paths, and `AtomicU8`/`AtomicI32`/`git2::Status`/`OnceLock<Mmap>` fields all need reconstruction). Scoped to the window between login/relaunch and walk completion — **not** steady-state per-keystroke latency, since Floodlight starts the index once at `applicationDidFinishLaunching` as a resident accessory app.

**Effort/Risk** L / Medium. `ChunkedPathStore.arena` is `Vec<SimdChunk>`, not directly mappable without an `Owned`/`Mapped` enum and updates to every construction site. A snapshot also commits with `bigram_index: None`, so `fff_live_grep` briefly loses its prefilter and brute-force-scans a stale list — needs its own gating.

**How to verify on Mac** `FFF_BENCH_REPO="$HOME" cargo bench -p fff-nvim --bench scan -- post_scan/full_init` as baseline; add a `snapshot_load` bench timing `load_snapshot` + first `fuzzy_search`. `hyperfine --warmup 1 'cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- "$HOME" --seconds 0'`.

**Caveats from review** Both skeptics confirmed the underlying facts (no persistence exists; the "10 ms" load-time estimate in the original finding was rejected as ~10-50x too optimistic — revised to 100-500 ms). The value lens recommends trying a much cheaper alternative first: phase the commit inside `walk_filesystem` (commit a shallow/priority-directory prefix, then the full walk) rather than building a whole new on-disk format — see U43, which is the same idea without persistence.

---

### U43 — Index commits all-at-once; nothing searchable until the whole walk finishes

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/scan.rs:171-228`

**Evidence**
```rust
let sync = match FileSync::walk_filesystem(...) { ... };
picker.commit_new_sync(sync);
...
signals.scanning.store(false, Ordering::Relaxed); // file are searchable
```

**Why it costs** `walk_collect_files` accumulates every entry into one mutex-guarded `Vec` and returns only after the full traversal; sort, chunked-store build, frecency pass, and commit all happen after. Nothing is queryable until that single commit.

**Proposal** Cheapest variant, no walker changes: run a depth-limited pre-pass first (`WalkBuilder::max_depth(3)`), commit it, clear `scanning`, then run the full walk and commit again — covers `~/Documents`, `~/Downloads`, `~/Desktop`, top-level project dirs (where a launcher's hits concentrate) within tens of ms.

**Expected impact** Contested — see caveats. If pursued, scope expectations to "the one search-panel presentation right after process launch," not steady-state or rescans (which already serve the previous `sync_data` until commit).

**Effort/Risk** L / Medium-High. Two `commit_new_sync` calls per `ScanJob::run` interact with the documented `post_scan_snapshot` unsafe invariant (`file_picker.rs:1468-1474`), and a second commit silently discards git-status boosting computed against the first commit (`git_status_worker.request_full_rescan()` fires once, at `scan.rs:196-200`) — must be re-issued after the *final* commit only.

**How to verify on Mac** Add a bench beside `scan_bench.rs` recording `Instant::now()` at picker creation and polling `picker.get_files().len()` every 10 ms; print time-to-first-nonzero vs. time-to-full.

**Caveats from review** This is the one item where the two skeptics genuinely disagree rather than converge. Accuracy: mechanism real, risk understated (batched commits contradict the `post_scan_snapshot` safety comment; clearing `scanning` mid-walk can let a rescan race a second commit). Value: refuted the win as mis-scoped — an fff-core-only change is invisible without a matching Swift-side relaxation of `waitForScanCompletion`, and the affected window is one panel presentation per launch, not steady state. The value lens's suggested cheaper alternative is Floodlight-only (decouple app/settings readiness from file readiness) and overlaps directly with U39 — do that first and re-measure before investing in this.

---

### U44 — Post-scan bigram build has no cancellation and no I/O budget

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:817` (read), `scan.rs:228, 240` (timing)

**Evidence**
```rust
let want = (file.size as usize).min(MAX_INDEXABLE_FILE_SIZE);
let filled = file.read_trimmed_into_buf(base_fd, base_path, arena, path_buf, &mut buf[..want]);
```

**Why it costs** `build_bigram_index` reads the full content of every indexable file (the 2 MB cap is a no-op since only pre-filtered ≤2 MB files reach this call), immediately after `scanning` clears — i.e. overlapping the user's first queries. Unlike its sibling `sniff_binary_for_non_indexable`, it has **no cancellation check at all**, so neither app quit nor a pending rescan can interrupt a home-scope build mid-flight.

**Proposal** Thread `signals.cancelled` into `build_bigram_index` and check it per `par_chunk`, matching the sibling function. **Reject** the originally proposed `ContentIndexBudget`/frecency-reordering scheme — the value review showed it breaks a load-bearing sort invariant (`find_file_index` binary-searches on the exact `(is_indexable, parent_dir_index, file_name)` ordering) and silently makes budget-skipped files permanently unsearchable by content until the next rescan — a real recall regression, not graceful degradation.

**Expected impact** Lets a scope change or app quit interrupt an in-flight home-directory bigram build instead of stalling behind it; no change to the common-case build duration.

**Effort/Risk** S (cancellation) / Low. The rejected budget variant would be M / Medium.

**How to verify on Mac** `RUST_LOG=fff_search=debug` — watch the "Building Bigram Index" span; issue a scope change mid-build before/after and time how long the old build takes to actually stop.

**Caveats from review** Both skeptics independently converged on cancellation as the real fix and rejected the budget/reorder scheme for the same reason (breaks the sort invariant `find_file_index` depends on, and silently drops files from content search).

---

### U48 — No FFI knob for extra ignore patterns

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/ffi_types.rs:56-65`

**Why it costs** `IGNORED_DIRS` is compile-time-const; the only FFI knobs are booleans. Floodlight cannot honor a user "exclude this folder" setting without patching and rebuilding the vendored engine and XCFramework.

**Proposal** Largely superseded by U47 (append the missing macOS entries directly, since fff-swift already forks and rebuilds this file routinely per `Vendor/fff/UPSTREAM.md`). For a genuine user-facing "exclude folder" setting, implement it as a Swift-side path-prefix filter over `FFFIndex.search`/`searchContent` results instead — needed regardless, since exclusions must also cover already-persisted frecency/history entries for now-excluded paths.

**Expected impact** Low as a standalone item once U47 lands; the Swift-side filter is the practical path to a user setting.

**Effort/Risk** M (FFI field) / Low. XS+S for the Swift-side alternative.

**How to verify on Mac** N/A if superseded; otherwise `cargo test -p fff-search walk::` after adding an `extra_ignore` case.

**Caveats from review** Both skeptics noted the same escape hatch already exists for the scan (not the watcher): the ripgrep walker honors a plain `.ignore` file (`walk/ripgrep.rs:27`) with no code change. Value lens recommended re-scoping this finding into "extend `IGNORED_DIRS` + add a Swift-side filter," effectively merging it into U47.

---

### U46 — `commit_new_sync` drops the old index under the picker write lock

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1499-1502`

**Evidence**
```rust
pub(crate) fn commit_new_sync(&mut self, sync: FileSync) {
    self.sync_data = sync;
    self.cache_budget.reset();
}
```

**Why it costs** `self.sync_data = sync` drops the old `FileSync` — arena, `FileItem`s (each with a possible heap `SmallVec`), dir table, bigram bitsets — while holding the write lock every search and progress poll contends on.

**Proposal** `mem::replace` the old value out under the lock, then drop it **synchronously right after the guard is released** (the calling thread is already a background-pool worker, so no need to spawn a separate drop task — spawning would contend with the `run_post_scan`/bigram build that follows immediately on the same pool).

**Expected impact** Accuracy review downgraded the stall from "hundreds of ms" to tens of ms — the mmap cache is capped at ~5,000 files regardless of index size, so munmap count is bounded. Value review further downgraded: watcher rescans on the main index are throttled to at most once per 30 s (once per 5 min above 1M files), so this is a <0.1%-duty-cycle cost invisible to a per-keystroke or cold-start benchmark.

**Effort/Risk** S / Low (synchronous variant only — do not spawn the drop).

**How to verify on Mac** `rescan_probe` while a second process hammers `fuzzy_search`; log p99 search latency across a rescan commit before/after.

**Caveats from review** The value review flagged a better target for the same class of bug: `FilePicker::new_with_shared_state` (`file_picker.rs:966-968`) drops the **entire previous picker** — sync data, watcher, git worker, bigram index — under the write lock, and that path (`fff_restart_index`) is the one Floodlight actually hits deterministically on every scope change and `rebuild()`, unlike the rarely-firing watcher-rescan path this finding targets. Consider fixing that site instead or in addition.

---

### U50 — Default (ripgrep) walker computes relative paths via `pathdiff::diff_paths` instead of `strip_prefix`

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:477`

**Evidence**
```rust
let rel = pathdiff::diff_paths(path, base_path).unwrap_or_else(|| path.to_path_buf());
```

**Why it costs** Every indexed file pays a full component-wise ancestor walk plus a `PathBuf` allocation, when `WalkBuilder` entries are always known to be under `base_path` — the walker's own directory branch three lines away already uses the cheap `strip_prefix`.

**Proposal** Swap to `path.strip_prefix(&base_path)`, falling back to `diff_paths` only on failure. **Note the bigger win nearby**: `walk/ripgrep.rs:39-40, 64` funnels every file and directory through one global `parking_lot::Mutex`-guarded `Vec` across all walker threads — replacing that with per-thread accumulation merged after `walker.run()` removes actual lock contention, versus the pathdiff change's single-digit-percent allocation saving.

**Expected impact** Low in isolation (both skeptics measured the zlob-backend's quoted "80-120ms/500k" figure as inapplicable to the parallel, stat-bound ripgrep backend Floodlight actually ships). Land as a tidiness/consistency fix; prioritize the mutex removal if pursuing this area at all.

**Effort/Risk** S / Low. Pure Rust, no ABI surface.

**How to verify on Mac** `FFF_BENCH_REPO="$HOME" cargo bench -p fff-nvim --bench scan -- post_scan/full_init`; Instruments → Time Profiler on `rescan_probe`, check for `pathdiff::diff_paths` frames disappearing.

**Caveats from review** Both skeptics independently refuted the magnitude claim (the cited number is from an unshipped `zlob`-only fast path with zero call sites in the shipped backend) and both redirected toward the global mutex as the actual bottleneck in the same function.

---

### U53 — Initial scan is capped at half the cores, same as a rescan

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/parallelism.rs:16`

**Evidence**
```rust
// Background work is mostly syscall-bound; halving parallelism leaves
// cores for search/UI at negligible throughput cost.
let bg_threads = (total / 2).max(2);
```

**Why it costs** `BACKGROUND_THREAD_POOL` sizes itself once, globally, and the cold-start walk (nothing to search yet) inherits the same halved thread count as a background rescan (where leaving cores for search matters).

**Proposal** Contested — see caveats. If pursued at all, target the walk-time-only benefit by threading `install_watcher` (the existing "is this the bootstrap scan" discriminator) through to the walker's explicit thread argument.

**Expected impact** Low. Upstream's own benchmarking comment in the same file (`parallelism.rs:36`, "16t=6.2s vs 13t=4.9s") shows exceeding the P-core count is *slower* on file-heavy work, and the available headroom (total/2 → P-core count) is zero on base 8-logical-core Macs.

**Effort/Risk** M / Medium.

**How to verify on Mac** `for t in 4 8 12 16; do FFF_BACKGROUND_THREADS=$t hyperfine --warmup 1 --runs 5 "cargo run --release -p fff-nvim --features rescan-stats --bin rescan_probe -- $HOME --seconds 0"; done` (after wiring an env var).

**Caveats from review** The value review essentially refuted this: the walker's real serialization point is the global mutex (see U50), raising thread count adds contenders there; Floodlight also runs two FFF instances concurrently at cold start sharing the same process-global pool, so a per-instance override is structurally hard to implement (the pool is a `static LazyLock`, built once, first-touch-wins). Do not implement without a measured baseline showing headroom exists on the target hardware.

---

### U52 — `hint_allocator_collect` is a no-op in the Floodlight build

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2445-2459`

**Evidence**
```rust
pub(crate) fn hint_allocator_collect() {
    #[cfg(feature = "mimalloc-collect")]
    { BACKGROUND_THREAD_POOL.broadcast(|_| unsafe { libmimalloc_sys::mi_collect(true) }); ... }
}
```

**Why it costs** The feature is enabled only by `fff-nvim`; `fff-c` (what Floodlight builds) uses defaults, so both call sites (post-bigram-build, post-walk) do nothing, and freed post-scan memory doesn't get an explicit "release to OS" hint on Floodlight's system-allocator build.

**Proposal** Do not add a `malloc_zone_pressure_relief` branch (the originally proposed fix) — the value review found this targets the wrong bucket (macOS libmalloc's large allocations, which dominate the walk's churn, already get vm_deallocate'd on free; pressure relief only reaches small/nano-zone allocations that already self-reclaim) and its broadcast-per-thread design is actively harmful for a global, lock-taking, zone-wide operation. **Measure first**: `vmmap --summary` / `footprint` right after `IndexStartup` completes, comparing dirty pages against the SCAN log's own reported `files_vec`/`chunked_store` sizes (free today, no code change). Only if a real gap shows up, the correct fix is the opposite of the original proposal — link mimalloc into `fff-c` (mirroring `fff-nvim`) and let the existing, upstream-tested `mi_collect` hook do its job.

**Expected impact** Speculative until measured; likely low.

**Effort/Risk** S / Low, but gated on measurement.

**How to verify on Mac** `footprint -j $(pgrep Floodlight)` after index settles, baseline vs. any change; `vmmap --summary` for dirty-page accounting.

**Caveats from review** The value review fully refuted the proposed fix (wrong allocator zone, wrong threading model, adds risk at exactly the moment the index becomes queryable) while confirming the underlying observation that the feature is off. Treat as "investigate, don't fix yet."

---

### Rejected ideas

- **U49** — "`StableVec::from_vec_with_reserve` doubles the file/dir arrays via `Vec::reserve`": refuted — the `files` vec arrives via an in-place-collect specialization from `Vec<(FileItem, String)>` with ~25% capacity slack already built in, so `reserve(1024)` is a no-op there; only the much smaller `dirs` array (~1-2 MB) is affected, not the claimed tens of MB.
- **U51** — "Bigram builder allocates two dense 5000-column bitset slabs sized by file count": refuted — the 5000-column cap is sized to cover essentially all possible printable bigrams, so on a real home-directory corpus nearly all columns get allocated anyway (lazy-column allocation saves ~nothing); the claimed "hundreds of MB of RSS" is virtual `calloc` address space, not resident memory, on macOS.

## Upstream: XCFramework build flags and toolchain

Floodlight links a third-party binary (`vmg-dev/fff-swift`'s `CFFF.xcframework`, checksum-pinned) that is itself built from a vendored, patched copy of `dmtrKovalenko/fff`. Every finding below is either a flag change to that build, a feature gate on the vendored Rust crates, or a linker change to Floodlight's own executable target. Two structural facts run through the whole list: (1) the XCFramework is consumed as a remote, checksummed release artifact, so most fff-swift-layer changes need a new fff-swift tag before Floodlight can use them — effort is routinely "S in the diff, M end-to-end"; (2) the build never `cd`s into the vendored workspace, so `Vendor/fff/.cargo/config.toml` and `rust-toolchain.toml` are invisible to it today.

### Ranked table

| Rank | ID | Opportunity | Layer | Impact | Effort | Risk | Status | Upstreamable |
|---|---|---|---|---|---|---|---|---|
| 1 | U66 | Own the XCFramework: drop the FFFKit product, vendor a local `binaryTarget` | floodlight | medium (enabler for all below) | M | low | unreviewed | false |
| 2 | U57 | Build XCFramework with `zlob` walker, not default `ripgrep` | fff-swift | medium | S (M end-to-end) | medium | confirmed | false |
| 3 | U58 | Backport fff #799 (lossy basename-offset fix) before shipping U57 | fff-core | low, gates U57's correctness | S | low | confirmed | false |
| 4 | U61 | Link Floodlight with `-dead_strip` + `-no_exported_symbols` | floodlight | high (unconfirmed) | S | medium | unreviewed | false |
| 5 | U64 | Gate vendored libgit2 behind an opt-in `git` feature | fff-core | high (unconfirmed) | L | medium | unreviewed | true |
| 6 | U65 | Gate `tracing-subscriber`/`env-filter`/`tracing-appender`; cap log level | fff-c | medium (unconfirmed) | M (S for step a) | low | unreviewed | true |
| 7 | U60 | `panic = "abort"` via a dedicated `xcframework` profile | fff-swift | medium (unconfirmed) | S | low | unreviewed | false |
| 8 | U69 | Build fff-c as staticlib only (`cargo rustc --crate-type staticlib`) | fff-c | dev-velocity only | S | low | unreviewed | false |
| 9 | U73 | Pin exact rustc version; emit BUILDINFO into the release | fff-swift | low, reproducibility | S | low | unreviewed | false |
| 10 | U59 | Fix `.cargo/config.toml`/`rust-toolchain.toml` discovery | fff-swift | low, enabler | S | low | confirmed | false |
| 11 | U63 | Set `mimalloc` as fff-c's global allocator | fff-c | medium (unconfirmed) | S | medium | unreviewed | true |
| 12 | U62 | Pin `fuzzy_search`/`fuzzy_search_mixed` onto `SEARCH_THREAD_POOL` | fff-core | medium (unconfirmed) | M | low | unreviewed | true |
| 13 | U71 | Add signposts around the FFI boundary and queue wait | floodlight | enabler (unconfirmed) | S | low | unreviewed | false |
| 14 | U70 | Make `profile.prof` selectable for symbolicated Instruments traces | fff-swift | enabler (unconfirmed) | S | low | unreviewed | false |
| 15 | U68 | Set `-C target-cpu=apple-m1` / `x86-64-v3` explicitly | fff-swift | low (unconfirmed) | S | low | unreviewed | false |
| 16 | U67 | Ship a universal (arm64+x86_64) XCFramework | fff-swift | correctness on Intel (unconfirmed) | M | low | unreviewed | false |
| 17 | U74 | Cross-module optimization / `-enforce-exclusivity=unchecked` on FloodlightEngine | floodlight | low (unconfirmed) | S | medium | unreviewed | false |
| 18 | U72 | Two-stage PGO build for libfff_c.a | fff-swift | medium-high (unconfirmed) | L | medium | unreviewed | false |

---

### 1. U66 — Own the XCFramework: drop FFFKit, vendor a local binaryTarget

**Where** `Package.swift:26-40` (Floodlight); `fff-swift/Package.swift:9-17`.

**Evidence**
```swift
.package(url: "https://github.com/vmg-dev/fff-swift", from: "0.2.1"),
...
.target(name: "FloodlightEngine",
        dependencies: [.product(name: "FFFKit", package: "fff-swift")], ...)
```
`rg -n 'import FFFKit|import CFFF' Sources Tests` shows production code imports only `CFFF`; `FFFKit` (670 lines) is referenced solely by one test file.

**Why it costs** Every flag change in this whole section — walker, panic strategy, allocator, target-cpu, libgit2 gating — lives inside a build that Floodlight can only consume as a `binaryChecksum`-pinned remote zip (`fff-swift/Package.swift:9-10`). Nothing here is landable from the Floodlight repo alone until a new fff-swift tag is cut. FFFKit itself also compiles and links a second, unused wrapper around the same C API into the app.

**Proposal** Build the XCFramework locally with the flags this audit recommends, commit it (or an LFS pointer) at `Vendor/CFFF.xcframework`, and switch to a local `binaryTarget`:
```swift
.binaryTarget(name: "CFFF", path: "Vendor/CFFF.xcframework"),
.target(name: "FloodlightEngine", dependencies: ["CFFF"], ...,
        linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("CoreServices"),
                          .linkedFramework("Security"), .linkedLibrary("iconv"), .linkedLibrary("z")])
```
Port `SearchModelInvariantTests.swift` off `FFFKit`. Compiling fff-c as a SwiftPM plugin target is not viable — the plugin sandbox blocks cargo's network/registry writes.

**Expected impact** Removes a compiled 670-line unused Swift module; more importantly, unblocks every other finding in this section from needing a third-party release cycle, and makes the shipped `.a`'s provenance auditable.

**Effort/Risk** M / low.

**How to verify on Mac** `./autoresearch.sh` before/after for `deliverable_size_bytes`/`binary_size_bytes`; `swift build -c release -Xlinker -map -Xlinker /tmp/fl.map && grep -c FFFKit /tmp/fl.map`; `swift package show-dependencies` should list no remote packages; `make check && make test && make test-performance` green.

**Caveats from review** Unreviewed — no adversarial pass ran. Committing a binary artifact trades a checksum guarantee for a manual build-provenance discipline (BUILDINFO.txt, see U73) that must be maintained by hand.

---

### 2. U57 — Build the XCFramework with `zlob`, not the default `ripgrep` walker

**Where** `fff-swift/scripts/build-xcframework.sh:19-24`.

**Evidence**
```
cargo build --manifest-path "$VENDOR_DIR/Cargo.toml" --package fff-c --release --locked --target "$TARGET"
```
No `--features`, so `fff-c/Cargo.toml`'s `default = ["ripgrep"]` wins, while `Vendor/fff/Makefile:52-60` (`build`, `build-e2e`, `build-c-lib`) all pass `--no-default-features --features zlob`.

**Why it costs** `walk/ripgrep.rs:60-65` does `entry.metadata().ok()` (a stat syscall the ignore crate doesn't cache from readdir) then `FileItem::new_from_walk` → `pathdiff::diff_paths` (a `PathBuf` alloc) + `to_string_lossy` + `to_canonical_slashes` + a path-component walk for `is_known_binary_extension`. `walk/zlob.rs:36-37` bulk-fetches `SIZE|MTIME` during traversal and builds `FileItem` via `new_raw` directly off walker-supplied bytes — no stat, no diff_paths, no component walk. This runs on the full home-directory scan Floodlight does at every cold start (`enable_home_dir_scanning = true`), which `FFFFileSource` must finish before the file source reports ready, and it repeats on every full rescan (`background_watcher.rs:733`).

**Proposal**
```sh
cd "$VENDOR_DIR"   # also fixes config discovery, see #10 (U59)
MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0} \
    cargo build --package fff-c --release --locked \
        --no-default-features --features zlob --target "$TARGET"
```
Also flip `Vendor/fff/Makefile`'s `cargo-test` and `lint` targets to the same features — otherwise CI validates ripgrep while the release ships zlob. `zlob 1.6.3` is already in `Cargo.lock`, so `--locked` holds without further changes (but see U58 — must bump to 1.6.5 first). Add Zig 0.16 to both fff-swift CI workflows (`mlugg/setup-zig@v2`), which neither installs today.

**Expected impact** Reviewers converged on: real but smaller than the per-entry ledger implies — a few hundred ms off a multi-second home-directory walk (visible in `IndexStartup` and time-to-first-file-result), not per-keystroke latency. This is the walker every upstream release ships and tunes against.

**Effort/Risk** S in the script, M end-to-end (cross-repo release). Risk: medium — zlob prunes differently on non-git roots (`SKIP_HIDDEN` + `extra_ignore(IGNORED_DIRS)` vs. ripgrep's `.hidden(!is_git_repo)`), so the indexed set for a home-directory scope can change, not just its speed; also needs `bindgen`/libclang at build time (Xcode CLT covers it) and Zig objects must carry `LC_BUILD_VERSION` consistent with `MACOSX_DEPLOYMENT_TARGET=14.0`.

**How to verify on Mac**
```sh
cargo bench -p fff-search --bench glob_bench --no-default-features --features zlob   # from Vendor/fff
```
End-to-end: rebuild XCFramework, `swift package edit fff-swift --path <fff-swift>`, `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`; compare `expanded_fff_scan_ms` vs a ripgrep build. Instruments signpost `IndexStartup` before/after. `sudo fs_usage -w -f filesys $(pgrep Floodlight) | grep -c stat64` during first scan.

**Caveats from review** Both skeptics confirmed the mechanism but corrected the magnitude framing (walker swap, not three line-items) and effort (cross-repo, not S). Drop the third claimed cost (`counter.fetch_add`) — both walkers already take a shared mutex per entry, so the atomic saving is noise. Must ship together with U58.

---

### 3. U58 — Backport fff #799 (lossy basename-offset fix) before shipping U57

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/walk/zlob.rs:81-88`.

**Evidence**
```rust
let basename_offset = entry.basename_offset_in_relative();       // raw-byte offset
let rel_str = String::from_utf8_lossy(rel_bytes).into_owned();   // lossy-decoded string
```
Upstream `v0.10.5..v0.10.6` (commit 81517a0, "(#799)") replaces both with `basename_offset_in_relative_lossy()` / `relative_path_lossy()`, and bumps `zlob = "=1.6.3"` → `"=1.6.5"`.

**Why it costs** For any filename with invalid UTF-8 in its **directory prefix**, `from_utf8_lossy` expands bad bytes into 3-byte U+FFFD, desyncing the stored offset from the decoded string. `filename_offset` feeds `String::split_at` (`file_picker.rs:2100`, inside a rayon `par_sort`) and `core::str::from_utf8_unchecked` (`simd_path.rs:139-208`) — a non-char-boundary index there panics or is UB, not just a mis-scored result. This is dormant today because ripgrep is in use; it goes live the moment U57 lands.

**Proposal** Backport commit 81517a0 in full (including the dead `new_from_walk_bytes` re-measurement and `tests/invalid_utf8_paths.rs`), bump the workspace pin to `zlob = "=1.6.5"`, `cargo update -p zlob --precise 1.6.5`, record it in `UPSTREAM.md`. Land in the same commit as U57 so the two can never separate.

**Expected impact** Prevents a panic/UB regression that U57 would otherwise introduce. No perf change.

**Effort/Risk** S / low.

**How to verify on Mac**
```sh
cargo test -p fff-search --no-default-features --features zlob --lib walk   # from Vendor/fff
```
Then a fixture: `printf 'x' > "$(printf 'bad\xffname.txt')"`, point Floodlight's `FFFIndexTests` suite at that root, assert the returned name renders lossily rather than panicking.

**Caveats from review** Both reviewers confirmed. Exposure is narrower than the finding implies — APFS/HFS+ reject invalid-UTF-8 names outright, so the default home-directory scope is immune; only external exFAT/NTFS/SMB volumes can trigger it. Backport anyway since it's cheap and it's the only regression guard available (the bug can't be reproduced on APFS).

---

### 4. U61 — Link Floodlight with `-dead_strip` + `-no_exported_symbols`

**Where** `Package.swift:50-56`.

**Evidence**
```swift
linkerSettings: [
    .linkedFramework("Carbon"), .linkedFramework("QuickLookUI"),
    .linkedFramework("QuickLookThumbnailing"), .linkedFramework("ServiceManagement"),
    .unsafeFlags(["-Xlinker", "-dead_strip_dylibs"]),
]
```
Floodlight calls 28 of ~60 exported `fff_*` symbols; `fff_health_check`, `fff_watch`/`fff_unwatch`, `fff_multi_grep`, `fff_refresh_git_status` are never called. `fff_health_check` is the sole reason `fff-c` links `serde_json` (`crates/fff-c/src/lib.rs:1108`).

**Why it costs** `-dead_strip_dylibs` only drops unused dylib load commands, not unreferenced code. `libfff_c.a` is a static archive built with `lto = "fat"`/`codegen-units = 1`, so members are pulled in wholesale, and the linker keeps everything reachable from an *exported* symbol — including the unused watch machinery and `serde_json`. `bundle.sh:22`'s `strip -u -r` only removes symbol-table entries afterward, not text. This is the cheapest lever on the primary tracked metric (`deliverable_size_bytes`) in the entire build, and it is entirely Floodlight-side — no fff-swift release needed.

**Proposal**
```swift
.unsafeFlags([
    "-Xlinker", "-dead_strip",
    "-Xlinker", "-dead_strip_dylibs",
    "-Xlinker", "-no_exported_symbols",
]),
```
`-no_exported_symbols` matters: without it, ld64 treats globals reachable through the export trie as GC roots, keeping every `#[no_mangle] extern "C" fn fff_*` (and `serde_json` with it) alive.

**Expected impact** Direct `deliverable_size_bytes`/`binary_size_bytes` reduction; `serde_json` alone is typically 150-300 KB after LTO, plus unused watch/multi-grep/git-status code paths.

**Effort/Risk** S / medium — `-dead_strip` is safe for Mach-O objects emitting `.subsections_via_symbols` (both Rust and Swift do), but Objective-C metadata / `NSPrincipalClass` lookup doesn't go through the export trie, so a regression there would be silent until runtime.

**How to verify on Mac**
```sh
swift build -c release -Xlinker -map -Xlinker /tmp/fl-base.map
awk '/^# Symbols:/,0' /tmp/fl-base.map | grep -c 'libfff_c.a'; grep -c 'serde_json' /tmp/fl-base.map
```
Rebuild with the new flags into a second map, diff counts. `./autoresearch.sh` before/after (`deliverable_size_bytes`, `binary_size_bytes`, `dmg_size_bytes`). Launch check: `make bundle && open .build/Floodlight.app`, exercise hotkey/file search/content search/Quick Look, then `codesign --verify --deep --strict .build/Floodlight.app`. Optional: `brew install bloaty && bloaty -d compileunits .build/release/Floodlight | head -40`.

**Caveats from review** Unreviewed — treat the 150-300 KB estimate as unconfirmed until a link-map diff is taken. Confirm empirically (not from docs) whether ld64 on macOS 14/15 treats an executable's globals as `-dead_strip` roots absent `-no_exported_symbols`.

---

### 5. U64 — Gate vendored libgit2 behind an opt-in `git` feature

**Where** `fff-swift/Vendor/fff/crates/fff-core/Cargo.toml:68`.

**Evidence**
```toml
git2 = { workspace = true }   # unconditional
```
Workspace: `git2 = { version = "0.21.0", default-features = false, features = ["vendored-libgit2"] }`. `module.modulemap:3-5` links `fff_c`, `iconv`, `z` as a result. Floodlight never calls `fff_refresh_git_status`; `FFFSearchResult` carries no git-status field.

**Why it costs** A full vendored libgit2 (plus zlib/iconv linkage) compiles into `libfff_c.a` and the Floodlight binary for a feature never surfaced. With the ripgrep walker (current build), the watcher's `IgnoreFilter` falls back to `repo.is_path_ignored(path)` per changed path and opens a `Repository` per event batch — a per-event cost on the incremental-update path.

**Proposal** Upstream (dmtrKovalenko/fff): add a default-on `git` feature to `fff-search`/`fff-c`; replace `FileItem.git_status: Option<git2::Status>` with a crate-local enum so the type doesn't leak `git2`; gate `Repository::open`/`is_path_ignored` behind `#[cfg(feature = "git")]` with the existing `is_non_code_directory` heuristic as the else-branch; replace `is_git_repo` detection with a `base.join(".git").exists()` probe. Build the XCFramework with `--no-default-features --features zlob` (no `git`) — with zlob the walker supplies its own ignore rules, so dropping libgit2 costs the watcher nothing.

**Expected impact** Removes vendored libgit2 (typically 1-2 MB of compiled C after LTO) plus `-lz`/`-liconv`, likely the single largest identified contributor to `deliverable_size_bytes`. Also removes per-batch `Repository::open` and per-event `is_path_ignored` from the watcher.

**Effort/Risk** L / medium — 9 files / ~25 call sites in fff-core.

**How to verify on Mac** Size attribution first: `grep -c 'libgit2' /tmp/fl.map`; `ar t Vendor/fff/target/aarch64-apple-darwin/release/libfff_c.a | grep -c libgit2`; `bloaty -d compileunits .build/release/Floodlight | grep -i git`. After: `./autoresearch.sh` deltas. Watcher regression: `cargo test -p fff-search --no-default-features --features zlob --lib --test rescan_regression`. Full gate: `cargo test --workspace --no-default-features --features zlob --exclude fff-nvim --exclude fff-python`, then `swift test`.

**Caveats from review** Unreviewed — largest single-line-item claim (1-2 MB) is the finder's estimate, not measured. Confirm sizing before committing to the L-effort refactor; if the number is small, this may not clear the bar against U57/U61/U65.

---

### 6. U65 — Gate `tracing-subscriber`/`env-filter`/`tracing-appender`; cap log level

**Where** `fff-swift/Vendor/fff/crates/fff-core/Cargo.toml:85-86`.

**Evidence**
```toml
tracing-appender = "0.2"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }   # unconditional
```
Only reachable when `log_file_path` is non-nil (`crates/fff-c/src/lib.rs:200-205`); Floodlight always passes `nil` (`FFFIndex.swift:27,79-80`).

**Why it costs** The subscriber stack, `env-filter`'s regex engine (`regex-automata`+`matchers`), and the non-blocking appender's worker-thread machinery are compiled and linked unconditionally, unreachable by dead-stripping because `init_tracing` is reachable from `fff_create_instance_with`, a link root. Enabling logging (if it ever were) also installs a process-wide SIGSEGV handler and replaces the panic hook — behavior a macOS app should opt into, not inherit.

**Proposal** Two steps, cheapest first. (a) Floodlight-local, no upstream churn: in `fff-c/Cargo.toml`, `tracing = { workspace = true, features = ["release_max_level_warn"] }` — turns 21 `trace!`/`debug!`/`info!` call sites (including in the watcher's per-event loop) into compile-time no-ops. (b) Upstream: gate the subscriber behind a default-on `logging` feature; build the XCFramework without it.

**Expected impact** Removes `tracing-subscriber`, `regex-automata`, `matchers`, `tracing-appender` — estimated 300-600 KB after LTO. Step (a) alone also removes per-event level-check/argument-setup overhead in watcher and walker loops.

**Effort/Risk** M end-to-end (S for step a alone) / low.

**How to verify on Mac** `grep -cE 'tracing_subscriber|regex_automata|matchers|tracing_appender' /tmp/fl.map`; `./autoresearch.sh` for `deliverable_size_bytes`. Apply step (a) alone first to isolate its effect. Confirm `FFFIndexTests` still pass and errors still surface.

**Caveats from review** Unreviewed; 300-600 KB is the finder's estimate.

---

### 7. U60 — `panic = "abort"` via a dedicated `xcframework` profile

**Where** `fff-swift/Vendor/fff/Cargo.toml:55-59`.

**Evidence**
```toml
[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
strip = "debuginfo"
```
`rg -n "catch_unwind" crates/fff-c/src crates/fff-core/src` → no matches. Every entry point is a plain `extern "C" fn`; since Rust 1.81 an unwind reaching that boundary aborts anyway.

**Why it costs** Unwind tables (`.eh_frame`/compact-unwind) and unreachable landing-pad cleanup edges are pure size/codegen tax when nothing ever catches a panic across the FFI boundary and Floodlight only ever inspects `FffResult.error`.

**Proposal** Don't touch the shared `[profile.release]` (fff-python/fff-mcp share it and panic=abort changes their semantics). Add:
```toml
[profile.xcframework]
inherits = "release"
panic = "abort"
```
and in `build-xcframework.sh`: `cargo build --package fff-c --profile xcframework --locked --target "$TARGET"`, artifact at `target/$TARGET/xcframework/libfff_c.a`.

**Expected impact** Finder estimates 5-12% of Rust code size for a panic-heavy crate graph, flowing into `deliverable_size_bytes`/`binary_size_bytes`; small secondary codegen win from removed cleanup edges.

**Effort/Risk** S / low. `cargo test` unaffected (test profiles ignore `panic`).

**How to verify on Mac** `ls -l` compare `release` vs `xcframework` profile `.a` sizes; end-to-end `./autoresearch.sh` deltas on `deliverable_size_bytes`/`binary_size_bytes`; sanity `make test` (fff-swift) and `swift test` (Floodlight).

**Caveats from review** Unreviewed — 5-12% is a general Rust heuristic, not measured against this crate graph.

---

### 8. U69 — Build fff-c as staticlib only

**Where** `fff-swift/Vendor/fff/crates/fff-c/Cargo.toml:11-12`.

**Evidence**
```toml
[lib]
crate-type = ["cdylib", "staticlib"]
```
`build-xcframework.sh:26` consumes only `libfff_c.a`.

**Why it costs** `cargo build -p fff-c` compiles both crate types through fat LTO at `codegen-units=1` — the slowest cargo configuration — and the dylib is thrown away. This is the dominant cost of `make build` and the release job, and it is what makes iterating on every other flag in this section slow.

**Proposal**
```sh
cargo rustc --package fff-c --release --locked --target "$TARGET" --crate-type staticlib
```
(`cargo rustc --crate-type`, stable since 1.64, overrides the manifest per-invocation without touching `fff-c/Cargo.toml`, so Node/Bun consumers needing the cdylib elsewhere are untouched.) Add `sccache` to fff-swift CI (mirrors upstream's `mozilla-actions/sccache-action@v0.0.11`). Do not raise `codegen-units` or switch to `--profile ci` (thin LTO) for the shipped artifact — build time isn't the tracked metric, size/latency are.

**Expected impact** Roughly halves XCFramework build wall time — makes the rest of this section's experiments practical to A/B. No shipped-artifact change.

**Effort/Risk** S / low.

**How to verify on Mac** `hyperfine --runs 2 --prepare 'cargo clean --manifest-path Vendor/fff/Cargo.toml' './scripts/build-xcframework.sh'` before/after; confirm `lipo -info`/`ar t` unchanged on the produced `.a`, and no `.dylib` remains in `target/.../release/`.

**Caveats from review** Unreviewed; purely a dev-velocity change, zero shipped-artifact effect claimed.

---

### 9. U73 — Pin exact rustc version; emit BUILDINFO

**Where** `fff-swift/.github/workflows/release.yml:40-43`.

**Evidence**
```yaml
rustup toolchain install stable --profile minimal
rustup default stable
```
`Vendor/fff/rust-toolchain.toml:1-2` says `channel = "stable"`; deps are `--locked` but the compiler floats.

**Why it costs** Two XCFrameworks built from identical sources weeks apart can differ in codegen/size with nothing recorded to explain why — a real cost when `deliverable_size_bytes` is the primary tracked metric. `--profile minimal` also drops `llvm-tools`, which the profiling/PGO work (U70, U72) needs.

**Proposal** Pin a concrete channel in `rust-toolchain.toml` (`channel = "1.90.0"`, keep needed components), drop `rustup default stable` in `release.yml` and let the toolchain file drive, and emit provenance into the artifact:
```sh
rustc -Vv > "$OUTPUT_DIR/BUILDINFO.txt"
echo "features: ${CARGO_FEATURES:-default}" >> "$OUTPUT_DIR/BUILDINFO.txt"
shasum -a 256 "$LIBRARY" >> "$OUTPUT_DIR/BUILDINFO.txt"
```
Add a CI assertion (`lipo -info`, archive-size band vs. previous release) so a mis-built artifact fails loudly.

**Expected impact** No runtime change; makes size/latency deltas between releases attributable, a precondition for treating `autoresearch.sh` metrics as a regression gate.

**Effort/Risk** S / low.

**How to verify on Mac** Build twice from a clean tree, `shasum -a 256` the two `.a`s, confirm they match. `rustc -V` matches the pin. `swift package compute-checksum` stability across two runs.

**Caveats from review** Unreviewed. Depends on U59 for the toolchain pin to actually take effect from the build's cwd.

---

### 10. U59 — Fix `.cargo/config.toml`/`rust-toolchain.toml` discovery

**Where** `fff-swift/scripts/build-xcframework.sh:20`.

**Evidence**
```sh
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
...
cargo build --manifest-path "$VENDOR_DIR/Cargo.toml" --package fff-c --release --locked --target "$TARGET"
```
`fff-swift/Vendor/fff/.cargo/config.toml:1-5` sets macOS `rustflags`; the package root has no `.cargo` directory.

**Why it costs** Cargo discovers `.cargo/config.toml` (and rustup discovers `rust-toolchain.toml`) by walking up from the process cwd, not from `--manifest-path`. `make build` runs with cwd = the fff-swift package root, so the vendored config and toolchain pin are silently never applied — any future `-C target-cpu=...` added there would be a silent no-op with no diagnostic.

**Proposal** Reviewers' preferred fix (safer than `cd`): pass flags through the environment instead of relying on file discovery —
```sh
CARGO_ENCODED_RUSTFLAGS=${CARGO_ENCODED_RUSTFLAGS:-} \
MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0} \
    cargo +stable build --manifest-path "$VENDOR_DIR/Cargo.toml" \
        --package fff-c --release --locked --target "$TARGET"
```
Avoid `cd "$VENDOR_DIR"`: it would newly apply the vendored macOS `-undefined dynamic_lookup` link-args to fff-c's (unused) cdylib target and could fail the build on modern ld64, and it triggers rustup to auto-install `rust-toolchain.toml`'s 5-component list (clippy, rustfmt, llvm-tools, rust-src, rust-analyzer) on every fresh runner. Keep the provenance echo from U73 regardless of which approach is chosen.

**Expected impact** No direct runtime change today (the existing macOS rustflags block only affects a cdylib link nothing consumes). Its value is entirely forward-looking: unblocking `-C target-cpu` (U68) and making the toolchain pin (U73) actually bite.

**Effort/Risk** S / low.

**How to verify on Mac** Add a deliberately invalid flag to the config file, confirm `make build` still succeeds (proving it's ignored) before the fix, then fails after. `CARGO_LOG=cargo::util::config=debug ./scripts/build-xcframework.sh 2>&1 | grep -i config`.

**Caveats from review** Confirmed mechanically by both reviewers, but both substantially downgraded its standalone value: `[profile.release]` keys (opt-level, lto, codegen-units, strip, panic) are manifest settings and already apply — only rustflags-only knobs (`-C target-cpu`) are actually gated on this. Also `Makefile`'s `cargo-test`/`fmt`/`clippy`/`clean` targets have the same discovery gap and are not fixed by this change alone.

---

### 11. U63 — Set `mimalloc` as fff-c's global allocator

**Where** `fff-swift/Vendor/fff/crates/fff-c/src/lib.rs:13` (no `#[global_allocator]` present).

**Evidence** `crates/fff-nvim/src/lib.rs:27-28` and `fff-mcp/src/main.rs:19-20` both set `static GLOBAL: MiMalloc = MiMalloc;`; fff-c does not. Every returned pointer has a matching `fff_free_*` (`include/fff.h:769-881`), and Floodlight uses only those.

**Why it costs** Every fff-c allocation goes through macOS libmalloc, whose nano/scalable zones lock per size class under the multi-threaded burst allocation a 300k-entry scan produces. The `mimalloc-collect` hook (`file_picker.rs:2449-2457`, releases the bigram-build arena back to the OS) is also unreachable without a mimalloc global allocator, so that transient arena stays as RSS for the app's multi-day lifetime.

**Proposal**
```toml
# fff-c/Cargo.toml
mimalloc = { workspace = true }
```
```rust
// lib.rs
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;
```
Safe here because the `mimalloc` crate's default build does not enable libmimalloc-sys's `override` feature — it defines only `__rust_alloc`/`__rust_dealloc` shims, never interposes process-wide `malloc`/`free`; Swift/Foundation/AppKit keep using libmalloc. Enable `fff/mimalloc-collect` alongside the `zlob` feature flip (U57).

**Expected impact** Finder estimates single-digit-percent on per-keystroke result marshalling (~180 `CString` allocs per 60-result page) and a larger win on scan; returns tens of MB of bigram-arena RSS to the OS post-build.

**Effort/Risk** S / medium — must verify no symbol collision before shipping.

**How to verify on Mac**
```sh
nm -gU target/aarch64-apple-darwin/release/libfff_c.a | grep -E ' T _(malloc|free|calloc|realloc|posix_memalign)$'   # must be empty
```
Then `FLOODLIGHT_RUN_INDEX_BENCH=1 swift test -c release --filter testExpandedFFFIndexScanBenchmark`; `footprint -p $(pgrep Floodlight)` 60s after `IndexStartup`, before/after. `cargo bench -p fff-search --bench bigram_bench`.

**Caveats from review** Unreviewed; the symbol-collision check (`researchNeeded` in the finding) must pass before this ships — treat it as a hard gate, not an optional check.

---

### 12. U62 — Pin `fuzzy_search`/`fuzzy_search_mixed` onto `SEARCH_THREAD_POOL`

**Where** `fff-swift/Vendor/fff/crates/fff-core/src/parallelism.rs:1-4,60-64`.

**Evidence**
```rust
//! ... a larger pool is slower on file-heavy work.
pub static SEARCH_THREAD_POOL: LazyLock<rayon::ThreadPool> = ...
```
Only grep installs into it (`file_picker.rs:1380,1411`); `fuzzy_search`/`fuzzy_search_mixed` (`file_picker.rs:1057,1224`) reach `.par_iter()` (`score.rs:953-955`, `index/constraints.rs:221,543`) with no `install(`.

**Why it costs** `fff_search`/`fff_search_mixed` — called after every 15-20 ms debounce — run on rayon's implicit global pool: sized to all logical cores (E-cores included) with no QoS pinning, versus the P-core-sized, QoS-pinned pool grep already uses. The module's own doc comment cites a measured 6.2s→4.9s (~21%) for grep at 16t→13t; the same asymmetry applies to scoring. Also a one-time thread-spawn burst on first keystroke.

**Proposal** Upstream: wrap the scoring entry points the same way grep already is (`SEARCH_THREAD_POOL.install(|| self.fuzzy_search_inner(...))`). Floodlight-side mitigation shippable today, no engine change — cap the global pool in `FFFIndex.start()` before `fff_create_instance_with`:
```swift
var cores: Int32 = 0; var size = MemoryLayout<Int32>.size
sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0)
setenv("RAYON_NUM_THREADS", String(max(2, Int(cores))), 0)
```

**Expected impact** Removes E-core drag/oversubscription from the per-keystroke path; small absolute win for a 12-result page but lands on p95/p99 keystroke latency and energy, and removes the first-keystroke thread-spawn burst.

**Effort/Risk** M / low.

**How to verify on Mac** `sample Floodlight 3 -f /tmp/fl.sample && grep -c 'rayon-' /tmp/fl.sample` (unnamed threads = global pool). Instruments Time Profiler + Points of Interest, 200 keystrokes, with/without `RAYON_NUM_THREADS=12`. `cargo bench -p fff-nvim --bench fuzzy_search --no-default-features --features zlob` with/without the env var. `powermetrics --samplers cpu_power -i 1000` while typing.

**Caveats from review** Unreviewed; the cited 21% is grep's measured number, not scoring's — treat scoring's gain as unconfirmed until benched.

---

### 13. U71 — Add signposts around the FFI boundary and queue wait

**Where** `Sources/FloodlightEngine/Search/FFFIndex.swift:451` (the serializing `perform` bridge).

**Evidence** Existing signposts cover only coarse app events (`IndexStartup`, `ApplicationRefresh/Discovery`, `ShowPanel/HidePanel`, `OpenSelection`); none exist on `search`/`searchFiles`/`searchDirectories`/`searchContent`. The only search timing is offline, on a 2,500-file synthetic fixture (`SearchPerformanceTests.swift:50,207`).

**Why it costs** Nothing measures how long `fff_search_mixed`/`fff_live_grep` actually take on a real home-directory index, or how long a request waits behind another on the single serial queue (`FFFIndex.swift:7`) — which is exactly why the build-flag findings in this section have to be argued from code rather than a trace.

**Proposal**
```swift
private func perform<T>(_ name: StaticString, _ body: @escaping () throws -> T) async throws -> T {
    let enqueued = FloodlightPerformance.begin(name)          // spans queue wait + call
    return try await withCheckedThrowingContinuation { continuation in
        queue.async {
            let running = FloodlightPerformance.begin("FFFCall")
            defer { FloodlightPerformance.end("FFFCall", id: running); FloodlightPerformance.end(name, id: enqueued) }
            ...
        }
    }
}
```
Distinct names from each of the four entry points. `os_signpost` is near-free when unrecorded, so ship enabled. Separately, let `testExpandedFFFIndexScanBenchmark` accept `FLOODLIGHT_BENCH_ROOT` to run against a real directory, not only the 2,500-file fixture.

**Expected impact** No runtime cost; makes every build-flag change in this section measurable on the real workload and exposes queue-wait latency no current metric captures.

**Effort/Risk** S / low.

**How to verify on Mac** `xcrun xctrace record --template 'Points of Interest' --launch .build/Floodlight.app --output /tmp/fl-poi.trace`; type 20-30 queries including a content-search trigger; read the `FFFSearchMixed`/`FFFLiveGrep`/`FFFCall` interval distributions — the gap between outer and inner intervals is queue wait.

**Caveats from review** Unreviewed; purely an observability enabler, no direct perf claim.

---

### 14. U70 — Make `profile.prof` selectable for symbolicated Instruments traces

**Where** `fff-swift/Vendor/fff/Cargo.toml:70-76`; `build-xcframework.sh:22,26` hardcode `--release` and the `release/` output dir.

**Evidence**
```toml
[profile.prof]
inherits = "release"
debug = "full"
strip = false
lto = "thin"
```
already exists but is unreachable from the script.

**Why it costs** The shipped `.a` has `debug = 0` plus `strip = "debuginfo"`, so an Instruments trace of Floodlight shows Swift/AppKit symbolicated and the entire Rust engine (scan/scoring/grep) as raw addresses.

**Proposal**
```sh
PROFILE=${CARGO_PROFILE:-release}
case "$PROFILE" in
    release) PROFILE_FLAG="--release"; PROFILE_DIR=release ;;
    *)       PROFILE_FLAG="--profile $PROFILE"; PROFILE_DIR="$PROFILE" ;;
esac
cargo rustc --package fff-c $PROFILE_FLAG --locked --target "$TARGET" --crate-type staticlib
LIBRARY="$VENDOR_DIR/target/$TARGET/$PROFILE_DIR/libfff_c.a"
```
`CARGO_PROFILE=prof ./scripts/build-xcframework.sh` then produces a symbolicated framework; pair with `swift build -c release -Xswiftc -g`.

**Expected impact** No shipped change. Converts "the engine is slow" into a named function+line — a prerequisite for verifying every other engine-side finding rather than arguing it from source.

**Effort/Risk** S / low. Note `profile.prof` uses thin LTO, so absolute numbers from it aren't release numbers — use for attribution only.

**How to verify on Mac** `dwarfdump --file-stats Vendor/fff/target/aarch64-apple-darwin/prof/libfff_c.a | head` confirms symbols present; `xcrun xctrace record --template 'Time Profiler' --launch .build/Floodlight.app` and confirm frames like `fff_search::score::score_filtered_by_frecency` resolve by name.

**Caveats from review** Unreviewed; purely an enabler.

---

### 15. U68 — Set `-C target-cpu=apple-m1` / `x86-64-v3` explicitly

**Where** `fff-swift/Vendor/fff/.cargo/config.toml:1-5` (link-args only, no target-cpu).

**Evidence** `simd_string_utils/case.rs:126-130` runtime-checks `is_aarch64_feature_detected!("dotprod")`; `index/bigram_filter.rs:604-607` compile-time-gates `normalize_bytes_neon` on `target_feature = "neon"`.

**Why it costs** `eq_lowered_case` — on the 35 ms `fff_live_grep` budget — pays a runtime feature check per call unless the target-cpu is set so the branch const-folds. Nothing in the build records what rustc's default target-cpu for `aarch64-apple-darwin` actually is.

**Proposal** First establish the baseline (`rustc --print cfg --target aarch64-apple-darwin | grep target_feature`) — if `dotprod`/`neon` are already implied by default, this is a no-op guard, not a fix. Otherwise, in `build-xcframework.sh`:
```sh
case "$TARGET" in
  aarch64-apple-darwin) CPU=apple-m1 ;;
  x86_64-apple-darwin)  CPU=x86-64-v3 ;;
esac
export CARGO_BUILD_RUSTFLAGS="-C target-cpu=$CPU"
```
Never use `-C target-cpu=native` for a shipped artifact — it pins the binary to the build machine's core and SIGILLs on older Macs. Requires U59's fix to actually take effect.

**Expected impact** If dotprod is not already default: low single-digit percent on the content-search budget. If already default: zero runtime change, value is purely an explicit, pinned baseline against future rustc default changes.

**Effort/Risk** S / low.

**How to verify on Mac** `rustc --print cfg --target aarch64-apple-darwin | grep target_feature` first — this single command may make the whole finding moot. If absent: `cargo bench -p fff-search --bench memmem_bench` with/without `RUSTFLAGS='-C target-cpu=apple-m1'`; portability gate: run/smoke-launch on an actual M1.

**Caveats from review** Unreviewed. `researchNeeded` in the source finding: confirm rustc's default target-cpu for `aarch64-apple-darwin` before investing further — believed to already be `apple-m1` since Rust 1.71, which would make this a no-op.

---

### 16. U67 — Ship a universal (arm64+x86_64) XCFramework

**Where** `fff-swift/scripts/build-xcframework.sh:7`.

**Evidence** `TARGET=${RUST_TARGET:-aarch64-apple-darwin}`; `release.yml` never sets `RUST_TARGET`. Floodlight/fff-swift both declare `.macOS(.v14)`, which still runs on 2018+ Intel Macs.

**Why it costs** Every published `CFFF.xcframework.zip` contains only an arm64 static library. An Intel user on macOS 14 either can't link the app or gets a non-launching arm64-only binary, with no build-time assertion catching it.

**Proposal** Build both slices and `lipo -create` them (xcodebuild rejects two `-library` args for the same platform):
```sh
for t in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target add "$t"
    ( cd "$VENDOR_DIR" && cargo build --package fff-c --release --locked \
        --no-default-features --features zlob --target "$t" )
done
lipo -create "$VENDOR_DIR/target/aarch64-apple-darwin/release/libfff_c.a" \
             "$VENDOR_DIR/target/x86_64-apple-darwin/release/libfff_c.a" \
             -output "$LIBRARY"
lipo -info "$LIBRARY"   # must print: arm64 x86_64
```
Add `-C target-cpu=x86-64-v3` for the Intel slice (every macOS-14-capable Intel Mac is Haswell+). If Intel support is deliberately out of scope, make that explicit instead (assert `lipo -info` in CI, document arm64-only) rather than leaving it an accident.

**Expected impact** Correctness/coverage on Intel, if in scope at all — per U66's reviewer note, Floodlight's app target may already be arm64-committed elsewhere, which would make this moot. Confirm scope before investing.

**Effort/Risk** M / low. Roughly doubles XCFramework build time and archive size; the shipped app's final slice is unaffected (ld picks one).

**How to verify on Mac** `unzip` a released zip, `lipo -info */libfff_c.a` (currently arm64-only). After: same command must show both. `arch -x86_64 swift build -c release --arch x86_64 && make bundle && open .build/Floodlight.app` on an Intel Mac.

**Caveats from review** Unreviewed. Determine whether Intel support is an actual product requirement before spending M effort here — this is a scope question, not purely a technical one.

---

### 17. U74 — Cross-module optimization / `-enforce-exclusivity=unchecked` split

**Where** `Package.swift:8-15,33-40,42-49`.

**Evidence** Shell target: `.unsafeFlags(["-Osize"])`. Engine target (`FloodlightEngine`, holding `FuzzyMatcher`/`SearchItemRanking`/`ApplicationCatalog.immediatePage`): plain `-O`, chosen independently.

**Why it costs** Every shell→engine call crosses a module boundary with no cross-module inlining, and the engine's `package`-visibility surface (`FloodlightPerformance`, `FFFIndex`, `ApplicationCatalog`) is large. Separately, Swift emits dynamic exclusivity checks (`swift_beginAccess`/`endAccess`) on class stored properties touched every search (`FFFIndex.handle`, `latestSearchGeneration`).

**Proposal** Apply and measure one at a time: (1) `-cross-module-optimization` on `FloodlightEngine` (expect a shell size increase — check against `deliverable_size_bytes` before keeping); (2) `-Osize` on the engine too, judged jointly against both size and latency, since `-Osize` suppresses loop unrolling/specialization the scoring loops may depend on; (3) `-enforce-exclusivity=unchecked` on the engine, gated on `make test-sanitizers` staying green (turns a would-be trap into UB, so this is a real safety trade, not free).

**Expected impact** Low single-digit percent at best per knob, and (1)/(2) push size in opposite directions — value is resolving an unexamined split, not a specific number.

**Effort/Risk** S / medium (mainly from (3)'s safety trade).

**How to verify on Mac** For each variant: `make test-performance` (`fast_application_search_us`, `top_ranked_selection_us`, `fuzzy_matcher_scoring_us`, `source_immediate_snapshot_ms`) and `./autoresearch.sh` (`deliverable_size_bytes`, `search_latency_us`, `selection_latency_us`, `fuzzy_scoring_us`), 3x, medians. For (3) additionally: `make test-sanitizers` green, `nm .build/release/Floodlight | grep -c swift_beginAccess` should drop.

**Caveats from review** Unreviewed and the lowest-confidence item in the section (finder's own confidence 0.55). Treat as an experiment to run only after the higher-leverage items above land.

---

### 18. U72 — Two-stage PGO build for libfff_c.a

**Where** `fff-swift/scripts/build-xcframework.sh:18-24` (single unadorned invocation, no instrumentation stage).

**Evidence** `rust-toolchain.toml:3-9` already pins `llvm-tools` (provides `llvm-profdata`); `Vendor/fff/Makefile:126-131` (`test-c-smoke`) already links a C driver (`crates/fff-c/tests/smoke.c`) against the built library, usable as the profiling workload driver.

**Why it costs** The scoring loop filters on `is_deleted()` (almost always false), the query parser dispatches over constraint kinds Floodlight never uses, and the grep path checks abort-signals/budgets every iteration (effectively never taken within 35 ms) — exactly the branch shape PGO exploits for block layout and inlining. Nothing collects or consumes a profile today.

**Proposal** Opt-in two-stage build gated on `FFF_PGO=1`, using the existing smoke driver:
```sh
# stage 1: instrument + collect
RUSTFLAGS="-Cprofile-generate=/tmp/fff-pgo" cargo build -p fff-c --release --locked --target "$TARGET" --no-default-features --features zlob
cc -O0 -I crates/fff-c/include -L "target/$TARGET/release" crates/fff-c/tests/smoke.c -lfff_c -o /tmp/fff_pgo_driver
/tmp/fff_pgo_driver "$HOME"
# stage 2: merge + rebuild
xcrun llvm-profdata merge -o /tmp/fff-pgo/merged.profdata /tmp/fff-pgo
RUSTFLAGS="-Cprofile-use=/tmp/fff-pgo/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
    cargo build -p fff-c --release --locked --target "$TARGET" --no-default-features --features zlob
```
Check the merged `.profdata` into the repo (or regenerate in the release job) for reproducibility. Extend `smoke.c` to run ~50 `fff_search_mixed` calls plus one `fff_live_grep`, not just a scan, or the profile over-weights the walk. BOLT is not an option on macOS (no Mach-O support) — skip it.

**Expected impact** Typical PGO gains for a branch-heavy search engine: 5-15% on the instrumented workload, compounding with existing fat LTO. Cost: build complexity plus a profile that must be regenerated on material engine changes.

**Effort/Risk** L / medium.

**How to verify on Mac** A/B both variants through `FLOODLIGHT_RUN_INDEX_BENCH=1 FLOODLIGHT_BENCH_ROOT=$HOME swift test -c release --filter testExpandedFFFIndexScanBenchmark` and `swift test -c release --filter PerformanceTests`; engine-level `cargo bench -p fff-search --bench grep_bench --bench bigram_bench --bench memmem_bench` per variant; `hyperfine --warmup 3 --runs 50 '/tmp/fff_pgo_driver $HOME'`; `./autoresearch.sh` since PGO usually grows text slightly.

**Caveats from review** Unreviewed, lowest confidence (0.6) in the whole section. `researchNeeded`: confirm `-Cprofile-generate` composes with `lto = "fat"` + `crate-type = staticlib` on `aarch64-apple-darwin` without requiring the profiling runtime explicitly linked into the C driver (may need `-lclang_rt.profile_osx`). Do this only after the higher-leverage, lower-effort items land.

---

### Rejected ideas

None — no findings were dropped for this section; all 18 (U57-U74) are carried forward above, ranked.

## Upstream: version drift, re-vendoring, and backports

| Rank | ID | Opportunity | Layer | Impact | Effort | Risk | Status | Upstreamable |
|---|---|---|---|---|---|---|---|---|
| 1 | U76 | Watcher dir registration is O(subdirs x depth) `find_or_add_dir` under the picker **write** lock | fff-core | High (multi-hundred-ms lock hold blocks every keystroke search) | M | medium | unreviewed | yes |
| 2 | U77 | Removed `files_to_add.is_empty()` early-return: every empty-dir watcher event now takes the write lock | fff-core | High (per-keystroke latency spikes on any home dir) | S | low | unreviewed | yes |
| 3 | U84 | `include_binary_files` is the largest slice of the vendor delta and a no-op in production | fff-core/fff-swift | Medium (removes ABI divergence risk, 2/3 of delta) | M | low | unreviewed | yes |
| 4 | U78 | Ancestor registration burns the 1024-slot dir overflow budget by path depth -> premature full rescans | fff-core | High when it fires (seconds of rescan + not-ready window) | M | medium | unreviewed | yes |
| 5 | U79 | `add_new_file` propagates ancestor-insert failure with `?`, orphaning dir entries and forcing rescan | fff-core | Medium (correctness + spurious rescans) | S | low | unreviewed | yes |
| 6 | U81 | `is_warmup_complete` dropped from Swift wrapper: content grep can run before the bigram index exists | floodlight | Medium (35ms/keystroke wasted + misleading empty results at launch) | S | low | unreviewed | yes |
| 7 | U80 | Delete Floodlight's 600-line FFFIndex.swift fork; consume FFFKit as a library like upstream floodlight does | fff-swift | Medium (maintenance, dead code, one Bool of real delta) | M | low | unreviewed | yes |
| 8 | U85 | Nine unused C API entries incl. grep pagination cursor and match ranges | floodlight | Medium-High (removes hard ceiling on content-search coverage) | M | medium | unreviewed | no |
| 9 | U75 | `waitForScanCompletion`'s two-idle-poll rule adds a guaranteed 10ms to every start/rebuild/changeScope | floodlight | Low-Medium (small but on the one path the user waits on) | S | low | unreviewed | no |
| 10 | U82 | Re-vendor fff v0.10.6 now while the two deltas are textually disjoint | fff-swift | Low today, prevents future cost | S | low | unreviewed | no |
| 11 | U83 | Both v0.10.6 fff-core fixes are zlob-gated, therefore inert in the shipped (ripgrep) XCFramework | fff-core | None today (documentation/decision-routing only) | S | low | unreviewed | no |
| 12 | U86 | fff-swift CI never builds/tests the zlob feature set; upstream's 0.10.6 regression tests never run | fff-swift | Low direct, unblocks zlob evaluation | S | low | unreviewed | no |
| 13 | U87 | Every filename search opens an LMDB read txn for combo boost even when irrelevant | fff-core | Low (microseconds, but on the serial FFI queue) | S | low | unreviewed | yes |
| 14 | U88 | vmg-dev/floodlight upstream has nothing perf-relevant this fork lacks, except FFFKit-as-library | floodlight | None (closes an open question) | S | low | unreviewed | no |

All findings below are **unreviewed** — the adversarial skeptic pass has not run on this section. Treat magnitude claims as unconfirmed; the code citations and mechanism have been re-verified against the checkouts.

### U76 — Watcher directory registration is O(subdirs x depth) `find_or_add_dir` under the picker write lock

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/watcher/background_watcher.rs:767-793`, `crates/fff-core/src/file_picker.rs:1621-1637`

**Evidence**:
```rust
// background_watcher.rs:767-793
let mut indexed_files = Vec::with_capacity(files_to_add.len());
{
    let Ok(mut guard) = shared_picker.write() else { return subdirs; };
    let Some(ref mut picker) = *guard else { return subdirs; };

    if !picker.handle_directory_create_or_modify(dir) { warn!(...); }
    for subdir in &subdirs {
        if !picker.handle_directory_create_or_modify(subdir) { warn!(...); }
    }
    for path in files_to_add { ... }
}

// file_picker.rs:1621-1637
pub(crate) fn handle_directory_create_or_modify(&mut self, path: &Path) -> bool {
    ...
    push_directory_and_ancestors(&relative_path, &mut ancestors);
    ancestors.into_iter().all(|ancestor| {
        self.sync_data.find_or_add_dir(ancestor)
            .inspect(|&dir_idx| self.sync_data.revive_dir(dir_idx))
            .is_some()
    })
}
```
Confirmed verbatim against the checkout, including the full guard block.

**Why it costs**: One new directory tree (`git clone`, `npm install`, Xcode DerivedData) registers the root plus every discovered subdir, and each registration walks all of that path's ancestors through `find_or_add_dir` -> binary search over the sorted base region + linear scan of the watcher overflow region. The whole loop runs inside `shared_picker.write()`. `fff_search_mixed` takes `inst.picker.read()` (fff-c/src/lib.rs:362), so every keystroke's search blocks behind this write lock while it runs. Upstream v0.10.5 registered no ancestors here at all — this is a Floodlight-only regression risk.

**Proposal**: Hoist deduplication out of the lock:
```rust
let mut wanted: Vec<&str> = subdirs.iter().chain([dir]).flat_map(relative_ancestors).collect();
wanted.sort_unstable();
wanted.dedup();
```
Register only that deduped set inside the guard. Separately, give `FileSync` an `overflow_dir_index: ahash::AHashMap<Box<str>, u32>` maintained by `find_or_add_dir` so the overflow branch is O(1) instead of linear — this also fixes the matching quadratic in `add_new_file`. Upstreamable together with the directory-registration feature.

**Expected impact**: Removes a multi-hundred-ms write-lock hold during bulk directory creation, currently visible as a frozen result list because SourceSearchEngine's 15-20ms debounce fires into a search that then waits on the read lock. Magnitude not yet measured.

**Effort/Risk**: M / medium — touches the hot watcher path and needs a new index structure.

**How to verify on Mac**: `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --release -- watcher`. Direct probe: `cargo run --manifest-path Vendor/fff/Cargo.toml --release -p fff-nvim --bin test_watcher` against a scratch base while `git clone --depth 1 https://github.com/torvalds/linux big-repo` runs inside it, with `cargo run --release -p fff-nvim --bin bench_search_only` looping in another shell. In Floodlight: Instruments os_signpost, subsystem `com.floodlight.app`, interval `IndexedSourceSearch`, record p99 during an `npm install` under the search scope.

**Caveats from review**: None — adversarial review has not run. Confirm the `test_watcher`/`bench_search_only`/`rescan-stats` binaries actually exist in `fff-nvim` before relying on the harness; they were not verified to exist in this pass.

### U77 — Removed early-return makes every directory-only watcher event take the write lock

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/watcher/background_watcher.rs:767` (missing guard), `crates/fff-c/src/lib.rs:362`

**Evidence**:
```rust
// upstream v0.10.5 had, immediately before the write guard:
-    if files_to_add.is_empty() {
-        return subdirs;
-    }
```
The vendored copy has no such check — confirmed: `background_watcher.rs:767` goes straight from computing `subdirs` into `let mut indexed_files = ...; { let Ok(mut guard) = shared_picker.write() ...`.

**Why it costs**: Empty new directories are extremely common under a home-directory scope: `.git/objects/xx`, build caches, DerivedData. Upstream skipped the write lock entirely for those. The vendored copy now acquires the exclusive lock for every one just to call `handle_directory_create_or_modify`, which in the common case finds the directory already registered and does nothing. `parking_lot::RwLock` is not reader-preferring, so a queued writer blocks subsequent readers — a per-keystroke `fff_search_mixed` waits behind it.

**Proposal**: Restore a cheap guard that preserves the new ancestor-registration behavior:
```rust
let needs_write = !files_to_add.is_empty() || {
    let g = shared_picker.read().ok();
    g.and_then(|g| g.as_ref().map(|p| {
        !p.dir_is_registered(dir) || subdirs.iter().any(|d| !p.dir_is_registered(d))
    })).unwrap_or(true)
};
if !needs_write { return subdirs; }
```
Add `pub(crate) fn dir_is_registered(&self, path: &Path) -> bool` next to `should_index_path` (file_picker.rs:1612).

**Expected impact**: Eliminates most watcher write-lock acquisitions on a busy home directory — a class of per-keystroke latency spikes that upstream fff does not have.

**Effort/Risk**: S / low.

**How to verify on Mac**: `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --release -- watcher::rescan_tests new_directory_watcher_test`. Instruments System Trace on Floodlight while `mkdir -p ~/scratch/{1..2000}` runs; check the fff dispatch queue's blocked time and `IndexedSourceSearch` signpost durations.

**Caveats from review**: Unreviewed. The read-then-maybe-write pattern has a TOCTOU window (something else could register the dir between the read check and taking the write lock) — acceptable since `handle_directory_create_or_modify` is idempotent, but call this out explicitly in the PR.

### U84 — `include_binary_files` is the largest piece of the vendor delta and a no-op in production

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2089-2092`; call sites `Sources/FloodlightEngine/Search/FFFIndex.swift:25`, `Sources/FloodlightEngine/Search/ApplicationCatalog.swift:69`

**Evidence**:
```rust
// file_picker.rs:2089-2092 — the only place the option filters anything
if !include_binary_files && !is_git_repo {
    pairs.retain(|(file, _)| !file.is_binary());
    synced_files_count.store(pairs.len(), Ordering::Relaxed);
}
```
```swift
// FFFIndex.swift:25 — main index takes the default (true, matches upstream)
includeBinaryFiles: Bool = true
// ApplicationCatalog.swift:69 — the only `false` call site
includeBinaryFiles: false
```

**Why it costs**: The main index passes `true` — upstream's default, no behavior change. The application catalog passes `false`, but it only indexes empty `<Name>.app` marker files, and `.app` is not a known binary extension, so `pairs.retain` removes nothing and `should_index_path` always returns true regardless. The option changes no observable behavior anywhere in Floodlight today, while costing five hunks in file_picker.rs, three in scan.rs, two in background_watcher.rs, an `FFF_CREATE_OPTIONS_VERSION` bump from 2 to 3, and a new ABI field at offset 83 — a permanent merge obligation and the part of the fork most likely to break on a future upstream options-struct change.

**Proposal**: Pick one. (a) Preferred: PR `include_binary_files` into `dmtrKovalenko/fff`'s `FilePickerOptions` and C options struct as v3, so the vendored delta collapses to zero for this feature and the ABI bump becomes upstream's own. (b) If declined: delete the modification from the vendored copy, drop `FFF_CREATE_OPTIONS_VERSION` back to 2 — the vendor delta then shrinks to the watcher directory-registration change plus the `staticlib` crate-type line, roughly 60 lines that merge trivially forever.

**Expected impact**: Cuts vendored delta by roughly two-thirds; removes the ABI-version divergence.

**Effort/Risk**: M / low.

**How to verify on Mac**: `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --release -- non_git_scan_respects_binary_filename_indexing_option`. Add a temporary assertion in ApplicationCatalog's index that `fff_file_item_get_is_binary` is false for every marker, or run `swift test --filter CatalogTests` before/after flipping `ApplicationCatalog.swift:69` to `true` and confirm identical results. After removal: `make -C fff-swift cargo-test && make -C fff-swift test`, then Floodlight `make test && make test-performance`.

**Caveats from review**: Unreviewed. Confirm no other call site (e.g. a settings index or a future catalog) relies on the filter actually doing something before removing it.

### U78 — Ancestor registration consumes the 1024-slot dir overflow budget by path depth, forcing premature full rescans

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1740-1748`, `constants.rs:21-22`, `file_picker.rs:2187-2191`

**Evidence**:
```rust
// constants.rs:21-22
pub const MAX_OVERFLOW_FILES: usize = 1024;

// file_picker.rs:2187-2191 — files AND dirs each get exactly that many spare slots
files: StableVec::from_vec_with_reserve(files, MAX_OVERFLOW_FILES),
dirs:  StableVec::from_vec_with_reserve(dirs,  MAX_OVERFLOW_FILES),

// file_picker.rs:1740-1748 (Floodlight modification inside add_new_file)
let mut ancestors = Vec::new();
push_directory_and_ancestors(&dir_rel, &mut ancestors);
for ancestor in ancestors {
    let dir_idx = self.sync_data.find_or_add_dir(ancestor)?;
```

**Why it costs**: Upstream consumed at most one overflow dir slot per new file (the leaf parent). This modification consumes up to `depth` slots per new directory, in both `add_new_file` and `handle_directory_create_or_modify`, sharing the same 1024-slot reserve as `ChunkedPathStoreBuilder`. Under a home-directory scope with deep trees (Xcode DerivedData hashes), the dir table exhausts roughly `depth` times sooner. Once `find_or_add_dir` returns `None`, the watcher reads it as `index_update_rejected` and triggers a full rescan of the home directory — seconds of walking plus a fresh bigram build plus the file source going non-ready.

**Proposal**: Two independent mitigations. (a) Skip ancestors that already resolve via `find_dir_index` before touching the builder — the common case is every ancestor but the leaf already exists, so `if self.find_dir_index(a).is_some() { continue; }` costs nothing and stops burning slots. (b) Give dirs their own reserve: `const MAX_OVERFLOW_DIRS: usize = MAX_OVERFLOW_FILES * 4;` used for the `dirs` StableVec and the dir side of the path-store builder. Add a regression test near `watcher_directory_event_registers_directory_and_ancestors` (file_picker.rs:2645) creating 300 depth-8 directories and asserting no rescan.

**Expected impact**: Removes a Floodlight-only cause of full home-directory rescans — each one is seconds of background CPU and a not-ready window.

**Effort/Risk**: M / medium.

**How to verify on Mac**: Build with rescan accounting if the feature exists in the vendored tree (`rg rescan-stats fff-swift/Vendor/fff/crates/*/Cargo.toml` first — not yet confirmed present); otherwise instrument the rescan trigger directly and run a scripted deep-directory-creation loop, comparing rescan counts before/after.

**Caveats from review**: Unreviewed. The `rescan-stats` cargo feature referenced in the finder's harness suggestion was not verified to exist in the vendored `Cargo.toml` — check before relying on it; fall back to logging at the `index_update_rejected` call site if absent.

### U79 — `add_new_file` aborts mid-ancestor-loop with `?`, leaving orphan dir entries and forcing a rescan

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1741-1751`

**Evidence**:
```rust
// vendored file_picker.rs:1741-1751
let mut ancestors = Vec::new();
push_directory_and_ancestors(&dir_rel, &mut ancestors);
for ancestor in ancestors {
    let dir_idx = self.sync_data.find_or_add_dir(ancestor)?;
    self.sync_data.revive_dir(dir_idx);
    if ancestor == dir_rel {
        file_item.parent_dir_index = dir_idx;
    }
}

// upstream v0.10.5 at the same place:
-        if let Some(dir_idx) = self.sync_data.find_or_add_dir(&dir_rel) {
-            file_item.parent_dir_index = dir_idx;
-        }
```

**Why it costs**: Upstream tolerated a failed dir insert — the file was still added with a stale `parent_dir_index`. This version propagates the failure with `?`, so `add_new_file` returns `None` after some ancestors were already appended and revived. The caller reads `None` as `index_update_rejected` and schedules a full rescan; meanwhile the dir table now contains ancestor entries for a file that was never indexed, so directory search can surface a directory whose only content is invisible.

**Proposal**: Don't propagate — register ancestors best-effort, keep upstream's tolerance for the leaf:
```rust
for ancestor in ancestors {
    let Some(dir_idx) = self.sync_data.find_or_add_dir(ancestor) else { break };
    self.sync_data.revive_dir(dir_idx);
    if ancestor == dir_rel { file_item.parent_dir_index = dir_idx; }
}
```
The genuine capacity failure is `self.sync_data.files.push(file_item)` a few lines later, which already returns `None` and is the correct rescan trigger.

**Expected impact**: Removes one spurious full-rescan trigger and one inconsistent-index state, both introduced by the fork.

**Effort/Risk**: S / low.

**How to verify on Mac**: `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --release -- file_picker::tests::watcher_directory_event_registers_directory_and_ancestors dir_index_consistency_test`. Add a test filling the dir overflow to `MAX_OVERFLOW_FILES`, then call `add_new_file` and assert the returned `Option` is `Some` with no orphan ancestor entry.

**Caveats from review**: Unreviewed; pairs naturally with U78's fix since both touch the same loop — implement together.

### U81 — `FFFIndexProgress` drops `is_warmup_complete`, so the first content grep can run before the bigram index exists

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:333-337` (confirmed: `FFFModels.swift:71-78` currently declares only `scannedFiles`, `isScanning`, `isWatcherReady` — no warmup field)

**Evidence**:
```c
// fff.h — the C ABI already carries the field
typedef struct FffScanProgress {
  uint64_t scanned_files_count;
  bool is_scanning;
  bool is_watcher_ready;
  bool is_warmup_complete;
} FffScanProgress;
```
```swift
// FFFModels.swift:71-78 — confirmed, three of four fields read
package let scannedFiles: UInt64
package let isScanning: Bool
package let isWatcherReady: Bool
```
```rust
// file_picker.rs — what the dropped field means
is_warmup_complete: !self.enable_content_indexing
    || self.sync_data.bigram_index.is_some(),
```

**Why it costs**: `is_scanning == false` is set before `run_post_scan` builds the bigram prefilter and before the watcher is installed. SourceSearchEngine fires `contentItems` (`fff_live_grep`, 35ms budget) as soon as the file source is ready, which can be well before the prefilter exists. Without the bigram filter, the grep has no early-exit and spends its whole budget scanning candidates, returning few or no results — the content stage silently produces nothing for the first stretch after launch, and pays 35ms of CPU per keystroke for it.

**Proposal**: Add `isWarmupComplete` to `FFFIndexProgress` and populate it from `progress.pointee.is_warmup_complete`. In `SourceSearchEngine.execute`, gate the content stage on it: skip `contentItems` (and the extra 30ms debounce) while warmup is incomplete, marking `.file` as still pending rather than showing a false "no content matches". Needs no engine change and no re-vendor — the field is already in the shipped 0.2.1 ABI. Mirror the addition in fff-swift's `FFFKit` so the two stay identical after the U80 dedup.

**Expected impact**: Stops burning a 35ms grep budget per keystroke during the post-scan window; removes a misleading empty content section right after launch.

**Effort/Risk**: S / low.

**How to verify on Mac**: Instruments os_signpost, subsystem `com.floodlight.app`, interval `ContentSourceSearch`: launch and type immediately — today expect full-budget 35ms intervals returning 0 matches; after the gate those intervals should not appear until warmup completes. Cross-check with `cargo run --manifest-path Vendor/fff/Cargo.toml --release -p fff-nvim --bin grep_profiler` against a scratch repo with and without a warm bigram index.

**Caveats from review**: Unreviewed. Verify `fff_get_scan_progress`'s struct layout in the actually-linked XCFramework matches `fff.h` exactly (offset/padding) before adding the field — an ABI mismatch here would silently misread adjacent bytes.

### U80 — Delete Floodlight's 600-line FFFIndex.swift fork; consume FFFKit as a library

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:1` (confirmed dead import: `Package.swift:36,73` still declares `.product(name: "FFFKit", package: "fff-swift")`)

**Evidence**:
```swift
// The entire functional delta vs fff-swift 0.2.1's Sources/FFFKit/FFFIndex.swift,
// after ignoring public->package and formatting:
+    private let enableHomeDirectoryScanning: Bool
+        enableHomeDirectoryScanning: Bool = false,
+        self.enableHomeDirectoryScanning = enableHomeDirectoryScanning
-                                options.enable_home_dir_scanning = false
+                                options.enable_home_dir_scanning = self.enableHomeDirectoryScanning

// upstream/floodlight/Sources/Floodlight/Search/FFFIndex.swift is 7 lines:
import FFFKit
typealias FFFIndex = FFFKit.FFFIndex
typealias FFFIndexError = FFFKit.FFFIndexError
typealias IndexedSearchItem = FFFKit.FFFSearchResult
```

**Why it costs**: Floodlight duplicates the whole FFFKit wrapper (~750 lines across FFFIndex.swift + FFFModels.swift) to gain one Bool, while `Package.swift` still links the FFFKit product that is never imported by FloodlightEngine — dead code in the linked binary, and `public` FFFKit types shadow Floodlight's `package` ones inside test targets that do import FFFKit. Every future fff-swift change requires a hand-port.

**Proposal**: 1) Land `enableHomeDirectoryScanning: Bool = false` and its test file in `vmg-dev/fff-swift`, cut release 0.2.2. 2) In Floodlight, bump to `from: "0.2.2"`, delete the FFFIndex class and FFFModels DTOs, keep only `FFFFileSource` + the `SourceSearchEngine` convenience init, add `import FFFKit` and the typealiases upstream uses. 3) Update `scripts/check-architecture.sh`'s note about the shell importing FFFKit.

**Expected impact**: Removes ~750 duplicated lines and a permanent hand-merge cost; removes one dead copy of the wrapper from the linked binary.

**Effort/Risk**: M / low.

**How to verify on Mac**: In fff-swift: `make cargo-test && make test` (builds XCFramework, runs `swift test`), confirm the new home-directory-scanning test passes. In Floodlight after the swap: `make check && make test && make test-performance`, diff FLOODLIGHT_BENCH lines against the pre-change run. `swift build -c release && ls -l .build/release/Floodlight` for the size delta.

**Caveats from review**: Unreviewed. Confirm no other Floodlight code path relies on a `public`-vs-`package` visibility difference between the two currently-separate type sets before merging them.

### U85 — Nine useful C API entry points are already shipped and unused, including grep pagination and match ranges

**Where**: `fff-swift/Vendor/fff/crates/fff-c/include/fff.h` (grep result/match accessors); `Sources/FloodlightEngine/Search/FFFIndex.swift:352-367`

**Evidence**:
```c
uint32_t fff_grep_result_get_next_file_offset(const struct FffGrepResult *r);
// "Pass as `file_offset` to a subsequent fff_live_grep/fff_multi_grep call to continue pagination."
uint32_t fff_grep_result_get_filtered_file_count(const struct FffGrepResult *r);
uint32_t fff_grep_result_get_total_matched(const struct FffGrepResult *r);
const char *fff_grep_result_get_regex_fallback_error(const struct FffGrepResult *r);
uint32_t fff_grep_match_get_match_ranges_count(const struct FffGrepMatch *m);
uint32_t fff_grep_match_get_col(const struct FffGrepMatch *m);
```

**Why it costs**: Floodlight's content stage runs `fff_live_grep` with a hard 35ms budget and discards everything the engine reports about that budget. `next_file_offset` is the engine's own resume cursor — when the budget expires mid-index it says exactly where to continue. Today a second keystroke restarts from file 0, so a large scope can never surface results past whatever fits in the first 35ms. `match_ranges`/`col` would let the UI highlight matches without a Swift-side re-scan; `regex_fallback_error` is the only signal that the engine silently degraded a regex to a literal.

**Proposal**: Extend `FFFIndex.searchContent` to return the cursor and let `SourceSearchEngine` continue it:
```swift
struct FFFContentPage { let matches: [FFFContentMatch]; let nextFileOffset: UInt32; let totalMatched: UInt32 }
```
Pass `fileOffset` into `fff_live_grep`'s file_offset argument instead of a hard-coded 0; keep the cursor keyed by the pending search token so a later stage for the *same* query resumes rather than restarts; cancel it whenever the normalized query changes. Separately carry `matchRanges` on `FFFContentMatch` for highlight-without-rescan.

**Expected impact**: Turns the 35ms budget from a hard ceiling on how much of the index is ever searched into a per-slice budget — the difference between "content search works on ~/src" and "content search works on ~".

**Effort/Risk**: M / medium.

**How to verify on Mac**: Engine side: `cargo run --manifest-path Vendor/fff/Cargo.toml --release -p fff-nvim --bin grep_profiler` and `--bin bench_grep_query` against a large scratch repo, checking files-covered-per-35ms-slice vs `filtered_file_count`. Floodlight side: Instruments os_signpost interval `ContentSourceSearch` — count matches per query on a home-directory scope before/after; add a FLOODLIGHT_BENCH line for matches-per-35ms.

**Caveats from review**: Unreviewed. **Open question carried from the finder**: is `next_file_offset` stable across index mutations — if the watcher adds or tombstones files between two paginated calls, does the offset skip or repeat files? Verify before shipping pagination (see research prompts).

### U75 — `waitForScanCompletion`'s two-idle-poll rule adds a guaranteed 10ms to every start/rebuild/changeScope

**Where**: `Sources/FloodlightEngine/Search/FFFIndex.swift:678-687` (confirmed verbatim against the checkout)

**Evidence**:
```swift
// FFFIndex.swift:677-687
private func waitForScanCompletion() async throws {
    var consecutiveIdlePolls = 0
    while consecutiveIdlePolls < 2 {
        try Task.checkCancellation()
        let progress = try await index.progress()
        consecutiveIdlePolls = progress.isScanning ? 0 : consecutiveIdlePolls + 1
        if consecutiveIdlePolls < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
```
```rust
// fff-core/src/file_picker.rs:955-961 — the race this guards against is already closed:
// "(e.g. lua `wait_for_initial_scan` after `restart_index_in_path`) that grab the signal
//  Arc between publish and spawn would otherwise observe scanning=false and skip the wait"
signals.scanning.store(true, std::sync::atomic::Ordering::Release);
```

**Why it costs**: The two-consecutive-idle-polls rule defends against observing `is_scanning == false` before the background scan thread flips it true. That race cannot happen here: `spawn_background_threads` stores `scanning = true` with Release ordering synchronously, before publishing the picker and before `ScanJob::spawn` stores it again. By the time `fff_create_instance_with`/`fff_restart_index` returns to Swift, `is_scanning` is already true — the second poll never observes a different value than the first. It is a pure 10ms `Task.sleep` on the critical path of `start()`, `changeScope()`, and `rebuild()`; `changeScope` pays it twice on the error path (rollback + second wait).

**Proposal**: `while try await index.progress().isScanning { try await Task.sleep(for: .milliseconds(5)) }`. Drop the inconsistent 200-iteration variant in `ApplicationCatalog.start()` (line 116) in favor of the same helper with a real timeout instead of an iteration count. Do **not** replace with `fff_wait_for_scan` — `SharedPicker::wait_for_scan` is itself a blocking 10ms `poll_until`, and calling it on FFFIndex's serial DispatchQueue would block every other FFI call for the whole scan.

**Expected impact**: Removes a guaranteed 10ms from cold start, every scope change, and every rebuild; halves the poll count. Small in absolute terms but pure dead time on the path the user waits on.

**Effort/Risk**: S / low.

**How to verify on Mac**: Instruments -> Blank template + os_signpost, subsystem `com.floodlight.app`, category Points of Interest, interval `IndexStartup`. Record app launch before/after; compare duration. Also `make test-performance`, read FLOODLIGHT_BENCH lines. For an end-to-end number, time `FFFFileSource.start()` in a release `swift test -c release --filter FFFIndexTests`.

**Caveats from review**: Unreviewed. The race-is-closed claim rests on the ordering guarantee documented at `file_picker.rs:955-961`; re-confirm that comment still describes the current store ordering before relying on it, since Release-ordering reasoning is easy to invalidate with an unrelated refactor.

### U82 — Re-vendor fff v0.10.6 now: the two deltas touch disjoint code

**Where**: `fff-swift/Vendor/fff/UPSTREAM.md:1-5` (confirmed: pins v0.10.5 at commit `459ebcdbdba094843fe5339a1a7f7dae4ced2d82`)

**Evidence**:
```
// UPSTREAM.md:3-4
This directory vendors FFF version 0.10.5 at commit `459ebcdbdba094843fe5339a1a7f7dae4ced2d82`.

// git diff v0.10.5..HEAD --stat -- crates/fff-core crates/fff-c (upstream side):
crates/fff-c/Cargo.toml                | 6 +-
crates/fff-core/Cargo.toml             | 2 +-
crates/fff-core/src/file_picker.rs     | 14 +-   (FileItem::new_from_walk_bytes only)
crates/fff-core/src/index/bigram_filter.rs | 3 +-
crates/fff-core/src/index/constraints.rs   | 11 +-
crates/fff-core/src/walk/zlob.rs           | 20 +-
```

**Why it costs**: The drift is 6 commits and the two trees do not overlap textually — upstream's `file_picker.rs` change is confined to `FileItem::new_from_walk_bytes`, which has zero callers in the vendored tree; Floodlight's `file_picker.rs` changes are in `FilePickerOptions`, `FilePicker`, `add_new_file`, `collect_files`, and tests. `constraints.rs`, `bigram_filter.rs`, and `walk/zlob.rs` are untouched by Floodlight. The only adjacency is `crates/fff-c/Cargo.toml`, where upstream bumps three version strings and Floodlight edited the `crate-type` line four lines above. Waiting only makes the merge strictly worse.

**Proposal**:
```bash
cd fff-swift
git subtree pull --prefix Vendor/fff https://github.com/dmtrKovalenko/fff v0.10.6 --squash
# resolve the single adjacency in crates/fff-c/Cargo.toml: keep
#   crate-type = ["cdylib", "staticlib"]
# and take upstream's 0.10.6 version strings; re-apply emptied CLAUDE.md if desired
make cargo-test && make test
```
Update `UPSTREAM.md` to name v0.10.6 and its commit, note `zlob = "=1.6.5"` is now required. Add a CI job failing when the pinned commit falls more than N commits behind `dmtrKovalenko/fff` main.

**Expected impact**: Zero runtime change today (see U83) but retires drift at its cheapest point and aligns the vendored copy with the zlob version upstream tests against.

**Effort/Risk**: S / low.

**How to verify on Mac**: `make -C fff-swift cargo-test` (`cargo test --manifest-path Vendor/fff/Cargo.toml --package fff-search --package fff-c --locked`), then `make -C fff-swift test` (rebuilds XCFramework, runs `swift test`). The two new upstream test files (`invalid_utf8_paths.rs`, `dotdir_glob_constraint_test.rs`) come with the pull, both zlob-gated: run with `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --no-default-features --features zlob` (needs zig 0.16).

**Caveats from review**: Unreviewed.

### U83 — Both v0.10.6 fff-core fixes are zlob-gated and inert in the ripgrep-built XCFramework

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/index/constraints.rs:151`; `crates/fff-c/Cargo.toml:15`; `scripts/build-xcframework.sh:19-24`

**Evidence**:
```rust
// upstream 973c859 adds, guarded:
#[cfg(feature = "zlob")]
const GLOB_FLAGS: zlob::ZlobFlags = zlob::ZlobFlags::RECOMMENDED.union(zlob::ZlobFlags::PERIOD);
// only compile_one/match_glob_pattern under #[cfg(feature = "zlob")] consume it

// crates/fff-c/Cargo.toml / fff-core/Cargo.toml
default = ["ripgrep"]
// scripts/build-xcframework.sh passes no --features, so ripgrep ships.
```

**Why it costs**: Treating the non-UTF-8-path fix and the dot-directory glob fix as correctness gaps in Floodlight is wrong — neither path is compiled into the shipped XCFramework. The ripgrep walker computes its basename offset from the already-decoded `to_string_lossy()` string, so the U+FFFD offset bug cannot occur there; glob constraints go through `globset::GlobMatcher`, which has no fnmatch leading-dot rule. The 0.10.5->0.10.6 drift buys nothing on its own — the decision that matters is which walker ships.

**Proposal**: Record this in `UPSTREAM.md` under a "What the vendored feature set actually builds" section naming `default = ["ripgrep"]` and the zlob-only modules. Treat the 0.10.6 merge as hygiene (U82) rather than a bug fix; evaluate zlob on its own merits separately (U86 unblocks that evaluation).

**Expected impact**: Prevents spending a release cycle backporting fixes that cannot execute; redirects effort to the walker decision.

**Effort/Risk**: S / low.

**How to verify on Mac**: `cargo build --manifest-path Vendor/fff/Cargo.toml -p fff-c --release 2>&1 | rg zlob` returns nothing; `nm -gU Vendor/fff/target/aarch64-apple-darwin/release/libfff_c.a | rg -i zlob` is empty. Compare with `cargo build -p fff-c --release --no-default-features --features zlob`.

**Caveats from review**: Unreviewed.

### U86 — fff-swift CI never builds or tests the zlob feature set

**Where**: `fff-swift/Makefile:6-14`

**Evidence**:
```makefile
# fff-swift/Makefile:6-14 — one feature set only
cargo-test:
	cargo test --manifest-path Vendor/fff/Cargo.toml --package fff-search --package fff-c --locked
lint:
	cargo clippy --manifest-path Vendor/fff/Cargo.toml --package fff-search --package fff-c --all-targets -- -D warnings

# upstream Vendor/fff/Makefile:98
test-rust: cargo test --no-default-features --features zlob
```

**Why it costs**: The vendored copy is only ever compiled/tested in the default (ripgrep) configuration — the opposite of what upstream tests. The zlob half of the vendored source rots undetected across re-vendors, clippy never lints the zlob arms, and it makes the zlob switch look riskier than it is because nobody has run those paths here.

**Proposal**:
```makefile
cargo-test-zlob:
	cargo test --manifest-path Vendor/fff/Cargo.toml --package fff-search --package fff-c \
		--no-default-features --features zlob --locked
```
Add a matching clippy invocation; wire a zig install step into CI running both feature sets. Bundle with the U82 re-vendor so the two new upstream test files start executing immediately.

**Expected impact**: Prevents silent rot in half the vendored engine; removes the main non-technical objection to adopting zlob.

**Effort/Risk**: S / low.

**How to verify on Mac**: `brew install zig` (0.16), `make -C fff-swift cargo-test-zlob`. Expect both new upstream tests to run: `cargo test --manifest-path Vendor/fff/Cargo.toml -p fff-search --no-default-features --features zlob -- invalid_utf8 dotdir_glob`. Confirm ripgrep set still passes with `make -C fff-swift cargo-test`.

**Caveats from review**: Unreviewed.

### U87 — Every filename search opens an LMDB read transaction for combo boost, even when irrelevant

**Where**: `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1092-1105`; `crates/fff-core/src/query_tracker.rs:331-354`; call sites `Sources/FloodlightEngine/Search/FFFIndex.swift:126,201`

**Evidence**:
```rust
// file_picker.rs:1092-1105 — unconditional, on every fuzzy_search
let last_same_query_entry = query_tracker
    .zip(options.project_path)
    .and_then(|(tracker, project_path)| {
        tracker.get_last_query_entry(query.raw_query, project_path, options.min_combo_count)
            .ok().flatten()
    });
// query_tracker.rs:331-354 — opens a fresh read txn + hashes a key per search
let query_key = Self::create_query_key(project_path, query)?;
let rtxn = self.env.read_txn()...
```
```swift
// FFFIndex.swift:126, 201 — Floodlight passes the defaults explicitly
fff_search_mixed(handle, $0, nil, 0, 0, limit, 100, 3)
fff_search(handle, $0, nil, 0, 0, limit, 100, 3)
```

**Why it costs**: Floodlight runs two FFF instances (two LMDB history environments) and issues up to three searches per keystroke stage. Each pays a key hash plus an LMDB read-transaction open/close before any matching starts, on the serial dispatch queue everything else waits on. The lookup is pure overhead when `combo_boost_score_multiplier` is 0, and near-pure overhead for the application catalog, where the same handful of markers are selected repeatedly and frecency already covers ranking.

**Proposal**: Guard upstream: `if options.combo_boost_score_multiplier != 0 { ... }` around the `last_same_query_entry` computation in `fuzzy_search` and its directory/mixed twins. Have Floodlight pass `0` as `combo_boost_multiplier` for `ApplicationCatalog`'s `searchFiles` call, keeping 100 for the main file index. Small, obviously-correct upstream patch that also benefits fff-nvim's own paging calls (`fff-c/src/lib.rs:453,517` already pass 0 there and still pay the lookup).

**Expected impact**: Removes one LMDB read transaction per application-catalog search — one per keystroke on the indexed stage. Microseconds each, but sits directly in front of the debounced search on the serial FFI queue.

**Effort/Risk**: S / low.

**How to verify on Mac**: `cargo bench --manifest-path Vendor/fff/Cargo.toml -p fff-nvim --bench query_tracker` isolates the tracker cost; `cargo bench -p fff-nvim --bench fuzzy_search -- search` gives the end-to-end delta with/without the guard. In Floodlight, Instruments os_signpost interval `IndexedSourceSearch` over the 8-query set used by SearchPerformanceTests, and the existing `fast_application_search_us` FLOODLIGHT_BENCH line from `make test-performance`.

**Caveats from review**: Unreviewed; confidence on this one is already lower (0.6) in the source finding — the microsecond-scale claim needs the bench numbers before treating it as more than speculative.

### U88 — vmg-dev/floodlight upstream holds nothing perf-relevant this fork lacks, except FFFKit-as-library

**Where**: `Package.swift:26` (fork); upstream `floodlight` repo `Package.swift:1,20-25`, `Makefile:12-14`

**Evidence**:
```
// upstream/floodlight: git log --oneline -8
d5eed30 Fix home indexing and login startup (#4)

// upstream Makefile:12-14 — the whole test story
test:
	swift test --package-path Vendor/fff-swift
	swift test
```
diff -rq Sources: upstream has 5 files under `Sources/Floodlight/Search`; the fork has a full `Sources/FloodlightEngine` tree plus 14 additional shell files.

**Why it costs**: N/A — this is a closing-the-question item, not a cost. The fork is far ahead on the FloodlightEngine/shell split, `-Osize`, `-dead_strip_dylibs`, ASCII/character-mask app search, the FLOODLIGHT_BENCH latency gate, sanitizer targets, architecture checks. Upstream has none of it. The one structural idea worth taking back is already covered by U80: consume FFFKit as a library with a thin typealias shim instead of duplicating the wrapper.

**Proposal**: Record in `CONTEXT.md` that the upstream comparison was done at commit `d5eed30` and the only adopted idea is the FFFKit-as-library structure (folded into U80). If the fork intends to keep diverging, consider dropping the upstream remote so future audits don't re-run this comparison; if it intends to contribute back, the FloodlightEngine split and the perf gate are the two things worth a PR.

**Expected impact**: No runtime effect; retires an open question that otherwise costs a comparison pass every audit cycle.

**Effort/Risk**: S / low.

**How to verify on Mac**: `diff -rq <upstream>/Sources <fork>/Sources` and `diff -u` the two `Package.swift` files; confirm the fork's `make test-performance` has no upstream counterpart.

**Caveats from review**: Unreviewed.

### Rejected ideas

None — no opportunities in this section's input were dropped.

