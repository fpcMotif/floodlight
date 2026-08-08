# SPM modularization — wayfinder map

**Destination reached 2026-08-06.** All tickets resolved; the handoff is live ([spec.md](spec.md) + fork issues [#11](https://github.com/fpcMotif/floodlight/issues/11)/[#12](https://github.com/fpcMotif/floodlight/issues/12)). Execution is a separate effort.

## Destination

A locked seam map for carving Floodlight into a 3–4-target SPM package — each target named with its *secret* and a one-line public API, a strict dependency DAG, and a leaf-first extraction order — captured as a draft `Package.swift` + `ARCHITECTURE.md`, then handed off as ready-for-agent execution issues on `fpcMotif/floodlight`. Plan only: no carve PRs happen on this map.

## Notes

- Domain: Floodlight — macOS Spotlight-alternative launcher (SwiftUI/AppKit, macOS 14+), single executable target today, one external dep (`FFFKit` from `vmg-dev/fff-swift`).
- Skills every session should consult: `/mattpocock-skills:codebase-design` (deep-module vocabulary) for any seam discussion; `/mattpocock-skills:grilling` + `/mattpocock-skills:domain-modeling` for HITL tickets.
- Standing defaults from f, verified against the repo 2026-08-06 (see [phase0-census.md](phase0-census.md)):
  - Pure SPM ✓ (no `.xcodeproj`); executable target `Floodlight` exists ✓.
  - `swift-tools-version: 5.10` ✓ → the `package` access level is available; no `@_spi` fallback needed.
  - First pass ≤ 5 targets — at ~4.5K lines aim **3–4**; depth beats granularity.
  - Carve style (for the eventual execution effort): leaf-first, one extraction per PR, everything `internal` → compile → error-driven promotion, log every promotion.
- Baseline surface is **zero** `public` decls — the interface will be discovered, not inherited. AppKit imports in 12/25 files; the AppKit-free core is the seam signal.
- Publishing: issues/PRs/labels go to `fpcMotif/floodlight` **only**; upstream `vmg-dev` is forbidden.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Coupling matrix & inbound-ref ranking](issues/01-coupling-matrix.md) — Utilities/Models are leaves, Search the hub, App↔UI one tangle; FFFKit leaks by typealias into a Models `extension`; `SearchCoordinator` hides login-item/QuickLook/layout concerns. Full data: [coupling-matrix.md](coupling-matrix.md).
- [Seam map: name the targets, secrets, and DAG](issues/02-seam-map.md) — **two targets**: `FloodlightEngine` (query → ranked `SearchItem` pages + `activate`; hides FFFKit, catalogs, ranking, action execution) ← `Floodlight` shell (panel/hotkey/onboarding/QuickLook/login-item, owns all linked frameworks). Kernel dissolved; `package`-only access with `public` pinned at 0; evict-then-carve in two PRs.
- [Prototype the concrete Package.swift + ARCHITECTURE.md](issues/03-package-draft.md) — approved as drafted; the spec is the ticket's three assets: [draft-Package.swift](draft-Package.swift), [draft-ARCHITECTURE.md](draft-ARCHITECTURE.md), [carve-checklists.md](carve-checklists.md).
- [Publish the execution handoff](issues/04-handoff-tickets.md) — [spec.md](spec.md) on this tracker (`ready-for-agent`) plus the two self-contained fork issues: [Evict non-search concerns from SearchCoordinator](https://github.com/fpcMotif/floodlight/issues/11) and [Carve FloodlightEngine into its own SPM target](https://github.com/fpcMotif/floodlight/issues/12).

## Not yet specified

<!-- clear — the remaining route (Package.swift/ARCHITECTURE.md draft, then handoff) is fully ticketed -->

## Out of scope

- Executing the carve (Phase 2–4 PRs) — this map ends at the handoff; execution is its own effort.
- Changes to `FFFKit` / `fff-swift` — external package, and upstream repos are off-limits.
- Behavior changes or logic refactors beyond file moves and access-level changes.
- An Onboarding target — statable secret but a hypothetical seam today ([seam map decision](issues/02-seam-map.md)); revisit only if the shell grows a second installer-shaped concern.
- The Phase-4 public-API ratchet (`diagnose-api-breaking-changes`, periphery) — collapsed by the `package`-only policy to a single CI grep asserting zero `public` ([seam map decision](issues/02-seam-map.md)).
