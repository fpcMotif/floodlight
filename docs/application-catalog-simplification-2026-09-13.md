# Application-catalog simplification: performance record

Issue #100 collapsed application Source Search onto one in-memory catalog and
deleted the private marker index, its FFF database, the scan waits, and the
character-mask prefilter (#69). This file records the before/after latency the
spec requires, measured on one host with `scripts/test-performance.sh`
(release).

- **Before**: `ae665ca` (the commit the branch forks from), run in a detached
  worktree so the working tree stayed untouched.
- **After**: `1f0ae68` (`test/search-transition-fff-101`, PR #102).
- Gate per the spec: each median within the larger of 120% of baseline or
  baseline plus one millisecond. The new at-scale benches have no baseline;
  their numbers are the first record.

## Gate metrics

| Median | Before | After | Gate bound | Verdict |
| --- | ---: | ---: | ---: | --- |
| fast_application_search_us | 6.077 | 25.920 | 1006.077 | pass |
| blocklisted_application_search_us | 5.991 | 25.850 | 1005.991 | pass |
| settings_search_us | 13.522 | 13.514 | 1013.522 | pass |
| source_immediate_snapshot_ms | 0.008 | 0.009 | 1.008 | pass |
| top_ranked_selection_us | 230.015 | 236.715 | 1230.015 | pass |
| fuzzy_matcher_scoring_us | 59.680 | 59.720 | 1059.680 | pass |
| clipboard_search_us | 279.029 | 291.749 | 1279.029 | pass |
| direct_link_recognition_us | 1.829 | 1.802 | 1001.829 | pass |

The +20µs on the application micro-bench is the expected cost of dropping the
mask: every candidate now reaches the structural matcher, which is what makes
substitution typos ("nebulx" → Nebula) matchable. At 26µs per keystroke it
sits far under the suite's one-millisecond budget, and the spec's +1ms floor
exists for exactly this kind of small constant-factor trade.

## New at-scale measurements (1,500 applications, 80-candidate budget)

| Median | Value |
| --- | ---: |
| app_search_1500_exact_us | 1285.325 |
| app_search_1500_broad_us | 875.312 |
| app_search_1500_typo_us | 553.662 |
| app_search_1500_nomatch_us | 545.238 |
| app_cold_start_ms | 5.490 |
| app_refresh_ms | 5.625 |
| app_index_storage_writes | 0 |

`app_index_storage_writes` is measured, not asserted by construction: every
catalog in the bench receives the same temporary support directory, and the
count is the number of files startup and refresh created there. Zero is the
eliminated marker-tree and FFF-database traffic.

The exact-query bench is the slowest because "studio tool 777" ties against
hundreds of candidates and pays the localized tie-break on each; a typo query
matches few and returns early. At a realistic fleet of ~150 applications the
whole path costs roughly a tenth of these numbers.

Raw logs: `/tmp/floodlight-perf-baseline-ae665ca.log` and
`/tmp/floodlight-perf-after-final.log` on the recording host.
