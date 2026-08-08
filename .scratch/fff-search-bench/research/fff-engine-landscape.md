# FFF engine landscape: FFFKit vs fff CLI/MCP, bench tooling, tuning knobs

Resolved: 2026-08-05. All claims cited (URL, file:line, or local command output). Unverifiable claims are marked.

## Summary

FFFKit and the `fff` MCP server the user runs in Claude Code share **the same core** — the Rust engine in **https://github.com/dmtrKovalenko/fff** ("Faboulous & Fast File Finder", crate `fff-search`) — but at **divergent versions**:

- **FFFKit** (vmg-dev/fff-swift, pinned here at tag `0.1.0`) vendors a **patched fork of fff 0.7.1** (commit `e8dd50ce`) built as a static XCFramework via the `fff-c` C FFI crate.
- **The local MCP server** is upstream **`fff-mcp` 0.10.0** (exactly the upstream `v0.10.0` tag), run from a nix store path via `~/.claude.json`. There is **no standalone `fff` CLI** installed; `fff-mcp` is the binary and its tools in this session are `find_files` / `grep` / `multi_grep`.
- Upstream ships **substantial criterion bench suites** (10 bench targets across 3 crates, retained in the vendored copy inside fff-swift) plus an **end-to-end agent benchmark harness** (`scripts/benchmark-claude.sh` + `analyze-results.py`) — extend these rather than reinvent. There is **no CI perf job**.
- Tuning knobs span the `fff-mcp` CLI flags, the `fff-c` C API (which FFFKit mostly hardcodes), frecency decay constants, content-cache budgets, and grep time budgets — detailed in section 3.

---

## 1. Relationship: FFFKit vs fff engine vs local MCP server

### The upstream engine: dmtrKovalenko/fff

