# Coupling matrix & inbound-ref ranking

Type: task
Status: resolved

## Question

Produce the cross-folder coupling evidence the seam map hangs on. Coupling is invisible inside one target (no imports between own files), so use the reference proxy: for each of the 37 type names in [phase0-census.md](../phase0-census.md), `rg` its occurrences in the *other* folders and count.

Deliverables (as `coupling-matrix.md` next to the census):

1. Folder×folder matrix of inbound type references (`App/ Models/ Search/ UI/ Utilities/` + root).
2. Per-type inbound-ref ranking — flag the cross-folder hot types (`SearchItem` expected to dominate).
3. Per-file AppKit/SwiftUI import map — the AppKit-free subset is the seam signal.
4. Confirm `FFFKit` symbols stay confined to `Search/` (census says 3 files).
5. Note where the framework-pinned files sit: Carbon (`GlobalHotKey`), QuickLookUI (`QuickLookController`), ServiceManagement.

At 25 files, skip networkx/community detection — the matrix is readable by eye. ast-grep for the harvest is optional; the census already lists every decl. Read-only: no source changes.

## Answer

Done — full matrix, ranking, and import map in [coupling-matrix.md](../coupling-matrix.md) (2026-08-06, read-only, no source changes). Headlines:

- **Utilities is a perfect leaf, Models a near-leaf; Search is the hub consumer** (52 refs into Models, 41 into Utilities); App↔UI is one bidirectional tangle (14/5). Coupling is carried by ~10 of 59 types — `SearchItem` (35 inbound) and `FloodlightPerformance` (25) dominate.
- **Deliverable 4 came back *negative*: FFFKit is not confined to Search.** `FFFIndex.swift` is a typealias façade (`IndexedSearchItem = FFFKit.FFFSearchResult` …) and `Models/SearchItem.swift:233` extends `IndexedSearchItem` — the value-type file extends an FFFKit type under a local name. First knot to cut in any Kernel extraction.
- **`SearchCoordinator` hides three foreign secrets**: `SMAppService` login-item registration (:340–369 — hence ServiceManagement linked from *Search*), QuickLook presentation (:59), panel-height layout (:43 — the lone Search→UI edge). It is otherwise the engine's natural façade — the only Search type App/UI touch.
- **Misfilings**: `FloodlightMetrics` (UI) is CoreGraphics-only geometry, 11/12 inbound from App; `QuickLookController` (Utilities) is AppKit/QuickLookUI shell code.
- **Extraction-order signal**: Models + pure Utilities first, Search second (after the coordinator sheds its three impurities), App+UI stay as shell.
