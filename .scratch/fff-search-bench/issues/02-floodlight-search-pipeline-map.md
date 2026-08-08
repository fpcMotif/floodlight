# Map Floodlight's search pipeline and timing seams

Type: research
Status: resolved

## Question

Where does a query travel in this repo from input to ranked results — which FFFKit calls, on what threads/actors, with what time budgets (the README mentions "time-budgeted FFF content search") — and what seams exist for (a) timing instrumentation and (b) a headless bench entry point that exercises the real pipeline without the UI? Do any perf tests or timing hooks already exist in `Sources/` or `Tests/`?

Findings: `.scratch/fff-search-bench/research/floodlight-search-pipeline.md`

## Answer

Query flow: text input → `SearchCoordinator` (@MainActor) → immediate app/settings fuzzy search (sync) → time-budgeted FFF index search after 35–180 ms debounce (async Tasks calling `FFFKit.FFFIndex.search()` and `.searchFiles()`) → conditional content search after 120 ms if <12 file matches (calling `FFFKit.FFFIndex.searchContent()`). All results deduplicated by ID and scored. Timing instrumented via 8 `os_signpost` named points (capture in Instruments.app). Headless seam exists: `SearchCoordinator` is UI-independent; `index.search()`, `applicationCatalog.search()`, and `SystemCatalog.searchPage()` are directly callable async/sync APIs. SearchPerformanceTests already measures app/settings/filter logic; bench can extend it to profile indexed + content searches via Task observation or signpost capture.

Findings: .scratch/fff-search-bench/research/floodlight-search-pipeline.md
