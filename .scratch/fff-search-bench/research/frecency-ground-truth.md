# Frecency & Query History Ground Truth Research

## Summary

Floodlight/FFF persist **both** frecency scores and query history on disk, stored in two places:
1. **RecentStore** (UserDefaults): item popularity via launch counts and last-opened timestamps
2. **FFFKit's LMDB databases**: query history and frecency scores managed by the underlying FFF engine

**(Query → result opened)** pairs **CAN be extracted**, but only from FFFKit's databases, not Floodlight's local storage. The extraction requires reading LMDB files or using FFFKit's public API methods (not currently exposed to Floodlight code, but available in the Rust binary).

---

## Storage Locations

### 1. RecentStore (UserDefaults)
- **Domain**: `com.floodlight.search`
- **Key**: `recent-items-v1`
- **Format**: JSON-encoded dictionary
- **Schema**: `{ [id]: { launches: Int, lastOpened: Date } }`
- **File path**: `~/Library/Preferences/com.floodlight.search.plist`
- **Source**: `/Users/martinfan/devv/floodlight/Sources/Floodlight/Utilities/RecentStore.swift`

**Example data**:
```json
{
  "application:/Applications/Claude.app": {
    "launches": 2,
    "lastOpened": 807630533.770457
  },
  "application:/Applications/Safari.app": {
    "launches": 1,
    "lastOpened": 807630413.613789
  }
}
```

**Note**: This stores item popularity only (ID + launch count + recency), NOT query→result mappings.

### 2. FFFKit LMDB Databases
Two separate FFFIndex instances store query history and frecency via LMDB (Lightning Memory-Mapped Database):

**Main file index**:
- `~/Library/Application Support/Floodlight/frecency.lmdb`
- `~/Library/Application Support/Floodlight/history.lmdb`
- Location ref: `SearchCoordinator.swift:88` - stores at `~/.../Library/Application Support/Floodlight`

**Application catalog index**:
- `~/Library/Application Support/Floodlight/ApplicationIndex/Database/frecency.lmdb`
- `~/Library/Application Support/Floodlight/ApplicationIndex/Database/history.lmdb`
- Location ref: `ApplicationCatalog.swift:50-56` - stored within the app index database directory

---

## Query Tracking Implementation

When a user opens a result, Floodlight calls:

```swift
// For files/folders (SearchCoordinator.swift:260)
index.track(query: selectedQuery, selectedURL: url)

// For applications (SearchCoordinator.swift:262)
applicationCatalog.track(query: selectedQuery, selectedURL: url)
```

**Source**: `SearchCoordinator.swift:249-268`

The `track` method signature takes:
- `query: String` - the user's search query text
- `selectedURL: URL` - the file/app URL that was opened

This data is passed to FFFKit's `FFFIndex.track()` method, which persists it to the LMDB `history.lmdb` database.

---

## Schema Notes

### RecentStore (Floodlight-specific)
- **Type**: Swift Codable struct stored in JSON
- **ID field**: The `id` key is a `SearchItem.ID` (String), typically:
  - `"application:/path/to/App.app"` for applications
  - `"file:/path/to/file"` or similar for files
  - `"web-search"` for web fallback
- **Accessible**: Yes, via UserDefaults API in Swift
- **Extractable**: Trivially via `defaults read com.floodlight.search recent-items-v1`

### FFFKit LMDB Databases
- **Type**: LMDB key-value stores (Rust-managed, binary format)
- **Version info**: LMDB format version mismatch errors occur when reading with Python `lmdb` module (likely compiled against different LMDB version than the Rust build)
- **Schema**: Opaque to Floodlight code — managed entirely by FFFKit/fff-search Rust crate
  - Package: `https://github.com/vmg-dev/fff-swift` (revision `23ac44fc572967f60e3ddf3c857438f30c60111c`, version `0.1.0`)
  - Binary XCFramework compiled into Floodlight
