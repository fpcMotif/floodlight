# Floodlight Search Pipeline Architecture

## Summary

User text input travels through `SearchCoordinator` (@MainActor) on the main thread. Immediate text-based searches run synchronously; async FFF content search waits 35–180 ms based on whether apps match, runs on background Tasks, and calls `FFFKit.FFFIndex.search()` and `FFFKit.FFFIndex.searchContent()` APIs. Timing is instrumented via `os_signpost` at 8 named points. Headless testing is feasible: `SearchCoordinator` is separable from SwiftUI views; async/await APIs let test harnesses await results without the UI.

---

## Query Pipeline: Input → Ranked Results

### 1. Entry Point: User Types in Text Field
**File**: `Sources/Floodlight/UI/SearchView.swift:31–40`  
**Mechanism**: `FloodlightTextField` updates `SearchCoordinator.query` as user types.

### 2. Main Search Orchestrator
**File**: `Sources/Floodlight/Search/SearchCoordinator.swift:8–9` (class declaration)  
**Threading**: `@MainActor` — all updates marshal to main thread via `DispatchQueue.main.async` (line 15).

**Pipeline stages in `scheduleSearch()` (line 404–532)**:

#### Stage A: Immediate Results (Synchronous, ~0–10 ms)
Lines 424–439:
- **Application Catalog Fast Search**: `ApplicationCatalog.fastSearchPage(query)` — in-memory fuzzy matching on normalized app names, **no FFF calls**
- **System Settings Search**: `SystemCatalog.searchPage(query)` — in-memory fuzzy matching on setting names
- **Results published immediately** (line 430–438)
- **Signpost**: `"ImmediateSearch"` (lines 405, 420, 439)

#### Stage B: Time-Budgeted Async Search (Background Task)
Lines 441–532 — wrapped in `searchTask: Task<Void, Never>`:

**Debounce** (lines 444–446):
```swift
let debounce = immediateApps.isEmpty ? 35 : 180
try? await Task.sleep(for: .milliseconds(debounce))
```
- **35 ms** — when no immediate app matches (sparse immediate results, search immediately)
- **180 ms** — when app is already visible (wait to see if user refines query)

**Concurrent File & App Index Searches** (lines 463–466):
```swift
async let indexed = searchIndexedFiles(requestQuery)
async let applications = searchIndexedApplications(requestQuery)
let fffItems = try await indexed
let apps = try await applications
```

**FFFKit API Calls**:
- **File Index Search** (line 540): `try await index.search(query)` → `FFFKit.FFFIndex.search(query)` → returns `[FFFKit.FFFSearchResult]`
- **Application Index Search** (line 548): `try await applicationCatalog.search(query)` → calls `index.searchFiles(query, limit:)` → `FFFKit.FFFIndex.searchFiles(query, limit:)` on a secondary FFF index (ApplicationCatalog line 132)
- **Signposts**: `"FileIndexSearch"` (line 536), `"ApplicationIndexSearch"` (line 544), `"IndexedSearch"` (line 450)

**Results merged and published** (lines 471–481).

#### Stage C: Time-Budgeted Content Search (Conditional, ~0–200 ms)
Lines 483–517:

**Conditions to trigger** (line 485):
- Query length ≥ 3 characters
- File index returned < 12 results
- User hasn't cancelled (not `Task.isCancelled`)

**Debounce**: 120 ms after indexed results (line 483)

**FFFKit Content API Call** (line 490):
```swift
let contentItems = try await index.searchContent(requestQuery)
```
→ `FFFKit.FFFIndex.searchContent(query)` — searches file contents, returns `[FFFKit.FFFContentMatch]`

**Signpost**: `"ContentSearch"` (line 486)

### 3. Result Building & Publication
**File**: `Sources/Floodlight/Search/SearchCoordinator.swift:551–631`

**Stages**:
1. **Calculator** (line 559–570): Arithmetic evaluation
2. **Command Catalog** (line 573): Floodlight shortcuts
3. **Apps & Settings** (line 574–575): From immediate + async searches
4. **Indexed Files** (line 576): FFF file results
5. **Content Matches** (line 512): File content search results (optional)
6. **Deduplication & Scoring** (line 578–586): Merge by ID, sort by score (descending), then title
7. **Web Fallback** (line 588–601): Appended if query is non-empty, shown last (score `Int.min`)
8. **Truncation** (line 603): First 80 items published

---

## Time Budgets & Constants

