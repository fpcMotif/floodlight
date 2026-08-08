# Seam map: name the targets, secrets, and DAG

Type: grilling
Status: resolved
Blocked by: 01

## Question

The central decision. With the coupling matrix in hand, name the 3–4 targets. For each: (a) its **secret** — the decision it hides; (b) its public API in **one sentence**. Wire the strict DAG and pick the leaf-first extraction order by inbound-ref count.

Working hypothesis to stress-test (not a conclusion):

- `FloodlightKernel` — `SearchItem` value types + `FuzzyMatcher` + `Calculator` (+ `FloodlightPerformance`?). Pure, zero AppKit. Secret candidate: what a search result *is* and how candidates rank.
- `FloodlightSearch` — catalogs + `FFFIndex` + `SearchCoordinator` (+ `RecentStore`?). Secret: where results come from (FFFKit, NSWorkspace, system catalogs) and how sources merge.
- `Floodlight` (app shell) — `App/` + `UI/` + `QuickLookController`; keeps the Carbon/QuickLookUI/ServiceManagement linker settings.

Kill-tests from the defaults: API needs two clauses → split; trivial secret → merge; Kernel can't state a secret → dissolve it into the search module (3 targets, not 4). Any feature→feature edge needs written justification, else the shared type moves down. Also settle here: does `Search/` split engine-vs-coordinator, and where does `UI/` sit if the shell gets fat?

Evidence to settle against ([coupling matrix answer](01-coupling-matrix.md)): the `extension IndexedSearchItem` in Models (FFFKit-by-typealias — Kernel can't keep it); `SearchCoordinator`'s three foreign concerns (SMAppService login item, QuickLook, panel-height) — where does each land; the misfiled `FloodlightMetrics` (App geometry, not UI) and `QuickLookController` (shell, not Utilities). `SearchCoordinator` is already the engine's only externally-touched type — the façade candidate.

## Answer

Resolved by grilling with f, 2026-08-06 — six decisions, each explicitly confirmed. The working hypothesis lost on two counts: no Kernel, and no feature targets. **Two targets, strict DAG: `Floodlight` (exe) → `FloodlightEngine` → FFFKit.**

1. **`FloodlightEngine`** (library) — the deep module.
   - **Secret:** where results come from (FFF index, NSWorkspace app discovery, system/settings catalogs, command catalog, calculator, recents), how they rank (FuzzyMatcher + recents boosting), and how their actions execute (NSWorkspace open / reveal / launch).
   - **Interface, one sentence:** *type a query; observe ranked, filterable pages of `SearchItem`s; `activate` one.*
   - Surface: `SearchCoordinator` (façade, shorn of launch-at-login), the `SearchItem`/filter value types, `FloodlightPerformance`. Contents: `Models/` + `Search/` + `FuzzyMatcher`, `Calculator`, `RecentStore` (all internal). The FFFKit typealias façade and the `extension IndexedSearchItem` become engine internals — FFFKit never crosses the seam. **The engine executes actions** (descriptor-relay alternative rejected: it moves the deepest behavior into the shell tangle and makes every new action touch two modules).
2. **`Floodlight`** (executable shell).
   - **Secret:** how Floodlight lives on macOS — panel, global hotkey, menu bar, onboarding, QuickLook presentation, login item.
   - Contents: `App/` + `UI/` + the misfiled `QuickLookController` and `FloodlightMetrics` + the evicted `SMAppService` launch-at-login code (its only callers are in `AppDelegate`). All three linked frameworks (Carbon, QuickLookUI, ServiceManagement) belong to this target; the engine needs none.
3. **Kernel dissolved** — every candidate (FuzzyMatcher 13/13, Calculator 2/2, RecentStore 4/4, SearchItem 33/35 refs from Search) has the engine as its only real consumer; a Kernel fails the deletion test. UI's few `SearchItem` refs are the engine's vocabulary crossing its interface, not grounds for a third module.
4. **Onboarding target rejected for the first pass** — statable secret, but a hypothetical seam (nothing varies across it); ruled out of scope, revisit only if the shell grows a second installer-shaped concern.
5. **Access policy: `package`-only.** Every promotion during the carve goes to `package`; `public` stays **zero**, enforced by a CI grep (`rg '^\s*public ' Sources` → empty; any new `public` needs written justification = a real external consumer). This collapses the Phase-4 ratchet: `diagnose-api-breaking-changes` has nothing to guard; periphery drops out of this effort.
6. **Carve sequencing: evict, then carve — two PRs.** PR 1 (behavior-preserving, in-monolith): coordinator sheds SMAppService/QuickLook/panelHeight; misfiled files move to shell folders. PR 2 (mechanical): create `Sources/FloodlightEngine`, move Models + Search + pure Utilities, split tests (`Calculator`/`FuzzyMatcher`/`Catalog`/`FFFIndex`/`SearchCoordinator`/`SearchFilter`/`SearchPerformance` → `FloodlightEngineTests`), compile, promote to `package` only where errors demand, promotion log in the PR body.

Resolve via `/mattpocock-skills:grilling` + `/mattpocock-skills:codebase-design`, with f live.
