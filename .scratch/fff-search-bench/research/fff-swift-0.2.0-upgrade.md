# fff-swift 0.2.0 upgrade: does it actually improve speed/robustness/memory?

Resolved: 2026-08-08. Triggered by f asking whether to pick up vmg-dev/floodlight's
`9a829c6b2bf39cec4abd951024854e9d88fd02be` ("Update FFF Swift to 0.2.0 (#2)") before
migrating this fork. All claims cited. Extends [fff-engine-landscape.md](fff-engine-landscape.md)
(the 0.7.1-vs-0.10.0 version-gap research from ticket 03) now that a concrete upgrade PR exists upstream.

## Summary

**Worth taking.** The bump closes the exact version gap ticket 03 flagged (fff-swift's vendored
engine was 3 minor versions behind). It carries concrete, named fixes for crashes, an LMDB
disk/handle-bloat bug, and a macOS-specific indexing perf fix — not vague "misc improvements."
The Swift-facing `FFFIndex` API is unchanged, so integration risk is low. **No upstream benchmark
numbers exist for any of this** — every claim below is from commit/release-note text, not measured
data. This repo's own bench harness (ticket 08, not yet built) is the only way to get real
before/after numbers; that work is still open and would be the rigorous way to confirm this rather
than trust the changelog.

## What the commit actually does

- `vmg-dev/floodlight@9a829c6b` ("Update FFF Swift to 0.2.0 (#2)", upstream floodlight repo):
  2-file, 4-line change — bumps `Package.swift`'s `fff-swift` requirement from `"0.1.0"` to
  `"0.2.0"` and updates `Package.resolved` to match. No engine code lives in this diff itself.
- The real work is upstream in `vmg-dev/fff-swift`: release **0.2.0** (commit `c446afc`,
  Aug 7) = PR #1 **"Upgrade vendored FFF to 0.10.3"** (commit `08efe3c`, Aug 7) — a 290-file,
  +39,773/−14,629 line `git subtree` re-vendor pulling the upstream `dmtrKovalenko/fff` copy
  in `Vendor/fff/` from **0.7.1** (commit `e8dd50ce`, pinned in this repo today via
  `fff-swift` 0.1.0 / `Package.resolved` revision `23ac44f`) to **0.10.3** (commit
  `e2cad2f0`). That's 172 upstream commits of drift closed in one PR.
  (https://github.com/vmg-dev/fff-swift/commit/08efe3c,
  https://raw.githubusercontent.com/vmg-dev/fff-swift/main/Vendor/fff/UPSTREAM.md)

## Per-dimension verdict

### Search speed — weak evidence, plausible
- `perf: Improve performance for no link time optimization builds (#455)` — build-config perf,
  not algorithmic.
- `fix(pi-fff): dedup concurrent aux finders and bound grep time` (0.10.3) — bounds worst-case
  grep latency and avoids redundant concurrent work; a tail-latency win more than a median one.
- No criterion bench numbers are published in any release note between 0.7.1 and 0.10.3.
  Upstream *has* the criterion suites (`fff-core/benches/*`, retained in the vendored copy —
  see ticket 03) that could produce real numbers, but nobody ran them for this changelog.
- **Verdict: can't confirm "faster search" from the changelog alone.** Would need the bench
  harness (ticket 08) or a manual `cargo bench` A/B on the vendored copy.

### Robustness / bug-free — strong evidence, the clearest win
Concrete, named fixes landed between 0.7.1 and 0.10.3
(https://api.github.com/repos/dmtrKovalenko/fff/compare/v0.7.1...v0.10.3,
https://github.com/dmtrKovalenko/fff/releases/tag/v0.10.3):
- `fix: Segmentation fault updating frecency (#456)`
- `fix: Segfault on dropping picker mid-rescan (#465)`
- `fix: Panic in query parsing if query contains wrong bracket expr (#483)`
- `fix: LMDB stale readers and automatic compactions (#468)` — see memory note below
- `fix(pi-fff): stop reopening main LMDB envs in aux finders` (0.10.3)
- `fix: Not finding if needle contains "!="` (0.10.3) — correctness, not just crash-safety
- `fix: gitignore incompatibility` and `empty directory handling during scans` (0.10.3)
- Security: git2 bumped to 0.21.0 for a RUSTSEC advisory (0.10.3)
- **Verdict: yes, materially more robust.** Two segfaults and a panic in query parsing are the
  kind of bugs that would currently be live in this fork's 0.7.1 base if triggerable from
  Floodlight's usage (frecency updates and mid-rescan teardown are both things Floodlight does
  routinely via `FFFIndex.track()` and the background watcher).

### Indexing speed — direct, named evidence
- `perf: Improve macOS indexing wall time (#457)` — explicitly macOS, explicitly indexing,
  explicitly wall-clock. This is Floodlight's exact platform and exact hot path
  (`FFFIndex.start()` / `.rescan()`).
- `fix: Reduce amount of rescans in giant $HOME like folders` (0.10.3) — directly relevant to
  the "whole-home slow tier" this repo's bench project already scoped (ticket 01); fewer
  full rescans on watcher overflow is a real indexing-cost reduction for large trees.
- New 0.10.3 feature: configurable home-directory scanning with warnings when indexing `$HOME`,
  plus exposed home/filesystem-root scanning options — governance around the exact scenario
  the reduced-rescans fix targets.
- **Verdict: yes, this is the best-evidenced of the four claims** — one commit is titled
  literally "macOS indexing wall time," which is a direct answer to the "index faster?"
  question.

### Memory — indirect but real
- `fix(pi-fff): stop reopening main LMDB envs in aux finders` (0.10.3) — each reopened LMDB
  environment holds its own mmap and file handles; deduping this reduces both RSS and open-fd
  count for the "aux finder" pattern (parallel/secondary search instances).
- `fix: LMDB stale readers and automatic compactions (#468)` — this is the standard LMDB
  failure mode: a stale reader transaction pins old pages and blocks the free-list from
  reclaiming space, so the on-disk (and page-cache-resident) database grows unbounded over
  time. `frecency.rs`'s on-disk cap is only 12 MiB before forced erase (per ticket 03's
  research), so uncontrolled growth there was already a latent problem this fix addresses.