**File**: `Sources/Floodlight/Search/SearchCoordinator.swift:445–446`

| Condition | Delay | Purpose | Source |
|-----------|-------|---------|--------|
| No immediate app match | 35 ms | Content search has time; user likely needs results | Line 445 |
| App already visible | 180 ms | Wait for query refinement; avoid thrashing | Line 446 |
| After indexed results | 120 ms | Debounce before content search | Line 483 |

**README mention**: "time-budgeted FFF content search" (README.md line 20)  
**Detailed explanation**: README.md lines 119–121 states file search waits 35 ms (no app) or 180 ms (app visible), and stale generations are discarded.

---

## Threading & Actors

**Main Thread (UI updates)**:
- `SearchCoordinator` is `@MainActor` (line 6)
- All state updates (`query`, `results`, `isSearching`) happen on main
- Panel height changes marshalled via `DispatchQueue.main.async` (line 15)

**Background Tasks**:
- File index scan runs on its own queue (`DispatchQueue` managed by FFFKit)
- Application catalog discovery runs on `discoveryQueue` (ApplicationCatalog.swift line 15–18)
- Async search runs in `Task { ... }` spawned from main but executes in default async context (Concurrency Actor isolation, not DispatchQueue)

**Application Catalog Threading** (ApplicationCatalog.swift):
- Discovery: `DispatchQueue(label: "com.floodlight.application-catalog", qos: .userInitiated)`
- App index: Runs `index.start()` and `index.rescan()` via Tasks (lines 93–94)
- Fast search: Synchronous, snapshot-based (lines 162–196) — no background thread

**System Catalog Threading** (SystemCatalog.swift):
- Discovery: `Task.detached(priority: .utility)` (line 269)
- Search: Synchronous (lines 342–395)

---

## Timing Instrumentation: Existing Signposts

**File**: `Sources/Floodlight/Utilities/FloodlightPerformance.swift:1–23`

**Mechanism**: Uses `os_signpost()` from `<os/signpost.h>` with category `.pointsOfInterest`:
```swift
static func begin(_ name: StaticString) -> OSSignpostID
static func end(_ name: StaticString, id: OSSignpostID)
static func event(_ name: StaticString)
```

**Named signposts in SearchCoordinator** (8 total):
1. `"ImmediateSearch"` — Line 405, 420, 439 (immediate app + settings)
2. `"IndexedSearch"` — Line 450, 454, 480 (file + app index search)
3. `"ContentSearch"` — Line 486, 488 (file content search)
4. `"FileIndexSearch"` — Line 536, 538 (FFF file index.search)
5. `"ApplicationIndexSearch"` — Line 544, 546 (FFF app index.searchFiles)
6. `"OpenSelection"` — Line 370, 377, 385 (workspace.open)
7. `"IndexStartup"` — Line 126, 128 (index.start during startup)

**Other signposts**:
- `"ApplicationRefresh"` (ApplicationCatalog.swift line 80, 90)
- `"ApplicationDiscovery"` (ApplicationCatalog.swift line 111, 118)
- `"ShowPanel"` / `"HidePanel"` (FloodlightPanel.swift)

**Capture method**: Connect Instruments.app → Points of Interest, or monitor via `log stream --level info --predicate 'subsystem == "com.floodlight.app"'`.

---

## Headless Testing: Seams for Bench Entry Point

### SearchCoordinator Separation from UI
**File**: `Sources/Floodlight/Search/SearchCoordinator.swift:6–113`

**Key property**: `SearchCoordinator` is `@Observable` (line 7) and can be instantiated without the UI:
```swift
let coordinator = SearchCoordinator()
try await coordinator.index.start()
try await coordinator.applicationCatalog.start()
await SystemCatalog.start()
coordinator.query = "test"
```

**Missing**: No public async API to await search results directly. `searchTask` is private; results are published via `@Observable` state mutations.

### Workaround: Async Testing
**File**: `Tests/FloodlightTests/SearchPerformanceTests.swift:56–123`

Already demonstrates **headless search logic**:
- No SwiftUI, no UI
- Measures filter logic, system catalog, and fast app search CPU
- Can be extended to measure indexed search timing

### Proposed Headless Entry Point
1. Add public async method to `SearchCoordinator`:
   ```swift
   func performSearch(_ query: String) async -> [SearchItem]
   ```
