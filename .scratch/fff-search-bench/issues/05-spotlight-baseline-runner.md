# Spotlight baseline: driving mdfind fairly

Type: research
Status: resolved

## Question

How do we drive Spotlight programmatically as a fair baseline — `mdfind` flags and `kMDItem*` predicates for filename vs content queries, scoping to specific roots (`-onlyin`), warm-vs-cold index caveats, and whether Spotlight's result *ordering* is accessible enough to compare ranking quality (not just latency) against FFF? Also: are `fd`/`fzf` worth including as secondary filename-search baselines, and what are the standard latency-measurement pitfalls (first-run cache effects, index staleness)?

Findings: `.scratch/fff-search-bench/research/spotlight-baseline-runner.md`

## Answer

Drive Spotlight via `mdfind -onlyin ROOT` with `-name PAT` (filename), `kMDItemTextContent`/`-interpret` predicates (content), and `-count` for recall; `-literal` pins raw predicates. The CLI returns an unordered set with no relevance scores, so Spotlight competes on latency + recall only — ranking needs an NSMetadataQuery harness sorting on NSMetadataQueryResultContentRelevanceAttribute (content queries only), and Spotlight has no fuzzy matching at all. Fairness gates: assert `mdutil -s` says "Indexing enabled." (this Mac has indexing disabled on every volume — mdfind returned 0 for files fd finds), `mdimport -i` + poll `mdfind -count` after corpus churn, keep the corpus out of hidden dirs/~/Library/Privacy list, and time with hyperfine (`-w 3 -r 20`). Include fd (`-H -I` for walk parity) and fd|`fzf --filter` (score-ranked, fuzzy) as secondary baselines — the only ranking-capable comparison for fuzzy filename queries.

Findings: .scratch/fff-search-bench/research/spotlight-baseline-runner.md
