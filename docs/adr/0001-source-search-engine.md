---
status: accepted
date: 2026-08-08
---

# Put Source Search behind SourceSearchEngine

Floodlight will move file, application, and System Settings search orchestration from `SearchCoordinator` into a deep `SourceSearchEngine` module in `FloodlightEngine`. `SearchCoordinator` retains the Search Session and presentation policy; `SourceSearchEngine` owns Search Source startup, freshness, staged execution, cancellation, scope changes, candidate normalization, failure isolation, and source-specific selection learning. This concentrates search correctness behind one seam and prevents raw FFF types and source lifecycle rules from leaking into the macOS shell.

`SourceSearchEngine` will be actor-isolated. Launch-time warm-up remains an optional latency optimization, while every Source Search automatically joins or starts the same single-flight startup work. Each query produces a live asynchronous sequence of complete Search Snapshots. The sequence remains idle when settled, can emit newer snapshots after refresh, rebuild, or scope changes, and ends only when superseded or explicitly cancelled. Delivery retains only the newest unconsumed snapshot because snapshots replace rather than amend one another.

A Search Snapshot contains normalized Search Source candidates, totals by result kind, pending result kinds, settled state, and general degradation state. It does not expose adapters, pass names, limits, generation identifiers, raw FFF values, or source-specific errors. One Search Source failure cannot discard healthy candidates; details are logged internally, while visible degradation UI is deferred to a separate product change.

Scope changes are transactional: old work and candidates are invalidated immediately, the active query is re-executed automatically after the new scope succeeds, and the shell persists the preference only after success. Rebuilds follow the same invalidation-and-reexecution rule. The shell reports successful candidate selection without choosing a source; `SourceSearchEngine` uses internal provenance to route ranking feedback.

## What selection learning means

“Learning” here means deterministic, local ranking personalization—not training or fine-tuning an AI model. No prompt, embedding, neural-network weight, or assistant conversation participates. The shell reports the selected item ID, its URL, and the immutable query that produced it:

```swift
await sourceSearch.trackSelection(
    of: selectedItem.id,
    selectedURL: selectedURL,
    for: originatingQuery
)
```

`SourceSearchEngine.trackSelection` normalizes the query, looks up the source provenance captured when that result was published, and routes the feedback without making the shell identify the source:

```swift
guard let source = selectionProvenance[normalized]?[candidateID] else { return }
switch source {
case .files: files.track(query: query, selectedURL: selectedURL)
case .applications: applications.track(query: query, selectedURL: selectedURL)
case .settings: settings.track(query: query, selectedURL: selectedURL)
}
```

The current file and application sources forward this message to FFF. `SystemCatalog` currently inherits `Catalog.track`'s no-op default, so Settings feedback is safely ignored rather than persisted. Application tracking first maps the real application URL to the corresponding marker inside its FFF index; file tracking uses the selected indexed URL directly.

Floodlight's Swift `FFFFileSource` calls `FFFKit.FFFIndex.track(query:selectedURL:)`. FFFKit is Swift, but its search and persistence implementation crosses a C-compatible interface into Rust. At the pinned FFF Swift 0.2.0 implementation, the Rust query tracker stores an association equivalent to:

```text
(canonical indexed root, exact query)
    -> selected path, selection count, last-selected timestamp
```

This is not a list of every previously selected result. Selecting the same path again increments its count; selecting a different path for the same exact root and query replaces the path and resets the count to one. The key is a BLAKE3 hash of the canonical root plus the exact query. Values are Bincode-serialized Rust data in an LMDB environment—not SQLite, Core Data, JSON, or a plist.

With Floodlight's production storage URL, the association is persisted locally under:

```text
~/Library/Application Support/Floodlight/history.lmdb/
├── data.mdb
└── lock.mdb
```

FFF's separate `frecency.lmdb` does not store this query-selection association. During a later mixed file search, FFF looks up the exact root-and-query entry. After the same path has been selected at least three times, Floodlight's configured FFF search adds `selection count × 100` ranking points to that matching path. For example, three repeated selections add 300 points and four add 400. Application catalogs use the same FFF mechanism over private marker files. `RecentStore` is separate: it supplies query-independent application frequency and recency rather than this query-specific association.

Authoritative dependency references for the pinned behavior:

- [`FFFIndex.track` converts Swift values to the C call](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Sources/FFFKit/FFFIndex.swift#L432-L447).
- [`fff_track_query` canonicalizes and forwards the selection in Rust](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Vendor/fff/crates/fff-c/src/lib.rs#L1008-L1055).
- [`QueryTracker` defines and persists the selected path, count, and timestamp](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Vendor/fff/crates/fff-core/src/dbs/query_tracker.rs#L13-L38).
- [`track_query_completion` applies replacement and increment rules](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Vendor/fff/crates/fff-core/src/dbs/query_tracker.rs#L227-L328).
- [`get_last_query_entry` enforces the minimum count](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Vendor/fff/crates/fff-core/src/dbs/query_tracker.rs#L330-L354), and [scoring applies the fixed multiplier](https://github.com/vmg-dev/fff-swift/blob/c446afc5344acf06b3a90d2262f094cc36c6068e/Vendor/fff/crates/fff-core/src/score.rs#L794-L816).

## Considered options

- **Keep orchestration in `SearchCoordinator`:** rejected because startup ordering, refresh policy, pass timing, generation checks, and source failures would continue leaking across the seam.
- **Use finite snapshot sequences:** rejected because later refresh, rebuild, and scope events would require the caller to understand when to repeat the active query.
- **Force every Search Source through one interface:** rejected because files, applications, and settings have materially different capabilities; optional operations and capability checks would create a shallow module. The existing two-adapter `Catalog` seam remains internal alongside a distinct FFF adapter.
- **Keep orchestration on the main actor:** rejected because UI publication and source correctness need separate owners. The dedicated actor serializes orchestration decisions while source work may still run concurrently.

## Consequences

Coordinator tests substitute a scripted Source Search adapter and exercise session behavior through the production seam. Engine tests exercise orchestration through the same external interface with controlled internal adapters, while a smaller integration set covers real FFF and catalogs. Result publication, filters, selection, calculator and command rows, addressed search, and web fallback remain outside this refactor. The shell’s direct FFFKit dependency can be removed once no shell usage remains.
