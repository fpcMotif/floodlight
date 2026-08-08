# Build the bench harness, produce first baselines

Type: task
Status: open
Blocked by: 02, 05, 06, 07

## Question

Execution ticket (per the map's plan-don't-do override): build the harness skeleton per the decided metrics (06), corpus/query set (07), pipeline seams (02), and baseline runners (05). Extend, don't reinvent: ticket 03 found upstream fff already ships 10 criterion bench targets (retained in the vendored copy inside fff-swift) and an end-to-end agent harness (`scripts/benchmark-claude.sh` + `analyze-results.py`). Deliverables: a repeatable `make bench`-style entry point, per-run results persisted (JSON or similar, in a gitignored data dir per ticket 01), and the **first baseline comparison: FFF vs `fd` / `fd|fzf` on the `~/devv` fast tier** (mdfind is out — Spotlight indexing stays disabled per ticket 01). Those numbers sharpen the "which optimizations" fog on the map into tickets.
