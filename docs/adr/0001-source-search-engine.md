---
status: accepted
date: 2026-08-08
---

# Put Source Search behind SourceSearchEngine

Floodlight will move file, application, and System Settings search orchestration from `SearchCoordinator` into a deep `SourceSearchEngine` module in `FloodlightEngine`. `SearchCoordinator` retains the Search Session and presentation policy; `SourceSearchEngine` owns Search Source startup, freshness, staged execution, cancellation, scope changes, candidate normalization, failure isolation, and source-specific selection learning. This concentrates search correctness behind one seam and prevents raw FFF types and source lifecycle rules from leaking into the macOS shell.

`SourceSearchEngine` will be actor-isolated. Launch-time warm-up remains an optional latency optimization, while every Source Search automatically joins or starts the same single-flight startup work. Each query produces a live asynchronous sequence of complete Search Snapshots. The sequence remains idle when settled, can emit newer snapshots after refresh, rebuild, or scope changes, and ends only when superseded or explicitly cancelled. Delivery retains only the newest unconsumed snapshot because snapshots replace rather than amend one another.

A Search Snapshot contains normalized Search Source candidates, totals by result kind, pending result kinds, settled state, and general degradation state. It does not expose adapters, pass names, limits, generation identifiers, raw FFF values, or source-specific errors. One Search Source failure cannot discard healthy candidates; details are logged internally, while visible degradation UI is deferred to a separate product change.

Scope changes are transactional: old work and candidates are invalidated immediately, the active query is re-executed automatically after the new scope succeeds, and the shell persists the preference only after success. Rebuilds follow the same invalidation-and-reexecution rule. The shell reports successful candidate selection without choosing a source; `SourceSearchEngine` uses internal provenance to route ranking feedback.

## Considered options

- **Keep orchestration in `SearchCoordinator`:** rejected because startup ordering, refresh policy, pass timing, generation checks, and source failures would continue leaking across the seam.
- **Use finite snapshot sequences:** rejected because later refresh, rebuild, and scope events would require the caller to understand when to repeat the active query.
- **Force every Search Source through one interface:** rejected because files, applications, and settings have materially different capabilities; optional operations and capability checks would create a shallow module. The existing two-adapter `Catalog` seam remains internal alongside a distinct FFF adapter.
- **Keep orchestration on the main actor:** rejected because UI publication and source correctness need separate owners. The dedicated actor serializes orchestration decisions while source work may still run concurrently.

## Consequences

Coordinator tests substitute a scripted Source Search adapter and exercise session behavior through the production seam. Engine tests exercise orchestration through the same external interface with controlled internal adapters, while a smaller integration set covers real FFF and catalogs. Result publication, filters, selection, calculator and command rows, addressed search, and web fallback remain outside this refactor. The shell’s direct FFFKit dependency can be removed once no shell usage remains.
