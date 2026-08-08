# Scope the bench: which search surfaces, which working set

Type: grilling
Status: resolved

## Question

Two scoping decisions only f can make:

1. **Which search surfaces does the bench measure?**
   - (a) Floodlight end-to-end — keystroke to ranked results in the app,
   - (b) the `fff` CLI / MCP server that agent workflows (Claude Code) use,
   - (c) both, as separate bench suites sharing corpus + query set.
2. **What is the "daily working set"?** Which roots count (e.g. `~/devv`, dotfiles, `~/Documents`, Downloads?), roughly how many files that is, and whether private path names may appear in bench fixtures/results committed to this repo — or whether bench data must stay untracked.
3. **Spotlight's role, given it's off**: ticket 05 found Spotlight indexing is *disabled* on this Mac (`mdutil -s`). Re-enable it (at least for bench roots) so `mdfind` is a live baseline, or demote Spotlight to an optional baseline and lean on `fd`/`fzf` for comparisons?

Resolve via /grilling, one question at a time. The answer fixes the frame for metrics (06) and corpus design (07).

## Answer

Decided with f (2026-08-05, grilling session):

1. **Surfaces: both, phased.** Phase 1 benches the fff engine/MCP surface headlessly (what Claude Code agents feel; fastest to stand up). Phase 2 adds Floodlight's `SearchCoordinator` pipeline via the headless seam ticket 02 found. One shared corpus + query set across both — the vendored-0.7.1 vs stock-0.10.0 engine gap becomes a built-in A/B.
2. **Working set: three corpus tiers.** `~/devv` (~87k visible / ~458k total files) is the fast tier, run every bench; `~/Documents` is the docs tier; whole-home (`~`) is the slow/realism tier, run occasionally. Whole-home subsumes the others; run cadence is ticket 07's design space. Dotfiles are not a distinct root.
3. **Privacy: code only in the public repo.** Harness code is committed; query sets, mined history, and all results live in a gitignored directory — no real paths or queries are ever published.
4. **Spotlight: stays disabled.** `mdfind` drops out of the bench. `fd` and `fd | fzf --filter` are the speed/ranking baselines; relevance is judged against `history.lmdb` ground truth (ticket 04). A one-time Spotlight snapshot (user-run `sudo mdutil`) remains available later if a "vs Spotlight" number is ever wanted.
