# Smarter search: web intent, local AI, and the next features

Label: wayfinder:map

## Destination

A buildable spec at `.scratch/smarter-search/spec.md` with decisions locked for:

1. **Web-search intent routing** — how a query says "I want the web, not files", composing all four chosen mechanisms: keyword triggers, a hotkey on any query, a Web filter tab, and smart auto-detect.
2. **Local on-device AI search** — natural-language file search, an explore/answer mode, and a query intent router, powered by a local model (no cloud).
3. **A prioritized shortlist of new Floodlight features** from a brainstorm.

Implementation happens per-feature *after* this map closes — the map produces decisions, not code.

## Notes

- Domain: Floodlight, a keyboard-first Spotlight replacement for macOS (SwiftUI + FFF fuzzy search). The search pipeline is `Sources/Floodlight/Search/SearchCoordinator.swift`; today's web search is a hard-coded Google row appended last with `score: Int.min` (`buildResults`, ~line 588) — it can never outrank anything, which is the original complaint.
- Filter tabs today: All / Apps / Files / Folders / PDFs / Images / Documents (`SearchFilterCounts`). No Web tab.
- Standing decisions from charting (user, 2026-08-05): **local on-device AI first** — cloud Haiku/Anthropic API is deferred (see Out of scope). All four web-intent mechanisms and all three AI jobs are wanted.
- Current minimum OS is macOS 14; Apple's Foundation Models framework needs macOS 26 — raising the minimum vs. bundling a model is a live tension for the AI research.
- Skills: use /grilling + /domain-modeling for grilling tickets; the prototype ticket should use the mattpocock-skills prototype skill.
- The user writes terse, typo-heavy messages — interpret charitably and confirm understanding with concrete options.
- Tracker: local markdown per mattpocock-skills conventions — tickets in `issues/`, research findings in `research/`.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Local AI options for on-device search](issues/01-local-ai-options.md) — primary stack: Apple Foundation Models, weak-linked behind `#available(macOS 26, *)` so the app keeps its macOS 14 minimum; the OS hosts the ~3B model (zero download, zero resident memory). NL file search via `@Generable` guided generation → structured FFF query; explore mode via tool calling over FFF (4,096-token context limit). The intent router should be deterministic heuristics (0 ms), with optional model refinement on idle pause. Fallback for older OSes if ever needed: llama.cpp prebuilt XCFramework (same pattern as FFF); MLX ruled out (Metal shaders don't build under plain `swift build`). Findings: [research/local-ai-options.md](research/local-ai-options.md).
- [Launcher web-search UX conventions](issues/02-web-search-ux-conventions.md) — copy the three-layer model every major launcher converges on: keyword-prefix engines (title + keyword + `{query}` URL template), a user-curated implicit fallback list when local results are weak/empty, and an always-available "web-search exactly what I typed" chord (Spotlight's ⌘B precedent); accept DDG bangs as aliases, promote a *ranked* web row instead of today's pinned one, skip cryptic punctuation sigils. Findings: [research/web-search-ux-conventions.md](research/web-search-ux-conventions.md).
- [Web-search routing: smart auto-detect](issues/03-web-routing-spec.md#smart-auto-detect--resolved-2026-08-08) — shipped, not just decided. Promotes the web row (out of its always-last `Int.min`, up to a new `SearchItemRanking.webPromoted = 1_500` band) on weak/zero local matches (≤2) OR a question/URL-shaped query. `WebSearchIntent.swift` + `SearchCoordinator.buildResults` re-ranking. Keyword triggers, the any-query hotkey chord, and the Web filter tab (the ticket's other three sub-questions) are still open.

## Not yet specified

- Per-feature implementation planning for whatever the feature-brainstorm shortlist selects — can't ticket until the shortlist exists.
- Live web suggestions inside the Web tab (needs a network-endpoint and privacy decision) — hangs on "Web-search routing spec".
- Keyword-trigger syntax, the any-query hotkey chord, and the Web filter tab — the other three sub-questions of the routing spec (auto-detect itself shipped, see Decisions above).
- Whether the AI intent router (ticket 04) subsumes the auto-detect heuristic once it lands — hangs on the AI architecture.

## Out of scope

- **Cloud Haiku / Anthropic API integration** — user chose local-first at charting ("local mode instead first … in future using cloud api, deferred"). Returns only as a fresh effort.
- **Implementing the specced features** — the destination is the spec; building is per-feature work after the map closes.
