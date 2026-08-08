# Spec: Carve Floodlight into a two-target SPM package

Status: ready-for-agent

Produced from the [SPM modularization wayfinder map](map.md) (all decision tickets resolved, 2026-08-06). Companion assets: [draft-Package.swift](draft-Package.swift) · [draft-ARCHITECTURE.md](draft-ARCHITECTURE.md) · [carve-checklists.md](carve-checklists.md) (verified call sites and file moves).

## Problem Statement

Floodlight is a single monolithic executable target. The search business logic — where results come from, how they rank, how their actions execute — is tangled with the macOS shell: the coordinator that owns search also registers login items, presents QuickLook, and computes panel geometry. Nothing enforces any interface: every one of the ~60 types can see every other, the third-party index library leaks into the value-type layer through typealiases, and the only thing keeping the code navigable is folder convention. For the maintainer this means changes ripple unpredictably, tests can't isolate the core, and there is no compiler-checked notion of "inside" vs "outside" the business logic.

## Solution

Restructure the package into two targets forming a strict one-edge DAG: **`FloodlightEngine`**, a deep module whose interface is one sentence — *type a query; observe ranked, filterable pages of `SearchItem`s; `activate` one* — and **`Floodlight`**, the executable shell that owns everything macOS-shaped (panel, hotkey, menu bar, onboarding, QuickLook, login item, all linked frameworks). All cross-target visibility uses the `package` access level; `public` stays at zero, compiler- and CI-enforced. The carve lands as two revertible PRs: first evict the coordinator's non-search concerns, then mechanically extract the engine, letting compiler errors discover the interface.

## User Stories

1. As Floodlight's maintainer, I want the search business logic closed inside one deep module, so that changes to ranking or result sources concentrate in one place instead of spreading across the app.
2. As Floodlight's maintainer, I want the engine's interface to be a single clause, so that I get maximum leverage per unit of interface anyone has to learn.
3. As Floodlight's maintainer, I want FFFKit fully hidden behind the engine's seam, so that upgrading or replacing the index library never touches the shell.
4. As Floodlight's maintainer, I want action execution to live inside the engine, so that adding a new result kind with its open/reveal behavior touches exactly one module.
5. As Floodlight's maintainer, I want the shell to own every linked framework, so that OS-integration churn never rebuilds or destabilizes the engine.
6. As Floodlight's maintainer, I want launch-at-login, QuickLook presentation, and panel geometry evicted from the search coordinator, so that the coordinator's secret is search and nothing else.
7. As Floodlight's maintainer, I want cross-target visibility to be `package`-only with zero `public` declarations, so that the package is closed by compiler enforcement rather than convention.
8. As Floodlight's maintainer, I want a CI check asserting the `public` count stays zero, so that surface creep is caught mechanically instead of in review.
9. As Floodlight's maintainer, I want the restructure delivered as two independently revertible PRs, so that main stays green and each step can be undone alone.
10. As a code reviewer, I want judgment (what leaves the coordinator) and mechanics (what moves targets) in separate PRs, so that each review is tractable.
11. As a code reviewer, I want the carve PR to log every access-level promotion the compiler demanded, so that the discovered interface is itself the review artifact.
12. As a test author, I want engine tests to exercise the same interface callers use, so that tests survive rewrites of the implementation.
13. As a test author, I want the engine's test suite to run without any shell machinery, so that the core suite is fast and headless.
14. As Floodlight's maintainer, I want `SearchItem` and its filter types exported as the engine's vocabulary, so that the shell renders results without knowing where they came from.
15. As Floodlight's maintainer, I want the fuzzy matcher, calculator, recents store, and catalogs internal to the engine, so that they can be rewritten freely with zero blast radius.
16. As an AFK coding agent, I want an `ARCHITECTURE.md` naming each target's secret and the rejected shapes, so that I can navigate and extend the codebase without re-litigating its design.
17. As an AFK coding agent, I want the import direction compiler-enforced in both directions, so that I cannot accidentally recreate the tangle.
18. As a future external consumer (a CLI, the fff MCP), I want `public` promotion to be a deliberate per-symbol act with written justification, so that the engine's external API is designed, never leaked.
19. As Floodlight's user, I want the restructure to change zero behavior, so that search, hotkey, onboarding, QuickLook, and login-at-launch work exactly as before.
20. As Floodlight's maintainer, I want the executable product to keep its name, so that the Makefile, launch configuration, and muscle memory keep working.

## Implementation Decisions

All decided in the wayfinder grilling ([seam map ticket](issues/02-seam-map.md)); the evidence base is the coupling matrix ([ticket](issues/01-coupling-matrix.md)).

