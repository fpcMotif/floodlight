# Coupling matrix & inbound-ref ranking — 2026-08-06

Asset for [Coupling matrix & inbound-ref ranking](issues/01-coupling-matrix.md). Method: harvested 59 type decls (regex over comment/string-stripped source — 22 more than the census's top-level scan), counted word-boundary references per folder, cross-folder only. Script: session scratchpad `coupling.py`.

## Folder × folder matrix (rows reference columns' types)

| refs ↓ defines → | (root) | App | Models | Search | UI | Utilities |
|---|---|---|---|---|---|---|
| **(root)** | · | 1 | · | · | · | · |
| **App** | · | · | · | 4 | **14** | 4 |
| **Models** | · | · | · | **1** ⚠️ | · | · |
| **Search** | · | · | **52** | · | **1** ⚠️ | **41** |
| **UI** | · | 5 | 3 | 5 | · | · |
| **Utilities** | · | · | · | · | · | · |

Reading:

- **Utilities is a perfect leaf** — zero outbound references to any other folder's types.
- **Models is a near-leaf** — one back-edge into Search (⚠️ see finding 1).
- **Search is the hub consumer**: 52 refs into Models, 41 into Utilities, plus one stray into UI (⚠️ finding 2).
- **App↔UI is bidirectional** (14 / 5) — the shell is one tangle, not two layers.

## Per-type inbound refs (cross-folder), ranked

| Type (home) | Inbound | From |
|---|---|---|
| `SearchItem` (Models) | 35 | Search 33, UI 2 |
| `FloodlightPerformance` (Utilities) | 25 | Search 21, App 4 |
| `FuzzyMatcher` (Utilities) | 13 | Search 13 |
| `FloodlightMetrics` (UI) | 12 | App 11, Search 1 |
| `SearchCoordinator` (Search) | 9 | UI 5, App 4 |
| `SearchItemPage` (Models) | 6 | Search 6 |
| `SearchFilterOption` / `SearchResultFilter` (Models) | 5 each | Search, UI |
| `RecentStore` (Utilities) | 4 | Search 4 |
| `SearchFilterCounts` (Models) | 4 | Search 4 |
| `FloodlightShortcut` (App) | 3 | UI 3 |
| `Calculator` (Utilities) | 2 | Search 2 |

39 of 59 types have **zero** cross-folder inbound (all of UI's views, all catalogs, panel/onboarding machinery) — the coupling story is carried by ~10 types.

## Findings

1. **FFFKit is *not* confined to Search — it leaks by typealias.** `Search/FFFIndex.swift` is a 7-line façade: `typealias FFFIndex = FFFKit.FFFIndex`, `IndexedSearchItem = FFFKit.FFFSearchResult`, etc. `Models/SearchItem.swift:233` then declares `extension IndexedSearchItem` — the value-type file extends an FFFKit type under a local name. Any Kernel extraction must either move that extension into the search module or drag FFFKit into the Kernel's deps. This is the plan's "audit `extension`s on shared types" failure mode, live in the code.
2. **`SearchCoordinator` hides three foreign secrets** (god-object): login-item registration via `SMAppService` (`SearchCoordinator.swift:340–369` — why the *Search* folder links ServiceManagement), QuickLook presentation (`quickLook = QuickLookController()`, line 59), and UI layout (`FloodlightMetrics.panelHeight`, line 43 — the lone Search→UI edge). These three will force ugly promotions unless relocated during the carve.
3. **`FloodlightMetrics` is misfiled in UI** — 11 of its 12 inbound refs come from App; it's layout geometry (CoreGraphics only), not a view.
4. **Framework pins**: Carbon → `AppDelegate`, `GlobalHotKey` (App). QuickLookUI → `QuickLookController` (Utilities — misfiled, it's shell). ServiceManagement → `SearchCoordinator` (Search — misplaced, it's app lifecycle). AppKit-free files: 11 of 25 — `Models/SearchItem.swift`, all of Utilities except QuickLook, `FFFIndex`/`SystemCatalog`/`FloodlightCommandCatalog`, onboarding state/session, `FloodlightMetrics`.
5. **`SearchCoordinator` is the engine's natural façade** — the only Search type App/UI touch (9 refs); catalogs and FFF machinery are already invisible outside the folder.

## Extraction-order signal (leaf-first)

1. Pure leaves first: Models value types + Utilities pure logic (`FuzzyMatcher`, `Calculator`, `FloodlightPerformance`, `RecentStore`) — zero outbound, heavy inbound. The `IndexedSearchItem` extension (finding 1) is the one knot to cut first.
2. Search second — after coordinator sheds SMAppService/QuickLook/panel-height (findings 2–3).
3. App + UI stay as the shell (bidirectional tangle, near-zero inbound from elsewhere).
