# Carve checklists — DRAFT (ticket 03 asset)

Two PRs, evict then carve. Main stays green after each. Every call site below was verified against source on 2026-08-06.

## PR 1 — Evict the coordinator's squatters (behavior-preserving, no target changes)

**Launch-at-login → shell.** Move `enableLaunchAtLoginOnFirstRun()`, `setLaunchAtLogin(_:)`, `launchesAtLogin`, the `SMAppService` block ([SearchCoordinator.swift:340–374](../../Sources/Floodlight/Search/SearchCoordinator.swift)) and the `launch-at-login-configured` UserDefaults key into a small shell-side type (e.g. `App/LaunchAtLogin.swift`). Rewire the four caller clusters, all already in `AppDelegate` (first-run :37, onboarding closure :126–129, menu toggle :158–161, menu state :334). `OnboardingWindowController`/`OnboardingView` take closures already — nothing below `AppDelegate` changes. Drop `import ServiceManagement` from the coordinator.

**QuickLook → shell.** The coordinator owns `quickLook = QuickLookController()` (:59) with two call sites: close-on-reset (:226) and toggle-preview (:309). Ownership moves to the shell (panel controller); the coordinator loses the property and instead exposes whatever the shell needs to preview the current selection (selection URL, if not already reachable). The reset/dismiss path the shell already observes triggers `close()`.

**Panel height → shell.** Delete the coordinator's `panelHeight` computed property (:42–44, the lone Search→UI reference) and the `onPanelHeightChange` push (:12–18). `FloodlightPanel` (:65) instead observes the coordinator's query state directly and computes `FloodlightMetrics.panelHeight(hasQuery:)` itself.

**File moves:** `Utilities/QuickLookController.swift` → `App/`. (`FloodlightMetrics` stays in `UI/` — it lands in the shell target either way; only the coordinator's reference to it dies. Optional cosmetic move, not part of this PR.)

**Tests:** `OnboardingTests` and `FloodlightMetricsTests` touch these concerns and already live shell-side; update call sites only. `SearchCoordinatorTests` references none of the evicted members (verified).

## PR 2 — Carve `FloodlightEngine` (mechanical)

1. Replace the manifest with [draft-Package.swift](draft-Package.swift).
2. `git mv` into `Sources/FloodlightEngine/` (keeping subfolder names):
   - `Models/SearchItem.swift`
   - `Search/` — `ApplicationCatalog`, `FFFIndex`, `FloodlightCommandCatalog`, `SearchCoordinator`, `SystemCatalog`
   - from `Utilities/` — `FuzzyMatcher`, `Calculator`, `RecentStore`, `FloodlightPerformance`
   - Shell keeps: `FloodlightApp.swift`, `App/` (incl. `QuickLookController`, `LaunchAtLogin`), `UI/`, `Resources/`.
3. Split tests: `Calculator`, `Catalog`, `FFFIndex`, `FuzzyMatcher`, `SearchCoordinator`, `SearchFilter`, `SearchPerformance` → `Tests/FloodlightEngineTests` (`@testable import FloodlightEngine`); `FloodlightIcon`, `FloodlightMetrics`, `FloodlightPanel`, `MenuBar`, `Onboarding` stay in `Tests/FloodlightTests`.
4. Build. Every "X is inaccessible" error gets a `package` promotion — never `public`. Expected promotion set (from the coupling matrix): `SearchCoordinator` + the members the shell touches, the `SearchItem` type family, `FloodlightPerformance`. **Log the actual list in the PR body** — the delta between expected and actual is the review.
5. Add the invariant check: a CI/Makefile step asserting `rg -n '^\s*(public|open) ' Sources` is empty.
6. Commit `ARCHITECTURE.md` (from [draft-ARCHITECTURE.md](draft-ARCHITECTURE.md), DRAFT header dropped).