- **Two targets, one edge**: `Floodlight` (executable) → `FloodlightEngine` (library) → FFFKit. No Kernel target — every candidate type had the engine as its only real consumer and failed the deletion test. No feature targets — the App/UI folders are one module in fact (bidirectional references), and an Onboarding target is a hypothetical seam.
- **`FloodlightEngine`'s secret**: where results come from (FFF index, app discovery, system/settings catalogs, command catalog, calculator, recents), how they rank (fuzzy matching + recents boosting), and how their actions execute (workspace open / reveal / launch). Its interface: `SearchCoordinator` as the façade plus the `SearchItem` family of value types plus the performance-signpost utility — nothing else crosses the seam.
- **The engine executes actions** (rejected: descriptor-only functional core). `activate` performs the side effects; the shell never sees workspace machinery.
- **FFFKit never crosses the seam.** The typealias façade over FFFKit's types and the extension on the aliased result type become engine internals; the shell has no FFFKit import.
- **The shell's secret**: how Floodlight lives on macOS. It absorbs the QuickLook controller, the panel-geometry metrics, and the evicted launch-at-login machinery, and is the sole owner of the Carbon, QuickLookUI, and ServiceManagement linker settings; the engine has none (its AppKit import is permitted for discovery and action execution).
- **Access policy**: every promotion the carve demands goes to `package`, never `public`. `public`/`open` count is pinned at zero by a CI/Make check; any future `public` requires written justification naming the real external consumer.
- **Sequencing**: PR 1 evicts the coordinator's squatters behavior-preservingly inside the monolith (launch-at-login beside its only callers in the app delegate; QuickLook ownership to the panel controller; panel height computed by the shell observing query state). PR 2 is the mechanical carve: manifest swap, file moves, test split, error-driven `package` promotion with the promotion list logged in the PR body.
- **Manifest** (from the approved prototype, trimmed to the decision-rich parts):

  ```swift
  .target(
      name: "FloodlightEngine",
      dependencies: [.product(name: "FFFKit", package: "fff-swift")]
  ),
  .executableTarget(
      name: "Floodlight",
      dependencies: ["FloodlightEngine"],
      linkerSettings: [
          .linkedFramework("Carbon"),
          .linkedFramework("QuickLookUI"),
          .linkedFramework("ServiceManagement")
      ]
  )
  ```

  Tools-version, platform (macOS 14), product name, and the FFFKit dependency are unchanged from today's manifest.

## Testing Decisions

- **The interface is the test surface.** Engine tests exercise `SearchCoordinator` and the `SearchItem` value types through the same seam the shell uses — external behavior (query in, ranked filterable pages out, activation effects), never catalog or matcher internals. `@testable` grants each test target access to its own module's internals only; no cross-target `@testable` bridges.
- **Test split follows the carve**: the calculator, catalog, index, fuzzy-matcher, coordinator, filter, and search-performance suites move to the engine's test target; the icon, metrics, panel, menu-bar, and onboarding suites stay with the shell's. No test logic changes — moves and import updates only.
- **Prior art**: the existing twelve suites already test at roughly this altitude (e.g. the coordinator and filter suites drive the coordinator's surface); they are the pattern to preserve, now with the compiler guaranteeing the altitude.
- Both test targets must pass after each PR independently — that, plus zero behavior change, is the acceptance bar for the whole effort.

## Out of Scope

- Any behavior change or logic refactor beyond file moves, member relocation, and access-level changes.
- Changes to FFFKit / fff-swift (external package; upstream repos are off-limits — all published artifacts target the fork only).
- An Onboarding target — revisit only if the shell grows a second installer-shaped concern.
- The public-API ratchet tooling (`diagnose-api-breaking-changes`, periphery) — collapsed to the zero-`public` CI check by the access policy.
- Splitting the engine further (engine-vs-coordinator, a ranking Kernel) — SPM makes later splits cheap; depth beats granularity for the first pass.

## Further Notes

- The full decision trail with evidence lives on the [wayfinder map](map.md); the [carve checklists](carve-checklists.md) carry verified call-site line numbers for both PRs and are the working reference for whoever executes — expect line numbers to drift, trust the member names.
- The coupling matrix ([data](coupling-matrix.md)) is a point-in-time snapshot (2026-08-06); re-running it post-carve should show the folder×folder table replaced by the single package-enforced edge.
- Naming rationale: `FloodlightEngine` states the secret; `FloodlightCore` was vetoed as dumping-ground bait, `SearchKit` for collision and undersell.