- No RSS/heap benchmark numbers published either way.
- **Verdict: a real bug fix with memory/disk implications, not a "reduced memory footprint by
  X%" feature.** Frame it as "fixes a slow memory/disk leak," not "uses less memory."

## Integration risk: lower than the 172-commit/290-file diff suggests

- All four Floodlight-specific patches from `Vendor/fff/UPSTREAM.md` survived the re-vendor
  onto 0.10.3 (binary-format exclusion from filename indexing, ancestor directories as
  first-class search results after incremental FS changes, the C API exposure for that config,
  and the static-lib XCFramework build) — confirmed by diffing `UPSTREAM.md` on `main` against
  the copy this repo currently vendors.
  (https://raw.githubusercontent.com/vmg-dev/fff-swift/main/Vendor/fff/UPSTREAM.md)
- The internal C API changed shape (`fff_create_instance3` → `fff_create_instance_with`, an
  options-struct constructor, plus new functions: `fff_search_directories`, `fff_live_grep`,
  `fff_get_scan_progress`, `fff_restart_index`, `fff_track_query`) — but this is entirely
  encapsulated inside `FFFKit`; Floodlight's own code never imports `CFFF` or calls `fff_*`
  directly (verified: `rg "CFFF|fff_create_instance|fff_search_mixed"` over `Sources/` returns
  nothing — only `FFFIndex(...)` construction in `SearchCoordinator.swift` and
  `ApplicationCatalog.swift`).
- **The public `FFFIndex` Swift surface is byte-identical** between the 0.1.0 copy vendored
  today and `main` (0.2.0): same `init` signature (`rootURL`, `storageURL`,
  `enableContentIndexing`, `includeBinaryFiles`, `watch`, `logFilePath`, `logLevel`, `homeURL`),
  same `start()`, `search()`, `searchFiles()`, `searchDirectories()`, `progress()`,
  `searchContent()`, `rescan()`, `changeRoot(to:)`, `track(query:selectedURL:)`. Diffed directly:
  `.build/checkouts/fff-swift/Sources/FFFKit/FFFIndex.swift` (0.1.0, local checkout) vs.
  `https://raw.githubusercontent.com/vmg-dev/fff-swift/main/Sources/FFFKit/FFFIndex.swift`.
- **Verdict: this should be a drop-in `Package.resolved` bump** — no call-site changes expected
  in `SearchCoordinator.swift` or `ApplicationCatalog.swift`. Still run `make cargo-test` +
  `make test` (fff-swift's own CI targets) plus this repo's `SearchPerformanceTests` after
  bumping, given the size of the underlying diff.

## Could not verify / caveats

- No side-by-side benchmark numbers exist anywhere in this chain (upstream release notes,
  fff-swift release notes, or the floodlight PR) — every performance/memory claim above is
  qualitative, sourced from commit titles and release-note prose, not measurement.
- Did not verify whether the criterion bench suites (`fff-core/benches/*`) still run cleanly
  against the 0.10.3 vendored copy, or whether the 0.7.1→0.10.3 constants ticket 03 flagged
  (`DECAY_CONSTANT`, `MAX_CACHED_CONTENT_BYTES`, `MMAP_THRESHOLD`, etc.) changed values —
  those are compile-time and weren't diffed line-by-line for this note.
- Did not check whether `fff-mcp` (the Claude Code MCP server, separately pinned via nix at
  0.10.0 per ticket 03) is affected by this at all — it isn't; this bump is FFFKit-only.
