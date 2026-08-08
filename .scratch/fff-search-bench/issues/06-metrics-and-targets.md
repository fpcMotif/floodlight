# Choose metrics and "lightning-fast" targets

Type: grilling
Status: resolved
Blocked by: 01, 04

## Question

Which metrics define done, and at what numbers?

- **Speed**: p50/p95 end-to-end query latency? time-to-first-result? keystroke-to-paint (if Floodlight UI is in scope per 01)? cold vs warm index runs?
- **Accuracy/relevance**: success@1 / success@10, MRR of the intended file — feasible only in the form ticket 04 found ground truth for.
- **Targets**: what counts as lightning-fast for f — e.g. p95 under N ms on the daily working set, intended file in top 3 for M% of history queries — and which target failing should count as a bench regression.

Resolve via /grilling once 01 (scope) and 04 (ground-truth availability) are closed.

## Answer

Decided with f (2026-08-06, grilling session):

1. **Speed: per-layer p50/p95, warm and cold on separate clocks.** Warm p95 targets on the `~/devv` tier: engine (`FFFIndex.search`/fff-core) ≤ 50 ms; fff MCP tool round-trip ≤ 200 ms; Floodlight keystroke→results-painted ≤ 150 ms (deliberately includes the 35–180 ms debounce so debounce tuning is visible work). Cold-start tracked separately, engine ≤ 500 ms, informational.
2. **Relevance: success@3 ≥ 90% is the headline** — the intended file appears in the top 3 for ≥90% of replayed history queries (`~/devv` tier) — with **MRR as a trend line** to catch rank drift within the top 3. Scoring replays (query → opened URL) ground-truth pairs, skipping pairs whose target no longer exists.
3. **Regression policy: rolling-baseline gates.** A run FAILS if any layer's warm p95 worsens >20% vs the median of the last 5 runs, or success@3 drops >2 points. Absolute targets are reported met/unmet but don't gate until first achieved. Cold-start and MRR stay informational.
