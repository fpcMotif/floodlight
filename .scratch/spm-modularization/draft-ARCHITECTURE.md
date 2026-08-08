# Floodlight architecture — DRAFT (ticket 03 asset)

The whole document. One target graph, one secret per target, the invariants that keep it true.

## Target graph

```
Floodlight (executable)
    │  package-access imports
    ▼
FloodlightEngine (library)
    │
    ▼
FFFKit (vmg-dev/fff-swift)
```

Strict DAG, one edge. The shell never imports FFFKit; FFFKit types never cross the engine's seam (they are laundered into `SearchItem` inside the engine — the typealias façade in `FFFIndex.swift` and the `extension IndexedSearchItem` are engine internals).

## Targets

### FloodlightEngine

**Secret:** where results come from (FFF index, `NSWorkspace` app discovery, system/settings catalogs, command catalog, calculator, recents), how they rank (`FuzzyMatcher` + recents boosting), and how their actions execute (`NSWorkspace` open / reveal / launch).

**Interface, one sentence:** type a query; observe ranked, filterable pages of `SearchItem`s; `activate` one.

Surface (all `package`-access): `SearchCoordinator` (the façade), the `SearchItem` family of value types (`SearchItem`, `SearchItemKind`, `SearchResultFilter`, `SearchFilterOption`, `SearchFilterCounts`, `SearchItemPage`, `SearchItemAction`, `SearchItemIconSource`), `FloodlightPerformance`. Everything else — catalogs, `FFFIndex` façade, `FuzzyMatcher`, `Calculator`, `RecentStore` — is `internal`.

### Floodlight (executable)

**Secret:** how Floodlight lives on macOS — the floating panel, global hotkey (Carbon), menu bar, onboarding & full-disk access, QuickLook presentation (QuickLookUI), launch-at-login (ServiceManagement).

Owns all three `linkedFramework` entries and the `Resources/` folder. Contains `App/`, `UI/`, `FloodlightApp.swift`, and `QuickLookController`.

## Invariants

1. **`public` count is zero.** All cross-target visibility is `package`. CI (or the Makefile) asserts `rg -n '^\s*(public|open) ' Sources` is empty; any new `public` requires a written justification naming the external consumer.
2. **One import direction.** `Sources/FloodlightEngine` never imports SwiftUI, Carbon, QuickLookUI, or ServiceManagement (AppKit is permitted: discovery and action execution need `NSWorkspace`). The shell never imports FFFKit.
3. **The engine's interface is the test surface.** Engine tests live in `FloodlightEngineTests` and exercise `SearchCoordinator` + value types; `@testable` grants access to internals within each target's own test bundle only.

## Rejected shapes (and why)

- **Kernel target** (SearchItem + FuzzyMatcher + …) — every candidate type has the engine as its only real consumer; fails the deletion test.
- **App/UI split** — 14/5 bidirectional references; it is one module in fact.
- **Onboarding target** — statable secret, hypothetical seam; revisit only if the shell grows a second installer-shaped concern.
- **Descriptor-only engine** (shell executes actions) — moves the deepest behavior into the shell tangle; every new action kind would touch two targets.
