# FFF engine landscape: FFFKit vs fff CLI/MCP, existing bench tooling

Type: research
Status: resolved

## Question

What is the relationship between FFFKit (the XCFramework this repo pulls from vmg-dev/fff-swift), the underlying fff engine, and the `fff` CLI / MCP server f uses in Claude Code — same core or divergent implementations? What benchmarking tools or perf harnesses do those projects already ship (so we extend rather than reinvent), and what tuning knobs exist (index format, frecency weighting, content-search budgets, watcher behavior)?

Findings: `.scratch/fff-search-bench/research/fff-engine-landscape.md`

## Answer

Same core, divergent versions. FFFKit (vmg-dev/fff-swift 0.1.0, pinned at 23ac44fc) vendors a patched fork of the Rust engine dmtrKovalenko/fff at 0.7.1 (dirs-as-results, binary-name indexing, live-update fixes), built as an XCFramework via fff-c. The user's Claude Code `fff` MCP server (find_files/grep/multi_grep) is stock upstream fff-mcp 0.10.0 from nix — three minor versions ahead of the vendored base; no standalone `fff` CLI exists locally. Upstream ships 10 criterion bench targets (fff-core/fff-nvim/fff-query-parser, retained in the vendored copy) plus an end-to-end Claude-vs-native harness (scripts/benchmark-claude.sh + analyze-results.py); no CI perf job. Key knobs: content indexing/warmup/watcher/max-cached-files/idle-timeout on the MCP CLI; ai_mode, cache budgets, combo boost via fff-c (mostly hardcoded by FFFKit); frecency decay (10-day half-life, 3-day in AI mode) and grep budgets are compile-time constants.

Findings: .scratch/fff-search-bench/research/fff-engine-landscape.md
