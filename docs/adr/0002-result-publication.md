---
status: accepted
date: 2026-08-08
---

# Publish projected search results atomically

Floodlight will keep Result Projection in the macOS shell behind one pure operation whose input distinguishes local and addressed web contexts. The operation returns one Result Publication containing rows, filter state, semantic selection, and search progress. Selection is anchored by result identity and whether it was automatic or user-driven, allowing an automatic web fallback to yield without displacing an explicit user selection.

`SearchCoordinator` continues to own Search Session intent and asynchronous orchestration, but stores one Result Publication and derives result-facing observations from it. Both local and web updates pass through Result Projection. Source candidate acquisition and normalization remain owned by `SourceSearchEngine` as established by [ADR 0001](0001-source-search-engine.md); Result Projection is presentation policy and does not move into `FloodlightEngine`.

## Consequences

Ranking, collision precedence, caps, filters, web rows, and selection reconciliation share one shell-local policy seam. Publication changes are atomic, while query and mode intent remain independently owned by the coordinator.
