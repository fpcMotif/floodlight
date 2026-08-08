# Prototype the concrete Package.swift + ARCHITECTURE.md

Type: prototype
Status: resolved
Blocked by: 02

## Question

Raise fidelity on the locked seam map ([answer](02-seam-map.md)): something concrete for f to react to before handoff.

- Draft `Package.swift` — two targets: `FloodlightEngine` library + `Floodlight` executable; all three `linkedFramework` entries (Carbon, QuickLookUI, ServiceManagement) on the executable; `FloodlightEngineTests` + slimmed `FloodlightTests`.
- Draft `ARCHITECTURE.md` — target graph + the two secrets as decided. Whole doc. Include the `public`-stays-zero invariant and its CI grep.
- Checklists for the two execution PRs: **PR 1 evict** (coordinator sheds SMAppService/QuickLook/panelHeight; `QuickLookController` + `FloodlightMetrics` move to shell folders), **PR 2 carve** (file moves into `Sources/FloodlightEngine`, test split per the answer, error-driven `package` promotion with a logged promotion list).

Assets link back here; revise with f until it reads right. This is a paper prototype — no source files move.

**Assets (drafted 2026-08-06):** [draft-Package.swift](../draft-Package.swift) · [draft-ARCHITECTURE.md](../draft-ARCHITECTURE.md) · [carve-checklists.md](../carve-checklists.md)

## Answer

Approved by f, 2026-08-06, as drafted — no vetoes. The three assets above stand as the spec: two-target manifest, architecture doc (secrets, invariants, rejected shapes), and the two PR checklists with verified call sites. The one flagged judgment call — `FloodlightMetrics` stays in `UI/`, its move optional cosmetics — was ratified with the approval. [Publish the execution handoff](04-handoff-tickets.md) turns the checklists into the ready-for-agent issues.
