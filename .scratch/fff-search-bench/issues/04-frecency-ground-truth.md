# Frecency & query history as relevance ground truth

Type: research
Status: resolved

## Question

Where do Floodlight / fff persist the frecency database and query history on this Mac (the README says both are persistent), what is the schema, and can **(query → result actually opened)** pairs be extracted from it? If yes, that history becomes free ground-truth labels for accuracy/relevance metrics (success@k, MRR) built from f's real usage instead of hand-written fixtures.

Findings: `.scratch/fff-search-bench/research/frecency-ground-truth.md`

## Answer

**YES**: Floodlight stores query→result pairs in FFFKit's `history.lmdb` LMDB database (~/Library/Application Support/Floodlight/history.lmdb). The `SearchCoordinator.performAction()` calls `index.track(query, selectedURL)` for every result opened, persisting the query text and URL to FFFKit's history store. RecentStore in UserDefaults separately tracks item popularity (launches + lastOpened) but not query context.

**Ground-truth extraction** requires either: (1) reading history.lmdb with a Rust LMDB reader matching FFFKit's compile version; (2) instrumenting `SearchCoordinator` to log track() calls; or (3) requesting query-history export from FFFKit's public API (currently unexposed). Historical data is retrievable; forward instrumentation is simpler for metrics building.