- Repo: https://github.com/dmtrKovalenko/fff — "The fastest and the most accurate file search SDK for AI agents, Neovim, Rust, C, Python, Bun and NodeJS". Latest release **v0.10.1** (2026-07-20). (Source: `gh repo view dmtrKovalenko/fff --json description,latestRelease`.)
- Rust workspace crates (`gh api repos/dmtrKovalenko/fff/contents/crates`): `fff-core` (the engine, published as crate **`fff-search`**), `fff-c` (C FFI), `fff-grep`, `fff-mcp` (the MCP server), `fff-nvim` (Neovim plugin backend), `fff-python`, `fff-query-parser`.
- `crates/fff-core/Cargo.toml`: `name = "fff-search"`, `version = "0.10.1"`, description "a fast and extremely correct file finder SDK with typo resistance, SIMD, prefiltering, and more". (https://raw.githubusercontent.com/dmtrKovalenko/fff/main/crates/fff-core/Cargo.toml)
- README (https://raw.githubusercontent.com/dmtrKovalenko/fff/main/README.md): typo-resistant path + content search, frecency ranking, background watcher, in-memory content index; MCP server section documents Claude Code / Codex / Cursor integration. Install scripts still reference `fff.nvim` URLs — the repo appears to have been renamed from `fff.nvim` to `fff` (inferred from those URLs; rename itself not directly verified).

### FFFKit: vmg-dev/fff-swift

- Repo description: "A Swift package for Floodlight's vendored FFF file search engine" (`gh api search/repositories?q=fff+user:vmg-dev`).
- README (https://raw.githubusercontent.com/vmg-dev/fff-swift/main/README.md): "FFF Swift packages a Floodlight-focused build of [FFF](https://github.com/dmtrKovalenko/fff) as a static XCFramework … The vendored FFF source is based on version 0.7.1".
- `Vendor/fff/UPSTREAM.md` (https://raw.githubusercontent.com/vmg-dev/fff-swift/main/Vendor/fff/UPSTREAM.md): vendors **fff 0.7.1 at commit `e8dd50ce5a6857f2dc7f827746163a4b1040ba9c`**, with these Floodlight-specific modifications:
  - retain common binary formats for filename-only indexing;
  - index **ancestor directories as first-class search results**;
  - keep files and directories current after live filesystem changes;
  - expose the corresponding configuration through the C API;
  - build `fff-c` as a static library for XCFramework distribution.
  - Updates are imported with `git subtree`.
- `Vendor/fff/` is a full copy of the upstream monorepo (all 7 crates present: `gh api repos/vmg-dev/fff-swift/contents/Vendor/fff/crates`).
- Swift surface is small: `Sources/FFFKit/FFFIndex.swift` + `FFFModels.swift`, calling `fff_create_instance3` / `fff_search_mixed` / `fff_free_*` from the `CFFF` module.

### The local `fff` MCP server (what the user's `find_files`/`grep`/`multi_grep` tools hit)

- `which fff` → **not found**. There is no standalone `fff` CLI on this machine; the "CLI" is the MCP server binary itself.
- `~/.claude.json` → `mcpServers.fff`:
  ```json
  { "type": "stdio",
    "command": "/nix/store/rbfxj0nmkac0651xr054ffrr0j66kw7c-fff-mcp-0.10.0/bin/fff-mcp",
    "args": [], "env": {} }
  ```
- `fff-mcp --version` → `fff-mcp 0.10.0 (31be2242234df9eb44851f3a59bf007e96986a44)`. That commit is upstream's "chore: release 0.10.0" and is exactly what the upstream `v0.10.0` tag dereferences to (`gh api repos/dmtrKovalenko/fff/git/tags/33005aaa…` → `31be2242… v0.10.0`). So the local server is a **stock upstream 0.10.0 build**, packaged via nix (a `fff-mcp-aarch64-apple-darwin.drv` in `/nix/store` indicates a fetched prebuilt darwin binary).
- Session tool names are `find_files`, `grep`, `multi_grep` (this session's fff MCP instructions). The upstream README refers to the tools as `fffind`/`ffgrep`/`fff-multi-grep`; the naming difference between README prose and the 0.10.0 binary's registered tool names was not further verified.

### Verdict: same core, three versions in play

| Artifact | Engine version | Delta |
|---|---|---|
| FFFKit XCFramework (this repo) | fff **0.7.1** + fff-swift patches (dirs-as-results, binary-name indexing, live-update fixes, C API additions) | patched fork |
| Local `fff-mcp` (Claude Code) | fff **0.10.0** stock | 3 minor versions ahead of vendored base |
| Upstream latest | fff **0.10.1** | — |

Benchmark implication: results from the local MCP server do **not** directly characterize Floodlight's engine — three minor versions of core drift plus fff-swift's behavioral patches (notably directory results) separate them.

## 2. Existing bench tooling (extend, don't reinvent)

### Criterion micro/meso benches (in-repo, also present in the vendored copy)

Found via `gh api "search/code?q=repo:dmtrKovalenko/fff+criterion"`; bench registrations confirmed in each crate's `Cargo.toml` (`harness = false`, criterion 0.5 with `html_reports`):

- `crates/fff-core/benches/`: `parse_bench.rs`, `bigram_bench.rs`, `memmem_bench.rs`, `glob_bench.rs` (requires `zlob` feature), `grep_bench.rs`
- `crates/fff-nvim/benches/`: `fuzzy_search_bench.rs`, `grep_bench.rs`, `query_tracker_bench.rs`, `scan_bench.rs`
- `crates/fff-query-parser/benches/`: `parse_bench.rs`

The **vendored copy in fff-swift retains the `benches/` dir** (`gh api repos/vmg-dev/fff-swift/contents/Vendor/fff/crates/fff-core` lists `benches`), so `cargo bench --manifest-path Vendor/fff/Cargo.toml` can benchmark **exactly the patched 0.7.1 engine Floodlight ships**, and the same bench names can run against upstream 0.10.x for A/B comparison.

### End-to-end agent benchmark harness

- `scripts/benchmark-claude.sh` (https://raw.githubusercontent.com/dmtrKovalenko/fff/main/scripts/benchmark-claude.sh): runs real Claude Code instances against a fixture repo, fff-MCP mode vs native Glob/Grep/Read mode, comparing tokens, cost, turns, and whether the right file was found; per-concept iterations, 10 named search "concepts" (fuzzy-function-search, api-endpoint-discovery, …), `MAX_TURNS=10`, 5-min timeout per concept/mode. Both modes connect the MCP so context overhead is identical.
- `scripts/analyze-results.py`: aggregates the per-iteration JSON results.
- This is the harness behind the README's `chart.png` comparison (inferred; not explicitly stated in the repo).

### CI

- Upstream `.github/workflows/rust.yml` contains **no bench/perf job** (`rg -i 'bench|perf'` over the fetched file → no matches). Workflows are: external-tests, lua, nix, panvimdoc, python, release, rust, spelling, stylua.
- fff-swift CI (`.github/workflows/ci.yml`) only runs `make cargo-test` (vendored `fff-search` + `fff-c` tests) and `make test` (XCFramework build + Swift tests). No benches.

## 3. Tuning knobs a benchmark could vary

### `fff-mcp` CLI flags (local 0.10.0 binary, `fff-mcp --help` output)

- Positional: `PATH` (base dir to index), `NO_CONTENT_INDEXING` (disable content index; slower grep, less RAM)
- `--frecency-db <PATH>` / `--history-db <PATH>` — index/DB location
- `--no-warmup` — disable eager mmap warmup after initial scan (lazy mmap on first grep)
- `--content-indexing` — force content indexing even with `--no-warmup`
- `--no-watch` — disable the background FS watcher (scan once at startup)
- `--max-cached-files <N>` — files kept persistently in memory (default **30 000**; env `FFF_MAX_CACHED_FILES`); beyond it, temporary mmaps per grep
- `--follow-symlinks` — off by default (cyclic symlinks can wedge the watcher)
- `--idle-timeout-secs` — default **900** (env `FFF_MCP_IDLE_TIMEOUT_SECS`)
- `--log-file`, `--log-level`, `--no-update-check`, `--healthcheck`

### C API knobs (vendored `fff-c`, what FFFKit can reach)

`fff_create_instance3` (Vendor/fff/crates/fff-c/src/lib.rs:230): `base_path`, `frecency_db_path`, `history_db_path`, `enable_mmap_cache`, `enable_content_indexing`, `watch`, **`ai_mode`**, `include_binary_files`, `log_file_path`, `log_level`, `cache_budget_max_files`, `cache_budget_max_bytes`, `cache_budget_max_file_size`.

`fff_search_mixed` (lib.rs:539): `current_file` (proximity context), `max_threads`, `page_index`, `page_size` (default 100), `combo_boost_multiplier`, `min_combo_count` (default 3).

**What Floodlight actually sets** (`Sources/FFFKit/FFFIndex.swift`): init exposes `rootURL`, `storageURL`, `enableContentIndexing` (default true), `includeBinaryFiles` (default true), `watch` (default true), `logFilePath`, `logLevel`. `start()` hardcodes `ai_mode=false`, `enable_mmap_cache=true`, cache budgets `0,0,0` (engine defaults); DBs go to `~/Library/Application Support/FFFKit/frecency.lmdb` + `history.lmdb` unless `storageURL` is set. `search()` hardcodes `max_threads=0`, `page_index=0`, `limit` default 60, `combo_boost_multiplier=100`, `min_combo_count=3`, `current_file=nil`. So combo-boost, ai_mode, cache budgets, and current-file proximity are C-API-variable but fixed at the Swift layer — a bench harness varying them must call the C API (or patch FFFKit).

### Frecency / ranking parameters (`crates/fff-core/src/dbs/frecency.rs`, upstream main)

- Storage: **LMDB via heed** — per-file `VecDeque<u64>` of access timestamps, bincode-encoded; map size 10 MiB, on-disk cap `SIZE_CAP_BYTES = 12 MiB` (DB is erased at open when exceeded), stale-entry GC.
- Decay: `DECAY_CONSTANT = 0.0693` (ln(2)/10 → **10-day half-life**), `MAX_HISTORY_DAYS = 30`, `MAX_TIMESTAMPS_PER_FILE = 128`.
- **AI mode**: `AI_DECAY_CONSTANT = 0.231` (**3-day half-life**), `AI_MAX_HISTORY_DAYS = 7`.
- Modification-recency boost `MODIFICATION_THRESHOLDS`: 16 pts ≤2 min, 8 pts ≤15 min, 4 pts ≤1 h, 2 pts ≤1 day, 1 pt ≤1 week; AI-mode compressed variant: 16 pts ≤30 s … 1 pt ≤4 h.
- These are **compile-time constants**, not runtime config — varying them means rebuilding the engine. (Verified on upstream main; assumed similar in the vendored 0.7.1, not line-verified there.)

### Engine constants (`crates/fff-core/src/constants.rs`, upstream main)

- `MAX_FFFILE_SIZE = 10 MiB` — grep read cap + content-cache mmap cap
- `MAX_INDEXABLE_FILE_SIZE = 2 MiB` — bigram (content prefilter) build cap
- `MAX_CACHED_CONTENT_BYTES = 512 MiB` — persistent content mmap cache budget
- `MMAP_THRESHOLD = 16 KiB` (aarch64) / 4 KiB — below this, chunked reads instead of mmap
- `FRESH_MMAP_THRESHOLD = 1 MiB` (macOS) — at/above this, direct mmap on cache miss
- `MAX_OVERFLOW_FILES = 1024` — watcher-discovered files beyond this force a **full rescan**

### Grep/search budgets (`crates/fff-mcp/src/server.rs`, upstream main)

- `GrepSearchOptions`: `max_file_size: 10 MiB`, `page_limit: 50`, `time_budget_ms: 0` (unbounded) for single grep; **`time_budget_ms: 3000`** in the multi-pattern path (server.rs:629); `max_results` default 20; `SCAN_READY_TIMEOUT = 30 s`.

### Build-level knobs (fff-core Cargo features)

`ripgrep` (default pure-Rust walker/glob: ignore+globset) vs `zlob` (Zig-compiled C glob lib, used by CI/release); `mimalloc-collect`; `definitions` (POC definition classification of grep hits); `ffi`.

## 4. Version pinned in this repo

- `/Users/martinfan/devv/floodlight/Package.swift:14-17` — depends on `https://github.com/vmg-dev/fff-swift`, `from: "0.1.0"`; product `FFFKit` (line 23).
- `/Users/martinfan/devv/floodlight/Package.resolved` — pins `fff-swift` **version 0.1.0**, revision **`23ac44fc572967f60e3ddf3c857438f30c60111c`**.
- Transitively: FFF engine **0.7.1 base** (`e8dd50ce`) + fff-swift patches, per `Vendor/fff/UPSTREAM.md`.

## Could not verify / caveats

- Whether the fff-swift `main` branch content cited above is identical to the pinned `0.1.0` tag (`23ac44fc`) — README/UPSTREAM/FFFIndex were fetched from `main`; the repo is young and `0.1.0` is its only release, so drift is unlikely but unverified.
- Frecency/engine constants were read from upstream `main` (0.10.1-era); the vendored 0.7.1 copies were not line-verified and may differ slightly.
- The claim that `chart.png` was produced by `benchmark-claude.sh` is an inference.
- Exact MCP tool-name history (`fffind`/`ffgrep` vs `find_files`/`grep`/`multi_grep`) across versions was not traced.
