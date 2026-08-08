# Phase-0 baseline census — 2026-08-06

Read-only inventory of `Sources/` at charting time (branch `claude/swift-package-structure-549e2b`, worktree `mattpocock-skills-implement-d33a9e`).

## Package

- Pure SPM, no `.xcodeproj`. `swift-tools-version: 5.10` → `package` access level available.
- One executable target `Floodlight` (`Sources/Floodlight`, excludes `Resources`), linking Carbon, QuickLookUI, ServiceManagement.
- One test target `FloodlightTests` (12 test files).
- One external dep: `FFFKit` from `vmg-dev/fff-swift`.

## Folder census

| Folder | Files | Lines | `public`/`open` decls |
|---|---|---|---|
| App/ | 6 | 1,162 | 0 |
| Models/ | 1 | 263 | 0 |
| Search/ | 5 | 1,740 | 0 |
| UI/ | 8 | 989 | 0 |
| Utilities/ | 5 | 380 | 0 |
| root (`FloodlightApp.swift`) | 1 | 18 | 0 |

**Baseline public surface = 0** — everything is `internal` in one target. The interface will be *discovered* entirely by Phase-2 error-driven promotion; there is no legacy `public` to demote.

## Imports (whole `Sources/`)

```
13 Foundation   12 AppKit   8 SwiftUI   3 os   2 Observation
 2 Carbon   1 ServiceManagement   1 QuickLookUI   1 FFFKit   1 CoreGraphics
```

- AppKit touches **12 of 25** files — the AppKit-free core is the interesting seam.
- `FFFKit` symbols appear only in `Search/FFFIndex.swift`, `Search/SearchCoordinator.swift`, `Search/ApplicationCatalog.swift`.

## Type decls by folder

- **Models/SearchItem.swift** — `SearchItemKind`, `SearchResultFilter`, `SearchFilterCounts`, `SearchFilterOption`, `SearchItemPage`, `SearchItemAction`, `SearchItemIconSource`, `SearchItem` (all value types, `Sendable`).
- **Search/** — `SearchCoordinator`, `ApplicationCatalog`, `SystemCatalog`, `FloodlightCommandCatalog`, `FFFIndex` (in FFFIndex.swift).
- **App/** — `AppDelegate`, `FloodlightPanel`, `FloodlightPanelController`, `GlobalHotKey`/`FloodlightShortcut`, `OnboardingFlowState`, `OnboardingSession`, `FloodlightFullDiskAccess`, `OnboardingWindowController`, `FloodlightConfigurationPresentation`.
- **UI/** — `SearchView`, `ResultRow`, `OnboardingView`, `FloodlightTextField`, `VisualEffectView`/`FloodlightSurface`, `FileIconCache`, `FloodlightMenuBarIcon`, `FloodlightMetrics`.
- **Utilities/** — `FuzzyMatcher`, `Calculator`, `RecentStore`, `FloodlightPerformance` (pure-ish); `QuickLookController` (AppKit/QuickLookUI — misfiled here).

## Tests

Calculator, Catalog, FFFIndex, FloodlightIcon, FloodlightMetrics, FloodlightPanel, FuzzyMatcher, MenuBar, Onboarding, SearchCoordinator, SearchFilter, SearchPerformance.