2. Internally: spawn `searchTask`, wait for completion via state observation or completion callback
3. Or: Expose a static function that creates a test harness (see `SearchPerformanceTests` for pattern)

### Current Measurable Seams
- `ApplicationCatalog.fastSearch(query)` — Synchronous in-memory search (no FFF)
- `ApplicationCatalog.search(query)` — Async, calls FFF index
- `SystemCatalog.searchPage(query)` — Synchronous, in-memory
- `FFFIndex.search(query)` — Async, direct FFF call
- `FFFIndex.searchContent(query)` — Async, FFF content search

All callable without views; results returned or awaited directly.

---

## Existing Performance Tests

**File**: `Tests/FloodlightTests/SearchPerformanceTests.swift`

### Test 1: Fast Application Search Performance
- **Method**: `testFastApplicationSearchPerformanceBudget()` (line 7–54)
- **What**: Measures `ApplicationCatalog.fastSearch(query)` — in-memory fuzzy match
- **Budget**: < 1 ms per query
- **Output**: `FLOODLIGHT_BENCH fast_application_search_us=<µs> results=<count>`

### Test 2: Filter & Settings Performance
- **Method**: `testNewSearchFeaturePerformanceBaselines()` (line 56–123)
- **What**: Measures filter counting and system settings search
- **Budgets**: Each < 1 ms per query
- **Output**: `FLOODLIGHT_BENCH filter_summary_us=<µs> filter_switch_cycle_us=<µs> settings_search_us=<µs>`

### Test 3: FFF Index Scan Benchmark (Optional, Requires Env Var)
- **Method**: `testExpandedFFFIndexScanBenchmark()` (line 125–177)
- **Trigger**: `FLOODLIGHT_RUN_INDEX_BENCH=1`
- **What**: Creates 2,500 temp files, measures FFF scan time
- **Output**: `FLOODLIGHT_BENCH expanded_fff_scan_ms=<ms> indexed_files=<count>`

### Utilities
- `measure()` (line 179–197): Measures query search time via `clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`
- `measureCPU()` (line 210–224): CPU time measurement for repeated operations
- `median()` (line 199–202): Statistical median of samples

---

## Summary Table: API Call Flow

| Stage | Caller | FFF API Called | Returns | Thread | Signpost |
|-------|--------|---|---|---|---|
| Immediate | `SearchCoordinator.scheduleSearch()` | None (app fuzzy, system search) | In-memory | Main | ImmediateSearch |
| Debounce | Task (line 446) | — | — | Async | — |
| File Index | `searchIndexedFiles()` | `FFFIndex.search(query)` | `[FFFSearchResult]` | Async | FileIndexSearch, IndexedSearch |
| App Index | `searchIndexedApplications()` | `FFFIndex.searchFiles(query)` | `[FFFSearchResult]` | Async | ApplicationIndexSearch, IndexedSearch |
| Content (if sparse) | `index.searchContent()` | `FFFIndex.searchContent(query)` | `[FFFContentMatch]` | Async | ContentSearch |

---

## FFFKit Dependency

**File**: `Package.swift:14–17`

```swift
.package(
    url: "https://github.com/vmg-dev/fff-swift",
    from: "0.1.0"
)
```

**Type aliases** (FFFIndex.swift):
- `FFFIndex` = `FFFKit.FFFIndex`
- `IndexedSearchItem` = `FFFKit.FFFSearchResult`
- `IndexedContentItem` = `FFFKit.FFFContentMatch`

---

## Bench Harness Checklist

✓ **Timing hooks**: os_signpost via FloodlightPerformance; capture in Instruments or via `log stream`  
✓ **Headless seams**: FFFIndex, ApplicationCatalog, SystemCatalog callable without UI  
✓ **Existing perf tests**: SearchPerformanceTests with CPU time measurement utilities  
✓ **Time budget constants**: 35 ms / 180 ms debounce, 120 ms content debounce (SearchCoordinator.swift:445–446, 483)  
✓ **Threading model**: @MainActor, background Task concurrency, DispatchQueue for catalog discovery  
✓ **Result deduplication**: By SearchItem.id; supports multi-source merging  

To build a headless bench:
1. Instantiate `SearchCoordinator` without UI
2. Call `.index.start()`, `.applicationCatalog.start()`, `SystemCatalog.start()`
3. Observe signposts via Instruments or instrument FFFIndex calls directly
4. Extend SearchPerformanceTests to measure full pipeline, or create new bench harness that awaits `searchTask` completion