- **Contents**: Presumed to store:
  - `frecency.lmdb`: frecency scores (launch counts, recency decay)
  - `history.lmdb`: query history with associated URLs or result IDs
- **Extractable**: Requires:
  1. FFFKit's API (not publicly exposed in Floodlight), OR
  2. Rust LMDB reader compiled against matching LMDB version, OR
  3. Reverse-engineering the FFFKit binary format

---

## Can (Query → Result) Pairs Be Extracted?

### Answer: **YES, but with caveats**

#### What IS available
1. **From FFFKit's `history.lmdb`** (likely, not yet verified):
   - Query text → URL pairs (stored by the `track()` call)
   - Timestamp of when the pair was recorded
   - Accessible via FFFKit internal APIs or LMDB readers

2. **From RecentStore** (verified):
   - Which items were opened (ID)
   - How many times each was opened (launches)
   - When each was last opened (lastOpened)
   - NOT accessible: which queries led to each opening

#### What IS NOT available in Floodlight's own code
- Direct access to the query→URL mapping via Floodlight's Swift code
- The `track()` method is a one-way write call; there's no public read API
- FFFKit doesn't expose query history retrieval methods to Floodlight

#### Extraction paths

**Path 1: Via LMDB reader (blocked)**
- Would require reading `history.lmdb` with Rust LMDB library compiled against the same LMDB version as FFFKit
- Current Python lmdb module fails with version mismatch
- Would yield: `[(query: String, url: URL, timestamp: Date)]` tuples (presumed)

**Path 2: Via FFFKit's public API (unavailable)**
- The `track()` method exists; a symmetric `history()` or `queryResults()` method likely exists internally
- Not currently exposed to Floodlight code or documented in the public Swift wrapper

**Path 3: From Floodlight logs** (new instrumentation)
- Could instrument `SearchCoordinator.performAction()` to log every `track()` call
- Would capture: `[(query: String, selectedURL: URL, timestamp: Date)]`
- Requires code changes to Floodlight

---

## Frecency Boosting

RecentStore's `boost()` method shows the frecency algorithm Floodlight uses:

```swift
// RecentStore.swift:48-52
let age = max(0, now.timeIntervalSince(entry.lastOpened))
let recency = max(0, 4_000 - Int(age / 900))
return min(entry.launches, 25) * 200 + recency
```

**Scoring formula**:
- `launches` component: `min(launches, 25) × 200` (capped at 25 launches)
- `recency` component: `max(0, 4000 - age_in_900_second_units)` (decays over ~1 hour)
- **Total boost score**: used to rank results, but this only applies to the RecentStore items (applications), not file search results

---

## Recommendations for Metrics

To build ground-truth labels for accuracy metrics (success@k, MRR), either:

1. **Instrument Floodlight**: Add logging to `SearchCoordinator.performAction()` that records each `track()` call with timestamp
   - Minimal code change: ~5 lines in one method
   - Captures all query→result→action sequences going forward
   - Backfill impossible (historical data only in LMDB)

2. **Leverage existing LMDB**: Contact vmg-dev or reverse-engineer FFFKit to read `history.lmdb`
   - Requires Rust tooling
   - Gives full historical data
   - Higher effort, higher data volume

3. **Hybrid**: Use RecentStore + instrumentation
   - RecentStore provides aggregate popularity (all-time launches + last-opened)
   - Instrumentation provides query context
   - Good for building synthetic ground truth (e.g., "Claude was opened 2x after queries containing 'claude'")

---

## Files Referenced

- `/Users/martinfan/devv/floodlight/Sources/Floodlight/Utilities/RecentStore.swift` - RecentStore implementation
- `/Users/martinfan/devv/floodlight/Sources/Floodlight/Search/SearchCoordinator.swift` - track() calls at lines 260, 262
- `/Users/martinfan/devv/floodlight/Sources/Floodlight/Search/ApplicationCatalog.swift` - application tracking
- `/Users/martinfan/devv/floodlight/README.md` - states "Persistent FFF history, frecency data"
