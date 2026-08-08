# Wayfinder map: FFF search bench — lightning-fast daily file search

Label: wayfinder:map

## Destination

A benchmark harness living in this repo that measures FFF-powered file search on this Mac — **latency, accuracy, and relevance** — against f's real daily working set, with `fd` / `fd | fzf --filter` as live baselines (Spotlight indexing stays off by choice; relevance is judged against `history.lmdb` ground truth); first baseline numbers produced, and a prioritized, evidence-backed improvement list ready to hand off. Alongside it, a standing working practice: **file-search/explore agent jobs run on Haiku**.

## Notes

- **Domain**: macOS file search. Three surfaces exist: (1) the Floodlight app (this repo — a SwiftUI Spotlight alternative powered by FFFKit from vmg-dev/fff-swift), (2) the `fff` MCP server / CLI f uses inside Claude Code for agent file-finding, (3) Apple Spotlight (`mdfind`) as the incumbent to beat. Ticket 01 decided: the bench covers both (1) and (2), phased — engine/MCP first — and Spotlight stays out (indexing disabled by choice).
- **Plan-don't-do override**: f explicitly asked for the bench to be *built* ("build up efficient and effective bench to monitor the search"). Tickets typed `task` carry that execution; search-engine improvements themselves stay decisions to hand off.
- **Standing preference (f)**: file-search and exploration subagent jobs run on the **Haiku** model. Research tickets that are repo/filesystem exploration are fired on Haiku; doc-research tickets use the default model.
- **Skills**: HITL tickets use /grilling and /domain-modeling. Research tickets use /research conventions (primary sources, findings as a cited Markdown file). Research findings land in `.scratch/fff-search-bench/research/<slug>.md`, linked from the ticket — never pasted into it.
- Tooling preferences: bun/bunx (never npm), Rust CLI tools (rg, fd, eza, bat), conventional commits.

## Decisions so far

<!-- one line per closed ticket: gist + link; the ticket holds the detail -->

- [Choose metrics and "lightning-fast" targets](issues/06-metrics-and-targets.md) — per-layer p50/p95, warm/cold split: warm p95 engine ≤ 50 ms, MCP round-trip ≤ 200 ms, Floodlight keystroke→paint ≤ 150 ms (debounce included); relevance headline **success@3 ≥ 90%** on replayed history queries with MRR as trend; runs fail on rolling-baseline regressions (p95 +20% vs last-5 median, or success@3 −2 pts), absolute targets don't gate until first met.
- [Scope the bench: which search surfaces, which working set](issues/01-scope-and-daily-working-set.md) — **both surfaces, phased** (engine/MCP headless first, Floodlight `SearchCoordinator` second, shared corpus/queries); working set = three tiers: `~/devv` fast tier, `~/Documents`, whole-home slow tier; **code committed, all bench data gitignored** (public repo); **Spotlight stays disabled** — `fd` / `fd|fzf` are the baselines, relevance judged against history ground truth.
- [Map Floodlight's search pipeline and timing seams](issues/02-floodlight-search-pipeline-map.md) — query flows through the @MainActor `SearchCoordinator` → 35–180 ms debounce → async `FFFIndex.search()`/`.searchFiles()` → content search only if <12 file matches (120 ms budget); 8 `os_signpost` points already instrument timing, and the coordinator is UI-independent, so a headless bench entry point is feasible; `SearchPerformanceTests` exists to extend.
- [Frecency & query history as relevance ground truth](issues/04-frecency-ground-truth.md) — **ground truth exists**: every opened result is persisted as a (query → URL) pair via `index.track()` into FFFKit's `history.lmdb` (~/Library/Application Support/Floodlight/); extraction needs an LMDB reader or (simpler) forward instrumentation of `SearchCoordinator.track()` calls — FFFKit doesn't expose a history-export API today.
- [FFF engine landscape: FFFKit vs fff CLI/MCP, existing bench tooling](issues/03-fff-engine-landscape.md) — same Rust core (dmtrKovalenko/fff), divergent versions: FFFKit vendors a patched **0.7.1** fork while the Claude Code `fff-mcp` runs stock **0.10.0**; upstream ships 10 criterion bench targets plus an end-to-end agent harness (`scripts/benchmark-claude.sh`) to extend rather than reinvent; key knobs are MCP CLI flags, `fff-c` API params (mostly hardcoded by FFFKit), and compile-time frecency/grep-budget constants.
- [Spotlight baseline: driving mdfind fairly](issues/05-spotlight-baseline-runner.md) — `mdfind -onlyin/-name/-count/-literal` can baseline Spotlight for latency + recall only: its output is unordered (relevance needs NSMetadataQuery) and it has no fuzzy matching. **Spotlight indexing is currently disabled on this Mac** (`mdutil -s`; mdfind returned 0 where fd found 2), so the runner must gate on index state, force-sync via `mdimport -i`, and time with hyperfine warmups; `fd` and `fd | fzf --filter` are the ranking-capable fuzzy baselines.

## Not yet specified

- **Which concrete FFF/Floodlight optimizations to pursue** — content-search time budget, watcher/index tuning, frecency weighting, warm caches, app-catalog costs, and (per ticket 03) closing the engine version gap: FFFKit vendors a patched fff 0.7.1 while upstream is at 0.10.x. Can't be sharpened until the bench produces baseline numbers (waits on 08).
- **Monitoring over time** — cadence of bench runs (manual, launchd, scheduled agent) and where result history lives; the regression *policy* itself is decided (ticket 06: rolling-baseline gates). Waits on the harness shape (08).
- **Haiku explore-agent ergonomics** — prompt patterns, fff-MCP tool budgets, when a job is too hard for Haiku. Waits on evidence from 09 and from real use.

## Out of scope

- Floodlight's non-file features — arithmetic evaluation, web-search fallback, System Settings and application catalogs. The destination is *file* search speed/relevance.
- Benchmarking Spotlight's own UI. Spotlight participates only as an `mdfind` baseline runner.
- Release, signing, and distribution work in this fork (the signed-release workflow is its own effort).
- Upstreaming improvements to vmg-dev repos — ruled out by f's standing rule (2026-08-05): all outward artifacts target the `fpcMotif/floodlight` fork only; touching upstream is forbidden. Improvements stay in the fork.
