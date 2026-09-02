# Floodlight engine field guide

Facts mined from the 2026-09-02 audit records (explorer maps, finding evidence, reviewer verdicts): 3292 raw facts, 3283 unique, consolidated per domain. Facts only, no proposals. Where a reviewer overturned a claim, the corrected truth is stated and the claim is listed under "Corrected on review". Evidence is path:line at Floodlight commit 936926b, fff-swift 0.2.1 (vendored fff 0.10.5), or upstream fff 0.10.6. Source tags are audit finding IDs (F = Floodlight, U = upstream).

Rendered version: https://claude.ai/code/artifact (see the session's Floodlight Engine Field Guide artifact).

## Contents

- [How the C interface is called](#c-abi)
- [Build: cargo profiles, features, walkers, toolchain](#build-cargo)
- [Build: XCFramework, SwiftPM, linker flags, sizes, CI](#build-xcframework-swiftpm-linker)
- [Query pipeline: parsing, typo budget, prefilter, SIMD matching](#engine-matching)
- [Query pipeline: scoring, frecency, combo boost, query tracker](#engine-scoring)
- [Query pipeline: directories, mixed search, sorting and pagination](#engine-dirs-mixed-pagination)
- [How the index is built, warmed, and kept fresh](#engine-index)
- [How content search (live grep) works](#grep)
- [Floodlight: Search Execution stages, tokens, cancellation, readiness](#swift-search-execution)
- [Floodlight: catalogs, fuzzy matcher, ranking, blocklist, recents](#swift-catalogs-ranking)
- [Floodlight: coordinator, projection, publication, observation](#swift-coordinator-projection)
- [Floodlight: clipboard capture, SQLite store, inspector](#swift-clipboard)
- [Floodlight: launch order, panel, hotkeys, SwiftUI, caches](#swift-shell-ui-launch)
- [Floodlight: other shell and engine facts](#swift-misc)
- [macOS and toolchain facts](#macos-system)
- [How to prove a change with a bench](#bench-measure)
- [Claims the reviewers overturned or corrected](#corrections)

<a id="c-abi"></a>
## How the C interface is called

Floodlight talks to the Rust search engine through one C header, fff.h, generated from the fff-c crate. Swift builds a single long-lived instance by filling in a versioned FffCreateOptions struct and calling fff_create_instance_with; the resulting FffInstance bundles a shared file picker, a shared frecency tracker, a shared query tracker, and a watch-callback slot behind Rust's own locks. Every call — search, grep, scan-progress, watch, wait — goes through that one handle, returns heap-allocated result structs, and reports failure through a uniform FffResult envelope rather than through a Rust panic reaching Swift. Search and mixed-search take a read lock on the file picker and share a max_threads path that resolves to available_parallelism(); grep instead runs under its own thread pool and its own (currently unconfigurable) abort behavior. Only grep's match struct carries byte-offset/match-range data — plain file-search results never do — and every C string or array crossing the boundary is caller-owned, freed through matching fff_free_* functions. The Swift wrapper (FFFIndex.swift) populates a subset of the available option fields, hardcodes several C-side parameters (thread count, abort signal, trim behavior) to fixed defaults, and leaves a handful of engine capabilities — cancellation tokens, warmup-readiness, several pagination and count accessors — unused or unexposed on the Swift side.

### Creating and configuring an instance

- FffInstance (the opaque handle returned to Swift) bundles four fields: a shared file picker, a shared frecency tracker, a shared query tracker, and an Arc<WatchCallbackSlot> for the watch callback. `fff-c/src/lib.rs:35-41` `U8`
- FFF_CREATE_OPTIONS_VERSION is 3, the field FffCreateOptions carries for ABI backwards-compatibility checks. `ffi_types.rs:22-65` `U9` `U21`
- The FffCreateOptions C struct exposes 17 configuration fields (base_path, frecency_db_path, history_db_path, enable_mmap_cache, enable_content_indexing, watch, ai_mode, log_file_path, log_level, three cache_budget_max_* fields, enable_fs_root_scanning, enable_home_dir_scanning, follow_symlinks, include_binary_files, version); Floodlight's Swift wrapper populates only 11 of them. `fff.h:73-147; FFFIndex.swift:72-90` `ffi-header cluster` `U1` `U9`
- Floodlight's options enable mmap cache, content indexing, and file watching, set ai_mode false, leave home-directory scanning as an init parameter, and always set the three cache_budget_max_* fields (files, bytes, file size) to 0, which fff-c documents as "use defaults" (auto-compute). `FFFIndex.swift:74-90, 83-85; fff-c/src/lib.rs:174` `record36` `record40` `U12`
- include_binary_files sits at byte offset 83 in the FffCreateOptions memory layout. `ffi_types.rs:813` `U21`
- FffCreateOptions has no field for a custom ignore list — only file paths, boolean flags, and cache sizes. `fff.h:110-146` `U47`
- fff_create_instance_with routes construction through FilePicker::new_with_shared_state. `fff-c/src/lib.rs:183 -> 256` `U13`
- The QueryTracker is only initialized when history_db_path is supplied; fff_get_historical_query then returns up to 128 stored query entries per project. `fff-c/src/lib.rs:229-241, 1056-1091; query_tracker.rs:12` `U38` `U25`
- init_tracing (and the log file it opens) is only reachable when log_file_path is supplied in the options. `fff-c/src/lib.rs:200-205` `U3`

### Search calls: fuzzy_search and fuzzy_search_mixed

- fff_search calls picker.fuzzy_search; fff_search_mixed calls picker.fuzzy_search_mixed. `fff-c/src/lib.rs:337, 384, 539, 585` `U62`
- fff_search_mixed takes a read lock on the file picker (inst.picker.read()) before searching. `fff-c/src/lib.rs:362` `U15`
- fff_search and fff_search_mixed both accept page_index/page_size for result pagination. `fff.h:559` `ffi-header cluster`
- FFFIndex.swift passes a literal max_threads=0 to all three of its calls (fff_search_mixed, fff_search, fff_search_directories); 0 resolves inside file_picker.rs to available_parallelism() along two separate fuzzy-search paths, then flows through ScoringContext into neo_frizbee::match_list_parallel_resolved for the actual parallel matching. `FFFIndex.swift:126, 201, 258; file_picker.rs:1063-1070, 1161-1168; score.rs:75, 82, 107, 336, 360, 657-662` `U6`
- combo_boost_score_multiplier defaults to 100 and min_combo_count defaults to 3 in fff.h; Floodlight passes exactly these values to fff_search_mixed. `fff.h:548-549; FFFIndex.swift:127` `U14` `U5`

### Grep calls: live_grep and multi_grep

- fff_live_grep takes 12 positional parameters — handle, query, mode, max_file_size, max_matches_per_file, smart_case, file_offset, page_limit, time_budget_ms, before_context, after_context, classify_definitions; fff_multi_grep is a separate export in the C ABI. `fff.h (fff_live_grep signature); fff.h:655` `U85`
- Floodlight calls fff_live_grep with a 10 MB per-file cap and a 35 ms execution time budget, passing mode=0 (the capped plain-text sink). `FFFIndex.swift:341-361, 353` `F62` `U9`
- fff-c hardcodes trim_whitespace:false when building GrepSearchOptions for grep calls, even though the Rust type and engine both support the field — trimming is left entirely to the Swift layer. `fff-c/src/lib.rs:671; grep/types.rs:107; grep.rs:661-663` `U9`
- fff-c hardcodes abort_signal:None identically for both fff_live_grep (lib.rs:672) and fff_multi_grep (lib.rs:754), so time_budget_ms is the only way to bound a grep — there is no cancellation token at the C boundary at all. `fff-c/src/lib.rs:672, 754` `U2` `U7` `U33`
- fff_grep_match_get_line_content simply returns the pointer the Rust sink already truncated; the C API has no length accessor and no max-line option. `fff-c/src/accessors.rs:224-229` `U15` `U9`
- fff_live_grep and fff_multi_grep return a next_file_offset for continuing a grep across pages (also exposed via the uint32_t accessor fff_grep_result_get_next_file_offset); Floodlight never calls that accessor. `fff.h:294, 1264; FFFIndex.swift:352-366` `ffi-header cluster` `U1` `U85`

### Scan progress, watch, and wait calls

- FffScanProgress has four fields: scanned_files_count (u64), is_scanning, is_watcher_ready, is_warmup_complete. `fff.h:305-310; ffi_types.rs:167-182` `U9` `U20`
- is_warmup_complete is not a stored atomic — it is computed on each read from enable_content_indexing && sync_data.bigram_index.is_some(). `file_picker.rs:1437-1438` `U55`
- fff_get_scan_progress only surfaces signals.scanning, with no separate post_scan_indexing_active signal; it boxes a fresh FffScanProgress plus its FffResult wrapper, both of which Swift must free. `file_picker.rs:1431; fff-c/src/lib.rs:829-852; FFFIndex.swift:326, 333` `U12` `U13`
- FFFIndex.swift drops the is_warmup_complete field entirely when reading scan progress, so Swift never learns whether the bigram index is ready. `FFFIndex.swift:330-337; FFFModels.swift:70-77` `U81`
- fff_is_scanning reads the scanning bit directly, with no picker lock and no heap allocation. `fff-c/src/lib.rs:786-796` `U55`
- fff_wait_for_scan takes the picker's read lock exactly once, clones the underlying Arc<AtomicBool>, and polls that clone lock-free afterward; the corresponding fff-core primitive is a blocking poll_until. `fff-c/src/lib.rs:851-864; shared.rs:150-163; file_picker.rs:154-166` `U55` `U75`
- fff_wait_for_watcher returns a struct FffResult*, not a bool. `fff.h:715` `U85`
- FffWatchCallback is `unsafe extern "C" fn(watch_id: u64, batch: *FffWatchEventBatch, user_data: *c_void)`; FffWatchEvent.kind is a u8 with 0=created, 1=modified, 2=removed, 3=rescan. `watch.rs:45-46, 30-34` `U10`
- Floodlight passes watch:true to fff_create_instance_with, so the watcher's internal polling/event engine is genuinely exercised. `FFFIndex.swift (initialization)` `U61`
- FFFIndex's own contract states that startup, rebuild, and scope changes only finish once a query can observe an atomic snapshot of the index. `FFFIndex.swift:683-685` `F57`

### Result and match structs across the FFI boundary

- Every call returns through a common FffResult envelope: bool success, char* error, void* handle, int64_t int_value. `fff.h:48-65` `ffi-header cluster`
- FffSearchResult carries a heap-allocated items array (FffFileItem), a heap-allocated scores array (FffScore), count (u32), total_matched, total_files, and a location. `fff.h:153-418; ffi_types.rs:81-119` `ffi-header cluster` `U9`
- FffFileItem holds relative_path, file_name, and git_status as C strings, size/modified as u64, four frecency-related score fields, and is_binary; neither it nor FffSearchResult ever carries match-range or byte-offset data. `ffi_types.rs:139-183, 137-149, 280-317` `U9` `U25`
- FffGrepResult holds a heap-allocated items array, count, total_matched, total_files_searched, filtered_file_count, and an optional regex_fallback_error string; each has its own accessor (fff_grep_result_get_total_matched, _get_filtered_file_count, _get_regex_fallback_error). `ffi_types.rs:38-84; fff.h:1231, 1255, 1273` `U9` `U85`
- FffGrepMatch is the only struct that carries match_ranges (plus context_before/after arrays, line/byte/col position, fuzzy_score, is_binary, is_definition); it has its own accessors for ranges count, a given range, and column. `ffi_types.rs:135-163, 340, 367-371; fff.h:242, 253, 1112, 1121, 1055` `U9` `U25` `U85`
- FffScore breaks a match's total into base_score, filename_bonus, frecency_boost, distance_penalty, current_file_penalty, combo_match_boost, path_alignment_bonus, an exact_match bool, and a match_type string. `ffi_types.rs:187-199` `U9`
- FffMixedItem allocates three separate CStrings per result — relative_path, display_name, and git_status (empty for directories) — with display_name a standalone allocation rather than an offset into relative_path; since no length field is exposed, Swift's String(cString:) must strlen every one. `fff-c/src/ffi_types.rs:673` `U22`
- FffMixedSearchResult includes total_matched and total_files fields at the C boundary, but Floodlight never reads them. `fff-c/src/lib.rs` `U20`

### Ownership: strings, arrays, and free functions

- Every C string field in a result struct is allocated with CString::new and must be freed by the caller via the matching fff_free_* function. `ffi_types.rs:93-94, 170-182` `U9`
- Heap arrays cross the boundary through vec_to_raw: a Vec becomes a boxed slice, then a raw pointer plus count, with the Rust side forgetting it — the caller owns and must free the result. `ffi_types.rs:98-107` `U9`
- FFFIndex.swift uses only fff_free_* deallocators for everything it receives over FFI, with exactly one exception: a bare libc free() on a realpath buffer. `include/fff.h:769, 799, 818, 837, 845, 854, 881; FFFIndex.swift:129, 137, 204, 212, 261, 269, 324, 332, 369, 377, 485` `U1`

### Locking, concurrency, and panics

- SEARCH_THREAD_POOL is installed only around grep and multi_grep, never around fuzzy_search, so plain search and grep parallelize through different mechanisms. `file_picker.rs:1380, 1411` `U6`
- The picker's parking_lot::RwLock is writer-preferring, so a running or pending watcher write (an index rebuild) makes search calls queue up behind it. `fff-core/src/shared.rs:78` `U77`
- watch.rs:290 wraps the caller-supplied C watch callback in std::panic::catch_unwind on its dispatcher thread; switching the crate's panic strategy to panic=abort would silently defeat this, turning a caught-and-logged panic into a full process abort. `watch.rs:275-296` `U60`
- FFFIndex.swift detects failure through the FffResult.success/error envelope, not by catching Rust panics — Swift only sees a panic if the C layer has already turned it into that envelope. `FFFIndex.swift:131-133` `U29`

### Unused and underused C API surface

- Floodlight does not call fff_glob, context-line options, match highlighting, definition classification, git-status refresh, or watch events from the C API, and never calls the file-level pagination accessor fff_grep_result_get_next_file_offset even though it exists. `record36; fff.h:1264; FFFIndex.swift:352-366` `record36` `U1`
- The only tracking export is fff_track_query, which writes solely to the QueryTracker; there is no fff_track_access symbol, so file-access frecency has no C entry point (fff-nvim has separate access-tracking calls that fff-c doesn't mirror). `fff.h:741; fff-c/src/lib.rs:1000-1048; fff-nvim/src/lib.rs:532, 549, 576` `U5` `U10`
- Eight symbols Floodlight never calls — including the ones above — are nonetheless real #[unsafe(no_mangle)] pub unsafe extern "C" fn definitions in fff-c/src/lib.rs and src/watch.rs, not stubs. `fff-c/src/lib.rs; fff-c/src/watch.rs` `U61`

### Build-time backend: allocator, walker, and vendoring

- fff-c declares no #[global_allocator], unlike sibling crates fff-nvim and fff-mcp, which both set up mimalloc; fff-c therefore runs on the platform's default allocator (system libmalloc on macOS), and the mimalloc-collect feature is documented as fff-nvim-only. `fff-c/src/lib.rs:1-30; fff-nvim/src/lib.rs:27-28; fff-mcp/src/main.rs:19-20; file_picker.rs:2446-2448; Cargo.toml:51-53` `U63` `U52` `U1`
- The vendored zlob directory walker (v1.6.3) has a UTF-8 offset bug — basename_offset_in_relative() is computed on raw bytes while the path is stored via String::from_utf8_lossy() — but it's compile-time dormant because Floodlight's build-xcframework.sh (rustup stable, no Zig) defaults to the ripgrep backend, and Floodlight's Package.swift pulls a prebuilt CFFF.xcframework.zip that already links the ripgrep walker. A non-boundary offset would panic in file_picker.rs:2100-2101 or hit undefined behavior in simd_path.rs:139/192/208 — not silently mis-score names. `zlob.rs:68-85; Vendor/fff/Cargo.toml:39; build-xcframework.sh:17-24; Floodlight Package.swift:26-29; fff-swift/Package.swift:11-17; ci.yml:17-26` `U58` `U57`
- Upstream fff builds exclusively against zlob (--no-default-features --features zlob) and installs Zig in CI to do it; Floodlight's own CI never installs Zig, so it can only build the ripgrep backend. `Vendor/fff/Makefile:53-54; release.yaml:265; ci.yml:17-26` `U57`
- SIMD paths are runtime-gated: memmem.rs and case.rs both check std::is_x86_feature_detected("avx2") on x86_64 before using AVX2 code; SIMD_CHUNK_BYTES is 16, which makes the filename_cow zero-copy borrow fast path apply only rarely. `memmem.rs:331; case.rs:122; simd_path.rs:7` `U67` `U9`
- PATH_BUF_SIZE is platform-dependent — 1024 on macOS (libc::PATH_MAX), 4096 on Windows — not a universal 4096; read_to_buf only ever copies min(byte_len, buf.len()) bytes into it. `constants.rs:44-48; simd_path.rs:168-186` `U27`
- log.rs installs a custom panic hook and a SIGSEGV handler (via signal-hook-registry), but both are only wired up from inside init_tracing — so they exist only when Floodlight supplies a log_file_path. `fff/log.rs:86-119, 232-233` `U65`
- The vendored fff-swift dependency sits at commit 459ebcdb (tag v0.10.5); the fork's diff against that tag touches 7 files, and upstream's own v0.10.5..HEAD has 5 commits — 3 real code changes (non-UTF8 zlob handling, a ZLOB_PERIOD change, a clippy pass) plus version bumps. `diff against fff v0.10.5; git log v0.10.5..HEAD` `U5`
- fff-c ships a standalone C smoke test whose main(int argc, char **argv) takes an optional base_path argument (argc > 1 ? argv[1] : "."). `fff-c/tests/smoke.c:200-201` `U72`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| FFF_CREATE_OPTIONS_VERSION | 3 | `ffi_types.rs:22-65` |
| FffCreateOptions fields (C struct / Swift-populated) | 17 total / 11 set by Floodlight | `fff.h:73-147; FFFIndex.swift:72-90` |
| include_binary_files struct offset | 83 bytes | `ffi_types.rs:813` |
| combo_boost_score_multiplier / min_combo_count defaults | 100 / 3 | `fff.h:548-549; FFFIndex.swift:127` |
| max_threads passed by Floodlight to all search calls | 0 (resolves to available_parallelism()) | `FFFIndex.swift:126,201,258; file_picker.rs:1063-1070` |
| Floodlight's fff_live_grep per-file cap / time budget | 10 MB / 35 ms | `FFFIndex.swift:341-361` |
| fff_get_historical_query entry cap | 128 entries per project | `fff-c/src/lib.rs:1056-1091` |
| PATH_BUF_SIZE | 1024 on macOS (libc::PATH_MAX), 4096 on Windows | `constants.rs:44-48` |
| SIMD_CHUNK_BYTES | 16 | `simd_path.rs:7` |
| Vendored zlob version | 1.6.3 | `Vendor/fff/Cargo.toml:39` |
| Vendored fff-swift commit / tag | 459ebcdb / v0.10.5, fork diff touches 7 files | `diff against fff v0.10.5` |

### Gotchas

- is_warmup_complete looks like a status flag Swift could poll cheaply, but it's recomputed on every read from enable_content_indexing && bigram_index.is_some() — it isn't a stored atomic. `file_picker.rs:1437-1438`
- catch_unwind guards the watch-callback dispatcher thread today; flipping the crate to panic=abort wouldn't be a no-op — it would silently turn caught, logged panics into full process aborts. `watch.rs:275-296`
- fff_wait_for_watcher's name suggests a bool return, but the header declares it returns struct FffResult*. `fff.h:715`
- PATH_BUF_SIZE isn't a fixed 4096 everywhere — it's 1024 on macOS via libc::PATH_MAX. `constants.rs:44-48`
- abort_signal is hardcoded to None for both fff_live_grep and fff_multi_grep, so a grep's only real bound is time_budget_ms — there is no way to cancel one mid-flight at the C boundary. `fff-c/src/lib.rs:672,754`
- FffScanProgress carries is_warmup_complete, but FFFIndex.swift drops that field entirely when reading scan progress, so Swift never actually learns whether the bigram index has finished warming up. `FFFIndex.swift:330-337`
- SEARCH_THREAD_POOL only wraps grep and multi_grep — plain fuzzy search parallelizes through an entirely separate max_threads=0/available_parallelism() path, so the two call families don't share one thread-pool story. `file_picker.rs:1380,1411`
- The zlob walker has a live UTF-8 offset bug, but it stays dormant only because Floodlight's build never actually links zlob (ripgrep backend by default, no Zig in CI) — a build-config change could silently reactivate it. `zlob.rs:68-85; build-xcframework.sh:17-24`
- fff-c has no #[global_allocator] while its siblings fff-nvim and fff-mcp both opt into mimalloc, so the identical engine code runs on different allocators depending on which host process links it. `fff-c/src/lib.rs:1-30; fff-nvim/src/lib.rs:27-28`

### Corrected on review

- ~~PATH_BUF_SIZE is 4096~~ → PATH_BUF_SIZE is 1024 on macOS (libc::PATH_MAX), 4096 on Windows, not universally 4096 `constants.rs:44-48`
- ~~A non-character-boundary basename_offset would silently mis-score names~~ → It would cause a panic in file_picker.rs:2100-2101 or undefined behavior in simd_path.rs:139/192/208 `file_picker.rs:2100-2101, simd_path.rs:139`
- ~~is_warmup_complete is an atomic~~ → is_warmup_complete is computed from enable_content_indexing and sync_data.bigram_index.is_some(), not stored as an atomic `file_picker.rs:1437-1438`
- ~~No catch_unwind anywhere in fff-c or fff-core; no behavior change from panic=abort~~ → catch_unwind exists at watch.rs:290 inside the dispatcher thread guarding caller-supplied C callbacks; panic=abort would silently defeat this, turning caught-and-logged panics into full process aborts `watch.rs:275-296, Cargo.toml profile inheritance`
- ~~bool fff_wait_for_watcher(void *fff_handle, uint64_t timeout_ms);~~ → fff_wait_for_watcher returns struct FffResult *, not bool `fff.h:715`

<a id="build-cargo"></a>
## Build: cargo profiles, features, walkers, toolchain

This section covers how Floodlight's vendored fff Rust workspace is compiled into the XCFramework Swift consumes: the build script's path/toolchain discovery, which walker backend and Cargo features ship by default, the Cargo release profiles in force, why the crate compiles two library outputs but uses only one, what dependencies get linked in unconditionally, how panics behave across the FFI boundary, the ripgrep walker's internal mechanics, and how CI pins (or fails to pin) the Rust toolchain. The recurring theme is a mismatch between where the vendored fff repo's own config files (`.cargo/config.toml`, `rust-toolchain.toml`) live and where cargo actually looks for them when invoked with `--manifest-path` from the fff-swift package root — several of those config files are silently never applied to the shipped build. A second theme is the workspace defaulting to the `ripgrep` walker feature while upstream releases and tests default to `zlob`, and building both `cdylib` and `staticlib` crate-types under full LTO even though only the `staticlib` is ever consumed.

### Build script & toolchain path discovery

- Cargo discovers .cargo/config.toml and rustup discovers rust-toolchain.toml by walking up from the process's current working directory, not from --manifest-path. `build-xcframework.sh:4-24; cargo/rustup documentation` `U24` `U59`
- build-xcframework.sh and the Makefile's cargo targets invoke cargo with --manifest-path against Vendor/fff/Cargo.toml but run from the fff-swift package root without cd'ing into Vendor/fff, so Vendor/fff/.cargo/config.toml and rust-toolchain.toml are never discovered or applied. `build-xcframework.sh:4-24; Makefile:7,13,14,21` `U24` `U59`
- As a result, Vendor/fff/.cargo/config.toml's rustflags for -undefined dynamic_lookup never apply to the XCFramework build. `Vendor/fff/.cargo/config.toml:1-5` `U24`
- Vendor/fff/.cargo/config.toml specifies macOS link args but sets no target-cpu for aarch64. `Vendor/fff/.cargo/config.toml:1-5` `U6` `U28`
- The RUSTFLAGS environment variable replaces cargo config.toml's rustflags array rather than appending to it, so setting RUSTFLAGS='-C target-cpu=apple-m1' would silently drop the -undefined dynamic_lookup link arg. `cargo build system semantics` `U28`
- Vendor/fff/rust-toolchain.toml specifies channel="stable", but this pin is likewise never discovered by the XCFramework build for the same cwd-vs-manifest-path reason. `Vendor/fff/rust-toolchain.toml:1-2` `U10` `U11`
- build-xcframework.sh has no instrumentation or profile-use stage for profile-guided optimization (PGO). `fff-swift/scripts/build-xcframework.sh:18-24` `U10`
- A proposed fix that cd's into Vendor/fff before building would newly apply -C link-arg=-undefined -C link-arg=dynamic_lookup to the cdylib link, which risks breaking the XCFramework build on modern ld64. `build-xcframework.sh:19-26; Vendor/fff/.cargo/config.toml:3-6; crates/fff-c/Cargo.toml:11-12` `U59`

### Feature flags & walker backend selection (ripgrep vs zlob)

- fff-c/Cargo.toml (~line 14-15) and fff-core/Cargo.toml (line 41) both declare default=["ripgrep"], making the pure-Rust ripgrep walker the shipped default backend. `crates/fff-c/Cargo.toml:14-15; crates/fff-core/Cargo.toml:41` `U22` `U50` `U57` `U83`
- build-xcframework.sh passes no --features flag (lines 19-24), so cargo builds fff-c with the default ripgrep walker rather than zlob. `fff-swift/scripts/build-xcframework.sh:19-24` `U22` `U50` `U83`
- Vendor/fff/Makefile builds its release and test targets with --no-default-features --features zlob (lines 45-54, 98) — upstream ships and tests the Zig-glob walker, diverging from the XCFramework's default-ripgrep build. `Vendor/fff/Makefile:45-54,98` `U22` `U23` `U2`
- fff-swift's own CI (Makefile:6-14) runs cargo test with the default feature set only; it does not exercise the zlob feature-set tests that upstream's Makefile runs. `fff-swift/Makefile:6-14` `U2`
- Upstream fff v0.10.6 added two zlob-gated regression tests — invalid_utf8_paths.rs (261 lines) and dotdir_glob_constraint_test.rs (98 lines) — that fff-swift's default-features CI never executes. `Vendor/fff/Makefile:98` `U2`
- Walker backend is selected at compile time via #[cfg(feature="zlob")] vs #[cfg(all(not(feature="zlob"), feature="ripgrep"))] in walk/mod.rs:11-19. `walk/mod.rs:11-19` `U57` `U58`
- Upstream commit 973c859 adds GLOB_FLAGS guarded by #[cfg(feature="zlob")] in constraints.rs, and commit 81517a0 changes walk/zlob.rs — a module only built under the zlob feature — so neither change affects the ripgrep-default XCFramework build. `upstream fff commits 973c859, 81517a0` `U22`
- is_known_binary_extension_basename (file_picker.rs:2347) is gated behind #[cfg(feature="zlob")], so it is absent from the default ripgrep-built XCFramework. `file_picker.rs:2347` `U50`

### Cargo release profiles (release / ci / prof)

- Workspace [profile.release] (Vendor/fff/Cargo.toml:55-59) sets opt-level=3, lto="fat", codegen-units=1, strip="debuginfo", with no explicit panic key (defaults to panic="unwind") and no debug key. `Vendor/fff/Cargo.toml:55-59` `U25` `U7` `U8` `U70` `U69` `U29`
- This release profile applies workspace-wide, so both of fff-c's crate-types (cdylib and staticlib) undergo the same fat-LTO, codegen-units=1 compilation. `Vendor/fff/Cargo.toml:55-59` `U69`
- [profile.release]'s fat LTO plus codegen-units=1 forecloses eliminating unreachable code that sits behind live runtime conditional branches. `reasoning over Cargo.toml:55-59` `U65`
- [profile.ci] (Cargo.toml:61-65) has weaker settings than [profile.release], and its comment assumes a march=native local build — a setting the XCFramework build never applies. `Vendor/fff/Cargo.toml:61-65` `U6` `U69`
- [profile.prof] (Cargo.toml:70-76) sets debug="full", strip=false, lto="thin", inherits release, and is documented for Instruments/xctrace profiling. `Vendor/fff/Cargo.toml:70-76` `U8` `U70`
- build-xcframework.sh hardcodes --release (line 22) and the output path .../release/libfff_c.a (line 26), with no environment variable or code path to select profile.prof instead. `fff-swift/scripts/build-xcframework.sh:22,26` `U70`

### Crate types: dual cdylib + staticlib

- fff-c/Cargo.toml declares crate-type=["cdylib","staticlib"] (lines 11-12); upstream fff v0.10.5 declared only ["cdylib"] — the staticlib target is a Floodlight addition. `crates/fff-c/Cargo.toml:11-12` `U7` `U27` `U69`
- build-xcframework.sh runs cargo build --package fff-c --release with no --crate-type filter, so both outputs compile, but line 26 consumes only libfff_c.a — the cdylib output is discarded. `fff-swift/scripts/build-xcframework.sh:19-26` `U7` `U69`
- Each declared crate-type undergoes its own full fat-LTO, codegen-units=1 compilation; building both under divergent codegen requirements prevents sharing a single LTO codegen pass, roughly doubling codegen time (no exact multiplier is established — see corrections). `Cargo.toml:55-59; build-xcframework.sh:19-26` `U27` `U69`
- Roughly half of the fat-LTO build's wall time produces the libfff_c.dylib that the XCFramework then discards. `build-xcframework.sh consumes only .a` `U27`
- `make build` invokes build-xcframework.sh, so the default Makefile build target pays this double-codegen cost even though only the staticlib is ever used. `Makefile:3-4` `U69`
- The Node package (via ffi-rs) and Bun package (via bun:ffi dlopen) load the cdylib output, so the dual crate-type declaration is necessary for those upstream consumers even though Floodlight's XCFramework build doesn't need it. `Vendor/fff structure` `U69`
- Upstream's own release.yaml builds with --profile ci (lto="thin"), while fff-swift's build uses --release (lto="fat") — fff-swift's staticlib is already more heavily optimized than upstream's shipped release artifact. `upstream release.yaml; Cargo.toml` `U69`
- cargo rustc --package <name> --crate-type staticlib is a stable (since Rust 1.64) mechanism to override the manifest's declared crate-type for a single invocation without editing Cargo.toml. `cargo documentation` `U69`

### Vendored / unconditional dependencies

- git2 is declared in Vendor/fff/Cargo.toml:68 as {workspace=true} with no optional=true, making it an unconditional dependency of fff-core. `Vendor/fff/Cargo.toml:68` `U64` `U2`
- The workspace pins git2 to 0.21.0 with default-features=false and features=["vendored-libgit2"], vendoring the full libgit2 C source; Cargo.lock resolves this to libgit2-sys 0.18.7+1.9.6. `Vendor/fff/Cargo.toml:68; Cargo.lock` `U2` `U64`
- fff-core/Cargo.toml:85-86 unconditionally declares tracing-subscriber and tracing-appender=0.2 (with the env-filter feature) as non-optional dependencies. `fff-core/Cargo.toml:85-86` `U3` `U65`
- The env-filter feature transitively pulls in regex-automata 0.4.14 and matchers. `Cargo.lock:2096` `U3`
- serde_json is pulled into fff-c/Cargo.toml:24 purely to serve an unused health check at lib.rs:1108. `crates/fff-c/Cargo.toml:24; lib.rs:1108` `U26`
- neo_frizbee 0.11.0 is a crates.io dependency (Cargo.toml:42), not vendored; it has zero of its own dependencies and manages its own thread pool rather than using rayon. `Cargo.toml:42; Cargo.lock:1528-1531` `U6` `U36`
- The mimalloc-collect feature (fff-core Cargo.toml:51-53) requires the consuming binary to have already installed mimalloc as the global allocator; hint_allocator_collect (file_picker.rs:2445-2459) is entirely guarded by #[cfg(feature="mimalloc-collect")] and is a no-op when the feature is off. `fff-core/Cargo.toml:51-53; file_picker.rs:2445-2459` `U1` `U52`
- fff-c depends on fff-core with default-features=false, so mimalloc-collect is not enabled in the XCFramework build. `crates/fff-c/Cargo.toml; crates/fff-core/Cargo.toml:51-53` `U63`
- hint_allocator_collect is called after the parallel sort in the cold-start walk (file_picker.rs:2159-2160) and again after bigram compression (bigram_filter.rs:899). `file_picker.rs:2159-2160; bigram_filter.rs:899` `U52`

### FFI panic/unwind behavior

- All FFI entry points in fff-c are plain extern "C" functions with no panic-catching (no catch_unwind). `crates/fff-c/src/lib.rs:183` `U25`
- A panic that reaches an extern "C" boundary aborts the process under Rust 1.81+. `finding-25 analysis` `U25`
- Unwind support (landing pads, exception tables, personality routines) costs an estimated 5-12% of binary size for panic-heavy crates. `finding-25 analysis; Rust codegen for unwinding` `U25` `U29`
- Setting panic="abort" in a Cargo profile applies to the whole compiled dependency graph — since fff-c depends on fff-core, a panic=abort profile for fff-c would force fff-core to recompile under panic=abort too. `crates/fff-c/Cargo.toml; cargo documentation` `U60`

### ripgrep walker backend internals

- The ripgrep walker accumulates every discovered file into a single global parking_lot Mutex<Vec<_>> (declared walk/ripgrep.rs:39-40) that every walker thread locks (line 64) to append results; walk_collect_files only yields output after the full traversal completes — there is no incremental/streaming output. `walk/ripgrep.rs:39-40,64` `U43` `U50`
- Each visited entry calls entry.metadata() (ripgrep.rs:60), a stat syscall estimated at roughly 1 microsecond. `walk/ripgrep.rs:60` `U50`
- ripgrep.rs:23 sets .hidden(!is_git_repo) using the `ignore` crate's hidden-file detection, which treats "hidden" as leading-dot-only on Unix; ignore crate 0.4.25 has no logic for the macOS UF_HIDDEN file flag. So hidden files are skipped only outside a git repo, and a non-git home-directory watch falls through to is_non_code_directory (background_watcher.rs:870-889) instead. `walk/ripgrep.rs:23; background_watcher.rs:870-889; Cargo.lock:1180` `U45` `U47`
- ripgrep.rs:27 sets .ignore(true) unconditionally, so .ignore files are honored in the base path and subdirectories regardless of git presence — but .gitignore files are only honored inside a git repository (require_git defaults true, lines 24-26). `walk/ripgrep.rs:24-27` `U48`
- WalkOutput.ignore_rules is always None for the ripgrep backend, because walk/ripgrep.rs:85 hardcodes ignore_rules: None. `walk/mod.rs:28-33; walk/ripgrep.rs:85` `U45` `U48`

### CI toolchain pinning & provenance

- Vendor/fff/rust-toolchain.toml pins channel="stable" plus five auto-installed components: clippy, rustfmt, llvm-tools, rust-src, rust-analyzer. `Vendor/fff/rust-toolchain.toml:1-9` `U59` `U73` `U10`
- .github/workflows/release.yml:40-43 installs the stable toolchain via rustup with --profile minimal, then runs rustup default stable — a floating stable channel matching rust-toolchain.toml's channel=stable. `.github/workflows/release.yml:40-43` `U11` `U59` `U73` `U8`
- --profile minimal drops the llvm-tools component that rust-toolchain.toml lists as required. `.github/workflows/release.yml:40-43` `U11`
- build-xcframework.sh passes --locked to cargo build (pinning dependency versions) but does not pin the compiler version itself. `fff-swift/scripts/build-xcframework.sh:19-24` `U73`
- Package.swift:9-10 pins only the XCFramework's output checksum/hash, with no Rust toolchain version recorded; Package.resolved likewise pins only the artifact checksum. `fff-swift/Package.swift:9-10; Floodlight Package.resolved` `U11` `U73`
- FloodlightEngine's Swift target enables only upcoming features in Package.swift:33-40, with no explicit optimization flag, so it defaults to -O. `Package.swift:33-40` `U12`

### Target-CPU / SIMD flags

- is_x86_feature_detected! caches its CPUID probe behind an atomic after first use, so steady-state runtime feature checks on x86 are a cheap cached load. `reasoning over x86 feature detection` `U67`

### Linking & dead-code stripping

- The XCFramework is a precompiled static-library binary target (Package.swift:6-17) fetched as a zip from a GitHub release, built with opt-level=3, lto="fat", codegen-units=1, strip="debuginfo". `fff-swift/Package.swift:6-17; Cargo.toml:56-59` `U61`
- ld64's -dead_strip treats exported symbols as GC roots by design; Rust #[no_mangle] pub extern "C" items get default visibility and are always kept live through rustc's LTO. `ld64 documentation; rustc LTO behavior` `U61`
- .subsections_via_symbols is emitted by both rustc's and swiftc's LLVM backends on Darwin by default, giving function-level granularity for -dead_strip even under codegen-units=1. `LLVM/ld64 documentation` `U61`

### Vendor delta vs upstream fff

- Vendor/fff/Cargo.toml:39 pins zlob to exactly 1.6.3. `Cargo.lock:3239-3242; Vendor/fff/Cargo.toml:39` `U57` `U59`
- Upstream commit 81517a0 fixes a zlob basename-offset UTF-8 desync bug and bumps the zlob pin to 1.6.5 — a fix Floodlight's 1.6.3 pin does not include. `Vendor/fff/Cargo.toml:39` `U58`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Release profile flags | opt-level=3, lto="fat", codegen-units=1, strip="debuginfo" | `Vendor/fff/Cargo.toml:55-59` |
| profile.prof settings | debug="full", strip=false, lto="thin" (inherits release) | `Vendor/fff/Cargo.toml:70-76` |
| zlob pin | 1.6.3 (upstream fixed at 1.6.5 in commit 81517a0) | `Vendor/fff/Cargo.toml:39; Cargo.lock:3239-3242` |
| libgit2-sys version | 0.18.7+1.9.6 | `fff-swift/Cargo.lock` |
| git2 version/features | 0.21.0, default-features=false, features=["vendored-libgit2"] | `Vendor/fff/Cargo.toml` |
| neo_frizbee version | 0.11.0, zero dependencies, own thread pool (not rayon) | `Vendor/fff/Cargo.toml:42; Cargo.lock:1528-1531` |
| regex-automata (transitive via env-filter) | 0.4.14 | `Cargo.lock:2096` |
| ignore crate version | 0.4.25 (no macOS UF_HIDDEN support) | `Cargo.lock:1180` |
| Unwind overhead estimate | 5-12% of binary size for panic-heavy crates | `finding-25 analysis` |
| stat syscall cost in walker | ~1 microsecond per entry.metadata() call | `walk/ripgrep.rs:60` |
| zlob-gated regression tests added upstream v0.10.6 | invalid_utf8_paths.rs (261 lines), dotdir_glob_constraint_test.rs (98 lines) | `Vendor/fff/Makefile:98` |
| Files differing from upstream fff v0.10.5 | exactly 7 files | `git diff v0.10.5..HEAD -- crates/` |
| rust-toolchain.toml components | 5: clippy, rustfmt, llvm-tools, rust-src, rust-analyzer | `Vendor/fff/rust-toolchain.toml:3-9` |
| cargo crate-type override availability | stable since Rust 1.64 (cargo rustc --crate-type) | `cargo documentation` |
| fff-c/Cargo.toml line spacing | crate-type at line 12, version strings at lines 22-23 (10 lines apart) | `crates/fff-c/Cargo.toml` |
| Discarded cdylib share of build time | roughly half of the fat-LTO build's wall time (estimate) | `build-xcframework.sh consumes only the .a output` |

### Gotchas

- The XCFramework build never reads Vendor/fff/.cargo/config.toml or rust-toolchain.toml because cargo/rustup discover these by walking up from the process cwd, not from --manifest-path — and the build scripts never cd into Vendor/fff. So the vendored rustflags (-undefined dynamic_lookup) and the stable-channel pin are dead configuration for this build path. `build-xcframework.sh:4-24; Vendor/fff/.cargo/config.toml:1-5; Vendor/fff/rust-toolchain.toml:1-2`
- RUSTFLAGS set as an environment variable replaces, not appends to, the rustflags array from .cargo/config.toml — so trying to add target-cpu via RUSTFLAGS would silently drop the existing -undefined dynamic_lookup link arg. `cargo build system semantics`
- fff-c is built with crate-type=[cdylib, staticlib] and both undergo full fat LTO, but build-xcframework.sh only consumes the staticlib output — the cdylib compile is pure waste for this build path, yet `make build` runs it every time. `crates/fff-c/Cargo.toml:11-12; build-xcframework.sh:19-26; Makefile:3-4`
- CI's rustup install uses --profile minimal, which drops the llvm-tools component that rust-toolchain.toml lists as required. `.github/workflows/release.yml:40-43`
- fff-swift's CI only tests the default ripgrep feature set; it never runs the zlob-gated regression tests upstream added in v0.10.6 (invalid_utf8_paths.rs, dotdir_glob_constraint_test.rs), even though the Makefile builds a zlob path. `fff-swift/Makefile:6-14; Vendor/fff/Makefile:98`
- .gitignore rules are only honored inside a git repository, but .ignore files are honored unconditionally in the ripgrep walker — an asymmetry that is easy to assume works the same way for both file types. `walk/ripgrep.rs:24-27`
- WalkOutput.ignore_rules is always None for the ripgrep backend, so any caller trying to introspect which ignore rules applied gets nothing back regardless of what actually happened during the walk. `walk/ripgrep.rs:85; walk/mod.rs:28-33`
- serde_json is a full dependency pulled in only to serve one unused health-check endpoint. `crates/fff-c/Cargo.toml:24; lib.rs:1108`
- All FFI entry points are plain extern "C" with no catch_unwind, and the release profile has no panic key (defaults to unwind) — a panic still pays full unwind-table cost before it can reach the extern "C" boundary and abort. `crates/fff-c/src/lib.rs:183; Vendor/fff/Cargo.toml:55-59`
- Floodlight's zlob pin (1.6.3) predates upstream's fix for a basename-offset UTF-8 desync bug, which landed in commit 81517a0 alongside a bump to 1.6.5. `Vendor/fff/Cargo.toml:39`

### Corrected on review

- ~~dotprod is optionally enabled on aarch64 only if explicitly configured via target-cpu~~ → rustc's built-in aarch64-apple-darwin target already defaults to an Apple-M1-equivalent CPU with dotprod and NEON enabled — no explicit target-cpu flag is required. `rustc --print cfg --target aarch64-apple-darwin`
- ~~normalize_bytes silently degrades to scalar on aarch64-apple-darwin without an explicit target-cpu setting~~ → NEON is mandatory for every AArch64 (ARMv8-A) implementation, so normalize_bytes's target_feature=neon path is always statically enabled on aarch64-apple-darwin. `ARM ISA specification`
- ~~dotprod dispatch causes per-call runtime overhead on aarch64-apple-darwin~~ → eq_lowered_case's is_aarch64_feature_detected!(dotprod) check (fff-core/src/simd_string_utils/case.rs:126-130) already const-folds on aarch64-apple-darwin because of the M1-default target CPU. `fff-core/src/simd_string_utils/case.rs:126-130`
- ~~Vendor/fff/rust-toolchain.toml pins the compiler version used in release builds~~ → rustup's toolchain-file discovery walks up from the process cwd, not from --manifest-path, so Vendor/fff/rust-toolchain.toml is never consulted by any of the repo's cargo invocations, including release builds. `rustup toolchain-file discovery behavior`
- ~~Building both cdylib and staticlib under fat LTO exactly doubles codegen time (a precise 2x figure)~~ → Building both crate-types under fat LTO roughly doubles codegen time because the two crate-types have divergent codegen requirements that prevent sharing one LTO pass — no exact multiplier is established. `build-xcframework.sh:19-26; Cargo/rustc LTO behavior`
- ~~The Floodlight delta touches 8 files, including CLAUDE.md and Cargo.toml files generically~~ → Exactly 7 files differ from upstream fff v0.10.5: fff-c/Cargo.toml, fff-c/include/fff.h, fff-c/src/ffi_types.rs, fff-c/src/lib.rs, fff-core/src/file_picker.rs, fff-core/src/scan.rs, fff-core/src/watcher/background_watcher.rs. `git diff v0.10.5..HEAD -- crates/`
- ~~In fff-c/Cargo.toml, version bumps sit four lines below the crate-type declaration~~ → The [lib] crate-type line is at line 12 and the version strings are at lines 22-23 — ten lines apart, not four. `crates/fff-c/Cargo.toml`

<a id="build-xcframework-swiftpm-linker"></a>
## Build: XCFramework, SwiftPM, linker flags, sizes, CI

This batch covers how Floodlight is compiled, linked, packaged, and gated by CI. Floodlight is a SwiftPM package (tools-version 6.4, Swift 6 language mode) that depends on a vendored Rust search engine (fff-core, forked from upstream fff-search 0.10.5) exposed to Swift through a C ABI and wrapped in a prebuilt CFFF.xcframework consumed via the fff-swift package. The build pipeline emits an arm64-only XCFramework, applies size optimization only to the app executable (not the search engine library), and passes a linker flag that trims unused dynamic-library references but not unused code in static archives. A Makefile chains six quality gates (format, lint, rules, architecture, build, dead-code) that CI runs on every PR; a separate, more privileged release workflow builds, code-signs, notarizes, and publishes a DMG on tag push without re-running any of those gates or the test suite. Several pieces of the pipeline are documented as measuring or asserting things (performance budgets, binary sizes, dead-code scans, index paths) that in practice are computed but never read, checked, or acted on by the surrounding scripts. The repository also carries several megabytes of binary build artifacts that were accidentally committed rather than gitignored.

### Package manifest: Swift version, concurrency, dependencies

- Package.swift sets swift-tools-version 6.4 (line 1) and swiftLanguageModes: [.v6] (line 85), requiring the Swift 6.4 compiler. `Package.swift:1,85` `F` `F11` `F150`
- Package.swift enables two Approachable-Concurrency upcoming features: NonisolatedNonsendingByDefault and InferIsolatedConformances (lines 8-10). `Package.swift:8-10` `F16` `F25` `F150`
- Package.swift declares FloodlightEngine's dependency on the fff-swift package's FFFKit product, pinned to version 0.2.1; Package.resolved records this as a binaryTarget resolved to revision dbc38f5c with binary checksum 900b222c. `Package.swift:26-40; Package.resolved; fff-swift/Package.swift:9-10` `F` `U4` `U59` `U66`
- Floodlight's Package.swift declares deployment target .macOS(.v14); fff-swift's own Package.swift also targets macOS 14. `Package.swift:19-21; fff-swift/Package.swift:21` `U5` `U26` `U67`

### Compilation optimization flags (-Osize scope)

- Package.swift's shellSettings apply -Osize only to the Floodlight executable target; FloodlightEngine (the search library) receives no such flag and compiles at the release default -O with no size or speed optimization specified. `Package.swift:8-15,33-40,42-49` `F` `F20` `U12` `U74`
- FloodlightEngine's swiftSettings apply the Approachable-Concurrency upcoming features but set no -cross-module-optimization flag. `Package.swift:33-40` `U74`
- Swift's release-mode whole-module optimization inlines calls within a module, but cross-module calls are inlined only with @inlinable or -cross-module-optimization; dynamic exclusivity checks are removed only by -enforce-exclusivity=unchecked. `Swift compiler behavior` `U74`

### Linker flags and framework linking

- Package.swift's executable linker settings pass -Xlinker -dead_strip_dylibs but never -dead_strip, so unreferenced code inside static archives is retained despite -Osize; -dead_strip_dylibs itself only drops dynamic-library load commands, not unreferenced text in static libraries. `Package.swift:50-56` `F` `F65` `U26` `U61`
- Static-library dead-code elimination happens only at the final Floodlight link step (swift build -c release); the linkerSettings apply then regardless of when the archive itself was compiled. `Package.swift:50-56` `U61`
- scripts/bundle.sh runs strip -u -r after linking, which removes only the symbol table, not unreferenced code sections. `scripts/bundle.sh:22` `U26` `U61`
- QuickLookUI and QuickLookThumbnailing are used only by QuickLookController and FileThumbnailCache, neither reachable until the Quick Look panel is opened; ServiceManagement is used only by LaunchAtLogin. `Package.swift:50-55,54` `F`
- Floodlight calls 28 of roughly 60 exported fff_* FFI symbols; it never calls fff_health_check, fff_watch, fff_unwatch, fff_set_watch_callback, fff_refresh_git_status, fff_multi_grep, fff_wait_for_scan, or fff_is_scanning, yet all remain linked in via the static archive. `grep for fff_ symbols` `U26`
- serde_json typically contributes 150-300 KB of code once statically linked into the binary. `finding-26 analysis` `U26`
- The fff module (module.modulemap) links libfff_c.a statically plus libz (compression), libiconv (character encoding), and the CoreFoundation, CoreServices, and Security frameworks. `module.modulemap:2-7` `ffi-header cluster` `U2`
- The module.modulemap's iconv/z link requirements exist to satisfy libgit2, which is statically linked inside the Rust archive. `module.modulemap` `U64`
- Floodlight ships no .entitlements file — only Sources/Floodlight/Resources/Info.plist. `repository structure` `F95`

### fff-swift / CFFF / FFFKit dependency shape

- fff-swift's Package.swift defines CFFF as a .binaryTarget fetched from a GitHub Release zip pinned by checksum 900b222c, with a local-artifact override at Artifacts/CFFF.xcframework that bypasses the checksum-pinned download. `fff-swift/Package.swift:6-17` `U66`
- fff-swift's Package.swift exports only the FFFKit Swift library as a product; CFFF itself is not exported as a product. `fff-swift/Package.swift:22-24` `U25`
- FloodlightEngine depends on the FFFKit product, but its production code imports CFFF directly (FFFIndex.swift:1), not FFFKit. `Package.swift:26-40; FFFIndex.swift:1` `U4` `U25` `U66`
- FFFKit is imported nowhere in production code; its only import site in the repo is Tests/FloodlightEngineTests/SearchModelInvariantTests.swift:1, yet it is still compiled and linked in as a declared product dependency. `Package.swift:36; grep for "import FFFKit"` `U66`
- The FFFKit Swift wrapper is roughly 750 lines (FFFIndex.swift 603 lines + FFFModels.swift 67 lines), largely duplicating logic already in Floodlight's own FFFIndex.swift and FFFModels.swift. `FFFKit source files` `U4`
- SwiftPM propagates a binaryTarget's framework/header search paths across the whole build graph rather than scoping them to the target that declares the dependency. `Package.swift dependency graph reasoning` `U66`
- Floodlight depends on fff-swift 0.2.1 as a pinned binaryTarget; changing fff-core requires rebuilding and republishing the XCFramework before Floodlight can pick up the change. `Package.swift; Package.resolved` `U9` `U67`
- A size change to FffMixedItem breaks binary ABI compatibility and forces an XCFramework rebuild, because callers index into the struct array by pointer arithmetic (result.items.add(index), lib.rs:1571-1583) rather than through a version-stamped options struct like FffCreateOptions (ffi_types.rs:14-24). `lib.rs:1571-1583; ffi_types.rs:14-24` `U16`

### build-xcframework.sh (the XCFramework build script)

- fff-swift/scripts/build-xcframework.sh defaults TARGET/RUST_TARGET to aarch64-apple-darwin with no x86_64 alternative and no lipo/universal-binary step anywhere in the script. `build-xcframework.sh:7,19-26,36-39` `U5` `U59` `U67`
- The script hardcodes --release and writes output to target/aarch64-apple-darwin/release. `build-xcframework.sh:22,26` `U8`
- The script builds CFFF.xcframework with exactly one -library argument, producing an arm64-only XCFramework. `build-xcframework.sh:36-39` `U59` `U67`
- --locked pins the Cargo.lock dependency versions but not which stable Rust toolchain compiles them — the compiler resolves to whatever "stable" is current at build time. `build-xcframework.sh:23` `U11`
- build-xcframework.sh never sets RUST_TARGET, and release.yml's call to create-release-archive.sh never exports a RUST_TARGET override either, so the arm64-only default always applies in CI releases. `build-xcframework.sh:7; fff-swift/.github/workflows/release.yml:53-57; release.yml:51-57` `U26` `U67`

### Vendored fff-core (UPSTREAM.md, divergence, compile gates)

- Floodlight vendors fff-search version 0.10.5 at commit 459ebcdbdba094843fe5339a1a7f7dae4ced2d82. `UPSTREAM.md:3-4` `U13` `U21` `U23`
- UPSTREAM.md deliberately limits the vendored fork's divergence from upstream to three behavioral deltas: a binary-format exclusion option, watcher-created directory registration, and C API exposure. `UPSTREAM.md:8-12` `U12` `U13` `U35`
- The binary-format-exclusion delta adds FileItem::new_from_walk_bytes, which currently has zero callers anywhere in the vendored tree. `file_picker.rs:498-511; rg for new_from_walk_bytes` `U21` `U22`
- Implementing include_binary_files cost 5 hunks in file_picker.rs, 3 in scan.rs, and 2 in background_watcher.rs, plus bumping FFF_CREATE_OPTIONS_VERSION from 2 to 3 and adding a new ABI field at offset 83. `vendor delta analysis` `U24`
- Between upstream v0.10.5 and v0.10.6, only 4 commits touch crates/fff-core or crates/fff-c. `git log v0.10.5..v0.10.6 -- crates/` `U82`
- Vendor/fff/Makefile (lines 126-131) contains a C smoke-test driver (test-c-smoke) used for profiling. `Vendor/fff/Makefile:126-131` `U10`
- walk/mod.rs (lines 10-18) gates its walker-implementation modules as mutually exclusive compile-time selections. `walk/mod.rs:10-18` `U83`
- sccache integration is documented in upstream fff's own release CI (fff-swift/release.yaml:249), not in Floodlight's own workflows. `fff-swift release.yaml:249` `U69`

### CI workflows (ci.yml, pages.yml)

- .github/workflows/ci.yml defines exactly three jobs — check (line 25), test (line 68), sanitizers (line 104) — all on the xcode-27 runner. `ci.yml:25,27,68,104,106` `F145` `F150` `F155`
- The check job runs make check (ci.yml:66); the test job runs make test (ci.yml:86) and make test-performance (ci.yml:93); the sanitizers job runs AddressSanitizer and ThreadSanitizer in parallel, each in its own build directory (ci.yml:104-132). `ci.yml:66,86,93,104-132` `F` `F145`
- ci.yml triggers only on pull_request and push to main. `ci.yml:11-15` `F146`
- ci.yml keys its dependency cache per job, so each job starts from a near-cold cache. `ci.yml:46,80` `F145`
- ci.yml and release.yml pin all third-party GitHub Actions by full commit SHA, while pages.yml uses floating major-version tags instead: actions/checkout@v6, withastro/action@v6, actions/deploy-pages@v5. `ci.yml:31,37,43,74,77,121,124; pages.yml:25,28,46` `F15` `F154`
- pages.yml grants permissions: pages: write and id-token: write — the highest-privilege permission set of any workflow in the repo — and deploys under environment: github-pages. `pages.yml:11-14,25-26,40-42` `F15` `F154`
- pages.yml deploys the docs site with SITE_URL: https://floodlight.vmg.dev and BASE_PATH: /. `pages.yml:34-35` `F151`
- ci.yml documents in a comment (lines 8-9) that "the release workflow is deliberately untouched by this: shipping stays decoupled from lint policy." `ci.yml:8-9` `F146`
- No workflow sets timeout-minutes on any job; GitHub Actions' own default job timeout is 360 minutes (6 hours). `rg for timeout-minutes across ci.yml/release.yml/pages.yml; GitHub Actions docs` `F18`
- EndToEndSearchTests polls with 30-second ceilings for index/catalog readiness, and the sanitizer jobs multiply every polling wait in the suite — combined with no timeout-minutes, a hung sanitizer run has no backstop short of GitHub's 6-hour default. `EndToEndSearchTests source; ci.yml sanitizer configuration` `F18`
- A repo-wide search for merge-base, is-ancestor, and gh run list returns no results — CI has no mechanism that checks prior-run history or ancestry. `rg search` `F146`

### Release pipeline (release.yml, signing, notarization, versioning)

- release.yml runs as a single tag-triggered job with exactly 8 steps — make bundle, create-dmg.sh, certificate import, codesign, notarize, gh release create — and declares environment: release, enabling GitHub's deployment protection rules and required reviewers. `release.yml:16,17,18` `F145` `F146`
- release.yml runs make bundle before exporting CODE_SIGN_IDENTITY, then calls scripts/create-dmg.sh, applies Developer ID codesigning, and notarizes; it blocks on xcrun notarytool submit --wait against Apple's service with no client-side timeout. `release.yml:68,70,136,138-148,152,161,167-171` `F145` `F146` `F18`
- release.yml publishes a notarized DMG without ever running make check, make test, make test-performance, or make install-tools. `release.yml` `F5` `F6` `F145` `F146`
- release.yml sets a 6-hour (21,600 s) keychain lock timeout via security set-keychain-settings -lut 21600 in the signing step. `release.yml context` `F18`
- release.yml mutates Sources/Floodlight/Resources/Info.plist at build time via PlistBuddy, deriving values from GITHUB_REF_NAME and GITHUB_RUN_NUMBER, but never commits the change back to the repository. `release.yml:58-65` `F21` `F160`
- The checked-in Info.plist hardcodes CFBundleShortVersionString to 0.1.0 and CFBundleVersion to 1; scripts/bundle.sh copies this file verbatim into the app bundle with no substitution, so four shipped releases all read version 0.1.0 in the tracked checkout. `Info.plist:19-22; bundle.sh:29; git tag` `F21` `F160`
- scripts/bundle.sh defaults SIGN_IDENTITY to "-" (ad-hoc signing) when CODE_SIGN_IDENTITY is unset, and performs an ad-hoc codesign in that case. `bundle.sh:9,35-41` `F145`
- The release pipeline emits no BUILDINFO/provenance file and runs no lipo or binary-size assertions anywhere in CI. `review of release workflow steps` `U73`

### Build & packaging scripts (bundle.sh, create-dmg.sh, build-app-icon.sh, install-tools.sh)

- The Makefile's check target chains 6 gates in order: format, lint, rules, architecture, build, dead-code; build runs swift build -c release; bundle depends on build and runs scripts/bundle.sh; dmg depends on bundle and runs scripts/create-dmg.sh. `Makefile:13,44-45,66-73` `F` `F145` `F146`
- bundle.sh and create-dmg.sh each emit FLOODLIGHT_BENCH metrics (binary_size_bytes; and dmg_size_bytes plus binary_size_bytes respectively), but autoresearch.sh's metric parser does not read either key. `bundle.sh:27; create-dmg.sh:46; autoresearch.sh:39-42` `F5` `F17` `F145`
- ci.yml greps only .build/performance.log for metrics, and CI never runs make bundle at all — packaging scripts are first exercised at release-tag time, not in CI. `ci.yml:68-101; release.yml:68` `F5` `F145`
- scripts/test-performance.sh runs swift test -c release --filter PerformanceTests and writes its METRIC output to .build/performance.log; make test-performance (ci.yml:93) invokes this script. `test-performance.sh:23,28,31; ci.yml:93` `F19` `F144` `F145`
- scripts/check-build.sh runs a debug build (swift build --build-tests -Xswiftc -warnings-as-errors); release-configuration compilation is instead exercised separately by test-performance.sh's swift test -c release. `check-build.sh:19; test-performance.sh:28` `F` `F145`
- bundle.sh calls scripts/build-app-icon.sh, which contains a Python-based PNG-filter/ICNS encoder with an iconutil fallback, and conditionally uses pngquant/oxipng if installed. `bundle.sh:31; build-app-icon.sh:54-217,74-90,193-205,219-221` `F145`
- release.yml never runs make install-tools, so release builds always take the pure-Python PNG/ICNS path without pngquant or oxipng compression. `release.yml; build-app-icon.sh` `F145`
- build-app-icon.sh line 149 references an undefined variable 'b' — a NameError that set -e would surface if that code path executes. `build-app-icon.sh:149` `F145`
- bundle.sh and run.sh both derive the build output path dynamically via swift build --show-bin-path. `bundle.sh:6; run.sh:6` `F155`
- scripts/install-tools.sh branches on uname -m with a catch-all fallback for x86_64. `install-tools.sh:23-36` `F155`
- scripts/create-dmg.sh defaults its DMG output to .build/Floodlight.dmg, a location already covered by the .build/ gitignore entry. `create-dmg.sh:7` `F142`

### Code-quality gates (SwiftLint, Periphery, ast-grep, Makefile)

- SwiftLint's configured complexity thresholds are file_length 665, type_body_length 586, function_body_length 119, and cyclomatic_complexity 13, documented as tracking the current worst offenders (SearchCoordinator.swift for file_length); the thresholds are only ever moved down, never back up. `.swiftlint.yml:73-109` `F` `F14` `F153`
- SearchCoordinator.swift has since grown past its documented worst-offender count: 687 raw lines / 636 excluding comment-only / 579 excluding comments and blanks. FFFIndex.swift now measures 714 raw / 701 / 622 lines. `line counts from source files` `F14`
- The architecture gate runs ast-grep scan and ast-grep test against sgconfig.yml, with probe self-tests validating that engine-scoped rules fire on the engine but not on the shell. `scripts/check-rules.sh:33-80` `F`
- Periphery excludes test targets and retains no public symbols (all Sources targets are internal), runs with strict: true, and additionally excludes Tests/FloodlightTestSupport via index_exclude — combined with exclude_tests: true this hides the entire Tests directory from the dead-code scan. `.periphery.yml:13-34` `F` `F19` `F158`
- FloodlightTestSupport is a .target, not a .testTarget, so Periphery's exclude_tests setting does not cover it on its own — it is only hidden via the separate index_exclude entry. `Package.swift:60-67` `F19` `F158`
- FloodlightTestSupport comprises five files — PropertyTesting.swift, TestDoubles.swift, SearchFixtures.swift, AdversarialCorpus.swift, ClipboardImageTestData.swift — totaling roughly 1,900 lines, all hidden from the dead-code scan. `FloodlightTestSupport directory` `F19`
- .periphery.yml hardcodes index_store_path to .build/arm64-apple-macosx/debug/index/store, even though swift build writes its index store under a triple-specific directory (e.g. .build/x86_64-apple-macosx on Intel), unlike bundle.sh/run.sh which derive the path dynamically via swift build --show-bin-path. `.periphery.yml:13; bundle.sh:6; run.sh:6` `F16` `F155`
- scripts/check-dead-code.sh documents itself as the slowest step in the check chain and the Makefile deliberately runs it last; Periphery runs exactly once per check invocation, with no second pass. `check-dead-code.sh:8-9,19; Makefile:13` `F155` `F158`
- Package.swift documents that FloodlightTestSupport depends only on FloodlightEngine, deliberately avoiding pulling the Floodlight shell target into engine tests. `Package.swift:60-66` `F147`

### Performance test budgets and CI benchmark parsing gaps

- The performance test suite asserts six latency budgets: application search 1 ms, filter/settings 1 ms, first source snapshot 5 ms, bounded selection 5 ms, fuzzy scoring 5 ms, and clipboard search 2 ms — the last measured against an in-memory database, not the WAL-backed file. `SearchPerformanceTests.swift; ClipboardHistoryPerformanceTests.swift:8; ClipboardHistoryStore.swift:22-25` `F3` `F22`
- No performance budget measures launch-to-first-keystroke latency, despite that being the headline user-facing metric. `autoresearch.sh metric parsing` `F22`
- testExpandedFFFIndexScanBenchmark is skipped unless FLOODLIGHT_RUN_INDEX_BENCH is set, and that variable is never assigned anywhere in the repository, so the benchmark — which scans a 2,500-file tree and prints expanded_fff_scan_ms without asserting any latency bound — never runs in CI. `SearchPerformanceTests.swift:161-203; rg for FLOODLIGHT_RUN_INDEX_BENCH` `F4` `F144`
- autoresearch.sh's metric parser reads only four keys (fast_application_search_us, source_immediate_snapshot_ms, top_ranked_selection_us, fuzzy_matcher_scoring_us), silently dropping clipboard_search_us, expanded_fff_scan_ms, and bundle.sh/create-dmg.sh's binary_size_bytes/dmg_size_bytes; a grep returning nothing inside set -e yields an empty string rather than an error, so these gaps fail silently. `autoresearch.sh:39-42; ClipboardHistoryPerformanceTests.swift:72; SearchPerformanceTests.swift:203` `F17` `F144`

### Repository size and committed build artifacts

- .gitignore is exactly 15 lines and has no entry for *.bc or *.dmg files. `.gitignore:15` `F1` `F142`
- 48 LLVM bitcode (.bc) files are committed at the repo root, totaling 8,885,328 bytes (8.5 MiB). `git ls-files "*.bc"` `F1` `F142`
- design/Floodlight.dmg — the only file in design/ — is a committed 3,040,244-byte (2.90 MiB) binary release artifact. `git ls-files design` `F1` `F142`
- git log attributes both the .bc files and design/Floodlight.dmg to commit 3f568c7 ("feat(search): deep path and directory navigation"). `git log --diff-filter=A` `F142`
- Combined, the committed .bc files and design/Floodlight.dmg total 11.36 MiB of repository bloat; git count-objects -vH reports a 27.36 MiB pack size overall. `combined artifact sizes; git count-objects -vH` `F142`
- Sources/**/*.swift totals exactly 12,821 lines of code, measured before build artifacts are added. `git ls-files 'Sources/*.swift'` `F1` `F142`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Swift tools version / language mode | 6.4 / swiftLanguageModes [.v6] | `Package.swift:1,85` |
| fff-swift / FFFKit pinned version | 0.2.1 (revision dbc38f5c, checksum 900b222c) | `Package.resolved; fff-swift/Package.swift:9-10` |
| Vendored fff-search version | 0.10.5 at commit 459ebcdbdba094843fe5339a1a7f7dae4ced2d82 | `UPSTREAM.md:3-4` |
| Commits touching fff-core/fff-c between v0.10.5 and v0.10.6 | 4 (not 6) | `git log v0.10.5..v0.10.6 -- crates/` |
| Deployment target | macOS .v14 (both Floodlight and fff-swift) | `Package.swift:19-21; fff-swift/Package.swift:21` |
| CI runner | xcode-27 for all ci.yml and release.yml jobs | `ci.yml:27,69/70,106; release.yml:17` |
| SwiftLint thresholds | file_length 665, type_body_length 586, function_body_length 119, cyclomatic_complexity 13 | `.swiftlint.yml:93-109` |
| Current SearchCoordinator.swift / FFFIndex.swift size | 687/636/579 lines and 714/701/622 lines respectively | `line counts from source files` |
| GitHub Actions default job timeout | 360 minutes (6 hours) — no workflow overrides it | `GitHub Actions documentation; rg for timeout-minutes` |
| Release keychain lock timeout | 21,600 seconds (6 hours) | `release.yml (set-keychain-settings -lut 21600)` |
| Committed .bc files | 48 files, 8,885,328 bytes (8.5 MiB) | `git ls-files "*.bc"` |
| Committed design/Floodlight.dmg | 3,040,244 bytes (2.90 MiB) | `git ls-files design` |
| Combined avoidable repo artifacts | 11.36 MiB | `combined artifact sizes` |
| Git pack size | 27.36 MiB (git count-objects -vH) | `git count-objects -vH` |
| Sources/**/*.swift line count | 12,821 lines | `git ls-files 'Sources/*.swift'` |
| Info.plist version fields | CFBundleShortVersionString 0.1.0, CFBundleVersion 1 (four releases shipped this way) | `Info.plist:19-22; git tag` |
| fff_* FFI symbols called vs available | 28 of ~60 | `grep for fff_ symbols` |
| serde_json code size once linked | 150-300 KB | `finding-26 analysis` |
| FFFKit wrapper size | ~750 lines (FFFIndex.swift 603 + FFFModels.swift 67) | `FFFKit source files` |
| Performance test budgets | app search 1ms, filter 1ms, snapshot 5ms, selection 5ms, fuzzy scoring 5ms, clipboard search 2ms | `SearchPerformanceTests.swift; ClipboardHistoryPerformanceTests.swift:8` |
| FFF_CREATE_OPTIONS_VERSION bump for include_binary_files | 2 -> 3, new ABI field at offset 83 | `vendor delta analysis` |
| XCFramework library count | exactly one -library argument (arm64-only) | `build-xcframework.sh:36-39` |

### Gotchas

- Every published CFFF.xcframework.zip is arm64-only (build-xcframework.sh defaults to aarch64-apple-darwin with no lipo/universal step), even though Package.swift declares .macOS(.v14), a target that also runs on Intel Macs, and CI never overrides RUST_TARGET. `build-xcframework.sh:7,19-26,36-39; release.yml:51-57; Package.swift:19-21`
- FFFKit is declared as a product dependency and compiled/linked into Floodlight, but is imported nowhere in production code — only in one test file — making it dead weight in every build. `Package.swift:26-40; grep for "import FFFKit"`
- Package.swift's -Xlinker -dead_strip_dylibs only removes unreferenced dynamic-library load commands; the executable never passes -dead_strip, so unreferenced code in statically linked archives (including ~28 of ~60 unused fff_* symbols and all of serde_json) survives into the shipped binary despite the -Osize setting. `Package.swift:50-56; grep for fff_ symbols`
- bundle.sh and create-dmg.sh emit binary_size_bytes and dmg_size_bytes as FLOODLIGHT_BENCH metrics, and the performance test suite emits clipboard_search_us and expanded_fff_scan_ms, but autoresearch.sh's parser only reads four unrelated keys — all four of these metrics are silently dropped. `bundle.sh:27; create-dmg.sh:46; autoresearch.sh:39-42; ClipboardHistoryPerformanceTests.swift:72; SearchPerformanceTests.swift:203`
- testExpandedFFFIndexScanBenchmark is gated behind FLOODLIGHT_RUN_INDEX_BENCH, a variable that is never set anywhere in the repository, so this benchmark has effectively never run in CI. `SearchPerformanceTests.swift:161-203; rg for FLOODLIGHT_RUN_INDEX_BENCH`
- release.yml builds, signs, notarizes, and publishes a public GitHub release without ever running make check, make test, make test-performance, or make install-tools. `release.yml`
- Because release.yml never runs make install-tools, release builds always take build-app-icon.sh's pure-Python PNG/ICNS path, skipping pngquant/oxipng compression that a local dev environment would normally apply. `release.yml; build-app-icon.sh:74-90,193-205`
- No workflow sets timeout-minutes anywhere, so a hung sanitizer job (whose polling waits are already multiplied) or a stalled notarytool submit --wait call has no backstop shorter than GitHub Actions' 360-minute default. `rg for timeout-minutes; release.yml:167-171`
- release.yml mutates Info.plist's version fields via PlistBuddy at build time but never commits the change, so the tracked checkout — and four shipped releases — still read CFBundleShortVersionString 0.1.0 / CFBundleVersion 1. `release.yml:58-65; Info.plist:19-22; git tag`
- .periphery.yml hardcodes its index_store_path to the arm64 debug directory, which breaks on an Intel build where swift build writes to a different triple-specific path. `.periphery.yml:13`
- Periphery's dead-code scan is blinded to Tests/FloodlightTestSupport (~1,900 lines across 5 files) via index_exclude, on top of already excluding all test targets — a .target masquerading among test-only code is invisible to the strict:true scan. `.periphery.yml:18,28; Package.swift:60-67`
- pages.yml is the only workflow using floating major-version action tags (@v6, @v5) while it simultaneously holds the highest-privilege permission set (pages: write, id-token: write) of any workflow in the repo. `pages.yml:25,28,46,11-14`
- The repository has no .gitignore entry for *.bc or *.dmg, resulting in 48 LLVM bitcode files (8.5 MiB) and a 3.0 MiB DMG being committed by accident in a single commit. `.gitignore:15; git ls-files "*.bc", design`

### Corrected on review

- ~~Swift 5.10 is sufficient to build Floodlight.~~ → Package.swift requires the Swift 6.4 compiler: swift-tools-version is 6.4 (line 1) and swiftLanguageModes is set to [.v6] (line 85). `docs/development/building.mdx:11 vs Package.swift:1,85`
- ~~pages.yml has no paths filter, so any change (including README-only edits) triggers a docs deploy.~~ → pages.yml carries a paths filter for docs/** and .github/workflows/pages.yml, so README-only changes do not trigger a Pages deployment. `pages.yml:6-8`
- ~~The Carbon, QuickLookUI, QuickLookThumbnailing, and ServiceManagement frameworks are linked into Floodlight because Package.swift:50-56 explicitly lists them alongside -dead_strip_dylibs.~~ → Swift's autolinking is what actually links these frameworks — it emits an LC_LINKER_OPTION -framework directive from each corresponding import statement (LaunchAtLogin.swift:2, QuickLookController.swift:2, FileThumbnailCache.swift:3); -dead_strip_dylibs only trims unused dynamic-library load commands after the fact. `Package.swift:50-56; LaunchAtLogin.swift:2; QuickLookController.swift:2; FileThumbnailCache.swift:3`
- ~~Appending fields to FffMixedItem is ABI-compatible, similar to how FffCreateOptions can grow.~~ → A size change to FffMixedItem breaks binary ABI compatibility and forces an XCFramework rebuild, because callers index into the array by raw pointer arithmetic (result.items.add(index)) rather than through a version-stamped struct like FffCreateOptions. `lib.rs:1571-1583; ffi_types.rs:14-24`
- ~~6 commits touch crates/fff-core or crates/fff-c between upstream v0.10.5 and v0.10.6.~~ → Only 4 commits touch crates/fff-core or crates/fff-c between v0.10.5 and v0.10.6. `git log v0.10.5..v0.10.6 -- crates/`

<a id="engine-matching"></a>
## Query pipeline: parsing, typo budget, prefilter, SIMD matching

The query pipeline starts in fff-query-parser, which splits a typed query into fuzzy text parts and structured constraints, then hands the fuzzy text to fff-core's matching engine. Matching runs through neo_frizbee, an external SIMD fuzzy-match crate, under a typo budget that floors at 2 allowed mismatches for almost any short-to-medium query (1-11 characters). A bigram index built after each filesystem scan lets grep and some prefilter paths narrow candidates before scanning; whenever that index is unavailable or returns nothing usable — during warmup, for very short patterns, or for certain regexes — the code falls back to pushing every eligible file into a Vec and sorting the whole thing by frecency, with no byte or count budget. A separate Swift-side FuzzyMatcher (five match shapes: exact, namePrefix, wordPrefix, acronym, typo) drives app/file search UI with its own ICU-based normalization and scoring hierarchy. Several Rust scoring code paths in score.rs share one specific bug: when the query's first token is a single character, the scorer reads the raw unfiltered token instead of the length-filtered one, which suppresses one bonus and misapplies two others. Almost all in-memory engine data structures — file list, path arena, directory table, bigram index — are volatile and rebuilt from scratch on every process start; only frecency and query history persist to LMDB.

### Query parsing and text normalization

- parser.parse() keeps raw_query verbatim, while lib.rs:583-599 separately parses the translated string that gets passed to fff_search_mixed. `fff-query-parser/src/parser.rs:61; lib.rs:583-599` `U8`
- MixedSearchConfig preserves a trailing slash as fuzzy text instead of parsing it as a directory constraint. `fff-query-parser/src/config.rs:236-248` `U26`
- fff-query-parser's split_whitespace emits a query Part for every whitespace-separated token, including single-character tokens, with no minimum length filter at parse time. `fff-query-parser/src/parser.rs:133` `U11`
- Calculator.Parser.parsePower() implements right-associative exponentiation (2^3^2 evaluates to 512). `Sources/FloodlightEngine/Utilities/Calculator.swift:84-91` `F`

### Fuzzy match call flow (Rust engine)

- Call chain for a non-empty query: fuzzy_search -> fuzzy_match_and_score_files -> match_and_score_in_arena (score.rs:605) -> match_fuzzy_parts (score.rs:46), which calls neo_frizbee::match_list_parallel_resolved from the external neo_frizbee 0.11.0 crate (not vendored). `fff-core/src/score.rs:605,46; fff-core/Cargo.toml` `U62`
- Query normalization and fuzzy scoring happen in score.rs via frizbee-powered pattern matching. `score.rs:33-90` `U16`
- fuzzy_match_and_score_files splits files at base_count and calls match_and_score_in_arena twice, once per arena, because match_fuzzy_parts takes only a single ArenaPtr. `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:135-160` `U32`
- For multi-part queries, fuzzy_match_and_score_files cascades through valid_parts[1..], collecting the surviving candidate set after each round. `score.rs:142-170` `U10`
- Queries of 2 or more characters reach the neo_frizbee matcher; 1-character queries skip frizbee entirely and go straight to frecency-based scoring. `score.rs:626-632, 420-435; fff-query-parser/src/parser.rs:60-100,126` `U22` `U21`
- fuzzy_search never touches the bigram prefilter: plain fuzzy queries without constraints run a full in-memory scan with no bigram-based narrowing. `file_picker.rs:1057-1128; score.rs:614-624` `U10` `U7`
- Fuzzy matching itself is a pure in-memory SIMD scan over the path arena with no syscalls. `file_picker.rs:1063-1070` `U6`
- fuzzy_match_byte_offsets_for_page allocates one String per page item and constructs one neo_frizbee::Matcher per query part, plus a per-character Vec. `score.rs:172-247` `U6` `U25`

### Threading and parallelism in the match path

- fuzzy_search (file_picker.rs:1124) does not install SEARCH_THREAD_POOL; it reaches neo_frizbee running on the global rayon pool. `file_picker.rs:1124` `U10`
- neo_frizbee's match_list_parallel_resolved and match_list_parallel both default max_threads to available_parallelism(). `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1062-1068` `U36`
- The post-match scoring loop runs single-threaded over every match, after the parallel SIMD match stage completes. `score.rs:709-885` `U4`
- The par_iter inside score_filtered_by_frecency only executes when fuzzy_parts is empty, i.e. in frecency-only/browsing mode, not on typed fuzzy queries. `fff-core/src/score.rs:953-955,167-169` `U62`
- Plain bare-text queries — the dominant per-keystroke case — hit none of the three par_iter sites in the scoring code and never install SEARCH_THREAD_POOL. `U62 correction analysis of score.rs par_iter sites` `U62`
- ArenaPtr is marked unsafe impl Send + Sync, which is what makes parallel chunking of the match_and_score_in_arena loop mechanically legal. `simd_path.rs:18-19` `U23`

### Typo budget

- max_typos is computed as (query length / 4).clamp(2, 6), applied identically in fuzzy_search (file_picker.rs:1091) and fuzzy_search_directories (file_picker.rs:1178); the value stays pinned at the floor of 2 for any query from 1 to 11 characters and only exceeds 2 once length reaches 12. `score.rs:1315; file_picker.rs:1090-1091,1178` `engine-scoring` `U2` `U21` `U28` `U32`
- For multi-part queries, each part's max_typos is separately clamped to min(global max_typos, part.len()), so short substrings get a tighter typo budget than the global value. `score.rs:46-138` `engine-scoring`
- No typo-budget parameter exists in FuzzySearchOptions or the fff-c ABI — max_typos is hardcoded inside file_picker.rs and is not client-configurable. `file_picker.rs:84-91; crates/fff-c` `U21`
- A 2-character needle with max_typos=2 matches every haystack; a 3-character needle matches anything sharing just one character with it. `file_picker.rs:1091; neo_frizbee config score.rs:646,443` `U2`
- Fuzzy matching requires at least (needle_len - max_typos) needle characters to appear in the haystack, so a 2-character query with max_typos=2 requires zero matching characters. `fuzzy_grep.rs:262-265` `U32`
- The frizbee haystack is the full relative path, not just the filename, so even a short query with a small typo budget can match a large fraction of a home-directory index. `score.rs:30` `U21`

### Multi-part query scoring bugs (short first token)

- When the query's first part is under 2 characters, the actual match runs against valid_parts[0] (length-filtered), but the scorer at score.rs:664 reads the unfiltered fuzzy_parts[0] instead. `score.rs:656-665, 53-57, 664` `U15` `U11`
- When main_needle_len==1, match_start_approx collapses to end_col, biasing nearly all matches to end_col_filename_match=true. `score.rs:677,736` `U15`
- The fallback re-match at score.rs:689 passes fuzzy_parts[0] instead of the needle that actually matched. `score.rs:689` `U15`
- The directory-path scoring twin (score.rs:428-462) correctly uses valid_parts after length-filtering, confirming that the file-path scorer's use of unfiltered fuzzy_parts[0] (score.rs:462 vs 664) is an oversight rather than intentional. `score.rs:428-462` `U15` `U11`
- score.rs:627-629 gates the Text query arm on len>=2, but the Parts arm bypasses this check entirely and calls match_fuzzy_parts directly regardless of part length. `score.rs:627-629` `U11`
- match_fuzzy_parts returns an empty result when every part is under 2 characters; in that case the Text arm falls through to score_filtered_by_frecency instead. `score.rs:59-62` `U11`
- has_uppercase and query_contains_path_separator both read the unfiltered fuzzy_parts rather than valid_parts, so a query like "A report" enables an 8-point capitalization_bonus for every candidate purely from the single-character "A" token, even though "A" is never used as an actual match needle. `score.rs:636-643` `U13`
- path_alignment_bonus requires common_suffix > 10, making it unreachable whenever main_needle_len==1. `score.rs:825-831` `U13`
- path_contains_separator also reads fuzzy_parts, so a dropped '/' token in a query like "query / src" disables the fallback path at score.rs:665. `score.rs:641` `U13`
- split_whitespace cannot produce an empty first token, which is what prevents an underflow at main_needle_len - 1. `score.rs:664` `U11`

### Scoring bonuses, thresholds, and frecency

- score.rs:668 disables the filename-fallback frizbee pass once path_matches.len() exceeds 15,000, re-enabling it when the match count is lower. `score.rs:668` `U21`
- get_modification_score() returns 0 immediately unless git_status is a modified status, so both halves of total_frecency_score are 0 for Floodlight's non-git home-directory index. `frecency.rs:362-372; score.rs:717` `U5`
- The directory table is roughly 10x smaller than the file table; DirItem is about 40 bytes, and materializing all directories costs a roughly 4 MB stream plus an 800 KB allocation — dwarfed by the parallel SIMD match that follows. `score.rs:408` `U26`

### Core data structures (arena, ChunkedString, FileItem)

- ChunkedPathStore's ChunkedString uses a SmallVec of INLINE_CHUNKS=4 chunks of SIMD_CHUNK_BYTES=16 bytes each (64 bytes inline total); this covers about 85 percent of filenames/paths, but home-directory paths regularly exceed it and heap-allocate. `simd_path.rs:7-12, 73, 263-265` `engine-scoring` `F34` `U42`
- The SIMD matcher's resolve_file_chunks reads only the 1-byte flags field and the 32-byte path field of FileItem, ignoring the other 63 bytes (implying FileItem is roughly 96 bytes total). `score.rs:32-43; types.rs:248` `U12`
- write_dir_name (score.rs:726) reads an entire directory path out of a ChunkedString into a fixed 1024-byte stack buffer, then slices the tail. `types.rs:188-199; simd_path.rs:169-186; constants.rs:45-48` `U27`

### Bigram index: query evaluation and construction

- BigramQuery evaluation uses Cow to avoid allocation on single-child queries but forces Cow::into_owned on every And/Or level. `bigram_query.rs:129,149` `U5`
- Or-node evaluation requires all children to return Some, with early-exit if any child produces a match. `bigram_query.rs:140-157` `U5`
- Combination generation for fuzzy queries enumerates all C(n, required) subsets and builds them as an OR(AND(...)) tree. `bigram_query.rs:183-248` `U5`
- sniff_binary_for_non_indexable is a serial for-loop over every file with 0 < size <= MAX_FFFILE_SIZE (10 MB) in the non-indexable partition. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:905-931` `F17`
- This post-scan binary sniff performs multi-GB read I/O starting immediately once the index becomes searchable, competing with the first fff_live_grep calls. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:905-931` `F17`
- build_bigram_index starts immediately after scanning clears, reading min(file_size, MAX_INDEXABLE_FILE_SIZE=2 MB) of every indexable file, with no byte budget, no file-count cap, and no idle deferral. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:817; scan.rs:228,240; constants.rs:9` `F21` `engine-scoring`
- Each bigram-build background thread permanently retains a 2 MB READ_BUF plus a growable NORM_BUF. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:28-31` `F21`
- The bigram builder allocates two dense bitset slabs during construction, each MAX_BIGRAM_COLUMNS(5000) * ceil(file_count/64) * 8 bytes in size; 5000 columns is documented to cover all printable bigrams with margin. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:14,70,834` `F28`
- This transient two-slab bitset cost is roughly 1.25 KB per indexable file: about 250 MB at 200k files, about 625 MB at 500k files. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:14` `F28`
- The finished (steady-state) bigram filter bitset is a single slab of 5000 columns by file_count/64 rows, about 305 MB for 500k files — smaller than the transient two-slab build cost above because it is only one slab. `bigram_filter.rs:14-15` `engine-scoring`
- The walk and bigram build together churn hundreds of MB, and libmalloc keeps freed spans in per-size magazines instead of returning them to the OS. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2448; bigram_filter.rs:896-898` `F29`
- build_bigram_index uses `return` inside a for-loop to bail on the first binary/zero-length file, silently dropping the rest of that BIGRAM_CHUNK_FILES=256 chunk from the index. `fff-swift/Vendor/fff/crates/fff-core/src/index/bigram_filter.rs:856` `F32`
- The size/binary guard inside that loop is unreachable in practice, because files[..indexable_count] is already pre-partitioned by is_indexable before the loop runs. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2140-2157` `F32`
- A file truncated to zero bytes by a filesystem-watcher event during build_bigram_index trips the is_binary/size guard and abandons the rest of its 256-file chunk. `bigram_filter.rs:849-859,856-858` `U54`
- run_post_scan calls build_bigram_index from scratch whenever content_indexing is enabled. `scan.rs:325-334` `U12`
- new_rescan inherits content_indexing and warmup flags verbatim and rebuilds the bigram index identically to a fresh scan. `scan.rs:89-90,322` `U12`

### Grep prefilter, chunk sizing, and warmup

- The grep prefilter evaluates constraints via ConstraintPlan and sorts candidates by total_frecency_score then modified time. `grep/prefilter.rs:171-175` `U38`
- The basic prefilter check is !is_deleted && !is_binary && size>0 && size<=max_file_size. `grep/prefilter.rs:77-79` `U38`
- prefilter_with_filepath_retry retries the prefilter without FilePath constraints if the first pass yields 0 files. `grep/prefilter.rs:12-48` `U38`
- Grep's chunk size starts at threads*4, and doubles up to 8K when the prefilter is "strong" (candidates under 50% of total files). `grep/grep.rs:578-593` `U39`
- NeedleFinder runs in either CaseSensitive (memchr) or CaseInsensitive (SIMD memmem) mode. `grep/grep.rs:23-87` `U39`
- When BigramFilter::query returns None (patterns under 2 bytes, or no bigram index built at all), literal_candidates returns None too, forcing prefilter_files to push every non-deleted, non-binary, size-ok file into a Vec with no early exit, then sort the entire vector by frecency before any budget check. `index/bigram_filter.rs:416-419; index/candidates.rs:37; grep/prefilter.rs:143-166,171-175` `U1` `U4` `U81`
- perform_grep detects this weak-prefilter case as files_to_search.len()*2 < ctx.total_files and sets max_chunk = (base_chunk*256).max(8*1024), doubling up to a ceiling of 8192 files per submitted chunk, which then runs to completion. `grep/grep.rs:556-612,579-585` `U4`
- Regex-mode queries can also return None from regex_candidates whenever the HIR decomposes to "any", triggering the same unbounded full-scan-and-sort path permanently, not just during cold start. `index/candidates.rs:80-82` `U4`
- The time budget at grep.rs:610-613 is only honored once all_matches.len() > 1 — zero-match and single-match queries scan the entire prefiltered candidate set regardless of time_budget_ms. `grep/grep.rs:607-618,610-613` `U2`
- Before is_warmup_complete, fff_live_grep runs with no bigram prefilter at all: literal_candidates and fuzzy_candidates both bail via ready_index(index)? when the index is None, so the full file list is materialized and sorted by frecency. `prefilter.rs:149-150,171-175; candidates.rs:37; grep.rs:365-380` `U9` `U55`
- During this warmup window, grep still runs under Floodlight's 35 ms query budget while treating every indexable file as a candidate. `FFFIndex.swift:701-704` `U55`

### Persistence and rebuild-on-restart

- FFF only persists frecency and query history to LMDB; the file list, chunked path arena, directory table, and bigram index are all volatile and rebuilt from scratch on every process start. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2187` `F19`
- commit_new_sync drops the old FileSync while holding the picker's write lock, freeing the chunked path arena, the StableVec of FileItems, the directory table, and the bigram bitsets in one step. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1499; scan.rs:189` `F23`

### Swift-side FuzzyMatcher (application/UI layer)

- FuzzyMatcher implements five match shapes: exact, namePrefix, wordPrefix, acronym, and typo (using Damerau-Levenshtein). `Sources/FloodlightEngine/Utilities/FuzzyMatcher.swift:6-12` `F`
- matchASCII (lines 90-119) is the per-keystroke, per-candidate hot path, calling extractWordsASCII, findWordPrefixASCII, findAcronymASCII, and findTypoASCII. `Sources/FloodlightEngine/Utilities/FuzzyMatcher.swift:90-119` `F`
- FuzzyMatcher.normalized applies ICU text folding with [.caseInsensitive, .diacriticInsensitive] and locale .current, allocating a new String per candidate on every call. `FuzzyMatcher.swift:121-123; also referenced at ApplicationCatalog.swift:171` `F` `F1` `F12`
- The Swift score hierarchy ranks exact (20000) above namePrefix, wordPrefix, acronym, and typo, in that order. `Tests/FloodlightEngineTests/FuzzyMatcherStressTests.swift:161-172` `F`
- Typo matches score around 8000. `FuzzyMatcher.swift:219-222` `F8`
- Typos that introduce a character entirely absent from the candidate are silently dropped by the character mask — the failure is specific to novel characters, not to substitutions generally. `ApplicationCatalog.swift:186` `F8`
- ApplicationCatalog.immediatePage runs blocklistStore.isBlocked per candidate, then applies the characterMask prefilter (line 186), then calls scoreASCII (line 233) — in that order. `ApplicationCatalog.swift:182-188,233` `F21` `F22`
- PathNavigator.findCaseInsensitiveMatch() blocks the hot path with a synchronous contentsOfDirectory() call plus a linear search for lowercased-name matches. `Sources/FloodlightEngine/Search/PathNavigator.swift:154-168` `F`
- contentEligible fires when query.utf8.count >= 3 && indexedFiles.value.count < 12 — true for nearly every 3+ character query with sparse file results. `SourceSearchEngine.swift:306` `F62`

### Clipboard history search (separate search surface)

- ClipboardHistoryStore.search falls back to in-memory localizedCaseInsensitiveContains filtering when sqlite3_prepare_v2 fails on the FTS query. `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:343-409` `F1` `F93` `F98`
- The fallback matcher, matchesSearch() (lines 405-409), tests only entry.text.localizedCaseInsensitiveContains plus an image-dimensions (WxH) match. `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:405-409` `F141`
- Of the clipboard schema-migration statements, only 3 DROP/CREATE (trigger) statements are real schema writes; the other 8 ALTERs incur parse overhead only, not a write lock. `ClipboardHistorySQLite.swift:200-264` `F94`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Typo budget formula | max_typos = (query.len()/4).clamp(2,6); floor of 2 holds for query lengths 1-11 chars, first exceeds 2 at length 12 | `score.rs:1315; file_picker.rs:1090-1091,1178` |
| Per-part typo clamp | min(global max_typos, part.len()) | `score.rs:46-138` |
| MAX_INDEXABLE_FILE_SIZE | 2 MB (bigram builder read cap per file) | `constants.rs:9; bigram_filter.rs:817` |
| MAX_FFFILE_SIZE | 10 MB (binary-sniff size threshold) | `bigram_filter.rs:905-931` |
| Bigram-build READ_BUF | 2 MB permanently retained per build thread | `bigram_filter.rs:28-31` |
| MAX_BIGRAM_COLUMNS | 5000 columns (covers all printable bigrams with margin) | `bigram_filter.rs:14` |
| BIGRAM_CHUNK_FILES | 256 files per build chunk | `bigram_filter.rs:856` |
| Transient bigram build memory (two slabs) | ~1.25 KB/file; ~250 MB at 200k files, ~625 MB at 500k files | `bigram_filter.rs:14` |
| Finished bigram filter bitset (one slab) | ~305 MB at 500k files | `bigram_filter.rs:14-15` |
| ChunkedString inline capacity | INLINE_CHUNKS=4 x SIMD_CHUNK_BYTES=16 = 64 bytes; covers ~85% of paths | `simd_path.rs:7-12,73,263-265` |
| FileItem fields read by SIMD matcher | 1-byte flags + 32-byte path (implies ~96-byte FileItem, 63 bytes unread) | `score.rs:32-43; types.rs:248` |
| write_dir_name stack buffer | 1024 bytes | `types.rs:188-199; simd_path.rs:169-186; constants.rs:45-48` |
| Filename-fallback frizbee cutoff | disabled when path_matches.len() > 15,000 | `score.rs:668` |
| Grep chunk sizing (weak prefilter) | base_chunk=threads*4; max_chunk=(base_chunk*256).max(8*1024), 2x growth, cap 8192 files | `grep/grep.rs:556-612,579-585` |
| DirItem size | ~40 bytes; full directory materialization ~4 MB stream + 800 KB allocation | `score.rs:408` |
| Swift exact-match score | 20000 (top of hierarchy) | `FuzzyMatcherStressTests.swift:161-172` |
| Swift typo-match score | ~8000 | `FuzzyMatcher.swift:219-222` |
| Warmup query budget | 35 ms, with zero bigram prefilter, treating every indexable file as a candidate | `FFFIndex.swift:701-704` |
| contentEligible gate | query.utf8.count >= 3 && indexedFiles.value.count < 12 | `SourceSearchEngine.swift:306` |
| Worst-case match-result allocation | 36 MB per query if a result Vec were sized to files.len() | `score.rs:605-661` |
| Clipboard migration writes | 3 real DROP/CREATE writes vs 8 parse-only ALTERs | `ClipboardHistorySQLite.swift:200-264` |
| neo_frizbee crate version | 0.11.0, external (not vendored) | `fff-core/Cargo.toml` |

### Gotchas

- fuzzy_search never touches the bigram prefilter at all — every plain fuzzy query without constraints runs a full in-memory scan, not a narrowed one. `file_picker.rs:1057-1128; score.rs:614-624`
- The typo budget floor is 2, not a gentle ramp from 0 — it stays at exactly 2 for every query from 1 to 11 characters long. `score.rs:1315; file_picker.rs:1090-1091`
- A 2-character query with max_typos=2 requires zero matching characters and effectively matches everything; a 3-character query matches anything sharing one character. `file_picker.rs:1091; fuzzy_grep.rs:262-265`
- The frizbee haystack is the full relative path, not just the filename, so a short low-typo-budget query can still match broadly across a large home-directory index. `score.rs:30`
- The main_needle_len==1 scoring bug suppresses the 40% exact-filename bonus rather than granting it, and disables path_alignment_bonus entirely (common_suffix>10 becomes unreachable). `score.rs:759,825-831`
- has_uppercase and query_contains_path_separator read the unfiltered first query token even when that token was too short to be used as an actual match needle — a query like "A report" gets a capitalization bonus purely from the discarded "A". `score.rs:636-643`
- The time budget in grep only applies once more than one match has already been found; zero-match and single-match queries ignore it and scan the entire candidate set. `grep/grep.rs:607-618,610-613`
- During warmup, grep runs with no bigram prefilter and treats every indexable file as a candidate, yet is still bound by the same 35 ms query budget as a warm query. `prefilter.rs:149-150; FFFIndex.swift:701-704`
- FFF rebuilds nearly everything — file list, path arena, directory table, bigram index — from scratch on every process start; only frecency and query history survive. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2187`
- Files dropped from the bigram build chunk (binary/zero-length triggers) don't just miss content indexing — they become permanently unsearchable via fff_live_grep because they never populate the candidate bitset. `grep/grep.rs:297-375; bigram_filter.rs:494`
- Wrapping neo_frizbee's already-internally-parallel matcher in an outer rayon::join would create 2N compute threads on an N-core machine — oversubscription, not added parallelism. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1062-1068`
- The binary/size guard inside the per-chunk bigram-build loop is dead code in the normal path, because the file slice it checks is already pre-partitioned by is_indexable before the loop runs. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:2140-2157`
- PathNavigator's case-insensitive path lookup does a synchronous directory listing plus a linear scan directly on the search hot path. `Sources/FloodlightEngine/Search/PathNavigator.swift:154-168`

### Corrected on review

- ~~Substitution typos never match.~~ → Only typos that introduce a character entirely absent from the candidate are silently dropped by the character mask; other substitution typos can still match. `ApplicationCatalog.swift:186`
- ~~8 ALTERs plus 3 triggers all take write locks.~~ → Only 3 DROP/CREATE trigger statements are real schema writes; the 8 ALTER statements incur parse overhead only. `ClipboardHistorySQLite.swift:200-264`
- ~~The main_needle_len==1 bug hands out the 16-40% filename bonus indiscriminately.~~ → The bug suppresses the 40% exact-filename bonus rather than granting it. `score.rs:759`
- ~~rayon::join can interleave directory and file scoring with a 40% wall-time savings.~~ → Wrapping neo_frizbee's internal parallel matcher in an outer rayon::join would create 2N compute threads on N cores — an oversubscription risk, not a parallelism win. `fff-swift/Vendor/fff/crates/fff-core/src/file_picker.rs:1062-1068`
- ~~Matched results can be pre-allocated to avoid reallocation.~~ → Match count is unknown before matching completes; sizing a result Vec to files.len() would allocate the worst case of 36 MB on every query. `fff-swift/Vendor/fff/crates/fff-core/src/score.rs:605-661`
- ~~The consequence of files dropped from the bigram build is cosmetic.~~ → Dropped files remain silently unsearchable via fff_live_grep because they never populate the candidate bitset. `grep/grep.rs:297-375; bigram_filter.rs:494`
- ~~par_iter at score.rs:953-955 runs on every typed keystroke query path.~~ → That par_iter only fires when fuzzy_parts is empty, i.e. frecency-only/browsing mode, not on typed fuzzy queries. `fff-core/src/score.rs:953-955,167-169`
- ~~SEARCH_THREAD_POOL.install() benefits per-keystroke fuzzy matching.~~ → Plain bare-text queries — the dominant per-keystroke case — hit none of the three par_iter sites and never install SEARCH_THREAD_POOL. `U62 correction analysis`

<a id="engine-scoring"></a>
## Query pipeline: scoring, frecency, combo boost, query tracker

Floodlight's file search is a Swift-to-C-to-Rust pipeline. FFFIndex (Swift) opens two LMDB databases — frecency and query history — then calls into the Rust fff-core engine via fff_search_mixed with fixed parameters (result limit, context window, fuzziness, thread count, combo threshold). Each candidate gets a Score built from a base fuzzy-match score plus several bonuses: filename match, frecency, git status, a current-file penalty, and a combo-match boost for files repeatedly opened under the same query text. Frecency is a separate on-disk tracker (its own LMDB database) that exponentially decays access and modification timestamps; it is computed once, at filesystem-walk time, and only read during scoring, never recomputed per search. The query tracker is a second LMDB-backed store that remembers past queries and selections per project — it is what lets the combo boost re-float a file the user picked before under the same search text, and it is read on every keystroke, not just written. Both trackers are capped in entry count and disk size, and the scoring engine takes different code paths, some parallel and some not, depending on query length and whether the target is a file or a directory. Several extracted findings are explicit corrections to earlier claims about which signal actually dominates ranking and which "optimizations" change asymptotic cost versus just shrinking an input.

### Call flow: how a query reaches scoring

- FFFIndex opens two LMDB databases at storageURL/frecency.lmdb and storageURL/history.lmdb. `FFFIndex.swift:65-66` `F`
- FFFIndex.swift passes those frecency/history DB paths into the C layer; fff.h documents that passing NULL skips DB initialization. `FFFIndex.swift:65-66,75-76; fff.h:83-90` `U11`
- FFFIndex.search calls fff_search_mixed with limit=60, context=100, fuzziness=3, max_threads=100, combo_min=3. `FFFIndex.swift:126` `Build configuration and XCFramework linkage`
- fff_search takes a query_tracker read lock, and FilePicker::fuzzy_search opens a read transaction against the 10 MB frecency LMDB map. `lib.rs:375-386; query_tracker.rs:92` `U11`
- Frecency scores are computed once, at filesystem-walk time, and stored on each FileItem; scoring reads them straight from memory rather than recomputing them per search. `scan.rs:170-177; score.rs:717` `U11`
- FFFIndex writes to query_tracker only at five lifecycle points — instance creation, destroy, rescan, refresh_git_status, and health-JSON reporting — not on every search. `fff-c/src/lib.rs:207-277,319,775,989,1198-1233` `U5`
- FFFIndex.track calls fff_track_query(handle, query, path) then fff_free_result on every selection; this reaches tracker.track_query_completion, which calls append_to_history. `FFFIndex.swift:433-434; lib.rs:1001-1046; query_tracker.rs:166-195` `U19`

### Walk-time frecency population (index build)

- FileSync.walk_filesystem calls update_frecency_scores for every file: it opens an LMDB read transaction, looks up the frecency score, and commits — once per file. `file_picker.rs:2127; types.rs:514; dbs/frecency.rs:195` `F18`
- At 300k files this puts 300k LMDB read transactions and 300k blake3 hashes on the critical path between walk completion and the index becoming searchable. `file_picker.rs:2127` `F18`
- The LMDB env's reader-slot allocation causes N background walker threads to contend on the reader-table lock for every file processed. `dbs/frecency.rs:195` `F18`
- Sorting, chunked-store construction, the frecency pass, and the final commit all run after the walk completes; nothing is searchable until the whole walk finishes. `scan.rs:171` `F20`

### Scoring formula (score.rs)

- Score computation combines many weighted components in one pass: base_score, frecency_boost, git_status_boost, distance_penalty, filename_bonus, special_filename_bonus, current_file_penalty, combo_match_boost, and path_alignment_bonus, among 15+ factors total. `score.rs:708-865` `U1` `Engine-picker cluster`
- Filename match bonus is 40% of base_score for an exact match, 16% for a fuzzy match, capped at 30. `score.rs:765,772` `engine-scoring` `U1`
- Frecency boost = base_score × file.total_frecency_score() / 100 (saturating multiply); total_frecency_score = access_frecency_score + modification_frecency_score. `score.rs:717; types.rs:438-439` `engine-scoring` `U10` `U5`
- Git-status boost for a modified file is 15% of base_score. `score.rs:720` `engine-scoring`
- Current-file penalty is −base_score/4. `score.rs:795` `engine-scoring`
- Special filename bonus, for hardcoded entry-point names like mod.rs, main.rs, lib.rs, and index.js, is 5% of base_score. `score.rs:890,932-949` `engine-scoring` `U1`
- A comment at score.rs:130 ("keep first part's position for filename bonus") confirms the filename bonus uses the end_col of a multi-part query's first part. `score.rs:130` `U11`
- match_and_score_in_arena (score.rs:709) is a sequential, not parallel, map over every path match, computing 10+ bonus operations per match. `score.rs:709-884` `U23`
- Per match, the scoring loop builds strings via write_dir_str and write_file_name_from_arena and reads into a 4KB buffer via read_to_buf. `score.rs:709-885` `U4`
- combo_match_boost recomputes m.file_path.to_string_lossy() as a loop-invariant inside the per-match loop instead of hoisting it out. `score.rs:796` `U11`
- combo_match_boost also builds the full relative path for every candidate via write_relative_path_from_arena. `score.rs:796` `U11`
- context.current_file is always None because Floodlight passes NULL, so the write_dir_str call at score.rs:726 is dead work, overwritten at line 804. `score.rs:725-727,804; FFFIndex.swift:126` `U11`
- git_status is read once per match to check is_modified_status, rather than from a precomputed flag bit. `score.rs:719; types.rs:248` `U12`
- FileItem.path.filename_offset is used throughout to split name-vs-path scoring, affecting both ranking and display. `types.rs:248` `U23`

### Frecency tracker internals

- FrecencyTracker DECAY_CONSTANT is 0.0693 (ln(2)/10, a 10-day half-life); AI mode uses 0.231 (3-day half-life). `frecency.rs:12` `U33`
- FrecencyTracker MAX_HISTORY_DAYS is 30 days (AI mode: 7 days). `frecency.rs:14` `U33`
- FrecencyTracker MAX_TIMESTAMPS_PER_FILE caps at 128 accesses per file. `frecency.rs:15` `U33`
- MODIFICATION_THRESHOLDS award 16 pts at 2 min, 8 pts at 15 min, 4 pts at 1 hr, 2 pts at 1 day, 1 pt at 1 week; AI mode compresses these thresholds 10x. `frecency.rs:28-43` `U33`
- get_access_score sums exponential decay e^(−0.0693 × days_ago) across recorded accesses, applying sqrt normalization once a file has more than 10 accesses. `frecency.rs:317-361` `U33`
- track_access enforces the per-file 128-access cap and the MAX_HISTORY_DAYS cutoff; hitting MDB_MAP_FULL marks the frecency DB unhealthy. `frecency.rs:258-315` `U33`
- Frecency LMDB MAP_SIZE is 10 MiB with a 12 MiB SIZE_CAP_BYTES, leaving margin before MDB_MAP_FULL; a real-world DB after years of use is only about 560 KiB. `frecency.rs:71-79` `U33` `dbs-grep cluster` `F18` `U41`
- FileItem.update_frecency_scores reads access_frecency_score as 0 when the FrecencyTracker has no entry for that file. `file_picker.rs:523` `U10`
- Correction: get_modification_score returns 0 unless git_status shows the file modified; since Floodlight indexes a non-git home directory, both the access and modification components of total_frecency_score are 0 there. `frecency.rs:362-372; score.rs:717` `U5`
- Correction: frecency_boost is capped near 13% of base_score — well below the 40% exact-filename bonus — so it is not the single strongest ranking signal. `frecency.rs:355-359; score.rs:765` `U5`

### Combo boost & query tracker

- QueryTracker maintains three LMDB tables: query_file_db, query_history_db, and grep_query_history_db. `query_tracker.rs:33-39` `U34` `U19`
- QueryTracker's lookup key is blake3(project_path + "::" + query), for deterministic lookup. `query_tracker.rs:144-155` `U34`
- QueryTracker.get_last_query_entry (query_file_db) returns a combo_boost when open_count >= 2 and the file_path matches on the same query. `query_tracker.rs:357-391` `U34`
- score.rs applies an additional min_combo_count gate — Floodlight passes combo_min=3 — so its own boost logic only applies once open_count >= 3 (the 4th+ selection under a query). `query_tracker.rs:354; score.rs:809-813` `U14` `U5`
- Every filename search opens an LMDB read transaction via query_tracker.get_last_query_entry / query_file_db to check for a combo boost — on every keystroke. `file_picker.rs:1093-1105,1098-1102; query_tracker.rs:331-354` `U3` `U19`
- Correction: the combo-boost mechanism is exercised on every keystroke via get_last_query_entry — LMDB query history is read back, not merely written and left unread. `fff-c/src/lib.rs:576-587; file_picker.rs:1091-1103` `U19`
- Combo boost feeds into FFF's own score and, in ApplicationCatalog, helps decide which limit×2 = 24 candidates are returned before Swift re-ranks them. `ApplicationCatalog.swift:133-136` `U11`
- QueryTracker.track_query_completion increments open_count when the same file is reselected under the same query, and resets it otherwise. `query_tracker.rs:228-329` `U34`
- QueryTracker MAX_HISTORY_ENTRIES is 128, applied per project and per history type. `query_tracker.rs:12` `U34`
- query_history_db is a bounded VecDeque capped at 128 entries; one entry is appended per selection inside an existing write transaction. `query_tracker.rs:12,185-187,296-299` `U19`
- append_to_history pushes every query completion unconditionally with no deduplication, so repeated opens of the same file produce consecutive identical history entries. `query_tracker.rs:181-184` `U19`
- read_history_at_offset opens a read transaction and bincode-deserializes the entire capped VecDeque (up to 128 entries) on every call; N offset reads mean N full deserializations. `query_tracker.rs:199-226` `U19`
- Query/selection history is keyed per project via a hash of picker.base_path(); changing the indexed scope orphans the previous project's history. `lib.rs:1065-1074` `U19`
- QueryTracker LMDB SIZE_CAP_BYTES is 8 MiB, with a 10 MiB MAP_SIZE. `query_tracker.rs:92-94` `U34` `dbs-grep cluster`
- Match-set size and combo-boost eligibility are anti-correlated: the largest match sets occur on short prefixes, while combo boost requires 3+ prior opens. `query_tracker.rs:354` `U6`

### Query-length and query-shape code paths

- Queries shorter than 2 characters skip fuzzy matching and fall through to score_filtered_by_frecency, which scores every live file (a parallel path handles directories similarly). `score.rs:626-632,953-960,953-968` `U3` `U22` `U36`
- Fuzzy match cascades multi-part queries: each part's surviving subset is passed to the next part, with early exit once a subset becomes empty. `score.rs:45-123,97-135` `U1` `U13`
- Fallback filename re-matching only runs when the query lacks '/' and the path-match count is under 15,000; above that threshold the pass is skipped. `score.rs:689-707,668` `U1` `U32`
- Correction: the fallback-indices cursor in match_and_score_in_arena must walk via partition_point over filename_fallback_matches indexed by fallback_indices, not the reverse — naive reversal would silently corrupt bonus assignments. `score.rs:673-680,699,738-741` `U23`
- Any mixed query unconditionally collects a Vec<&DirItem> of every live directory before any query-shape check or sort, even with no constraints. `score.rs:410,406-418; file_picker.rs:1197,1250` `U7` `U26`
- On a home-directory-sized index (50k–200k directories) that directory collection allocates 0.4–1.6 MB per keystroke. `score.rs:410` `U7`
- Directory scoring calls write_dir_name, copying the entire path into a 4KB stack buffer per directory match. `score.rs:493-497; types.rs:188-199` `U8`
- Short queries can produce directory matches on the order of the whole table — 10k–100k full-path copies per keystroke. `score.rs:493-497` `U8`
- is_exact_dirname is called unconditionally per directory match, but its result is only used when is_dirname_match is true and the lengths match. `score.rs:489-497` `U8`
- No cross-query state caches the previous candidate set for incremental narrowing across a keystroke sequence — each keystroke re-scores from scratch. `score.rs:142; file_picker.rs:574-596` `U13`
- Multi-character queries never touch rayon during scoring: fuzzy_match_and_score_files uses .into_iter(), not .par_iter(). `score.rs:705` `U4`
- is_deleted() is filtered out for files in both the "All" and "Filtered" FileItems branches via filter_map, but resolve_dir_chunks has no equivalent check, so directory results aren't filtered for tombstones the way file results are. `score.rs:953-967,37-40,293-309,963-970` `U10` `U26` `U72`

### Data structures & memory

- Score is a 64-byte struct (10×i32 + bool + a 16-byte fat pointer to &'static str); an (&FileItem, Score) match element is 72 bytes. `types.rs:808-822` `U5` `U22` `U24` `U37`
- On a 1M-file index, an unfiltered query (e.g. a single character) materializes the full match set — about 72 MB of (&FileItem, Score) tuples — before select_nth_unstable_by truncates it to a page (e.g. 24 items). `score.rs:709,953-960,1014-1032` `U3` `U22` `U24`
- FileItem is a 96-byte struct: size (u64) + modified (u64) + two i16 frecency scores + git_status + a 32-byte path + parent_dir_index (u32) + an AtomicU8 flags byte + 24 bytes of content. `types.rs:248` `U12`
- On a 1M-file index, the matcher streams about 96 MB of FileItem data per pass where roughly 33 MB would suffice for the fields actually read — a 2–3x memory-bandwidth overhead. `score.rs:32-43; types.rs:248` `U12`
- fuzzy_match_and_score_files pre-builds "overflow" results, then extends the base Vec with them via a ptr copy_nonoverlapping, reallocating and copying the entire base Vec. `score.rs:142-168,155` `U18` `U37`
- At 500k matches (72 bytes each), that overflow-merge reallocation peaks around 36 MB plus another 36 MB of memcpy traffic. `score.rs:155` `U18`
- At 500k matches, select_nth_unstable_by's partitioning passes move hundreds of MB of 72-byte elements. `score.rs:1021` `U5`
- MixedSearchResult carries no match-range or offsets field; fuzzy_search_mixed's consumers get only items and scores, not highlight ranges. `types.rs:891-898; file_picker.rs:1303-1307` `U25`
- FuzzySearchOptions has exactly five fields — max_threads, current_file, project_path, combo_boost_score_multiplier, min_combo_count, and pagination — with no abort_signal or cancellation field. `file_picker.rs:84-91` `U33`
- FileItems::All passes a contiguous slice, while FileItems::Filtered passes a Vec<u32> resolved through resolve_ref, making the filtered path pointer-chased and prefetch-hostile. `score.rs:68-86` `U32`
- live_file_count() (file_picker.rs:1080) returns the true count of live items for the frecency scoring path, equal to total_matched when nothing has been filtered out. `file_picker.rs:1080` `U22`
- Character-indices-to-byte-offsets computation collects a per-character Vec instead of walking the string once; this overhead applies to every entry point (grep, nvim, python), not just Floodlight. `score.rs:243-247` `U25`
- Overflow-file tagging gives overflow items a stable-sort tie-break advantage that survives into the final order, because sort_with_buffer is a stable glidesort. `score.rs:613-620; sort_buffer.rs:43-54` `U24`

### Threading & parallelism

- score_filtered_by_frecency and constraints.rs's filtering both run their par_iter() work on the global rayon pool. `score.rs:953-955; constraints.rs:221,543` `U27`
- None of fuzzy_search, fuzzy_search_directories, or fuzzy_search_mixed install a SEARCH_THREAD_POOL before calling into scoring or the constraint paths — they run on the ambient/global pool. `file_picker.rs:1057,1156,1224; score.rs:953; constraints.rs:221,543` `U27` `U62`
- The fallback filename re-match thread-count calculation is context.max_threads.div_ceil(2048). `score.rs:692` `U9`
- On realistic hardware (e.g. 8–16 cores on Apple Silicon), that div_ceil(2048) evaluates to 1, so the 4096-match parallelization branch is always single-threaded in practice. `score.rs:692` `U9`
- score_dirs_by_frecency runs as a sequential iterator, while its file counterpart score_filtered_by_frecency uses par_iter — files and directories are parallelized inconsistently. `score.rs:542-560,546-561 vs 953-960,955` `U22` `U36`
- score_filtered_by_frecency's par_iter().filter_map().collect() (rayon's unindexed parallel collect) builds per-thread buffers and reduces them, creating a transient ~2x peak-memory spike before final concatenation. `score.rs:953-960` `U22`

### Partial sort & pagination

- Partial sort uses select_nth_unstable_by when items_needed < total_matched/2 and total_matched > 100. `score.rs:538-570,1021-1034` `U1` `U26`
- With page_size 100, that optimization is disabled once total_matched exceeds 400; with page_size 12 it engages once total_matched exceeds 48. `score.rs:1022; file_picker.rs:1240` `U20`
- Correction: select_nth_unstable_by's cost is O(total_matched), independent of k — lowering the internal limit changes the final sort's input size but not the dominant select_nth cost. `score.rs:1019-1032` `U36`
- Correction: sort_with_buffer still runs unconditionally after select_nth_unstable_by even when the partial-sort path is used — the optimization shrinks the sort's input from N to items_needed, it does not eliminate the sort. `score.rs:1035-1042` `U20`
- Correction: sort_and_paginate's final unzip step operates only on results already truncated to items_needed, so it is always bounded by the page limit (e.g. 12), not by the size of the match set. `score.rs:1027-1051` `U37`
- sort_and_paginate tiebreaks on (total score, then modified time), while the merge step sorts on total score alone — tightening the per-side limit can shift tie ordering right at the page boundary. `score.rs:1024-1040` `U36`

### Swift-side catalog scoring

- SearchItemRanking defines score bands: keywordEngine=150000, calculator/application/pathNav=100000, setting=50000, content=1000. `Catalog.swift` `F`
- SearchItemRanking.ranksBefore() chains comparisons: score descending, then title ascending, then ID ascending. `Catalog.swift:78-84` `F`
- ApplicationCatalog.immediatePage's per-keystroke synchronous search filters all candidates by a character mask, then scores survivors via FuzzyMatcher. `ApplicationCatalog.swift:166-208` `F`
- ApplicationCatalog.score() takes an ASCII fast path when both the query and candidate are ASCII, and falls back to a Unicode path otherwise. `ApplicationCatalog.swift:227-244` `F`
- ApplicationCatalog.immediatePage runs its scoring loop outside its lock, while SystemCatalog performs matching inside its lock. `ApplicationCatalog.swift:176-206 vs SystemCatalog.swift:349-415` `F17`

### LMDB health & sizing (shared infrastructure)

- DbHealthState is a u8 enum: Pending (0), Healthy (1), Degraded (2). `lmdb.rs:15-33` `U35`
- DbHealth is backed by an Arc<AtomicU8> using Acquire/AcqRel ordering; Pending counts as unhealthy. `lmdb.rs:35-65` `U35`
- The LMDB env pool's MAX_READERS is 1024, versus heed's default of 126; it's tunable via the FFF_LMDB_MAX_READERS env var. `env_pool.rs:223-229` `U32`

### Benchmark harness gotcha

- fff-nvim's benchmarks call fuzzy_search (not fuzzy_search_mixed), use a result limit of 100 (not 12), pass no query_tracker, and run against a git repo rather than a home directory — so they don't exercise the same code paths Floodlight does. `fuzzy_search_bench.rs:150,107` `U19`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| fff_search_mixed call params (Floodlight) | limit=60, context=100, fuzziness=3, max_threads=100, combo_min=3 | `FFFIndex.swift:126` |
| SearchItemRanking score bands | keywordEngine=150000; app/calculator/pathNav=100000; setting=50000; content=1000 | `Catalog.swift` |
| Filename match bonus | 40% exact, 16% fuzzy, capped at 30 (of base_score) | `score.rs:765,772` |
| Frecency boost formula | base_score × total_frecency_score() / 100 | `score.rs:717` |
| Git-status boost | 15% of base_score | `score.rs:720` |
| Current-file penalty | −base_score / 4 | `score.rs:795` |
| Special filename bonus | 5% of base_score (mod.rs, main.rs, lib.rs, index.js) | `score.rs:890,932-949` |
| FrecencyTracker DECAY_CONSTANT | 0.0693 (10-day half-life); AI mode 0.231 (3-day) | `frecency.rs:12` |
| FrecencyTracker MAX_HISTORY_DAYS | 30 days (AI mode: 7 days) | `frecency.rs:14` |
| FrecencyTracker MAX_TIMESTAMPS_PER_FILE | 128 accesses per file | `frecency.rs:15` |
| Frecency LMDB sizing | MAP_SIZE 10 MiB, SIZE_CAP_BYTES 12 MiB; real-world DB ~560 KiB after years | `frecency.rs:71-79` |
| QueryTracker MAX_HISTORY_ENTRIES | 128 per project per history type | `query_tracker.rs:12` |
| QueryTracker LMDB sizing | SIZE_CAP_BYTES 8 MiB, MAP_SIZE 10 MiB | `query_tracker.rs:92-94` |
| Combo-boost thresholds (two layers) | QueryTracker gates at open_count>=2; score.rs's min_combo_count (passed as 3) requires the 4th+ selection | `query_tracker.rs:357-391,354; FFFIndex.swift:126` |
| LMDB env pool MAX_READERS | 1024 (heed default 126), tunable via FFF_LMDB_MAX_READERS | `env_pool.rs:223-229` |
| Score struct size | 64 bytes; (&FileItem, Score) match tuple = 72 bytes | `types.rs:808-822` |
| FileItem struct size | 96 bytes | `types.rs:248` |
| Filename-fallback re-match threshold | disabled once path-match count exceeds 15,000 | `score.rs:668-707` |
| Partial-sort threshold | items_needed < total_matched/2 && total_matched > 100 (disabled >400 matches at page_size 100; engages >48 at page_size 12) | `score.rs:1021-1034; file_picker.rs:1240` |
| Fallback re-match thread count | max_threads.div_ceil(2048) — evaluates to 1 on realistic core counts (8-16 cores) | `score.rs:692` |
| 1M-file unfiltered-query match-set size | ~72 MB of (&FileItem, Score) tuples before truncation to a page | `score.rs:709,1014-1032` |
| 300k-file walk cost | 300k LMDB read transactions + 300k blake3 hashes on the critical path | `file_picker.rs:2127` |
| ApplicationCatalog combo candidate window | limit×2 = 24 candidates returned before Swift re-ranks | `ApplicationCatalog.swift:133-136` |

### Gotchas

- context.current_file is always None because Floodlight passes NULL, so the write_dir_str call at score.rs:726 is dead work that gets overwritten at line 804. `score.rs:725-727,804; FFFIndex.swift:126`
- The partial-sort optimization (select_nth_unstable_by) does not eliminate the final sort — sort_with_buffer still runs unconditionally afterward; the optimization only shrinks the sort's input from N to items_needed. `score.rs:1035-1042`
- Combo-boost history is read on every keystroke via query_tracker.get_last_query_entry — it is not a write-only, never-read LMDB table. `fff-c/src/lib.rs:576-587; file_picker.rs:1091-1103`
- select_nth_unstable_by's cost is O(total_matched), independent of k, so lowering the internal result limit does not cut the dominant scoring/sorting cost. `score.rs:1019-1032`
- Directories are not filtered for is_deleted the way files are — resolve_dir_chunks has no equivalent tombstone check. `score.rs:37-40,293-309,963-970`
- score_dirs_by_frecency is single-threaded (sequential iterator) while its file counterpart score_filtered_by_frecency uses rayon's par_iter — files and directories are parallelized inconsistently. `score.rs:542-560 vs 953-960`
- Multi-character queries never use rayon at all (fuzzy_match_and_score_files uses .into_iter(), not .par_iter()), even though sub-2-character queries do go parallel via score_filtered_by_frecency. `score.rs:705 vs 953-960`
- The fallback re-match "parallelization" branch (triggered above 4096 matches) is effectively always single-threaded, because context.max_threads.div_ceil(2048) evaluates to 1 on realistic core counts. `score.rs:692`
- get_modification_score returns 0 for Floodlight's non-git home-directory index, so frecency's modification component contributes nothing there — despite mtime being commonly assumed to drive ranking. `frecency.rs:362-372; score.rs:717`
- frecency_boost caps near 13% of base_score, smaller than the 40% exact-filename bonus, so frecency is not the dominant ranking signal despite being the most-discussed one. `frecency.rs:355-359; score.rs:765`
- Two different combo-boost thresholds exist at two layers: QueryTracker's own logic gates at open_count>=2, but score.rs's min_combo_count (passed as 3 by Floodlight) requires the 4th+ selection before the boost actually applies. `query_tracker.rs:357-391,354; score.rs:809-813; FFFIndex.swift:126`
- fff-nvim's benchmarks exercise a different code path than Floodlight (fuzzy_search not fuzzy_search_mixed, limit 100 not 12, no query_tracker, git repo not home directory), so their timing numbers don't transfer directly. `fuzzy_search_bench.rs:150,107`

### Corrected on review

- ~~get_modification_score is the single strongest ranking signal, driven purely by mtime.~~ → get_modification_score returns 0 unless git_status shows the file modified; in Floodlight's non-git home-directory index, both the access and modification components of total_frecency_score are 0. `frecency.rs:362-372; score.rs:717`
- ~~frecency_boost is the single strongest ranking signal.~~ → frecency_boost is capped near 13% of base_score, well below the 40% exact-filename bonus. `frecency.rs:355-359; score.rs:765`
- ~~The LMDB query history is opened, mapped, GC'd and size-capped with nothing reading it back.~~ → The combo-boost mechanism is used on every keystroke via query_tracker.get_last_query_entry — the history is read back, not just written. `fff-c/src/lib.rs:576-587; file_picker.rs:1091-1103`
- ~~The fallback cursor can be reset via partition_point on fallback_indices directly.~~ → The fallback-indices cursor in match_and_score_in_arena must walk via partition_point over filename_fallback_matches indexed by fallback_indices, not the reverse — naive reversal would silently corrupt bonus assignments. `score.rs:673-680,699,738-741`
- ~~Lowering internal_limit halves the per-side scoring/sorting output cost.~~ → select_nth_unstable_by is O(total_matched), independent of k, so lowering internal_limit changes only the final sort's input size, not the dominant select_nth cost. `score.rs:1019-1032`
- ~~sort_and_paginate allocates two full-size Vecs in the unzip step.~~ → The unzip in sort_and_paginate operates only on results already truncated to items_needed, so it is bounded by the page limit, not the match-set size. `score.rs:1027-1051`
- ~~The partial sort avoids a full sort for certain result sets.~~ → sort_with_buffer still runs unconditionally after select_nth_unstable_by; the partial-sort optimization shrinks the sort's input from N to items_needed, it does not eliminate the sort. `score.rs:1035-1042`

<a id="engine-dirs-mixed-pagination"></a>
## Query pipeline: directories, mixed search, sorting and pagination

The query pipeline runs Swift (FFFIndex) → a thin C FFI (fff-c) → the Rust engine (fff-core's FilePicker). Every FFI search call takes a read lock on a shared RwLock<FilePicker> and returns owned/heap-allocated results, and the background watcher/rescan path competes for the write side of that same lock, so watcher activity can stall in-flight searches. Floodlight always requests page 0 at a fixed page size and never advances pagination — "pagination" is really a single over-fetch, since the mixed-search path internally doubles the requested limit for both directories and files before Swift-side ranking truncates it back down. Inside fuzzy_search_mixed, directory search and file search run sequentially (directories first, no parallel join), and a trailing-slash query skips file search entirely. Content search (fff_live_grep) uses fixed, Swift-hardcoded parameters — a 35 ms time budget, a 10 MB per-file cap, and small match limits — and the engine's own time-budget check fires only every 8th file inside a rayon chunk, so an abort or budget-exceeded signal does not stop work immediately. Around this core sit several Swift-side layers (ApplicationCatalog, SystemCatalog, FuzzyMatcher, RecentStore, BlocklistStore) doing their own matching, ranking, and locking, plus a Rust-side watcher/rescan/cache-budget system managing background reindexing and an mmap content cache. Several spots that read like unresolved TODOs or startup races turn out, on closer inspection, to already be handled correctly, or to be genuinely dead code.

### FFI call flow and locking (Swift → fff-c → fff-core)

- fff_search_mixed acquires a picker.read() guard, calls picker.fuzzy_search_mixed, then converts the result via from_core. `lib.rs:190-253` `U8`
- fff_live_grep acquires a picker.read() guard, decodes the mode parameter (0=plain, 1=regex, 2=fuzzy), builds GrepSearchOptions, calls picker.grep, and returns a heap-allocated FffGrepResult. `lib.rs:68-129` `U8`
- fff_is_scanning reads picker.is_scan_active via a read guard and does not hold the lock after the read returns. `lib.rs:37-48` `U8`
- fff_get_scan_progress Box-heap-allocates an FffScanProgress and reads the picker's get_scan_progress struct once under a read lock. `lib.rs:80-98` `U8`
- fff_get_scan_progress's read lock is on the same lock the commit/rescan path takes for writing and on the same serial queue as searches, so progress polling can queue behind a commit. `fff-c/src/lib.rs:829` `F33`
- All FFI search operations require the RwLock read guard on the picker; a rescan triggers a non-blocking flag flip plus a background thread spawn rather than blocking the caller. `lib.rs:188-253` `U8`
- fff_search_mixed and fff_search both acquire inst.picker.read() on the same RwLock that watcher directory registration also touches. `fff-c/src/lib.rs:362, 564` `U76`
- parking_lot::RwLock blocks new readers once a writer is queued, so a batch of watcher events queued for the write lock can stall the next search. `fff-c/src/lib.rs:564` `U14`

### Mixed search: directories and files

- FFFIndex wraps the fff-swift C library and exposes three search methods: mixed (files+dirs), files-only, and directories-only. `Sources/FloodlightEngine/Search/FFFIndex.swift:101-301` `F`
- FFFIndex calls fff_search_mixed with fixed parameters limit, 100, 3 — meaning the page's item limit, an overall 100-item total limit, and 3 directory levels. `FFFIndex.swift:126` `U1`
- fuzzy_search_mixed computes internal_limit = (page_offset + page_limit).saturating_mul(2), applied independently to both directory and file search; for Floodlight's limit=12 request this yields 24 dirs + 24 files = 48 candidates fetched for one 12-item page. `file_picker.rs:1240, 1242` `U17` `U20` `U22` `U36`
- Inside fuzzy_search_mixed, directory search runs to completion (fuzzy_search_directories, ~line 1251) before file search starts (fuzzy_search, ~line 1295), sequentially with no rayon::join, despite the two having no shared mutable state. `file_picker.rs:1224-1290` `U17` `U22` `U36`
- fuzzy_search_mixed detects a trailing-slash / path-separator-terminated query (via query.raw_query, path-segment filtering) and returns directory results only, skipping fuzzy_search (file search) entirely. `file_picker.rs:1224-1240, 1238-1239, 1251, 1287` `U26` `U8` `U20` `U22`
- PAR_THRESHOLD = 10,000 items gates rayon-parallel constraint filtering (ConstraintPlan, with per-thread scratch space) and the globset glob-mask parallel path; both apply only to queries with explicit extension/path constraints, and the globset path only compiles under the default ripgrep feature (not zlob). `constraints.rs:220-228, 221, 276-290, 420-424, 541, 10` `U6` `U62`
- Extension filters use OR semantics and are checked first, with an early exit on pass. `constraints.rs:276-290` `U6`
- The prepass glob strategy generates Vec<Vec<bool>> masks without per-item glob compilation. `constraints.rs:420-424` `U6`
- Below the 10,000-item parallel threshold, constraint filtering applies a plain linear O(n) scan with no parallelization. `file_picker.rs:619-629` `Engine-picker cluster`
- FilePicker.fuzzy_search processes overflow files first, giving them a tiebreaker advantage in result ordering. `file_picker.rs:explorer-summary` `Engine-picker cluster`
- fuzzy_match_byte_offsets_for_page computes match byte offsets during mixed search, but the result never reaches MixedSearchResult or FffMixedItem — it is discarded before crossing the FFI boundary. `file_picker.rs:1131, types.rs:891-898, ffi_types.rs:651-668` `U6`
- The vendored fff-c crate is v0.10.5; the fuzzy-match offset computation landed upstream in commit 93b063b (#673, 2026-07-15) and is present in both v0.10.5 and v0.10.6, but no FFI consumer ever sees these offsets because the C FFI layer does not expose them. `file_picker.rs:1131-1132, types.rs:891-898` `U25`
- FFFIndex.searchDirectories (FFFIndex.swift:244-301, 58 lines) has zero production call sites but ten test call sites, including folder-move/rename coverage. `FFFIndexTests.swift:196,202,282,305,311,325,509,515,532` `U20`
- FFFFileSource.start() blocks in waitForScanCompletion() over the user's root directory (default ~/Downloads), producing an unbounded wait on cold start. `FFFIndex.swift:623-625, 677-686` `F57`
- FFFIndex.waitForScanCompletion costs roughly 10 ms per call due to its polling interval. `FFFIndex.swift:676-686` `U75`

### Content search (grep) mechanics

- Floodlight's fff_live_grep calls (FFFIndex.searchContent) use a fixed configuration: 10 MB (10,485,760 bytes) max file size, a 35 ms time budget, plain-text mode, zero context lines, and an overall cap of 16 returned matches. `FFFIndex.swift:142-167, 349, 357; record 36` `ffi-header cluster` `dbs-grep cluster` `U1`
- max_matches_per_file is set to 1 in both Floodlight's fuzzy_search and grep calls, so the Rust searcher halts on each file after its first match. `FFFIndex.swift:353-366; grep/grep.rs:129` `U20`
- GrepSearchOptions' library-level defaults (before Floodlight overrides them) are: max_matches_per_file=200, page_limit=50, time_budget_ms=0 (unlimited). `grep/types.rs:82-132` `U37`
- GrepMode is an enum of PlainText (default), Regex, Fuzzy. `grep/types.rs:10-21` `U37`
- GrepMatch stores match_byte_offsets as a SmallVec<[u32; 4]> for small-vector optimization. `grep/types.rs:25-49` `U37`
- Grep's time-budget/abort check runs only every 8th file (`local_idx % 8 == 0`) inside each rayon worker's per-chunk loop; the outer loop only breaks after the whole chunk finishes, and a budget_exceeded AtomicBool then stops all remaining chunks. `grep/grep.rs:606-619, 667-678, 579-585` `U39` `dbs-grep cluster` `U6` `U2` `U1`
- Because the abort check is gated by `local_idx % 8 == 0`, only the 8th file in a worker's local batch actually checks and respects a pending abort signal — the other 7 of every 8 files still complete a full mmap/read even after the signal is raised. `grep/grep.rs:606-618` `U2`
- Grep falls back to a plain literal search when constraint-filtered matching yields 0 results, by stripping non-FilePath constraints. `grep/grep.rs:223-225, 223-240` `U39` `U23`
- Grep also falls back silently from a regex parse failure to literal matching, setting a regex_fallback_error flag. `grep/grep.rs:223-240` `U23`
- max_matches_per_file stops grep after the first hit per file via search_file(content, options.max_matches_per_file). `grep/grep.rs:639` `U26`
- All four FFI grep modes (plain text, regex, fuzzy, multi-pattern) truncate each line's display bytes to MAX_LINE_DISPLAY_LEN = 512 bytes via truncate_display_bytes / SinkState::prepare_line, documented as preventing minified JS or huge single-line files from blowing up memory; the same truncation feeds plain-text, Aho-Corasick, and regex sinks. `grep/sink.rs:5-7, 48-63, 165-176; grep.rs:132-137; regex.rs:82-89; fuzzy_grep.rs:240-247; multi_pattern.rs:57-61` `U9`
- The 10 MiB max_file_size only determines which files get opened for content search; it does not size the returned snippet. Snippet length is separately capped at 512 bytes by truncate_display_bytes, so it is wrong to attribute large per-match memory use to the 10 MiB file cap. `grep/sink.rs:5-7, 165-176` `U9`
- MAX_FFFILE_SIZE = 10 MB is the hard content-read cap, serving as both the default max_file_size and the gate for content-search eligibility. `constants.rs:5; types.rs:701, 751-754` `engine-scoring` `U18` `U40`
- get_content_for_search always returns content for an eligible file even when the mmap cache budget is exhausted, falling back to a transient mmap or read_exact. `types.rs:728-729, 759-773` `U18`
- No benchmark data exists in the Floodlight repository to empirically confirm whether the 35 ms time budget is actually sufficient (or insufficient) for a full home-directory-scope content search. `audit record notes absence of host-platform benchmarks` `U85`

### Pagination behavior

- Floodlight always uses page_index=0 and page_size=limit for every search call and never advances pagination — it stops after the first request. `record 43` `ffi-header cluster`
- Floodlight's UI-facing per-keystroke limit is hardcoded to 12 in SourceSearchEngine; the engine's internal over-fetch (the internal_limit doubling described under mixed search) is truncated back down to this limit at file_picker.rs:1327. `SourceSearchEngine.swift:290; file_picker.rs:1327` `U7`
- For clipboard search results, a full sort precedes the LIMIT-based truncation, rather than a bounded/partial sort. `Mentioned in finder-coverage` `F2`

### Swift-side FFFIndex wrapper

- FFFIndex.exactPathItem() performs synchronous fileExists() and attributesOfItem() calls on exact-match paths, once per keystroke. `FFFIndex.swift:543-576` `F`
- FFFIndex is created with enableHomeDirectoryScanning=true, enableContentIndexing=true, includeBinaryFiles=true, and watch=true. `FFFIndex.swift:700-708, 24-27` `F`
- FFFIndex.init calls the realpath syscall twice. `FFFIndex.swift:35-36` `F`
- FFFIndex.swift:73-90 is the single initialization path shared by both the file-index and marker-index instances; it sets enable_mmap_cache=true and all three cache_budget_max_* fields to 0 unconditionally. `FFFIndex.swift:73-90 (lines 77, 83-85)` `F171`

### Ranking, catalogs, and per-source matching

- FuzzyMatcher.damerauLevenshtein runs an O(n·m) DP, allocating a temporary matrix via withUnsafeTemporaryAllocation only if the edit-distance budget permits; the budget is 1 edit for query lengths 3-5 and 2 beyond that. `FuzzyMatcher.swift:190-223, 335-395` `F` `F8`
- FuzzyMatcher.matchASCII returns early for an exact match (line 99) and for a whole-string prefix match (line 102); only candidates past both checks reach extractWordsASCII (line 108). `FuzzyMatcher.swift:90-113, 108` `F9` `F22`
- FuzzyMatcher.extractWordsASCII (lines 312-333) has no reserveCapacity call, unlike its Unicode twin (lines 288-292), which reserves capacity 4. `FuzzyMatcher.swift:312-333, 288-292` `F9` `F22`
- FuzzyMatcher.findAcronymASCII allocates an initials array via compactMap (line 174) only when words.count > 1, so single-word app names never allocate it. `FuzzyMatcher.swift:173-174` `F22`
- SearchItemRanking.topRankedInPlace is an O(n log limit) bounded-heap selection with capacity reserved once — not a full/unbounded sort. `Catalog.swift:86-134, 104-134` `F` `F10` `F19`
- SearchItem.init's default id uses lazy evaluation behind the `??` operator, not eager allocation. `SearchItem.swift` `F10`
- SourceSearchEngine.execute calls immediatePage twice per execution (lines 244-245 and 286-287); a later use at 329/331 reuses the 286-287 values rather than calling a third time. `SourceSearchEngine.swift:244-245, 286-287, 329-331` `F1` `F10`
- The second of those two immediatePage calls is a complete scan of all roughly 1,500 applications, guaranteed identical to the first call's result in steady state. `SourceSearchEngine.swift:244-245, 286-287, 283-285 comment` `F13`
- ApplicationCatalog.boostMap is already hoisted out of the immediatePage loop as a single call before application iteration, not recomputed per app. `ApplicationCatalog.swift:177` `F10`
- Query normalization, UTF-8 byte-array generation, ASCII checking, and character-mask computation are duplicated across ApplicationCatalog.immediatePage, ApplicationCatalog.indexedItems, and SystemCatalog.immediatePage, running 1-2 times per keystroke. `ApplicationCatalog.swift:171-174, 128-132; SystemCatalog.swift:343-347` `F1`
- SearchCoordinator.projectLocal filters blocklist-clean candidates but the same filtering is repeated at three separate call sites: stale-while-revalidate (527), selectFilter (364), and excludeFromSearch (397). `SearchCoordinator.swift:596, 527, 364, 397; SearchResultProjection.swift:170` `F2`
- invalidateActiveExecution yields a SearchSnapshot with empty candidates and pendingKinds = [application, file, folder, systemSetting]. `SourceSearchEngine.swift:516-520` `F22`
- SourceSearchEngine.execute runs Task.sleep(15ms) if appPage.items is empty, else Task.sleep(20ms), inside execute. `SourceSearchEngine.swift:266-267` `F26`
- SourceSearchEngine.execute runs a further Task.sleep(30ms) before content grep. `SourceSearchEngine.swift:320-321` `F26`
- SourceSearchEngine.execute collects a bounded set of 12 apps, 24 settings, and 12 files before ranking. `SourceSearchEngine.swift:244-245, 290-294` `F14`
- ApplicationCatalog.characterMask encodes present a-z and A-Z (folded) in bits 0-25, and 0-9 in bits 26-35, as a UInt64 bitmask. `ApplicationCatalog.swift:435-451` `F`
- SystemCatalog defines builtInSettings statically at compile time, spanning 193 lines of settings panes, with 39 built-in Setting literals plus discovery of additional settings in four fixed directories. `SystemCatalog.swift:43-235, 455-468` `F` `F17`
- SystemCatalog.immediatePage applies a word-boundary matching requirement for short queries via a requiresWordPrefix gate, reached only after a single characterMask AND-check runs before any matching work. `SystemCatalog.swift:339-416, 353` `F` `F17`
- SystemCatalog.extractMatchedKeyword() allocates a new String for each non-title match result. `SystemCatalog.swift:419-435` `F`
- SystemCatalog.immediatePage holds an OSAllocatedUnfairLock across mask test, fuzzy match, subtitle generation, and SearchItem construction (lines 349-415). `SystemCatalog.swift:349-415` `F17`
- SystemCatalog.refreshIfNeeded holds its lock across a dedup Set, a filter, and three map comparisons for 40-60 entries (lines 288-298), but short-circuits entirely unless the directory fingerprint has changed (lines 277-280). `SystemCatalog.swift:288-298, 277-280` `F17`
- Catalog refresh is rate-limited to once per 2 seconds via CatalogRefreshGuard.reserve(minimumInterval: 2). `Catalog.swift:40-42, 224-233` `F17`
- ApplicationCatalog.discoverApplications enumerates /Applications, /System/Applications, ~/Applications, .applicationDirectory, and CoreServices. `ApplicationCatalog.swift:333-382` `F18`
- ApplicationCatalog.indexedItems iterates at most 24 FFF results. `ApplicationCatalog.swift:133-144` `F21`
- ApplicationCatalog.prepare() calls synchronizeMarkers, which deletes undesired markers and creates one file per app. `ApplicationCatalog.swift:481-501` `F18`
- KeywordEngineRegistry.addressedResult() does an O(1) dict lookup per keystroke to route keyword-addressed queries (e.g. "yt" at line 414, "claude" at lines 430-436). `Sources/FloodlightEngine/Search/KeywordEngine.swift:225-233, 414, 430-436` `F` `F140`
- KeywordEngine.searchURL() URL-encodes the query remainder and interpolates it into urlTemplate. `KeywordEngine.swift:97-108` `F`
- KeywordEngine's host value is recomputed via replacingOccurrences + URL(string:) on every addressedResult and defaultWebResult call rather than cached. `KeywordEngine.swift:83-90, 113, 248` `F14`
- Calculator.evaluate() short-circuits on a guard checking for an operator character (line 6), then does eager string replacements before parsing. `Calculator.swift:4-18, 6` `F` `F14`
- Calculator.swift:21 constructs a new NumberFormatter on every call. `Calculator.swift:21` `F14`
- PathNavigator.swift:25 short-circuits before any filesystem I/O for queries containing no "/" or "~". `PathNavigator.swift:25` `F14`
- BlocklistStore checks the blockedIDs set first (O(1)); only if the names set is non-empty does it Unicode-fold the input name and check normalizedBlockedNames — and it skips the ICU folding entirely when normalizedBlockedNames is empty (line 74). `BlocklistStore.swift:72-82, 74` `F` `F18`
- When a name rule does exist, BlocklistStore.isBlocked performs a Unicode-folding allocation per checked item (line 145) and wraps each check in an OSAllocatedUnfairLock acquisition (lines 144-146). `BlocklistStore.swift:144-146` `F24` `F21`
- RecentStore persists usage data to UserDefaults.standard via JSONEncoder on every persist() call, and JSONDecoder on init. `RecentStore.swift:21, 69` `F`
- RecentStore.boostMap() computes frequency+recency boosts for all entries in-memory under withLock, allocating a dictionary with reserved capacity, but has a `!dict.isEmpty` fast path (lines 50-51) that skips construction when there is nothing to boost. `RecentStore.swift:49-60, 50-51` `F` `F18`

### Content cache budgets and mmap

- ContentCacheBudget auto-sizes by index size: over 50k files → 5k files / 128MB; 10k-50k files → 10k files / 256MB; under 10k files → 30k files / 512MB. `types.rs:908-1005, 943-958` `dbs-grep cluster` `U18` `F30` `U46`
- Floodlight passes 0 for all three cache_budget_max_* parameters, which triggers this auto-sizing instead of a fixed limit. `FFFIndex.swift:83-85, 158` `dbs-grep cluster`
- A home-directory index stays far above the 50k-file boundary, so it permanently pins to the smallest cache bucket (5k files / 128MB), avoiding bucket oscillation. `types.rs:943-952` `U18`
- ContentCacheBudget::from_overrides is all-or-nothing: once any one field is set non-zero, the remaining zero-valued fields inherit the default new_for_repo(30k) rather than the size-appropriate auto value. `types.rs:976-991, 1000-1003` `U18`
- fff_live_grep mmaps files into the content cache, where they remain mapped for the picker's lifetime via FileItem.content: OnceLock<Mmap>. `types.rs:246` `F30`
- Every FileItem carries an inline OnceLock<Mmap> field even though at most cache_budget.max_files of them are ever populated. `types.rs:246` `F34`
- That OnceLock<Mmap> field adds roughly 24-32 bytes per FileItem. `types.rs:246; file_picker.rs:2170-2180` `F34`
- enable_mmap_cache in FFF only concerns caching file contents for grep; its warmup path is commented out. `scan.rs:357-360` `F19`
- warmup_mmaps is commented out (scan.rs:357-359, with a TODO note) and is never executed — no rescan runs it as a post-scan job. `scan.rs:357-359` `U11`
- need_complex_rebuild is defined (shared.rs:145) but never called anywhere in the codebase — it does not gate any warmup job. `shared.rs:145` `U11`
- set_cache_budget (file_picker.rs:719-721) only swaps the Arc<ContentCacheBudget> pointer; it does not invalidate or preserve mmaps across a rescan. `file_picker.rs:719-721` `U18`
- commit_new_sync (file_picker.rs:1499-1502) unconditionally calls cache_budget.reset() on both its branches, dropping all cached mmaps. `file_picker.rs:1499-1502` `U18`
- commit_new_sync causes a multi-hundred-millisecond stall of every query and progress poll, and doubles peak RSS. `file_picker.rs:1499` `F23`

### Indexing, rescan, and the file watcher

- RESCAN_MIN_INTERVAL is 30 seconds for normal repos, and RESCAN_MIN_INTERVAL_LARGE_INDEX is 5 minutes once the index exceeds 1 million files. `constants.rs:24-33` `engine-scoring` `U45`
- Ordinary file add/remove events do not trigger a full rescan; full rescans fire only on ignore-file change, watcher/kernel event loss, or overflow. `rescan_tests.rs:76-81, 153` `U18`
- MAX_OVERFLOW_FILES = 1024 slots, reserved independently for files and directories; watcher-added files under ~/.cache, ~/.local/share, ~/.docker, ~/.ollama, ~/.config, ~/.vscode are indexed into this overflow region. `constants.rs:21-22` `F22` `U16` `U18` `U76` `U78` `U79`
- StableVec::from_vec_with_reserve calls vec.reserve(1024), triggering RawVec::grow_amortized to allocate a buffer roughly twice the index size. `stable_vec.rs:47` `F26`
- Once the overflow region fills, handle_debounced_events raises IndexUpdateRejected and requests a full rescan every 30 seconds on active machines. `background_watcher.rs:624-635; rescan_throttle.rs:29-33` `F22`
- find_dir_index does a binary search over base_dirs_count, then a linear scan over the watcher-appended overflow region. `file_picker.rs:345-360` `U76`
- find_or_add_dir short-circuits with an early return when the ancestor directory is already registered, so the common case of known ancestors does not consume overflow-table slots — it is not true that overflow is only avoided when full. `file_picker.rs:364-368` `U78`
- The initial walk of a non-git root skips dotfiles via walk_builder.hidden(!is_git_repo), but the watcher's own path applies no such rule. `walk/ripgrep.rs:23, 85` `F22`
- With the ripgrep backend on a non-git home directory, IgnoreFilter falls back to a substring match against IGNORED_DIRS only. `background_watcher.rs:885; file_picker.rs:1612` `F22`
- IGNORED_DIRS on macOS explicitly lists Library/Application Support, Library/Caches, Library/Containers, Library/Group Containers, Library/pnpm, Library/Metadata, and Library/Developer/CoreSimulator — but does NOT list Library/Developer/Xcode/DerivedData, iOS DeviceSupport, Archives, CloudStorage, Mobile Documents, Mail, Safari, or photo/music library bundles. `ignore.rs:25` `F24`
- IGNORED_DIRS is a compile-time const, and the FFI only exposes boolean knobs, so Floodlight cannot exclude DerivedData without patching the vendored Rust. `fff-c/src/ffi_types.rs:56` `F25`
- Glob constraints go through globset::GlobMatcher, which has no fnmatch-style leading-dot rule for hidden files. `globset library implementation` `U22`
- background_watcher.rs:335 calls Repository::open and returns None immediately when git_workdir is None. `background_watcher.rs:335` `U64`
- IgnoreFilter::is_ignored (background_watcher.rs:872-887) falls through to is_non_code_directory when git_workdir is None, regardless of whether git2 is present. `background_watcher.rs:872-887` `U64`
- walk/ripgrep.rs:85 sets ignore_rules: None unconditionally, and no feature flags are passed to build-xcframework.sh, confirming the shipped build uses the ripgrep+git default. `walk/ripgrep.rs:85; build-xcframework.sh` `U64`
- The Sources tree has zero references to git_status/GitStatus/fff_refresh_git_status — the git feature is compiled in but unused by Floodlight. `grep results over Sources tree` `U64`
- format_git_status never returns an empty string for files; it returns "clean" for unmodified files. `git.rs:144, 162` `U16`
- fff's detect_binary_per_byte reads the entire file in 16 KB chunks without stopping after the first NUL byte. `types.rs:561` `F17`
- walk_collect_files accumulates entries into a parking_lot::Mutex-guarded Vec, returning only once traversal is complete. `walk/ripgrep.rs:39-40` `F20`
- The ripgrep walker calls entry.metadata() per file (a stat syscall). `walk/ripgrep.rs:60-65` `U22`
- FileItem::new_from_walk runs pathdiff, to_string_lossy, to_canonical_slashes, and is_known_binary per file. `file_picker.rs:489-492` `U22`
- The ripgrep walker rebuilds each relative path with pathdiff::diff_paths (walking both paths component-by-component, allocating a PathBuf then a String per file); a code comment puts this cost at roughly 80-120 ms over a 500k-entry scan. `file_picker.rs:477, 489-492` `F27` `U22`
- The walker's directory branch and the zlob backend instead use strip_prefix, which the same comment documents as the optimization avoiding that 80-120 ms/500k-entries cost. `walk/ripgrep.rs:69` `F27`
- The zlob walker bulk-fetches SIZE|MTIME during traversal, avoiding a per-file stat call. `walk/zlob.rs:36-37` `U22`
- fff 0.10.5's zlob computes basename_offset_in_relative() over raw bytes then applies from_utf8_lossy, which expands a bad byte to U+FFFD and leaves the stored offset pointing into the middle of that replacement for non-UTF-8 filenames; fff 0.10.6 (issue #799) fixed this with basename_offset_in_relative_lossy(), decoding first. `walk/zlob.rs:81-88` `U23`
- hint_allocator_collect is a no-op in Floodlight because fff-c defaults to the ripgrep feature without mimalloc-collect. `file_picker.rs:2448` `F29`
- scan.rs:94 sets install_watcher: false for a rescan job, with a comment that the watcher is independent of rescan and never restarts; file_picker.rs:988 sets install_watcher: true only on the restart path. `scan.rs:94; file_picker.rs:988` `U12`
- ScanJob::spawn (scan.rs:145-146) stores scanning=true synchronously on the calling thread, before the pooled closure runs and before the FFI call returns. `scan.rs:145-146` `U12` `U13`
- fff_restart_index publishes a fresh, empty picker before the filesystem walk begins. `file_picker.rs:957-976, esp. 966-971` `U12`
- ScanJob::new_rescan returns None while post_scan_indexing_active is true. `scan.rs:73-80` `U12`
- fff_restart_index validates the target path exists and canonicalizes it (lib.rs:908-915); a rescan does neither. `lib.rs:908-915` `U12`
- FilePicker::new_with_shared_state / fff_create_instance_with pre-arms signals.scanning=true (Release ordering) before publishing the picker and before ScanJob::spawn runs, which closes what looks like a startup race rather than leaving one open. `file_picker.rs:951-990` `U12` `U13`
- wait_for_indexing_complete returns true only when both scanning == false AND post_scan_indexing_active == false. `shared.rs:185-200` `U13`
- fff_restart_index and fff_scan_files both run an identical FileSync::walk_filesystem plus BigGram rebuild; the only work the rescan path removes is picker allocation and one BackgroundWatcher::new FSEvents install. `scan.rs:167, 325-334, 89-90; file_picker.rs:905` `U12`
- fff_restart_index drops its guard before rebuilding (lib.rs:954) and takes picker.write() only for the final pointer swap; rescan likewise constructs its picker outside the lock — so the write-lock window is already short on both paths. `lib.rs:954; file_picker.rs:967-970` `U12`
- A watcher batch takes the write lock and holds it across a stat, a 16 KB binary classification, and an uncapped whole-file read; handle_file_modify does not honor MAX_INDEXABLE_FILE_SIZE (2 MB) at index-build time, so modifying a 500 MB file allocates the full 500 MB while every search blocks on that same write lock. `file_picker.rs:1686-1688; background_watcher.rs:543; constants.rs:9` `U16`
- background_watcher.rs:402 logs tracing::debug!(event=?debounced_event.event) inside the per-FS-event loop. `background_watcher.rs:402` `U65`

### Thread pools and parallelism

- The global rayon pool sizes itself to available_parallelism(), which includes efficiency cores on Apple silicon, with no QoS pinning on macOS. `parallelism.rs:1-4; file_picker.rs:1064-1070` `U10` `U27`
- parallelism.rs documents that this oversubscribes asymmetric chips because E-cores run roughly 2x slower than P-cores. `parallelism.rs:1-4` `U10`
- SEARCH_THREAD_POOL, by contrast, is sized to performance_core_count() and is QoS-pinned on macOS. `parallelism.rs:36-64` `U27`
- A measurement in parallelism.rs on a 12P+4E M4 Max shows grep taking 6.2s with 16 threads (global pool) vs 4.9s with 13 threads (tuned, QoS-pinned pool). `parallelism.rs:60-64` `U27`
- That 6.2s→4.9s figure is specifically a grep measurement whose stated cause (open()/VFS-lock contention) does not apply to fuzzy matching, which is syscall-free and entirely in-memory — the speedup number should not be assumed to carry over to fuzzy search. `parallelism.rs:1-4; file_picker.rs:1063-1070` `U6`
- SEARCH_THREAD_POOL.install() has exactly two call sites in fff-core — inside grep() (file_picker.rs:1380) and multi_grep() (file_picker.rs:1411); fuzzy_search, fuzzy_search_directories, and fuzzy_search_mixed never install it, so mixed/directory search runs on whatever pool or thread the caller is already on. `file_picker.rs:1370-1411, 1380, 1411` `U8` `U10` `U36` `U62`
- BACKGROUND_THREAD_POOL sizes itself once, globally, at half the logical core count. `parallelism.rs:16` `F31`
- walk_filesystem hands BACKGROUND_THREAD_POOL's thread count to the walker, leaving cores unused during cold-start on high-core machines. `file_picker.rs:2075` `F31`
- The reference Neovim client (a separate consumer of the same engine) hardcodes max_threads = 4 as its default. `lua/fff/conf.lua:215; lua/fff/main.lua:156` `U6`

### Query-shape and index-size observations

- Floodlight's dominant query lengths are 1-6 characters. `finding-2 analysis` `U2`
- On M-series unified memory (roughly 50-100 GB/s bandwidth), an analysis attributes about 1-2 ms per query to FileItem memory-bandwidth overhead alone; this is a derived estimate, not a direct measurement. `finding-12 analysis` `U12`
- A realistic home-directory index on macOS, after ignore-filtering, holds roughly 100k-400k live file items (about 7-29 MB materialized, 14-58 MB transient peak). `walk/ripgrep.rs:23-24; ignore.rs:5-63` `U22`

### Dead code, unused paths, and other engine internals

- env_pool.rs uses the MDB_NOTLS flag for LMDB read transactions, so reader slots are transaction-scoped rather than thread-scoped. `env_pool.rs:97` `U32`
- FileItem::new_from_walk_bytes (file_picker.rs:498) has zero call sites — it is dead code. `file_picker.rs:498; rg -n new_from_walk_bytes` `U83`
- FuzzySearchOptions has no abort_signal field, while GrepSearchOptions does — fuzzy/mixed search cannot be cooperatively cancelled the way grep can. `file_picker.rs:1124; grep options at 1375` `U14`
- FilePicker holds no sync_data state to cache a query-to-query survivor set between keystrokes. `file_picker.rs:574-596` `U13`
- fff-nvim (crates/fff-nvim/src/log.rs:3; lib.rs:803-807) unconditionally re-exports fff::log::init_tracing and install_panic_hook for Lua-facing crash logging. `crates/fff-nvim/src/log.rs:3; crates/fff-nvim/src/lib.rs:803-807` `U65`

### Clipboard search and adjacent instrumentation

- maxImageByteCount for clipboard entries is 15 MB. `ClipboardCaptureService, finding context` `F18` `F19` `F20`
- SearchResultProjection.projectClipboard maps a SearchItem for ALL entries from an uncapped result set; buildClipboardTextRow does a synchronous FileManager.fileExists check per row. `SearchResultProjection.swift:196-199, 299` `F69`
- ClipboardImageCapture generates 128x128 device-pixel (64pt x 2.0 scale) thumbnails. `ClipboardImageCapture.swift:7-8, 60` `F72`
- source_app_bundle_id is captured at three separate call sites. `ClipboardCaptureService.swift:261, 274, 284` `F141`
- ClipboardCaptureService.swift:129 sets pollInterval: TimeInterval = 0.5 for pasteboard polling. `ClipboardCaptureService.swift:129` `F148`
- ClipboardCaptureService's poll() function (lines 232-285) is documented with seven numbered rules in comments; Rule 3 (line 244) skips pasteboard types marked concealed, transient, or is-sensitive. `ClipboardCaptureService.swift:232-285, 244` `F148`
- pruneOnSchedule is called only from start(), so a long-running process never prunes again after startup. `ClipboardCaptureService.swift:176` `F162`
- NSImage(data:) defers decoding until draw time, materializing an 80 MB RGBA buffer at that point rather than at load — it is wrong to assume NSImage decodes in 20-100ms at load time. `ClipboardInspectorPane.swift:145` `F163`
- autoresearch.sh:39-42 reads FLOODLIGHT_BENCH metrics via grep/sed/head pipelines. `autoresearch.sh:39-42, 52-55` `F156`
- SearchPerformanceTests.swift:207 emits an expanded_fff_scan_ms metric, and line 115 emits a filter_summary_us metric. `SearchPerformanceTests.swift:207, 115` `F156`
- autoresearch.sh:47 labels deliverable_size_bytes as the PRIMARY metric. `autoresearch.sh:47` `F156`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| fff_live_grep time budget (Floodlight) | 35 ms | `FFFIndex.swift:142-167, 349, 357` |
| fff_live_grep max file size | 10 MB (10,485,760 bytes) | `FFFIndex.swift:349; constants.rs:5` |
| fff_live_grep total match limit / max_matches_per_file | 16 total matches; 1 match per file | `FFFIndex.swift:349; grep.rs:129` |
| GrepSearchOptions library defaults | max_matches_per_file=200, page_limit=50, time_budget_ms=0 (unlimited) | `grep/types.rs:82-132` |
| MAX_LINE_DISPLAY_LEN (grep snippet truncation) | 512 bytes | `grep/sink.rs:5-7` |
| MAX_INDEXABLE_FILE_SIZE | 2 MB | `constants.rs:9` |
| fff_search_mixed fixed params (Floodlight) | limit, 100 total, 3 directory levels | `FFFIndex.swift:126` |
| Mixed-search internal_limit formula | (offset+limit)*2 — 24 for a limit=12 request, 48 total (24 dirs+24 files) | `file_picker.rs:1240,1242` |
| Floodlight per-keystroke UI limit | 12 | `SourceSearchEngine.swift:290` |
| RESCAN_MIN_INTERVAL | 30 s normal; 5 min above 1M files | `constants.rs:24-33` |
| MAX_OVERFLOW_FILES | 1024 slots (files and dirs independently) | `constants.rs:21-22` |
| ContentCacheBudget auto-size buckets | >50k files: 5k files/128MB; 10k-50k: 10k files/256MB; <10k: 30k files/512MB | `types.rs:908-1005, 943-958` |
| OnceLock<Mmap> per-FileItem overhead | ~24-32 bytes | `types.rs:246; file_picker.rs:2170-2180` |
| PAR_THRESHOLD (rayon parallel filtering/glob) | 10,000 items | `constraints.rs:221, 541` |
| Dominant query length | 1-6 characters | `finding-2 analysis` |
| diff_paths vs strip_prefix walker cost | ~80-120 ms per 500k entries | `file_picker.rs:489-492; walk/ripgrep.rs:69` |
| M4 Max grep pool benchmark | 6.2s (16 threads, global pool) vs 4.9s (13 threads, tuned pool) | `parallelism.rs:60-64` |
| BACKGROUND_THREAD_POOL size | half the logical core count | `parallelism.rs:16` |
| Reference Neovim client thread default | max_threads = 4 | `lua/fff/conf.lua:215` |
| Catalog refresh throttle | once per 2 seconds | `Catalog.swift:40-42` |
| ApplicationCatalog.indexedItems cap | 24 FFF results | `ApplicationCatalog.swift:133-144` |
| SourceSearchEngine bounded set before ranking | 12 apps, 24 settings, 12 files | `SourceSearchEngine.swift:244-245,290-294` |
| SourceSearchEngine internal sleeps | 15ms or 20ms (app page), plus 30ms before grep | `SourceSearchEngine.swift:266-267, 320-321` |
| Damerau-Levenshtein edit budget | 1 for query length 3-5 chars, 2 beyond | `FuzzyMatcher.swift:190-223` |
| FFFIndex.waitForScanCompletion poll cost | ~10 ms per call | `FFFIndex.swift:676-686` |
| SystemCatalog built-in settings | 39 literals, 193 lines of definitions | `SystemCatalog.swift:43-235, 455-468` |
| Home-directory index size (realistic) | ~100k-400k live items (7-29MB materialized, 14-58MB transient peak) | `walk/ripgrep.rs:23-24; ignore.rs:5-63` |
| Clipboard pasteboard poll interval | 0.5 s | `ClipboardCaptureService.swift:129` |
| Clipboard maxImageByteCount | 15 MB | `ClipboardCaptureService` |
| Clipboard thumbnail size | 128x128 device px (64pt x 2.0 scale) | `ClipboardImageCapture.swift:7-8,60` |

### Gotchas

- Floodlight never advances pagination — every search call uses page_index=0 with page_size=limit and stops after the first request, so there is no true "page 2" in the running app. `record 43 (ffi-header cluster)`
- Inside fuzzy_search_mixed, directory search runs to full completion before file search even starts, sequentially, even though the two share no mutable state that would force serialization. `file_picker.rs:1224-1290`
- A trailing-slash or path-separator-terminated query skips file search entirely — only directories are searched for such queries. `file_picker.rs:1224-1240, 1251, 1287`
- Grep's abort/time-budget check only fires on every 8th file within a rayon worker's batch; the other 7 of 8 files still complete a full mmap/read after an abort signal is raised. `grep/grep.rs:606-618`
- SEARCH_THREAD_POOL (the QoS-pinned pool) is installed only by grep()/multi_grep(); fuzzy_search, fuzzy_search_directories, and fuzzy_search_mixed never install it and simply run on the caller's pool/thread. `file_picker.rs:1370-1411`
- FuzzySearchOptions has no abort_signal field (GrepSearchOptions does), so fuzzy/mixed search cannot be cooperatively cancelled the way grep can. `file_picker.rs:1124, 1375`
- warmup_mmaps is commented out and need_complex_rebuild is never called anywhere — neither actually runs a mmap-warming job on rescan, despite code structure that suggests one exists. `scan.rs:357-359; shared.rs:145`
- A watcher batch holds the write lock across a stat, a 16KB binary check, and an uncapped whole-file read; modifying a 500MB file allocates all 500MB in memory while every concurrent search blocks on that same lock. `file_picker.rs:1686-1688; background_watcher.rs:543`
- The initial filesystem walk skips dotfiles on a non-git root, but the background watcher's own event path applies no such dotfile-skip rule. `walk/ripgrep.rs:23, 85`
- The Sources tree has zero references to git_status/GitStatus/fff_refresh_git_status even though the git feature is compiled into the shipped build — it is dead weight for Floodlight. `grep results over Sources tree; walk/ripgrep.rs:85`
- FileItem::new_from_walk_bytes has zero call sites in the codebase — it is dead code. `file_picker.rs:498`
- pruneOnSchedule is invoked only from ClipboardCaptureService.start(); a long-running process never prunes clipboard history again after startup. `ClipboardCaptureService.swift:176`
- No benchmark data exists in the repository to confirm whether the hardcoded 35ms content-search time budget is actually sufficient for a full home-directory-scope search. `audit record notes absence of host-platform benchmarks`

### Corrected on review

- ~~SourceSearchEngine.execute makes three immediatePage calls per execution.~~ → It makes two immediatePage calls (lines 244-245 and 286-287); a later use at 329/331 reuses the 286-287 values rather than calling a third time. `SourceSearchEngine.swift:244-245, 286-287, 329-331`
- ~~SearchItem.init eagerly allocates its default id.~~ → The default id uses lazy evaluation behind the `??` operator, not eager allocation. `SearchItem.swift`
- ~~SearchItemRanking.topRankedInPlace does a full sort.~~ → It is an O(n log limit) bounded-heap selection with capacity reserved once, not a full/unbounded sort. `Catalog.swift:86-134`
- ~~ApplicationCatalog.boostMap is recomputed per app inside the immediatePage loop.~~ → boostMap is already hoisted out of the loop as a single call before application iteration. `ApplicationCatalog.swift:177`
- ~~NSImage decodes an image in 20-100 ms (implying at load time).~~ → NSImage(data:) defers decode until draw time, materializing an 80 MB RGBA buffer at that later point. `ClipboardInspectorPane.swift:145`
- ~~An abort signal within 8 files means grep stops within 8 files.~~ → Only the 8th file in a rayon worker's local batch actually checks and respects a pending abort; the other 7 of every 8 files still complete a full mmap/read. `grep/grep.rs:606-618`
- ~~The measured grep speedup of 6.2s to 4.9s (20%, global vs. tuned thread pool) applies to fuzzy search too.~~ → That measurement is grep-specific; its stated cause (open()/VFS-lock contention) does not exist in fuzzy matching, which is syscall-free and in-memory. `parallelism.rs:1-4; file_picker.rs:1063-1070`
- ~~Content-search snippet length is driven by max_file_size (10 MiB), risking 10 MiB memory blow-ups per match.~~ → max_file_size only gates which files get opened; snippet/line length is separately capped at 512 bytes by truncate_display_bytes. `grep/sink.rs:5-7, 165-176`
- ~~Rebuilding the index via a full restart (changeRoot) is uniquely necessary; there is no existing wrapper to reuse for a lighter rescan.~~ → fff_restart_index and fff_scan_files run an identical FileSync::walk_filesystem plus BigGram rebuild; the only work removed on the rescan path is picker allocation and one BackgroundWatcher FSEvents install. `scan.rs:167, 325-334, 89-90; file_picker.rs:905`
- ~~Using rescan instead of restart shrinks the exclusive write-lock window from long to nothing.~~ → fff_restart_index already drops its guard before rebuilding and takes picker.write() only for the final pointer swap; rescan also constructs its picker outside the lock — both paths already hold the write lock only briefly. `lib.rs:954; file_picker.rs:967-970`
- ~~There is a startup race where fff_create_instance_with can return before scanning is set true.~~ → signals.scanning=true is set (Release ordering) before the picker is published and before ScanJob::spawn runs, closing that race. `file_picker.rs:951-990`
- ~~need_complex_rebuild gates a warmup job.~~ → need_complex_rebuild is defined but never called anywhere in the codebase. `shared.rs:145`
- ~~Every rescan runs warmup_mmaps as a post-scan job.~~ → warmup_mmaps is commented out (with a TODO) and never executed. `scan.rs:357-359`
- ~~Setting an explicit cache budget preserves warm mmap state across rescans.~~ → set_cache_budget only swaps the Arc<ContentCacheBudget> pointer; it does not invalidate or preserve mmaps across a rescan (commit_new_sync separately resets the cache unconditionally on rescan). `file_picker.rs:719-721, 1499-1502`
- ~~Setting cache_budget_max_files=0 while another field is non-zero keeps the size-appropriate auto budget for the other fields.~~ → ContentCacheBudget::from_overrides is all-or-nothing: once any field is non-zero, remaining zero fields inherit the flat default new_for_repo(30k), not the auto-sized value. `types.rs:976-991, 1000-1003`
- ~~git_status returns an empty string for unmodified files.~~ → format_git_status never returns empty for files; it returns "clean" for unmodified files. `git.rs:144, 162`
- ~~find_or_add_dir only fails to register a directory when the overflow table is exhausted; known ancestors are not given special handling.~~ → find_or_add_dir short-circuits with an early return when the ancestor is already registered, so the common case of known ancestors does not consume overflow-table slots at all. `file_picker.rs:364-368`

<a id="engine-index"></a>
## How the index is built, warmed, and kept fresh

Floodlight embeds fff-core, a Rust engine that owns one big FilePicker struct (2748 lines) coordinating three jobs: walking the filesystem into an in-memory FileSync, watching for changes, and answering fuzzy queries. A scan partitions files into indexable, unindexable, and overflow zones, commits them, then flips a "scanning" signal to false — search over filenames becomes available immediately, while content search (bigram index) finishes building afterward on the same commit. Nothing about the file list survives a restart: only two LMDB-backed side tables, frecency scores and query/selection history, persist across launches, so every launch re-walks the tree from scratch. A background watcher (inotify on Linux, FSEvents-equivalent elsewhere) debounces filesystem events, updates the same in-memory structures under a shared read-write lock, and can trigger a full rescan if changes outgrow small fixed-size overflow reserves. Floodlight deliberately diverges from upstream fff in a few places — most notably by registering every ancestor directory a watcher event touches, so new directories show up as search results immediately. On the Swift side, FFFIndex.swift wraps the C FFI, waits for scan completion by polling, and sets several content-indexing options on by default.

### Scan call flow, signals, and the Swift bridge

- FilePicker is a 2748-line struct that orchestrates filesystem indexing, watching, and fuzzy search from one place `file_picker.rs:574-596` `Engine-picker cluster`
- FileSync partitions files into three zones with separate boundaries: indexable, unindexable, and overflow `file_picker.rs:94-147` `Engine-picker cluster`
- Scans run on BACKGROUND_THREAD_POOL (about half the cores); SEARCH_THREAD_POOL (P-core count on macOS) is installed only by grep and multi_grep, not by scanning or fuzzy_search `file_picker.rs explorer-summary; parallelism.rs:62-84; file_picker.rs:1124` `Engine-picker cluster` `U4`
- restart_index_in_path / spawn_background_threads stores scanning=true (Release ordering) synchronously before the picker is published and before ScanJob::spawn runs `file_picker.rs:955-970,992` `U14` `U75`
- fff_create_instance_with can return to its caller before that background scan thread has actually flipped scanning=true, so the very first poll after creation usually still reads false `lib.rs:829-852` `U19`
- scan.rs sets scanning=false right after the walk commits and before run_post_scan builds the bigram index — the file list is searchable by name before content search is ready `scan.rs:228,240,325-334` `U4` `U9` `U10` `U20` `U75` `U81`
- ScanningGuard is an RAII guard that clears the scanning signal even on an early return or panic `scan.rs:365-380` `U10`
- FileSync.walk_filesystem holds no picker lock at all; only commit_new_sync takes the write lock, so the expensive walk itself never blocks readers `scan.rs:154-206` `U39`
- is_warmup_complete = !enable_content_indexing || bigram_index.is_some(); Floodlight enables content indexing by default, so warmup completion is really gated on the bigram index existing `file_picker.rs:1437-1438; FFFIndex.swift:24,78` `U20` `U4` `U81`
- run_post_scan's warmup_mmaps call is commented out with the note "TODO Skipped as potentially unsafe," so post-scan today only runs bigram-index build and binary sniffing, not mmap warming `scan.rs:357-360` `U4`
- rescan_pending is an atomic flag that queues a rescan requested while one is already active, without racing `scan.rs:25` `U27`
- No file list is ever checkpointed to disk; every scan builds a fresh FileSync purely in memory `file_picker.rs:2061-2140` `U26`
- enable_mmap_cache warms the OS page cache, not a persisted file list — the index itself is never saved, so a full walk repeats on every app launch `file_picker.rs:939` `U39`
- SharedPicker::wait_for_scan is a blocking poll loop (poll_until), not an event/signal callback `shared.rs:154-166` `U75`
- FFFIndex.swift's waitForScanCompletion sleeps once for 10 ms when the index is already idle, not twice for a 20 ms floor `FFFIndex.swift:678-687` `F57`
- FFFIndex's production convenience initializer defaults to enableHomeDirectoryScanning=true, enableContentIndexing=true, watch=true, includeBinaryFiles=true `FFFIndex.swift:699-708,24-27` `F62`
- fff_create_instance_with builds indexes from base_path, starts the background watcher, and (per its own doc comment) aims for a roughly 1-2 second cold start `fff.h:fff_create_instance_with` `ffi-header cluster`
- ScanJob exposes progress via scanned_files_counter, an Arc<AtomicUsize> the UI thread polls with relaxed-ordering loads `scan.rs:51-63` `U15`
- fuzzy_search is the main entry point for filename matching; fuzzy_search_mixed performs a combined file-and-directory search with immediate path matching `file_picker.rs:1057-1154,1224-1310` `U14`
- log.rs installs a process-wide SIGSEGV handler and replaces the panic hook during tracing setup, giving scan and watcher threads a crash safety net `log.rs:92,119` `U3` `U29`

### Walkers and ignore rules

- Ripgrep is the default walker; zlob is 15-20% faster on large repos `walk/mod.rs:11-19` `U20`
- The ripgrep walker batches files per entry behind a single parking_lot Mutex, taking one lock per append `ripgrep.rs:40,64,74` `U12`
- Ripgrep's walker calls entry.metadata() unconditionally per file — a real lstat, since walkdir doesn't cache metadata — making it the more stat-heavy of the two walkers despite being the default `walk/ripgrep.rs:60-62` `U57`
- FileItem::new_from_walk_parts, used on the ripgrep path, runs pathdiff::diff_paths, to_string_lossy, to_canonical_slashes, and is_known_binary_extension for every entry `file_picker.rs:468-486` `U57`
- The ripgrep walker computes each basename offset from an already-decoded to_string_lossy() string `walk/ripgrep.rs:63` `U22`
- Zlob emits progress every 13 files and returns an exact count at the end `zlob.rs:92,109` `U13`
- Zlob bulk-fetches only SIZE and MTIME metadata via WalkMetadata::SIZE|MTIME, instead of one entry.metadata() per file `zlob.rs:36-37; walk/zlob.rs:36-37` `U13` `U57`
- Zlob calls FileItem::new_raw directly, skipping the path canonicalization and binary-extension checks the ripgrep path performs `zlob.rs:85` `U57`
- Zlob handles non-UTF8 paths via relative_path_lossy and basename_offset_in_relative_lossy `walk/zlob.rs:54-89` `U19`
- Zlob's bulk metadata fetch saves an estimated 80-120 ms on a chromium-scale scan, per the engine's own doc comment `file_picker.rs FileItem::new_from_walk_bytes doc` `U23`
- Excluded by design: hidden paths, node_modules, Python venvs, Rust build directories, Library subdirectories, .local state, package caches, and .gitignore rules `indexing.mdx; walk/ripgrep.rs:23` `Documentation & Architecture cluster` `U35`
- A hardcoded IGNORED_DIRS list on macOS excludes roughly 30 patterns (Library caches, containers, logs) `ignore.rs:5-65` `U18`
- GLOB_FLAGS = RECOMMENDED | PERIOD, a fix so glob patterns can cross dot-directories `constraints.rs:151-155` `U18`
- constraints.rs, bigram_filter.rs, and walk/zlob.rs are untouched relative to upstream fff v0.10.5 `diff vs upstream v0.10.5` `U21`

### FileItem and DirItem: layout and memory

- FileItem carries size, modified, access/modification frecency scores, an optional git_status, a path pointer, parent_dir_index, an atomic flags byte, and an OnceLock content mmap `types.rs:48-61` `U17` `U24`
- FileItemFlags uses bits 0-2 only — BINARY=1, DELETED=2, OVERFLOW=4 — leaving bits 3-7 free for future flags `types.rs:56-66,59-65` `U17`
- flags is an AtomicU8 so DELETED/OVERFLOW marking during watcher updates is thread-safe without a lock `types.rs:56-66` `U17`
- DirItem.max_access_frecency is an AtomicI32 updated lock-free via fetch_max during parallel scoring `file_picker.rs:explorer-file; types.rs:161` `Engine-picker cluster` `U17`
- A runtime size_of::<FileItem>() log (visible in SCAN log lines) and a structural breakdown both put FileItem at roughly 96 bytes on arm64, of which the OnceLock<memmap2::Mmap> content field accounts for about 24 bytes `types.rs:245-259; file_picker.rs:2162-2180` `U7` `U56`
- FileItem.set_binary() and update_metadata() mutate the struct in place, but only under the write lock `types.rs:549,655-662` `U54`
- The content OnceLock<memmap2::Mmap> field is compiled out entirely on Windows via cfg(not(windows)) `types.rs:258-259` `U7`
- That content field's only readers are invalidate_content_cache and get_cached_content/get_content_for_search; fuzzy matching (resolve_file_chunks) touches only the flags and path fields `types.rs:258-259; score.rs:33-42` `U7`
- new_for_repo auto-sizes the mmap cache to at most 5000 FileItems once a repo passes 50k files, so in a 500k-file index roughly 99% of FileItems can never populate their OnceLock (about 12 MB of struct effectively unused), and in a 1M-file index at most 0.5% can ever hold an Mmap `types.rs:944-995; file_picker.rs:2162-2181,2206` `U56`
- include_binary_files is a plain bool field on FilePicker, feeding a scan-time filter, but changes no observable behavior in Floodlight today `file_picker.rs:589,2089-2092` `U14` `U24`

### Arena, chunked paths, and overflow reserves

- About 85% of file paths fit inline in ChunkedString chunks, avoiding a separate heap allocation per path `simd_path.rs:9-11` `U7`
- Arena chunks are deduplicated, reducing the number of distinct chunk reads across similar paths `simd_path.rs:292,328-338` `U7`
- ChunkIndices is a SmallVec<[u32;4]> that heap-allocates as soon as a path exceeds 64 bytes `simd_path.rs:12,322` `U56`
- Directory paths are stored with a trailing separator via slicing &dir_path[..=index] `file_picker.rs:2324-2329` `U27`
- At 250k files, FileItem storage is about 12 MB for the vec plus 20-50 MB of deduplicated chunked path storage `types.rs:48-61; file_picker.rs:2112-2121` `U24`
- MAX_OVERFLOW_FILES = 1024, reserved as two separate StableVecs — one for files, one for directories — not a single shared pool `constants.rs:21-22; file_picker.rs:2187,2191` `U17` `U24` `U78`
- ChunkedPathStoreBuilder::new uses 1024 only as a Vec::with_capacity growth hint for the path arena, not a hard ceiling on path storage `simd_path.rs:295-302` `U78`
- find_or_add_dir already does a binary-search precheck against known ancestors, so exhausting the 1024-slot directory overflow reserve in practice requires roughly 150-250 distinct brand-new nested directory trees, not one slot per watcher event `file_picker.rs:364-368,1740-1748` `U78`
- The overflow Vec's extend-capacity optimization only fires once files.len() exceeds base_count — i.e. after the watcher has already appended at least one overflow file since the last full scan `file_picker.rs:1727-1760` `U37`
- The overflow region must be fully rescanned to stay coherent while watching a large home directory `file_picker.rs:1697` `U32`
- A full rescan is triggered when index_update_rejected is true or the overflow count exceeds MAX_OVERFLOW_FILES `background_watcher.rs:624` `U17`

### Bigram content index build

- The bigram overlay is built after the main scan and updated on file modify — it is never computed live during the initial walk `file_picker.rs explorer-summary` `Engine-picker cluster`
- FileSync.bigram_overlay is an Arc<RwLock<..>> for concurrent read/write access `file_picker.rs explorer-file` `Engine-picker cluster`
- BigramIndexBuilder lazily allocates via OnceLock<UnsafeCell<..>>, letting concurrent writers use disjoint ranges without contention `bigram_filter.rs:35-50` `U17`
- MAX_BIGRAM_COLUMNS = 5000, sized to cover roughly 4900 distinct printable bigrams after lowercasing, with margin `bigram_filter.rs:12-15` `U17` `U51`
- get_or_alloc_column hands out column IDs sequentially via fetch_add on a bigram's first occurrence, but uses Relaxed ordering on both the fast-path load and the CAS, which races when publishing a freshly-allocated heap pointer `bigram_filter.rs:85-101,88,96-97` `U51`
- The next_column counter is only an AtomicU16 and wraps at 65536 under enough CAS races, which can reassign a column ID to a different bigram and silently weaken the filter — column IDs are not permanently stable `bigram_filter.rs:85-101,88` `U51`
- BIGRAM_CHUNK_FILES = 256 (4×64); the prefilter build parallelizes into 256-file chunks via rayon par_chunks `bigram_filter.rs:791,829` `U54` `Engine bigram prefilter index cluster`
- SEEN_WORDS is a 1024-entry u64 array used for concurrent flush tracking `bigram_filter.rs:21` `U17`
- LONG_CONTENT_MIN_LEN = 1024 bytes, the length threshold where branchless two-pass scanning overtakes single-pass `bigram_filter.rs:26` `U17`
- add_long_content uses a stack-local 8 KB seen-bitset without real-time ORs `bigram_filter.rs:264` `Engine bigram prefilter index cluster`
- Each indexable file reserves roughly 1.25 KB in the bigram filter (5000 × ceil(N/64) × 8 × 2); a 200,000-file home directory reserves about 250 MB, and the worst case at 500,000 files with all 5000 columns populated is 312.5 MB `bigram_filter.rs:14-15,52-54,70-73,834-835` `U51`
- compress() drops columns that are sparse (under 3.1% of files) or near-ubiquitous (90%+); the skip-1 sub-index instead uses a 12% density cutoff — but this filtering runs only after the full 5000-column slab has already been allocated `bigram_filter.rs:336-355,356,796` `Engine bigram prefilter index cluster` `U51`
- In a typical home directory (source code, minified JS, JSON, base64 blobs, logs), about 98% of the 5000 bigram columns end up allocated before density filtering runs `bigram_filter.rs:12-15,336-355` `U51`
- BigramFilter itself is a 65536×u16 lookup table plus a dense Vec<u64> at stride, with an optional skip_index `bigram_filter.rs:387-401` `U7`
- A 1-character query returns None from BigramFilter.query, since a single byte produces no bigram `bigram_filter.rs:417` `Engine bigram prefilter index cluster`
- normalize_bytes_neon is gated behind target_feature="neon" at compile time `bigram_filter.rs:604-607` `U6`
- The overlay's base_file_count — the partition point where indexable files end — is set via BigramOverlay::new(indexable_count) `file_picker.rs:1445-1446` `U35`
- Binary detection reads a 16 KB chunk (BINARY_CLASSIFICATION_CHUNK_SIZE) and checks for a NUL byte `types.rs:85,90` `U17`
- A file qualifies for content indexing only if it's non-binary and 0 < size ≤ 2 MB (MAX_INDEXABLE_FILE_SIZE) `file_picker.rs:2142-2147; constants.rs:9` `U51` `U54` `U35`
- handle_file_modify re-reads metadata, re-runs the 16 KB binary check, and re-reads content, but never re-checks is_binary() after that reclassification — a file that just turned binary can still be read and bigram-extracted `file_picker.rs:1641-1688,1672-1674` `U35`
- That uncapped re-read on modify only fires for files that were non-binary and ≤2 MB at the last scan but have since grown — not for an arbitrary large file `file_picker.rs:2143-2147` `U35`

### LMDB persistence: frecency and query history

- FrecencyTracker and QueryTracker (LMDB) are the only on-disk persistence in the whole system; the file index itself is fully volatile in memory `scan.rs:305-361; shared.rs:421-531; indexing.mdx` `U26` `Documentation & Architecture cluster`
- The query tracker's key is blake3(project_path || '::' || query), so different projects and different query strings never collide `query_tracker.rs:144-156` `U8`
- The get_last_query_entry combo lookup lives inside fuzzy_search, not fuzzy_search_mixed `file_picker.rs:1057,1093-1105` `U8`
- Each tracker spawns its own LMDB garbage-collection thread on initialization `shared.rs:477-489; dbs/lmdb.rs:70` `U11`
- The per-keystroke LMDB read path is indexedItems → searchFiles → fff_search → query_tracker.read() → get_last_query_entry inside fuzzy_search `lib.rs:375-380; file_picker.rs:1093-1105; query_tracker.rs:331-355` `U11`
- fff_track_query is wired up: a combo boost of open_count × combo_boost_score_multiplier is awarded once open_count ≥ min_combo_count, so repeatedly-typed exact queries do accumulate a ranking boost `file_picker.rs:1093-1105; score.rs:794-816; FFFIndex.swift:127` `U5`
- resolvePathQuery only substitutes the relative path when relativePath(of:within:) succeeds; for out-of-root paths it falls back to the trimmed query, so write-time and read-time keys already agree `FFFIndex.swift:519-533` `U8`
- Floodlight's access_frecency_score is effectively pinned at 0: track_access is only called from fff-nvim and the AI-mode watcher branch, and Floodlight sets ai_mode=false, so nothing writes the LMDB table get_access_score reads `FFFIndex.swift:80; background_watcher.rs:659; frecency.rs:258,317` `U5`

### Filesystem watcher: debounce, throttle, and directory registration

- On Linux, inotify watches each directory non-recursively, manually maintaining subscriptions itself `background_watcher.rs:59,73` `U19`
- DEBOUNCE_TIMEOUT = 50 ms; the watcher tick rate is 25 ms `background_watcher.rs:39,14` `U19` `U35`
- An owner thread (fff-watcher-own) processes WatchTask messages over an mpsc channel, so it never holds picker locks directly `background_watcher.rs:117-165` `U19`
- The Linux watch loop tolerates up to 16 consecutive failures before aborting `background_watcher.rs:61-99` `U19`
- The watcher is installed only after the initial scan completes, via config.install_watcher `background_watcher.rs:251` `U27`
- RescanThrottle serializes concurrent rescan requests with an atomic compare-and-swap `rescan_throttle.rs:44-47` `U15`
- Minimum rescan interval is 30 seconds baseline, or 5 minutes once the tree has 1M+ files and sits outside a git repo `rescan_throttle.rs:28-52` `U15`
- trigger_full_rescan only checks the throttle when the reason isn't Explicit — explicit rescans bypass it entirely `shared.rs:225-262` `U16`
- handle_directory_create_or_modify and its per-path loop run inside one write-lock guard acquired once per debounced batch `background_watcher.rs:543,767-785` `U15` `U35`
- That handler walks every ancestor directory through find_or_add_dir, doing a binary search over roughly 10^4-10^5 base directories plus a linear scan of the overflow region per probe, decoding each candidate path into a PATH_MAX stack buffer `file_picker.rs:1621-1637,345-360` `U15`
- Upstream fff v0.10.5 never registered ancestor directories from watcher events at all, and used a non-propagating if-let for parent-dir registration plus an early `if files_to_add.is_empty() { return }` guard before touching the write lock `upstream v0.10.5 background_watcher.rs:764,767; file_picker.rs:1621-1637` `U15` `U16` `U77`
- Floodlight removes that early-return guard, so every directory event takes the picker write lock, and propagates ancestor-registration failures with `?` instead of tolerating them — a failed add_new_file surfaces as index_update_rejected and forces a full rescan `background_watcher.rs:767; file_picker.rs:1741-1751,790` `U16` `U18` `U79`
- This ancestor-registration behavior is a documented, intentional Floodlight feature — "register watcher-created directories and ancestors as first-class search results" — not an accidental regression `UPSTREAM.md:9-10; file_picker.rs:1621-1638` `U76` `U77`
- Upstream consumed at most one overflow directory slot per new file (the leaf parent); Floodlight's version can consume up to `depth` slots per brand-new nested directory `upstream v0.10.5 file_picker.rs; file_picker.rs:1741-1751` `U17`
- A separate files-overflow guard checks the file overflow count before directory registration even runs, and can independently trigger a rescan `background_watcher.rs:588-591` `U78`
- parking_lot::RwLock is not reader-preferring; SharedPickerInner.picker uses a task-fair policy, so a single queued writer (e.g. a watcher-triggered directory registration) blocks all subsequent readers until it completes `shared.rs:78` `U16` `U35`
- IgnoreFilter opens a fresh libgit2 Repository per debounced batch when its cached rules are None; WalkIgnoreRules is never actually constructed in ripgrep-walker builds, so rules stays None and every changed path in a watch batch is checked via repo.is_path_ignored `background_watcher.rs:338,847-888,881; walk/mod.rs:46` `U2` `U64`
- git2 remains a genuine, non-dead runtime dependency — 25 call sites across 9 files, including real git-dirty-boosting in the frecency scorer, not just the unused fff_health_check path `error.rs, git.rs, shared.rs, file_picker.rs, types.rs, score.rs, index/constraints.rs, watcher/background_watcher.rs, dbs/frecency.rs` `U61` `U64`
- git_workdir is derived once per index via Repository::discover(base_path), Some only when the home directory sits inside a git working tree; get_modification_score applies its git-dirty boost only when git_workdir is Some `file_picker.rs:1009,2034-2045; frecency.rs:364-370` `U64`

### Cache budgets and process safety

- The auto cache budget is recomputed on every scan commit via ContentCacheBudget::new_for_repo(live_count), with no hysteresis between recomputations `scan.rs:201-203` `U24`
- Setting cache_budget_max_* to 0 in FFFIndex initialization falls back to the engine's default auto-sizing — it does not mean unlimited and does not mean disabled `.scratch/fff-search-bench/research/fff-engine-landscape.md:104` `F171`
- Floodlight's live updates require no restart: newly installed apps are picked up and settings changes refresh the index `indexing.mdx` `Documentation & Architecture cluster`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| MAX_BIGRAM_COLUMNS | 5000 | `bigram_filter.rs:14-15` |
| BIGRAM_CHUNK_FILES | 256 (4×64) | `bigram_filter.rs:791,829` |
| SEEN_WORDS | 1024-entry u64 array | `bigram_filter.rs:21` |
| LONG_CONTENT_MIN_LEN | 1024 bytes | `bigram_filter.rs:26` |
| MAX_INDEXABLE_FILE_SIZE | 2 MB | `constants.rs:9` |
| MAX_OVERFLOW_FILES | 1024, separate pools for files and dirs | `constants.rs:21-22` |
| BINARY_CLASSIFICATION_CHUNK_SIZE | 16 KB | `types.rs:85,90` |
| Watcher debounce / tick | 50 ms debounce, 25 ms tick | `background_watcher.rs:39,14` |
| Rescan minimum interval | 30 s baseline, 5 min for 1M+ files outside git | `rescan_throttle.rs:28-52` |
| Linux watcher failure tolerance | 16 consecutive failures before abort | `background_watcher.rs:61-99` |
| Bigram density cutoffs | drop <3.1% or ≥90%; skip-1 sub-index uses 12% | `bigram_filter.rs:356,796` |
| Bigram memory footprint | ~1.25 KB per indexable file; ~250 MB at 200k files; 312.5 MB worst case at 500k files | `bigram_filter.rs:14-15,52-54,70-73,834-835` |
| FileItem size (measured) | ~96 bytes on arm64, ~24 bytes of it the content OnceLock | `types.rs:245-259; file_picker.rs:2162-2180` |
| Mmap-cache cap | auto-sizes to 5000 files once repo exceeds 50k files | `types.rs:944-947` |
| FileItem memory at 250k files | ~12 MB vec + 20-50 MB path storage | `types.rs:48-61; file_picker.rs:2112-2121` |
| Directory overflow cap in practice | ~150-250 new nested directory trees to exhaust | `file_picker.rs:364-368` |
| waitForScanCompletion idle sleep | 10 ms, once | `FFFIndex.swift:678-687` |
| Cold start (fff_create_instance_with) | ~1-2 seconds | `fff.h fff_create_instance_with doc` |
| ChunkedString inline-path rate | ~85% of paths stored inline, no separate allocation | `simd_path.rs:9-11` |

### Gotchas

- scanning=false fires immediately after the walk commits, before the bigram content index exists — "not scanning" means filenames are searchable, not that content search or is_warmup_complete is true yet. `scan.rs:228,240,325-334; file_picker.rs:1437-1438`
- run_post_scan's mmap-warming call (warmup_mmaps) is commented out ("TODO Skipped as potentially unsafe"), so despite names like enable_mmap_cache, no mmap prewarming actually runs on the post-scan path today. `scan.rs:357-360; file_picker.rs:939`
- FileItem's size is described two ways in different places — a 48-byte field tally versus a ~96-byte figure backed by an actual runtime size_of::<FileItem>() log; the measured 96-byte figure is the one with direct evidence. `types.rs:48-61 (claimed 48B) vs types.rs:245-259 and file_picker.rs:2162-2180 (measured ~96B)`
- The bigram column allocator's next_column counter is only an AtomicU16 and can wrap at 65536 under contention, silently reassigning a column ID to a different bigram — column IDs are not guaranteed stable forever. `bigram_filter.rs:85-101,88`
- Floodlight's watcher deliberately registers every ancestor directory on file events (unlike upstream fff), which sounds unbounded, but the 1024-slot overflow cap in practice needs ~150-250 brand-new nested directory trees to exhaust, because find_or_add_dir already skips ancestors it recognizes. `file_picker.rs:364-368,1740-1748; UPSTREAM.md:9-10`
- access_frecency_score always reads as 0 in Floodlight: the LMDB table it reads is only ever written from an fff-nvim / AI-mode code path, and Floodlight explicitly sets ai_mode=false. `FFFIndex.swift:80; background_watcher.rs:659; frecency.rs:258,317`
- include_binary_files is a real filter field and gate in the Rust core, but it produces no observable difference in Floodlight's behavior today. `file_picker.rs:589,2089-2092`
- Ripgrep, the default walker, is not the cheap one per file — it calls entry.metadata() (a real lstat) on every entry, while zlob's speed edge comes partly from fetching size/mtime in one bulk pass instead. `walk/ripgrep.rs:60-62; walk/zlob.rs:36-37`
- Because WalkIgnoreRules is never constructed on the ripgrep-walker build, IgnoreFilter's cached rules stay None permanently, so every changed path in a watcher batch reopens a libgit2 Repository handle instead of hitting a cheap table. `walk/mod.rs:46; background_watcher.rs:338`
- parking_lot::RwLock is not reader-preferring, so a single watcher-triggered write (e.g. registering a new directory) can queue behind readers and then block every subsequent reader until it finishes. `shared.rs:78`

### Corrected on review

- ~~warmup_mmaps is part of the post-scan phase that blocks content search~~ → The warmup_mmaps call is commented out at scan.rs:357-360 ("TODO Skipped as potentially unsafe"), so run_post_scan only builds the bigram index and does binary sniffing — it never warms mmaps. `scan.rs:357-360`
- ~~Ranking is structurally dead with no learning for user-facing queries~~ → fff_track_query is wired and awards open_count × combo_boost_score_multiplier once open_count ≥ min_combo_count, so repeatedly-typed exact queries already learn. `file_picker.rs:1093-1105; score.rs:794-816; FFFIndex.swift:127`
- ~~Query key mismatch is permanently dead for any query containing ~/ or a leading /~~ → resolvePathQuery only substitutes the relative path when relativePath(of:within:) succeeds; for out-of-root paths it returns the trimmed query, so write and read keys already agree. `FFFIndex.swift:519-533`
- ~~The 72-byte allocation doubling occurs on every query~~ → The overflow Vec extend optimization only fires when files.len() > base_count, meaning the watcher has appended at least one overflow file since the last scan. `file_picker.rs:1727-1760`
- ~~A modified 500 MB file allocates and reads 500 MB~~ → The uncapped read in handle_file_modify only fires for files that were non-binary and ≤2 MB at scan time but have since grown. `file_picker.rs:2143-2147`
- ~~The 2-30 s scan duration includes content indexing~~ → scan.rs sets signals.scanning = false before run_post_scan, so waitForScanCompletion waits only for the walk commit, not for content indexing to finish. `scan.rs:227`
- ~~The file index is persisted across launches~~ → enable_mmap_cache maps to OS page-cache warming, not a persisted file list — the full walk repeats on every launch. `file_picker.rs:939`
- ~~Bigram column IDs are permanently assigned~~ → The next_column AtomicU16 wraps at 65536 after excessive CAS races and can reassign column IDs to different bigrams, silently weakening the filter. `bigram_filter.rs:85-101,88`
- ~~A dir_is_registered precheck needs to be added before ancestor registration~~ → Floodlight's ancestor registration already uses find_or_add_dir, which implements a binary-search precheck internally. `file_picker.rs:364-368,1740-1748`
- ~~MAX_OVERFLOW_FILES=1024 is a shared reserve for the path arena~~ → ChunkedPathStoreBuilder::new uses 1024 only as a Vec::with_capacity hint for a growable arena, not a hard ceiling. `simd_path.rs:295-302`
- ~~Files and directories share the same 1024-slot overflow reserve~~ → Floodlight uses two separate, independent StableVecs — one for files, one for directories — each with its own 1024-slot cap. `file_picker.rs:2187,2191`
- ~~Every watcher event consumes `depth` overflow slots because find_dir_index doesn't skip known ancestors~~ → find_or_add_dir already skips ancestors it recognizes, so hitting the 1024-slot directory cap requires roughly 150-250 distinct brand-new nested directory trees. `file_picker.rs:364-368`
- ~~waitForScanCompletion sleeps twice for a 20 ms floor~~ → waitForScanCompletion sleeps once, for 10 ms, when the index is already idle. `FFFIndex.swift:678-687`
- ~~cache_budget_max_* = 0 semantics are unknown (unlimited vs disabled)~~ → Setting cache_budget_max_* to 0 makes the engine fall back to its default auto-sizing — neither unlimited nor disabled. `.scratch/fff-search-bench/research/fff-engine-landscape.md:104`

<a id="grep"></a>
## How content search (live grep) works

When Floodlight wants to search inside file contents, FFFIndex.searchContent calls the Rust fff_live_grep function across the C shim, but only when the query text is at least 3 bytes and the current index has fewer than 12 files. The call ships a fixed, hardcoded set of options: a 35ms time budget, a 16-row page limit, a 10MB per-file size cap, and plain-text mode (never regex). Inside Rust, the engine first tries a bigram-based prefilter to narrow candidate files; if that prefilter yields zero matches after a full scan, it falls back to a literal scan of the same file-path-constrained candidate set rather than broadening the query. The operation carries budget and abort-signal checks, and a per-search staleness check, but both are weaker or less exercised in practice than a newcomer would assume. The Rust result struct returns more than Floodlight uses — it reads only the match count and drops the richer totals the Rust side already computed. On the way out, grep results pass through the same path-based post-filter as the other search entry points, and the UI caps how many rows it will ever show.

### Eligibility and the parameters Floodlight passes

- Content grep is only attempted when the query is at least 3 bytes and the indexed-file count is below 12. `SourceSearchEngine.swift:306` `F11`
- FFFIndex.searchContent calls fff_live_grep with time_budget_ms=35, page_limit=16, and max_file_size=10MB. `FFFIndex.swift:349-362, fff.h:631-642` `U15`
- mode is hardcoded to 0 (plain text, no regex) at FFFIndex.swift:356, which guarantees regex_fallback_error is always null. `FFFIndex.swift:356, fff.h:621-622` `U17`

### Time budget, staleness checks, and the abort signal

- fff_live_grep is given a 35ms internal time budget per call. `FFFIndex.swift:344` `F11`
- The generation staleness check that FFF operations use runs only once, before the FFI call is made — not while the call is in flight. `FFFIndex.swift:104-105` `F12`
- FFFIndex.searchContent skips the reserveSearchGeneration/isLatestSearch guard that search, searchFiles, and searchDirectories all have. `FFFIndex.swift:341-350 vs 102-105` `F11`
- The grep hot path's abort-signal and budget checks are effectively never taken, because the whole call finishes inside the 35ms window before they'd matter. `fff-swift/Vendor/fff/crates/fff-core hot paths` `U10`

### Bigram prefilter and the literal fallback

- The bigram candidate prefilter is used only by grep, not by other fff search paths. `grep/grep.rs:197-209, file_picker.rs:1372-1418` `U10`
- Without the bigram prefilter, grep has no early-exit condition and spends its entire time budget scanning candidates. `fff-core grep implementation logic` `U20`
- The literal fallback fires when a completed scan produces zero matches and reaches the end of the file list (result.matches.is_empty() && result.next_file_offset == 0). `grep.rs:222-223` `U17`
- The fallback keeps the original FilePath constraints and reruns the raw literal string — it narrows the retry to the same file set rather than widening the search. `grep.rs:235-244` `U17`
- regex_fallback_error is only ever assigned inside the GrepMode::Regex branch, so with mode hardcoded to 0 that branch — and the field — is unreachable. `grep.rs:301, 337, 450` `U17`

### The result struct vs. what Floodlight actually reads

- FFFIndex reads only the count field off FffMixedSearchResult and discards total_matched and total_files. `FFFIndex.swift:136-139` `U14`
- total_matched is a combined files+directories match count taken before pagination and post-filtering are applied. `fff.h:403-405` `U14`
- total_files and total_dirs report index cardinalities (how many files/directories are indexed overall), not how many matched the query. `fff.h:407-409` `U11`

### Post-processing and display limits

- All four FFFIndex search entry points — search, searchFiles, searchDirectories, and searchContent — run results through the same filter: splitting the path on slash and checking for .app bundles. `FFFIndex.swift:151, 223, 280, 389` `F4`
- FloodlightMetrics caps visible results at 7; SearchResultProjection separately caps the underlying result set at 80 rows. `FloodlightMetrics.swift:12; SearchResultProjection.swift:436` `F74`
- fff_multi_grep is never called anywhere in Floodlight, even though fff_live_grep is in active use. `Floodlight sources (grep-related symbol audit)` `U61`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Content-grep query length floor | query byte count >= 3 | `SourceSearchEngine.swift:306` |
| Content-grep indexed-file ceiling | indexed files < 12 | `SourceSearchEngine.swift:306` |
| fff_live_grep time budget | 35 ms | `FFFIndex.swift:344, 349-362` |
| fff_live_grep page limit | 16 rows per page | `FFFIndex.swift:349-362, fff.h:631-642` |
| fff_live_grep max file size | 10 MB | `FFFIndex.swift:349-362, fff.h:631-642` |
| fff_live_grep mode | 0 (plain text, hardcoded) | `FFFIndex.swift:356` |
| Visible result cap (menu) | FloodlightMetrics.maximumVisibleResults = 7 | `FloodlightMetrics.swift:12` |
| Underlying result cap | SearchResultProjection.maxResultsLimit = 80 | `SearchResultProjection.swift:436` |

### Gotchas

- searchContent looks like the other three search functions but actually skips their per-search staleness guard (reserveSearchGeneration/isLatestSearch) entirely. `FFFIndex.swift:341-350 vs 102-105`
- The grep call has abort-signal and time-budget checks, suggesting it can be interrupted mid-flight, but the 35ms budget is short enough that those checks are effectively never reached. `fff-core hot paths; FFFIndex.swift:344`
- FffMixedSearchResult carries total_matched, total_files, and total_dirs, but Floodlight reads only count — the richer totals the Rust side computes are thrown away. `FFFIndex.swift:136-139; fff.h:403-409`
- The API exposes a regex_fallback_error field, but because mode is hardcoded to plain-text (0), the code path that ever sets it (GrepMode::Regex) can never run — the field is permanently null. `FFFIndex.swift:356; grep.rs:301,337,450`
- The literal fallback after an empty bigram-prefiltered scan does not broaden the search — it keeps the same FilePath constraints and just reruns the raw string as a literal. `grep.rs:235-244`
- Floodlight has a batch grep entry point (fff_multi_grep) available in the FFI surface but never calls it, relying only on the single-query fff_live_grep. `Floodlight sources (grep-related symbol audit)`

### Corrected on review

- ~~regex_fallback_error can be observed in production~~ → mode = 0 is hardcoded in FFFIndex.swift:356; mode 0 is plain text (no regex), so regex_fallback_error is guaranteed null in Floodlight's usage. `FFFIndex.swift:356, fff.h:621-622`
- ~~formattedModifiedDate fires per row per keystroke~~ → ResultShowcase.formattedModifiedDate is referenced only by tests, never by production rendering code, so it carries no per-row render cost. `ResultShowcase.swift:30`

<a id="swift-search-execution"></a>
## Floodlight: Search Execution stages, tokens, cancellation, readiness

This section covers how Floodlight executes a search: the actor/concurrency setup, the three-stage pipeline (immediate app/settings results, then indexed files/apps, then content grep), how results are merged and published as snapshots, how SearchCoordinator turns snapshots into on-screen projections, how selections are tracked, how cancellation works through a generation counter and Swift Task cancellation, and how startup/warm-up/cold-start readiness is handled. SourceSearchEngine is a `package actor` that owns the pipeline; FFFIndex is the Swift wrapper around the Rust/C fff engine, reached through two independent FFF instances (the main file index and ApplicationCatalog's marker index). Cancellation is only partial: a generation counter drops stale queued work, but a query already dispatched to the C FFI queue runs to completion regardless of Task cancellation. Readiness is tracked per source (files/applications/settings) and surfaces to the UI as `pendingKinds` on each `SearchSnapshot`. Several facts in this batch are internal corrections to earlier (wrong) claims about call counts, gate semantics, thread affinity, and instrumentation coverage — these are recorded under `corrections` below.

### Actor model, concurrency setup, and call chain

- SourceSearchEngine is declared as a `package actor` (SourceSearchEngine.swift:48/50). `SourceSearchEngine.swift:48,50` `K1197` `K1271` `K1425`
- Because SourceSearchEngine is an actor, its work — including query normalization — runs off the main thread, not on it. `SourceSearchEngine.swift:50` `K1278`
- SearchCoordinator is a MainActor class whose `query.didSet` calls `scheduleSearch()` on every keystroke with no debounce. `SearchCoordinator.swift:5-6,8-14` `K1208` `K1799` `K2486` `K1310`
- Package.swift (line 9) enables the Swift 6.4 upcoming features NonisolatedNonsendingByDefault and InferIsolatedConformances for every target, letting isolated-actor access happen without @Sendable and letting nonisolated async functions inherit the caller's actor isolation. `Package.swift:9` `K749` `K1483` `K1522`
- ApplicationCatalog.indexedItems is a nonisolated async method that, because of that feature, inherits the calling SourceSearchEngine actor's isolation. `ApplicationCatalog.swift:125; Package.swift` `K704`
- SystemCatalog.refreshIfNeeded is deliberately marked `@concurrent` — its doc comment explains a plain nonisolated async method would otherwise inherit the caller's actor isolation, and filesystem I/O must not block SourceSearchEngine. `SystemCatalog.swift:261-274` `K706` `K1485`
- ADR 0001 defines SourceSearchEngine's domain model using the concepts Search Source, Search Execution, and Search Snapshot. `CONTEXT.md` `K148`
- The engine's hot paths, called from the shell, are SourceSearchEngine, FuzzyMatcher.scoreASCII, SearchItemRanking, and topRanked. `Package.swift context; SearchCoordinator source` `K779`
- All three FFFIndex search methods (search, searchFiles, searchDirectories) run on a `qos: .userInitiated` DispatchQueue labeled "dev.vmg.fff-swift", with a generation counter to enable cancellation of stale requests. `FFFIndex.swift:101-185,187-242,244-301; FFFIndex.swift:7` `K3` `K951`

### Three-stage search pipeline (overview and timing)

- SourceSearchEngine.execute runs a three-stage async pipeline per query: immediate apps/settings (~0ms) → 15-20ms sleep → indexed files/apps via FFI → 30ms sleep → content (grep) search. `SourceSearchEngine.swift:120-163,238-348` `K266` `K313`
- SourceSearchEngine.execute emits exactly 3 snapshots per execution — immediate, indexed, and content — at lines ~252, ~307-310, and ~335-338; an earlier claim of 4 snapshots is wrong. `SourceSearchEngine.swift:252,307-310,335-338` `K1420` `K1555` `K1258` `K636` `K1307`
- The 15-20ms sleep occurs before the indexed stage — after the synchronous immediate-page calls and before `ensureStarted()`/the second catalog scan. `SourceSearchEngine.swift:266-268; :267; :321` `K1200` `K1408` `K1518` `K1464` `K3117`
- A further 30ms sleep occurs before the content stage (before calling searchContent/contentItems, at line ~308-321); finishActiveExecution runs after this sleep. `SourceSearchEngine.swift:308,321,1494→542` `K1186` `K1409` `K1494` `K2745`
- Content search's `searchContent` declares a `timeBudgetMilliseconds` parameter defaulting to 35ms, used for the fff_live_grep call. `SourceSearchEngine.swift:341-343` `K1085` `K2746`
- The immediate stage (apps+settings) is computed synchronously in-actor and published before `ensureStarted()` is awaited, so typed queries return app/setting results while file scans continue in the background — synthetic app/setting rows appear before file rows. `SourceSearchEngine.swift:238-264,270` `K1601` `K1615` `K1621` `K1428` `K1511`
- SourceSearchEngine.search spawns a second Task (lines 157-160) that runs `execute()`. `SourceSearchEngine.swift:157-160` `K1427`

### Immediate stage (apps + settings)

- immediatePage calls applications.immediatePage and settings.immediatePage synchronously, returning 0-cost instant results. `SourceSearchEngine.swift:244-245,286-287` `K317`
- applications.immediatePage and settings.immediatePage are each called exactly twice per execute — at lines 244-245 and again, redundantly, at 286-287 — not "two to four times" as earlier claimed. `SourceSearchEngine.swift:244-245,286-287` `K569` `K570` `K1196` `K1334` `K1396` `K1517` `K1269`
- The second immediatePage pair (286-287) re-executes work identical to the first pair (244-245), for both applications and settings. `SourceSearchEngine.swift:244-245,286-287` `K1330`
- immediatePage requests limit=12 for applications and limit=24 for settings. `SourceSearchEngine.swift:244-245` `K323` `K573` `K574` `K1249`
- applications.immediatePage scores a ~1500-entry application array; settings.immediatePage scores a ~40-entry settings array. `SourceSearchEngine.swift:244-245` `K571` `K572`
- Each execute performs exactly 5 FuzzyMatcher.normalized calls and 4 characterMask recomputations — not "4-6 of each" as earlier claimed. `SourceSearchEngine.swift:244,245,286,287,291` `K1277`
- ApplicationCatalog.immediatePage takes a state lock to snapshot the application array, then an OSAllocatedUnfairLock per application to check blocklistStore.isBlocked. `ApplicationCatalog.swift:176-184` `K701`
- blocklistStore.isBlocked is called once per application per immediatePage call, and also inside indexedItems and projectLocal. `ApplicationCatalog.swift:183-184,142; SearchCoordinator.swift:593` `K702`

### Indexed stage (files + apps via FFI)

- FFFIndex.indexedItems / files.indexedItems is called with limit=12 and no minimum-query-length requirement. `SourceSearchEngine.swift:290` `K915` `K1141` `K2742`
- FFFIndex.search's production caller passes limit 12; the API's default of 60 is unused. `SourceSearchEngine.swift:290` `K1347`
- ApplicationCatalog.indexedItems calls index.searchFiles with limit 24 (= max(limit*2, limit), limit=12); its compactMap epilogue processes at most 24 results. `ApplicationCatalog.swift:133-161` `K1515` `K1516`
- ApplicationCatalog.indexedItems normalizes the query independently, in its own pass at lines 128-132, rather than reusing the immediate-stage normalization. `ApplicationCatalog.swift:128-132` `K599`
- ApplicationCatalog.indexedItems applies `Self.score` without the characterMask guard used elsewhere, so it can, in principle, surface a substitution-typo match from FFF — not "never", as earlier claimed. `ApplicationCatalog.swift:125-164` `K1226` `K1240`
- SystemCatalog has no indexed pass; it inherits the default indexedItems implementation. `Catalog.swift:34` `K1228`
- ApplicationCatalog.indexedItems's non-suspending segments are query trimming and FuzzyMatcher setup before the FFI call, then compactMap scoring after the FFI call constructs up to 24 SearchItems. `ApplicationCatalog.swift:125-142` `K705` `K1757`
- FFFIndex.indexedItems routes through index.search (the fff_search_mixed path); ApplicationCatalog.indexedItems routes through index.searchFiles. `FFFIndex.swift:628-630; ApplicationCatalog.swift:133` `K3205` `K3207`
- FFFIndex.swift:126 calls fff_search_mixed unconditionally with no minimum-query-length guard; only the content stage has a length gate (>=3 bytes). `FFFIndex.swift:126; SourceSearchEngine.swift:290,306` `K2771`

### Content stage (grep) and its eligibility gate

- contentEligible = `query.utf8.count >= 3 && indexedFiles.value.count < 12` gates the content/grep stage; this tests the returned file-page count against the 12-item limit, not the total indexed or matched file count — correcting a claim that it compared against "fewer than 12 indexed files" overall. `SourceSearchEngine.swift:305-320` `K315` `K916` `K1185` `K1308` `K1410` `K1531` `K2602` `K2696` `K1446`
- This gate can fire unnecessarily when `.app` filtering reduces the returned file count below 12, even though the underlying number of matches is larger. `SourceSearchEngine.swift:306; FFFIndex.swift:151` `K1194`
- Once contentEligible is true, execute proceeds unconditionally to content-grep, with no separate gate on bigram-index completion. `SourceSearchEngine.swift:280-324` `K3247`
- The content stage runs after the indexed snapshot has been published and after the 30ms sleep — off the critical keystroke path. `SourceSearchEngine.swift:308-323` `K2745`
- SourceSearchEngine fires contentItems (fff_live_grep) with a 35ms time budget once the file source is ready. `SearchCoordinator.swift contentItems publisher` `K1085`

### Snapshot publishing, merge/dedup, and SearchCoordinator projection

- SourceSearchEngine.search()/execute() operate on a trimmed query (lines 125/159), while trackSelection forwards the untrimmed query (lines 232-234), creating a QueryTracker key mismatch. `SourceSearchEngine.swift:125,159,232-234` `K1182` `K2652` `K1276`
- SourceSearchEngine's AsyncStream (allocated at search() lines 144-147) uses a `.bufferingNewest(1)` policy at line 145, coalescing multiple published snapshots into the latest one. `SourceSearchEngine.swift:144-147` `K1309` `K1426`
- SearchCoordinator performs one synchronous "stale-while-revalidate" projection in scheduleSearch (around line 527) before starting the debounced search Task, plus one projection per snapshot streamed from SourceSearchEngine.execute — up to 4 projectLocal calls per keystroke in total. `SearchCoordinator.swift:527,540-545,555-556; SourceSearchEngine.swift:252,305` `K1219` `K1296` `K1382` `K1424` `K675` `K635` `K653`
- Because query.didSet has no debounce, the stale-while-revalidate projection path runs on every keystroke. `SearchCoordinator.swift:8-14` `K1310`
- SearchResultProjection is a non-isolated enum; `SearchResultProjection.project` is a nonisolated static pure function called directly by tests, so projection/budget tests need no MainActor hop. `SearchResultProjection.swift:121-126` `K1384` `K2031`
- SourceSearchEngine.merge is called 3 times per keystroke, rebuilding its dedup Set<SearchItem.ID> each time; it already deduplicates context.candidates at line 459. `SourceSearchEngine.swift:456,459` `K594` `K616`
- Dedup uses id = "kind:" + full path (~40-80 bytes); merge preserves insertion order with no sorting applied. `SourceSearchEngine.swift:453-468,456-462` `K316` `K331` `K595`
- The candidate set is bounded to roughly 40-80 items after merge/dedup; the engine's own per-source caps sum to ~60 items (12 apps + 24 settings + 12 files + 12 indexed apps). `SourceSearchEngine.swift:244-245,286-293` `K1301` `K1329`
- SourceSearchEngine.totals allocates a fresh [SearchItemKind:Int] dictionary per snapshot; three call sites each additionally pass an `overrides` literal, allocating a second dictionary. `SourceSearchEngine.swift:470-481,300-305,328-334` `K613` `K614`
- totalMatches is computed only for the application and systemSetting stages, not for files or folders. `SourceSearchEngine.swift:311-314` `K1192`
- SearchSnapshot.isSettled is true only when pendingKinds.isEmpty; pendingKinds is what lets the shell distinguish an invalidated snapshot from a settled-but-empty one, correcting a claim that no such distinction existed. `SourceSearchEngine.swift:20; SearchCoordinator.swift:562` `K1519` `K1472`
- SearchCoordinator.publish unconditionally overwrites publication.sourceCandidates with snapshot.candidates, including for the empty/invalidation snapshot. `SearchCoordinator.swift:552-567` `K1471` `K1501` `K1521`
- SourceSearchEngine writes `isDegraded` at lines 261, 316, 344, and 520, but it is read only by tests — no file under Sources/ consumes it. `SourceSearchEngine.swift:261,316,344,520` `K2726`
- SearchCoordinator.selectFilter (lines 354-370) re-projects the existing snapshot without re-querying the engine — switching filters never requests a larger result limit. `SearchCoordinator.swift:354-370` `K2744`

### SearchItem construction and selection tracking

- trackSelection routes selections to files.track, applications.track, or settings.track based on provenance. `SourceSearchEngine.swift:224-236` `K324`
- selectionProvenance is cached across 2 queries using a 2-query LRU. `SourceSearchEngine.swift:484-497` `K325`
- The tracking path (SourceSearchEngine.swift:232-234 → FFFIndex.swift:671 → FFFIndex.track:433-449) issues fff_track_query only on selection, with no per-keystroke cost. `SourceSearchEngine.swift:232-234; FFFIndex.swift:433-449` `K2595`
- FFFIndex.track (lines 435-439) early-returns unless selectedURL.path.hasPrefix(rootURL.path); selections outside the indexed root never enter history. `FFFIndex.swift:435-439` `K2738`

### Startup, warm-up, and cold-start readiness

- SourceSearchEngine's readiness signals are filesReady, applicationsReady, settingsReady (lines 74-76). `SourceSearchEngine.swift:74-76` `K1333`
- ensureStarted() fans out async let startFiles()/startApplications()/startSettings() and awaits all three as one tuple, so the slowest of the three scans gates the indexed-stage publish for all sources. `SourceSearchEngine.swift:377-388` `K1465` `K1525` `K1609` `K1623` `K2882` `K2933`
- The three startups are coalesced onto a single `startup.task` on the actor; startFiles awaits `startup.task.value` with no cancellation handler. `SourceSearchEngine.swift:390-420,431` `K1466` `K1526`
- ApplicationCatalog.start() polls up to 200 iterations of a 10ms sleep, exiting on the first isScanning==false with no idle debounce, concurrently with startFiles. `ApplicationCatalog.swift:107-124` `K1156` `K1473`
- SourceSearchEngine.execute awaits ensureStarted() before publishing the indexed snapshot, which blocks on FFFFileSource.waitForScanCompletion; at launch, SearchCoordinator.warmUp's call to startFiles blocks on full scan completion before returning. `SourceSearchEngine.swift:99-101,270; FFFIndex.swift:622-634; SearchCoordinator.swift:225` `K857` `K858`
- waitForScanCompletion (FFFIndex.swift:677-688) polls scan progress every 10ms and sets filesReady, but does not itself wait for the bigram content index to finish building; FFFIndex.swift:623-625 has start() await waitForScanCompletion() twice. `FFFIndex.swift:677-688,623-625` `K2606` `K3085`
- During the initial full home-directory walk, the second/third publish stages don't run yet — but the panel is not blank or spinning forever: apps and settings appear immediately from the pre-ensureStarted publish; what's actually missing during cold start is isSettled, refresh, and indexedItems. `SourceSearchEngine.swift:245-262,270; ApplicationCatalog.swift:107-124` `K859` `K1569`
- SourceSearchEngine.execute initializes pendingKinds as [.application, .file, .folder] (line 250-253) — application and folder, not just file, remain pending during the initial scan. `SourceSearchEngine.swift:250-253` `K1510` `K2883`
- SourceSearchEngine publishes pendingKinds:[.file] before calling searchContent (line 315), so a warmup-time empty content result shows a pending-file affordance that resolves to nothing unless pendingKinds is also cleared. `SourceSearchEngine.swift:315` `K2612`
- SourceSearchEngine.warmUp is invoked exactly once (from SearchCoordinator.swift:225), restarts synchronously, and issues/returns within one frame — before any rebuild flash, contrary to a claim that the warmUp flash was comparable in severity to the rebuild flash. `SourceSearchEngine.swift:99-118; SearchCoordinator.swift:225` `K1469` `K1512`
- warmUp() fires at applicationDidFinishLaunching (AppDelegate.swift:79), so the initial home-directory walk overlaps app launch rather than a keystroke. `AppDelegate.swift:79` `K2909`
- changeScope and rebuild defer restart until the index mutation completes, leaving the result list empty for the entire rebuild duration; SourceSearchEngine.restart re-runs execute, whose first act publishes the immediate page again (lines 525-535). `SourceSearchEngine.swift:172-196,198,525-535` `K1470` `K1437`
- The only production call site for rebuild() is the manual AppDelegate.rebuildIndex menu action (Cmd-Shift-R). `AppDelegate.swift:70; SearchCoordinator.swift:468; SourceSearchEngine.swift:198` `K2669`
- invalidateActiveExecution yields a SearchSnapshot with an empty candidates array and an empty totalMatches dict (with four pendingKinds); it is called from warmUp on a readiness change, from changeScope, and from rebuild. `SourceSearchEngine.swift:512-522,115` `K844` `K845` `K1436` `K1520`
- isolatedRefresh returning `changed: false` fails to signal readiness changes. `SourceSearchEngine.swift:366` `K1331`
- The warmUp pattern (lines 100-113) checks readiness-before-change to skip redundant work. `SourceSearchEngine.swift:100-113` `K1332`
- SourceSearchEngine does not gate per-keystroke searches on startup completion; files.indexedItems/contentItems are called unconditionally, correcting a claim that a startup gate exists. `SourceSearchEngine.swift:290,324` `K3054`
- Startup and query execution are not competing high-priority peers — they are serialized on the SourceSearchEngine actor, with query awaiting the same coalesced startup task. `SourceSearchEngine.swift:270,377,50` `K1567`
- SearchCoordinator.start() declares sourceWarmUp and resolvedKeywordRegistry as concurrent async let (lines 225-240) but awaits sourceWarmUp (line 228) before applying the registry result (line 236); it also creates a startupTask and gates on startupTask==nil for idempotence. `SearchCoordinator.swift:218,225-240` `K362` `K1608` `K1552`
- Two separate FFF/FFFIndex instances exist — the main file index and ApplicationCatalog's marker index — and both cold-start concurrently, sharing the process-global BACKGROUND_THREAD_POOL; both are created with watch=true, so the file-watch callback dispatcher thread is live in production. `SourceSearchEngine.swift:377-383; ApplicationCatalog.swift:31` `K3045` `K3234` `K3099`
- Every launch performs a full home-directory walk because enable_mmap_cache is a post-scan warmup, not a persisted index. `file_picker.rs:922-995,534-535` `K3067`

### Cancellation and generation tokens

- FFFIndex.search reserves a search generation number, guarded by NSLock, so stale requests can be dropped without blocking the C FFI calls. `FFFIndex.swift:303-308,101-109` `K7` `K110` `K269`
- The generation guard is checked inside the dispatched closure after dequeue, so a stale, still-queued query throws CancellationError before ever reaching fff_search_mixed; the truly uncancellable window is just one already-in-flight FFI call — correcting a claim that perceived latency was the sum of all stale queries. `FFFIndex.swift:101-109` `K2880`
- FFFIndex.perform is a bare withCheckedThrowingContinuation wrapping queue.async, with no withTaskCancellationHandler — it does not bridge Task cancellation to the dispatch queue, so scheduled work runs to completion even after the calling Task is cancelled. `FFFIndex.swift:451-463` `K671` `K1405` `K1502`
- Consequently, cancelling via invalidateActiveExecution or cancel(token) cannot stop a C call already dispatched; the next keystroke's fff_search_mixed waits behind the in-flight grep on the same serial queue. `SourceSearchEngine.swift:350-361,508-514; FFFIndex.swift:451-463` `K2589`
- SourceSearchEngine.search returns its stream early via `guard !Task.isCancelled` (line 118) if the caller's Task is already cancelled, and may separately await `sourceMutation.task.value` (lines 129-131) for an in-flight scope change; lines 130 and 242 both await it before file-source operations, so a scope change in flight adds no extra delay to waitForScanCompletion's own polling. `SourceSearchEngine.swift:118,129-135,130,242` `K1503` `K1429` `K2618`
- finishActiveExecution cancels the execution Task via `execution?.task?.cancel()`; execute maps CancellationError to an empty, non-degraded result. `SourceSearchEngine.swift:543,354-356` `K1411` `K1412`
- The no-arg `cancel()` (line 166) is dead code (marked periphery:ignore) with no call site, but `cancel(token:)` is a live path invoked from the AsyncStream continuation's onTermination; SearchCoordinator.reset cancels searchTask directly, which triggers that onTermination and thus cancel(token) — correcting the impression that no cancellation call site existed for SourceSearchEngine.cancel at all. `SourceSearchEngine.swift:154-156,166,508; SearchCoordinator.swift:252-260,541-549` `K696` `K1474` `K1475` `K695`
- SearchCoordinator's query.didSet unconditionally calls assistantRunSession.cancel() every keystroke; AssistantRunSession.cancel() unconditionally sets run=nil, firing an observation update even when run was already nil. `SearchCoordinator.swift:8-14; AssistantRunSession.swift:95-100` `K1736` `K1737`

### FFI/engine configuration and progress reporting

- The file-index FFFIndex is constructed with enableHomeDirectoryScanning:true at FFFIndex.swift:701-707, inside `package extension SourceSearchEngine` — not at SourceSearchEngine.swift:701-707 as earlier claimed. `FFFIndex.swift:701-707` `K338` `K2580`
- The file index enables content indexing, the file watcher, and home-directory scanning; ApplicationCatalog's marker index disables content indexing and the watcher. `SourceSearchEngine.swift:701-707; ApplicationCatalog.swift:65-73` `K853`
- FFFIndex.swift:83-85 passes all three cache-budget knobs (enable_mmap_cache, max_files, warmup_mmaps) as 0/None — disabled. `FFFIndex.swift:83-85; types.rs:975-995` `K3087`
- include_binary_files=true at FFFIndex.swift:87; since file binary-sniffing (scan.rs:337-345) hasn't run yet during warmup, the warmup-time prefilter can admit unsniffed binary files. `FFFIndex.swift:87; scan.rs:337-345` `K2613`
- Floodlight never calls fff_get_historical_query and bails on an empty query without reading LMDB history. `FFFIndex.swift:433; SourceSearchEngine.swift:142` `K1170`
- No pagination cursor or file_offset state is threaded between successive keystrokes in SourceSearchEngine or FFFFileSource.contentItems(for:). `SourceSearchEngine.swift; FFFIndex.swift` `K3279`
- FFFIndex.rescan calls fff_scan_files, which re-walks and commits a new snapshot into the existing picker without losing the watcher. `FFFIndex.swift:408-415` `K1155`
- FffScanProgress (fff.h:305-310, populated in ffi_types.rs:779) has 4 fields, but Swift's FFFIndexProgress/progress() only reads and keeps 3 (scannedFiles, isScanning, isWatcherReady), dropping is_warmup_complete. `FFFModels.swift:70-80; fff.h:305-310; ffi_types.rs:779; FFFIndex.swift:333-337` `K904` `K1082` `K1133` `K2604` `K3055`

### Instrumentation (signposts) and analysis-tool coverage gaps

- FloodlightPerformance.begin has exactly 9 production call sites, across ApplicationCatalog.swift(92,109), FloodlightPanel.swift(197,207), SelectedResultActionPerformer.swift(83,209), SourceSearchEngine.swift(239,289,323), and SearchCoordinator.swift(221). `listed line numbers above` `K1631`
- The IndexStartup signpost wraps the entire async warm-up task launched from SearchCoordinator.start(). `SearchCoordinator.swift:221-223` `K1633`
- SourceSearch (line 239), IndexedSourceSearch (lines 289-296), and ContentSourceSearch (lines 323-325) signposts already bracket the per-keystroke query path, the indexed FFI calls, and the content/grep call respectively, all after the debounce sleeps — correcting claims that no instrumentation existed on the query path, that only offline timing existed, and that nothing measured fff_search_mixed/fff_live_grep timing. `SourceSearchEngine.swift:239,289,296,323,325` `K1533` `K3202` `K3203` `K3204` `K1563`
- IndexedSourceSearch wraps both FFFIndex.indexedItems (fff_search_mixed, via index.search) and ApplicationCatalog.indexedItems (via index.searchFiles). `FFFIndex.swift:628-630; ApplicationCatalog.swift:133` `K3205` `K3207`
- The ast-grep rule tools/ast-grep/rules/query-path-no-sync-disk-read.yml is scoped only to Sources/FloodlightEngine/** and only matches immediatePage|indexedItems — it misses PathNavigator.swift's main-thread sync disk read (lines 154-161) and misses SearchResultProjection in the shell layer. `tools/ast-grep/rules/query-path-no-sync-disk-read.yml; PathNavigator.swift:154-161` `K679` `K1777` `K2035`

### Adjacent concurrency and cache mechanisms elsewhere in the app

- AssistantProcessRunner enforces a 45-second timeout with SIGTERM/SIGKILL escalation on CLI execution, and its `run` method inherits main-actor isolation from the caller's `Task{@MainActor}` because Package.swift's NonisolatedNonsendingByDefault is enabled. `AssistantProcessRunner.swift:17; AssistantRunSession.swift:64` `K94` `K1447`
- FileIconCache is an @MainActor singleton with a 256-item NSCache limit and a concurrent nonisolated async loader; AppIconCache, by contrast, is cache-only with no async loading path. `FileIconCache.swift:14-37; AppIconCache.swift:14-29` `K98` `K1711`
- The icon cache-miss handling is correctly implemented at ResultRow.swift:218-231 (fileIcon set to nil at line 226, guarded by `!Task.isCancelled` at line 228) — correcting a wrong line-range citation of 221-230. `ResultRow.swift:218-231,226,228` `K1798`
- panelCommand maps the "." character to togglePin, which conflicts with the macOS convention of "." as cancel. `FloodlightPanel.swift:368` `K556`
- FloodlightTextField.fieldCommand's switch (lines 37-57) only maps insertNewline, insertNewlineIgnoringFieldEditor, cancelOperation, insertTab, insertBacktab, and deleteBackward — no cursor-movement cases. `FloodlightTextField.swift:37-57` `K2226`
- Under Swift 6 complete concurrency, a static DateFormatter needs `nonisolated(unsafe)`, not a plain `static let`, because DateFormatter isn't Sendable. `Package.swift:6.4; RecentStore.swift:10` `K1731`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Immediate-stage sleep before indexed stage | 15-20 ms | `SourceSearchEngine.swift:266-268,267,321` |
| Sleep before content stage | 30 ms | `SourceSearchEngine.swift:308,321` |
| Content search time budget (searchContent default) | 35 ms | `SourceSearchEngine.swift:341-343` |
| Content-eligibility query length gate | >= 3 UTF-8 bytes | `SourceSearchEngine.swift:306` |
| Content-eligibility file-count gate | < 12 (returned file page) | `SourceSearchEngine.swift:306` |
| applications.immediatePage limit | 12 | `SourceSearchEngine.swift:244-245` |
| settings.immediatePage limit | 24 | `SourceSearchEngine.swift:244-245` |
| Approx. application catalog size scored | ~1500 entries | `SourceSearchEngine.swift:244` |
| Approx. settings catalog size scored | ~40 entries | `SourceSearchEngine.swift:245` |
| Files/indexedItems limit | 12 | `SourceSearchEngine.swift:290` |
| ApplicationCatalog.indexedItems searchFiles limit | 24 (= max(limit*2, limit), limit=12) | `ApplicationCatalog.swift:133-136` |
| immediatePage/indexedItems calls per execute (apps, settings) | exactly 2 each | `SourceSearchEngine.swift:244-245,286-287` |
| FuzzyMatcher.normalized calls per execute | exactly 5 | `SourceSearchEngine.swift:244,245,286,287,291` |
| characterMask recomputations per execute | 4 | `SourceSearchEngine.swift:244,245,286,287,291` |
| Snapshots emitted per execute | 3 (immediate, indexed, content) | `SourceSearchEngine.swift:252,307-310,335-338` |
| projectLocal calls per keystroke (SearchCoordinator) | up to 4 | `SearchCoordinator.swift:527,555-556` |
| Candidate set size after merge | ~40-80 items (engine caps sum to ~60) | `SourceSearchEngine.swift:244-245,286-293` |
| SearchItem.ID size | ~40-80 bytes ("kind:"+path) | `SourceSearchEngine.swift:456-462` |
| selectionProvenance LRU size | 2 queries | `SourceSearchEngine.swift:484-497` |
| ApplicationCatalog.start() poll loop | 200 iterations x 10 ms sleep (up to ~2s) | `ApplicationCatalog.swift:107-124` |
| waitForScanCompletion poll interval | 10 ms | `FFFIndex.swift:677-688` |
| AsyncStream buffering policy | .bufferingNewest(1) | `SourceSearchEngine.swift:145` |
| FloodlightPerformance.begin production call sites | 9 | `ApplicationCatalog.swift:92,109; FloodlightPanel.swift:197,207; SelectedResultActionPerformer.swift:83,209; SourceSearchEngine.swift:239,289,323; SearchCoordinator.swift:221` |
| AssistantProcessRunner CLI timeout | 45 s (SIGTERM then SIGKILL) | `AssistantProcessRunner explorer-summary` |
| FileIconCache NSCache limit | 256 items | `FileIconCache.swift:18-29` |
| FffScanProgress fields vs. Swift-side fields kept | 4 fields in Rust/C, 3 kept in Swift (is_warmup_complete dropped) | `fff.h:305-310; FFFModels.swift:70-73` |
| Number of FFF/FFFIndex instances at cold start | 2 (main file index + ApplicationCatalog marker index) | `SourceSearchEngine.swift:377-383; ApplicationCatalog.swift:31` |

### Gotchas

- applications.immediatePage and settings.immediatePage are each called twice per keystroke — the second pair (lines 286-287) redundantly repeats the identical work already done at lines 244-245. `SourceSearchEngine.swift:244-245,286-287`
- The content-search eligibility gate (query.utf8.count>=3 && indexedFiles.value.count<12) can fire unnecessarily when `.app` filtering shrinks the returned file page below 12, even though the underlying match count is much larger. `SourceSearchEngine.swift:306; FFFIndex.swift:151`
- FFFIndexProgress silently drops the is_warmup_complete field that the Rust/C layer already populates, so Swift can't distinguish "warmup done" from the 3 fields it does keep. `FFFModels.swift:70-80; fff.h:305-310`
- FFFIndex.perform has no cancellation handler: once a query is dispatched to the C FFI queue, cancelling the Swift Task does not stop it — it runs to completion, and the next keystroke's query queues behind it on the same serial queue. `FFFIndex.swift:451-463`
- The generation guard for cancellation is only checked after a query is dequeued, so exactly one in-flight FFI call is always uncancellable, however many keystrokes arrive after it. `FFFIndex.swift:101-109`
- SourceSearchEngine's no-arg cancel() is dead code; the real cancellation path is cancel(token:), reached only indirectly through the AsyncStream's onTermination callback when SearchCoordinator.reset cancels searchTask. `SourceSearchEngine.swift:154-156,166,508`
- The ast-grep rule meant to catch synchronous disk reads on the query path is scoped only to Sources/FloodlightEngine's immediatePage/indexedItems, so it misses PathNavigator's main-thread sync read and SearchResultProjection in the shell. `tools/ast-grep/rules/query-path-no-sync-disk-read.yml; PathNavigator.swift:154-161`
- isolatedRefresh returning changed:false silently fails to signal a readiness change, so downstream restart logic that depends on the change flag can miss it. `SourceSearchEngine.swift:366`
- ApplicationCatalog.indexedItems scores without the characterMask guard used elsewhere, so it can surface a substitution-typo match that other code paths would reject. `ApplicationCatalog.swift:125-164`
- Two separate FFF instances (main file index and ApplicationCatalog's marker index) cold-start concurrently, sharing one process-global thread pool. `SourceSearchEngine.swift:377-383; ApplicationCatalog.swift:31`
- Every app launch does a full home-directory walk; there is no persisted index between launches because enable_mmap_cache is only a post-scan warmup, not persistence. `file_picker.rs:922-995,534-535`
- isDegraded is written by SourceSearchEngine at four call sites but consumed only by tests — no production code path reads it. `SourceSearchEngine.swift:261,316,344,520`
- search() trims the query but trackSelection forwards the untrimmed query, so the same logical search can produce two different QueryTracker keys. `SourceSearchEngine.swift:125,159,232-234`

### Corrected on review

- ~~ApplicationCatalog.indexedItems will never return a substitution-typo match for an application.~~ → It can, in principle, surface a substitution-typo match returned by FFF, since indexedItems scores without the characterMask guard used elsewhere. `ApplicationCatalog.swift:125-164`
- ~~applications.immediatePage is called two to four times per keystroke.~~ → SourceSearchEngine.execute invokes ApplicationCatalog.immediatePage exactly twice per execution, at lines 244 and 286. `SourceSearchEngine.swift:244,286`
- ~~FuzzyMatcher.normalized and characterMask each run 4-6 times per execute.~~ → Each execute performs exactly 5 FuzzyMatcher.normalized calls and 4 characterMask recomputations. `SourceSearchEngine.swift:244,245,286,287,291`
- ~~SourceSearchEngine's query normalization runs on the main thread.~~ → SourceSearchEngine is a package actor, so normalization runs off the main thread, at SourceSearchEngine.swift:50. `SourceSearchEngine.swift:50`
- ~~SourceSearchEngine.execute publishes 4 projections/snapshots per keystroke.~~ → It publishes 3 snapshots — immediate, indexed, content — at lines 252, 308, and 335. `SourceSearchEngine.swift:252,308,335`
- ~~settings.immediatePage is called 4 times per setting search.~~ → It is called exactly twice per execution (lines 245, 287); four times only if execute itself is resumed/re-run. `SourceSearchEngine.swift:245,287,532`
- ~~contentEligible tests the query against fewer than 12 total indexed files.~~ → It tests the returned file-page count at the 12-item limit, not the total indexed or matched file count. `SourceSearchEngine.swift:306`
- ~~The shell has no way to distinguish "no results" from "invalidated" in a SearchSnapshot.~~ → SearchSnapshot carries pendingKinds, and isSettled (true only when pendingKinds.isEmpty) lets the shell distinguish invalidation from a settled-but-empty result. `SourceSearchEngine.swift:20; SearchCoordinator.swift:562`
- ~~SourceSearchEngine.cancel has no call site.~~ → The no-arg cancel() (line 166) is dead code, but cancel(token:) is a live path invoked from the AsyncStream continuation's onTermination, reached when SearchCoordinator.reset cancels searchTask. `SourceSearchEngine.swift:154-156,166,508; SearchCoordinator.swift:252-260,541-549`
- ~~Clipboard-mode search gets the same debounce treatment as local mode.~~ → SearchCoordinator.scheduleSearch starts searchTask immediately with no debounce; only local mode stages work after a Task.sleep. `SearchCoordinator.swift:495-548`
- ~~warmUp's UI flash is comparable in severity to the rebuild flash.~~ → warmUp issues and returns within one frame, before any rebuild flash occurs. `SearchCoordinator.swift:225; SourceSearchEngine.swift:99-118`
- ~~No instrumentation exists for the debounce/content phases; the query path is untimed and only offline search timing exists.~~ → SourceSearch, IndexedSourceSearch, and ContentSourceSearch signposts already bracket the query path, the indexed FFI calls, and the content/grep call, all after the debounce sleeps. `SourceSearchEngine.swift:239,289,296,323,325`
- ~~Startup and query execution are competing high-priority peers on SourceSearchEngine.~~ → They are serialized on the actor: query execution awaits the same coalesced startup task. `SourceSearchEngine.swift:270,377,50`
- ~~During cold start the panel shows nothing, or a spinner forever.~~ → Every keystroke's pre-ensureStarted publish shows apps/settings results immediately; what is actually missing during cold start is isSettled, refresh, and indexedItems. `SourceSearchEngine.swift:245-262; ApplicationCatalog.swift:107-124`
- ~~A plain `static let` DateFormatter compiles cleanly under Swift 6 complete concurrency.~~ → It requires `nonisolated(unsafe)` because DateFormatter is not Sendable. `RecentStore.swift:10`
- ~~The icon cache-miss comparison logic is at ResultRow.swift:221-230.~~ → The correct cache-miss handling is at ResultRow.swift:218-231 (fileIcon nil at line 226, guard !Task.isCancelled at line 228). `ResultRow.swift:218-231,226,228`
- ~~The file-index FFFIndex is constructed at SourceSearchEngine.swift:701-707.~~ → It is constructed at FFFIndex.swift:701-707, inside `package extension SourceSearchEngine`. `FFFIndex.swift:701-707`
- ~~Perceived latency from cancelled stale queries is the sum of the durations of all the stale queries.~~ → The generation guard runs after dequeue, so queued-but-not-yet-dispatched stale queries throw CancellationError immediately; only one already-in-flight FFI call is ever truly uncancellable. `FFFIndex.swift:101-109`
- ~~Only the .file pending kind remains pending during the initial home-directory scan.~~ → initialPending = [.application, .file, .folder] — application and folder also remain pending, not just file. `SourceSearchEngine.swift:251-253`
- ~~A startup gate prevents per-keystroke searches from running until startup completes.~~ → SourceSearchEngine does not gate per-keystroke searches on startup completion; files.indexedItems/contentItems are called unconditionally. `SourceSearchEngine.swift:290,324`
- ~~Precomputing results formats the same items as the render path.~~ → FFFFileSource.indexedItems returns a limit of 12 items per query. `SourceSearchEngine.swift:290`

<a id="swift-catalogs-ranking"></a>
## Floodlight: catalogs, fuzzy matcher, ranking, blocklist, recents

Floodlight's search stack layers Swift catalogs (ApplicationCatalog for apps, SystemCatalog for macOS settings panes) on top of two independent FFF index instances, a fuzzy matcher, a recency-boost store (RecentStore), a per-user blocklist (BlocklistStore), a built-in calculator, and a path navigator, all wired together by SearchCoordinator and SearchResultProjection. On startup, SearchCoordinator spins a MainActor Task that probes local assistant CLIs (codex, claude) serially to build the keyword-engine registry, while ApplicationCatalog and SystemCatalog each walk the filesystem on their own background queues to populate candidate sets — ApplicationCatalog polls its own FFF marker index with a bounded 2-second loop instead of using the shared wait helper. Per keystroke, each catalog's immediatePage method does a pure in-memory linear scan using a cheap per-byte character-mask prefilter before invoking FuzzyMatcher, while SearchResultProjection.buildLocalRows separately tries the calculator, the keyword-address parser, and PathNavigator — each of which gates on a cheap string check and returns nil immediately unless the query looks like its domain, despite being called several times per keystroke. Results are deduplicated and sorted with a locale-aware (ICU) comparator by SearchItemRanking before display. Two FFF index instances run side by side: the main file-search index and a separate, content-indexing-disabled marker index that ApplicationCatalog uses purely to track installed applications and whose computed scores it discards, rescoring everything itself in Swift. Locking is narrow and coarse-grained throughout (single locks held across whole per-keystroke loops, not per item), and a large share of this batch's facts are corrections of earlier claims about line numbers, lock granularity, per-keystroke call counts, and matching semantics — those are called out explicitly below.

### Search call flow: startup and per-keystroke pipeline

- SearchCoordinator calls AssistantProcessRunner.isAvailable() for each CLI at startup to populate the keyword row registry. `SearchCoordinatorWebModeTests.swift:23-39` `Assistant Process Execution cluster`
- SearchCoordinator.start creates a Task inheriting MainActor isolation (lines 217-227) and uses async let for resolvedKeywordRegistry, pinning KeywordEngineCatalog.availableRegistry and AssistantProcessRunner.isAvailable to the main actor. `SearchCoordinator.swift:217-227,219` `F16` `F39` `F38`
- KeywordEngineCatalog.availableRegistry/availableEngines loops over all assistant-CLI engines sequentially, awaiting runner.isAvailable() for each one in turn with no memoization; AssistantProcessRunner.isAvailable probes codex first, then claude. `KeywordEngine.swift:418-477` `F` `F16` `F38` `F53` `F58:value`
- Availability detection literally shells out: KeywordEngine.swift:427 and :436 run `codex exec` and `claude -p` respectively to test assistant CLI availability. `KeywordEngine.swift:427,436` `F149`
- KeywordEngineCatalog.initialRegistry is published synchronously in SearchCoordinator.init (SearchCoordinator.swift:136), filtered to .webSearch engines only, and contains every web engine unconditionally from the start. `SearchCoordinator.swift:136; KeywordEngine.swift:437-446` `F53:value` `F58:accuracy`
- Only the "Ask Claude" and "Ask Codex" assistant rows are delayed by keyword-registry resolution; web-mode search rows are available from t=0. `SearchCoordinator.swift:136; KeywordEngine.swift:421-438,441-447` `F58:accuracy` `F58:value`
- SearchCoordinator.projectLocal (lines 596-600) filters candidates through blocklistStore.isBlocked before calling project; this filter step runs up to four times per keystroke. `SearchCoordinator.swift:596-600` `F18` `F19`
- SearchResultProjection.projectLocal (lines 143-164) runs up to 4 times per keystroke on the main actor, performing the blocklist filter, Calculator, PathNavigator disk I/O, dedupe, and sort over up to 80 rows. `SearchResultProjection.swift:143-164` `F8`
- SearchResultProjection.buildLocalRows (lines 438-473) executes Calculator, the keyword registry, PathNavigator.resolve, Set-based dedupe, and topRankedInPlace in sequence. `SearchResultProjection.swift:438-473` `F19`
- buildLocalRows calls context.keywordRegistry.addressedResult(for:) at line 451. `SearchResultProjection.swift:451` `F140`
- buildLocalRows calls PathNavigator.resolve unconditionally at line 454 for each projected local result — up to four times per keystroke — even though PathNavigator.resolve takes a fileManager parameter that SearchResultProjection.LocalContext does not expose. `SearchResultProjection.swift:454` `F23` `F19` `F7-accuracy` `F37`
- Calculator.evaluate is invoked unconditionally from buildLocalRows at line 440. `SearchResultProjection.swift:440` `F33`
- addressedResult returns nil immediately on a keyword-lookup miss without reaching the host (KeywordEngine.swift:228) — the per-keystroke cost is not "4x addressedResult parsing a URL template." `KeywordEngine.swift:228` `F14`
- defaultWebResult always runs regardless of the other fast-exits, performing percent-encoding, URL string parsing, and a host lookup. `KeywordEngine.swift:248-253,84-90,113-115` `F14`
- SearchCoordinator.tabCompletionHint(for:) (lines 293-301) calls KeywordEngine.tabCompletionTitle per row; tabCompletionTitle (lines 303-348) runs parseAddress and typedKeyword.lowercased(), allocating fresh Strings for every row. `SearchCoordinator.swift:293-301; KeywordEngine.swift:303-348,306-312` `F24` `F81`
- KeywordEngine.addressedResult (lines 225-232) requires both a successfully parsed keyword and a non-empty remainder string before it returns a result. `KeywordEngine.swift:225-232` `F58:value`
- Row subtitles are built from different sources depending on result kind: SearchItem.swift:336 uses a relative path, SearchResultProjection.swift:354 an absolute path, ApplicationCatalog.swift:473 the app's directory, and FFFIndex.swift:637 a "path:line" string with a code snippet. `SearchItem.swift:336; SearchResultProjection.swift:354; ApplicationCatalog.swift:473; FFFIndex.swift:637` `F108`

### ApplicationCatalog: discovery, marker index, and startup polling

- ApplicationCatalog constructs a second, fully independent FFFIndex (own DispatchQueue) over a private marker directory (ApplicationIndex/Items) with enableContentIndexing:false, includeBinaryFiles:false, and watch:false, so app-catalog scans never block on the main file-index's grep operations; this marker index scans in milliseconds. `ApplicationCatalog.swift:63-73; FFFIndex.swift:6-7` `U3` `U23` `F27` `F57:value` `F171` `F`
- Of the two FFF instances, only the main file-search index builds a bigram content index; the marker-index FFFIndex does not, because ApplicationCatalog passes enableContentIndexing:false. `ApplicationCatalog.swift:68` `U51`
- Both the main file index and the marker index are created with cache_budget fields set to 0 and enable_mmap_cache true. `FFFIndex.swift:77-87` `F13`
- The marker-index FFFIndex offers no way to disable persistent ranking. `ApplicationCatalog.swift:65-73` `U11`
- ApplicationCatalog.discoverApplications (lines 333-382) does a shallow FileManager enumeration (.skipsPackageDescendants) over /Applications, /System/Applications, ~/Applications, /System/Library/CoreServices/Applications, Finder.app/Applications, and every URL from FileManager.urls(for:.applicationDirectory, in:.allDomainsMask). `ApplicationCatalog.swift:333-382` `F` `U3` `F1-accuracy`
- ApplicationCatalog.prepare() runs on a private serial discoveryQueue (label com.floodlight.application-catalog, qos .userInitiated) via enqueueDiscovery, not on the main thread. `ApplicationCatalog.swift:24-27,110-112,246-254` `F27` `F46`
- ApplicationCatalog.appendApplication calls fileManager.displayName(atPath:) (a LaunchServices lookup) and resolvingSymlinksInPath() (a realpath syscall) for every discovered application. `ApplicationCatalog.swift:421-433,428,430` `F` `F54:accuracy`
- Markers are stored as empty files or symlinks under the FFF index root, defaulting to ~/Library/Application Support/Floodlight/ApplicationIndex/Items when supportURL is nil. `ApplicationCatalog.swift:31,63-73,481-502` `F` `F55:value` `F18`
- ApplicationCatalog.State.isPrepared defaults to false per process (set true only after prepare completes), so ApplicationCatalog.synchronizeMarkers runs one contentsOfDirectory call over roughly 1,500 marker files plus one fileManager.fileExists(atPath:) per application (~3,000 syscalls) on every launch. `ApplicationCatalog.swift:20,265-271,287,496-502` `F3` `F55:accuracy` `F55:value`
- ApplicationCatalog.signature builds two separate 1,500-element string arrays purely to compare them for equality. `ApplicationCatalog.swift:268` `F3`
- SearchCoordinator.swift:173 and ApplicationCatalog.swift:51-52 each independently resolve applicationSupportDirectory (with create:true) on the main thread during construction — two redundant resolutions, not the three or four originally suspected. `SearchCoordinator.swift:173; ApplicationCatalog.swift:51-56` `F63`
- ApplicationCatalog.init takes an optional supportURL (default nil, line 39), but the default's defaultSupport value is computed unconditionally before the `supportURL ?? defaultSupport` fallback runs, so passing supportURL explicitly does not eliminate the redundant resolution. `ApplicationCatalog.swift:39,51-61` `F63`
- If supportURL resolution fails, ApplicationCatalog.swift:57-60 falls back to temporaryDirectory while SearchCoordinator.swift:168-172 falls back to a hardcoded path — the two can disagree about the index root. `ApplicationCatalog.swift:57-60; SearchCoordinator.swift:168-172` `F63`
- ApplicationCatalog is declared `package final class ApplicationCatalog` with mutable state properties. `ApplicationCatalog.swift:4` `U74` `U12`
- An ApplicationDiscovery signpost brackets the prepare(...) call to mark population of the application catalog. `ApplicationCatalog.swift:109-113` `F61`
- ApplicationCatalog wires the marker index's history LMDB path as supportURL.appendingPathComponent("history.lmdb").path (line 66), passed to FFFIndex as options.history_db_path; FFFIndex.start() unconditionally opens both frecency.lmdb and history.lmdb even though ApplicationCatalog discards all FFF-computed search scores and recomputes them itself in Swift. `ApplicationCatalog.swift:65-66,138-161; FFFIndex.swift:65-66,75-76` `U17` `U19`
- ApplicationCatalog.swift:71 and SearchCoordinator.swift:196 both override the FFF log path via the FLOODLIGHT_FFF_LOG environment variable — a caller does override log_file_path, contrary to an earlier claim. `ApplicationCatalog.swift:71; SearchCoordinator.swift:196` `U65`
- Floodlight runs exactly two FFF instances: the main file-search index and ApplicationCatalog's marker index. `FFFIndex.swift; ApplicationCatalog.swift` `U35`
- ApplicationCatalog.prepare() is called unconditionally from init unless deferDiscovery is true; production always constructs it with deferDiscovery: true (SearchCoordinator.swift:190-194), which skips prepare() and the immediate file-index scan. `ApplicationCatalog.swift:74-76,107-114,256-258; SearchCoordinator.swift:190-194` `F54:value` `F63`
- Estimates of the marker-file count disagree: one source cites ~200 app marker files, others cite ~1,500 — neither is marked as correcting the other. `explorer summary vs ApplicationCatalog.swift:268,496-501` `floodlight-usage cluster` `F3`

### ApplicationCatalog: startup polling and refresh gating

- ApplicationCatalog.start() (lines 107-123) calls prepare(), then polls index.progress() up to 200 times at 10ms intervals (a 2-second ceiling), breaking early if not isScanning; it implements its own polling loop rather than calling waitForScanCompletion the way FFFFileSource does. `ApplicationCatalog.swift:107-123,115-123` `U3` `F` `F45` `F54:value` `U46`
- ApplicationCatalog.start's 2-second poll cap is a hard bound; FFFFileSource.start's equivalent wait is unbounded — the two wait patterns are not equivalent. `ApplicationCatalog.swift:115-121` `U39`
- If the 200x10ms poll loop times out, ApplicationCatalog falls through silently — no error and no logging. `ApplicationCatalog.swift:116-124` `U19`
- ApplicationCatalog.prepare() populates state.applications before the poll loop runs at all, so the in-memory fuzzy pass over applications is available before the file scan finishes. `ApplicationCatalog.swift:110-112,116` `F57`
- The 200x10ms poll loop at ApplicationCatalog.swift:107-123 is described elsewhere as having only a single idle check, inconsistent with a double-idle-check variant used elsewhere. `ApplicationCatalog.swift:107-123` `U75`
- ApplicationCatalog.refreshIfNeeded (lines 93-104) guards the expensive rescan() call behind forceDiscovery || applicationDirectoriesChanged, and is the only production caller of FFFIndex.rescan; it calls index.rescan() and returns immediately without waiting for the scan to complete. `ApplicationCatalog.swift:93-104` `F144` `U18`
- ApplicationCatalog.refreshIfNeeded already offloads its filesystem work to discoveryQueue via withCheckedContinuation (lines 93-98,246-254), unlike SystemCatalog which runs its refresh work inline — an @concurrent decorator would only help SystemCatalog, not ApplicationCatalog. `ApplicationCatalog.swift:93-98,246-254 vs SystemCatalog.swift:276-281` `F46`
- FFFIndex.rebuild() (line 664) calls changeRoot, which calls fff_restart_index and takes picker.write() (a heavier lock), even though the cheaper fff_scan_files/rescan() wrapper already exists. `FFFIndex.swift:664,417-430,408-415; ApplicationCatalog.swift:103` `U12`
- CatalogRefreshGuard prevents stacked filesystem walks with a state machine checking isRefreshing and minimumInterval. `Sources/FloodlightEngine/Search/Catalog.swift:224-233` `F`

### SystemCatalog: startup and settings discovery

- SystemCatalog.start() unconditionally calls refreshIfNeeded(forceDiscovery: true), running discoverInstalledSettings() on every launch and bypassing the fingerprint guard at line 277. `SystemCatalog.swift:251-259,277` `F` `F56:accuracy`
- SystemCatalog.discoverInstalledSettings instantiates a Bundle for every appex under ExtensionKit/Extensions, System Settings.app PlugIns, and PreferencePanes directories, but calls localizedInfoDictionary only for bundles that pass a shouldIndex filter — reaching a few dozen appex bundles, not several hundred. `SystemCatalog.swift:455-478,470-479,500-518,521-528` `F` `F56:accuracy`
- SystemCatalog's fingerprint is stored in-memory behind an OSAllocatedUnfairLock (line 239) with no persistence across app launches. `SystemCatalog.swift:239` `F56:accuracy`
- SystemCatalog's built-in Setting count is reported inconsistently: 39 entries at lines 43-235 in one source, 41 entries at line 237 in another — the two numbers disagree. `SystemCatalog.swift:43-235,237` `F30` `F56:value` `F57:value`
- SystemCatalog.refreshIfNeeded does its filesystem work outside the lock (lines 276, 281) and takes the settings lock only for the final state swap (lines 288-298), which performs three map allocations and builds a Set — the lock is not held during filesystem work. `SystemCatalog.swift:276,281,288-298` `F30`
- SystemCatalog.refreshIfNeeded is marked @concurrent (lines 261-262) and runs inside a background startup Task. `SystemCatalog.swift:261-262` `F56:accuracy`

### Query-time matching: immediatePage and characterMask

- ApplicationCatalog.immediatePage (lines 166-208) is a synchronous, non-async, pure in-memory linear scan over state.applications, served entirely before any FFF call: it applies a fast characterMask prefilter, calls blocklistStore.isBlocked per application before that mask gate (lines 183,186), then scores candidates with FuzzyMatcher, building a SearchItem only when the score is non-nil (lines 189-196). `ApplicationCatalog.swift:166-208,182-206,189-196` `U3` `U13` `F46` `F3-value`
- immediatePage caps output at 64 matches, pre-allocating the SearchItem array with reserveCapacity(min(currentApps.count, 64)) and deduplicating via SearchItemRanking. `ApplicationCatalog.swift:166-208,179-180` `U3` `F3-accuracy`
- characterMask (ApplicationCatalog.swift:435-451, SystemCatalog.swift:437-453) is a UInt64 bitmask with one bit per a-z/0-9 byte — a-z and A-Z share bits 0-25, digits use bits 26-35 — and ignores every other byte. `ApplicationCatalog.swift:435-451; SystemCatalog.swift:437-453` `U3` `F8-accuracy`
- The characterMask prefilter is unsound for substitution typos, since a one-character substitution introduces a query byte absent from the candidate; FuzzyMatcherTests only exercises deletion typos, so no test catches this. In practice FFF's fuzzy/subsequence matching makes substitution typos unlikely to arise anyway. `ApplicationCatalog.swift:186; FuzzyMatcher.swift:186-263; FuzzyMatcherTests.swift:75-130` `F8-accuracy`
- ApplicationCatalog.immediatePage picks asciiQuery (raw UTF-8 bytes) when the query is entirely under 0x80, otherwise falls back to normalizedQuery for full UTF-8 character matching. `ApplicationCatalog.swift:166-208` `U3`
- ApplicationCatalog.immediatePage (line 171) and SystemCatalog.immediatePage (line 344) each normalize the incoming query independently rather than sharing a single normalization pass. `ApplicationCatalog.swift:171-174; SystemCatalog.swift:344-347` `F22`
- Application caches only asciiCandidate and characterMask (populated in assignMarkerNames); ApplicationCatalog.score(of:) calls FuzzyMatcher.scoreASCII/score and discards the match shape, returning only an Int. `ApplicationCatalog.swift:12-13,227-244,453,466-467` `F9-accuracy` `F107`
- ApplicationCatalog calls blocklistStore.isBlocked() per result (lines 142,183) and recentStore.boostMap()/boost() per keystroke (lines 177,158). `ApplicationCatalog.swift:142,158,177,183` `F`
- SystemCatalog.immediatePage is declared at line 339 (not line 349 as an earlier claim had it) and starts from a candidate set of roughly 44 curated panes plus discovered prefPanes; for queries under 4 characters, its gate at line 358 runs String.hasPrefix across every word. `SystemCatalog.swift:339,358-359` `F3-accuracy` `F27`
- SystemCatalog takes its settings OSAllocatedUnfairLock exactly once, holding it across the entire per-keystroke fuzzy-matching and SearchItem-construction loop (lines 339-360) — not one lock per candidate item. `SystemCatalog.swift:339-360,349` `F6` `F27` `F2-accuracy`
- SystemCatalog.immediatePage allocates a fresh id string "setting:\(setting.pane)" and a subtitle string "Matches: \(keyword)" for every matched setting; Setting.pane is an immutable stored field. `SystemCatalog.swift:8,402,405` `F27` `F30`
- SystemCatalog matches against a normalized candidate built by concatenating name + space + keywords (line 32); because match offsets can land in the keywords portion, SystemCatalog.swift:377-401 checks isTitleMatch before using MatchEvidence offsets to build the highlighted subtitle. `SystemCatalog.swift:32,377-401` `F107`
- FuzzyMatcher.MatchEvidence's match positions are computed by SystemCatalog but SearchItem does not store them; of SearchItem.SearchItemKind's 8 cases, only 2 — application and systemSetting — ever touch FuzzyMatcher, so highlighted match positions are not universal across result kinds. `FuzzyMatcher.swift:5-21; SearchItem.swift:268-306` `F107`

### FuzzyMatcher internals

- FuzzyMatcher.MatchEvidence carries a match shape plus offset: namePrefix, wordPrefix(offset:), acronym(offset:), or typo(edits:offset:). `FuzzyMatcher.swift:6-21` `F`
- FuzzyMatcher.findAcronym's offsets are word indices into the initials array, not character offsets into the title. `FuzzyMatcher.swift:153-167` `F107`
- FuzzyMatcher.normalized folds with [.caseInsensitive, .diacriticInsensitive] options and locale:.current via String.folding, routed through ICU/CFString machinery; this folding is not length-preserving. `FuzzyMatcher.swift:118-123` `F4-accuracy` `F22`
- matchASCII (lines 90-108) early-exits on an exact match or a name-prefix match; every other candidate unconditionally calls extractWordsASCII, which allocates a fresh [(Int, ArraySlice<UInt8>)] array with no reserveCapacity, while the non-ASCII extractWords (line 289) does call reserveCapacity(4). `FuzzyMatcher.swift:90,100,104,108,289,312-333` `F9-accuracy` `F14`
- findAcronymASCII allocates an array via compactMap to build the initials list. `FuzzyMatcher.swift:169-174` `F14`
- editBudget is 0 for queries of length 1-2 bytes. `FuzzyMatcher.swift:265-271` `F1-accuracy`

### SearchItemRanking / sorting

- SearchItemRanking's comparator (Catalog.ranksBefore, line 80) sorts by lhs.title.localizedStandardCompare — an ICU-backed, locale-aware collation call. `Catalog.swift:80` `F4` `F32`
- topRankedInPlace calls items.sort(by: ranksBefore) when items.count > limit (lines 112-114) — this is reported alongside a separate COW analysis of the same function (see the ApplicationCatalog matching section) finding that the >limit branch never mutates items and that copies occur only in the <=limit branch where sort runs; the batch does not reconcile which branch actually invokes sort(by:). `Catalog.swift:104-135` `F32` `F3-accuracy`
- FLOODLIGHT_BENCH budgeted performance tests are engine-level only (SearchItemRankingPerformanceTests.swift) and cannot observe UI-frame costs. `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift` `F77` `F79` `F81` `F82`

### RecentStore and boost scoring

- RecentStore.record() dispatches asynchronously to a persistenceQueue rather than writing synchronously on the calling thread. `Sources/FloodlightEngine/Utilities/RecentStore.swift:29-40` `F`
- The boost formula is min(entry.launches, 25) * 200 + max(0, 4000 - Int(age/900)); recency decays in 900-second (15-minute) steps. `Sources/FloodlightEngine/Utilities/RecentStore.swift:62-65,64` `F17`
- boostMap rebuilds its Dictionary with reserveCapacity(dict.count) on every call. `Sources/FloodlightEngine/Utilities/RecentStore.swift:49-59` `F17`
- RecentStore tracks launch counts, persisted to UserDefaults under the key recent-items-v1, and is read by ApplicationCatalog (lines 158, 177) for score boosting. `RecentStore.swift; ApplicationCatalog.swift:158,177` `U19`
- A recents list with icons can be built from RecentStore in-process with no FFI work, whereas fff_get_historical_query returns bare strings that require a fresh search to resolve into items. `RecentStore.swift` `U19`

### BlocklistStore

- BlocklistStore.isBlocked (lines 144-146) acquires an OSAllocatedUnfairLock then checks blockedIDs.contains — an O(1) set lookup with minimal contention — on every keystroke; the function is located at line 144, not line 216 as an earlier claim had it. `Sources/FloodlightEngine/Utilities/BlocklistStore.swift:144-146` `F` `F13` `F4-accuracy`
- Because Swift's NativeSet.contains short-circuits when count==0, an empty blocklist costs no string hashing — only the OSAllocatedUnfairLock round-trip, not ~1,500 hashes of an id string as previously claimed. `BlocklistStore.swift:73` `F4-value`
- BlocklistStore's case/diacritic folding (line 74) is guarded by an isEmpty check, skipping the fold in the common case; isBlocked(name:id:) performs exact, fully case- and diacritic-folded full-string matching, not substring matching. `BlocklistStore.swift:72-82,74-75` `F13` `F128`
- BlocklistStore.isBlocked is called from ApplicationCatalog.immediatePage per application (lines 183,186), before the characterMask gate, with .folding(options:) normalization per title, and also from SearchCoordinator.projectLocal (line 596). `ApplicationCatalog.swift:183,186; BlocklistStore.swift:75; SearchCoordinator.swift:596` `F4` `F13`
- BlocklistStore is UserDefaults-backed under the key search-blocklist-v1 and persists across app restarts; block(name:)/block(id:) write there. `BlocklistStore.swift:108-115` `F128`
- BlocklistStore is mutated by OnboardingSession (lines 119,123-128); blocked entries are removable via the Settings window (OnboardingView blocklistSection, lines 229-262) through OnboardingSession.unblockRule (lines 123-131). `OnboardingSession.swift:119,123-131; OnboardingView.swift:229-262` `F13` `F128`
- SearchCoordinator.excludeFromSearch calls blocklistStore.block(id:) and block(name:) unconditionally, with no mode guard. `Sources/Floodlight/Search/SearchCoordinator.swift:391-393` `F123`

### Calculator

- Calculator.evaluate gates on the query containing at least one operator character from the 11-character literal "+-*/%^()×÷−" (line 6), then early-exits via looksLikeExpression (line 12); the recurring per-keystroke cost is not "4x Calculator.evaluate" — it is the fast gate check plus, on a real expression, three replacingOccurrences passes (×→*, ÷→/, −→-) and a trimmingCharacters call (lines 7-11). `Calculator.swift:6,7-11,12` `F30` `F33` `F113-accuracy` `F14`
- Calculator.looksLikeExpression's contains(where:) and allSatisfy checks (lines 30-31) both short-circuit, so they are not the recurring cost — but looksLikeExpression admits Unicode Nd digits via Character.isNumber, not just ASCII digits, confirmed by non-ASCII input in CalculatorStressTests.swift:273-281, so replacing it with [UInt8] byte parsing would change behavior. `Calculator.swift:30-31; Tests/FloodlightEngineTests/CalculatorStressTests.swift:273-281` `F33` `F8`
- Calculator.Parser.init allocates a [Character] array to parse the expression. `Calculator.swift:39-40` `F30`
- Calculator.format allocates a fresh, uncached NumberFormatter (an expensive ICU-backed object) on every call, but it is invoked exactly once per projection (SearchResultProjection.swift:441) and only when evaluation succeeds. `Calculator.swift:20-27; SearchResultProjection.swift:441` `F7` `F30` `F113-value` `F113-accuracy`
- Calculator.evaluate returns nil for bare numbers. `Tests/FloodlightEngineTests/CalculatorAdversarialTests.swift:210-212` `F113-accuracy`
- SelectedResultActionPerformer.swift:240-243 reuses a precomputed copy value instead of re-calling Calculator.format when the user copies a calculator result. `SelectedResultActionPerformer.swift:240-243` `F113-accuracy` `F113-value`
- The Calculator result row uses Font.system(size: 15, weight: .medium) and echoes the input query as its subtitle. `FloodlightMetrics.swift:55; ResultRow.swift:45-50; SearchResultProjection.swift:445` `F113-accuracy` `F113-value`
- Calculator's copy payload uses a grouped number display format pinned by CalculatorTests.swift:24, CalculatorPropertyTests.swift:387-393, and CalculatorStressTests.swift:228-246; CalculatorDifferentialTests.swift:504-522 pins a divergence between Foundation's CharacterSet.whitespacesAndNewlines and Swift's Character.isWhitespace around U+200B, and CalculatorStressTests.swift:273-281 exercises Unicode operators. `CalculatorTests.swift:24; CalculatorPropertyTests.swift:387-393; CalculatorStressTests.swift:228-246,273-281; CalculatorDifferentialTests.swift:504-522` `F113-accuracy` `F33`

### PathNavigator

- PathNavigator.findCaseInsensitiveMatch (lines 159-166) synchronously calls fileManager.contentsOfDirectory on the main actor, lowercases every directory entry name, and returns first(where: { $0.lowercased() == lower }). `PathNavigator.swift:159-166,164` `F23` `F7-accuracy`
- For a relative-path query (contains "/" but doesn't start with "~" or "/"), PathNavigator.generateCandidatePaths/resolve calls findCaseInsensitiveMatch twice — once under rootURL (line 116), once under homeURL (line 127) — both hitting contentsOfDirectory unconditionally, synchronously, on the main actor. `PathNavigator.swift:116,118-135,127,159` `F2` `F7-accuracy` `F37` `U10`
- PathNavigator returns early — skipping directory listing entirely — for queries starting with "~" (line 94) or "/" (line 109); resolve only performs any filesystem gating at all when query.contains("/") or the query starts with "~" (lines 24-30), so the per-keystroke cost is not "4x PathNavigator.resolve with filesystem I/O." `PathNavigator.swift:24-30,94,109` `F7-accuracy` `F14` `F37`
- On case-insensitive APFS volumes, findCaseInsensitiveMatch still runs even when the literal path already exists. `PathNavigator.swift:115-135` `F7-accuracy`

### Clipboard write actions and documentation

- SelectedResultActionPerformer.writeFiles() (lines 48-62) calls clearContents(), then writeObjects(urls as [NSURL]), then setData and setPropertyList, adding a file-reference and a duplicate-avoidance marker to the pasteboard. `Sources/Floodlight/Search/SelectedResultActionPerformer.swift:48-62` `F:clipboard-ui`
- AppKitSelectedResultActionEffects.writeImage (lines 64-78) performs its own clearContents() plus its own write marker, separate from writeFiles(). `SelectedResultActionPerformer.swift:64-78` `F136`
- docs/adr/ contains exactly 7 ADRs, numbered 0001-0007, covering the source search engine, selected-result actions, assistant CLI, keyword engines, and search scope; docs/adr/0006-keyword-engine-registry.md specifically covers keyword-engine-registry decisions. `docs/adr/0001-0007; docs/adr/0006-keyword-engine-registry.md` `F148` `F149`
- No keyword-catalog row exists for "clip" (no grep match in the engine catalog). `grep search of engine catalog` `F131`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| ApplicationCatalog.start poll loop | 200 iterations x 10ms = 2s ceiling | `ApplicationCatalog.swift:107-123` |
| immediatePage result cap | 64 matches (reserveCapacity(min(currentApps.count,64))) | `ApplicationCatalog.swift:166-208,179-180` |
| Boost formula | min(launches,25)*200 + max(0,4000-Int(age/900)) | `RecentStore.swift:62-65` |
| Boost recency step | 900 seconds (15 minutes) | `RecentStore.swift:64` |
| FuzzyMatcher editBudget for very short queries | 0 for queries of length 1-2 bytes | `FuzzyMatcher.swift:265-271` |
| Marker file count (conflicting) | ~200 (one source) vs ~1,500 (another source) | `explorer summary vs ApplicationCatalog.swift:268,496-501` |
| synchronizeMarkers syscalls per launch | ~3,000 (1 contentsOfDirectory + 1 fileExists per app over ~1,500 markers) | `ApplicationCatalog.swift:265-271,496-502` |
| SystemCatalog built-in settings count (conflicting) | 39 entries (lines 43-235) vs 41 entries (line 237) | `SystemCatalog.swift:43-235,237` |
| SystemCatalog immediatePage candidate set | ~44 curated panes plus discovered prefPanes | `SystemCatalog.swift:339` |
| Calculator operator-gate literal | 11-character constant "+-*/%^()×÷−" | `Calculator.swift:6` |
| Calculator result row font size | 15pt, .medium weight | `FloodlightMetrics.swift:55` |
| FFF instance count | exactly 2 (main file index + marker index) | `FFFIndex.swift; ApplicationCatalog.swift` |
| docs/adr count | 7 ADRs, numbered 0001-0007 | `docs/adr/` |
| FFF index cache config (both instances) | cache_budget fields = 0, enable_mmap_cache = true | `FFFIndex.swift:77-87` |

### Gotchas

- The characterMask prefilter used by both ApplicationCatalog and SystemCatalog is unsound for substitution-typo queries — a substituted character can be rejected by the mask even though FuzzyMatcher could still score it as a typo match — and no existing test catches this because FuzzyMatcherTests only uses deletion typos. `ApplicationCatalog.swift:186; FuzzyMatcher.swift:186-263; FuzzyMatcherTests.swift:75-130`
- ApplicationCatalog's startup poll loop can silently time out after 2 seconds with no error and no log line. `ApplicationCatalog.swift:116-124`
- ApplicationCatalog.prepare() populates state.applications before the progress-poll loop even starts, so the in-memory fuzzy pass can serve results before the underlying file scan is done. `ApplicationCatalog.swift:110-112,116`
- ApplicationCatalog.swift and SearchCoordinator.swift disagree on their fallback path when supportURL resolution fails — one falls back to temporaryDirectory, the other to a hardcoded path — so the two components can end up pointed at different index roots. `ApplicationCatalog.swift:57-60; SearchCoordinator.swift:168-172`
- SearchCoordinator.excludeFromSearch blocks both the id and the name unconditionally, with no mode guard on which one applies. `Sources/Floodlight/Search/SearchCoordinator.swift:391-393`
- Two facts in this batch disagree on marker-file count (~200 vs ~1,500) and on SystemCatalog's built-in settings count (39 vs 41); neither pair is flagged as a correction of the other. `explorer summary vs ApplicationCatalog.swift:268,496-501; SystemCatalog.swift:43-235 vs :237`
- Reports of SearchItemRanking's large-result branch conflict: one says topRankedInPlace calls items.sort(by: ranksBefore) when count > limit, another says the >limit branch never mutates items and sort only runs in the <=limit branch — the batch never reconciles which is true. `Catalog.swift:104-135,112-114`
- FLOODLIGHT_BENCH performance tests only measure engine-level costs and cannot observe UI-frame costs, so a passing budget there does not guarantee UI responsiveness. `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift`
- The marker-index FFFIndex that ApplicationCatalog creates has no way to disable persistent ranking, even though ApplicationCatalog discards and recomputes all scores itself in Swift. `ApplicationCatalog.swift:65-73,138-161`

### Corrected on review

- ~~ApplicationCatalog.start calls waitForScanCompletion like FFFFileSource.~~ → ApplicationCatalog.start implements its own 200x10ms polling loop and does not call waitForScanCompletion. `ApplicationCatalog.swift:107-123`
- ~~BlocklistStore.isBlocked is at BlocklistStore.swift:216.~~ → BlocklistStore.isBlocked is at BlocklistStore.swift:144-146. `BlocklistStore.swift:144-146`
- ~~An empty blocklist still incurs ~1,500 hashes of an id string.~~ → NativeSet.contains short-circuits at count==0, so an empty blocklist costs only the lock round-trip, no hashing. `BlocklistStore.swift:73`
- ~~Settings scan takes one lock per candidate item.~~ → SystemCatalog.immediatePage takes ONE lock for the entire per-keystroke candidate loop. `SystemCatalog.swift:339-360`
- ~~The ranking page copies the array again after materialization.~~ → Copy-on-write means the >limit branch in SearchItemRanking never mutates items; copies happen only in the <=limit branch where items.sort runs. `Catalog.swift:104-135`
- ~~SystemCatalog.immediatePage is declared at SystemCatalog.swift:349.~~ → SystemCatalog.immediatePage is declared at SystemCatalog.swift:339. `SystemCatalog.swift:339`
- ~~Calculator.evaluate runs 4x per keystroke.~~ → Calculator.evaluate returns nil early unless the query contains an operator character; the 4 buildLocalRows calls each hit this fast gate. `Calculator.swift:6`
- ~~PathNavigator.resolve does filesystem I/O 4x per keystroke.~~ → PathNavigator.resolve returns nil unless the query contains "/" or starts with "~"; most calls fast-exit before any I/O. `PathNavigator.swift:24-25`
- ~~addressedResult parses a URL template 4x per keystroke.~~ → addressedResult returns nil immediately on a keyword-lookup miss, without reaching the host/template logic. `KeywordEngine.swift:228`
- ~~SystemCatalog.refreshIfNeeded holds its lock while doing filesystem work.~~ → refreshIfNeeded does filesystem work outside the lock and takes it only for the final state swap. `SystemCatalog.swift:276,281,288-298`
- ~~Calculator.looksLikeExpression walks the query two more times.~~ → looksLikeExpression's contains(where:)/allSatisfy both short-circuit; the real recurring cost is 4 String allocations from replacingOccurrences/trimmingCharacters. `Calculator.swift:30-31`
- ~~Character.isNumber semantics in looksLikeExpression can be replaced with UTF-8 byte parsing.~~ → looksLikeExpression admits Unicode Nd digits via Character.isNumber, not just ASCII, so byte-level parsing would change behavior on non-ASCII input. `Calculator.swift:31; CalculatorStressTests.swift:273-281`
- ~~ApplicationCatalog.refreshIfNeeded needs an @concurrent decorator like SystemCatalog.~~ → ApplicationCatalog.refreshIfNeeded already offloads filesystem work via discoveryQueue/withCheckedContinuation; only SystemCatalog needs @concurrent. `ApplicationCatalog.swift:93-98,246-254`
- ~~The web-mode tab list is missing from the panel.~~ → Only the Ask Claude / Ask Codex assistant rows are delayed by keyword-registry resolution; web-mode rows are available from t=0. `SearchCoordinator.swift:136; KeywordEngine.swift:421-447`
- ~~localizedInfoDictionary is loaded for several hundred bundles.~~ → Only bundles passing the shouldIndex filter reach localizedInfoDictionary — a few dozen appex bundles, not several hundred. `SystemCatalog.swift:470-479,500-528`
- ~~There are three or four redundant applicationSupportDirectory resolutions during construction.~~ → There are two: SearchCoordinator.swift:173 and ApplicationCatalog.swift:51-52 each resolve it independently. `SearchCoordinator.swift:173; ApplicationCatalog.swift:51-52`
- ~~Passing the supportURL parameter to ApplicationCatalog.init avoids the redundant directory resolution.~~ → defaultSupport is computed unconditionally before the supportURL ?? defaultSupport fallback, so passing supportURL does not eliminate the resolution. `ApplicationCatalog.swift:51-61`
- ~~All SearchItem result kinds can display highlighted match positions.~~ → Of SearchItem.SearchItemKind's 8 cases, only 2 (application, systemSetting) ever touch FuzzyMatcher. `SearchItem.swift; ApplicationCatalog.swift; SystemCatalog.swift`
- ~~BlocklistStore's substring matching can hide files unintentionally.~~ → BlocklistStore.isBlocked(name:id:) performs exact, case/diacritic-folded full-string matching, not substring matching. `BlocklistStore.swift:72-82`
- ~~ApplicationCatalog has adequate wait guards via a two-idle-poll debounce.~~ → ApplicationCatalog.refreshIfNeeded calls index.rescan() and returns immediately without waiting for scan completion. `ApplicationCatalog.swift:102-104`
- ~~ApplicationCatalog.start and FFFFileSource.start have equivalent wait patterns.~~ → ApplicationCatalog.start caps its wait at 200 polls x 10ms = 2 seconds, while FFFFileSource.start is unbounded. `ApplicationCatalog.swift:115-121`
- ~~No caller overrides log_file_path.~~ → ApplicationCatalog.swift:71 and SearchCoordinator.swift:196 both override it via the FLOODLIGHT_FFF_LOG environment variable. `ApplicationCatalog.swift:71; SearchCoordinator.swift:196`

<a id="swift-coordinator-projection"></a>
## Floodlight: coordinator, projection, publication, observation

This batch covers Floodlight's Swift shell: how SearchCoordinator boots, how a keystroke turns into a published result set, and how SearchResultProjection builds each row (title, subtitle, icon, preview). SearchCoordinator is a @MainActor, @Observable class whose entire UI state hangs off one stored property, `publication` (a SearchResultPublication struct with sourceCandidates/allRows/visibleRows/filterOptions), reassigned at 12 sites. Every keystroke runs a synchronous stale-while-revalidate local projection before the async search task even starts, and several projection/filter passes repeat per keystroke by design, not by accident — a few things that read as obvious bugs (duplicate dedup, duplicate projections) are confirmed-necessary by tests and by a documented list-collapse regression. The row-building code (previewTitle, icon selection, fileExists checks) mixes cheap and expensive work indiscriminately per row per keystroke. Keyboard handling has several undocumented or mismatched bindings (Command+Period, Command+D, a mislabeled footer button). The engine boundary (FFFIndex) filters out `.app`-bundle paths in Swift, redundantly, at all four of its search entry points, after the Rust FFI layer has already paged the results down to a handful of items.

### App startup and coordinator construction

- AppDelegate is a @MainActor class that lazily constructs SearchCoordinator on first access, deferring all coordinator initialization until needed. `AppDelegate.swift:5,10` `F61`
- AppDelegate.installGlobalHotKey() accesses model.activeShortcutDisplayName, which forces the lazy SearchCoordinator to construct on the main thread (cited at AppDelegate.swift:34/111 in one finding and :109 in another, with the SearchCoordinator init spanning :158-200). `AppDelegate.swift:34,109,111; SearchCoordinator.swift:158-200` `F51` `F67`
- AppDelegate.registerLaunchAtLogin runs synchronously on the main thread at line 35, before presentation.launch runs at line 37. `AppDelegate.swift:35,37; ApplicationPresentationCoordinator.swift:47-54` `F59`
- ApplicationPresentationCoordinator.launch calls ensureSearchStarted() then showSearch() unconditionally and synchronously, before any Task body runs — so the search panel is displayed while the app-discovery walk is still in progress. `ApplicationPresentationCoordinator.swift:47-55` `F` `F38` `F50` `F54:value`
- Cold start loads 1000 rows with thumbnails synchronously on the main thread. `SearchCoordinator.swift:201-205; AppDelegate.swift:35` `F14`
- SearchCoordinator's publication is initialized in the initializer with pendingKinds: [.application, .systemSetting]. `SearchCoordinator.swift:138-151` `F57:value`
- SearchCoordinator's convenience init resolves applicationSupportDirectory with create=true and separately creates the FileIndex directory, both on the main thread. `SearchCoordinator.swift:173-184` `F`
- SearchCoordinator's default/initial search root is ~/Downloads. `SearchCoordinator.swift:164-165` `F30` `F37` `F62`
- SearchCoordinator reads and writes the UserDefaults key "index-root" directly — hardcoded, with no dependency-injection seam for testing — to persist and restore the search scope. `SearchCoordinator.swift:163,488` `F` `F61` `F132`
- SearchCoordinator.scheduleSearch(immediate: true) restarts the search once file-index startup completes. `SearchCoordinator.swift:238` `F44`
- FloodlightPanelController.init allocates the NSPanel, runs applyGlassState with an NSHostingController and NSGlassEffectView, and registers one global NSEvent monitor plus two notification observers. `FloodlightPanel.swift:36-102` `F`

### Query to search: per-keystroke call flow

- SearchCoordinator is declared @MainActor. `SearchCoordinator.swift:5-7` `F33` `F37` `F48` `F166` `F10` `F13` `F101`
- SearchResultProjection is also a @MainActor class. `SearchResultProjection.swift:5` `F116-accuracy`
- SearchCoordinator's `query` property's didSet calls scheduleSearch() synchronously, in the same run-loop turn as the keystroke, with no debounce delay. `SearchCoordinator.swift:8-14` `F13` `F47` `F49` `F78` `F116-accuracy` `F166`
- SearchCoordinator's startupTask and searchTask are created via Task {} with no explicit priority argument. `SearchCoordinator.swift:219,540` `F48`
- SearchCoordinator assigns the stale-while-revalidate local projection to `publication` synchronously at line 527, before the async searchTask is even created at line 540 — so rows are non-empty in the same turn as the keystroke. `SearchCoordinator.swift:527,540` `F49` `F69` `F77`
- That stale-while-revalidate pre-projection deliberately preserves the previous query's sourceCandidates to prevent a list-collapse regression (see correction on why the two projections cannot be merged). `SearchCoordinator.swift:519-526` `F36`
- SearchResultProjection.buildLocalRows runs up to 4 times per keystroke, all on the main actor. `SearchResultProjection.swift:143; SearchCoordinator.swift:527,556` `F15`
- Three separate sites in SearchCoordinator apply the same filtering predicate per keystroke. `SearchCoordinator.swift:364-370,394-399,527-540` `F13`
- SearchResultProjection.project is invoked synchronously from SearchCoordinator, on the main actor, at four separate call sites. `SearchCoordinator.swift:138,577,600,663` `F79`
- visibleRows filtering is redone in all four of those projection passes per keystroke. `SearchResultProjection.swift:162,203` `F19`
- selectFilter(_:) contains an early-return guard comparing the requested filter against the current selectedFilter. `SearchCoordinator.swift:355-358` `F132`
- SearchCoordinator.activate(_:) already performs select-then-act in a single call. `SearchCoordinator.swift:342-346` `F129`
- webModeReturnIsArmed gates openSelection but is unconditionally true outside web mode. `SearchCoordinator.swift:382-385` `F106`

### SearchResultPublication and SearchResultProjection data model

- SearchResultPublication carries (at least) four fields — sourceCandidates, allRows, visibleRows (capped at maxResultsLimit=80), and filterOptions — and is the sole stored property SearchCoordinator assigns; storing both allRows and visibleRows doubles row memory when the filter is .all. `SearchResultProjection.swift:4,170; SearchCoordinator.swift:85,152,162,436` `F3` `F19` `F78` `F13` `F36`
- SearchResultPublication conforms to Equatable and holds both allRows and visibleRows, which multiplies thumbnail memcmp cost across every image row whenever a comparison runs. `Sources/Floodlight/Search/SearchResultProjection.swift` `F8`
- SearchResultPublication's Equatable conformance is never actually invoked for comparison anywhere in SearchCoordinator.swift or SearchView.swift — the publication property is reassigned unconditionally on every update. `SearchResultProjection.swift:4 (conformance declared, no call sites found)` `F169`
- SearchResultPublication carries a single optional selection (SearchResultSelection?, an id/origin pair); every mutation path assumes exactly one selection. `SearchResultProjection.swift:4-11,10` `F7` `F139`
- SearchResultProjection.selecting(_:) rebuilds that single selection field. `SearchResultProjection.swift:13-23` `F139`
- SearchCoordinator.moveSelection(by:) walks a single index and calls publication.selecting() with one item. `SearchCoordinator.swift:332-338` `F139`
- SearchResultProjection.reconcile(_:in:) returns at most one SearchResultSelection. `SearchResultProjection.swift:475-491` `F139`
- SearchItemIconSource.thumbnail(Data) is a Hashable field on SearchItem, so SwiftUI's equality diffing memcmps entire thumbnail buffers per publication comparison. `SearchItem.swift:259-268` `F85`
- SearchResultProjection.maxResultsLimit is 80, applied to cap immediate/local-mode results. `SearchResultProjection.swift:436,465-467` `F4` `F25` `F6` `F10` `F19` `F32` `F69` `F78` `F82`
- SearchResultProjection contains a `seen: Set<SearchItem.ID>` used to deduplicate result IDs. `SearchResultProjection.swift:467` `F32`
- buildLocalRows separately re-deduplicates with its own Set<SearchItem.ID> over a roughly 60-row list. `SearchResultProjection.swift:459-460` `F29`

### Observation model

- publication is the sole @Observable-tracked stored property on SearchCoordinator; results, selectedFilter, selectedID, isSearching, and filterOptions are all computed properties derived from it. `SearchCoordinator.swift:85,21-57` `F70`
- publication is written at 12 separate assignment sites inside SearchCoordinator; moveSelection writes the entire struct even when only the selection changed. `SearchCoordinator.swift:138,234,260,319,337,349,364,397,515,527,556,577,663` `F70`
- SearchCoordinator is a shell-side @Observable class with @ObservationIgnored stored properties. `SearchCoordinator.swift:71-79` `F132`
- For comparison elsewhere in the codebase, AssistantRunSession declares `run` as its sole non-@ObservationIgnored property; runTask and generation are marked @ObservationIgnored. `AssistantRunSession.swift:41,43-48` `F78`
- SearchCoordinator.results is a computed property returning publication.visibleRows; SearchView's row(for:index:) re-evaluates it up to 80 times per body pass. `SearchCoordinator.swift:21-23; SearchView.swift:417` `F82`

### Filter chips and counts

- Filter chips consist of 4 always-visible filters (All, Apps, Files, Folders) plus dynamic filters (Settings, PDFs, Images, Documents) appended after them, in that order. `filters.mdx` `Documentation & Architecture cluster`
- emptyFilterOptions yields the 4 SearchResultFilter.primary chips unconditionally. `SearchResultProjection.swift:127-138` `F77`
- SearchFilterCounts is a flat struct of eight Ints with a subscript for per-category counts, and it is rebuilt from scratch on every projection by scanning allRows. `SearchItem.swift; SearchResultProjection.swift:153; SearchItem.swift:156-180` `F28` `F4`
- SearchResultProjection (lines 499-506) consumes totalMatches for the filter-chip count, while the .files and .folders cases fall into a default: visibleCount branch (524-537). `SearchResultProjection.swift:499-506,524-537` `U14`
- SearchResultFilter.imageExtensions is a fileprivate static let scoped to the engine module, not exposed to the shell, and SearchResultFilter itself has no .video case — it exists for search-filter chips, not media classification. `SearchItem.swift:133` `F112`
- SearchFilterOption is Equatable. `SearchItem.swift:197` `F83`
- SearchFilterChip is a View holding a () -> Void closure and is not itself @Equatable, so SwiftUI's default view-diffing cannot short-circuit its re-render. `SearchView.swift:306-310` `F83`
- SearchFilterBar.chipRow reads model.filterOptions from the monolithic publication on every bar render; a test (SearchViewRenderingTests.swift:543-553) pins SearchFilterChip's rendered values. `SearchView.swift:293-301; Tests/FloodlightTests/SearchViewRenderingTests.swift:543-553` `F83`

### Row content building: previews, subtitles, icons, pinned rows

- SearchResultProjection.previewTitle builds a row's preview by splitting the entry text on newlines (split(whereSeparator: \.isNewline)), joining with a space, then trimming whitespace — running once per text row per keystroke, over text up to 32KB. `SearchResultProjection.swift:396-401` `F` `F6` `F19` `F23` `F69` `F78` `F100` `F133`
- FileManager.default.fileExists(atPath:) is called synchronously, per local-path-shaped row, inside the main-actor projection. `SearchResultProjection.swift:299` `F13` `F100` `F116-accuracy`
- The parseLocalPath + fileExists chain re-runs for every text row, including pinned rows, which pay this cost outside any short-circuit conditional. `SearchResultProjection.swift:282,299` `F116-accuracy` `F116-value`
- Pinned entries short-circuit the icon-selection chain (swapping in a fixed pin icon), even though the earlier parseLocalPath/fileExists calls still ran unconditionally for them. `SearchResultProjection.swift:282,290,299,309` `F116-value`
- Text-row subtitles are built as string concatenation of the app name, a space, and a relative time from formattedRelativeTime. `SearchResultProjection.swift:316-317` `F105`
- formattedRelativeTime has exactly 3 call sites in the file. `SearchResultProjection.swift:287,316,375` `F105`
- appDisplayName returns just the last dot-separated component of a bundle ID. `SearchResultProjection.swift:403-409` `F109`
- Icon/glyph selection covers pin.fill, link, paintpalette.fill, curlybraces, and doc.text for different content types. `SearchResultProjection.swift:318-328` `F109`
- Choosing that glyph re-runs parseURL, parseHexColor, and parseCodeHint purely to pick the icon, discarding the classification results already computed earlier in the same function. `SearchResultProjection.swift:320-325` `F110` `F166`
- Pinned entries get their row icon swapped to pin.fill, colored orange. `SearchResultProjection.swift:290-291,318` `F123`
- That pin.fill icon replaces the type icon (photo/video/inferred), destroying the type affordance for pinned rows. `SearchResultProjection.swift:290-291,318` `F123`
- A precomputed answer string is stored as a .copy(answer) action payload. `SearchResultProjection.swift:447` `F113-accuracy` `F113-value`
- Other text rows set .copy(text) with the full text, not a preview snippet. `SearchResultProjection.swift:305,334` `F134`
- Text entries that parse as an existing local path get fileURL set. `SearchResultProjection.swift:299-309` `F133`
- Plain URL text rows set no fileURL at all, so any action requiring fileURL is a silent no-op on link rows. `SearchResultProjection.swift:329-338` `F135`
- SearchCoordinator.previewableSelectionURL is the sole QuickLook fallback that supplies a fileURL for preview. `SearchCoordinator.swift:418-433` `F133`

### Selection handling

- Selection movement is implemented only via raw keyCode 125 (down) and 126 (up), read in FloodlightPanel's keyDown monitor and forwarded to SearchCoordinator.moveSelection(by:); SearchView wires its keymap to these coordinator movement methods. `FloodlightPanel.swift:283-289; SearchCoordinator.swift:332; SearchView.swift:89-102` `F130`
- moveSelection(by:) and select(_:) both reassign publication = publication.selecting(), replacing the whole struct even when only the selection changed. `SearchCoordinator.swift:337,349` `F83`
- "Show in Finder" calls model.revealSelection() against the current selection, not against whatever item the menu was opened on. `SearchView.swift:440` `F81`

### Keyboard shortcuts and panel commands

- FloodlightPanel.panelCommand binds Command+Period to .togglePin and 'd' to .deleteSelection; both bindings are undocumented and not platform-idiomatic, and deleteSelection fires with no confirmation prompt. `FloodlightPanel.swift:365-383 (case '.' at 378-383/380-383, case 'd' at 368,382-383)` `F5` `F19` `F123` `F138` `F152`
- panelCommand also maps 'c' to .copySelection. `FloodlightPanel.swift:369-371` `F121` `F136`
- FloodlightTextField maps Return to submit, Command-Return to commandSubmit, and Option-Return to copySelection. `FloodlightTextField.swift:38-46,42-43` `F106` `F136`
- The SearchView footer button (labeled "Actions", showing a Command-K glyph) calls model.copySelection(), which is actually bound to Command-C, not Command-K. `SearchView.swift:501-518 (button call at 502-503)` `F106` `F127` `F136`
- SearchCoordinator.copySelection routes through actionPerformer.copy(item). `SearchCoordinator.swift:410-413` `F136`
- FloodlightPanel maps "\r"/"r" under .command to .revealSelection; revealSelection's implementation guards on `let url = item.fileURL, url.isFileURL else { return }`, so it silently no-ops when fileURL is nil. `FloodlightPanel.swift:375-379; SelectedResultActionPerformer.swift:203-207` `F135`
- filterShortcutIndex gates on (1...5).contains(digit), so Command+5 is the last valid filter shortcut and Command+6-9 are unbound, while commandDigit itself accepts the full 0-9 range. `FloodlightPanel.swift:431-447` `F129`
- Command+digit maps to model.selectFilter(options[index].filter). `FloodlightPanel.swift:320-324` `F132`
- docs/src/content/docs/guides/keyboard-shortcuts.mdx documents Command-C, Command-R, Command-Y, Command-L, Shift-Command-R, and the filter digits, but omits Command-Period and Command-D. `docs/src/content/docs/guides/keyboard-shortcuts.mdx` `F106`

### Preview and Space-key behavior

- FloodlightPanel evaluates model.previewableSelectionURL eagerly on every Space keypress, before the shouldHandleSpaceAsPreview / empty-query guard runs — so the file is materialized on every Space press regardless of outcome. `FloodlightPanel.swift:291-295,294; guard implementation at 449-457` `F19` `F2` `F41` `F119-accuracy`
- previewableSelectionURL creates a temp directory and writes image data only if the file doesn't already exist. `SearchCoordinator.swift:448-450` `F41` `F167`
- FloodlightPanel.togglePreview calls model.previewableSelectionURL a second time, repeating the same blob read/write for the intentional preview action. `FloodlightPanel.swift:231-234` `F41` `F168`

### Engine-side .app filtering and Rust/Swift boundary

- FFFIndex filters out results whose relative path traverses a .app bundle by checking lowercased path components for a ".app" suffix (split/dropLast/lowercased per component), applied in Swift after the FFI layer has already truncated/paged the native results. `FFFIndex.swift:147-153,222,223-227,279,280-284` `U1` `F20` `U12` `U14`
- FFFIndex has four separate search entry points, and all four independently perform this same .app-bundle filter. `FFFIndex.swift:151,223` `F20`
- searchDirectories intentionally omits dropLast() in its path-component check, so a directory whose own last component is literally "Foo.app" is filtered out too. `FFFIndex.swift:280-284` `U7`
- Floodlight shows at most 16 content matches within a 35ms search budget, leaving 512MB of retained mappings largely unused in the background menu-bar process. `SearchCoordinator.swift` `F30`
- SearchCoordinator.swift:596 filters only the already-paged candidate set — tens of items (12 apps, 24 settings, 12 files) — not thousands. `SearchCoordinator.swift:596` `F4-value`
- query_tracker.rs:354 filters get_last_query_entry on open_count >= min_combo_count; Floodlight passes 3 for that threshold. `query_tracker.rs:354` `U3`
- Floodlight tracks query strings at selection time only, not intermediate typed prefixes. `FFFIndex.swift:433-449` `U6`
- build_bigram_index runs on the background thread pool without holding the picker's read lock, which allows FileItem state mutations from watcher events to race with it. `bigram_filter.rs:842-847,834-838` `U54`

### Panel window and lifecycle

- FloodlightPanel.hide() calls model.reset(), which sets mode = .local and publication = idleLocalPublication() (visibleRows empty, selectedFilter: .all), tearing down the results subtree for the session. `FloodlightPanel.swift:206-211; SearchCoordinator.swift:252-261,614,618` `F77` `F124` `F132`
- An NSApplication.didResignActiveNotification observer on FloodlightPanel dismisses the panel when the app deactivates. `FloodlightPanel.swift:77-87` `F124`
- FloodlightPanel.observeQueryForPanelHeight fires on every query change and runs a 0.16s NSAnimationContext panel.animator().setFrame animation. `FloodlightPanel.swift:238-275` `F77`
- SearchView's gate at line 182 blocks the Divider (183), SearchFilterBar, and resultsContent together while idle, rather than gating them separately. `SearchView.swift:182-228` `F77`
- resultHeight depends on showsFilterBar, so filter-bar presence must not flip layout on the first keystroke. `SearchView.swift:184-186,199-204` `F77`
- SearchFilterBar uses .scrollClipDisabled(), which requires .clipShape and .accessibilityHidden together to achieve a zero-height mount. `SearchView.swift:21-26,282` `F77`
- ResultRow computes its background opacity with 8-way conditional logic based on selection, hover, and topHit state. `ResultRow.swift:124-139` `UI Cluster`
- ResultShowcase.isTopHit(index:resultCount:filter:) returns true only when index==0 AND resultCount>0 AND filter==.all. `ResultShowcase.swift:15-17` `UI Cluster`
- isTopHit has a single live call site (SearchView.swift:415) and would be flagged production-dead by Periphery (exclude_tests: true, strict: true) if inlined there. `ResultShowcase.swift:15-17; SearchView.swift:415; tools/.periphery.yml` `F82`
- SearchView's LazyVStack renders only the visible rows, not the full projection. `SearchView.swift:385` `F77` `F79`
- FloodlightMetrics.maximumVisibleResults is 7 rows — the only count ever shown to the user despite the pipeline processing up to 1,000 rows upstream. `SearchResultProjection.swift context` `F26`

### Architecture notes and dead-code checks

- ADR 0002 defines "Result Publication," separating source search (in the engine) from projection (in the shell). `CONTEXT.md:10` `Documentation & Architecture cluster`
- clearHistory has exactly three references in the codebase: its definition and two test-only call sites. `SearchCoordinator.swift:639` `F4`
- SearchCoordinator.applyResults does not exist anywhere in the codebase (0 ripgrep hits). `rg applyResults — 0 hits` `F153`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| maxResultsLimit (immediate/local-mode result cap) | 80 items | `SearchResultProjection.swift:436,465-467` |
| FloodlightMetrics.maximumVisibleResults | 7 rows shown to user | `SearchResultProjection.swift context` |
| Cold-start synchronous row load | 1000 rows with thumbnails, on main thread | `SearchCoordinator.swift:201-205; AppDelegate.swift:35` |
| Content-match display cap / search budget / retained mappings | 16 matches max, 35ms budget, 512MB retained mappings | `SearchCoordinator.swift` |
| filterShortcutIndex valid range | Command+1 through Command+5 only; Command+6-9 unbound | `FloodlightPanel.swift:431-447` |
| commandDigit accepted range | 0-9 | `FloodlightPanel.swift:431-440` |
| SearchFilterCounts fields | 8 Ints (flat struct with subscript) | `SearchItem.swift` |
| clearHistory reference count | 3 (1 definition + 2 test-only) | `SearchCoordinator.swift:639` |
| publication assignment sites in SearchCoordinator | 12 sites | `SearchCoordinator.swift:138,234,260,319,337,349,364,397,515,527,556,577,663` |
| buildLocalRows dedup list size | ~60 rows | `SearchResultProjection.swift:459-460` |
| buildLocalRows calls per keystroke | up to 4 | `SearchResultProjection.swift:143; SearchCoordinator.swift:527,556` |
| SearchCoordinator.swift:596 filtered candidate set (corrected) | tens of items: 12 apps, 24 settings, 12 files — not ~1,500/~3,000 | `SearchCoordinator.swift:596` |
| query_tracker.rs min_combo_count threshold passed by Floodlight | 3 | `query_tracker.rs:354` |
| FFFIndex search entry points performing .app filter | 4 | `FFFIndex.swift:151,223` |
| formattedRelativeTime call sites | 3 (lines 287, 316, 375) | `SearchResultProjection.swift:287,316,375` |
| Panel resize animation duration | 0.16s (NSAnimationContext) | `FloodlightPanel.swift:238-275` |
| previewTitle text size handled | up to 32KB | `SearchResultProjection.swift:396-401` |
| Filter chip counts | 4 always-visible (All, Apps, Files, Folders) + 4 dynamic (Settings, PDFs, Images, Documents) | `filters.mdx` |
| SearchCoordinator.applyResults hit count | 0 (method does not exist) | `rg applyResults` |

### Gotchas

- The footer button labeled "Actions" shows a Command-K glyph but actually calls copySelection, which is bound to Command-C — the displayed shortcut does not match the real binding. `SearchView.swift:501-518`
- "Show in Finder" reveals the current selection, not the item the context menu was opened on. `SearchView.swift:440`
- Plain URL text rows never get a fileURL, so Command+Return (reveal) is a silent no-op on link rows with no error or feedback. `SearchResultProjection.swift:329-338; SelectedResultActionPerformer.swift:203-207`
- Icon selection re-runs parseURL/parseHexColor/parseCodeHint a second time purely to pick a glyph, discarding classification work already done earlier in the same row-build pass. `SearchResultProjection.swift:320-325`
- Pinned rows still pay the full parseLocalPath+fileExists cost even though their icon is short-circuited to a fixed pin glyph afterward — the pin icon also overwrites the type icon (photo/video/inferred), losing the type affordance. `SearchResultProjection.swift:282,290-291,299,309,318`
- Keyboard shortcuts Command-Period (togglePin) and Command-D (deleteSelection, no confirmation) exist and work but are absent from the shipped keyboard-shortcuts documentation. `FloodlightPanel.swift:365-383; docs/src/content/docs/guides/keyboard-shortcuts.mdx`
- clearHistory is only ever called from tests, never from production code paths, despite being a real, working method. `SearchCoordinator.swift:639`
- ResultShowcase.isTopHit has exactly one live call site and the project's strict Periphery config would flag it as dead code if that call were inlined — a working, load-bearing function sitting one refactor away from a lint failure. `ResultShowcase.swift:15-17; SearchView.swift:415; tools/.periphery.yml`
- SearchResultPublication conforms to Equatable but nothing in the codebase ever calls that comparison — the conformance is dead weight, not a change-detection optimization. `SearchResultProjection.swift:4`
- FloodlightPanel evaluates previewableSelectionURL (which can write files to a temp directory) on every Space keypress before checking whether a preview should even happen. `FloodlightPanel.swift:291-295,449-457`

### Corrected on review

- ~~The same result-filtering predicate is applied a third time over merged candidates, roughly 3,000 calls.~~ → SearchCoordinator.swift:596 filters only the already-paged candidate set — tens of items (12 apps, 24 settings, 12 files), not ~1,500 or more. `SearchCoordinator.swift:596`
- ~~The dedup Set in SearchResultProjection is redundant and should be removed.~~ → The dedup at SearchResultProjection.swift:467 is required for correctness, as confirmed by explicit tests at SearchCoordinatorStressTests.swift:330 and SearchCoordinatorIntegrationTestsResults.swift:131. `SearchResultProjection.swift:467; Tests/FloodlightTests/SearchCoordinatorStressTests.swift:330`
- ~~Running two projections per keystroke is redundant work that could be deduplicated.~~ → The two projections operate on different source-candidate sets and cannot be merged; removing the stale-while-revalidate pre-projection would reintroduce a documented list-collapse regression. `SearchCoordinator.swift:519-526`
- ~~Splitting SearchCoordinator's single @Observable property into finer-grained properties would remove ForEach re-diff cost.~~ → ResultList reads model.selectedID directly in its builders, and ResultRow's @Equatable only stops leaf-view bodies — a selection change re-runs ResultList regardless of how finely the observable state is split. `SearchView.swift:414,417,423,459`
- ~~SearchResultPublication.selecting retains/releases up to 80 SearchItems twice on every selection change.~~ → selecting(_:) copies four Swift arrays, which are four O(1) copy-on-write buffer refcount bumps, not per-element retain/release. `SearchResultProjection.swift:13-23`
- ~~The Divider in SearchView would need its own separate height-gating logic.~~ → SearchView.swift:182 already gates the Divider (line 183), SearchFilterBar, and resultsContent together as one group while idle. `SearchView.swift:182-228`
- ~~SearchFilterOption is not Equatable.~~ → SearchFilterOption is Equatable. `SearchItem.swift:197`
- ~~A selection change invalidates the filter bar only through the projection pipeline.~~ → SearchCoordinator.moveSelection(by:) and select(_:) directly reassign publication = publication.selecting(), replacing the whole struct — including filterOptions — even when only the selection changed. `SearchCoordinator.swift:337,349`
- ~~There is no visual pin indicator for pinned entries.~~ → SearchResultProjection swaps the row icon to an orange pin.fill for pinned entries. `SearchResultProjection.swift:290-291,318`
- ~~SearchCoordinator.applyResults offenders exist in the code.~~ → SearchCoordinator.applyResults does not exist anywhere in the codebase (0 ripgrep hits). `rg applyResults — 0 hits`

<a id="swift-clipboard"></a>
## Floodlight: clipboard capture, SQLite store, inspector

Floodlight's clipboard feature polls NSPasteboard every 0.5 seconds on the main thread, routes captured content as files, then images, then text, and stores entries in a SQLite database (WAL journal mode) with an FTS5 index, backed by an in-memory window of up to 1,000 recent entries plus all pinned entries. Text is capped at 32,000 bytes and images at 15 MB per format; both PNG and TIFF are stored for every image, so one image entry can use up to 30 MB on disk. Retention is time-based only (default 30 days) and is enforced by a single prune pass at app launch, not on a recurring schedule — and choosing "Forever" retention does not actually disable the 30-day cutoff. The clipboard-mode UI (SearchResultProjection, ClipboardInspector, ClipboardInspectorPane, SearchCoordinator.clipboardInspector) re-parses and re-classifies clipboard text on every keystroke and re-reads the full image blob from SQLite on every render of the detail pane, because none of these paths cache their output. Several user-facing actions behave differently than their labels suggest: the default "paste" action only writes the pasteboard and dismisses (no synthetic Cmd+V is sent), the footer names the source app rather than the paste destination, and the image row's copy action actually copies the display-title text rather than the image payload.

### Components

- The clipboard-history feature is made up of ClipboardHistoryStore, ClipboardHistorySQLite, ClipboardEntry, ClipboardCaptureService, ClipboardImageCapture, ClipboardExclusionStore, and ClipboardInspectorPane. `CONTEXT.md:70` `K744`

### App launch and store initialization

- AppDelegate.applicationDidFinishLaunching runs, in order and synchronously: setActivationPolicy, installMenu, installStatusItem, installGlobalHotKey, then LaunchAtLogin.enableOnFirstRun, then clipboardCapture.start(), then presentation.launch(). `AppDelegate.swift:30-37` `K350` `K784`
- clipboardCapture.start() forces the lazy `model` property (a SearchCoordinator) to construct synchronously on the main thread, before presentation.launch() runs. `AppDelegate.swift:19-20,36` `K351`
- SearchCoordinator's convenience init synchronously reads UserDefaults, creates the Application Support directory, loads RecentStore and BlocklistStore via JSONDecoder, and inits ApplicationCatalog and FFFIndex (two realpath syscalls) — all on the main thread. `SearchCoordinator.swift:158-210` `K352`
- SearchCoordinator's convenience init opens ClipboardHistoryStore with sqlite3_open_v2, sets the WAL pragma, runs CREATE TABLE/INDEX/FTS5, runs 7 ALTER TABLE statements, and drops-and-recreates 3 triggers, all synchronously at launch. `SearchCoordinator.swift:158-210,162-184` `K352` `K788`
- SearchCoordinator's convenience init then calls loadInitialWindow (up to 1,000 rows plus all pinned rows) and a COUNT query, synchronously at launch. `SearchCoordinator.swift:158-210` `K352`
- ClipboardHistoryStore.init() calls ClipboardHistorySQLite.loadInitialWindow() at startup to populate the pinned and recent in-memory arrays from disk. `Sources/FloodlightEngine/Utilities/ClipboardHistoryStore.swift:54-80` `K71`
- clipboardCapture.start() also calls pruneOnSchedule() and installs the run-loop polling timer, both at launch. `AppDelegate.swift:37; ClipboardCaptureService.swift:176` `K787` `K365`
- The clipboard-capture enable flag defaults to true when UserDefaults has no stored value. `ClipboardCaptureService.swift:141-144` `K510`
- AppDelegate calls clipboardCapture.start() before OnboardingSession.shouldPresent() is checked, so clipboard recording begins before onboarding/setup is shown. `AppDelegate.swift:36` `K510` `K524`
- OnboardingSession, on init, opens the real clipboard database at ~/Library/Application Support/Floodlight/clipboard.sqlite3 by default, not a sandboxed test database. `OnboardingSession.swift:97-100; ClipboardHistoryStore.swift:36-52` `K735`

### Capture loop: polling and pasteboard reading

- ClipboardCaptureService is @MainActor; poll() runs via Timer.scheduledTimer on RunLoop.main in .common mode, repeating forever at a 0.5-second interval with 0.2-second tolerance. `ClipboardCaptureService.swift:103,172-185,178-184` `K84` `K85` `K367` `K409` `K410` `K444` `K645` `K691` `K722` `K813` `K814`
- At roughly 2 polls per second, the timer fires about 172,800 times per day, regardless of whether capture is enabled. `0.5s interval x 86,400s/day x 2` `K477` `K818`
- The only pause condition for polling is NSWorkspace's sessionDidResignActive/sessionDidBecomeActive notifications (fast user switching); screen lock and sleep do not pause it. `ClipboardCaptureService.swift:172-207,188-189` `K89` `K815`
- Each poll tick calls pasteboard.changeCount (a mach round trip to the pasteboard server) and reads the isEnabled flag from UserDefaults inside the handler; when disabled, only the pasteboard read/save is skipped — the timer itself keeps firing on schedule. `ClipboardCaptureService.swift:233,139-144,232-233` `K478` `K693` `K816` `K817`
- poll() runs the entire capture pipeline — decode, hash, and insert — synchronously on the main thread. `ClipboardCaptureService.swift:266-276` `K441`
- The PasteboardObserving protocol exposes changeCount, types, string(forType:), filePaths(), pngData(), and tiffData(), with no accessor for .rtf, .rtfd, or .html. `ClipboardCaptureService.swift:6-14` `K378`
- poll() reads only the .string pasteboard flavor; .rtf, .html, and public.url representations are discarded. `ClipboardCaptureService.swift:279-280` `K379` `K512` `K550`
- poll() routes captured content in priority order: files, then image, then text — a pasteboard carrying a TIFF is captured as an image before text is even considered. `ClipboardCaptureService.swift:258-280` `K466` `K547`
- For a multi-file copy, poll() calls recordFile once per path, sequentially within a single tick; there is no cap on how many paths one pasteboard can contribute. `ClipboardCaptureService.swift:258-263` `K473` `K534` `K829` `K476` `K831`
- ClipboardFileReference performs static path canonicalization and per-file deduplication during capture. `ClipboardCaptureService.swift:258` `K151`
- Each recordFile call takes the store lock, runs sqlite3_prepare_v2, commits a WAL implicit transaction, and performs an O(n) array insert. `ClipboardCaptureService.swift:258-263` `K830`
- poll() filters captured content against ClipboardExclusionStore using an O(1) Set.contains check on the frontmost app's bundle identifier. `ClipboardCaptureService.swift:254` `K86`
- Captured entries are stamped with sourceAppBundleID, and poll() skips entries stamped floodlightOwnWrite — pasteboard writes Floodlight itself made. `ClipboardCaptureService.swift:242,253; SelectedResultActionPerformer.swift:44` `K535`
- ClipboardExclusionStore is @unchecked Sendable, guarded by an OSAllocatedUnfairLock, and loads/persists via JSONDecoder/JSONEncoder against UserDefaults. `ClipboardExclusionStore.swift:4,11-16,44-52` `K130` `K131`
- ClipboardExclusionStore starts with an empty exclusion list and matches bundle IDs by exact string equality after trimming whitespace. `ClipboardExclusionStore.swift:16,44` `K511`
- Text entries are deduplicated only against the single most-recent entry (by text and kind), not the full history, using a full String comparison of up to 32 KB per captured entry. `ClipboardHistoryStore.swift:292-294` `K88` `K500` `K492` `K493`
- The same most-recent-entry dedup logic is separately duplicated inside the recordImage function rather than shared. `ClipboardHistoryStore.swift:203-204` `K495`

### Image capture and thumbnails

- ClipboardImageCapture caps PNG/TIFF decoding at maxImageByteCount (15 MB = 15 x 1024 x 1024 bytes) before generating a thumbnail. `ClipboardImageCapture.swift:19-35` `K146` `K723` `K561` `K504`
- Both PNG and TIFF representations of the same image are captured (ClipboardImageCapture.payload) and stored as separate blobs in the same row (PNG at bind index 11, TIFF at index 12). `ClipboardImageCapture.swift:20-21; ClipboardHistorySQLite.swift:247-248` `K801` `K741` `K802`
- Reported thumbnail dimensions conflict across the codebase: some evidence cites 64x128 px for the NSBitmapImageRep/NSGraphicsContext draw step, other evidence cites 128x128 px for what appears to be the same step. `ClipboardImageCapture.swift:60-107,19-35 (64x128) vs. ClipboardImageCapture.swift:52-106,61,94-106 (128x128)` `K87` `K146` `K442` `K647` `K724` `K795`
- Thumbnail generation saves and restores NSGraphicsContext state around the scaled-image drawing call. `ClipboardImageCapture.swift:94-104` `K147`
- Resulting thumbnail PNGs are typically 10-40 KB each and stay resident in memory for the process lifetime. `ClipboardImageCapture.swift:61; ClipboardHistorySQLite.swift:154` `K795`
- ClipboardImageCapture is @MainActor and decodes images up to the 15 MB cap on the main thread during poll(). `ClipboardCaptureService.swift:266` `K646`
- Because both PNG and TIFF are stored, a single clipboard image can consume up to 2x maxImageByteCount, i.e. up to 30 MB on disk. `ClipboardHistorySQLite.swift:186-188,247-248` `K514` `K803`

### On-disk storage: SQLite schema and limits

- ClipboardHistorySQLite opens the database with PRAGMA journal_mode = WAL and PRAGMA synchronous = NORMAL. `ClipboardHistorySQLite.swift:15-16` `K725`
- initializeSchema runs unconditionally on every database open, on the main thread. `ClipboardHistorySQLite.swift:50-52; AppDelegate.swift:35` `K482`
- Clipboard text entries are capped at maxTextByteCount = 32,000 UTF-8 bytes; larger copies are silently dropped with no logging or user notification. `ClipboardHistorySQLite.swift:281,285` `K407` `K513` `K581` `K833`
- The store has no entry-count cap and no total byte-size budget; only time-based retention applies, defaulting to 30 days. `ClipboardHistoryStore.swift:512-517; ClipboardCaptureService.swift:154-160` `K739`
- There is no VACUUM, no auto_vacuum pragma, and no wal_checkpoint configuration anywhere in the store (confirmed by an rg search with zero matches). `ClipboardHistorySQLite.swift:14-16` `K740` `K811`
- SQLite's default auto_vacuum=NONE means a DELETE only marks pages free without shrinking the database file. `ClipboardHistoryStore.swift:503-505` `K812`
- Bind parameters are converted with (x as NSString).utf8String, which allocates an autoreleased NSString per bind call. `ClipboardHistoryStore.swift:317-323` `K455`
- OnboardingSession.clearClipboardHistory() calls clipboardStore.clear(), which executes DELETE FROM clipboard_entries. `OnboardingSession.swift:143; ClipboardHistoryStore.swift:503` `K738`

### In-memory cache and search

- inMemoryRecentWindowLimit is 1,000 rows; loadInitialWindow eagerly materializes up to 1,000 recent entries plus all pinned entries into recentEntries at startup. `ClipboardHistoryStore.swift:10,62-93,350` `K408` `K496` `K583` `K794` `K566`
- An empty clipboard query returns pinnedEntries + recentEntries up to the 1,000-row in-memory limit, built by array concatenation. `ClipboardHistoryStore.swift:349-351` `K436` `K480` `K506` `K630`
- 1- and 2-character clipboard queries search only the in-memory recent window, not the full history. `ClipboardHistoryStore.swift:353-360` `K507`
- The 2-character search case runs localizedCaseInsensitiveContains (locale-aware Unicode folding) over up to 1,000 cached entries, each up to 32 KB. `ClipboardHistoryStore.swift:405-409` `K521`
- FTS5 full-text search results are capped at searchResultLimit = 200 rows with no truncation indicator shown to the user. `ClipboardHistoryStore.swift:366-376` `K726` `K508`
- search(query:) matches only entry.text; there is no FTS5 index on source_app_bundle_id. `ClipboardHistoryStore.swift:343` `K567` `K568`
- insert(at: 0) memmoves the entire recentEntries buffer — up to 1,000 elements, always at capacity — on every recorded entry. `ClipboardHistoryStore.swift:331-333` `K475` `K494`

### Retention and pruning

- pruneOnSchedule() is called only once, from ClipboardCaptureService.start() at app launch, with no record of the last prune time and no periodic or background schedule. `ClipboardCaptureService.swift:176,287` `K365` `K469`
- prune() deletes rows WHERE pinned_at IS NULL AND created_at < cutoff, so pinning is the only way an entry survives retention pruning. `ClipboardHistoryStore.swift:512,516` `K565` `K754`
- prune runs on Task.detached at .utility priority but holds the store's stateLock through the entire DELETE FROM clipboard_entries query and the subsequent COUNT(*); it is the only place in the search path with an explicit TaskPriority. `ClipboardCaptureService.swift:287-291,516,525` `K366` `K470` `K823` `K710`
- Because prune runs from applicationDidFinishLaunching, the first clipboard search, entry lookup, and the first 0.5-second capture tick can block on the same lock prune holds; every deleted row also fires the clipboard_entries_ad FTS5 trigger. `ClipboardCaptureService.swift:287-291,516; AppDelegate.swift:36; ClipboardHistorySQLite.swift:235-244` `K824` `K825`
- The retention property's getter maps any non-positive stored value to days(30), overriding the stored "forever" sentinel (-1) — a user who selects Forever retention still has entries deleted after 30 days from the next launch onward. `ClipboardCaptureService.swift:154-169` `K461` `K462` `K546`

### Enable/disable and retention settings

- The capture-enabled flag and retention-days setting are read from and written to UserDefaults. `ClipboardCaptureService.swift:140-144,147,165,167` `K90`
- The capture store does not re-baseline lastChangeCount when capture is disabled, so turning capture off and back on backfills items that were copied while it was off. `ClipboardCaptureService.swift:232-242` `K498`
- OnboardingSession.clipboardHistoryEnabled writes directly to UserDefaults, bypassing the ClipboardCaptureService.isEnabled setter that would otherwise re-baseline lastChangeCount. `OnboardingSession.swift:49` `K527`
- OnboardingView's Clipboard History Settings section includes an enable/disable toggle, a retention-days control, an excluded-app bundle-ID list, and a Clear-history button. `OnboardingView.swift:281-395` `K755`

### Search-to-UI projection pipeline (per keystroke)

- publishClipboardModeResults / scheduleSearch calls ClipboardHistoryStore.search synchronously on the main actor on every keystroke, with no debounce and no background task. `SearchCoordinator.swift:503-508,657,666` `K445` `K446` `K631` `K686`
- projectClipboard maps over up to 1,000 entries (the empty-query case) via enumerated().map, calling buildClipboardRow / previewTitle and full classification per row, per keystroke, on the main actor. `SearchResultProjection.swift:196-198` `K383` `K505` `K582` `K797`
- publishClipboardModeResults only republishes on query change, mode entry, or a pin/delete mutation — it does not observe the store during real-time clipboard activity, so the list does not refresh if a copy lands while the panel is open in clipboard mode. `SearchCoordinator.swift:503-506,657-680` `K543` `K846` `K847`
- Clipboard-mode projection builds up to 1,000 SearchItems, filters them, then walks them again to compute filter-option counts, with no cap until an 80-row display limit. `SearchResultProjection.swift:196-299, line 436` `K798`
- parseCodeHint trims the text and, if it starts with { or [, runs JSONSerialization.jsonObject over the entire body (up to the 32,000-byte maxTextByteCount) as Data, allocating a trimmed copy of the whole entry. `ClipboardInspector.swift:272-298,272-279` `K385` `K519` `K627` `K633` `K832`
- After the JSON parse attempt, parseCodeHint makes 7 further `contains` scans of the same string. `ClipboardInspector.swift:272-298` `K386`
- parseCodeHint recognizes exactly 3 language values: JSON, Code, HTML. `ClipboardInspector.swift:272-298` `K423`
- buildClipboardTextRow calls parseCodeHint, parseURL, and parseHexColor for every text row on every keystroke on the main actor; parseURL and parseHexColor each also trim the string, for 3 total string trims per row. `SearchResultProjection.swift:320-325,282,322,324` `K387` `K580` `K834`
- ClipboardInspector.snapshot separately re-runs parseCodeHint, parseURL, and parseHexColor on the selected row again, for icon classification. `ClipboardInspector.swift (snapshot)` `K835`
- buildClipboardTextRow / projection calls FileManager.default.fileExists (a blocking stat(2)) on the main thread for every text row that parses as a local path, on every keystroke. `SearchResultProjection.swift:282-299` `K520` `K584` `K632` `K799`
- previewTitle splits clipboard text on newlines, rejoins, and trims whitespace to build the row title. `SearchResultProjection.swift:397-400` `K579`
- Text rows get a subtitle combining source app and relative time; file rows carry the full absolute path as their subtitle. `SearchResultProjection.swift:315-317,354` `K398` `K419`
- A detected URL in clipboard text is bound to action .copy(text), and fileURL stays nil for URL-typed entries, so revealSelection() no-ops on clipboard links. `SearchResultProjection.swift:329` `K551` `K552`
- The row's app display name is derived by taking only the last dot-separated component of the bundle ID, while ClipboardInspector separately resolves the full app name via NSWorkspace.urlForApplication — two different resolution paths for the same bundle ID. `SearchResultProjection.swift:403-406; ClipboardInspector.swift:360-369` `K420` `K526`
- A multi-file copy is recorded as N separate clipboard entries, one per file path, each bound to a single-file action. `ClipboardCaptureService.swift:258; SearchResultProjection.swift:356` `K501`
- Pinned entries get their title prefixed with an emoji; VoiceOver reads this emoji aloud as part of the item name. `SearchResultProjection.swift:285` `K518`
- Row drag-out sends item.title — which includes the pin-emoji prefix and has newlines collapsed — rather than the actual copied text from item.action. `SearchView.swift:450; SearchResultProjection.swift:285,396-401` `K532`
- Every clipboard text and image row sets modifiedAt to entry.createdAt, so every row in clipboard mode pays the date-formatting cost. `SearchResultProjection.swift:309,337` `K851`
- SearchItem's synthesized Equatable compares action (which can hold up to 32 KB of clipboard text) and iconSource (PNG Data); ResultRow's equality check therefore triggers a full clipboard-payload comparison on every row diff. `SearchItem.swift:268; ResultRow.swift:27-28` `K605` `K606`

### Inspector snapshot and detail-pane rendering

- SearchCoordinator.clipboardInspector is an uncached computed property, read at least twice per SwiftUI body pass — once by ClipboardInspectorPane and once by the footer's targetAppName — and re-evaluated on every arrow-key press while in Clipboard mode. `SearchCoordinator.swift:647-654; SearchView.swift:220,470` `K380` `K381` `K435` `K502` `K559` `K560` `K628` `K629` `K791`
- Each clipboardInspector evaluation calls clipboardStore.entry(id:), which takes the store's OSAllocatedUnfairLock and does a linear scan over up to 1,000 cached entries. `SearchCoordinator.swift:652` `K623`
- clipboardInspector then calls clipboardStore.imageData(for:), which reads the full PNG blob (up to 15 MB) from SQLite and decodes it to NSImage on the main thread. `SearchCoordinator.swift:653; ClipboardInspectorPane.swift:145` `K437` `K503` `K624` `K792` `K808`
- ClipboardInspector.snapshot(for:imagePNG:), at lines 94-187, is the main entry point that turns a ClipboardEntry into a typed snapshot. `ClipboardInspector.swift:94-187` `K72`
- ClipboardInspector.snapshot calls FileManager.fileExists and url.resourceValues synchronously. `ClipboardInspector.swift:152,159` `K626`
- sourceAppDisplayName / snapshot calls NSWorkspace.shared.urlForApplication(withBundleIdentifier:) synchronously on the main actor — an IPC round trip to lsd. `ClipboardInspector.swift:360-365,362` `K563` `K625` `K793` `K848`
- formattedDetailedDate creates one or two DateFormatter instances per snapshot call, uncached. `ClipboardInspector.swift:310-325,312,321` `K73` `K425` `K562`
- The detailed date's time format is hardcoded as HH:mm:ss, ignoring locale and the device's 12/24-hour preference. `ClipboardInspector.swift:313` `K426`
- fileByteCount() calls url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]). `ClipboardInspector.swift:354-357` `K75`
- imageFormatName ignores its width/height parameters and always returns the PNG constant, regardless of actual format. `ClipboardInspector.swift:327-328` `K397`
- ClipboardInspector rebuilds an imageExtensions literal (13 strings) and a videoExtensions literal (11 strings) on every call, rather than caching them. `ClipboardInspector.swift:218-225` `K427` `K428`
- SVG is classified as an image by ClipboardInspector but not by FileThumbnailCache's thumbnail generator, an inconsistency between the two. `ClipboardInspector vs FileThumbnailCache` `K429`
- ClipboardInspectorPane decodes NSImage(data: detail.previewPNG) on every render when there is no local cache, for a payload that can be up to 15 MB, on the main thread. `ClipboardInspectorPane.swift:145` `K76` `K807`
- Decoding a 6016x3384 screenshot creates roughly an 80 MB RGBA backing bitmap on the main thread. `ClipboardInspectorPane.swift:145, macOS bitmap math` `K809`
- ClipboardInspectorPane frames the decoded screenshot to maxWidth: .infinity, maxHeight: 180 points. `ClipboardInspectorPane.swift:149` `K810`
- AppIconCache.shared.icon(for:) supplies the app icon shown in the inspector. `ClipboardInspectorPane.swift:245` `K77` `K421`
- FileThumbnailCache.shared.cachedThumbnail(for:) does a synchronous in-memory lookup, while FileThumbnailCache.shared.thumbnail(for:) generates and caches asynchronously. `ClipboardInspectorPane.swift:296,299` `K78` `K79`
- Code preview renders in font size 11.5, weight regular, monospaced design, with no lineLimit; the .text case also has no lineLimit; the .link case caps at lineLimit(6). `ClipboardInspectorPane.swift:99-114,111,121-126,67` `K424` `K388` `K389` `K390`
- ClipboardInspectorPane sets .textSelection(.enabled), forcing a selectable TextKit backing store. `ClipboardInspectorPane.swift:126` `K391`
- ResultRow decodes clipboard thumbnails via NSImage(data:) inline in body, with no caching, on every body evaluation. `ResultRow.swift:194-197` `K804` `K607`
- SwiftUI re-evaluates ResultRow's body on selection change, hover, and publication, causing redundant thumbnail decodes. `ResultRow.swift:190-197` `K806`

### User actions: copy, paste, drag, exclude

- SelectedResultActionPerformer.writeToClipboard writes only the public.utf8-plain-text flavor, via writeString. `SelectedResultActionPerformer.swift:30-45` `K392`
- activate() (the default Return action) only calls writeToClipboard and dismisses — it does not synthesize a Command+V keystroke, so nothing is actually pasted into the target app. `SelectedResultActionPerformer.swift:156-163` `K401` `K488` `K517`
- The footer's "Paste to <app>" button names the source app (the app the entry was copied FROM), not the destination/paste target. `SearchView.swift:469-470,481-487` `K487` `K400`
- Return on a clipboard URL row copies the URL text instead of opening it. `SelectedResultActionPerformer.swift:157-163` `K422`
- writeImage restores both PNG and TIFF representations back onto the pasteboard. `SelectedResultActionPerformer.swift:64-77` `K491`
- copyImage actually copies item.title (text) instead of the image payload; writeImageDataToClipboard exists but is never called for image rows, so "copy" on an image row does not copy the image itself. `SelectedResultActionPerformer.swift:246,13` `K553` `K554`
- excludeFromSearch for a clipboard item calls blocklistStore.block with the clipboard entry's title, poisoning the unrelated local file-search blocklist. `SearchCoordinator.swift:391` `K529`
- excludeFromSearch then calls projectLocal with empty updatedCandidates, replacing the clipboard-mode results with local-search results while the coordinator is still in clipboard mode. `SearchCoordinator.swift:391-400; SearchResultProjection.swift:205` `K530`
- clipboardImagePreviewURL (invoked on Space/QuickLook) writes up to a 15 MB blob to NSTemporaryDirectory()/FloodlightClipboardPreviews/<id>.<ext>; these files are never deleted. `SearchCoordinator.swift:435-459,449-457` `K464` `K465` `K509` `K839` `K840`
- model.previewableSelectionURL is evaluated unconditionally on every Space keypress regardless of clipboard mode or query state. `FloodlightPanel.swift:290-293` `K837` `K838`

### Keyboard shortcuts and mode entry

- Clipboard mode is entered only by typing "clip" then pressing Tab; "clip" is not registered as a KeywordEngine, so it produces no ranked row and no tab-completion hint while typing. `SearchMode.swift:92` `K515`
- Entering clipboard mode hard-codes the selection filter to "all" (applyModeEvent), and reset() discards clipboard mode's filter state on every dismissal. `SearchCoordinator.swift:321,252` `K528`
- SearchItem.clipboard defines exactly 4 filters: all, text, files, and images. `SearchItem.swift:68` `K539`
- Command+period toggles pin, and Command+D deletes the selection, both gated on isClipboardMode. `FloodlightPanel.swift:345-351,380-383` `K752` `K753`
- FloodlightPanel's commandDigit check treats Command+1 through Command+9 as consumed, so Command+5 through Command+9 — which have no filter binding in clipboard mode — are still swallowed and never reach the text field. `FloodlightPanel.swift:319-325` `K538`

### Capture loop: polling and routing

- ClipboardCaptureService.poll is a MainActor method that runs the full capture path synchronously: image decode, thumbnail PNG re-encode, sha256Hex, and the SQLite insert. `ClipboardCaptureService.swift:103,232,266` `F42` `F72`
- ClipboardCaptureService.start() arms a 0.5-second repeating Timer on RunLoop.main in .common mode with 0.2-second tolerance, driving poll(). `ClipboardCaptureService.swift:172-207,178-186,129` `F42` `F66` `F91` `F92` `F97`
- At 0.5-second intervals the timer produces 172,800 idle wakeups per day even when nothing changes. `ClipboardCaptureService.swift:178-186,184` `F42`
- poll() early-exits when pasteboard changeCount is unchanged, so the decode/insert cost is paid only per actual image copy, not on every 0.5s tick. `ClipboardCaptureService.swift:237` `F72`
- poll() routes a captured item as files -> image -> text with early returns, trying ClipboardImageCapture.payload before the text branch. `ClipboardCaptureService.swift:258-284,266` `F91` `F99`
- poll() reads observer.string(forType:.string) for the text branch and records it via store.record(text:sourceAppBundleID:). `ClipboardCaptureService.swift:179-181,280-284` `F60` `F99`
- store.record(...) performs a synchronous SQLite INSERT plus an FTS5 trigram insert on the main thread under stateLock for every clipboard change, for text up to 32 KB. `ClipboardCaptureService.swift:283` `F60`
- Text length is enforced at the capture site with guard text.utf8.count <= maxTextByteCount inside poll(). `ClipboardCaptureService.swift:281` `F99`
- poll() loops observer.filePaths().compactMap(ClipboardFileReference.canonicalize) with no batching or transaction wrapping for multi-file copies. `ClipboardCaptureService.swift:258-264` `F92`
- filePaths() already canonicalizes paths via ClipboardFileReference.paths()/appendCanonicalPath, so poll()'s subsequent compactMap(canonicalize) call is redundant. `ClipboardCaptureService.swift:258,36-38,93-100` `F92`
- ClipboardCaptureService records the source app via NSWorkspace.shared.frontmostApplication.bundleIdentifier. `ClipboardCaptureService.swift:48-49` `F95`
- PasteboardObserving is MainActor-bound, so observer.pngData/tiffData reads must stay on the main thread and cannot be hopped off. `ClipboardCaptureService.swift:6,40-46` `F42`
- PasteboardObserving does not expose data(forType:) generically, and no RTF, RTFD, HTML, or NSAttributedString code path exists anywhere in Sources — AppKitPasteboardObserver only ever reads .string, .png, and .tiff, so rich text is always flattened to plain text. `ClipboardCaptureService.swift:6-14,32-46` `F99`
- ClipboardCaptureService.pause is bound to sessionDidResignActiveNotification (fast user switching), not to general app deactivation. `ClipboardCaptureService.swift:188-196` `F42`
- AppDelegate.swift:36 calls clipboardCapture.start() unconditionally; isEnabled is checked only inside poll() from UserDefaults, so the timer always runs regardless of the user's setting. `AppDelegate.swift:36; ClipboardCaptureService.swift:232-233,139-145` `F42`

### Enable/disable toggle and retention pruning

- poll() guards on isEnabled before reading pasteboard changeCount, so a disabled user pays only a coalesced runloop wakeup plus a UserDefaults lookup — no pasteboard IPC. `ClipboardCaptureService.swift:233-236` `F66`
- ClipboardCaptureService.isEnabled getter performs two UserDefaults calls per invocation, i.e. 4 lookups per second at the 2 Hz poll rate. `ClipboardCaptureService.swift:139-145,233` `F42` `F66`
- Those UserDefaults reads resolve via macOS's own cached CFPreferences layer (already effectively free at ~4/sec); adding a manual cache on top would reintroduce a staleness bug, since OnboardingSession writes the same key directly without notifying the service. `ClipboardCaptureService.swift:141-144; OnboardingSession.swift:43-49` `F72`
- isEnabled defaults to true when the UserDefaults key is unset, making disabled users a minority population. `ClipboardCaptureService.swift:141-143` `F66`
- ClipboardCaptureService.isEnabled's own setter (lines 146-151) has zero call sites; the real user-facing toggle is OnboardingSession.clipboardHistoryEnabled. `ClipboardCaptureService.swift:146-151; OnboardingSession.swift:40-51` `F66`
- OnboardingSession.clipboardHistoryEnabled writes the shared UserDefaults key directly without notifying ClipboardCaptureService — any future cached flag in the service would go permanently stale. `OnboardingSession.swift:40-51; ClipboardCaptureService.swift:146-151` `F66`
- pruneOnSchedule() is called unconditionally from ClipboardCaptureService.start() during AppDelegate.applicationDidFinishLaunching, once per app launch, on a detached utility task that reads the retention value and calls store.prune(retention:). `ClipboardCaptureService.swift:176,287-292; AppDelegate.swift:36` `F60` `F89`
- Any early return added to ClipboardCaptureService.start() must come after the pruneOnSchedule() call at line 176, or retention enforcement stops entirely for disabled users. `ClipboardCaptureService.swift:172-207` `F66`
- Default clipboard retention is 30 days. `ClipboardCaptureService.swift:159` `F60`
- ClipboardCaptureService.retention getter returns .days(30) for any non-positive stored integer, so the -1 sentinel meant to represent .forever can never be read back as .forever. `ClipboardCaptureService.swift:154-170,158` `F89`
- OnboardingView.swift:319 presents the stored value -1 to the user with the label "Forever", while ClipboardCaptureService.retention's getter silently decodes that same -1 as .days(30) — the UI and the enforcement logic disagree about what the sentinel means. `OnboardingView.swift:319; ClipboardCaptureService.swift:154-170` `F89`
- retentionDaysDefaultsKey is a single shared UserDefaults key read independently by OnboardingSession.clipboardRetentionDays and by ClipboardCaptureService.retention, each with its own decoding of the sentinel value. `OnboardingSession.swift:55-59; ClipboardCaptureService.swift:154-170` `F89`
- ClipboardCaptureService.retention's setter writes -1 for .forever, but has no caller anywhere in Sources/ — the .forever value is write-only dead code. `ClipboardCaptureService.swift:166-167` `F89`
- ClipboardHistoryStore.prune() SQL is DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < cutoff — pinned entries are exempt from retention deletion, so only unpinned entries older than the retention window are at risk. `ClipboardHistoryStore.swift:516` `F89`
- The prune operation holds stateLock for the entire DELETE FROM clipboard_entries plus the subsequent queryTotalCount call. `ClipboardHistoryStore.swift:512-527` `F60`
- Prune uses a plain DELETE statement with no VACUUM or page-return step, so deleted rows' pages are not reclaimed. `ClipboardHistoryStore.swift:512-527` `F96`
- On a same-day relaunch shortly after a previous launch, the prune DELETE matches zero rows and only performs an imperceptible index probe. `ClipboardHistorySQLite.swift:27; ClipboardHistoryStore.swift:516` `F60`

### Image capture: PNG/TIFF materialization and thumbnails

- ClipboardImageCapture.payload unconditionally fetches both capped(pngData()) and capped(tiffData()), forcing both lazy pasteboard representations to render before either is evaluated. `ClipboardImageCapture.swift:20-21,38` `F42` `F72` `F91` `F96`
- A full-screen screenshot's uncompressed TIFF is roughly 80 MB (6016x3384x4), read on the main thread only to be rejected by the capped() size check. `ClipboardImageCapture.swift:20-21,38` `F72`
- ClipboardImageCapture.capped nils out any representation over 15 MB, and decode nils out anything NSBitmapImageRep cannot parse. `ClipboardImageCapture.swift:37-42,51-58` `F72`
- payload uses png ?? tiff as the primary representation, falling back to TIFF only when PNG is absent or oversized; the helper checks only for non-empty data and never checks whether the pasteboard also carries text. `ClipboardImageCapture.swift:19-23,37-42` `F99` `F104`
- ClipboardImageCapture.displayName returns the literal string "TIFF Image" whenever hasPNG == false. `ClipboardImageCapture.swift:44-49` `F104`
- payload decodes the image via NSBitmapImageRep(data:) and renders a 128x128 thumbnail through NSGraphicsContext/NSBezierPath before PNG-encoding it, all on the main actor per image copy. `ClipboardImageCapture.swift:51-107,52,94-106` `F42` `F72`
- Thumbnails are fixed at 128x128 pixels (thumbnailPointSize 64, thumbnailScale 2), producing PNG files typically 5-15 KB each. `ClipboardImageCapture.swift:7-8,37-42,61` `F42` `F52` `F75` `F85`
- ClipboardHistorySQLite stores png_data and tiff_data as separate columns rather than one image column, and both blobs are bound into the clipboard_entries row on recordImage. `ClipboardHistorySQLite.swift:213-214; ClipboardHistoryStore.swift:246-248` `F96` `F104`
- maxImageByteCount = 15*1024*1024 is applied independently to the PNG and TIFF representations. `ClipboardHistoryStore.swift:9,189,244-246` `F42` `F96`
- For mid-size images TIFF is 5-20x the PNG size, so dropping the TIFF blob would cut the stored row by roughly 85-90 percent (not merely halve growth or cap it at 30 MB, as an earlier estimate assumed). `ClipboardHistoryStore.swift:9` `F96`
- recordImage deduplicates a newly captured image against state.recentEntries.first both when appending to the in-memory list (lines 200-203) and again in the SQLite insert path (lines 290-293). `ClipboardHistoryStore.swift:200-203,290-293` `F42`

### Storage engine: SQLite schema, locking, and connection handling

- ClipboardHistoryStore is an @unchecked Sendable final class guarded by a single OSAllocatedUnfairLock<State> around all SQLite connection access, and the database is separately opened with SQLITE_OPEN_FULLMUTEX — the mutex serializes SQLite's own internals but not the Swift-side array state, which the OSAllocatedUnfairLock protects instead. `ClipboardHistoryStore.swift:7,19-20,56` `F40` `F42` `F72`
- ClipboardHistorySQLite's entryColumns always include thumbnail_png, but the blob is copied via Data(bytes:count:) in readEntry() only for rows where kind == .image. `ClipboardHistorySQLite.swift:8-11,63,79,145,154,191-196` `F52` `F85`
- png_data and tiff_data are not part of entryColumns/the normal row read — they are fetched separately and lazily by ClipboardHistoryStore.imageData(for:) via SELECT png_data, tiff_data FROM clipboard_entries WHERE id = ?. `ClipboardHistoryStore.swift:263-266; ClipboardHistorySQLite.swift:8-11` `F99`
- ClipboardEntry deliberately keeps only the 64pt thumbnail resident for images; the full-resolution PNG/TIFF blobs are fetched on demand. `ClipboardEntry.swift:12-32` `F99`
- ClipboardEntry has no precomputed preview or hint field, and stores the full clipboard text rather than a truncated preview. `ClipboardEntry.swift:46-53,46-75` `F23` `F100`
- The FTS table is created with tokenize='trigram', enabling broad substring/prefix matches across all three indexed text columns. `ClipboardHistorySQLite.swift:30-34` `F5-accuracy` `F87`
- ClipboardHistorySQLite sets PRAGMA journal_mode = WAL and synchronous = NORMAL, but does not enable auto_vacuum. `ClipboardHistorySQLite.swift:15-16` `F96`
- Only two indexes exist — idx_clipboard_created_at(created_at DESC) and idx_clipboard_pinned_at(pinned_at ASC) — and neither provides a leading key for the ORDER BY pinned_at IS NOT NULL DESC expression search uses, forcing a temporary B-tree sort on every search query. `ClipboardHistorySQLite.swift:27-28; ClipboardHistoryStore.swift:365-371` `F87`
- That sort cost is bounded, not O(n log n) over full history: search() binds searchResultLimit (200) into the LIMIT clause, so the sorter retains at most 200 records, i.e. O(matches log 200). `ClipboardHistoryStore.swift:11,376` `F87`
- ClipboardHistoryStore.swift has 8 call sites that prepare and finalize a SQLite statement per call with no statement cache, and 9 call sites with an early return between sqlite3_step and sqlite3_finalize, risking unclosed statement handles under WAL mode. `ClipboardHistoryStore.swift:128-139,219-248,266-270,307-325,417-423,444-449,480-485,516-521,138,250,271,327,424,450,486,522` `F86`
- search() binds exactly one text parameter and one integer parameter to its prepared statement (not roughly five NSString bridges, as an earlier estimate assumed). `ClipboardHistoryStore.swift:375-376` `F86`
- An FTS5 parse error on the query surfaces at sqlite3_step, exiting the loop and simply returning an empty result array. `ClipboardHistoryStore.swift:375-384` `F98`
- clear() unconditionally empties pinnedEntries, recentEntries, and totalCount without checking the sqlite3_exec result; SearchCoordinator.clearHistory then republishes an empty clipboard list purely from that in-memory cache. `ClipboardHistoryStore.swift:499-508; SearchCoordinator.swift:639-644` `F98`
- ClipboardHistoryStore.deinit closes the database handle and nils state.db under stateLock, which races against any active query if the lock were ever dropped mid-operation. `ClipboardHistoryStore.swift:82-89` `F40`
- ClipboardHistoryStore.init takes an explicit databaseURL parameter; SearchCoordinator.swift:201-206 always supplies one, making the else-branch fallback at ClipboardHistoryStore.swift:21-31 dead/unreachable code. `ClipboardHistoryStore.swift:21-31; SearchCoordinator.swift:201-206` `F63`

### In-memory cache and search query paths

- ClipboardHistoryStore.inMemoryRecentWindowLimit is 1,000 entries, and ClipboardHistoryStore.maxTextByteCount hard-caps stored text at 32,000 UTF-8 bytes per entry (not the "hundreds of KB" an earlier estimate assumed). `ClipboardHistoryStore.swift:8,10-11` `F5-accuracy` `F6` `F28` `F51` `F52:value` `F75` `F85` `F99` `F100`
- ClipboardHistoryStore.searchResultLimit is 200. `ClipboardHistoryStore.swift:10-11` `F5-accuracy` `F6` `F20` `F69` `F87` `F100`
- An empty query returns pinnedEntries plus recentEntries directly from the in-memory cache, up to the 1,000-entry window, without touching FTS5 or copying any blob. `ClipboardHistoryStore.swift:349-362,10` `F6` `F97` `F100`
- For 1-2 UTF-8-byte queries, search() filters the same in-memory recent window with localizedCaseInsensitiveContains — unbounded and locale-aware over up to 1,000 entries, with no FTS5 query and no re-read from SQLite. `ClipboardHistoryStore.swift:349-362,405-409` `F40` `F100`
- Queries under 3 UTF-8 bytes stay unbounded against the resident cache, but queries of 3+ bytes go through FTS5 capped at searchResultLimit (200) — not a blanket ~1,000-row scan per keystroke as an earlier estimate assumed. `ClipboardHistoryStore.swift:353-361,370,376` `F69`
- search() runs the SQLite FTS prepare/step loop synchronously under stateLock, on the MainActor. `ClipboardHistoryStore.swift:363-386` `F69`
- A ClipboardHistoryPerformanceTests budget test (clipboard_search_us) asserts search stays under 2 milliseconds across 1,000 entries and 8 queries. `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:23-78,71-78` `F85` `F87` `F97`
- ClipboardEntry has an in-memory stride of roughly 120 bytes; an insert(at:0) memmove across 1,000 entries moves about 120 KB, estimated at 10-15 microseconds. `ClipboardEntry.swift:46-53; ClipboardHistoryStore.swift:331,254` `F97`
- state.pinnedEntries.max is evaluated only when state.recentEntries.first is nil, via an autoclosure; recentEntries is non-empty from the first successful record() call onward, so that branch is effectively cold after startup. `ClipboardHistoryStore.swift:293,203-207` `F97`

### Result projection: mapping entries to search rows

- SearchCoordinator's clipboard branch calls publishClipboardModeResults synchronously on the MainActor on every keystroke — the query didSet drives scheduleSearch(), which for clipboard mode returns before the debounced local-search path, bypassing the app's normal debounce entirely (the local path instead hops onto a Task). `SearchCoordinator.swift:8-14,495-508,503-507,540,655-668` `F6` `F20` `F40` `F69` `F93` `F100`
- SearchResultProjection.projectClipboard/buildClipboardRow maps every returned entry into a SearchItem — calling parseLocalPath, previewTitle, parseURL, parseHexColor, and parseCodeHint — with no result cap and no cache, allocating a full second array on every keystroke. `SearchResultProjection.swift:196-213,277-324,282,318-328` `F6` `F20` `F23` `F93` `F100` `F101`
- buildClipboardTextRow calls FileManager.default.fileExists once per text entry it renders. `SearchResultProjection.swift:299-300` `F5-accuracy` `F6` `F23` `F28` `F69` `F93`
- The dominant cost in clipboard text-row projection is the repeated whole-string scanning inside the parse helpers, not the FileManager.fileExists calls (an earlier estimate had attributed the cost to up to 1,000 stat syscalls per keystroke). `SearchResultProjection.swift:196-213,277-324` `F6` `F23`
- buildClipboardTextRow splits and rejoins the full body (up to 32,000 bytes) to build previewTitle, on every row, on every keystroke. `SearchResultProjection.swift:394-398` `F93`
- buildClipboardImageRow sets the subtitle to dimensions + relative time + appended file size; buildClipboardFileRow sets the subtitle to just the path, with no modifiedAt and no fileSize; buildClipboardTextRow's local-path branch sets both fileURL and modifiedAt while embedding relative time. `SearchResultProjection.swift:282-311,341-361,363-394` `F105`
- formattedRelativeTime is used to precompute the relative-time subtitle at three call sites (lines 287, 316, 375), all exclusive to clipboard mode. `SearchResultProjection.swift:287,314,316,375` `F79` `F105`
- buildClipboardFileRow emits .copyFiles([path]) as a single-element array, while SelectedResultActionPerformer.writeFiles accepts and is written to handle multiple files. `SearchResultProjection.swift:356; SelectedResultActionPerformer.swift:48-62` `F92`
- SelectedResultActionPerformer.activate handles .copy, .copyFiles, and .copyImage identically: write to the pasteboard, then call onDismiss(). `SelectedResultActionPerformer.swift:156-176` `F95`

### ClipboardInspector text parsing (path, URL, color, code hint)

- ClipboardInspector.parseLocalPath returns nil unless the trimmed text is single-line and begins with /, ~/, or file:// — it does no disk access for any text that fails that gate. `ClipboardInspector.swift:235-253,236-250` `F6` `F41`
- parseLocalPath, parseURL, parseHexColor, and parseCodeHint each begin with their own trimmingCharacters(in: .whitespacesAndNewlines) full-string copy — four separate whole-string scans per row. `ClipboardInspector.swift:236,256,264,273` `F23` `F69` `F101`
- parseCodeHint runs up to seven .contains scans plus a JSONSerialization.jsonObject parse over the entire trimmed body, with the JSON attempt gated on both an opening and a closing bracket/brace being present. `ClipboardInspector.swift:274-296,274-278,277-292` `F23` `F101`
- ClipboardInspector.previewTitle allocates a fresh full-length string via split-then-join over the entire body. `ClipboardInspector.swift:331-336` `F102`
- countWords and countLines each perform a full O(n) split, allocating a substring array over the whole text; ClipboardInspectorPane displays both counts. `ClipboardInspector.swift:300-308; ClipboardInspectorPane.swift:182-186` `F102`
- imageFormatName(width:height:) is a constant-return function that takes two Int parameters it never uses. `ClipboardInspector.swift:327-329` `F104`

### ClipboardInspector snapshot and per-keystroke recompute

- SearchCoordinator.clipboardInspector is an unmemoized computed property that rebuilds the entire snapshot from the store on every read, with no cache. `SearchCoordinator.swift:647-655` `F68` `F88` `F102`
- clipboardInspector is read from two independent view bodies — SearchView.swift:220 (ClipboardInspectorPane) and :470 (ClipboardFooterBar) — so it fires twice per body evaluation in clipboard mode. `SearchView.swift:220,470` `F68` `F88`
- clipboardInspector re-evaluates on every keystroke and every arrow-key selection move; an unresolvable bundle ID triggers a fresh Launch Services lookup on every single evaluation. `SearchCoordinator.swift:647` `F71`
- SearchView.swift:220 evaluating model.clipboardInspector inside the view body triggers a synchronous full-resolution image blob read (imageData(for:).png under stateLock, on the MainActor) on every body evaluation — the same blob read the Space-key preview path performs. `SearchCoordinator.swift:653,647-654; ClipboardHistoryStore.swift:263-277; SearchView.swift:220` `F75` `F76` `F90`
- snapshot() unconditionally calls sourceAppDisplayName() and formattedDetailedDate() on every evaluation; sourceAppDisplayName hits NSWorkspace.shared.urlForApplication(withBundleIdentifier:) with no memoization. `ClipboardInspector.swift:98-99,360-362` `F88`
- formattedDetailedDate() allocates a fresh DateFormatter plus a Calendar.current at lines 311-312, and a second DateFormatter at line 321 for non-today/non-yesterday dates (two formatters per call, not four as an earlier estimate assumed); DateFormatter construction here is invoked 2-4 times per render via the doubly-read clipboardInspector property. `ClipboardInspector.swift:310-325,312,321` `F76` `F88`
- snapshot() performs two filesystem checks for file entries — FileManager.default.fileExists at lines 107 and 152 — plus url.resourceValues at line 354, and fileType(for:) adds a third stat via url.hasDirectoryPath on a URL built without an isDirectory hint. `ClipboardInspector.swift:107,152,338-339,354` `F88`
- ClipboardInspectorPane.swift:245 calls AppIconCache synchronously on the main actor for every snapshot evaluation. `ClipboardInspectorPane.swift:243-245` `F88`
- ClipboardInspector and TextDetail are Equatable, so SwiftUI still skips a re-layout when the recomputed snapshot's Text value compares equal — the per-keystroke recompute does not necessarily force a visible re-render. `ClipboardInspector.swift:6,30` `F102`
- The recompute is fundamentally selection-driven, independent of the storage model — splitting the observable class would not by itself remove the SQLite/LaunchServices work from the navigation path, as an earlier plan assumed. `SearchCoordinator.swift:647-655; SearchView.swift:220,470` `F70`

### Startup and initialization ordering

- SearchCoordinator.activeShortcutDisplayName is a stored property, and its convenience init (lines 201-206) eagerly constructs the ClipboardHistoryStore, forcing full SearchCoordinator + store initialization. `SearchCoordinator.swift:53,201-206` `F51`
- AppDelegate.installGlobalHotKey (line 34) forces SearchCoordinator construction by writing model.activeShortcutDisplayName; clipboardCapture's lazy property merely reads the already-built store — it is the hotkey installer, not the clipboardCapture initializer, that forces construction (contrary to an earlier claim about lines 19-21). `AppDelegate.swift:34,111` `F51`
- installGlobalHotKey() runs at line 33, before clipboardCapture.start() at line 35, so the hotkey installation itself is not delayed by clipboard store init. `AppDelegate.swift:33,35` `F52:value`
- Reordering installGlobalHotKey relative to other launch steps only shifts where the forced SearchCoordinator construction happens — it does not remove that construction from the critical path, since installGlobalHotKey itself is what touches activeShortcutDisplayName. `AppDelegate.swift:111` `F67`
- ClipboardHistoryStore.init() runs synchronously on the main thread: it opens SQLite with SQLITE_OPEN_FULLMUTEX, runs 7 ALTER TABLE migrations, and calls loadInitialWindow(recentLimit: 1_000), all before app launch completes. `ClipboardHistoryStore.swift:53-78,67-72,68-72` `F51` `F52` `F52:value`
- That initial load holds all 1,000 entries' thumbnail PNG Data resident in memory for the lifetime of the process. `ClipboardHistoryStore.swift:10,53-78` `F85`
- ClipboardHistorySQLite.loadInitialWindow issues an unbounded query for pinned entries and a separate, LIMIT-bounded query for recent entries. `ClipboardHistorySQLite.swift:62-67,79` `F52`
- initializeSchema is called synchronously from ClipboardHistoryStore.init (line 68), reached via SearchCoordinator.init (lines 201-205), which AppDelegate forces at line 36 inside applicationDidFinishLaunching. `AppDelegate.swift:30-37; SearchCoordinator.swift:201-205` `F94`
- AppDelegate.applicationDidFinishLaunching runs, in order: installMenu, installStatusItem, installGlobalHotKey, clipboardCapture.start, presentation.launch. `AppDelegate.swift:30-38` `F64`
- presentation.launch calls ensureSearchStarted then showSearch, presenting the full SwiftUI panel on launch together with the hotkey, NSStatusItem, and clipboard capture already active. `ApplicationPresentationCoordinator.swift:47-53` `F64`

### UI rendering: rows, inspector pane, and previews

- SearchView renders clipboard history in a scrollable LazyVStack; SearchResultsSection.body only mounts that ScrollView/LazyVStack/filter-bar when !query.isEmpty || isClipboardMode, so it is skipped entirely when idle. `SearchView.swift:385,398-402,182` `F6` `F77`
- SearchResultProjection (line 376) reads entry.image?.thumbnailPNGData for every projected clipboard row, and ResultRow.swift decodes that thumbnail PNG inline via NSImage(data:) on every body evaluation, with no decode cache. `SearchResultProjection.swift:376; ResultRow.swift:193-195; SearchCoordinator.swift:666` `F52:value` `F75` `F85`
- ClipboardInspectorPane renders the full-resolution PNG at up to 180pt (360px at retina scale) while the stored thumbnail is only 128px — the inspector image is visibly blurrier than a 128px thumbnail alone would suggest. `ClipboardInspectorPane.swift:145` `F75`
- ClipboardInspectorPane renders the full text body with no lineLimit for text and code detail kinds, and ClipboardInspector sets body directly from entry.text with no truncation. `ClipboardInspectorPane.swift:110-127; ClipboardInspector.swift:132-133` `F102`
- A full 32 KB clipboard entry renders as approximately 550-600 lines at 12.5pt system font in a 312pt-wide inspector pane. `ClipboardInspectorPane.swift:11-21; FloodlightMetrics.swift:13` `F102`
- previewableSelectionURL for a copyImage selection calls clipboardStore.imageData, which materializes both png_data and tiff_data from SQLite under stateLock before the caller picks which one to use. `SearchCoordinator.swift:424-425; ClipboardHistoryStore.swift:263-277` `F41`
- previewableSelectionURL evaluation runs on every Space keypress in both clipboard mode and non-clipboard modes, not only in clipboard mode as an earlier claim assumed. `FloodlightPanel.swift:291-295` `F41`
- FloodlightPanel passes hasPreviewableSelection as an eager, non-autoclosure argument before the isClipboardMode guard is checked, so it is computed on every keyDown regardless of mode. `FloodlightPanel.swift:291-295,449-458` `F90`
- clipboardImagePreviewURL writes the image blob to NSTemporaryDirectory()/FloodlightClipboardPreviews via createDirectory, fileExists, and data.write. `SearchCoordinator.swift:451-457` `F90`
- That write is guarded by a prior fileExists check, so the multi-MB data.write happens at most once per entry id for the lifetime of the temp directory — not on every Space keypress as an earlier claim assumed. `SearchCoordinator.swift:455-456` `F90`
- deleteSelection and clearHistory remove only the database rows; they leave the corresponding files in FloodlightClipboardPreviews on disk, and AppDelegate.applicationWillTerminate (line 40) never removes that directory. `SearchCoordinator.swift:635,639; AppDelegate.swift:40` `F90`
- ClipboardFooterBar renders model.clipboardInspector?.sourceApp ?? "App" — this is the app the content was copied FROM, not the app it will be pasted TO, and is derived from entry.sourceAppBundleID with a fallback of "Clipboard" when nil. `SearchView.swift:469-470,486; ClipboardInspector.swift:78-82,98,360` `F95`

### Known bugs and mismatches

- An image/video extension Set is duplicated in three places — ClipboardInspector.swift:221, FileThumbnailCache.swift:40-43, and ClipboardInspectorPane.swift:292-294. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43; ClipboardInspectorPane.swift:292-294` `F84`
- ClipboardInspector.swift:221 lists svg as an image extension but FileThumbnailCache.swift:40-43 does not — this mismatch (not merely "duplicate lists cause inconsistency" in general) causes SVG clippings to render a blank preview that displays the previous entry's image indefinitely. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43,48` `F84`
- ClipboardInspectorPane.swift:290 uses .task(id: url) to fetch thumbnails but does not reset thumbnail to nil on a cache miss, nor guard the assignment at line 299 with a Task.isCancelled check. `ClipboardInspectorPane.swift:290,299` `F84`
- ClipboardInspector is a non-isolated enum called from non-isolated tests; under Swift 6 language mode its static let DateFormatter() becomes non-Sendable and fails to compile. `ClipboardInspector.swift; ClipboardInspectorTests.swift:6,16; Package.swift:1` `F88`

### Test coverage gaps

- ClipboardHistoryPerformanceTests seeds only text entries — it has no coverage for the thumbnail blob path, projectClipboard, or clipboardInspector. `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:11-27` `F14`
- No footprint assertion exists in the clipboard performance tests to detect RSS growth. `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift` `F14`
- ClipboardCaptureServiceTests has approximately 25 test sites that call harness.service.poll and assert store.count on the next line. `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift:97,106,121,299` `F42`
- pollPrefersFileReferencesOverImageDataWhenBothArePresent covers the files-vs-image precedence case, but no test covers image-plus-text pasteboard content. `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift:392-407` `F91`

### Capture pipeline: polling, pasteboard reading, exclusions

- ClipboardCaptureService.poll() runs on an unconditionally scheduled repeating timer with a 0.5s interval and 0.2s tolerance (40% slack). `ClipboardCaptureService.swift:129,178-186,184` `F164`
- poll() re-reads the isEnabled flag on every 0.5s tick; this is an in-process CFPreferences cache hit, not a disk read, and defaults lookups are computed twice per tick. `ClipboardCaptureService.swift:139-152,233` `F120-value` `F164`
- poll() only guards on isEnabled/isPaused flags before proceeding to read the pasteboard. `ClipboardCaptureService.swift:232-285` `F120-accuracy`
- pause()/resume() are wired only to NSWorkspace.sessionDidResignActive/BecomeActive; the timer also registers for fast-user-switch notifications, not lock or sleep-screen notifications. `ClipboardCaptureService.swift:223-230,188-206` `F120-accuracy` `F164`
- poll() checks content in fixed order — file paths (line 258), image payload (line 266), then string (line 280) — and the image branch runs before the text branch, so a copy carrying image data is classified as image and never reaches the text path even if a string flavor is also present. `ClipboardCaptureService.swift:258,266,280,266-281` `F134` `F121`
- The text branch reads only observer.string(forType: .string); no RTF or HTML pasteboard flavor is ever read, and no .rtf/.html pasteboard type, copyPlainText action, or plain-text keyboard shortcut exists anywhere in the codebase. `ClipboardCaptureService.swift:279-283` `F121-accuracy` `F134`
- Clipboard restore (paste) writes only .string, via AppKitSelectedResultActionEffects.writeString calling pasteboard.setString(). `SelectedResultActionPerformer.swift:42-46` `F121`
- Net effect of the string-only capture and restore paths: a rich-formatted copy round-tripped through clipboard history is silently flattened to plain text. `ClipboardCaptureService.swift:279-281; SelectedResultActionPerformer.swift:42-46` `F121`
- poll() sets lastChangeCount = observer.changeCount only inside the polling loop, so pasteboard contents already present at app launch are never captured. `ClipboardCaptureService.swift:174` `F120-accuracy`
- poll() checks pasteboard type strings org.nspasteboard.ConcealedType, TransientType, and com.apple.is-sensitive to skip sensitive copies. `ClipboardCaptureService.swift:108-110,244-250` `F120-accuracy`
- ClipboardCaptureService.isEnabled (and OnboardingSession.clipboardHistoryEnabled, which mirrors the same logic independently) return true when defaults.object(forKey:) is nil — capture is enabled by default until the user explicitly disables it. `ClipboardCaptureService.swift:139-152,141-143; OnboardingSession.swift:40-52` `F120-accuracy` `F120-value` `F149`
- ClipboardCaptureService reads retention days from UserDefaults; a stored value of -1 falls through to .days(30) instead of the intended .forever. `ClipboardCaptureService.swift:154-162` `F115-value`
- Default retention when no preference is stored is 30 days. `ClipboardCaptureService.swift:154-161` `F149`
- Only two UserDefaults keys exist for clipboard persistence: clipboard-history-enabled and clipboard-history-retention-days. `ClipboardCaptureService.swift:105-106` `F132`
- PasteboardObserving protocol exposes only string(forType:), data(forType: .png), data(forType: .tiff), and filePaths() — no richer pasteboard type is abstracted at all. `ClipboardCaptureService.swift:8-45` `F121-accuracy`
- ClipboardCaptureService feeds the frontmost app's bundle identifier verbatim into the exclusion check with no validation, and ClipboardExclusionStore.isExcluded does exact, case-sensitive Set<String>.contains() matching on it — no case folding or app-name matching is performed. `ClipboardCaptureService.swift:253-256; ClipboardExclusionStore.swift:44-48` `F120-value` `F125`
- ClipboardExclusionStore seeds an OSAllocatedUnfairLock(initialState: []) when no stored exclusion data exists. `ClipboardExclusionStore.swift:9-18` `F120-accuracy`
- AppDelegate calls clipboardCapture.start() immediately before presentation.launch() during app startup. `AppDelegate.swift:30-38,36-37` `F120-accuracy`
- pruneOnSchedule (ClipboardCaptureService.swift:287) is the one place where Task.detached usage is legal in this service. `ClipboardCaptureService.swift:287` `F119-value`

### Data model and size/retention limits

- ClipboardEntry carries hash, width, height, byteCount, and thumbnailPNGData fields; the struct itself has no separate png_data/tiff_data payload fields (those exist only as SQLite columns). `ClipboardEntry.swift:12-18` `F104`
- ClipboardEntry.text is the searchable display field: app name for images, the input text for text entries, or the path for file entries; it stores the full text in `let text: String` with no truncation at the struct level. `ClipboardInspector.swift:174; ClipboardHistoryStore.swift:190-191; ClipboardEntry.swift:47` `F104` `F122-value`
- ClipboardEntryKind has exactly three cases: text, file, image. `ClipboardEntry.swift:6-8` `F115-accuracy` `F115-value`
- ClipboardRetention supports only two variants: .days(Int) or .forever. `ClipboardEntry.swift:91-103` `F115-accuracy`
- Per-entry size limits: maxTextByteCount = 32,000 bytes; maxImageByteCount = 15,728,640 bytes (15 MB), each enforced independently. `ClipboardHistoryStore.swift:8-9,398-403` `F115-accuracy` `F118` `F122` `F122-value`
- A single screenshot entry can store up to ~30 MB total, since png_data and tiff_data are each capped at 15 MB independently and both get bound into the same row (not a single 15 MB image cap as previously assumed). `ClipboardHistoryStore.swift:245-247,398-403` `F118`
- The 32 KB text cap gates only plain text; rich HTML flavors of styled paragraphs routinely exceed 32 KB and are not comparably protected (the cap does not apply uniformly to all clipboard content types). `ClipboardHistoryStore.swift:8` `F121`
- ClipboardCaptureService.poll() silently drops text whose UTF-8 byte count exceeds maxTextByteCount, and ClipboardHistoryStore.insert(text:) separately also silently returns nil for the same condition; no `truncated` column exists in the schema to flag this. `ClipboardCaptureService.swift:281; ClipboardHistoryStore.swift:285-287; ClipboardHistorySQLite.swift` `F122`
- Because dropped-oversized entries are unmarked, a truncated clipboard entry pasted back through the copy action would silently deliver partial data with no visible indicator. `ClipboardHistoryStore.swift:285-287` `F122`
- No aggregate byte or entry-count ceiling exists for total clipboard history storage. `ClipboardHistoryStore.swift:8-11` `F115-accuracy`
- inMemoryRecentWindowLimit = 1000 caps state.recentEntries, but state.pinnedEntries is uncapped (not a 1,000-entry total cap). `ClipboardHistoryStore.swift:10,255,332,351-353,456` `F116-accuracy` `F141` `F126`
- searchResultLimit = 200 caps every non-empty-query FTS search via LIMIT. `ClipboardHistoryStore.swift:11,370-373,376` `F116-accuracy` `F141` `F126`
- An empty/whitespace-only query returns the full pinned+recent in-memory window instead of going through FTS. `ClipboardHistoryStore.swift:351-353` `F116-value`
- The short-query path (trimmed query under 3 UTF-8 bytes) has no result cap at all, while the FTS path caps at 200 — the two paths are inconsistent, not consistently capped. `ClipboardHistoryStore.swift:353-361,376` `F126`
- ClipboardHistoryStore uses text as the dedup key, so formatting-only changes to otherwise-identical text are swallowed as duplicates. `ClipboardHistoryStore.swift:285` `F121`
- ClipboardEntry conforms to Equatable and Hashable and is rebuilt wholesale in withPinnedAt, so equality needs a carve-out for that one derived field. `ClipboardEntry.swift:46,77` `F126`
- Realistic clipboard text averages hundreds of bytes, far below the 32 KB maxTextByteCount ceiling. `ClipboardHistoryStore.swift:8` `F126`
- Tests hard-code the 32,000-byte boundary in ClipboardHistoryStoreTests.swift:60-80 and ClipboardHistoryStorePropertyTests.swift:12. `ClipboardHistoryStoreTests.swift:60-80; ClipboardHistoryStorePropertyTests.swift:12` `F122`

### SQLite storage and FTS5 indexing

- ClipboardHistoryStore's SQLite file lives at ~/Library/Application Support/Floodlight/clipboard.sqlite3, with createDirectory called if the folder is missing. `ClipboardHistoryStore.swift:35-52,49` `F118-accuracy` `F119-value` `F147`
- ClipboardHistorySQLite sets only PRAGMA journal_mode = WAL and PRAGMA synchronous = NORMAL; it never sets secure_delete or auto_vacuum, and the codebase contains no VACUUM or wal_checkpoint call anywhere. `ClipboardHistorySQLite.swift:14-18,14-50` `F114-accuracy` `F118`
- SQLite's secure_delete is a per-connection/compile-time setting, not persisted in the file header, so it must be set on every connection to take effect; under WAL mode, secure_delete zeroing is journaled, so plaintext can linger in old WAL frames until a checkpoint runs. `SQLite documentation` `F118-accuracy`
- sqlite3_wal_checkpoint_v2(..., SQLITE_CHECKPOINT_TRUNCATE, ...) removes WAL frames but can return SQLITE_BUSY if a reader connection is still live. `SQLite API` `F118-accuracy`
- clipboard_fts is an external-content trigram FTS5 table with content='clipboard_entries' and content_rowid='rowid'. `ClipboardHistorySQLite.swift:30-35,32-33` `F114-accuracy` `F114-value`
- Three FTS5 triggers exist — clipboard_entries_ai (insert), _ad (delete), _au (update) — and recreateFTSTriggers drops and recreates all three on every initializeSchema call, i.e. every store open. `ClipboardHistorySQLite.swift:220-265,225-262,52; ClipboardHistoryStore.swift:68` `F114-accuracy` `F122`
- The insert trigger appends a "WxH" dimension suffix to indexed text for image entries; this trigger landed together with image capture in commit 5cbc725, so no image row predates it. `ClipboardHistorySQLite.swift:228-231` `F114-accuracy` `F114-value`
- INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild') re-reads content straight from clipboard_entries.text and does not run the triggers. `ClipboardHistorySQLite.swift:32` `F114-accuracy` `F114-value`
- The delete/update triggers (_ad, _au) must supply byte-identical text to what the insert trigger (_ai) indexed, or the FTS5 index desynchronizes — this is not independent per trigger. `ClipboardHistorySQLite.swift:236-243,247-254,225-262` `F114-accuracy` `F114-value` `F122`
- FTS5 prefix-only indexing with substr() would silently cause search to miss any match past the prefix bound (e.g. 4 KB) if such a limit were introduced. `ClipboardHistorySQLite.swift:225-262` `F122`
- Pin/unpin operations fire the AFTER UPDATE trigger on clipboard_fts. `ClipboardHistoryStore.swift:417,444` `F114-value`
- delete(id:) runs a plain `DELETE ... WHERE id = ?`; prune(olderThan:) runs `DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?`; clear() runs `sqlite3_exec(db, 'DELETE FROM clipboard_entries;', nil, nil, nil)` with its return value discarded and no error check. `ClipboardHistoryStore.swift:476,512-527,516,499-508,503` `F115-accuracy` `F117-accuracy` `F117-value` `F118-accuracy`
- None of delete(), clear(), or prune() reclaim any disk space (no VACUUM is ever run). `ClipboardHistoryStore.swift:476,499,512` `F118`
- prune() re-derives state.totalCount via queryTotalCount() and self-corrects on error, but clear() just zeroes pinnedEntries/recentEntries/totalCount locally without checking whether the SQL actually succeeded. `ClipboardHistoryStore.swift:526,503` `F118`
- state.totalCount, state.pinnedEntries, and state.unpinnedEntries are all tracked in-memory alongside the SQLite-backed rows. `ClipboardHistoryStore.swift:107-111,104-106` `F117-value` `F140`
- An ALTER TABLE ... ADD COLUMN migration path already exists and was previously used to add the png_data/tiff_data BLOB columns. `ClipboardHistorySQLite.swift:202-216,207-216,210` `F121-accuracy` `F122`
- recordImage's INSERT binds both png_data (SQL parameter index 11) and tiff_data (index 12) into the same row. `ClipboardHistoryStore.swift:245-247` `F118`
- ClipboardHistoryStore.swift:263-277 selects the raw png_data/tiff_data blob columns, falling back to thumbnailPNGData if those are absent. `ClipboardHistoryStore.swift:263-277` `F119-value`
- No FileProtection attribute or POSIX permission hardening is applied to clipboard.sqlite3. `grep posixPermissions|FileProtection Sources/` `F119-value`

### Search flow: entering clipboard mode and querying

- Clipboard mode is entered only via SearchMode.entered matching token.typedKeyword.lowercased() == "clip" exactly, followed by Tab; "clip" is hardcoded again as the canonical spelling in exitClipboardFieldText, so any alias added later would need to be kept in sync in both places or it permanently shadows that spelling for future engines. `Sources/FloodlightEngine/Search/SearchMode.swift:92-100,145,92-102` `F124` `F131`
- SearchCoordinator.applyModeEvent sets mode and query and calls publishClipboardModeResults; entering clipboard mode hard-codes selectedFilter to .all (line 321-323), whereas every other clipboard mutation instead defaults selectedFilter to self.selectedFilter. `SearchCoordinator.swift:303-329,321-323,657-668` `F131` `F132`
- scheduleSearch short-circuits straight to publishClipboardModeResults() when in clipboard mode, with no debounce. `SearchCoordinator.swift:502-508,503-506` `F116-accuracy` `F143` `F166`
- publishClipboardModeResults calls clipboardStore.search(query:) synchronously and inline, inside stateLock.withLock, on the main thread; ClipboardHistoryStore is @MainActor, so every keystroke in clipboard mode runs SQLite FTS5 prepare/step directly on the main actor. `SearchCoordinator.swift:657-671,666,5,503-508` `F116-accuracy` `F126` `F143` `F161`
- ClipboardHistoryPerformanceTests.swift:34-78 averages short-path queries together with 6 FTS queries in one benchmark, which dilutes and hides the true cost of the uncapped short-query path. `ClipboardHistoryPerformanceTests.swift:34-78` `F126`
- selectFilter(_:) at SearchCoordinator.swift:359-363 is the wiring point for changing the active clipboard filter chip. `SearchCoordinator.swift:359-363` `F132`
- SearchResultFilter.clipboard exposes exactly four filter chips: .all, .text, .files, .images. `SearchItem.swift:68-73; SearchFilterTests.swift:12` `F129` `F132`
- Any digit-key rebinding added for clipboard mode must be scoped to model.isClipboardMode, or it would break the existing Command+5 "first dynamic filter" behavior in other modes. `FloodlightPanel.swift:345-350` `F129`
- excludeFromSearch (the blocklist action) has no mode guard at all — it runs identically in web mode and clipboard mode. `SearchCoordinator.swift:391-403; SearchResultProjection.swift:186,205` `F128`
- In clipboard mode, running excludeFromSearch calls projectClipboard, which returns sourceCandidates: [] — this drops all local clipboard rows from the result list during the blocklist operation, but does not switch the coordinator's mode value. `SearchCoordinator.swift:391-403; SearchResultProjection.swift:205` `F128`
- This wrong-publication state is not sticky — it self-heals, because the next keystroke or filter click re-enters the clipboard branch and republishes correctly. `SearchCoordinator.swift:503-508,360` `F128`
- The correct fix for the blocklist gate would be `guard case .local = mode else { return }`, not just `!isClipboardMode`, since the current check only excludes clipboard mode and lets every other non-local mode through unchecked. `SearchCoordinator.swift:391` `F128`
- OnboardingSession.unblockRule lets a user undo a clipboard title accidentally added to the exclusion blocklist, from the settings page. `OnboardingSession.swift:123-131` `F128`
- Production ClipboardHistoryStore opens its file at indexStorage/clipboard.sqlite3, wired via SearchCoordinator. `SearchCoordinator.swift:201-205` `F143`
- OnboardingSession.swift:93-96 and SearchCoordinator.swift:101-103 both default blocklistStore, clipboardExclusionStore, and clipboardStore using the same constructor pattern. `OnboardingSession.swift:93-96; SearchCoordinator.swift:101-103` `F147`
- ClipboardExclusionStore lives under Sources/Floodlight/Search/ (app-side, shell-only); BlocklistStore and ClipboardHistoryStore live under Sources/FloodlightEngine/Utilities/ (engine-side). `Sources/Floodlight/Search/ClipboardExclusionStore.swift; Sources/FloodlightEngine/Utilities/` `F147`
- CONTEXT.md:70 documents "Clipboard History" as a module seam. `CONTEXT.md:70` `F148`
- SearchCoordinatorClipboardModeTests and SearchViewRenderingTests both explicitly thread in a ClipboardHistoryStore.inMemory() test double. `SearchCoordinatorClipboardModeTests; SearchViewRenderingTests` `F147`

### Result row construction (SearchResultProjection)

- Clipboard, calculator, web, and assistant result rows are all synthesized directly in SearchResultProjection.swift with no fuzzy-match classification step. `SearchResultProjection.swift` `F107`
- projectClipboard maps buildClipboardRow over the entire entry array with no cap or memoization, then filters and walks the array a third time. `SearchResultProjection.swift:196-212,233-256,246-248` `F116-accuracy` `F161`
- Both the local-path text row (line 305) and the plain non-path text row (line 334) are built with a hardcoded `action: .copy(text)`, and buildClipboardTextRow never passes a fileURL argument for non-path text. `SearchResultProjection.swift:305,334,329-338` `F105` `F133` `F135`
- buildClipboardFileRow (lines 349-359) does set fileURL: fileURL for file-type rows. `SearchResultProjection.swift:349-359` `F133`
- buildClipboardImageRow (lines 363-390/393) sets no fileURL at all — its title is just entry.text ("Image", "Screenshot", etc.) — so dragging a screenshot row drags the literal string "Image" rather than image data. `SearchResultProjection.swift:363-393` `F133`
- modifiedAt is set only inside the buildClipboardTextRow branches (lines 309, 337); buildClipboardImageRow never sets modifiedAt. `SearchResultProjection.swift:309,337,363-390` `F170`
- Pinned clipboard rows get a "📌 " prefix added to their title at four separate call sites (lines 285, 314, 348, 369). `SearchResultProjection.swift:285,314,348,369` `F123` `F128`
- SearchResultProjection.swift:282 calls ClipboardInspector.parseLocalPath(text) to detect path-like clipboard text. `SearchResultProjection.swift:282` `F116-accuracy`
- buildClipboardTextRow calls FileManager.fileExists on the main thread while building rows. `SearchResultProjection.swift:299` `F161`

### Clipboard inspector: classification and rendering

- ClipboardInspector.classifyText (lines 189-213) runs parseURL, parseHexColor, and parseCodeHint in sequence, classifying text into link / color / code / plain-text with associated metadata. `ClipboardInspector.swift:189-213,189-206` `F110` `F166`
- ClipboardInspector.parseURL is HTTP(S)-only and already returns a (url, domain) pair. `ClipboardInspector.swift:255-261` `F135`
- parseCodeHint (starting line 272) returns literal strings — "JSON" (line 278), "Code" (lines 284, 289), "HTML" (line 295) — or nil if unrecognized, collapsing any Swift/Kotlin/Go/JavaScript code to the same undifferentiated "Code" label while SQL/Python/shell/bash fall to nil. `ClipboardInspector.swift:272-298,281-290` `F111`
- parseCodeHint runs JSONSerialization.jsonObject (line 277) plus roughly 6 to 10 `contains` substring scans unconditionally over the text, up to the 32 KB text cap. `ClipboardInspector.swift:272-298,277,284-296` `F111` `F116-accuracy` `F166`
- classifyFile declares imageExtensions (13 elements) and videoExtensions (11 elements) as function-body local arrays. `ClipboardInspector.swift:218-225` `F112`
- All of ClipboardInspector's extension-list string literals are 5 UTF-8 bytes or fewer, which fits Swift's small-string form — there is no heap allocation per call, contrary to an earlier "~24 String allocations" estimate. `ClipboardInspector.swift:218-225` `F112`
- classifyFile runs at most ~2 times per SwiftUI body pass in clipboard mode; its real cost is dominated by FileManager syscalls, not Set/String allocation. `ClipboardInspector.swift:106-115,150-157; SearchCoordinator.swift:647; SearchView.swift:220,470` `F112`
- ClipboardInspector.imageExtensions includes ico, icns, and svg, but FileThumbnailCache.imageExtensions omits svg — the two lists have diverged (not three identical copies as previously assumed), so ClipboardInspectorPane's media-preview branch (lines 133-134) can never produce a thumbnail for .svg clipboard entries. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43; ClipboardInspectorPane.swift:133-134` `F112`
- Four separate parsers each independently call text.trimmingCharacters (lines 236, 256, 264, 273) rather than sharing one trimmed value. `ClipboardInspector.swift:236,256,264,273` `F116-value`
- parseLocalPath rejects any text that is not single-line and does not start with /, ~/, or file://. `ClipboardInspector.swift:235-252` `F161`
- ClipboardInspector.snapshot(for:) fetches on-disk file size via url.resourceValues(forKeys:) for a single selected entry, performed as a synchronous filesystem syscall, and calls FileManager.default.fileExists at two points (lines 110, 152) for disk validation. `ClipboardInspector.swift:354-358,353-358,106-115,150-157` `F105`
- ClipboardInspector.sourceAppDisplayName (lines 360-370) resolves the app's display name via NSWorkspace.shared.urlForApplication(withBundleIdentifier:), falling back to the bundle ID's last path component. `ClipboardInspector.swift:360-370` `F109`
- SearchCoordinator.clipboardInspector is a computed property that rebuilds the entire snapshot from scratch on every access; SearchView.swift reads it at both line 220 and line 470, so a single body evaluation in clipboard mode triggers two full snapshot rebuilds. `SearchCoordinator.swift:647-655; SearchView.swift:220,470` `F106` `F163`
- ClipboardInspectorPane.swift:229 applies .truncationMode(.middle) to file-row subtitles, inconsistent with ResultRow's default tail truncation elsewhere. `ClipboardInspectorPane.swift:229` `F108`
- The Format row in the inspector is rendered via infoRow(label:value:) with detail.format, correctly located at ClipboardInspectorPane.swift:213 (not "Search/ClipboardInspectorPane.swift:213" as one earlier claim stated). `ClipboardInspectorPane.swift:213` `F104`
- ClipboardInspectorPane already renders a content-type label at line 178, duplicating information a proposed code badge would also show. `ClipboardInspectorPane.swift:178` `F111`
- ClipboardInspectorPane renders code content in a single uniform monospaced block (lines 99-119) with no per-token syntax highlighting. `ClipboardInspectorPane.swift:99-119` `F111`
- ClipboardInspectorPane renders link domain and body as plain Text (lines 52-73) with no tappable Link affordance. `ClipboardInspectorPane.swift:52-73` `F135`
- ClipboardInspectorPane contains no Button or focus-handling components anywhere — only plain Text and info rows. `ClipboardInspectorPane.swift` `F110`
- AppIconCache is used solely by ClipboardInspectorPane.swift:245, to cache the inspector's app-icon NSImage. `AppIconCache.swift; ClipboardInspectorPane.swift:245` `F109`
- source_app is displayed at multiple ClipboardInspectorPane locations (accounts differ: lines 98/119/142/163/182 in one pass, 176/191/205 in another). `ClipboardInspectorPane.swift:176,191,205` `F141`
- ClipboardInspectorPane.swift:292's media-extension check runs inside .task(id: url), so it executes once per URL change rather than on every render. `ClipboardInspectorPane.swift:292` `F112`
- FileMediaPreview's concurrent-decorator work (ClipboardInspectorPane.swift:32,262-301) runs off the main actor. `ClipboardInspectorPane.swift:32,262-301` `F165`
- Inspector pane width is fixed at 340pt. `FloodlightMetrics.swift:13` `F163`
- Tests/FloodlightTests/SearchResultProjectionClipboardTests.swift:44,51 lock in exact subtitle-string expectations, making them sensitive to any app-name integration change. `SearchResultProjectionClipboardTests.swift:44,51` `F109`
- ClipboardHistoryPerformanceTests.swift's fixture contains 10 strings, of which 5 are code/shell types (not "mostly code and shell" as one earlier summary put it). `ClipboardHistoryPerformanceTests.swift:11-22` `F111`

### Actions: copy, paste, pin, delete, clear

- SearchCoordinator.openSelection routes through SelectedResultActionPerformer.activate; its .copy(value) case (line 158) is a direct `guard effects.writeToClipboard(value)` with no transform hook, and writes+dismisses. `SearchCoordinator.swift:374-377; SelectedResultActionPerformer.swift:158-163,158` `F106` `F134`
- Inside activate(), the separate .copyImage case (lines 172-180) correctly uses the clipboardImagePayload path and writeImageDataToClipboard for image writing. `SelectedResultActionPerformer.swift:172-180,172-179` `F110` `F136`
- A different code path — SelectedResultActionPerformer.copy(_:)/copyValue(for:) (lines 193-198, 240-247) — routes uniformly through effects.writeToClipboard(copyValue(for:item)); for .copyImage it writes item.title (plain text) instead of actual image data, silently copying the wrong content for images. `SelectedResultActionPerformer.swift:246-247,193-198,240-247` `F110` `F136`
- Plain Return in clipboard mode calls model.openSelection() → SearchCoordinator.activate() → copy + dismiss. `SearchView.swift:93,374-377; SelectedResultActionPerformer.swift:157-162` `F135`
- The context-menu "Open" item (SearchView.swift:435-437) calls model.activate(item), performing the same copy+dismiss behavior for clipboard rows. `SearchView.swift:435-437` `F135`
- ClipboardFooterBar renders a primary "Paste to <targetAppName>" button with a ↵ chip calling model.openSelection(), and separately shows "Actions ⌘K" — but ⌘K/"Actions" has no corresponding case in panelCommand, and the footer advertises no pin or delete hint. `SearchView.swift:466-500,481-489,466-528,505-512` `F135` `F123` `F139`
- togglePin and deleteSelection are both gated on model.isClipboardMode. `FloodlightPanel.swift:344-350,345-350` `F123` `F129` `F138` `F139` `F152`
- ResultList is shared between file mode and clipboard mode, including the same context menu, which offers only Open, Show in Finder, and Exclude — no clipboard-specific actions (pin/delete) appear there. `SearchView.swift:214-221,434-449` `F123`
- OnboardingView.swift renders a "Clear all history…" button inside the "Clipboard History" SetupSection (around lines 281-395), which calls session.clearClipboardHistory(); this button is the sole caller found in the test suite. `OnboardingView.swift:387-394,391,392,281-395` `F137` `F147` `F152`
- OnboardingSession.clearClipboardHistory() calls clipboardStore.clear() and increments clipboardVersion. `OnboardingSession.swift:143-146,143` `F117-accuracy` `F137`
- clipboardStore.clear() runs `DELETE FROM clipboard_entries` and also removes all pinned entries. `ClipboardHistoryStore.swift:499-508,503` `F117-accuracy` `F117-value` `F137`
- SearchCoordinator.clearHistory() (lines 639-644) has no production caller at all — only Tests/FloodlightTests/SearchCoordinatorClipboardModeTests.swift (lines 266, 277) call it; it is not an active production function. `SearchCoordinator.swift:639-644,639` `F137`
- deleteSelection() and clearHistory() in SearchCoordinator only call clipboardStore.delete(id:)/clear() — they never remove cached preview files, and nothing else in the codebase removes files from FloodlightClipboardPreviews either. `SearchCoordinator.swift:635-644,635-641` `F119-accuracy` `F119-value` `F168`
- AppDelegate.swift:325 passes clipboardStore into FloodlightConfigurationWindowController. `AppDelegate.swift:325` `F137`
- No clipboard entry exists anywhere in AppDelegate.makeStatusMenu()'s status-bar menu. `AppDelegate.swift:142-194` `F131`

### Image handling and preview files

- ClipboardImageCapture picks the payload as png ?? tiff; when PNG is capped/oversized, the result is a TIFF-only ClipboardImagePayload. `ClipboardImageCapture.swift:20-22` `F104`
- ClipboardImageCapture.displayName is "Screenshot" for the com.apple.screencapture source, else "PNG Image" or "TIFF Image" depending on which payload is present; ClipboardHistoryStore.recordImage falls back to a "WxH" string when displayName is empty. `ClipboardImageCapture.swift:44-49,44-48; ClipboardHistoryStore.swift:190-191` `F104` `F110`
- SearchCoordinator.clipboardInspector obtains the full ClipboardImagePayload with both png and tiff data but discards the tiff half by taking only .png. `SearchCoordinator.swift:653` `F104`
- Clipboard image thumbnails are capped at 128x128 px total (a 64pt point-size thumbnail rendered at 2x scale) — not 10-40 KB of PNG data as an earlier estimate had it. `ClipboardImageCapture.swift:6-7,60-68,7-8,61` `F169` `F163`
- clipboardImagePreviewURL(for:) pulls the full png_data/tiff_data blob (not the thumbnail) and materializes it to NSTemporaryDirectory()/FloodlightClipboardPreviews/<id>.<ext>; a full-codebase search finds exactly two hits for "FloodlightClipboardPreviews", both inside this one function. `SearchCoordinator.swift:435-459,436-459,451; ClipboardHistoryStore.swift:263-277` `F119-accuracy` `F119-value` `F133` `F168`
- This preview-materialization function is currently declared private, so it cannot be reused for drag-and-drop. `SearchCoordinator.swift:434` `F133`
- clipboardImagePreviewURL is evaluated eagerly at FloodlightPanel.swift:291-295 on every space/keystroke, not lazily on demand. `FloodlightPanel.swift:291-295` `F167`

### Settings / onboarding UI

- OnboardingView.swift (lines 281-395) renders the full clipboard-history settings block: record toggle, retention picker, exclusions list, and the "Clear all history…" button, inside SetupSection(title: "Clipboard History") starting at line 282. `OnboardingView.swift:281-395,282,391` `F137` `F152`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Clipboard poll interval | 0.5 seconds | `ClipboardCaptureService.swift:178-184` |
| Poll timer tolerance | 0.2 seconds | `ClipboardCaptureService.swift:184` |
| Poll wakeups per day | ~172,800 | `0.5s interval x 86,400s/day x 2 wakeups/s` |
| Max clipboard text size | 32,000 bytes (maxTextByteCount) | `ClipboardHistorySQLite.swift:281,285` |
| Max clipboard image size per format | 15 MB (15 x 1024 x 1024 bytes, maxImageByteCount) | `ClipboardImageCapture.swift:19-35` |
| Max disk use per image entry | up to 30 MB (PNG + TIFF each capped at 15 MB) | `ClipboardHistorySQLite.swift:186-188,247-248` |
| In-memory recent window limit | 1,000 rows (inMemoryRecentWindowLimit) | `ClipboardHistoryStore.swift:10,350` |
| FTS search result cap | 200 rows (searchResultLimit), no truncation indicator | `ClipboardHistoryStore.swift:366-376` |
| Default/forced retention period | 30 days | `ClipboardCaptureService.swift:154-169` |
| Reported thumbnail dimensions (conflicting) | 64x128 px in some evidence, 128x128 px in other evidence | `ClipboardImageCapture.swift:60-107 vs 52-106,61,94-106` |
| Typical thumbnail PNG size | 10-40 KB | `ClipboardImageCapture.swift:61` |
| Code preview font size | 11.5 pt, regular weight, monospaced | `ClipboardInspectorPane.swift:111` |
| Link preview line cap | lineLimit(6) | `ClipboardInspectorPane.swift:67` |
| Clipboard filter options | 4 (all, text, files, images) | `SearchItem.swift:68` |
| parseCodeHint recognized languages | 3 (JSON, Code, HTML) | `ClipboardInspector.swift:272-298` |
| Rebuilt extension literals per call | 13 imageExtensions strings, 11 videoExtensions strings | `ClipboardInspector.swift:218-225` |
| Clipboard projection display cap | 80 rows | `SearchResultProjection.swift line 436` |
| Screenshot decode bitmap estimate | ~80 MB RGBA for a 6016x3384 image | `ClipboardInspectorPane.swift:145, macOS bitmap math` |
| Inspector image frame max height | 180 points | `ClipboardInspectorPane.swift:149` |
| Schema migration steps at every init | 7 ALTER TABLE statements, 3 triggers dropped and recreated | `SearchCoordinator.swift:158-210` |
| Text entry cap | 32,000 UTF-8 bytes (32 KB) | `ClipboardHistoryStore.swift:8` |
| In-memory recent window | 1,000 entries | `ClipboardHistoryStore.swift:10` |
| FTS search result limit | 200 (queries ≥3 UTF-8 bytes) | `ClipboardHistoryStore.swift:11` |
| Per-image-representation cap | 15 MB (15*1024*1024) applied independently to PNG and TIFF | `ClipboardHistoryStore.swift:9` |
| Thumbnail size | 128x128 px PNG (64pt @2x), typically 5-15 KB | `ClipboardImageCapture.swift:7-8,61` |
| Capture poll interval | 0.5s Timer, 0.2s tolerance, .common RunLoop mode | `ClipboardCaptureService.swift:178-186` |
| Idle wakeups per day | 172,800 | `ClipboardCaptureService.swift:184` |
| isEnabled UserDefaults reads | 2 per call, ~4/sec at 2 Hz poll rate | `ClipboardCaptureService.swift:139-145` |
| Default retention | 30 days | `ClipboardCaptureService.swift:159` |
| Full-screen TIFF size | ~80 MB uncompressed (6016x3384x4) | `ClipboardImageCapture.swift:20-21,38` |
| TIFF vs PNG size ratio | 5-20x for mid-size images | `ClipboardHistoryStore.swift:9` |
| ClipboardEntry stride | ~120 bytes | `ClipboardEntry.swift:46-53` |
| 1000-entry memmove cost | ~120 KB moved, ~10-15 microseconds | `ClipboardHistoryStore.swift:331,254` |
| Search performance budget | under 2 ms across 1,000 entries and 8 queries | `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:71-78` |
| 32KB entry rendered line count | ~550-600 lines at 12.5pt in a 312pt pane | `ClipboardInspectorPane.swift:11-21` |
| Inspector image render size vs stored thumbnail | 180pt (360px retina) rendered vs 128px stored | `ClipboardInspectorPane.swift:145` |
| SQLite prepare/finalize sites with no statement cache | 8 call sites | `ClipboardHistoryStore.swift:128-139,219-248,266-270,307-325,417-423,444-449,480-485,516-521` |
| SQLite sites with early-return risk before finalize | 9 call sites | `ClipboardHistoryStore.swift:138,271,250,327,424,450,486,522` |
| ClipboardCaptureServiceTests poll+assert sites | ~25 | `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift:97,106,121,299` |
| maxTextByteCount | 32,000 bytes | `ClipboardHistoryStore.swift:8` |
| maxImageByteCount (per PNG or TIFF blob) | 15,728,640 bytes (15 MB) | `ClipboardHistoryStore.swift:9,398-403` |
| Worst-case single image entry size | ~30 MB (png_data + tiff_data, 15 MB each) | `ClipboardHistoryStore.swift:245-247,398-403` |
| inMemoryRecentWindowLimit | 1000 (recentEntries only; pinnedEntries uncapped) | `ClipboardHistoryStore.swift:10,351-353` |
| searchResultLimit (FTS path) | 200 rows | `ClipboardHistoryStore.swift:11,370-373` |
| Short-query path result cap | none (queries under 3 UTF-8 bytes) | `ClipboardHistoryStore.swift:353-361,376` |
| Capture poll interval / tolerance | 0.5s interval, 0.2s tolerance (40% slack) | `ClipboardCaptureService.swift:129,178-186,184` |
| Default clipboard retention | 30 days | `ClipboardCaptureService.swift:154-161` |
| Retention -1 sentinel behavior | falls to .days(30), not .forever | `ClipboardCaptureService.swift:154-162` |
| Clipboard thumbnail size | 128x128 px (64pt point size x 2x scale) | `ClipboardImageCapture.swift:6-8,60-68` |
| Inspector pane width | 340pt | `FloodlightMetrics.swift:13` |
| FTS5 triggers on clipboard_fts | 3 (clipboard_entries_ai, _ad, _au) | `ClipboardHistorySQLite.swift:220-265` |
| classifyFile local extension-list sizes | 13 image extensions, 11 video extensions | `ClipboardInspector.swift:218-225` |
| Extension-list literal size (Swift small-string threshold) | <=5 UTF-8 bytes each, no heap allocation | `ClipboardInspector.swift:218-225` |
| classifyFile calls per SwiftUI body pass | ~2 (clipboard mode ceiling) | `ClipboardInspector.swift:106-115,150-157; SearchView.swift:220,470` |
| parseCodeHint substring scans | roughly 6-10 contains scans per call | `ClipboardInspector.swift:272-298,284-296` |
| SearchResultFilter.clipboard chip count | 4 (.all, .text, .files, .images) | `SearchItem.swift:68-73` |
| ClipboardHistoryPerformanceTests fixture composition | 10 strings total, 5 code/shell | `ClipboardHistoryPerformanceTests.swift:11-22` |
| UserDefaults keys for clipboard persistence | 2 (clipboard-history-enabled, clipboard-history-retention-days) | `ClipboardCaptureService.swift:105-106` |

### Gotchas

- Choosing "Forever" retention does not work: the retention getter maps any non-positive value (including the -1 "forever" sentinel) to 30 days, so entries are still deleted after 30 days from the next launch. `ClipboardCaptureService.swift:154-169`
- Disabling then re-enabling clipboard capture backfills everything copied while it was off, because lastChangeCount is never re-baselined on disable/enable. `ClipboardCaptureService.swift:232-242`
- Turning capture off via UserDefaults directly (as OnboardingSession does) skips the isEnabled setter's re-baseline step entirely. `OnboardingSession.swift:49`
- The polling timer keeps firing every 0.5 seconds even when capture is disabled — disabling only skips the pasteboard read/save inside the handler, not the timer wakeup. `ClipboardCaptureService.swift:232-233,178-181`
- The default Return action and the footer's "Paste to <app>" button never actually paste — they only write the pasteboard and dismiss, with no synthetic Command+V. `SelectedResultActionPerformer.swift:156-163`
- The footer names the source app (where the entry came from), not the app you're about to paste into. `SearchView.swift:469-470,481-487`
- Pressing Return on a clipboard URL copies the URL text again instead of opening it. `SelectedResultActionPerformer.swift:157-163`
- The "copy" action on an image row copies the row's title text, not the image — writeImageDataToClipboard exists in code but is never invoked for image rows. `SelectedResultActionPerformer.swift:246,13`
- Excluding a clipboard item from search calls the local file-search blocklist with the clipboard entry's title, polluting an unrelated blocklist, and swaps the visible results to local-search output while still nominally in clipboard mode. `SearchCoordinator.swift:391-400; SearchResultProjection.swift:205`
- QuickLook/Space preview writes full clipboard image blobs (up to 15 MB) to a temp directory that is never cleaned up. `SearchCoordinator.swift:435-459,449-457`
- Pin-emoji prefixes on titles are read aloud by VoiceOver as part of the item name, and are also what gets dragged out (not the underlying copied text). `SearchResultProjection.swift:285,396-401; SearchView.swift:450`
- SVG is treated as an image by the inspector but not by the thumbnail generator — inconsistent classification of the same file type. `ClipboardInspector vs FileThumbnailCache`
- imageFormatName always reports "PNG" regardless of the image's actual width, height, or real format. `ClipboardInspector.swift:327-328`
- "clip" (the keyword that enters clipboard mode) is not a registered KeywordEngine, so it shows no ranked row or tab-completion hint even though typing it and pressing Tab is the only way in. `SearchMode.swift:92`
- Command+5 through Command+9 have no filter binding in clipboard mode but are still swallowed by the panel's blanket Command+1-9 check, so they never reach the text field. `FloodlightPanel.swift:319-325`
- The clipboard list does not refresh in real time — a new copy made while the panel sits open in clipboard mode is not shown until the next query change, mode switch, or pin/delete. `SearchCoordinator.swift:503-506,657-680`
- OnboardingSession.clipboardHistoryEnabled writes the shared UserDefaults key directly without notifying ClipboardCaptureService, so any future cached copy of the flag inside the service would go permanently stale. `OnboardingSession.swift:40-51; ClipboardCaptureService.swift:146-151`
- ClipboardFooterBar's sourceApp label shows the app the clipboard content was copied FROM, not the app it will be pasted TO — an easy misreading at a glance. `SearchView.swift:469-470,486; ClipboardInspector.swift:78-82,98,360`
- filePaths() already canonicalizes paths internally, so poll()'s extra compactMap(ClipboardFileReference.canonicalize) call is doing redundant work. `ClipboardCaptureService.swift:258,36-38,93-100`
- AppKitPasteboardObserver only ever reads .string, .png, and .tiff pasteboard types — there is no RTF, RTFD, HTML, or NSAttributedString path anywhere in the codebase, so rich-text pastes are silently flattened to plain text. `ClipboardCaptureService.swift:6-14,32-46`
- The "Forever" retention option is a UI-only concept: the UI labels -1 as "Forever" but ClipboardCaptureService.retention's getter treats any non-positive stored value as .days(30), so the setting can never actually persist as forever. `OnboardingView.swift:319; ClipboardCaptureService.swift:154-170`
- Even though clipboardInspector recomputes on every keystroke, ClipboardInspector and TextDetail are Equatable — SwiftUI can still skip the visible re-layout when the new snapshot compares equal to the old one. `ClipboardInspector.swift:6,30`
- buildClipboardFileRow only ever emits a single-element .copyFiles array even though SelectedResultActionPerformer.writeFiles is built to accept multiple files at once. `SearchResultProjection.swift:356; SelectedResultActionPerformer.swift:48-62`
- imageFormatName(width:height:) looks like it computes something from its width/height parameters but is actually a constant-return function that never uses them. `ClipboardInspector.swift:327-329`
- Any early return added inside ClipboardCaptureService.start() has to come after the pruneOnSchedule() call, otherwise retention cleanup silently stops running for users with capture disabled. `ClipboardCaptureService.swift:172-207`
- ClipboardHistoryStore.init's else-branch database-URL fallback is unreachable dead code — SearchCoordinator always constructs the store with an explicit URL. `ClipboardHistoryStore.swift:21-31; SearchCoordinator.swift:201-206`
- A rich-formatted copy round-tripped through clipboard history is silently flattened to plain text — only .string is ever captured or restored. `ClipboardCaptureService.swift:279-283; SelectedResultActionPerformer.swift:42-46`
- An oversized text entry is silently dropped (no record, no truncated flag) rather than truncated-and-flagged, so a later copy of that same clipboard event simply never appears — and if it did get through partially, the paste would deliver silently incomplete data. `ClipboardCaptureService.swift:281; ClipboardHistoryStore.swift:285-287`
- SelectedResultActionPerformer.copyValue's .copyImage case writes item.title (a string) to the pasteboard instead of actual image bytes — a distinct, buggy code path from the correct one used by activate()'s .copyImage case. `SelectedResultActionPerformer.swift:246-247 vs. 172-180`
- buildClipboardImageRow sets no fileURL, so dragging a screenshot row drags the literal string "Image" rather than any image data. `SearchResultProjection.swift:363-393`
- ClipboardInspector.imageExtensions includes svg but FileThumbnailCache.imageExtensions does not, so svg clipboard entries can never get a thumbnail in the media-preview branch. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43; ClipboardInspectorPane.swift:133-134`
- clipboardInspector is an uncached computed property rebuilt from scratch on every access, and SearchView reads it twice per body pass (lines 220 and 470), doubling the rebuild cost in clipboard mode. `SearchCoordinator.swift:647-655; SearchView.swift:220,470`
- ClipboardFooterBar advertises "Actions ⌘K" but no ⌘K case exists in panelCommand, and the footer shows no pin/delete hint even though both actions exist and are keyboard-reachable. `SearchView.swift:466-528,505-512`
- excludeFromSearch has no mode guard and runs identically in web and clipboard mode; in clipboard mode it drops all local rows via sourceCandidates: [] without switching the coordinator's mode — though this self-heals on the next keystroke. `SearchCoordinator.swift:391-403; SearchResultProjection.swift:186,205`
- None of delete(id:), clear(), or prune() ever reclaim SQLite disk space (no VACUUM anywhere in the codebase), and secure_delete is never set, so deleted plaintext can persist on disk, including lingering in old WAL frames until a checkpoint. `ClipboardHistoryStore.swift:476,499,512; ClipboardHistorySQLite.swift:14-50`
- clear() discards the sqlite3_exec return value and zeroes in-memory state unconditionally, with no check that the DELETE actually succeeded — unlike prune(), which re-derives totalCount and self-corrects on error. `ClipboardHistoryStore.swift:503,526`
- SearchCoordinator.clearHistory() looks like a production entry point but has zero production callers — only two test call sites reference it. `SearchCoordinator.swift:639-644; SearchCoordinatorClipboardModeTests.swift:266,277`
- deleteSelection()/clearHistory() and every other code path never delete files written to NSTemporaryDirectory()/FloodlightClipboardPreviews, so preview files accumulate indefinitely. `SearchCoordinator.swift:635-644,451`
- A stored retention preference of -1 does not mean "forever" as one might assume — it falls through to a 30-day default. `ClipboardCaptureService.swift:154-162`
- The FTS5 delete/update triggers must supply byte-identical text to what the insert trigger indexed, or the FTS5 index silently desynchronizes from clipboard_entries. `ClipboardHistorySQLite.swift:225-262`
- The image capture branch in poll() runs before the text branch, so any copy event carrying both an image and a string flavor is captured only as an image, never as text. `ClipboardCaptureService.swift:258,266,280,266-281`

### Corrected on review

- ~~Clipboard retention pruning has no enforcement mechanism at all.~~ → pruneOnSchedule() is called once, at app launch, from ClipboardCaptureService.start() (invoked by AppDelegate) — so retention is enforced, but only as of the last boot time, not continuously in the background. `ClipboardCaptureService.swift:176,287`
- ~~A pasted document can be hundreds of KB.~~ → ClipboardHistoryStore hard-caps entry text at 32,000 UTF-8 bytes (32 KB). `ClipboardHistoryStore.swift:8`
- ~~Path detection triggers up to 1,000 stat syscalls per keystroke.~~ → ClipboardInspector.parseLocalPath does no disk access unless the trimmed text is single-line and starts with /, ~/, or file://; the dominant projection cost is repeated whole-string scanning in the parse helpers, not filesystem stats. `ClipboardInspector.swift:235-253; SearchResultProjection.swift:196-213,277-324`
- ~~previewableSelectionURL evaluation is limited to clipboard mode.~~ → previewableSelectionURL evaluation runs on every Space keypress in both clipboard and non-clipboard modes. `FloodlightPanel.swift:291-295`
- ~~AppDelegate.clipboardCapture's initializer (lines 19-21) forces SearchCoordinator construction.~~ → AppDelegate.installGlobalHotKey (line 34) forces SearchCoordinator construction by writing model.activeShortcutDisplayName; clipboardCapture's lazy property just reads the already-built store. `AppDelegate.swift:34,111`
- ~~Image capture work runs on every 0.5-second poll interval.~~ → poll() early-exits on an unchanged pasteboard changeCount, so image decode/insert cost is paid only per actual image copy, not every timer tick. `ClipboardCaptureService.swift:237`
- ~~Caching the UserDefaults-backed isEnabled flag would be a beneficial optimization.~~ → isEnabled already reads through macOS's cached CFPreferences layer (~4 reads/sec, effectively free); adding a manual cache would introduce a staleness bug because OnboardingSession writes the same key directly without notifying the service. `ClipboardCaptureService.swift:141-144; OnboardingSession.swift:43-49`
- ~~Splitting the observable class would remove SQLite/LaunchServices work from the selection-navigation path.~~ → The recompute is inherently selection-driven and independent of which class owns the observable state, so splitting the class alone would not remove the SQLite or LaunchServices calls from that path. `SearchCoordinator.swift:647-655; SearchView.swift:220,470`
- ~~Reordering installGlobalHotKey removes SearchCoordinator construction from the launch critical path.~~ → installGlobalHotKey itself is what touches activeShortcutDisplayName and forces lazy SearchCoordinator construction; reordering only shifts when that work happens, it does not remove it. `AppDelegate.swift:111`
- ~~Clipboard search scans roughly 1,000 rows on every keystroke regardless of query length.~~ → Empty and 1-2 byte queries scan the unbounded in-memory window (up to 1,000), but queries of 3+ bytes go through FTS5 capped at searchResultLimit (200). `ClipboardHistoryStore.swift:353-361,370,376`
- ~~Duplicate image-extension lists across files cause generally inconsistent image detection.~~ → Specifically, ClipboardInspector.swift:221 lists svg as an image extension but FileThumbnailCache.swift:40-43 does not, which causes SVG clippings to render a blank preview that shows the previous entry's image indefinitely. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43,48`
- ~~Each clipboard search binds around 5 NSString bridges per query.~~ → search() binds exactly one text parameter and one integer parameter to its prepared statement. `ClipboardHistoryStore.swift:375-376`
- ~~Pruning risks losing pinned-adjacent history.~~ → The prune SQL explicitly exempts pinned entries (WHERE pinned_at IS NULL AND created_at < cutoff), so only unpinned entries older than the retention window are at risk. `ClipboardHistoryStore.swift:516`
- ~~The ORDER BY pinned_at IS NOT NULL DESC sort is an O(n log n) full-history sort.~~ → search() binds searchResultLimit (200) into the LIMIT clause, so the sort retains at most 200 records — O(matches log 200), not full-history. `ClipboardHistoryStore.swift:11,376`
- ~~formattedDetailedDate() creates 4 DateFormatters per call.~~ → It creates at most two DateFormatters per call (one at line 312, a second at line 321 for non-today/yesterday dates); the property that reads it is what gets invoked 2-4 times per render. `ClipboardInspector.swift:310-325,312,321`
- ~~ClipboardCaptureService.retention's setter has callers that depend on .forever round-tripping correctly.~~ → The setter writes -1 for .forever but has zero callers anywhere in Sources/ — .forever is write-only dead code. `ClipboardCaptureService.swift:166-167`
- ~~A multi-MB preview write to disk happens on every Space keypress.~~ → clipboardImagePreviewURL's write is guarded by a fileExists check, so the multi-MB write happens at most once per entry id for the life of the temp directory. `SearchCoordinator.swift:455-456`
- ~~Removing the TIFF blob would roughly halve row growth, capping images at 30 MB per screenshot.~~ → TIFF is 5-20x the PNG size for mid-size images, so removing it cuts the stored row by roughly 85-90 percent. `ClipboardHistoryStore.swift:9`
- ~~Search/ClipboardInspectorPane.swift:213 is where the Format row is rendered.~~ → The Format row is rendered via infoRow(label:value:) with detail.format at ClipboardInspectorPane.swift:213 (no "Search/" prefix in the path). `ClipboardInspectorPane.swift:213`
- ~~There are three identical copies of the image-extension list across the codebase.~~ → ClipboardInspector.imageExtensions includes ico, icns, and svg, but FileThumbnailCache.imageExtensions omits svg — the lists have diverged, not stayed identical. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43`
- ~~The performance-test fixture is mostly code and shell strings.~~ → The fixture has 10 strings total, of which 5 are code/shell types. `ClipboardHistoryPerformanceTests.swift:11-22`
- ~~The extension-list construction costs roughly ~24 String allocations.~~ → All extension-list literals are 5 bytes or fewer in UTF-8, fitting Swift's small-string form, so there is no heap allocation at all. `ClipboardInspector.swift:218-225`
- ~~classifyFile's extension-list cost needed per-keystroke performance optimization.~~ → classifyFile runs at most ~2 times per SwiftUI body pass in clipboard mode, and its real cost is dominated by FileManager syscalls, not Set/String allocation. `ClipboardInspector.swift:106-115,150-157; SearchCoordinator.swift:647; SearchView.swift:220,470`
- ~~Forever retention mode works correctly once the user selects it.~~ → A stored retention value of -1 falls through to .days(30) instead of .forever. `ClipboardCaptureService.swift:154-162`
- ~~A single image clipboard entry is capped at 15 MB.~~ → An entry can store up to ~30 MB, because png_data and tiff_data are each capped at 15 MB independently and both are bound into the same row. `ClipboardHistoryStore.swift:245-247,398-403`
- ~~The FTS5 trigger fix is independent per trigger.~~ → The delete/update triggers (_ad, _au) must receive byte-identical text to what the insert trigger (_ai) indexed, or the FTS5 index desynchronizes. `ClipboardHistorySQLite.swift:225-262`
- ~~The same 32 KB size cap applies to all clipboard content types.~~ → maxTextByteCount = 32,000 gates only plain text; rich HTML flavors of styled paragraphs routinely exceed 32 KB and are not comparably capped. `ClipboardHistoryStore.swift:8`
- ~~Clipboard history is capped at 1,000 total entries.~~ → Only state.recentEntries is capped at inMemoryRecentWindowLimit (1000); state.pinnedEntries is uncapped. `ClipboardHistoryStore.swift:255,332,456`
- ~~Both the short-query and FTS search paths have consistent result caps.~~ → The short-query path (under 3 UTF-8 bytes) has no cap at all, while the FTS path caps at 200 rows. `ClipboardHistoryStore.swift:353-361,376`
- ~~The wrong publication state left by excludeFromSearch in clipboard mode is sticky.~~ → It self-heals: the next keystroke or filter click re-enters the clipboard branch and republishes correctly. `SearchCoordinator.swift:503-508,360`
- ~~Exclusion (blocklist) logic is blocked only in clipboard mode.~~ → The gate only excludes clipboard mode; it should instead check `guard case .local = mode else { return }` so every non-local mode is excluded, not just clipboard. `SearchCoordinator.swift:391`
- ~~Digit-key rebinding behaves the same regardless of mode.~~ → Any digit rebinding for clipboard mode must be scoped to model.isClipboardMode or it breaks the existing Command+5 first-dynamic-filter behavior elsewhere. `FloodlightPanel.swift:345-350`
- ~~SearchCoordinator.clearHistory() is an active production function.~~ → It has no production caller at all; only two test call sites in SearchCoordinatorClipboardModeTests.swift invoke it. `SearchCoordinator.swift:639-644; SearchCoordinatorClipboardModeTests.swift:266,277`
- ~~Clipboard thumbnail PNGs reach 10-40 KB.~~ → Thumbnails are capped at 128x128 px (64pt point size x 2x scale) in ClipboardImageCapture. `ClipboardImageCapture.swift:6-8,60-68`

<a id="swift-shell-ui-launch"></a>
## Floodlight: launch order, panel, hotkeys, SwiftUI, caches

Floodlight is a macOS Spotlight-style launcher panel built with SwiftUI+AppKit over a Rust/C search engine (fff). At launch, AppDelegate sets an accessory activation policy, wires LaunchAtLogin through SMAppService, installs a hand-built NSApp menu bar (discarding SwiftUI's own .commands), and registers one global Carbon hotkey (Command-Space or Option-Space) that toggles a lazily-allocated NSPanel. Inside the panel, SwiftUI renders a virtualized LazyVStack of up to 7 result rows, backed by three separate NSCache-based caches (AppIconCache, FileIconCache, FileThumbnailCache) with different size limits and different cache-miss costs. In-panel keyboard handling is a patchwork: a small panelCommand table (c/l/r/shift-r/y/return/period/d), a separate text-editing-command intercept that runs first, and raw key-code monitors for arrows and the space bar — several shortcuts users might expect (Command-K, Command-Backspace, Command-O) are not actually wired up, and one (Command-K) is even advertised in the UI as dead code. Assistant CLI invocation (Ask Claude/Codex) goes through AssistantProcessRunner, which re-resolves the executable's path on every single call, with no caching, including a possible login-shell PATH probe. Underneath, the Swift layer talks to the fff Rust/C engine through FFFIndex with a fixed set of content-search and caching parameters, plus a handful of known path-translation and lifecycle rough edges. Ten places in the source batch explicitly correct an earlier, wrong claim; two places have conflicting, unreconciled claims about the same code.

### App launch and menu bar lifecycle

- AppDelegate sets the app's activation policy to .accessory. `AppDelegate.swift:30` `F50`
- LaunchAtLogin.enableOnFirstRun() is called from AppDelegate.applicationDidFinishLaunching on the main thread; it checks SMAppService.status before calling service.register(), talking to the ServiceManagement daemon at launch. `AppDelegate.swift:35,36; LaunchAtLogin.swift:57-72` `F` `F22` `F65`
- If registration throws, enableOnFirstRun does not persist the configuredKey flag, so registration is retried on every subsequent launch until it succeeds. `LaunchAtLogin.swift:70-76` `F`
- registerIfNeeded first guards its whole body on defaults.bool(forKey: configuredKey); once registration has succeeded once, later launches take this early-return path with zero SMAppService/XPC round trips. `LaunchAtLogin.swift:57-77` `F59:accuracy`
- On a failure path, registerIfNeeded makes up to three separate XPC round trips to the ServiceManagement daemon: status() (line 60), register() (line 71), and requireEnabledStatus (line 107); SMAppService.status/register are themselves XPC calls. `LaunchAtLogin.swift:57-77,107; LaunchAtLogin.swift:60-72` `F59:accuracy` `F`
- AppDelegate.makeConfiguration also reads LaunchAtLogin.launchesAtLogin, which triggers another independent SMAppService.status call. `AppDelegate.swift:321` `F`
- LaunchAtLoginController's default parameter (service: any LaunchAtLoginService = SMAppService.mainApp) is evaluated unconditionally at the call site, ahead of any guard inside enableOnFirstRun. `LaunchAtLogin.swift:37,58` `F65`
- LaunchAtLoginController and the LaunchAtLogin enum are both @MainActor. `LaunchAtLogin.swift:4,28` `F59:accuracy`
- AppDelegate.installMenu() unconditionally overwrites NSApp.mainMenu with a hand-built menu, discarding any menu items SwiftUI's .commands would otherwise merge in; makeMainMenu() hand-constructs the app menu (Show/Settings/Scope/Rebuild/Quit) and Edit menu (Undo/Redo/Cut/Copy/Paste/Select All). `AppDelegate.swift:205-207,209-297` `F64`
- FloodlightApp declares a Settings { EmptyView() } scene with CommandGroup(replacing: .appSettings) given an empty body. `FloodlightApp.swift:7-16` `F`
- SwiftUI does not evaluate a scene's body until its window is opened; since this Settings window is never opened, the EmptyView body is never evaluated and the scene contributes no launched-window cost. `FloodlightApp.swift:7-16,9,11-16` `F64`
- All window management in Floodlight uses AppKit directly — NSHostingController at FloodlightPanel.swift:158 and FloodlightConfigurationWindowController.swift:107 — rather than SwiftUI WindowGroup/Settings scenes. `FloodlightPanel.swift:158; FloodlightConfigurationWindowController.swift:107` `F64`
- Swapping the @main App entry point for a main.swift top-level-code entry point would change the SwiftPM link path; 30 test files currently use @testable import Floodlight. `Tests/FloodlightTests (30 files)` `F64`
- FloodlightMenuBarIcon loads FloodlightMenuBar.svg (a 418-byte asset with two path elements, copied into the app bundle by scripts/bundle.sh:30) or falls back to NSBezierPath drawing, at 18x18 template size. Its image() method calls NSImage(contentsOf:), parsing the SVG synchronously through CoreSVG on the main thread, and is called exactly once, at AppDelegate.swift:125 (NSImage is non-Sendable without @MainActor isolation). `FloodlightMenuBarIcon.swift:6-15; scripts/bundle.sh:30; AppDelegate.swift:125` `F` `F67`

### Global hotkey registration

- installGlobalHotKey reads UserDefaults and performs the Carbon hotkey registration call on the main thread during launch. `AppDelegate.swift context` `F22`
- GlobalHotKeyRegistration holds exactly one activeRegistration and one onPressed callback; handle() gates dispatch by checking event.identifier == activeRegistration?.identifier, enforcing single-dispatch. `GlobalHotKeyRegistration.swift:69-73,132-160,242,264,273,277` `F32` `F124` `F131`
- allocateIdentifier() increments and returns an identifier; firstIdentifier defaults to UInt32(1) in the designated init, which exposes it as module-internal, while the convenience init does not expose that parameter. `GlobalHotKeyRegistration.swift:91-96,94,264-271,80-89` `F131`
- AppDelegate creates exactly one GlobalHotKeyRegistration instance. `AppDelegate.swift:15` `F131`
- CarbonGlobalHotKeySystem hard-codes UInt32(kVK_Space) as the registered key code and is file-private, forcing AppDelegate to use the convenience init instead. `GlobalHotKeyRegistration.swift:356-358,304` `F32` `F131`
- FloodlightShortcut is a String-rawValue, CaseIterable enum with only two cases, .commandSpace and .optionSpace; the two cases vary only in carbonModifiers, never in keyCode. `Sources/Floodlight/App/GlobalHotKey.swift:4-6,33; GlobalHotKeyRegistration.swift:357` `F32` `F131`
- GlobalHotKey.fallback is a total function over exactly those two FloodlightShortcut cases, and GlobalHotKeyRegistration.start(preferred:) relies on that totality. `GlobalHotKey.swift:40-45; GlobalHotKeyRegistration.swift:128` `F131`
- GlobalHotKeyRegistration.supportsConcurrentRegistrations = true, even though only one registration can ever be active at a time. `GlobalHotKeyRegistration.swift:306` `F131`
- FloodlightShortcut.preferenceKey = "global-shortcut" is a single static UserDefaults key used by both save(in:) and preferred(in:). `GlobalHotKey.swift:8,51-53` `F131`
- OnboardingView.swift:121 iterates FloodlightShortcut.allCases to build the hotkey radio group; GlobalHotKey.swift:29-31 hardcodes each shortcut's displayName as "\(modifierSymbol) Space"; OnboardingView.swift:465 separately hardcodes a ShortcutPreview KeyCap with symbol "space". `OnboardingView.swift:121,465; GlobalHotKey.swift:29-31` `F131`

### In-panel keyboard handling

- FloodlightPanel.panelCommand(for:shiftHeld:) binds exactly these keys: c, l, r, shift+r, y, Return/newline, period (.), and d; everything else returns .unmatched. `FloodlightPanel.swift:368-387,365-390` `F` `F27` `F103` `F106` `F138`
- Command-K is not among the bound keys — it returns .unmatched from panelCommand and falls through to AppKit, producing no action. No .keyboardShortcut modifier or Command-K binding exists anywhere under Sources/Floodlight. Yet the Actions chip in the UI still advertises Command-K, which is dead code — the chip actually performs the Command-C verb instead. `FloodlightPanel.swift:368-390; SearchView.swift:501-518` `F` `F106` `F127`
- panelCommand(for:shiftHeld:) already threads a shiftHeld flag through its signature, but never receives any option-key flag information. `FloodlightPanel.swift:368` `F121`
- handleCommandKeyEquivalent (gated on .command being held) lowercases charactersIgnoringModifiers and calls performSearchTextEditingCommand before panelCommand, so text-editing shortcuts are intercepted first. `FloodlightPanel.swift:306-311,313-317,315` `F103` `F121`
- performSearchTextEditingCommand's case 'v' pastes into the field editor and returns true with no shift check, swallowing Shift-V combinations; the function's own signature takes no shiftHeld parameter at all. `FloodlightPanel.swift:401,388-392` `F103` `F121`
- FloodlightTextField.fieldCommand matches insertNewline and insertNewlineIgnoringFieldEditor in the same case, and never inspects .shift either. `FloodlightTextField.swift:37-44` `F134`
- FloodlightTextField.commandSelector does not handle moveUp/moveDown (they map to nil); instead, raw key codes 125 and 126 are monitored separately by a local NSEvent monitor in FloodlightPanel, which returns nil for those codes so they never reach the field editor. `FloodlightTextField.swift:55-56,190-192; FloodlightPanel.swift:283-288,286,289` `F30` `F130`
- commandDigit accepts any single character with a wholeNumberValue, consuming Command+0 through Command+9; the handler's return true swallows every Command-digit keypress regardless of whether the digit is in range. `FloodlightPanel.swift:431-440,319-329` `F129`
- Option+1 through Option+9 produce nothing useful in the text field editor and claim no system shortcut. `FloodlightPanel.swift` `F129`
- No Command+Backspace (key code 51) binding exists anywhere in the Floodlight sources, and Command-O is likewise unclaimed. `Sources/Floodlight/App/FloodlightPanel.swift` `F123` `F135`
- AppDelegate registers NSMenuItem key equivalents only for: Space, comma, l, shift-r, q, z, shift-z, x, c, v, a. FloodlightPanel.performKeyEquivalent calls its keyEquivalentHandler before calling super.performKeyEquivalent. `AppDelegate.swift:214-291; FloodlightPanel.swift:17-22` `F138`
- docs/keyboard-shortcuts.mdx documents only Cmd-1 through Cmd-5, Cmd-C, Cmd-R, Cmd-Y, Cmd-L, and Shift-Cmd-R — it omits Cmd-period and Cmd-D even though both are functional. `docs/src/content/docs/guides/keyboard-shortcuts.mdx` `F5`
- The results footer hand-rolls its own key-chip styling instead of reusing the shared KeyChip component used elsewhere in ResultRow and the rest of SearchView. `SearchView.swift:487-494,508-518,142; ResultRow.swift:98,108` `F106`
- Space-bar handling (case 49 in FloodlightPanel's keyDown switch) eagerly evaluates all three arguments to shouldHandleSpaceAsPreview before the conditional gate short-circuits, and runs on the main thread on every keyDown while the panel is visible; this case and togglePreview are the only two guards on the QuickLook preview write path. `FloodlightPanel.swift:289-296,290-298,232,294; FloodlightPanel.swift:74-76,278-295` `F6` `F41` `F167`
- Search scope defaults to the home folder and is user-toggleable via Cmd-L, with the chosen scope persisting across launches. `indexing.mdx` `Documentation & Architecture cluster`

### Panel show/hide lifecycle and window metrics

- showSearch forces the lazy panelController property, which allocates an NSPanel hosting SearchView plus an NSGlassEffectView. `FloodlightPanel.swift:36-102,154-174` `F50`
- A "ShowPanel" OSSignpost wraps FloodlightPanel.show()'s startup work, marking when the panel becomes visible to the user. `FloodlightPanel.swift:197-198` `F50` `F61`
- FloodlightPanel.show() is at line 196 and calls NSApp.activate(ignoringOtherApps: true) at line 201, inside show(). `FloodlightPanel.swift:196-212` `F95`
- A local NSEvent monitor for .keyDown is registered on this @MainActor class. `FloodlightPanel.swift:25,74-75` `F90`
- Panel makeKey happens before FloodlightTextField.requestFocus finishes its deferred makeFirstResponder call — but FloodlightTextField early-returns when window.firstResponder is already the editor, so on the steady-state focus path this async hop is a no-op, correcting a claim that it runs an async makeFirstResponder on the hot path on every summon. `FloodlightPanel.swift:202; FloodlightTextField.swift:108,110-117` `F7` `F73`
- FloodlightPanelController.hide() calls model.reset(), which sets mode back to .local; hide() calls QuickLookController.close() before model.reset(). `FloodlightPanel.swift:206,209,211` `F20` `F119-value`
- A copy made in another app while the panel is visible triggers NSApplication.didResignActiveNotification, which dismisses and resets the panel — correcting a claim that a stale result list is easily reachable. `FloodlightPanel.swift:77-87` `F124`
- FloodlightPanel.resize(to:) returns early if abs(frame.height - height) <= 0.5pt, before it reads accessibilityDisplayShouldReduceMotion. `FloodlightPanel.swift:258,265` `F80`
- FloodlightPanel width is exactly 680 points; searchHeight is 60pt. `FloodlightMetrics.swift:6; FloodlightPanel.swift:37-44,61-66` `F108` `F77`
- FloodlightMetrics.expandedPanelHeight is actually 521pt, computed as 60+1+40+7×2+7×58 — correcting an earlier reading of 548pt. `FloodlightMetrics.swift:15-21` `F77`
- FloodlightMetrics.maximumVisibleResults is 7; SearchView renders the result list as a LazyVStack materializing up to 7-8 rows at render. `FloodlightMetrics.swift:12,15-21; SearchView.swift:381-406,385` `F25` `F129` `F81` `F82` `F83`
- SearchViewRenderingTests.swift includes a test, theCollapsedPanelRendersAtTheSearchBarHeight, pinning the idle (collapsed) render state. `Tests/FloodlightTests/SearchViewRenderingTests.swift:95-106` `F77`

### SwiftUI search view and result rendering

- SearchView.resultsContent resolves to EmptyResultsView when results.isEmpty rather than building a ScrollView/LazyVStack — correcting a claim that idle mount-time prewarms both. `SearchView.swift:207-228` `F77`
- When there are results, SearchView implements a ScrollView + LazyVStack virtualized list, so only on-screen ResultRow instances get constructed and diffed on update. `SearchView.swift:356-357,381-386` `F169` `F171`
- On macOS 26.0, SearchView.swift forks to Array(model.results.enumerated()) inside the LazyVStack, which eagerly materializes the whole results array on every body evaluation on that OS version. `SearchView.swift:396-405,402,381-387` `F82`
- SearchView.row(for:index:) re-evaluates per realized row on every keystroke; the .equatable() wrapper covers only ResultRow itself, not the .contextMenu or .onDrag modifiers attached alongside it. `SearchView.swift:408-463,423,434-459` `F81` `F82` `F107`
- SearchItem.iconSource has three cases: .inferred, .engine(symbol:tint:), and .thumbnail(Data); SearchItem's synthesized Hashable/Equatable conformance walks the Data payload byte-for-byte whenever iconSource is .thumbnail. `SearchItem.swift:259-266,268-279` `F109` `F8` `F75`
- Because of that, ResultRow's .equatable() comparison of lhs.item == rhs.item amounts to a byte-level memcmp of a 10-40KB PNG on every per-row re-render diff. `ResultRow.swift:28; SearchView.swift:423` `F8`
- ResultRow does conform to Equatable, but its body still re-evaluates on hover regardless, because @State isHovered is read inside backgroundColor and set by .onHover — a state change that Equatable conformance cannot prevent. `ResultRow.swift:22,27,121,124-139` `F107`
- SearchView's frame budget is 16.7ms at 60Hz; the tens-of-microseconds overheads measured elsewhere in the render path are imperceptible against that budget. `F77,F79,F81,F82` `F77` `F79` `F81` `F82`
- ResultShowcase's date formatting uses 4-tier logic and allocates a fresh Calendar.current per call, calling startOfDay twice, dateComponents once, and .formatted() three times — all on the main actor, per row, at render time. `ResultShowcase.swift:30-53,39-40,56,60,64` `F` `F170`
- ResultRow also calls fileSize.formatted(.byteCount(style:.file)) and formattedModifiedDate on the main actor at render time. `ResultRow.swift:73,78` `F79`
- ResultRow unconditionally appends the absolute formattedModifiedDate text after the subtitle whenever modifiedAt is set, and gates fileSize display only on fileSize > 0. `ResultRow.swift:76-79,71` `F` `F105`
- ResultRow's subtitle text renders with .lineLimit(1) and no explicit .truncationMode, defaulting to .tail truncation; previewTitle is rendered the same way with lineLimit(1) and ellipsization. `ResultRow.swift:68-69,68-87,45,52` `F1` `F108` `F100`
- ResultRow renders item.title as flat, uniformly-styled text (.foregroundStyle(.primary)) with no matched-character highlighting. `ResultRow.swift:45-53,45` `F` `F107`
- The search-results footer prints the truncated result count without any indication that it has been truncated. `Sources/Floodlight/UI/SearchView.swift:475` `F15`
- SearchItem carries six heap-refcounted fields: id, title, subtitle, action payload, Data (iconSource), and fileURL. `SearchItem.swift` `F3` `F4`

### Icon and thumbnail caches

- AppIconCache is an @MainActor singleton backed by an NSCache<..., NSImage> with countLimit = 64 and no totalCostLimit. `AppIconCache.swift:4-29,14-29,15` `F5` `F71` `F74` `F109`
- AppIconCache.icon(for:) has no async path: on a cache miss it calls NSWorkspace.shared.urlForApplication(withBundleIdentifier:) and NSWorkspace.shared.icon synchronously, inside SwiftUI view-body evaluation. `AppIconCache.swift:14-29,21-27` `F71`
- AppIconCache only caches successful lookups, so every miss for an uninstalled or unresolvable bundle ID re-runs the full urlForApplication resolution on every subsequent lookup. `AppIconCache.swift:21-25` `F11`
- AppIconCache.icon(for:) is also what resolves a bundle ID to an icon for the exclusion-list UI, via urlForApplication(). `AppIconCache.swift:14-28` `F125`
- FileIconCache uses an NSCache with countLimit = 256; cachedIcon derives the file's url.path and bridges it to NSString for the cache key. `FileIconCache.swift:11,14-15` `F26` `F1`
- FileIconCache has an off-main concurrent load path used from ResultRow, separate from thumbnail loading; FileIconCache.swift documents @concurrent as precedent for the same isolation-inheritance rule used elsewhere. `ResultRow.swift:218-231; FileIconCache.swift:31-34` `F28` `F39`
- FileThumbnailCache is an @MainActor singleton with an NSCache countLimit of 128 and uses QLThumbnailGenerator concurrently to produce entries. `FileThumbnailCache.swift:19-30,33-71,12` `F165`
- Each cached thumbnail is generated at 320pt x2 (i.e. 640x640 RGBA), roughly 1.6MB per entry — making FileThumbnailCache the larger memory consumer of the two icon/thumbnail caches, correcting an earlier claim that FileIconCache was the "tens of megabytes, highest-priority" one. `FileThumbnailCache.swift:12,53` `F74`
- FileThumbnailCache.swift:66 calls NSImage(contentsOf: url), which loads the image at full resolution and ignores the requested maxDimension; a single large photo decoded this way can reach roughly 96MB in memory. `FileThumbnailCache.swift:66` `F165`
- Separately, ResultIcon.body decodes a SearchItem's thumbnail Data via NSImage(data:) on every SwiftUI body evaluation — this decode path has no cache at all. `ResultRow.swift:192-202,194-197,218-231` `F22` `F28`

### Assistant process execution

- AssistantProcessRunner.resolveExecutable first checks four hardcoded directories — /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin — via four separate FileManager.isExecutableFile stat calls. On a miss (the common case for Homebrew/npm-installed tools like codex and claude), it spawns /bin/zsh -l -c 'echo -n "$PATH"' to query the login shell's PATH, with a 5-second timeout and a 64KB max-output cap on that probe. `AssistantProcessRunner.swift:34-39,127-132,136-141,139-140` `F38` `F` `F53`
- resolveExecutable is a static func with no memoization: both isAvailable and run() re-run the entire directory scan (and potential login-shell spawn) on every single call, so pressing Return on an assistant command can trigger a fresh login-shell spawn before the CLI itself even starts. `AssistantProcessRunner.swift:109,112-113,124-152` `F39` `F53`
- AssistantProcessRunner.run spawns the process via posix_spawn inside a withCheckedThrowingContinuation; the posix_spawn/Pipe setup itself is synchronous and takes low single-digit milliseconds, but the call runs on the main thread — AssistantRunSession pins its runTask to @MainActor specifically to execute this on the main thread. `AssistantProcessRunner.swift:250,213-260,172-178; AssistantRunSession.swift:64-71` `F38` `F39` `F17`
- Output is drained on a dedicated DispatchQueue labeled "com.floodlight.assistant-output", reading in 16KB chunks via FileHandle.read, with the continuation resumed from the process's terminationHandler; a 256KB default maximum total output is enforced by an OutputDrainer that terminates the process if exceeded. `AssistantProcessRunner.swift:182-186,232-245,86,54-73,83-97` `F38` `Assistant Process Execution cluster`
- That same drain queue is used for spawned assistant processes during interactive runs — it is not, as an earlier claim held, an "availability probe" queue. `AssistantProcessRunner.swift:184` `F48` `F53`
- AssistantProcessRunner is invoked once per explicit user action (pressing Return on an "Ask Claude/Codex" result row), not per keystroke; SelectedResultActionPerformer, which triggers it from .activate, is itself @MainActor. `SelectedResultActionPerformer.swift:185,122-123` `F39`
- AssistantRunSession increments a generation counter on each run so that a stale async result (from a row the user has since navigated away from) cannot overwrite the result for a newer row. `AssistantRunSession.swift:58-93,102-110` `Assistant Process Execution cluster`

### Result actions, drag/drop, and QuickLook

- SelectedResultActionPerformer's protocol has exactly three write methods: writeString, writeFiles, writeImage. writeString calls clearContents then setString(value, forType: .string); writeFiles publishes both NSURLs and the NSFilenamesPboardType; writeImage publishes both .png and .tiff representations. `SelectedResultActionPerformer.swift:10-16,42-46,48-62,64-78` `F103`
- SelectedResultActionPerformer.activate has exactly five cases: .copy, .copyFiles, .copyImage, .open, .askAssistant. `SelectedResultActionPerformer.swift:156-191` `F110`
- RunningApplicationActivator (used when activating a running app from a result) scans NSWorkspace.shared.runningApplications with an O(n) path comparison. `RunningApplicationActivator.swift:19-27` `clipboard-capture cluster`
- SearchView's .onDrag falls back to NSItemProvider(object: item.title as NSString) when item.fileURL is nil; SearchItem.isPreviewable requires fileURL != nil. `Sources/Floodlight/UI/SearchView.swift:450-456; SearchItem.swift:309` `F133`
- ResultList's row(for:index:) attaches one unconditional .contextMenu containing a destructive item that calls model.excludeFromSearch(item). `Sources/Floodlight/UI/SearchView.swift:434-448` `F128`
- QuickLookController is a stored property on FloodlightPanel that requires QLPreviewPanelDataSource conformance at compile time, and its preview item is URL-based only — it returns an NSURL for QLPreviewItem. `FloodlightPanel.swift:29; QuickLookController.swift:5,30-38` `F65` `F119-value`
- FileThumbnailCache declares QLThumbnailGenerator.Request stored types, which require the QuickLookThumbnailing framework at compile time. `FileThumbnailCache.swift:54-58` `F65`

### Onboarding and settings UI

- OnboardingView's "Clear all history…" button is a plain Button with no confirmationDialog or .alert; the label implies confirmation but the handler wipes history immediately. `OnboardingView.swift:391-394,391` `F117-accuracy` `F117-value` `F137`
- OnboardingView's copy tells the user that excluded app names will be matched for exclusion, but the exclusion list only ever matches bundle IDs — names are never matched. `Sources/Floodlight/UI/OnboardingView.swift:331` `F125`
- The exclusion list's TextField has no validation, autocompletion, or picker for bundle IDs; the resulting exclusion chips render only the bundle ID text plus an xmark button, with no app icon or display name shown — despite AppIconCache.icon(for:) already existing to resolve a bundle ID to an icon. `Sources/Floodlight/UI/OnboardingView.swift:337-339,362-375; AppIconCache.swift:14-28` `F125`

### FFF engine: data model and configuration constants

- FFFSearchResult carries name, relativePath, url, isDirectory:Bool, score:Int, modified:UInt64, size:UInt64 — and no git-status field. `FFFModels.swift:18-44,18-26` `U2` `U64`
- FFFContentMatch carries name, relativePath, url, line:UInt64, snippet:String. `FFFModels.swift:47-67` `U2`
- FFFIndexProgress carries scannedFiles:UInt64, isScanning:Bool, isWatcherReady:Bool. `FFFModels.swift:70-80` `U2`
- FFFSearchResult.isApplicationBundle is true when isDirectory is true AND pathExtension.caseInsensitiveCompare(to: "app") == .orderedSame; makeSearchItem uses this to set kind to .application (else .folder or .file based on isDirectory), and derives the application's title from url.deletingPathExtension().lastPathComponent. `SearchItem.swift:318-320,322-347` `U5`
- An exact path match gets a score boost of 300000. `FFFIndex.swift:155` `U1`
- Frecency and history LMDB databases are stored at storageURL/frecency.lmdb and storageURL/history.lmdb (applicationSupportDirectory/FFFKit). `FFFIndex.swift:65-66` `ffi-header cluster` `U1`
- FFFIndex enables mmap caching (enable_mmap_cache = true) but passes cache_budget_max_files=0, max_bytes=0, max_file_size=0 — sources disagree on what 0 means here: one describes it as disabling in-memory caching entirely, another as "auto-size." `FFFIndex.swift:73-74,83,89` `U1` `U24`
- Floodlight passes max_threads=0 to the fuzzy search, which resolves to std::thread::available_parallelism (all logical cores). `FFFIndex.swift:126; file_picker.rs:1064-1070` `U11`
- Floodlight sets ai_mode = false, which disables the only watcher code path that writes to FrecencyTracker. `FFFIndex.swift:80; background_watcher.rs:657,673` `U10`
- Floodlight's content search has a 35ms time budget. `FFFIndex.swift:352` `U1` `U6`
- FFFIndex.searchContent calls fff_live_grep with max_file_size = 10485760 (10 MiB) and trim_whitespace: false, so full untrimmed lines are returned. `FFFIndex.swift:357; lib.rs:671` `U15`
- FFFFileSource.contentItems then interpolates the grep snippet and calls trimmingCharacters on it for multiple copies. `FFFIndex.swift:637` `U15`
- Floodlight passes combo_boost_multiplier=100 and min_combo_count=3 to fff_search. `FFFIndex.swift:201` `U3` `U14`
- With page_size=12, the internal_limit becomes 24, which triggers a partial sort for larger result sets. `score.rs:1021-1034` `U26`

### FFF engine: path/query translation and lifecycle edge cases

- resolvePathQuery translates paths like ~/code/foo and /Users/me/code/foo to root-relative form (e.g. code/foo), appending / for directory queries, before sending the query to fff_search_mixed. `FFFIndex.swift:500-541,111-127,536-538` `U13` `U8`
- However, fff_track_query is called with the original untranslated raw query while fff_search_mixed gets the translated one — this mismatch breaks QueryTracker's combo lookup. `FFFIndex.swift:440-443,111-127; query_tracker.rs:144-155` `U13` `U8`
- For any path-like query whose target exists, the exact resolved path is unconditionally pinned to result slot 0. `FFFIndex.swift:173-179` `U8`
- The two path-existence "stat" call sites (FFFIndex.swift:117-120 and 174-181) are mutually exclusive branches, gated on resolvedQuery.fffQuery.isEmpty, so exactly one stat occurs per query — correcting an earlier claim of two sequential stats needing memoization. `FFFIndex.swift:115-122,174-181` `U10`
- FileManager.default.fileExists(atPath:isDirectory:) and attributesOfItem(atPath:) both run on a single serialized FFI DispatchQueue. `FFFIndex.swift:6-7,551,560` `U10`
- Floodlight reads only relativePath and displayName off each FffMixedItem, never git_status. `FFFIndex.swift:140-148` `U22`
- Floodlight never calls fff_grep_result_get_regex_fallback_error or checks any literal-fallback flags. `FFFIndex.swift:376` `U23`
- FFFIndex.changeRoot calls fff_restart_index, which takes an exclusive picker.write() lock and drops the entire FilePicker, losing its watcher subscription. `FFFIndex.swift:426-428; lib.rs:958-1018` `U18`
- FFFFileSource.waitForScanCompletion requires two consecutive isScanning == false polls before declaring the scan complete. `FFFIndex.swift:677-687` `U19`
- The scanning flag is cleared before build_bigram_index/set_bigram_index actually run, creating a window where scan-readiness fires before the bigram index exists. `scan.rs:228,328-334` `U55`
- Sources disagree about the bound on line_content from fff_live_grep at FFFIndex.swift:395: one account says String(cString:) processes an unbounded line, up to 10 MiB for a single line; another says it strlen-scans at most 512 bytes per content query. Neither is marked as the correcting fact. `FFFIndex.swift:395; fff-c/src/ffi_types.rs:383` `U15` `U9`
- dropLast() on an Array returns an ArraySlice with no allocation. `FFFIndex.swift:151-153` `U7`
- String.lowercased() on components of 15 UTF-8 bytes or fewer uses Swift's small-string representation with zero heap allocation. `FFFIndex.swift:151-153` `U7`
- Swift's release mode still emits dynamic exclusivity checks (swift_beginAccess/endAccess) on class stored properties. `Swift language semantics` `U12`

### Tests, build, and instrumentation

- FFFIndex.swift imports CFFF (the raw C API) rather than FFFKit (the Swift wrapper); the only file in the codebase that imports FFFKit is Tests/FloodlightEngineTests/SearchModelInvariantTests.swift, which imports both FFFKit and Floodlight's own package, causing name collisions between the two. `Sources/FloodlightEngine/Search/FFFIndex.swift:1; Tests/FloodlightEngineTests/SearchModelInvariantTests.swift:1` `U66` `U4` `U25`
- No *PerformanceTests file exists under Tests/FloodlightTests; all FLOODLIGHT_BENCH-gated tests live in Tests/FloodlightEngineTests. `Tests/FloodlightEngineTests` `F19`
- Tests/FloodlightTests is 100% swift-testing, with zero XCTestCase usage. `Tests/FloodlightTests` `F19`
- FloodlightPanelTests.swift exercises shouldHandleSpaceAsPreview and would need updating if that function's parameters change. `Tests/FloodlightTests/FloodlightPanelTests.swift:39-56` `F41`
- docs/adr/0003-assistant-run-session.md documents the assistant-CLI-integration design decisions. `docs/adr/0003-assistant-run-session.md` `F149`
- FloodlightPerformance exposes only begin(_:) and end(_:label:id:), with no event(_:) helper for discrete cross-keystroke signposts. `FloodlightPerformance.swift:4-19,10-18` `F49` `F61`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| AssistantProcessRunner max total output | 256 KB | `AssistantProcessRunner.swift:54-73,83-97` |
| AssistantProcessRunner output read chunk size | 16 KB | `AssistantProcessRunner.swift:86` |
| resolveExecutable PATH-probe max output | 64 KB | `AssistantProcessRunner.swift:139-140` |
| resolveExecutable / login-shell timeout | 5 seconds | `AssistantProcessRunner.swift:139` |
| resolveExecutable hardcoded PATH directories checked | 4 (/opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin) | `AssistantProcessRunner.swift:34-39` |
| AppIconCache NSCache countLimit | 64 items, no totalCostLimit | `AppIconCache.swift:15` |
| FileIconCache NSCache countLimit | 256 items | `FileIconCache.swift:11` |
| FileThumbnailCache NSCache countLimit | 128 items | `FileThumbnailCache.swift:12` |
| FileThumbnailCache per-entry size | ~1.6 MB (320pt x2 = 640x640 RGBA) | `FileThumbnailCache.swift:12,53` |
| Max single-photo decode via NSImage(contentsOf:) | ~96 MB | `FileThumbnailCache.swift:66` |
| FloodlightPanel width | 680 points | `FloodlightMetrics.swift:6` |
| FloodlightMetrics.searchHeight | 60 points | `FloodlightPanel.swift:37-44,61-66` |
| FloodlightMetrics.expandedPanelHeight (corrected) | 521 points (= 60+1+40+7x2+7x58); previously misread as 548pt | `FloodlightMetrics.swift:15-21` |
| FloodlightMetrics.maximumVisibleResults | 7 rows | `FloodlightMetrics.swift:12,15-21` |
| resize(to:) no-op threshold | 0.5 pt height delta | `FloodlightPanel.swift:258` |
| Exact-path match score boost | 300000 | `FFFIndex.swift:155` |
| Content-search time budget | 35 ms | `FFFIndex.swift:352` |
| fff_live_grep max_file_size | 10485760 bytes (10 MiB) | `FFFIndex.swift:357` |
| line_content bound at FFFIndex.swift:395 (conflicting) | either unbounded (up to 10 MiB/line) or capped at 512 bytes, per disagreeing sources | `FFFIndex.swift:395; fff-c/src/ffi_types.rs:383` |
| fff_search combo params | combo_boost_multiplier=100, min_combo_count=3 | `FFFIndex.swift:201` |
| Result page size / internal limit | page_size=12 -> internal_limit=24 | `score.rs:1021-1034` |
| FloodlightMenuBar.svg asset size | 418 bytes, 2 path elements | `scripts/bundle.sh:30` |
| GlobalHotKeyRegistration firstIdentifier default | UInt32(1) | `GlobalHotKeyRegistration.swift:94` |
| ResultRow-vs-ResultRow equality comparison size | 10-40 KB PNG memcmp per re-render diff | `ResultRow.swift:28; SearchView.swift:423` |
| SwiftUI frame budget referenced for perf comparisons | 16.7 ms at 60Hz | `F77,F79,F81,F82` |

### Gotchas

- Command-K is advertised on the UI's Actions chip but is not wired up anywhere in the code — panelCommand returns .unmatched for it, and the chip actually performs the Command-C verb instead. `FloodlightPanel.swift:368-390; SearchView.swift:501-518`
- ResultRow conforms to Equatable and is wrapped in .equatable(), which a reader might assume prevents re-renders on hover — but @State isHovered still forces a body re-evaluation on every hover change, bypassing Equatable entirely. `ResultRow.swift:22,27,121`
- performSearchTextEditingCommand's paste case ('v') has no shift-check, so Shift-V is silently swallowed as a plain paste rather than reaching any shift-aware handler. `FloodlightPanel.swift:401,388-392`
- AppIconCache and FileThumbnailCache both look like simple bounded caches by their countLimit, but neither caches failures (AppIconCache) nor respects a requested max dimension (FileThumbnailCache), so real-world memory/CPU cost is higher than the countLimit alone suggests. `AppIconCache.swift:21-25; FileThumbnailCache.swift:66`
- The onboarding UI's own copy claims excluded app names will be matched, but the underlying exclusion mechanism only ever matches bundle IDs, never names. `OnboardingView.swift:331`
- The search-results footer shows a plain result count with no indicator that the count was truncated, which can mislead a reader into thinking they're seeing the full result set. `Sources/Floodlight/UI/SearchView.swift:475`
- Two sources give incompatible bounds (10 MiB vs 512 bytes) for the same line_content read at the same file/line, and neither is flagged as the corrected value — the true bound is unresolved in this batch. `FFFIndex.swift:395; fff-c/src/ffi_types.rs:383`
- Two sources also disagree on what cache_budget=0 means for FFFIndex's LMDB/mmap cache — "no in-memory caching" versus "auto-size" — despite citing the same lines. `FFFIndex.swift:73-74,83,89`
- On macOS 26.0 specifically, SearchView's result list eagerly materializes the full results array via Array(enumerated()) inside the LazyVStack, partly defeating the laziness the rest of the view relies on. `SearchView.swift:396-405`
- resolveExecutable's lack of memoization means the potentially slow login-shell PATH probe can run again on every Return press for an assistant command, not just the first time. `AssistantProcessRunner.swift:109,113,124-152`

### Corrected on review

- ~~AssistantProcessRunner's stdout/stderr drain queue is an availability-probe queue.~~ → AssistantProcessRunner.swift:184 is the drain queue used for spawned assistant processes during interactive runs, not an availability probe. `AssistantProcessRunner.swift:184`
- ~~ServiceManagement is not needed to show the panel.~~ → ServiceManagement is imported at LaunchAtLogin.swift:2 and is exercised during AppDelegate.applicationDidFinishLaunching via LaunchAtLogin.enableOnFirstRun() at AppDelegate.swift:35. `AppDelegate.swift:35; LaunchAtLogin.swift:2,37`
- ~~Moving from @main App to main.swift top-level code is a clean cold-start optimization.~~ → That move changes SwiftPM's link path, and 30 test files depend on @testable import Floodlight, so it is not a free change. `Tests/FloodlightTests (30 files)`
- ~~FloodlightApp's Settings scene evaluates and is vestigial.~~ → SwiftUI does not evaluate a Settings scene's EmptyView body until its window is opened; since it's never opened, the body is never evaluated, regardless of the scene's declaration existing. `FloodlightApp.swift:9,11-16`
- ~~FileIconCache's memory footprint is tens of megabytes and is the highest-priority cache to address.~~ → FileThumbnailCache caches 128 QuickLook thumbnails at 640x640 RGBA (~1.6MB each), making it the larger, higher-value memory target compared to FileIconCache. `FileThumbnailCache.swift:12,53`
- ~~FloodlightTextField runs an async makeFirstResponder on the hot path every time the panel is summoned.~~ → FloodlightTextField early-returns when window.firstResponder is already the editor, so the async hop is a no-op on the steady-state (already-focused) path. `FloodlightTextField.swift:110-117`
- ~~FloodlightMetrics.expandedPanelHeight is 548 points.~~ → expandedPanelHeight is 521pt, computed as 60+1+40+7x2+7x58. `FloodlightMetrics.swift:15-21`
- ~~Mount-at-idle prewarms both ScrollView and LazyVStack.~~ → SearchView.resultsContent resolves to EmptyResultsView when results.isEmpty, so it never builds a ScrollView/LazyVStack in that state. `SearchView.swift:207-228`
- ~~A stale result list is easily reachable while the panel sits inactive.~~ → A copy made in another app while the panel is visible triggers NSApplication.didResignActiveNotification, which dismisses and resets the panel. `FloodlightPanel.swift:77-87`
- ~~Two sequential filesystem stats occur per exact-path query, requiring memoization to avoid the duplicate work.~~ → The two stat-like call sites (FFFIndex.swift:117-120 and 174-181) are mutually exclusive branches gated on resolvedQuery.fffQuery.isEmpty, so exactly one stat occurs per query. `FFFIndex.swift:115-122,174-181`

<a id="swift-misc"></a>
## Floodlight: other shell and engine facts

This batch covers Floodlight's search engine wrapper (FFFIndex.swift), its Rust engine internals, the clipboard/paste action performer, and several UI components. The Swift wrapper serializes every call into the Rust/C engine (fff-c) onto one serial DispatchQueue, uses a generation counter to drop stale fuzzy-search queries before they reach the FFI boundary, but does not apply that same guard to content (grep) search. Index startup walks the filesystem, commits results, and only then allows search; a Swift-side polling loop waits for that scan to finish with no timeout. Clipboard actions (copy/paste-back) go through a single SelectedResultActionPerformer that writes one payload type per action (string, files, or image) with no transformation hook and no synthetic keystroke simulation anywhere in the codebase. Several config knobs (home-directory scanning, binary-file inclusion, symlink following, cache budget, mmap cache) are set once at index construction and mostly default to permissive/on. A handful of earlier claims in the finding set were corrected by later, more specific findings — these are listed under corrections.

### Startup and scan lifecycle

- FFFIndex.start() dispatches through the private serial DispatchQueue via perform{}, so file-system work inside start() runs off the main thread, not during object construction. `FFFIndex.swift:51-63,451-455` `F63`
- FFFIndex is rooted at the user's home directory: options.base_path = root, defaulting to homeDirectoryForCurrentUser. `FFFIndex.swift:74` `U64`
- FFFFileSource.start() calls index.start() then waitForScanCompletion() with no timeout, before setting hasStartedIndex, blocking all file search results until the scan settles. `FFFIndex.swift:622-626` `F45` `F62`
- FFFIndex is constructed with enableHomeDirectoryScanning: true, so the first query gates on a full home-directory scan. `FFFIndex.swift:704` `F45` `U47` `U19`
- waitForScanCompletion polls fff_get_scan_progress every 10ms, returning only after 2 consecutive idle polls; each idle-poll iteration costs a 10ms Task.sleep plus one extra FFI round trip, and the minimum floor is a single 10ms sleep (not 20ms). `FFFIndex.swift:677-687` `U1` `U14` `F57:value` `U75`
- The two-consecutive-idle-poll wait runs on cold start, on rebuild, and on changeScope rollback; the rollback path incurs it twice (once for rollback, once again after). `FFFIndex.swift:646-668` `U14` `U75`
- waitForScanCompletion has no deadline or poll cap — it can run unbounded. `FFFIndex.swift:677-687` `U39`
- Readiness polling (line 682) runs only during start, rebuild, and scope change — never during steady-state searching. `FFFIndex.swift:682` `U45`
- On the Rust side, ScanJob::run walks the filesystem first (walk_filesystem), commits at line 198, then sets scanning=false at lines 227-228; nothing is searchable until the walk finishes and commits. `scan.rs:171,198,227-228` `U41` `U42` `U43`
- FileSync is created empty (file_picker.rs:908) and populated only by the scan (scan.rs:198); persistence otherwise covers only the LMDB frecency and query-history stores. `file_picker.rs:908; scan.rs:170-205` `U42`
- ScanJob::run calls FileSync::walk_filesystem unconditionally — the enable_mmap_cache flag does not skip the walk. `scan.rs:89; file_picker.rs:939; scan.rs:171-179` `U57`
- A separate Rust-side wait_for_scan helper polls the scanning signal every 10ms up to a default 10-second timeout. `shared.rs:154-166` `U16` `U28`
- Scanning a home directory containing ~500K files takes roughly 500-1000ms. `explorer answer` `floodlight-usage cluster`

### FFI concurrency model

- All FFI calls are serialized on one DispatchQueue labeled "dev.vmg.fff-swift" with QoS .userInitiated; search, searchContent, progress, track, rescan, and changeRoot all funnel through it via the perform wrapper. `FFFIndex.swift:6-7,451-463` `ffi-header cluster` `Build configuration and XCFramework linkage` `U1` `F34` `F35` `U3` `F12` `F27` `F16` `F63` `U5` `U8`
- FFFIndex is declared package final class FFFIndex: @unchecked Sendable. `FFFIndex.swift:6` `U74`
- perform{} wraps each queued operation in queue.async plus withCheckedThrowingContinuation. `FFFIndex.swift:451-463` `U1`
- FFFIndex holds mutable stored properties (handle, latestSearchGeneration) touched on every search, at lines 47/54/97/107. `FFFIndex.swift:9-10,47,54,97,107` `U12` `U74`
- A dedicated NSLock (searchGenerationLock) protects the search-generation counter. `FFFIndex.swift:6,8,63` `U1`
- Separately, `handle` (written in start(), line 97) and `rootURL` (written in changeRoot at 423/429, read at 111,159,230,290,400,436) are protected only by the single serial queue — no lock guards them directly. `FFFIndex.swift:10-11,97,423,429,111,159,230,290,400,436` `U3`
- search, searchFiles, and searchDirectories reserve a search generation before enqueueing; the generation is checked only once, right before the FFI call, and a queued-but-not-yet-started stale search is dropped in microseconds by the isLatestSearch guard rather than running to completion. `FFFIndex.swift:101-109,303-308,451-463` `U33` `F35`
- Once a query's FFI call has actually started, it runs to completion even if a newer query supersedes it — the generation check is not rechecked mid-call. `FFFIndex.swift:102-106` `U14`
- searchContent, unlike search/searchFiles/searchDirectories, reserves no search generation and has no isLatestSearch guard. `FFFIndex.swift:341-350` `F34` `F35` `U3`
- startupTask priority (e.g. .utility) does not reduce the QoS of the explicitly-QoS'd DispatchQueue or the Rust threads it drives, since queue.async does not inherit caller priority. `FFFIndex.swift:451-463,7` `F48`

### Fuzzy search (fff_search_mixed)

- FFFIndex.search and searchFiles use a fixed result limit of 100 and a directory-depth limit of 3 levels. `FFFIndex.swift:126,222` `U1`
- Floodlight passes max_threads = 0 to fff_search_mixed, which resolves to available_parallelism() including efficiency cores; the literal 100 at this call site is combo_boost_multiplier, not max_threads. `FFFIndex.swift:126` `U10` `U28` `U21` `U2`
- A separate finding describes the same fff_search_mixed call passing limit 12, page_size 100, max_threads 3 — this conflicts with the max_threads=0 finding above and is not resolved by an isCorrection marker in this batch. `FFFIndex.swift:126` `U36`
- current_file = nil is passed to fff_search_mixed, so the write_dir_str/distance-penalty branch (score.rs:726) never executes on the per-keystroke path. `FFFIndex.swift:126` `U23` `U2`
- min_combo_count = 3 is passed; last_same_query_match is Some for every repeated query. `FFFIndex.swift:126` `U11`
- Intermediate query prefixes take the None path and skip the combo block; only a final, repeated query string can activate combo scoring once open_count >= 3. `FFFIndex.swift:433-449` `U6`
- FFFIndex.search has no minimum-length gate, so short fuzzy query fragments fall through to score.rs:421-425. `FFFIndex.swift:126` `U5`
- FFFIndex.swift:151-152 (repeated at 222-224, 279-281, 388-389) does split(separator:"/") plus .lowercased() per path component just to test .hasSuffix(".app"). `FFFIndex.swift:151-152,222-224,279-281,388-389` `U16`
- Trailing-slash directory queries are preserved: hasSuffix("/") is checked at line 506, the slash is stripped for path translation, then re-appended at lines 537-539. `FFFIndex.swift:506,537-539` `U20`
- FFFIndex.search runs fff_search_mixed on every keystroke; the returned FFFSearchResult has no highlight-range field. `FFFIndex.swift:290` `U6`
- FFFIndex.swift:290 requests a limit of 12 files from the engine per keystroke. `FFFIndex.swift:290` `U15`

### Content search (searchContent / fff_live_grep)

- searchContent passes timeBudgetMilliseconds: 35 to fff_live_grep, but the engine only honors that budget when all_matches.len() > 1. `FFFIndex.swift:341-361,353-361; grep.rs:610-613` `U2` `F34` `U41` `U85`
- It also passes max_file_size(10 MiB) and max_matches_per_file(1), and a hard-coded result limit of 16 matches per content search. `FFFIndex.swift:142-213` `U41` `U85`
- Full observed fff_live_grep parameter list: query, 0, file_size_cap, 1, true, 0, limit 16, timebudget 35, 0, 0, false. `FFFIndex.swift:341-405` `U1`
- The file_offset parameter passed to fff_live_grep is hard-coded to 0 on every call. `FFFIndex.swift:353-367` `U85`
- Each content-search keystroke therefore restarts fff_live_grep from file offset 0 — the 35ms budget acts as a hard ceiling on how much of a large scope is reachable per keystroke, not a per-slice budget carried across keystrokes. `FFFIndex.swift:353-367` `U85`
- The FFI result is bound then immediately freed via defer { fff_free_grep_result(result) } before any pagination metadata is extracted, and the returned next_file_offset is discarded — nothing lets a budget-truncated grep resume. `FFFIndex.swift:341-380,376-377; fff.h:1264, accessors.rs:583` `U1` `U85`
- A repo-wide grep for all nine fff pagination/match-range accessor symbols found zero hits in Sources/ — they are wired into the ABI but unused by Floodlight. `Sources/` `U85`
- max_file_size (10 MiB) bounds which files get searched and is independent of returned-snippet length; String(cString:) at FFFIndex.swift:395-396 trims a snippet the engine has already truncated to ~512 bytes, so worst-case per-match allocation is ~512 bytes, not 10 MiB. `FFFIndex.swift:395-396; grep/sink.rs:5-7` `U9`
- Matches are copied into FFFContentMatch structs carrying name, relativePath, url, line, and snippet. `FFFIndex.swift:379-397` `U85`
- FFFIndex.progress() runs through the same serialized perform queue as searchContent, so it cannot be polled inline to gate a content query without queueing behind the grep it is meant to guard. `FFFIndex.swift:322-339,341,451-463` `U4`
- contentItems (lines 632-644) calls index.searchContent, i.e. the fff_live_grep path. `FFFIndex.swift:632-644` `U71`
- Content indexing itself is enabled via config.content_indexing. `scan.rs:322` `U51`

### Index configuration and path lookups

- includeBinaryFiles defaults to true for the main index. `FFFIndex.swift:25` `U24` `U40` `U47`
- enable_home_dir_scanning defaults to true, covering 100K-1M entries. `finding-22 analysis` `U22`
- follow_symlinks is set to false, so symbolic links are not traversed. `FFFIndex.swift:88` `U47`
- start() unconditionally sets options.frecency_db_path, history_db_path, and enable_mmap_cache = true, while leaving cache_budget_* at 0 for engine auto-sizing. `FFFIndex.swift:52-99,65-66,75-77` `U41` `U11`
- options.ai_mode = false prevents background_watcher from writing to the frecency tracker; frecency_db_path/history_db_path are real paths but access_frecency_score stays permanently 0 as a result. `FFFIndex.swift:65,75,80; background_watcher.rs:673; frecency.rs:362-372` `U5`
- Auto-sizing from a zero cache budget caps memory at ~512MB up to 30K files, 256MB for 10K-50K files, and 128MB above 50K files; separately it caps max_files at 5,000 for directories with more than 50,000 files. `dbs-grep summary; types.rs:944-946` `U30` `U56`
- The main index's storageURL differs from the ApplicationIndex/Database, so their LMDB environments are genuinely separate, not pooled. `FFFIndex.swift:701-708` `U11`
- exactPathItem calls fileExists/attributesOfItem synchronously on the serialized FFI queue for any path-shaped query (contains "/" or starts with "~" or "/"), called from FFFIndex.search at both lines 117 and 175. `FFFIndex.swift:551,116-123,175-181` `U20` `U16`
- Because that call is synchronous on the shared serial queue, a network-mounted path can block exactPathItem for hundreds of milliseconds, stalling every subsequent query behind it. `FFFIndex.swift:551` `U20`
- FFFIndex never supplies a log file path (logFilePath defaults to nil, logLevel defaults to .info); fff-c only calls init_tracing when opts.log_file_path is Some. `FFFIndex.swift:27-29,79-80; fff-c/src/lib.rs:200-205` `U3` `U65`
- FFFIndex.swift imports only CFFF, not FFFKit. `FFFIndex.swift:1` `U25`
- FFFIndex never catches Rust panics — it only inspects the FffResult.error string. `FFFIndex.swift` `U25`
- fff_get_historical_query is declared and callable but has zero real call sites in Floodlight. `fff.h:749` `U19`

### Rust engine internals (threading, FilePicker)

- SharedFilePicker uses parking_lot::RwLock instead of std::sync::RwLock for faster contended reads. `shared.rs:77-94` `U16`
- Watchers are stored outside the picker lock so delivery never blocks searches. `shared.rs:79-81` `U16`
- get_cached_content hands out a &[u8] under a "hold the picker read lock" safety contract. `types.rs:687-698` `U12`
- FilePicker's state is sync_data, signals, background_watcher, git_status_worker, and cache_budget — it holds no query-side state. `file_picker.rs:574-596` `U10`
- BACKGROUND_THREAD_POOL is sized to (total_logical_cores / 2).max(2) — zero headroom on 8-logical-core Macs, only 8->12 headroom on 12P+4E systems. `parallelism.rs:16` `U53`
- SEARCH_THREAD_POOL is sized to the P-core count via performance_core_count() on macOS. `parallelism.rs:62-84` `U62`
- fuzzy_search, fuzzy_search_directories, and fuzzy_search_mixed run on rayon's implicit global pool, sized to all logical cores with no QoS pin. `file_picker.rs:1057,1156,1224` `U62`
- The walker thread count is set per walk_collect_files call, not per FFF instance — two concurrent FFF instances get the same thread count and cannot be tuned independently. `file_picker.rs:2075-2086; walk/ripgrep.rs:29` `U53`

### Data model (SearchItem and results)

- SearchItem carries only title, subtitle, and score fields — no MatchEvidence field. `SearchItem.swift:268-279` `F`
- File-search rows carry relativePath as their subtitle. `SearchItem.swift:337` `F1`
- SearchItem stores only raw Date? and UInt64? values, no precomputed display strings. `SearchItem.swift:268-315` `F79`
- SearchItem is a struct of roughly 3 Strings, an action enum carrying a URL, a fileURL, and 4 more fields, totaling ~100 bytes — approximately 4-6 refcounted fields, several eligible for small-string optimization. `SearchItem.swift:268-279,268-306` `F3-accuracy` `F82`
- SearchItemAction has only a case copy(String) for text — no formatting variant. `SearchItem.swift:230-236` `F103`
- FFFIndex returns file rows carrying only an opaque score from FFFKit — no MatchEvidence. `SearchItem.swift:322-346` `F107`
- No Set<SearchItem> or Dictionary keyed on SearchItem exists anywhere in Sources/, so SearchItem's hash(into:) is dead weight. `grep confirmed; no call sites` `F169`

### Clipboard and paste actions (SelectedResultActionPerformer)

- writeString() calls clearContents(), then setData(.floodlightOwnWrite), then setString() — it tags the pasteboard write with an own-write marker before writing the string. `SelectedResultActionPerformer.swift:42-46,43-45` `F:clipboard-ui` `F121-accuracy`
- writeImage() calls clearContents() then setData for both .png and .tiff flavors. `SelectedResultActionPerformer.swift:64-78` `F:clipboard-ui` `F` `F99`
- writeFiles() publishes both NSURL objects and the legacy NSFilenamesPboardType. `SelectedResultActionPerformer.swift:48-62` `F`
- Both the image restore path (lines 64-77) and the file restore path (lines 48-62) round-trip successfully. `SelectedResultActionPerformer.swift:64-77,48-62` `F121-accuracy`
- The restore path always writes only .string — plain-text-on-paste is the current, deliberate, unconditional behavior. `SelectedResultActionPerformer.swift:42-46` `F121-accuracy`
- copyValue() returns the stored bytes verbatim with no text transforms, and no transformation hook exists anywhere in the copy or activate action paths. `SelectedResultActionPerformer.swift:240,158,193-198` `F1` `F134`
- For the .copyImage action, copyValue returns item.title (the display name / capture-provenance label, e.g. "PNG Image") rather than image bytes, after stripping a "📌 " pin-emoji prefix via item.title.hasPrefix("📌 "). `SelectedResultActionPerformer.swift:246-247` `F110` `F123` `F133` `F136`
- open(_:for:query:) is declared private (line 209); activate() dispatches on the item.action case rather than a direct URL. `SelectedResultActionPerformer.swift:157-180,209` `F135`
- Only a single payload is ever written per action (writeString/writeFiles/writeImage) — there is no multi-item paste. `SelectedResultActionPerformer.swift:42-75` `F139`
- No CGEvent, CGEventTap, AXIsProcessTrusted, kVK_ANSI_V, or keyDown code exists anywhere in Sources — Floodlight never synthesizes a Command-V keystroke for pasting. `grep for CGEvent, kVK_ANSI_V, paste in Sources/Floodlight` `F27` `F95` `F106` `F139`

### UI components

- FileThumbnailCache uses an NSCache with countLimit 128 and no totalCostLimit (72-line file). `FileThumbnailCache.swift:12,80` `F1` `F84` `F165`
- With that 128-count limit and no cost limit, the cache can hold roughly 200MB of decoded image data. `FileThumbnailCache.swift:79-80,93-96` `F1`
- Thumbnails are generated at maxDimension 320 with scale 2.0, producing 640x640px images at ~1.6MB each. `FileThumbnailCache.swift:120-121` `F1`
- The media-extension check runs inside an @concurrent function before QLThumbnailGenerator is invoked. `FileThumbnailCache.swift:40-46` `F112`
- thumbnail(for:) only rechecks the in-memory NSCache before issuing a new QLThumbnailGenerator request — there is no in-flight coalescing or de-duplication. `FileThumbnailCache.swift:19-30` `F84`
- The NSImage(contentsOf:) fallback path caches the full-resolution image with no downsampling. `FileThumbnailCache.swift:66` `F165`
- NSCache generally requires an explicit countLimit and totalCostLimit to prevent unbounded memory growth. `F75` `F75`
- FloodlightMetrics.maximumVisibleResults = 7. `FloodlightMetrics.swift:12` `F129`
- FloodlightMetrics.Typography.rowSubtitle is Font.system(size: 11.5, weight: .medium), proportional, not monospaced. `FloodlightMetrics.swift:57` `F108`
- KeyChip exists at Sources/Floodlight/UI/KeyChip.swift:7 with a label: initializer. `KeyChip.swift:7` `F106`
- ResultShowcase.formattedModifiedDate calls calendar.startOfDay twice, then dateComponents, then date.formatted. `ResultShowcase.swift:30-53,39-65` `F79`
- Foundation caches ICU formatters behind Date.FormatStyle and ByteCountFormatStyle, so each formatting call is single-digit microseconds in steady state — it does not construct a new formatter per call. `ResultShowcase.swift:55-65` `F79` `F83`
- Date.FormatStyle(date:.omitted, time:.standard) is locale-dependent (e.g. 12-hour in en_US) versus the current code's hardcoded 24-hour format, so adopting it changes behavior rather than being a pure optimization. `ResultShowcase.swift:30-53` `F76`

### Build, deployment, tests, and fork lineage

- Package.swift declares swift-tools-version 6.4, enforcing Swift 6 complete concurrency checking. `Package.swift` `F76`
- Package.swift:20 sets the deployment floor to .macOS(.v14), and Info.plist's LSMinimumSystemVersion is 14.0, so the "else" branch of any macOS-26-gated code fork is the live path on macOS 14-15. `Package.swift:20; Sources/Floodlight/Resources/Info.plist` `F82`
- FFFIndex.swift is a 600+ line fork of fff-swift's own FFFIndex wrapper. `Sources/FloodlightEngine/Search/FFFIndex.swift vs fff-swift/Sources/FFFKit/FFFIndex.swift` `U19`
- The only functional delta between Floodlight's fork and upstream fff-swift's FFFIndex is a single enableHomeDirectoryScanning Bool parameter; upstream (vmg-dev/floodlight) carries exactly that patch in FFFKit. `FFFIndex.swift:25,79; upstream/floodlight/Vendor/fff-swift/Sources/FFFKit/FFFIndex.swift` `U19`
- The upstream floodlight branch's own Floodlight/Search/FFFIndex.swift is just a typealias re-exporting FFFKit.FFFIndex. `upstream/floodlight/Sources/Floodlight/Search/FFFIndex.swift` `U19`
- Tests/FloodlightTestSupport totals 1456 lines. `Tests/FloodlightTestSupport/*.swift` `F158`
- PropertyTesting.swift:62's mapShrinking has zero call sites. `Tests/FloodlightTestSupport/PropertyTesting.swift:62` `F158`
- Character is a 16-byte value type in Swift. `Swift language specification` `F30`
- Main-actor scheduling latency is normally 0.2-1ms, rising under contention. `Task scheduling overhead analysis` `F14`

### Other gotchas and correctness notes

- An always-running 0.5-second poll re-reads isEnabled from UserDefaults twice per second, totaling 172,800 timer wakeups per day for disabled users. `0.5s interval calculation` `F20`
- The query-path-no-sync-disk-read lint rule only covers Sources/FloodlightEngine/**. `lint rule scope` `F13`
- CONTEXT.md:62 defines Global Hot-Key Registration as a module seam with no ADR. `CONTEXT.md:62` `F148`
- No secure_delete, vacuum, or wal_checkpoint pragmas exist anywhere in Sources/. `grep output` `F118-accuracy`
- ADR 0003's claim of owning selected-result copying is superseded by ADR 0005. `CONTEXT.md ADR 0003 line 8` `Documentation & Architecture cluster`
- update_frecency_scores is at file_picker.rs:514-528, not types.rs:514 as an earlier note had it. `file_picker.rs:514` `U41`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| FFI queue QoS | .userInitiated, label dev.vmg.fff-swift | `FFFIndex.swift:6-7` |
| searchContent time budget | 35 ms (honored only when >1 match already found) | `FFFIndex.swift:341-361; grep.rs:610-613` |
| Content search match limit | 16 matches per search | `FFFIndex.swift:142-213` |
| Content search max_file_size | 10 MiB | `FFFIndex.swift:142-213` |
| Content search max_matches_per_file | 1 | `FFFIndex.swift:142-213` |
| Truncated snippet size | ~512 bytes per match (engine-side) | `FFFIndex.swift:395-396; grep/sink.rs:5-7` |
| search/searchFiles result limit | 100 results, directory depth 3 | `FFFIndex.swift:126,222` |
| searchFiles per-keystroke file limit | 12 files | `FFFIndex.swift:290` |
| min_combo_count | 3 | `FFFIndex.swift:126` |
| waitForScanCompletion poll interval | 10 ms, 2 consecutive idle polls required | `FFFIndex.swift:677-687` |
| Rust wait_for_scan timeout | default 10 s, 10 ms poll | `shared.rs:154-166` |
| Scan time, 500K files | ~500-1000 ms | `explorer answer` |
| Cache-budget auto-size thresholds | 512MB (<=30K files), 256MB (10K-50K), 128MB (50K+) | `dbs-grep summary` |
| Cache-budget max_files cap | 5,000 files for directories >50,000 files | `types.rs:944-946` |
| FileThumbnailCache countLimit | 128 entries, no totalCostLimit | `FileThumbnailCache.swift:12,80` |
| FileThumbnailCache max memory (estimated) | ~200 MB decoded images | `FileThumbnailCache.swift:79-80,93-96` |
| Thumbnail size | maxDimension 320, scale 2.0 -> 640x640px, ~1.6 MB each | `FileThumbnailCache.swift:120-121` |
| FloodlightMetrics.maximumVisibleResults | 7 | `FloodlightMetrics.swift:12` |
| rowSubtitle font size | 11.5pt, .medium, proportional | `FloodlightMetrics.swift:57` |
| Disabled-user poll wakeups | 172,800 per day (0.5 s interval) | `0.5s interval calculation` |
| Swift tools version | 6.4 | `Package.swift` |
| Deployment floor | macOS 14.0 (.v14) | `Package.swift:20; Info.plist` |
| FFFIndex.swift size | 600+ lines | `Sources/FloodlightEngine/Search/FFFIndex.swift` |
| Tests/FloodlightTestSupport size | 1456 lines | `Tests/FloodlightTestSupport/*.swift` |
| Character type size (Swift) | 16 bytes | `Swift language specification` |
| Main-actor scheduling latency | 0.2-1 ms normal | `Task scheduling overhead analysis` |
| BACKGROUND_THREAD_POOL size | (total_logical_cores / 2).max(2) | `parallelism.rs:16` |
| SearchItem approximate size | ~100 bytes, 4-6 refcounted fields | `SearchItem.swift:268-306` |

### Gotchas

- searchContent (content/grep search) has no search-generation guard, unlike search/searchFiles/searchDirectories — stale grep queries are not dropped the way stale fuzzy searches are. `FFFIndex.swift:341-350`
- exactPathItem runs synchronously on the shared FFI queue for any path-shaped query; a network mount can block it for hundreds of ms, stalling every other query queued behind it. `FFFIndex.swift:551`
- waitForScanCompletion has no timeout or poll cap — a stuck scan can hang the wait indefinitely. `FFFIndex.swift:677-687`
- ai_mode=false means access_frecency_score stays permanently 0 even though real frecency_db_path/history_db_path are configured. `FFFIndex.swift:65,75,80; background_watcher.rs:673`
- FileThumbnailCache.thumbnail(for:) has no in-flight request coalescing — concurrent requests for the same thumbnail can trigger duplicate QLThumbnailGenerator work. `FileThumbnailCache.swift:19-30`
- SearchItem's hash(into:) is unused dead code — no Set<SearchItem> or Dictionary keyed on SearchItem exists anywhere in Sources/. `grep confirmed; no call sites`
- fff_get_historical_query is declared and wired into the ABI but has zero real call sites in Floodlight. `fff.h:749`
- Floodlight has no CGEvent/CGEventTap/kVK_ANSI_V/keyDown code anywhere — it never simulates a Command-V paste keystroke, contrary to what one might assume from a paste-back feature. `grep for CGEvent, kVK_ANSI_V, paste in Sources/Floodlight`
- searchContent discards fff_live_grep's next_file_offset and always calls with file_offset=0, so a budget-truncated grep can never resume from where it left off — each keystroke restarts from the beginning of the scope. `FFFIndex.swift:341-380,353-367`
- Task priority set on the calling Swift Task does not propagate through queue.async to the serial FFI DispatchQueue or the Rust threads it drives — QoS tuning at the call site is a no-op for this path. `FFFIndex.swift:451-463,7`
- copyValue for the .copyImage action returns the display title string, not image bytes — the image payload itself comes from a separate writeImage() call, not copyValue. `SelectedResultActionPerformer.swift:246-247`
- Two concurrent FFF instances cannot be given independent walker thread counts — the count is set per walk_collect_files call, not per instance. `file_picker.rs:2075-2086; walk/ripgrep.rs:29`

### Corrected on review

- ~~ADR 0003 owns selected-result copying.~~ → That ownership claim is superseded by ADR 0005. `CONTEXT.md ADR 0003 line 8`
- ~~Floodlight passes max_threads=100 to fff_search_mixed.~~ → The literal 100 at FFFIndex.swift:126 is combo_boost_multiplier; max_threads=0 is passed, which auto-resolves to available_parallelism(). `FFFIndex.swift:126, fff-c signature`
- ~~Stale FFF searches run to completion and consume queue depth.~~ → A queued-but-not-yet-started stale search dequeues in microseconds — reserveSearchGeneration bumps the counter before enqueue and isLatestSearch guards the queued block before any FFI call. `FFFIndex.swift:303-308,451-463`
- ~~Task priority .utility can reduce startup work QoS.~~ → startupTask priority does not govern heavy work on explicitly-QoS'd DispatchQueues and Rust threads — caller priority is not inherited by queue.async. `FFFIndex.swift:451-463,7`
- ~~waitForScanCompletion's idle-poll loop has a 20 ms minimum sleep.~~ → It sleeps only when consecutiveIdlePolls < 2, so the minimum floor is one 10 ms sleep, not 20 ms. `FFFIndex.swift:686-695`
- ~~Date/byte-count formatting in ResultShowcase constructs a new formatter on every call.~~ → Foundation caches ICU formatters behind Date.FormatStyle and ByteCountFormatStyle, making each call single-digit microseconds in steady state. `ResultShowcase.swift:55-65`
- ~~Switching to Date.FormatStyle(date:.omitted, time:.standard) is a pure optimization.~~ → That FormatStyle is locale-dependent (e.g. 12-hour in en_US) versus the current hardcoded 24-hour format, so it is a behavior change, not a pure optimization. `ResultShowcase.swift:30-53`
- ~~Each keystroke costs ~480 retains and ~960 retain+release operations on SearchItem.~~ → SearchItem carries approximately 4-6 refcounted fields, several benefiting from small-string optimization (making many inline, not heap-retained). `Sources/FloodlightEngine/Models/SearchItem.swift:268-279`
- ~~Plain-text-only restore-on-paste is a missing feature.~~ → The restore path always writes only .string — that is the current, unconditional, deliberate behavior. `SelectedResultActionPerformer.swift:42-46`
- ~~searchContent has a generation guard like the other search methods.~~ → searchContent reserves no search generation and has no isLatestSearch guard, unlike search/searchFiles/searchDirectories. `FFFIndex.swift:101-104,191-194,248-251,341`
- ~~line_content can reach 10 MiB from minified-JS lines under the 10 MiB max_file_size limit.~~ → max_file_size bounds which files are searched, not the length of returned snippets — they are independent knobs. `FFFIndex.swift:357`
- ~~line_content can be up to 10 MiB in size from files under the 10 MiB max_file_size cap.~~ → line_content is already truncated to ~512 bytes by the engine before Swift ever sees it, so worst-case per-match allocation is ~512 bytes. `FFFIndex.swift:395-396; grep/sink.rs:5-7`
- ~~update_frecency_scores is defined at types.rs:514.~~ → It is at file_picker.rs:514-528. `file_picker.rs:514`

<a id="macos-system"></a>
## macOS and toolchain facts

This section covers how Floodlight's Swift UI layer talks to macOS frameworks, and how the underlying Rust engine adapts to Apple Silicon's mixed core layout. On the Swift side, NSWorkspace and Launch Services resolve app identities and icons, AppKit's NSWindow/NSApp control panel focus and activation, and NSPasteboard drives clipboard capture through a polling loop rather than a push notification. File access on both sides goes through FileManager and Foundation's URL resource APIs, which cost real stat() and readdir() calls even when they look free in Swift syntax. On the Rust side, dedicated thread pools are pinned to a QoS class and sized from a sysctl read of performance-core count, keeping engine work off Apple Silicon's efficiency cores. File-system watching rides on FSEvents, with its own per-process watch limit and quirks around recursive watches. A handful of macOS behaviors read as one thing and turn out to be another: an "unfair" lock that still donates priority, a keyboard shortcut that looks free but is already claimed by WindowServer or Mission Control, and an activation call that looks synchronous but isn't. Packaging and code-signing sit at the edge of this domain — the release pipeline verifies binary signatures and Gatekeeper acceptance — and a few round numbers (installed app counts, thumbnail sizes) turned out smaller once checked against the actual code.

### Application & system discovery (Launch Services, NSWorkspace)

- ApplicationCatalog discovers applications by walking /Applications, /System/Applications, ~/Applications, and application domain roots. `ApplicationCatalog.swift:333-382` `F`
- SystemCatalog discovers installed settings extensions by walking /System/Library/ExtensionKit/Extensions, /System/Applications/System Settings.app/Contents/PlugIns, /Library/PreferencePanes, and ~/Library/PreferencePanes. `SystemCatalog.swift:455-496` `F`
- A heavily populated Mac yields 200-600 discovered applications, not the ~1,500 worst case once assumed. `ApplicationCatalog.swift:333-373` `F1-accuracy`
- A typical macOS machine has roughly 100-300 installed applications, not ~800. `F55:value verdict reasoning` `F55:value`
- NSWorkspace.shared.urlForApplication(withBundleIdentifier:) is the Launch Services name resolver for app identities; ClipboardInspector's sourceAppDisplayName calls it synchronously on the main thread once per clipboard snapshot. `ClipboardInspector.swift:362` `F` `F:clipboard-ui` `F17` `F109`
- When that Launch Services lookup fails, sourceAppDisplayName falls back to the bundle ID's last path component. `ClipboardInspector.swift:360-370` `F109`
- AppIconCache returns nil for an unresolvable bundle ID without caching the negative result, so the blocking XPC round trip to Launch Services re-runs on every view body evaluation. `AppIconCache.swift:21-24` `F71`
- NSWorkspace.icon returns a multi-representation NSImage with AppKit choosing the representation to draw; scrolling the panel's result list does not trigger per-frame Core Graphics resampling of a large representation. `FileIconCache.swift:34-35` `F74`

### Window & panel activation (AppKit focus lifecycle)

- FloodlightPanel.show() calls NSApp.activate(ignoringOtherApps: true) then makeKeyAndOrderFront, stealing focus from the previously frontmost app. `FloodlightPanel.swift:196-203` `F50`
- Nothing restores the prior frontmost application when the panel is dismissed after that activate call. `FloodlightPanel.swift:201,206` `F24`
- NSApp.activate(ignoringOtherApps:) is asynchronous and is the dominant cause of first-keystroke loss after the hotkey; making first-responder assignment synchronous does not close this activation window. `FloodlightPanel.swift:201` `F73`
- NSWindow retains its first responder across an orderOut/makeKeyAndOrderFront cycle; FloodlightPanel never resigns first responder when it hides. `FloodlightPanel.swift:206-212` `F73`
- FloodlightPanel installs an NSEvent.addLocalMonitorForEvents(matching: .keyDown) local monitor at negligible per-event cost. `FloodlightPanel.swift:73-76` `F50` `F167`
- AppDelegate.applicationDidFinishLaunching sets the NSApplication activation policy to .accessory, and Info.plist's LSUIElement key marks Floodlight a UI-element agent with no Dock icon. `AppDelegate.swift:31; Info.plist:25-26` `F61` `F64`
- The accessibility read of NSWorkspace.shared.accessibilityDisplayShouldReduceMotion is guarded so it does not execute on every keystroke, only at boundary conditions. `FloodlightPanel.swift:258,265` `F80`

### Clipboard capture pipeline

- poll() performs two CFPreferences reads before it even checks the pasteboard changeCount, on every timer tick. `ClipboardCaptureService.swift:140-144` `F24`
- The capture-service observer compares NSPasteboard's changeCount via an IPC round trip on every tick; 2Hz polling is the accepted rate for macOS clipboard managers generally. `ClipboardCaptureService.swift:25,236` `F164` `F167`
- sessionDidResignActiveNotification and sessionDidBecomeActiveNotification cover fast user switching only. `ClipboardCaptureService.swift:188-206` `F164`
- The image-capture path triggers on NSBitmapImageRep data carried as a png or tiff pasteboard type, then extracts TIFF/PNG representations and generates a thumbnail. `ClipboardImageCapture.swift:19-22; ClipboardCaptureService.swift:232` `F20`
- Clipboard thumbnails are 128x128 RGBA PNGs of roughly 5-30 KB each, not the 10-40 KB once assumed. `ClipboardImageCapture.swift:7-8,61` `F52:value`
- Office apps place a rendered TIFF alongside plain text on the pasteboard, which can cause the plain-text copy to be lost from clipboard history. `observed macOS behavior` `F20`
- File entries in the clipboard inspector call FileManager.fileExists twice per snapshot, and fileByteCount separately reads file stat data via url.resourceValues. `ClipboardInspector.swift:107,152,354` `F17`
- Data equality checks have an O(1) buffer-identity fast path when both sides share the same copy-on-write buffer. `SearchResultProjection.swift` `F169`
- NSImage(data:) decodes lazily at draw time, though the NSImage object itself is still constructed synchronously — in ResultRow's case, on the main actor. `ClipboardImageCapture.swift; ResultRow.swift:193-194` `F163` `F75`
- NSImage(contentsOf:) for the status-bar icon defers SVG rasterization specifically to the status button's first draw pass, not to image-load time. `FloodlightMenuBarIcon.swift:17-22` `F67`

### File system access & path resolution

- PathNavigator.resolve calls homeDirectoryForCurrentUser, performs two contentsOfDirectory enumerations, and does one fileExists stat per candidate. `PathNavigator.swift:154-161,41-43` `F15`
- AssistantProcessRunner.resolveExecutable performs four isExecutableFile stats before forking /bin/zsh as a login shell. `AssistantProcessRunner.swift:136-138` `F16`
- The zsh -l -c invocation is a non-interactive login shell: it sources only .zshenv, .zprofile, and .zlogin — not .zshrc. `F53:value verdict corrections` `F53:value`
- FFFFileSource.exactPathItem calls FileManager.fileExists (one stat) and then attributesOfItem, which pulls a full NSDictionary of metadata. `FFFIndex.swift:551` `U16`
- FileManager.fileExists follows symlinks; lstat does not. `FFFIndex.swift:551` `U10`
- A FileManager.fileExists guard bounds a write to once per entry ID. `SearchCoordinator.swift:456` `F168`
- A warm FileManager.url(..., create: true) call on a directory that already exists costs tens of microseconds, not milliseconds. `SearchCoordinator.swift:173-174` `F63`
- iCloud Desktop & Documents reach the index only via symlinks into ~/Library/Mobile Documents/com~apple~CloudDocs/. `analysis U47` `U47`
- Dropbox, OneDrive, and Google Drive files live under ~/Library/CloudStorage and get indexed because the walker's follow_symlinks is false. `analysis U47` `U47`
- The file walker skips hidden files outside a git repo and respects .gitignore; a separate ignore list excludes Library/Application Support, Library/Caches, node_modules, .cargo/registry, and other system directories. `walk/ripgrep.rs:23-24; ignore.rs:5-63` `U22`

### FSEvents file watching

- The macOS FSEvents watcher uses a single recursive watch, subject to the per-process limit of 4096 watches. `background_watcher.rs:88` `U19`
- Because the watcher opens with RecursiveMode::Recursive, FSEvents also delivers events for dot-directories. `background_watcher.rs:86` `U45`

### Threading, QoS, and P/E cores

- BACKGROUND_THREAD_POOL is pinned to QOS_CLASS_USER_INITIATED on macOS specifically to prevent the OS from demoting its threads onto efficiency cores. `parallelism.rs:24-28` `U2` `U14`
- SEARCH_THREAD_POOL sizes itself to performance_core_count(), read from macOS via the hw.perflevel0.physicalcpu sysctl. `parallelism.rs:62-84,38-58` `U2` `U14`
- If that sysctl call fails, performance_core_count falls back to available_parallelism(). `parallelism.rs:54` `U2`
- On base M1/M2/M3/M4 chips (4P+4E or 4P+6E), hw.perflevel0.physicalcpu returns 4. `parallelism.rs` `U6`
- SEARCH_THREAD_POOL's QoS pinning is applied per-thread via pthread_set_qos_class_self_np, called from each thread's start handler. `parallelism.rs:60-64` `U62`
- setenv()/getenv() mutate global process state and are not thread-safe against concurrent environment reads. `correction reasoning U62` `U62`

### Locks & concurrency primitives

- OSAllocatedUnfairLock wraps os_unfair_lock and tracks the owning thread, which gives it kernel priority-donation for resolving priority inversions; 'unfair' only means it drops FIFO wake ordering, not that it drops priority donation. `ClipboardHistoryStore.swift:512-527; SystemCatalog.swift:349` `F60` `F17`

### Caching, images & rendering

- Swift strings of 15 UTF-8 bytes or fewer are stored inline, so lowercasing a Substring path component heap-allocates nothing. `FFFIndex.swift:151-164` `F15`
- GlassAvailability.rendersGlass is true only when both glass rendering is supported and Reduce Transparency is off. `GlassAvailability.swift:10-12` `UI Cluster`
- FloodlightSurface uses macOS 26's native glass material when available and falls back to VisualEffectView otherwise. `VisualEffectView.swift:14-28` `UI Cluster`
- NSCache purges its contents under system memory pressure regardless of the per-item cost value set on insertion. `FileThumbnailCache.swift:12` `F165`
- Package.swift pins .macOS(.v14), whose bundled system SQLite has trigram-tokenizer support of version 3.34 or later. `Package.swift:20` `F98`

### Packaging, code signing & toolchain

- release.yml runs codesign --verify --deep --strict to check binary signatures, and separately spctl --assess for Gatekeeper validation. `release.yml:148,174-178` `F146`
- An Intel Mac user trying to link Floodlight gets a linker error rather than a clear 'platform unsupported' message. `packaging mismatch analysis` `U26`
- Carbon, QuickLookUI, QuickLookThumbnailing, and ServiceManagement all live in the dyld shared cache, pre-linked, with sub-millisecond load cost per launch. `Package.swift:50-56` `F65`
- NSTemporaryDirectory() resolves to a per-user directory under /var/folders/.../T, mode 0700. `NSTemporaryDirectory behavior` `F119-value`
- macOS purges that TMPDIR by last-access time on roughly a 3-day cadence. `NSTemporaryDirectory cleanup behavior` `F119-value`

### Keyboard shortcuts & system-reserved keys

- Floodlight's shortcut set: Cmd-Space (primary), Option-Space (fallback), Cmd-Return (alternate reveal), arrow keys (navigation), Return (activate), Escape (dismiss), Cmd-C (copy), Cmd-R (reveal), Cmd-Y/Space (Quick Look), Cmd-L (scope picker), Shift-Cmd-R (index rebuild), Cmd-1 through Cmd-5 (filters). `keyboard-shortcuts.mdx` `Documentation & Architecture cluster`
- Control+1 through Control+9 are intercepted by WindowServer for Mission Control's 'Switch to Desktop N' before any app-level local event monitor sees them; they are not free for Floodlight to bind. `macOS window server event handling` `F129`
- Command-M is the system Minimize shortcut and cannot be reused unless FloodlightPanel overrides handleCommandKeyEquivalent. `FloodlightPanel.swift:44` `F139`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| FSEvents per-process watch limit | 4096 | `background_watcher.rs:88` |
| hw.perflevel0.physicalcpu on base M1-M4 | 4 performance cores | `parallelism.rs (K2626)` |
| Clipboard thumbnail size | 128x128 RGBA PNG, ~5-30 KB | `ClipboardImageCapture.swift:7-8,61` |
| Swift small-string inline threshold | <=15 UTF-8 bytes | `FFFIndex.swift:151-164` |
| Minimum deployment target / SQLite trigram tokenizer | macOS .v14 / SQLite >= 3.34 | `Package.swift:20` |
| Heavily populated Mac: discovered apps | 200-600 (corrected from ~1,500) | `ApplicationCatalog.swift:333-373` |
| Typical Mac: installed apps | 100-300 (corrected from ~800) | `F55:value` |
| TMPDIR purge cadence | ~3 days, by atime | `NSTemporaryDirectory cleanup behavior` |
| NSTemporaryDirectory() permission mode | 0700, per-user | `NSTemporaryDirectory behavior` |
| Clipboard changeCount poll rate | 2 Hz | `ClipboardCaptureService.swift` |
| AssistantProcessRunner executable stats before exec | 4 isExecutableFile checks | `AssistantProcessRunner.swift:136-138` |

### Gotchas

- Office apps put a rendered TIFF next to plain text on the pasteboard, and the plain-text copy can be lost from clipboard history as a result. `ClipboardImageCapture.swift:19-22 / observed macOS behavior`
- NSWindow keeps its first responder across an orderOut/makeKeyAndOrderFront cycle, and FloodlightPanel never explicitly resigns it on hide. `FloodlightPanel.swift:206-212`
- Activating the panel steals focus but nothing hands it back to the previously frontmost app on dismiss. `FloodlightPanel.swift:201,206`
- NSApp.activate(ignoringOtherApps:) looks like it should complete before the next line runs, but it is asynchronous — that gap, not a missing sync call, is what drops the first keystroke after the hotkey. `FloodlightPanel.swift:201`
- Control+1 through Control+9 look like free real estate for shortcuts, but WindowServer already claims them for Mission Control's Switch to Desktop N, before any app can see the event. `macOS window server event handling`
- Command-M looks unused inside Floodlight's own event loop, but it is the system Minimize shortcut and needs an explicit override to reuse. `FloodlightPanel.swift:44`
- AppIconCache's nil result for a bad bundle ID isn't cached, so a broken lookup silently re-triggers a blocking XPC call to Launch Services on every SwiftUI body evaluation. `AppIconCache.swift:21-24`
- FileManager.fileExists follows symlinks, but lstat — used elsewhere in the same code path — does not, so the two checks can disagree on the same path. `FFFIndex.swift:551`
- os_unfair_lock's name suggests no fairness guarantees at all, but OSAllocatedUnfairLock still tracks the owning thread and donates kernel priority to resolve inversions — only FIFO wake ordering is what it drops. `ClipboardHistoryStore.swift:512-527`
- Setting RecursiveMode::Recursive for the FSEvents watch means dot-directories get delivered too, not filtered out by default. `background_watcher.rs:86`

### Corrected on review

- ~~~1,500 installed applications worst-case~~ → discoverApplications yields 200-600 applications on a heavily populated Mac `ApplicationCatalog.swift:333-373`
- ~~~800 apps~~ → Typical macOS machine has approximately 100-300 installed applications, not 800 `F55:value verdict reasoning`
- ~~10-40 KB thumbnails~~ → Clipboard thumbnails are 128x128 RGBA PNG images, approximately 5-30 KB each, not 10-40 KB `ClipboardImageCapture.swift:7-8,61; F52:value verdict corrections`
- ~~unfair lock offers no priority donation and causes unbounded inversion~~ → OSAllocatedUnfairLock wrapping os_unfair_lock provides priority donation by tracking the owning thread, enabling kernel priority boost to resolve inversions `ClipboardHistoryStore.swift:512-527`
- ~~Core Graphics resamples large rep on every scroll frame~~ → NSWorkspace.icon returns multi-rep NSImage with AppKit rep selection; no per-frame Core Graphics resampling for scrolling panel list `FileIconCache.swift:34-35`
- ~~two async hops cause first-keystroke loss after every hotkey~~ → NSApp.activate(ignoringOtherApps:) is asynchronous and dominates first-keystroke loss; synchronous makeFirstResponder does not fix activation window `FloodlightPanel.swift:201`
- ~~accessibility read happens before 0.5pt guard~~ → NSWorkspace.shared.accessibilityDisplayShouldReduceMotion does not execute on non-boundary keystrokes due to guard at :258 `FloodlightPanel.swift:258,265`
- ~~control-digit is entirely free for Floodlight~~ → Control+1 through Control+9 are consumed by macOS Mission Control Switch to Desktop N at the window server level `macOS window server event handling`
- ~~Command-M is free~~ → Command-M is system Minimize key and cannot be reused unless FloodlightPanel overrides handleCommandKeyEquivalent `Sources/Floodlight/App/FloodlightPanel.swift:44`

<a id="bench-measure"></a>
## How to prove a change with a bench

Floodlight proves a performance change with two separate, disconnected measurement systems. On the Swift side, XCTest functions tagged FLOODLIGHT_BENCH warm up for several runs, take many samples, print a named microsecond/millisecond metric, and assert a hard budget with margin — CI runs these in release mode and dumps every FLOODLIGHT_BENCH line to the step summary. On the Rust side, the fff engine has its own criterion benches and bin harnesses, but nothing wires them into Floodlight's CI, so they only run by hand. OSLog signposts exist for a handful of app-lifecycle events and for the three stages inside SourceSearchEngine.execute, but stop at the Swift/Rust boundary — nothing is instrumented on the FFFIndex calls that actually cross into Rust, and nothing spans a keystroke to the first published result. Several budgeted tests measure a number without asserting it, run only against synthetic offline fixtures, or run in a configuration (env-gated, in-memory, default query config) that doesn't match production. A newcomer should read this as: what a bench looks like, what the Swift suite currently checks, how CI surfaces it, what Instruments can and can't see, what the Rust side benches (unconnected to CI), and where the coverage simply stops.

### Building blocks: test doubles and property/stress harnesses

- SeededGenerator drives Floodlight's property-based tests with a deterministic SplitMix64 PRNG, shrinking, and concurrent-stress utilities. `Tests/FloodlightTestSupport/PropertyTesting.swift:332-372` `F`
- hammerConcurrently spawns 16 threads doing 200 iterations each, to expose data races under ThreadSanitizer. `Tests/FloodlightTestSupport/PropertyTesting.swift:447-457` `F`
- ScriptedCatalog.immediatePage is a test double that returns prefixed results synchronously and records the queries it received; ScriptedAssistantRunner.run can either execute immediately or suspend in a continuation that the test resolves later. `Tests/FloodlightTestSupport/TestDoubles.swift:249-259, 340-356` `F`

### The FLOODLIGHT_BENCH convention

- Performance tests warm up with 5-9 runs before sampling, to let JIT and the scheduler settle. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift` `F`
- SearchItemRankingPerformanceTests documents the house rule for shipping a new hot path: warm-up runs, many samples, take the median, and assert with a margin — nothing ships without a budgeted test built this way. `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift:16-19` `F28`

### Swift engine performance budgets (the FLOODLIGHT_BENCH tests)

- testFastApplicationSearchPerformanceBudget runs 8 queries (a, cl, claude, calendar, xcode, safari, notes, terminal) 80 times each over 9 samples and asserts the median stays under 1,000 microseconds; a related assertion budgets a single ApplicationCatalog.immediatePage call at the same 1,000us threshold. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:8-55, 86` `F` `F4-accuracy` `F18`
- SearchPerformanceTests.swift also budgets settings_search_us and filter_summary_us, each asserted under 1,000 microseconds. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:100-124, 115` `F30` `F156`
- testSourceSearchImmediateSnapshotBudget uses a ScriptedFileSource to measure the time from SourceSearchEngine.search() to the first published snapshot, over 200 samples, and asserts it stays under 5 milliseconds — this is the one budgeted test that covers keystroke-to-first-result latency. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:126-158, 130` `F` `F30` `F49` `F144`
- testExpandedFFFIndexScanBenchmark creates 2,500 temp files (25 directories x 100 files) and scans them 7 times, gated behind FLOODLIGHT_RUN_INDEX_BENCH=1; it prints an expanded_fff_scan_ms metric but the only hard assertion is XCTAssertEqual(indexedFiles, 2_500) — a correctness check, not a latency budget. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:159-211, 206-210` `F` `F144` `F156`
- testTopRankedSelectionBudget selects the top 12 results from 1,500 synthetic candidates via bounded selection and asserts under 5,000 microseconds. `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift:21-65` `F` `F18`
- testFuzzyMatcherScoringBudget scores 12 candidates against 8 queries and asserts under 5,000 microseconds. `Tests/FloodlightEngineTests/SearchItemRankingPerformanceTests.swift:67-123` `F`
- AWideTreeIsIndexedAndSearchableWithinBudget is an end-to-end test creating 2,000 files across 20 directories with 100 files each. `Tests/FloodlightTests/EndToEndSearchTests.swift:583-607` `F`
- testClipboardHistorySearchPerformanceBudget seeds an in-memory (:memory:) ClipboardHistoryStore with 1,000 text-only entries (via record(text:), never recordImage), runs 100 iterations (20 in debug) over 8 query patterns, averages elapsedSeconds*1_000_000/(iterations*queries.count) into a single number printed as clipboard_search_us, and asserts that average stays under 2,000 microseconds (2ms). `Tests/FloodlightEngineTests/ClipboardHistoryPerformanceTests.swift:7-79` `F` `F6` `F9` `F20` `F40` `F143` `F156`
- SearchPerformanceTests.waitForScan() polls scan completion with Task.sleep(nanoseconds: 1_000_000) — 1ms granularity. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:288-298` `F144`
- SearchPerformanceTests measures application search on a GitHub Actions macOS runner with an empty boostMap and default blocklist, using a much smaller app catalog than even a normal Mac's roughly 150-300 installed .app bundles. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:18-26` `F7` `F54:value`
- No FLOODLIGHT_BENCH test exists in the app/shell target (Tests/FloodlightTests) for shell-side projection latency, SearchResultProjection, or ClipboardInspector, and no app-level cold-start or UI-frame benchmark exists at all — budgeted tests only cover the engine target. `Tests/FloodlightTests/, Tests/FloodlightEngineTests/` `F8` `F172` `F67`
- ClipboardCaptureServiceTests has 27 call sites that assert poll results synchronously; the async image-capture branch can't be exercised without adding an injectable completion seam. `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` `F72`

### CI wiring for benches

- CI runs the Swift performance tests in release configuration via `swift test -c release --filter PerformanceTests`. `scripts/test-performance.sh:28` `F`
- ci.yml collects every FLOODLIGHT_BENCH-prefixed print line from the test run and dumps it into the GitHub Actions step summary. `.github/workflows/ci.yml:98-101` `F156`
- ci.yml contains no cargo criterion invocation, so none of the Rust fff-engine's own benchmarks run in CI — only the Swift FLOODLIGHT_BENCH tests do. `.github/workflows/ci.yml` `U38`

### Signposts and the app's Instruments coverage

- FloodlightPerformance.swift defines a single OSLog with subsystem "com.floodlight.app" and category .pointsOfInterest that all app signposts use. `Sources/FloodlightEngine/Utilities/FloodlightPerformance.swift:5-8` `U9`
- Signpost call sites cover only app-level lifecycle events — IndexStartup, ApplicationRefresh, ApplicationDiscovery, ShowPanel, HidePanel, OpenSelection, ActivateRunningApplication (AppDelegate.swift) — plus three stages inside SourceSearchEngine.execute: SourceSearch, IndexedSourceSearch, ContentSourceSearch. `AppDelegate.swift:30-37; SourceSearchEngine.swift:239, 289, 323` `F` `U9` `F28`
- Nothing is instrumented on applicationDidFinishLaunching, hotkey registration, or on any FFFIndex call that crosses into Rust — search, searchFiles, searchDirectories, searchContent, or the perform bridge — so Instruments is blind to the Swift/Rust boundary. `AppDelegate.swift:30-37; FFFIndex.swift:101, 187, 244, 341, 451` `F` `U9`
- No signpost spans from a query keystroke to the first published snapshot, and none covers the 15-30ms of debounce delay inside SourceSearchEngine.execute (15-20ms before indexed search, 30ms before content search) — a delay window larger than most of the micro-optimizations being chased. `SourceSearchEngine.swift:120-163` `F26` `F28` `U1` `U4`
- fff_live_grep content search runs under a 35ms time budget and returns at most 16 matches; FFFIndex.search and searchFiles cap results at 100 items and 3 directory levels deep. `FFFIndex.swift:126, 222, 349` `U1`
- FFFFileSource and ApplicationCatalog poll scan progress every 10ms; ApplicationCatalog.start caps this at 200 iterations, a 2-second worst-case ceiling, but on a warm machine the poll actually finishes in single-digit milliseconds — the 2s figure is a safety ceiling that is essentially never reached, not routine behavior. `FFFIndex.swift:232; ApplicationCatalog.swift:107-123` `U1` `U3`
- Search performance measurement exists only against synthetic, offline fixtures (e.g. the 2,500-file fixture in SearchPerformanceTests.swift), never against a real, populated index. `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:50, 207` `U9`
- Typical human typing cadence is 90-150 milliseconds between keystrokes — the yardstick against which the 15-30ms debounce and sub-millisecond budgets should be read. `Finding analysis` `F11`

### Rust criterion benches and bin harnesses (fff engine)

- fff-nvim's fuzzy_search_bench.rs sweeps result limits of 10, 50, 100, and 500 (bench_search_ordering uses limit 10) and includes the 1-character query "a", the least-selective case — earlier claims that the shortest limit benched was always 100 and the shortest query 3 characters are wrong. `crates/fff-nvim/benches/fuzzy_search_bench.rs:259, 311` `U38`
- The same bench file hardcodes max_threads = 4, and its thread_scaling sweep only tests 1, 2, 4, and 8 threads — it never tests 12 or 16. `crates/fff-nvim/benches/fuzzy_search_bench.rs:168, 207` `U6`
- setup_once() hardcodes ./big-repo as the search path for these benches. `crates/fff-nvim/benches/fuzzy_search_bench.rs:104-109` `U38`
- These benches call QueryParser::default(), while Floodlight's actual FFI path uses QueryParser::new(MixedSearchConfig) — the benched code path is not the one production runs. `crates/fff-nvim/benches/fuzzy_search_bench.rs:158` `U38`
- fuzzy_search_mixed — the directory-pipeline plus mixed-search merge — is never called by any bench; only plain fuzzy_search is measured. `crates/fff-nvim/benches/` `U38`
- On an M4 Max, a grep benchmark ran 4.9s with 13 threads versus 6.2s with 16 threads (roughly 21% slower at 16), attributed to open()/VFS-lock contention on file-heavy I/O. `parallelism.rs:1-4, 35-36` `U11` `U62`

### Workload and memory numbers cited to justify design (not exercised by any bench)

- Code-comment estimates put fuzzy matching at roughly 100ms and scoring at roughly 50ms for 100k files on 8 cores with 50k matches, and an initial filesystem walk plus partition at roughly 2-3 seconds for 500k files — figures from source comments, not a documented harness run. `file_picker.rs (explorer-file)` `Engine-picker cluster`
- In mixed search over 10k files and 5k directories (15k items total), every query sorts all items together by score descending. `file_picker.rs:1257-1313` `Engine-picker cluster`
- For 500k files, a 96-byte FileItem array costs about 0.5ms of aggregate memory bandwidth inside match_list_parallel_resolved; removing FileItem's content field saves about 25% of that array bandwidth but not the separate 16-byte arena-chunk reads. `types.rs:246-259; simd_path.rs:104-112` `U12`
- A large corpus allocates roughly 95% of 5,000 bigram-filter columns, because about 4,761 distinct keys occur at least once. `bigram_filter.rs:12` `U51`
- FileItem is roughly 88-96 bytes and DirItem roughly 40 bytes; a 300k-file home index leaves roughly 75,000 spare slots in the files vector after in-place-collect, and a home directory with roughly 40,000 directories yields about 1.6MB of dirs-vector payload. `types.rs:77-86` `U49`
- A 0.5-second polling timer in clipboard capture equals 172,800 wakeups per day. `ClipboardCaptureService.swift:129` `F164`
- A decoded 6000x4000 RGBA photo occupies about 96MB in memory. `FileThumbnailCache.swift:66` `F165`

### PGO training-data gap

- smoke.c, used to train profile-guided optimization, currently exercises only one search ("smoke.c") plus watch-event smoke tests — it is not a representative workload. `crates/fff-c/tests/smoke.c` `U72`
- A PGO profile trained on a scan-heavy workload with no grep and no varied queries can bias the compiled code layout toward the wrong hot paths. `U72 correction` `U72`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Application-search budget (8 queries x80 iter x9 samples) | < 1,000 microseconds median | `Tests/FloodlightEngineTests/SearchPerformanceTests.swift:8-55` |
| ApplicationCatalog.immediatePage / settings_search_us / filter_summary_us budgets | < 1,000 microseconds | `SearchPerformanceTests.swift:86, 100-124` |
| Search-to-first-snapshot budget (200 samples) | < 5 milliseconds | `SearchPerformanceTests.swift:126-158` |
| Index-scan fixture size | 2,500 files (25 dirs x 100), scanned 7x | `SearchPerformanceTests.swift:160-212` |
| Top-ranked-selection budget | < 5,000 microseconds over 1,500 candidates | `SearchItemRankingPerformanceTests.swift:21-65` |
| Fuzzy-matcher scoring budget | < 5,000 microseconds, 12 candidates x8 queries | `SearchItemRankingPerformanceTests.swift:67-123` |
| End-to-end wide-tree fixture | 2,000 files / 20 dirs x100 | `EndToEndSearchTests.swift:583-607` |
| Clipboard search budget | < 2,000 microseconds average, 1,000 entries, 8 queries, 100 iter (20 debug) | `ClipboardHistoryPerformanceTests.swift:7-79` |
| Concurrent stress harness | 16 threads x 200 iterations | `PropertyTesting.swift:447-457` |
| SourceSearchEngine debounce delays | 15-20ms then 30ms | `SourceSearchEngine.swift:120-163` |
| fff_live_grep time budget / match cap | 35ms / 16 matches | `FFFIndex.swift:349` |
| Scan-progress poll interval / worst-case ceiling | 10ms; 200 iter = 2s ceiling (real poll finishes in single-digit ms) | `FFFIndex.swift:232; ApplicationCatalog.swift:107-123` |
| FFFIndex.search/searchFiles caps | 100 items, 3 directory levels deep | `FFFIndex.swift:126, 222` |
| Typical inter-keystroke interval | 90-150 milliseconds | `Finding analysis (F11)` |
| fuzzy_search_bench limits swept | 10, 50, 100, 500; shortest query is 1 char ("a") | `fuzzy_search_bench.rs:259, 311` |
| fff-nvim thread sweep | hardcoded max_threads=4; sweep is 1,2,4,8 only | `fuzzy_search_bench.rs:168, 207` |
| M4 Max grep thread-count result | 13 threads: 4.9s vs 16 threads: 6.2s (~21%) | `parallelism.rs:1-4, 35-36` |
| Clipboard-capture timer wakeups | 0.5s timer = 172,800 wakeups/day | `ClipboardCaptureService.swift:129` |
| Decoded photo memory footprint | 6000x4000 RGBA = 96 MB | `FileThumbnailCache.swift:66` |
| FileItem / DirItem size | ~88-96 bytes / ~40 bytes | `types.rs:77-86, 246-259` |
| Bigram-filter column occupancy on large corpus | ~4,761 of 5,000 columns (~95%) | `bigram_filter.rs:12` |

### Gotchas

- testExpandedFFFIndexScanBenchmark prints a timing metric (scanMilliseconds / expanded_fff_scan_ms) but never asserts a latency bound — its only hard assertion is XCTAssertEqual(indexedFiles, 2_500), a correctness check, not a performance budget. `SearchPerformanceTests.swift:206-211`
- That same index-scan bench only runs when FLOODLIGHT_RUN_INDEX_BENCH=1 is set, and even then disables content indexing and file watching — a configuration that doesn't match production and won't run in a default CI job. `SearchPerformanceTests.swift:159-163`
- No signposts exist on any FFFIndex call that crosses into Rust (search, searchFiles, searchDirectories, searchContent, the perform bridge), and none span keystroke-to-first-snapshot or the 15-30ms debounce delays — Instruments is blind to the Swift/Rust boundary and to the single largest fixed latency in the search pipeline. `FFFIndex.swift:101, 187, 244, 341, 451; SourceSearchEngine.swift:120-163`
- ci.yml has no cargo criterion invocation, so the Rust fff-engine's own benchmarks never run in CI — only the Swift FLOODLIGHT_BENCH tests do. `.github/workflows/ci.yml`
- fff-nvim's fuzzy_search_bench uses QueryParser::default(), but Floodlight's real FFI path uses QueryParser::new(MixedSearchConfig) — the benched code path isn't the one production runs. `fuzzy_search_bench.rs:158`
- fuzzy_search_mixed (the directory pipeline plus mixed-search merge) is never benched; only plain fuzzy_search is, leaving the merge/sort cost for combined file+directory results unmeasured. `crates/fff-nvim/benches/`
- ClipboardHistoryPerformanceTests runs entirely against an in-memory (:memory:) store seeded with text-only entries — the on-disk SQLite+FTS prepare/finalize path and image entries are never timed by this bench. `ClipboardHistoryPerformanceTests.swift:8-32`
- Averaging all 8 clipboard query patterns into one number dilutes the pathological cases — an empty query scanning all 1,000 rows and a sub-trigram linear scan both get smoothed into the same 2ms average. `ClipboardHistoryPerformanceTests.swift:34-42, 64-66`
- No FLOODLIGHT_BENCH test exists anywhere for the app/shell target (Tests/FloodlightTests) — no shell-side projection latency, no SearchResultProjection or ClipboardInspector budget, and no app-level cold-start or UI-frame benchmark at all; budgeted tests only cover the engine target. `Tests/FloodlightTests/, Tests/FloodlightEngineTests/`
- smoke.c, the workload used to train PGO, exercises only one search query plus watch-event smoke tests — training on a workload this narrow can bias the compiled layout toward the wrong hot paths. `crates/fff-c/tests/smoke.c`

### Corrected on review

- ~~No budgeted test covers keystroke-to-first-snapshot latency.~~ → testSourceSearchImmediateSnapshotBudget measures and budgets engine.search-to-first-snapshot latency at under 5ms over 200 samples. `SearchPerformanceTests.swift:126`
- ~~The GitHub CI runner's app catalog is a small fraction of the ~1,500 apps a heavily-populated Mac would have.~~ → A normal macOS machine has roughly 150-300 .app bundles (not 300-1,500), and a warm walk of it takes about 20-60ms — so the assumed 'heavily-populated' baseline was itself overstated. `F54:value verdict corrections; SearchPerformanceTests.swift:18-26`
- ~~The 200x10ms poll in ApplicationCatalog represents a routine 2-second stall.~~ → The marker/directory-index poll finishes in single-digit milliseconds on a warm machine; 200x10ms is a never-reached safety ceiling, not routine behavior. `ApplicationCatalog.swift:107-123`
- ~~ClipboardImageTestData already supplies realistic bytes.~~ → ClipboardImageTestData.thumbnail is Data(repeating: 0xEF, count: 32) — 32 opaque bytes, not a realistic PNG. `Tests/FloodlightTestSupport/ClipboardImageTestData.swift:9`
- ~~The shortest limit benched in fuzzy_search_bench.rs is always 100.~~ → fuzzy_search_bench.rs benches multiple limits: 10, 50, 100, and 500 (bench_search_ordering uses limit 10). `crates/fff-nvim/benches/fuzzy_search_bench.rs:259`
- ~~The shortest queries benched in fuzzy_search_bench.rs are 3 characters.~~ → fuzzy_search_bench.rs benches a 1-character query, "a" — the least-selective case. `crates/fff-nvim/benches/fuzzy_search_bench.rs:311`
- ~~smoke.c provides a representative training workload for PGO.~~ → smoke.c currently exercises only one search ("smoke.c") plus watch-event smoke tests. `crates/fff-c/tests/smoke.c`

<a id="corrections"></a>
## Claims the reviewers overturned or corrected

This section catalogs every point where a Floodlight reviewer ("skeptic" pass) checked a finder's claim against actual Swift, Rust, or documentation source and found it wrong. The corrections fall into a few recurring patterns: a finder cited the wrong file:line for a symbol; a finder assumed a loop or lock ran per-item when the code runs it once; a finder extrapolated a cost (allocations, apps installed, syscalls, milliseconds) from a worst-case assumption that the real code bounds far lower; and a finder proposed removing code (a dedup, a lock, a scan, an abort check) that turned out to be load-bearing for correctness. On the Swift side, most corrections concern how many times SourceSearchEngine.execute repeats work per keystroke, and how clipboard-history retention, pruning, and thumbnail sizing actually behave. On the Rust side (fff-core/fff-c), most corrections concern which fields cross the FFI boundary, what generation-guards and abort-checks actually cover, and which frecency/ranking signals are structurally zero for a non-git home directory. A recurring failure mode across both languages is inferring "this runs on every keystroke" or "this has no cap" from code shape alone, when a guard clause, an early return, or a hardcoded limit a few lines away already bounds the behavior.

### Search call-flow: what actually runs per keystroke (Swift)

- ApplicationCatalog.start does not call waitForScanCompletion; it implements its own polling loop, capped at 200 polls x 10ms = 2s (FFFFileSource.start is unbounded by contrast). `ApplicationCatalog.swift:107-123,115-121` `U3` `U39`
- SourceSearchEngine.execute calls immediatePage exactly twice per execution (lines 244-245 and 286-287); a third apparent call at 329/331 just reuses the 286-287 values. `SourceSearchEngine.swift:244-245,286-287,329-331` `F1` `F10` `F11`
- Each execute performs exactly 5 FuzzyMatcher.normalized calls and 4 characterMask recomputations, not a loose "4-6 of each." `SourceSearchEngine.swift:244,245,286,287,291` `F12`
- Query normalization runs off the main thread: SourceSearchEngine is a package actor, so the work at line 50 executes on the actor's executor, not the main thread. `SourceSearchEngine.swift:50` `F12`
- Calculator.evaluate, PathNavigator.resolve, and KeywordEngine.addressedResult all return nil or skip via a guard clause before doing any expensive work (operator check, slash/tilde check, keyword-lookup miss) — none of them run 4x with parsing or filesystem I/O per keystroke. `Calculator.swift:6; PathNavigator.swift:24-25; KeywordEngine.swift:228` `F14`
- A typical keystroke produces 3 result projections, not 4, from SourceSearchEngine.swift:252, 308, 335. `SourceSearchEngine.swift:252,308,335` `F14`
- FFFIndex's production caller (SourceSearchEngine.swift:290) yields at most 12 results per query, not 60; total production FFFIndex volume is capped at 52 items/keystroke (12 search + 16 searchContent + 24 searchFiles). `SourceSearchEngine.swift:290,324; ApplicationCatalog.swift:133` `F16` `F15`
- FFFIndex.searchDirectories has no production caller under Sources/ — it is test-only. FFFIndex.searchFiles (called from ApplicationCatalog.swift:133) roots at a marker directory with single-component relative paths and never calls lowercased, contradicting a claim of 100-400 transient String allocations per keystroke. `FFFIndex.swift; ApplicationCatalog.swift:63-66,133,471` `F15`
- The app-bundle-rejection idiom (split + lowercased) appears at five sites in FFFIndex, not four (lines 151, 223, 280, 389, 555). `FFFIndex.swift:151,223,280,389,555` `F15`
- FuzzyMatcher serves only ApplicationCatalog and SystemCatalog result kinds; file results bypass it via FFFKit entirely, so its candidate set is bounded by installed-app count plus ~45 settings after character-mask/prefix pruning — not on the order of 2000 allocations across file search. `ApplicationCatalog.swift; SystemCatalog.swift` `F9`
- Only 2 of SearchItem's 8 SearchItemKind cases (application, systemSetting) ever touch FuzzyMatcher, so only those two kinds can display highlighted match positions. `SearchItem.swift; ApplicationCatalog.swift; SystemCatalog.swift` `F107`
- A typo that substitutes in a character absent from the candidate string is silently dropped by ApplicationCatalog's character mask (line 186), so while a substitution typo could in principle match, most cannot. `ApplicationCatalog.swift:125-164,186` `F8`
- RecentStore.record is called only for launched applications, so boostMap is bounded by launched-app count, not all-time selections; boostMap is already computed once, hoisted above the per-app iteration loop in immediatePage, not recomputed per app. `SelectedResultActionPerformer.swift:214,227; ApplicationCatalog.swift:177` `F10`
- SearchItem.init's default id uses lazy ?? evaluation rather than eager allocation; topRankedInPlace is a bounded heap, not an unbounded sort; ApplicationCatalog.snapshotApplicationsByMarker returns an O(1) COW array retain, not a dictionary copy; and the COW copy in Catalog.page's >limit branch never mutates items — copies only happen in the <=limit branch where items.sort runs. `SearchItem.swift; SearchItemRanking.swift; ApplicationCatalog.swift; Catalog.swift:104-135` `F10` `F3-accuracy`
- The two SourceSearchEngine result projections operate on different source candidate sets and cannot be deduplicated into one; the SearchResultProjection dedup at line 467 is required for correctness, exercised explicitly by SearchCoordinatorStressTests.swift:330. `SearchCoordinator.swift:519-526; SearchResultProjection.swift:467; Tests/FloodlightTests/SearchCoordinatorStressTests.swift:330` `F32` `F36`
- Every keystroke's pre-ensureStarted publish already reads immediatePage, so apps and settings appear immediately on a fresh start; only isSettled, refresh, and indexedItems are delayed by startup — the panel does not show nothing or spin forever during cold start. `SourceSearchEngine.swift:245-262; ApplicationCatalog.swift:107-124` `F45`
- A queued-but-not-yet-started stale search dequeues in microseconds: reserveSearchGeneration bumps latestSearchGeneration before enqueue and isLatestSearch guards the queued block; the generation guard itself runs inside the dispatched closure after dequeue, so the only truly uncancellable window is one in-flight FFI call, not the sum of all stale queries. `FFFIndex.swift:303-308,451-463; FFFIndex.swift:101-109` `F35` `U33`
- contentEligible tests the returned file count against the limit of 12, not the total indexed-file count; SourceSearchEngine.initialPending is [.application, .file, .folder], so application and folder remain pending during the file-scan block too, not just file. `SourceSearchEngine.swift:306,251-253` `F34` `U39`
- SourceSearchEngine does not gate per-keystroke searches on startup completion — files.indexedItems/contentItems are called unconditionally regardless of whether startup has finished. `SourceSearchEngine.swift:290,324` `U55`
- scan.rs sets signals.scanning = false before run_post_scan runs, so FFFIndex.waitForScanCompletion covers only the filesystem walk commit, not content indexing — the 2-30s duration some findings attributed to it does not include content indexing. `fff-core/src/scan.rs:227` `U39`
- SearchPerformanceTests.testSourceSearchImmediateSnapshotBudget already measures and budgets engine.search-to-first-snapshot latency at under 5ms; a budgeted test for keystroke-to-first-snapshot latency does exist. `SearchPerformanceTests.swift:126` `F49`

### Locking, threading, and concurrency

- SystemCatalog.immediatePage takes one lock for the entire candidate loop, not one lock per item. `SystemCatalog.swift:339-360` `F2-accuracy`
- SystemCatalog.refreshIfNeeded does its filesystem work outside the lock and takes the lock only for the final state swap (lines 288-298). `SystemCatalog.swift:276,281,288-298` `F30`
- ApplicationCatalog.refreshIfNeeded already offloads filesystem work to discoveryQueue via withCheckedContinuation, unlike SystemCatalog which runs inline — so an @concurrent decorator is needed only on SystemCatalog, not both. `ApplicationCatalog.swift:93-98,246-254 vs SystemCatalog.swift:276-281` `F46`
- SearchCoordinator.reset cancels searchTask, which triggers AsyncStream.onTermination to call cancel — there is a call site to cancel, contrary to a claim that none exists. `SearchCoordinator.swift:252-260,541-549` `F43`
- Startup work's Task priority (.utility) does not govern heavy work already running on explicitly-QoS'd DispatchQueues or Rust threads, since queue.async does not inherit caller priority; startup and query are instead serialized on the SourceSearchEngine actor, with query awaiting the same coalesced startup task rather than competing as high-priority peers. `FFFIndex.swift:451-463,7; SourceSearchEngine.swift:270,377,50` `F48`
- OSAllocatedUnfairLock (wrapping os_unfair_lock) provides priority donation by tracking the owning thread, enabling a kernel priority boost to resolve inversions — it is not a lock that causes unbounded inversion. `ClipboardHistoryStore.swift:512-527` `F60`
- SearchCoordinator and ApplicationCatalog each independently compute applicationSupportDirectory on the main thread during construction; passing ApplicationCatalog's supportURL parameter does not eliminate this because the default (defaultSupport) is still computed unconditionally before the supportURL ?? defaultSupport fallback runs. `SearchCoordinator.swift:173; ApplicationCatalog.swift:51-61` `F63`
- fff_restart_index drops its guard before rebuilding (lib.rs:954) and takes picker.write() only for the pointer swap; rescan also constructs the new picker outside the lock — the exclusive write-lock window shrinks to near-zero, it does not stay long. `lib.rs:954; file_picker.rs:967-970` `U12`
- FilePicker::new_with_shared_state pre-arms signals.scanning = true before publishing the picker and before ScanJob::spawn runs, closing the startup race where fff_create_instance_with could return before scanning is true. `file_picker.rs:953-962,966-969,971-990` `U13`
- score_filtered_by_frecency's par_iter (score.rs:953-955) fires only when fuzzy_parts is empty (frecency-only/browsing mode) — it does not run on every typed-keystroke query. Plain bare-text queries, the dominant per-keystroke case, hit none of the three par_iter sites and never install SEARCH_THREAD_POOL. `fff-core/src/score.rs:953-955,167-169` `U62`
- catch_unwind exists at watch.rs:290 inside the dispatcher thread specifically to guard caller-supplied C callbacks; switching the crate to panic=abort would silently defeat this, turning caught-and-logged panics into full process aborts. `watch.rs:275-296` `U60`
- Clearing signals.scanning mid-walk would let a concurrent rescan spawn and clobber the first walk's commit; walk_filesystem already completes before the write lock is taken, so deferring the drop lengthens the double-resident memory window rather than shortening it. Batching commits would also break the post_scan_snapshot safety contract documented at file_picker.rs:1470-1497. `scan.rs:73-80,171-181; file_picker.rs:1896-1898,1470-1497` `U43-value` `U46-accuracy`

### Clipboard history: storage, retention, and pruning

- pruneOnSchedule() is called only once, at app launch from AppDelegate — retention policy is enforced only as of the last boot time, not continuously. `ClipboardCaptureService.swift:176,287` `F10`
- ClipboardHistoryStore.search has two regimes: queries under 3 UTF-8 bytes (including empty) run unbounded and return every match, while queries of 3+ bytes go through FTS5 and are capped at LIMIT 200, applied before any post-filtering, giving the sort O(matches log 200) rather than a full sort of ~1000+ rows on every keystroke. `ClipboardHistoryStore.swift:353-361,370,376,11` `F69` `F126` `F161` `F141` `F87`
- prune()'s SQL exempts pinned entries (WHERE pinned_at IS NULL AND created_at < cutoff), so only unpinned entries older than the retention window are ever at risk of loss. `ClipboardHistoryStore.swift:516` `F89`
- ClipboardCaptureService reads a retention-days value where the -1 sentinel meant to mean "forever" instead falls through to the 30-day default; the setter that writes -1 for .forever has no reader anywhere in Sources/, making .forever effectively dead/broken. `ClipboardCaptureService.swift:154-167` `F115-value` `F152` `F89`
- Duplicate ALTER TABLE ADD COLUMN statements fail at prepare time during name resolution and take no write lock; of the 11 schema statements only the 3 trigger DROP/CREATE pairs are real schema writes, the 8 ALTERs are parse-only overhead. `ClipboardHistorySQLite.swift:200-264` `F94`
- The clipboard image-preview temp-file write is guarded by a fileExists check, so a multi-MB Data.write happens at most once per entry id per temp-directory lifetime, not on every Space keypress; ClipboardHistoryStore stores blobs as plaintext (no encryption, no FileProtection, no posixPermissions references) — decrypted images do persist unencrypted in /tmp. `SearchCoordinator.swift:455-456` `F90`
- TIFF data is 5-20x the PNG size for mid-sized images, so dropping the TIFF column cuts a clipboard row's size by 85-90%, not merely "roughly halves" it; one screenshot entry can still store up to 30MB total (png_data and tiff_data at up to 15MB each). `ClipboardHistoryStore.swift:9,245-247,398-403` `F96` `F118`
- The FTS delete triggers (_ad, _au) must receive byte-identical text content to the insert trigger (_ai) or the FTS5 index desynchronizes — the fix is not independent per trigger. `ClipboardHistorySQLite.swift:225-262` `F122`
- The 32,000-byte maxTextByteCount cap gates only plain text; rich HTML flavors of styled paragraphs routinely exceed 32KB and are not gated by the same cap. `ClipboardHistoryStore.swift:8` `F121`
- Pinned clipboard rows already get a visible pin.fill (orange) icon in SearchResultProjection — there is a visual pin indicator. State.recentEntries is capped at inMemoryRecentWindowLimit but State.pinnedEntries is uncapped in memory. `SearchResultProjection.swift:290-291,318; ClipboardHistoryStore.swift:255,332,456` `F123` `F126`
- BlocklistStore.isBlocked(name:id:) performs exact, case/diacritic-folded full-string matching, not substring matching, so it cannot hide files via partial-name collisions; an empty blocklist incurs no string hashing at all (NativeSet.contains short-circuits on count==0), only OSAllocatedUnfairLock round-trips. `BlocklistStore.swift:72-82,73` `F128` `F4-value`
- Mode corruption from excludeFromSearch self-heals: the next keystroke or filter click re-enters the clipboard branch and republishes correctly, so the wrong publication state is not sticky. `SearchCoordinator.swift:503-508,360` `F128`
- A copy made in another app while the panel is visible triggers NSApplication.didResignActiveNotification, which dismisses and resets the panel — a stale clipboard list is not easily reachable in that scenario. `FloodlightPanel.swift:77-87` `F124`
- exitClipboardFieldText hardcodes "clip" as the one canonical spelling for clipboard mode — mode aliases are not a simple feature to add. `SearchMode.swift:145` `F124`
- The clipboard blocklist gate should read `guard case .local = mode else { return }`, not merely check !isClipboardMode, since other non-local modes need the same exclusion. `SearchCoordinator.swift:391` `F128`
- SearchCoordinator.clearHistory() has no production callers — only test callers in SearchCoordinatorClipboardModeTests.swift:266,277. `SearchCoordinator.swift:639` `F137`
- ClipboardImageTestData.thumbnail is Data(repeating: 0xEF, count: 32) — 32 opaque bytes, not a realistic PNG — so tests built on it don't exercise real image-decode costs. `Tests/FloodlightTestSupport/ClipboardImageTestData.swift:9` `F143`
- NSImage(data:) defers PNG decode until draw time, materializing up to ~80MB of RGBA at that point rather than decoding cheaply in 20-100ms; the actual dominant cost in the image-compare path is a synchronous SQLite blob read plus a Data copy plus memcmp, not NSImage decode. `ClipboardInspectorPane.swift:145; ClipboardHistoryStore.swift:263-277` `F163`
- On the capture-poll tick path, only isEnabled is read every tick; retention is not read on the tick path. The poll tolerance is already 40% slack, well past Apple's 10% guidance, and a proposed 2s adaptive backoff would lose copies, breaking the clipboard-history feature. `ClipboardCaptureService.swift:176,184,236-284,288` `F164`
- modifiedAt is set only in buildClipboardTextRow, not in buildClipboardImageRow — image rows and text rows are not populated symmetrically. `SearchResultProjection.swift:309,337,363-390` `F170`
- Clipboard image thumbnails are capped at 128x128px (a 64pt point size at 2x scale), roughly 5-30KB each — not the previously claimed 10-40KB. `ClipboardImageCapture.swift:6-8,60-68` `F169` `F52:value`
- ClipboardInspector.parseLocalPath only treats text as a path when it starts with /, ~/, or file:// and contains no newlines — a narrow gate, not a source of up to 1000 stat syscalls per keystroke. The dominant cost in rendering clipboard text rows is instead repeated whole-string scanning/splitting of up to 32KB of text (e.g. in previewTitle), not file-existence checks. `ClipboardInspector.swift:236-250; SearchResultProjection.swift:196-213,396-401` `F6` `F161`
- ClipboardInspector.imageExtensions includes ico, icns, and svg, but FileThumbnailCache's list omits svg — causing an SVG clipping to render a stale/blank preview from the previous entry indefinitely. The extension-list String literals are all 5 bytes or fewer (Swift small-string form, no heap allocation), so the real cost in classifyFile (~2 calls per body pass in clipboard mode) is FileManager syscalls, not Set/String allocation. `ClipboardInspector.swift:106-115,150-157,218-225,221,236-250; FileThumbnailCache.swift:40-43,48` `F84` `F112`
- In clipboard mode, Return always puts the entry back on the pasteboard and dismisses the panel — the invariant is not "kind-dependent, should open URLs." Restore already always writes only .string (plain-text paste), so plain-text restore is existing unconditional behavior, not a missing feature. `SelectedResultActionPerformer.swift:42-46,158-179` `F110` `F121-accuracy`
- ClipboardHistoryStore.search() binds exactly one text parameter and one integer parameter to its prepared statement, not ~5 NSString bridges. `ClipboardHistoryStore.swift:375-376` `F86`
- ClipboardHistoryStore.search uses an FTS5 trigram index for text matching, not a linear scan. `ClipboardHistoryStore.swift` `F10`
- FLOODLIGHT_FFF_LOG environment-variable overrides for the log file path are already wired at two call sites, contrary to a claim that no caller overrides log_file_path. `ApplicationCatalog.swift:71; SearchCoordinator.swift:196` `U65`

### fff Rust engine internals and the Swift/Rust FFI boundary

- The value 100 at FFFIndex.swift:126 is combo_boost_multiplier, not max_threads; passing max_threads=0 auto-resolves to available_parallelism, it is not a literal request for 100 threads. `FFFIndex.swift:126` `U21`
- The production FFFIndex instance is constructed at FFFIndex.swift:701-707 inside `package extension SourceSearchEngine`, with home-directory scanning, content indexing, and the file watcher all enabled by default. `FFFIndex.swift:701-707` `F171`
- Setting cache_budget_max_* to 0 selects the engine's default auto-sizing behavior — it means neither "unlimited" nor "disabled." ContentCacheBudget::from_overrides is all-or-nothing: once any field is non-zero, the remaining zero fields inherit the default new_for_repo(30k) rather than each independently auto-sizing. `file_picker.rs:719-721; types.rs:976-991,1000-1003` `F171` `U18`
- searchContent (FFFIndex.swift:341) does not reserve a search-generation counter, unlike search, searchFiles, and searchDirectories, which do (lines 101-104, 191-194, 248-251). `FFFIndex.swift:101-104,191-194,248-251,341` `U3`
- max_file_size (hardcoded to 10 MiB at FFFIndex.swift:357) governs which files get opened for grep, not the length of returned snippets — those are independently capped at 512 bytes by truncate_display_bytes, and by the time Swift's String(cString:) runs on line_content, the engine has already truncated it, so the worst case is ~512 bytes per match, not a 10 MiB copy. `FFFIndex.swift:357,395-396; grep/sink.rs:5-7,165-176` `U9`
- warmup_mmaps is commented out at scan.rs:357-360 with the note "TODO Skipped as potentially unsafe" — it never runs as part of the post-scan phase, and need_complex_rebuild (shared.rs:145) is defined but never called anywhere. `scan.rs:357-360; shared.rs:145` `U4` `U11`
- The abort check in grep.rs is gated by `if local_idx % 8 == 0`, so 7 of every 8 files in a rayon worker's batch still do a full mmap/read even with an abort signal pending; only every 8th file respects it. `grep/grep.rs:606-618` `U2`
- The claimed 6.2s→4.9s grep speedup's stated cause — open() VFS-lock contention — does not exist in the syscall-free, in-memory fuzzy-matching path it was attributed to. `parallelism.rs:1-4; file_picker.rs:1063-1070` `U6`
- get_modification_score returns 0 immediately unless git_status.is_modified is true; since Floodlight indexes a non-git home directory, both the access and modification components of total_frecency_score are always 0 there. frecency_boost is capped at roughly 13% of the base score, well below the 40% exact-filename bonus, so neither is the single strongest ranking signal. The combo-boost feature (re-floating a file matched by the same query previously) IS wired and used on every keystroke via query_tracker.get_last_query_entry. `frecency.rs:355-372; score.rs:717,765,794-816; file_picker.rs:1091-1105; fff-c/src/lib.rs:576-587` `U5` `U19`
- Both fff_restart_index and fff_scan_files run an identical FileSync::walk_filesystem plus bigram rebuild; the only work removed by choosing one over the other is picker allocation and one BackgroundWatcher FSEvents install. `scan.rs:167,325-334,89-90; file_picker.rs:905` `U12`
- set_cache_budget only swaps the Arc<ContentCacheBudget> pointer — it neither invalidates nor preserves mmap state across a rescan. `file_picker.rs:719-721` `U18`
- Each returned file result requires five heap allocations (two Rust Strings, two CStrings, one git_status CString), not three; format_git_status never returns an empty string for a file — it returns "clean" for unmodified files. `types.rs:343-347,353; ffi_types.rs:93-95; git.rs:144,162` `U16`
- FffMixedItem is stride-indexed via result.items.add(index), so changing its field layout breaks ABI and requires an XCFramework rebuild — unlike FffCreateOptions, which is not stride-indexed the same way. `lib.rs:1571-1583; ffi_types.rs:14-24` `U16`
- grep mode is hardcoded to 0 (plain text, no regex) at FFFIndex.swift:356, so regex_fallback_error is guaranteed null in production. literal_fallback exists on the Rust GrepResult (types.rs:157) but is absent from the entire FFI surface — not in ffi_types.rs, accessors.rs, or fff.h — so exposing it requires a field addition, an from_core update, a regenerated header, and an XCFramework rebuild (effort M, not a one-line addition). `FFFIndex.swift:356; types.rs:157; ffi_types.rs:440-455; fff.h:266-300` `U17`
- fff_free_result explicitly does not free the handle; callers must call both fff_free_string(handle) and fff_free_result(envelope), and fff_wait_for_watcher returns a struct FffResult *, not a bool. `lib.rs:1432-1445; fff.h:715` `U19` `U85`
- sort_with_buffer runs unconditionally after select_nth_unstable_by; the "partial sort" only shrinks the input to the sort from N down to items_needed — it does not avoid sorting altogether. sort_and_paginate's select_nth_unstable_by cost is O(total_matched) and independent of the limit k, so lowering internal_limit changes only the final sort size, not the dominant select_nth cost. The unzip step in sort_and_paginate operates on results already truncated to items_needed (bounded by limit=12), not the full match set. `score.rs:1019-1051` `U20` `U36` `U37`
- The fallback-indices cursor logic in match_and_score_in_arena requires a partition_point over filename_fallback_matches indexed by fallback_indices, not the reverse; naively reversing the indexing would silently corrupt bonus assignments. `score.rs:673-680,699,738-741` `U23`
- PATH_BUF_SIZE is 1024 on macOS (libc::PATH_MAX), not universally 4096 — Windows uses 4096. `constants.rs:44-48` `U27`
- A buggy main_needle_len=1 check suppresses the 40% exact-filename bonus, it does not grant it indiscriminately as previously claimed. `score.rs:759` `U11`
- The overflow Vec-extend allocation-doubling only fires when files.len() > base_count — i.e. the watcher appended at least one overflow file since the last scan — not on every query. A modified file only triggers an uncapped read in handle_file_modify if it was non-binary and <= 2MB at scan time but has since grown. `file_picker.rs:1727-1760,2143-2147` `U37` `U35`
- rayon join with neo_frizbee's internal parallel matcher would create up to 2N compute threads on N cores — an oversubscription risk, not a clean parallelism win. `file_picker.rs:1062-1068` `U36`
- fuzzy_search_bench.rs benches multiple limits (10, 50, 100, 500) and the single-character query "a" — not exclusively a limit-of-100, 3-character baseline. `fff-nvim/benches/fuzzy_search_bench.rs:259,311` `U38`
- enable_mmap_cache only warms the OS page cache; it does not persist a file list, so the full filesystem walk repeats on every launch — the index is not persisted across launches. `file_picker.rs:939` `U39`
- Pre-allocating the match-results Vec to files.len() is not viable because the matched count is unknown before matching — using files.len() as the capacity bound would allocate a worst-case ~36MB on every query. `score.rs:605-661` `U32`
- update_frecency_scores is at file_picker.rs:514-528, not types.rs:514. `file_picker.rs:514` `U41`
- Truncating detect_binary_per_byte to 16KB would contradict the design's reliance on the first 2MB containing an invalid text sequence; re-sorting by frecency inside build_bigram_index breaks the binary-search invariant that find_file_index depends on (file_picker.rs:240-257). `index/bigram_filter.rs:872-877; file_picker.rs:2148-2157,240-257` `U40-value` `U44-value`
- A rescan requires roughly 1,024 distinct previously-unseen paths per window before the overflow cap is hit — repeated modifications to the same path reuse its existing slot, so idle machines do not trigger a full re-walk every 30 seconds. `file_picker.rs handle_create_or_modify` `U45`
- The ripgrep walker already enables .ignore files (line 27), so users can exclude a folder from the initial scan today via ~/.ignore; the asymmetry is that ripgrep.rs:85 returns ignore_rules: None, so those same .ignore entries are invisible to the live file watcher. `walk/ripgrep.rs:27,85; background_watcher.rs:885-888` `U48`
- The files Vec is built via an in-place-collect specialization that leaves roughly 25% spare capacity, so a reserve(1024) call on it is a no-op, not a trigger for RawVec::grow_amortized and a memcpy of the whole array. `file_picker.rs:2114` `U49`
- Files dropped from the bigram build become silently unsearchable via fff_live_grep — a consequence that is not merely cosmetic, since they never populate the candidate bitset. `grep/grep.rs:297-375; bigram_filter.rs:494` `U54`
- A non-character-boundary basename_offset would cause a panic (file_picker.rs:2100-2101) or undefined behavior (simd_path.rs:139/192/208) — it would not silently mis-score file names. `file_picker.rs:2100-2101; simd_path.rs:139` `U58`
- is_warmup_complete is computed on the fly from enable_content_indexing and sync_data.bigram_index.is_some() — it is not stored as an atomic flag. `file_picker.rs:1437-1438` `U55`
- The next_column AtomicU16 in the bigram filter wraps at 65536 under excessive CAS races and can then reassign a column ID to a different bigram, silently weakening the filter — column IDs are not permanently fixed. `bigram_filter.rs:85-101,88` `U51`
- rustc's builtin aarch64-apple-darwin target spec already defaults to an M1-equivalent CPU with dotprod and NEON enabled — no explicit target-cpu flag is needed, and the is_aarch64_feature_detected!(dotprod) check in eq_lowered_case already const-folds on this target, so it adds no per-call runtime dispatch overhead. `fff-core/src/simd_string_utils/case.rs:126-130` `U68`
- rustup's toolchain-file discovery walks up from the current working directory, not from --manifest-path, so Vendor/fff/rust-toolchain.toml is currently never consulted when building from outside that directory. `rustup toolchain-file resolution behavior` `U73`
- SourceSearch, IndexedSourceSearch, and ContentSourceSearch signposts already bracket the debounce, indexed-search, and content-search phases of the query path (SourceSearchEngine.swift:239,289-296,323-325) — instrumentation exists, only named constants for the signpost categories are missing. `SourceSearchEngine.swift:239,289-296,323-325` `U71` `U13` `F47`
- smoke.c currently exercises only one search (for the string "smoke.c") plus watch-event smoke tests — it is not a representative training workload for profile-guided optimization. `fff-c/tests/smoke.c` `U72`
- build-xcframework.sh defaults to building both cdylib and staticlib crate types, which roughly doubles LTO codegen time because the two crate types have divergent codegen requirements. `build-xcframework.sh crate-type defaults` `U69`
- find_or_add_dir already short-circuits with an early return when an ancestor directory is already registered — a proposed dir_is_registered precheck already exists inside it, and it is not on the common path to overflow. ChunkedPathStoreBuilder's 1024 is a Vec::with_capacity growth hint for a growable arena, not a hard ceiling. Files and directories use separate, independent StableVecs, each with its own 1024-slot cap, not a shared pool — hitting the directory cap requires roughly 150-250 distinct brand-new nested directory trees, not one slot consumed per watcher event. `file_picker.rs:364-368,1740-1748,2187,2191; simd_path.rs:295-302` `U78`
- Floodlight modifies exactly 7 files from upstream fff v0.10.5 (fff-c/Cargo.toml, fff-c/include/fff.h, fff-c/src/ffi_types.rs, fff-c/src/lib.rs, fff-core/src/file_picker.rs, fff-core/src/scan.rs, fff-core/src/watcher/background_watcher.rs) — not 8, and CLAUDE.md is not among them. Only 4 commits between v0.10.5 and v0.10.6 touch crates/fff-core or crates/fff-c. In fff-c/Cargo.toml, the [lib] crate-type line (12) and the version strings (22-23) are ten lines apart, not four. `git diff v0.10.5..HEAD -- crates/; git log v0.10.5..v0.10.6 -- crates/; fff-c/Cargo.toml` `U82`

### Capacity, size, and timing numbers corrected

- discoverApplications yields roughly 200-600 applications on a heavily populated Mac, not ~1,500 worst case; a typical macOS machine has roughly 100-300 installed applications (not ~800), or 150-300 .app bundles with a warm walk taking 20-60ms, not several hundred ms. `ApplicationCatalog.swift:333-373` `F1-accuracy` `F55:value` `F54:value`
- ApplicationCatalog.synchronizeMarkers costs sub-millisecond to low-single-digit milliseconds on a warm machine, not several hundred ms. `ApplicationCatalog.swift synchronizeMarkers path` `F55:value`
- RecentStore's launch history tracks distinct applications launched from Floodlight, on the order of tens of entries — not thousands of files. `RecentStore.swift:29-40` `F11`
- A non-interactive login shell with typical version managers and shell config takes roughly 30-80ms, not 300ms-2s. `shell-startup timing analysis` `F53:value`
- Steady-state LaunchAtLogin cost, after successful first registration, is one cached UserDefaults read and zero XPC round trips — not an XPC call on every launch forever. `LaunchAtLogin.swift:58` `F59:accuracy`
- FFFIndex.waitForScanCompletion sleeps only once (10ms) when the index is already idle (consecutiveIdlePolls < 2), giving a minimum floor of 10ms, not 20ms; ApplicationCatalog's marker-directory index poll finishes in single-digit milliseconds in practice, making the 200x10ms=2s ceiling a safety cap that is effectively never reached, not a routine 2s stall. `FFFIndex.swift:678-695; ApplicationCatalog.swift:115-123` `F57:value`
- FloodlightMetrics.expandedPanelHeight computes to 60+1+40+7*2+7*58 = 521pt, not 548pt. `FloodlightMetrics.swift:15-21` `F77`
- ClipboardHistoryStore hard-caps entry text at 32,000 UTF-8 bytes — a pasted document cannot reach "hundreds of KB" through this path. `ClipboardHistoryStore.swift:8` `F5-accuracy`
- SystemCatalog.discoverInstalledSettings calls localizedInfoDictionary only for bundles that already pass the shouldIndex filter — a few dozen appex bundles, not several hundred. `SystemCatalog.swift:470-479,500-518,521-528` `F56:accuracy`
- SearchCoordinator.swift:596's blocklist filter runs only over the paged candidates (tens of items: 12 apps, 24 settings, 12 files), not over ~1,500 or ~3,000 merged candidates. `SearchCoordinator.swift:596` `F4-value`

### SwiftUI panel and rendering mechanics

- previewableSelectionURL is evaluated on every space keypress in both clipboard and non-clipboard modes, not clipboard mode only. `FloodlightPanel.swift:291-295` `F41`
- SearchSnapshot carries pendingKinds so isSettled can distinguish an invalidated state from a genuinely settled-empty one, and publish sets filterContinuity: preserve — the shell is not blind to the difference between "no results" and "invalidated." `SearchCoordinator.swift:562` `F44`
- Clipboard-mode search starts its searchTask immediately with no debounce, unlike local mode which stages work after a Task.sleep — the two modes are not symmetric. `SearchCoordinator.swift:495-548` `F40`
- SourceSearchEngine.warmUp issues and returns within one frame, before the rebuild-flash window, so its flash is not comparable in severity to a full rebuild flash. `SearchCoordinator.swift:225; SourceSearchEngine.swift:99-118` `F44`
- ResultShowcase.formattedModifiedDate is referenced only by tests, never in production code — it does not fire per row per keystroke. `ResultShowcase.swift:30` `F76`
- ResultRow's @Equatable stops leaf-row re-renders, but ResultList.row reads model.selectedID directly in its builder — a selection change still re-runs ResultList regardless of how finely the observable model is split. `SearchView.swift:414,417,423,459` `F70`
- SearchResultPublication.selecting copies four Swift arrays, which is four O(1) copy-on-write buffer retain-count bumps, not per-element retain/release of up to 80 SearchItems. `SearchResultProjection.swift:13-23` `F70`
- NSApp.activate(ignoringOtherApps:) is asynchronous and dominates first-keystroke loss after a hotkey; making makeFirstResponder synchronous does not fix the activation window, because FloodlightTextField already early-returns when the window's firstResponder is already the editor — the async hop is a no-op on the steady-state focus path. `FloodlightPanel.swift:201; FloodlightTextField.swift:110-117` `F73`
- ClipboardInspectorPane.snapshot recompute is driven by selection changes, independent of how the storage model is split — splitting the observable would not remove SQLite/LaunchServices work from the navigation path. `SearchCoordinator.swift:647-655; SearchView.swift:220,470` `F70`
- AppDelegate.installGlobalHotKey (line 111/34) forces lazy SearchCoordinator construction by writing model.activeShortcutDisplayName; clipboardCapture's initializer merely reads an already-built store lazily. Reordering initialization shifts this work rather than removing it from the critical path. `AppDelegate.swift:34,111` `F67` `F51`
- Under Swift 6 complete concurrency (Package tools version 6.4), a static DateFormatter requires nonisolated(unsafe), not a plain static let, because DateFormatter is non-Sendable. `Package.swift; RecentStore.swift:10` `F76`
- NSWorkspace.shared.accessibilityDisplayShouldReduceMotion is not read on every non-boundary keystroke; it is gated behind a guard at FloodlightPanel.swift:258. `FloodlightPanel.swift:258,265` `F80`
- SearchView.resultsContent resolves to EmptyResultsView when results.isEmpty rather than building a ScrollView/LazyVStack, and the idle gate at line 182 blocks the Divider, SearchFilterBar, and resultsContent together as one unit, not per-element. `SearchView.swift:182-228` `F77`
- Date.FormatStyle(date:.omitted, time:.standard) is locale-dependent (12-hour in en_US) versus the current code's hardcoded 24-hour format — adopting it is a behavior change, not a pure optimization. `ResultShowcase.swift:30-53` `F76`
- ClipboardInspectorPane renders the full-resolution PNG up to 180pt (360px retina) while the stored thumbnail is only 128px, making the inspector preview visibly blurrier than a 128px thumbnail would suggest is sufficient. `ClipboardInspectorPane.swift:145` `F75`
- SearchFilterOption already conforms to Equatable. `SearchItem.swift:197` `F83`
- SearchCoordinator.moveSelection(by:) and select(_:) both reassign the whole publication = publication.selecting() struct even when only the selection changed, rather than narrowly invalidating just the filter bar. `SearchCoordinator.swift:337,349` `F83`
- SearchItem carries roughly 4-6 refcounted fields, many inlined via small-string optimization — not ~480 retains / ~960 retain+release operations per keystroke. `SearchItem.swift:268-279` `F82`
- ResultRow's cache-miss handling (fileIcon set nil, guarded by !Task.isCancelled) is correctly implemented at lines 218-231, not at 221-230 as one finding cited. `ResultRow.swift:218-231,226,228` `F84`
- Foundation caches ICU formatters behind Date.FormatStyle and ByteCountFormatStyle, making each formatting call single-digit microseconds at steady state, not a fresh-formatter-per-call cost; FFFFileSource.indexedItems already returns a limit of 12 items per query, so precomputing formats would format the same small set the render path already handles. `ResultShowcase.swift:55-65; SourceSearchEngine.swift:290` `F79` `F83`
- NSWorkspace.icon returns a multi-representation NSImage with AppKit rep selection — there is no per-frame Core Graphics resampling of a large representation while scrolling the panel's result list. `FileIconCache.swift:34-35` `F74`
- FileThumbnailCache caches 128 QuickLook thumbnails at 320pt x2 (640x640 RGBA, ~1.6MB each) — a bigger memory target than FileIconCache, contrary to a claim that FileIconCache was the highest-priority memory consumer. `FileThumbnailCache.swift:12,53` `F74`
- SwiftUI does not evaluate the Settings scene's EmptyView until its window opens, but the scene declaration itself exists regardless — it is not fully vestigial, and moving from @main App to main.swift top-level code changes the SwiftPM link path, a change constrained by the 30 test files that use @testable import Floodlight. `FloodlightApp.swift:9,11-16; Tests/FloodlightTests (30 files)` `F64`
- ClipboardCaptureService.poll early-exits on an unchanged changeCount, so the image-capture cost is per-image-copy, not incurred on every 0.5s poll interval; ClipboardCaptureService.isEnabled reads a cached CFPreferences value roughly 4 times/second, but that caching introduces a stale-flag bug against OnboardingSession's writes (OnboardingSession.swift:43-49), so it is not a purely beneficial optimization. `ClipboardCaptureService.swift:141-144,237` `F72`
- AssistantProcessRunner.swift:184 is a stdout/stderr drain queue for spawned assistant processes in interactive runs, not an availability-probe queue. `AssistantProcessRunner.swift:184` `F48` `F53`
- Only the Ask Claude and Ask Codex assistant rows are delayed by keyword-registry resolution; web-mode rows are available from t=0 — the web-mode tab list is not missing from the panel. `SearchCoordinator.swift:136; KeywordEngine.swift:421-438,441-447` `F58:accuracy` `F58:value`
- ServiceManagement is imported and actually used during AppDelegate.applicationDidFinishLaunching via LaunchAtLogin.enableOnFirstRun(), so it is needed even just to show the panel; Swift's autolinking emits a linker option per import statement, so frameworks are linked because of import statements scattered across files, not because of explicit Package.swift linker entries. `AppDelegate.swift:35; LaunchAtLogin.swift:2,37; Package.swift:50-56` `F65`
- Control+1 through Control+9 are already consumed by macOS Mission Control's "Switch to Desktop N" at the window-server level, so they are not entirely free for Floodlight to rebind; any digit rebinding inside clipboard mode must be scoped on model.isClipboardMode to avoid breaking Command+5's existing first-dynamic-filter behavior, and Command-M is the system Minimize shortcut and cannot be reused without FloodlightPanel overriding handleCommandKeyEquivalent. togglePin and deleteSelection are already gated on model.isClipboardMode. `FloodlightPanel.swift:44,345-350` `F129` `F138` `F139`
- ClipboardHistoryPerformanceTests.swift's fixture contains 10 strings, of which 5 are code/shell content types, not "mostly code and shell." `ClipboardHistoryPerformanceTests.swift:11-22` `F111`

### Documentation, repo hygiene, and citation accuracy

- ADR 0003's claim of owning selected-result copying is superseded by ADR 0005. `CONTEXT.md ADR 0003 line 8` `Documentation & Architecture cluster`
- docs/development/building.mdx states Swift 5.10 is sufficient to build Floodlight, but Package.swift actually requires tools version 6.4 — the two disagree. `building.mdx:11; Package.swift:1,85` `F11` `F150`
- README.md links to the anchor #sources-not-yet-integrated, which does not exist; the correct target is #not-currently-searchable, defined by the "## Not currently searchable" heading in docs/src/content/docs/guides/search.mdx:116. `README.md:210-211; search.mdx:116` `F12` `F151`
- README.md's feature-bullet list (13-30) omits Clipboard History, Keyword Search, and Assistant modes; its persistent-data section (line 201) documents only FFF history, frecency data, and private-app markers, omitting the clipboard database and its retention policy. `README.md:13-30,201` `F149`
- .github/workflows/pages.yml has a paths filter restricted to docs/** and the workflow file itself (lines 6-8), so a README-only change does not trigger the docs-publish workflow. `pages.yml:6-8` `F154`
- rescan() has exactly one production caller, ApplicationCatalog.refreshIfNeeded() at line 103 — it is not invoked on every shift-cmd-R or every scope change. `ApplicationCatalog.swift:102-104` `F144` `U13`
- check-build.sh runs a debug build (line 19); the release-config compile path is separately checked by test-performance.sh's `swift test -c release` (line 28) — release compilation is not left unchecked. `scripts/check-build.sh:19; scripts/test-performance.sh:28` `F145`
- A search for SearchCoordinator.applyResults returns zero matches in the codebase — the offenders a finding attributed to it do not exist. `rg applyResults (0 hits)` `F153`
- BlocklistStore.isBlocked is at BlocklistStore.swift:144, not line 216; SystemCatalog.immediatePage is declared at SystemCatalog.swift:339 (its preamble normalizes at lines 344-347), not line 349/343-347; ApplicationCatalog.indexedItems normalizes at lines 128-130 (three lines), not 128-132 (four lines); the clipboard inspector's Format row is rendered via infoRow(label:value:) at ClipboardInspectorPane.swift:213, not Search/ClipboardInspectorPane.swift:213. `BlocklistStore.swift:144-146; SystemCatalog.swift:339,344-347; ApplicationCatalog.swift:128-130; ClipboardInspectorPane.swift:213` `F4-accuracy` `F3-accuracy` `F12` `F104`

### Numbers to remember

| What | Value | Where |
|---|---|---|
| Package.swift tools version required to build | 6.4 (not Swift 5.10 as building.mdx claims) | `Package.swift:1,85; building.mdx:11` |
| SourceSearchEngine.execute immediatePage calls per execution | 2 (lines 244-245, 286-287), not 3 | `SourceSearchEngine.swift:244-245,286-287,329-331` |
| FFFIndex.normalized / characterMask calls per execute | 5 normalized calls, 4 characterMask recomputations | `SourceSearchEngine.swift:244,245,286,287,291` |
| Production FFFIndex result cap per keystroke | 52 items (12 search + 16 searchContent + 24 searchFiles) | `SourceSearchEngine.swift:290,324; ApplicationCatalog.swift:133` |
| ClipboardHistoryStore plain-text byte cap | 32,000 UTF-8 bytes (HTML flavors can exceed this) | `ClipboardHistoryStore.swift:8` |
| ClipboardHistoryStore FTS search result cap | 200 rows (LIMIT), only for queries >=3 UTF-8 bytes; shorter queries are unbounded | `ClipboardHistoryStore.swift:11,353-361,370,376` |
| Max blob size per clipboard screenshot entry | up to 30MB total (png_data and tiff_data at up to 15MB each) | `ClipboardHistoryStore.swift:245-247,398-403` |
| Clipboard image thumbnail size | 128x128px, ~5-30KB each (64pt point size x2 scale) | `ClipboardImageCapture.swift:6-8,60-68` |
| ApplicationCatalog.start polling ceiling | 200 polls x 10ms = 2s max wait (rarely reached; single-digit ms typical) | `ApplicationCatalog.swift:115-123` |
| FFFIndex.waitForScanCompletion sleep floor | 10ms (one sleep when already idle), not 20ms | `FFFIndex.swift:678-695` |
| expandedPanelHeight computed value | 521pt (60+1+40+7*2+7*58), not 548pt | `FloodlightMetrics.swift:15-21` |
| max_file_size for content search (fff-core) | 10 MiB, hardcoded — governs which files open, independent of snippet length | `FFFIndex.swift:357` |
| Snippet/line_content truncation length | 512 bytes, applied by the Rust engine before Swift sees it | `grep/sink.rs:5-7,165-176; FFFIndex.swift:395-396` |
| PATH_BUF_SIZE | 1024 on macOS (libc::PATH_MAX), 4096 on Windows | `constants.rs:44-48` |
| frecency_boost cap vs exact-filename bonus | frecency_boost capped ~13% of base score; exact-filename bonus up to 40% | `frecency.rs:355-359; score.rs:759,765` |
| Heap allocations per returned file result (fff-c) | 5 (2 Rust Strings, 2 CStrings, 1 git_status CString), not 3 | `types.rs:343-347,353; ffi_types.rs:93-95` |
| Typical installed application count on macOS | ~100-300 (contested across findings: 200-600 discovered, 150-300 .app bundles), not ~800 or ~1,500 | `ApplicationCatalog.swift:333-373; F55:value; F54:value` |
| Files modified from upstream fff v0.10.5 | exactly 7 files, not 8 | `git diff v0.10.5..HEAD -- crates/` |
| Directory overflow-slot cap per StableVec | 1024, separately for files and for directories (not shared) | `file_picker.rs:2187,2191` |
| Overflow directory cap trigger threshold | ~150-250 distinct brand-new nested directory trees | `file_picker.rs:364-368` |

### Gotchas

- is_warmup_complete looks like a state flag but is actually computed fresh each time from enable_content_indexing and whether the bigram index exists — it is not a stored atomic. `file_picker.rs:1437-1438`
- scan.rs sets signals.scanning = false before run_post_scan (bigram build, binary sniffing) runs, so waitForScanCompletion only ever waited for the filesystem walk commit, never for content indexing. `fff-core/src/scan.rs:227`
- The .forever clipboard-retention option is effectively dead: its sentinel value (-1) is written by the setter but nothing reads it back, and the separate poll-side lookup treats -1 as "fall through to the 30-day default" instead of forever. `ClipboardCaptureService.swift:154-167`
- ClipboardInspector recognizes .svg as an image extension but FileThumbnailCache's list does not — pasting an SVG shows a blank preview that silently keeps displaying the previous entry's image. `ClipboardInspector.swift:221; FileThumbnailCache.swift:40-43,48`
- Pinned clipboard entries are exempt from the retention prune query, but the in-memory pinnedEntries collection itself is uncapped — unlike recentEntries, which is capped. `ClipboardHistoryStore.swift:255,332,456; ClipboardHistoryStore.swift:516`
- Vendor/fff/rust-toolchain.toml looks like it pins the compiler for release builds, but rustup's toolchain-file discovery walks up from the current working directory, not from --manifest-path, so building from outside that directory never consults it. `rustup toolchain-file resolution`
- Control+1 through Control+9 look free for app-level rebinding but are already consumed by macOS Mission Control's "Switch to Desktop N" at the window-server level. `macOS window-server event handling`
- catch_unwind at watch.rs:290 quietly guards every caller-supplied C callback; switching the crate's panic strategy to abort would silently remove this safety net and turn a caught, logged panic into a full process crash. `watch.rs:275-296`
- fff_free_result does not free the result handle — callers who call only fff_free_result and skip fff_free_string will leak. `lib.rs:1432-1445`
- warmup_mmaps and need_complex_rebuild both look like active parts of the post-scan pipeline from their names, but warmup_mmaps is commented out (TODO: unsafe) and need_complex_rebuild is never called anywhere. `scan.rs:357-360; shared.rs:145`
- main_needle_len=1's known bug does not hand out the exact-filename bonus too generously as one might assume — it does the opposite, suppressing the bonus. `score.rs:759`

### Corrected on review

- ~~ApplicationCatalog.start calls waitForScanCompletion like FFFFileSource~~ → ApplicationCatalog.start implements its own polling loop, capped at 200 x 10ms = 2s `ApplicationCatalog.swift:107-123`
- ~~SourceSearchEngine.execute calls immediatePage three times per execution~~ → It calls immediatePage exactly twice (lines 244-245, 286-287); a third apparent call reuses those values `SourceSearchEngine.swift:244-245,286-287,329-331`
- ~~docs/development/building.mdx: Swift 5.10 is sufficient to build Floodlight~~ → Package.swift requires Swift tools version 6.4 `building.mdx:11; Package.swift:1,85`
- ~~README.md links to the anchor #sources-not-yet-integrated~~ → That anchor does not exist; the correct target is #not-currently-searchable `README.md:210-211; search.mdx:116`
- ~~BlocklistStore.isBlocked is at BlocklistStore.swift:216~~ → It is at BlocklistStore.swift:144 `BlocklistStore.swift:144-146`
- ~~An empty blocklist costs ~1,500 string hashes per query~~ → NativeSet.contains short-circuits on count==0; only lock round-trips occur, no hashing `BlocklistStore.swift:73`
- ~~SearchCoordinator's blocklist predicate runs a third time over ~3,000 merged candidates~~ → It filters only the paged candidates — tens of items (12 apps, 24 settings, 12 files) `SearchCoordinator.swift:596`
- ~~Floodlight indexes ~1,500 installed applications worst case~~ → discoverApplications yields roughly 200-600 apps on a heavily populated Mac `ApplicationCatalog.swift:333-373`
- ~~SystemCatalog's settings scan takes one lock per candidate item~~ → immediatePage takes one lock for the entire candidate loop `SystemCatalog.swift:339-360`
- ~~Catalog.page copies the array again after materialization~~ → COW in the >limit branch never mutates items; copies only occur in the <=limit branch where items.sort runs `Catalog.swift:104-135`
- ~~A pasted document can be hundreds of KB in ClipboardHistoryStore~~ → Entry text is hard-capped at 32,000 UTF-8 bytes `ClipboardHistoryStore.swift:8`
- ~~Substitution typos will never match an application~~ → They could in principle, but a typo introducing a character absent from the candidate is silently dropped by the character mask `ApplicationCatalog.swift:186`
- ~~SystemCatalog.immediatePage is at SystemCatalog.swift:349~~ → It is at SystemCatalog.swift:339 `SystemCatalog.swift:339`
- ~~~2000 allocations per keystroke across file search via FuzzyMatcher~~ → FuzzyMatcher serves only app and settings catalogs; file results bypass it via FFFKit `Sources/FloodlightEngine/Search/`
- ~~Launch history tracked by RecentStore holds thousands of files~~ → It is a set of distinct launched applications, on the order of tens of entries `RecentStore.swift:29-40`
- ~~SourceSearchEngine calls ApplicationCatalog.immediatePage two to four times per keystroke~~ → It calls it exactly twice, at lines 244 and 286 `SourceSearchEngine.swift:244,286`
- ~~ApplicationCatalog.indexedItems preamble normalizes at lines 128-132 (four lines)~~ → It normalizes at lines 128-130 (three lines) `ApplicationCatalog.swift:128-130`
- ~~SourceSearchEngine performs 4-6 normalized calls and characterMask recomputations~~ → Exactly 5 normalized calls and 4 characterMask recomputations `SourceSearchEngine.swift:244,245,286,287,291`
- ~~Query normalization in SourceSearchEngine runs on the main thread~~ → SourceSearchEngine is a package actor; normalization runs off the main thread `SourceSearchEngine.swift:50`
- ~~Up to 1000 stat syscalls per keystroke from ClipboardInspector.parseLocalPath~~ → The path gate is narrow (starts with /, ~/, or file://, no newlines); it does not scan for 1000 stat calls `ClipboardInspector.swift:236-250`
- ~~1000 stat syscalls dominate the cost of rendering clipboard rows~~ → Repeated whole-string scanning of up to 32KB of text dominates, not file-existence checks `SearchResultProjection.swift:196-213`
- ~~Calculator.evaluate runs 4x with full parsing per keystroke~~ → It returns nil immediately unless the query contains an operator character `Calculator.swift:6`
- ~~PathNavigator.resolve runs 4x with filesystem I/O per keystroke~~ → It returns nil unless the query contains a slash or starts with tilde `PathNavigator.swift:24-25`
- ~~A typical keystroke produces 4 result projections~~ → It produces 3, from SourceSearchEngine.swift:252,308,335 `SourceSearchEngine.swift:252,308,335`
- ~~FFFIndex returns up to 60 results per path-shaped query~~ → The production caller yields at most 12 results (SourceSearchEngine.swift:290) `SourceSearchEngine.swift:290`
- ~~FFFIndex's app-bundle-rejection idiom appears at four sites~~ → It appears at five sites (lines 151,223,280,389,555) `FFFIndex.swift:151,223,280,389,555`
- ~~FFFIndex.searchDirectories is a production code path~~ → It has no production caller under Sources/ — it is test-only `FFFIndex.swift`
- ~~The dedup at SearchResultProjection.swift:467 is redundant and should be removed~~ → It is required for correctness, exercised explicitly by SearchCoordinatorStressTests.swift:330 `Tests/FloodlightTests/SearchCoordinatorStressTests.swift:330`
- ~~Stale FFF searches run to completion and consume queue depth~~ → Queued-but-not-started stale searches dequeue in microseconds via a generation bump before they run `FFFIndex.swift:303-308,451-463`
- ~~contentEligible tests query length against fewer than 12 total indexed files~~ → It tests the returned file count against the limit of 12, not the indexed total `SourceSearchEngine.swift:306`
- ~~Two projections per keystroke are redundant and can be merged~~ → They operate on different candidate sets; merging would reintroduce a documented list-collapse regression `SearchCoordinator.swift:519-526`
- ~~SystemCatalog.refreshIfNeeded locks while doing filesystem work~~ → Filesystem work happens outside the lock; the lock is taken only for the final state swap `SystemCatalog.swift:276,281,288-298`
- ~~ApplicationCatalog.refreshIfNeeded needs the same @concurrent decorator as SystemCatalog~~ → It already offloads filesystem work via withCheckedContinuation; only SystemCatalog needs it `ApplicationCatalog.swift:93-98,246-254`
- ~~There is no call site to cancel SearchCoordinator's search task~~ → SearchCoordinator.reset cancels searchTask, triggering AsyncStream.onTermination's cancel `SearchCoordinator.swift:252-260,541-549`
- ~~Clipboard mode gets a debounce like local mode~~ → scheduleSearch starts searchTask immediately with no debounce in clipboard mode `SearchCoordinator.swift:495-548`
- ~~OSAllocatedUnfairLock offers no priority donation and causes unbounded inversion~~ → It tracks the owning thread, enabling kernel priority boost that resolves inversions `ClipboardHistoryStore.swift:512-527`
- ~~pruneOnSchedule enforces clipboard retention continuously~~ → It runs only once, at app launch — retention is enforced only as of the last boot time `ClipboardCaptureService.swift:176,287`
- ~~Forever clipboard retention works as the user selects it~~ → The -1 sentinel falls through to the 30-day default instead of enabling Forever `ClipboardCaptureService.swift:154-160`
- ~~Clipboard thumbnails are 10-40KB~~ → They are roughly 5-30KB, at 128x128px `ClipboardImageCapture.swift:7-8,61`
- ~~Removing TIFF data roughly halves clipboard row growth~~ → TIFF is 5-20x the PNG size, so removing it cuts the row by 85-90% `ClipboardHistoryStore.swift:9`
- ~~Decrypted clipboard images persist unencrypted only transiently in /tmp~~ → ClipboardHistoryStore has no encryption at all — blobs are stored as plaintext in the database `ClipboardHistoryStore.swift`
- ~~A multi-MB image-preview write happens on every Space keypress~~ → The write is guarded by a fileExists check and happens at most once per entry id per temp-dir lifetime `SearchCoordinator.swift:455-456`
- ~~NSImage decodes cheaply in 20-100ms~~ → NSImage(data:) defers decode until draw, materializing up to ~80MB of RGBA at that point `ClipboardInspectorPane.swift:145`
- ~~NSImage decode dominates the clipboard image-compare cost~~ → A synchronous SQLite blob read plus Data copy plus memcmp dominates `ClipboardHistoryStore.swift:263-277`
- ~~Return key behavior in clipboard mode should be kind-dependent, opening URLs for some entries~~ → Return always restores the entry to the pasteboard and dismisses the panel, regardless of kind `SelectedResultActionPerformer.swift:158-179`
- ~~max_threads=100 is passed to the fff engine from Floodlight~~ → 100 at that line is combo_boost_multiplier; max_threads=0 auto-resolves to available_parallelism `FFFIndex.swift:126`
- ~~get_modification_score is the single strongest ranking signal, driven purely by mtime~~ → It returns 0 unless git_status.is_modified is true, which is always false for a non-git home directory `frecency.rs:362-372`
- ~~fff's ranking is structurally dead with no learning for user-facing queries~~ → fff_track_query is wired; combo boost rewards repeatedly-typed exact queries via open_count `file_picker.rs:1093-1105; score.rs:794-816`
- ~~Snippet length from max_file_size (10 MiB) can blow up memory allocation to 10 MiB copies~~ → max_file_size only bounds which files are opened; snippets are capped at 512 bytes independently `sink.rs:5-7,165-176`
- ~~Two sequential stats occur per exact-path query, requiring memoization~~ → The two call sites are mutually exclusive branches; exactly one stat occurs per query `FFFIndex.swift:115-122,174-181`
- ~~literal_fallback is a one-line upstream addition, effort S~~ → Exposing it needs a field addition to FffGrepResult, an from_core update, a regenerated header, and an XCFramework rebuild — effort M `ffi_types.rs:440-455; include/fff.h`
- ~~fff_free_string alone is sufficient to free a result~~ → fff_free_result does not free the handle; both fff_free_string and fff_free_result must be called `lib.rs:1432-1445`
- ~~Every file dropped from the bigram build has a merely cosmetic search consequence~~ → Such files become silently unsearchable via fff_live_grep — they never populate the candidate bitset `grep/grep.rs:297-375; bigram_filter.rs:494`
- ~~A non-character-boundary basename_offset would silently mis-score file names~~ → It would cause a panic or undefined behavior instead `file_picker.rs:2100-2101; simd_path.rs:139`
- ~~is_warmup_complete is stored as an atomic flag~~ → It is computed on demand from enable_content_indexing and bigram_index presence `file_picker.rs:1437-1438`
- ~~No catch_unwind exists in fff-c/fff-core, so panic=abort changes nothing~~ → catch_unwind at watch.rs:290 guards caller-supplied C callbacks; panic=abort would silently defeat it `watch.rs:275-296`
- ~~Vendor/fff/rust-toolchain.toml pins the compiler version used in release builds~~ → rustup discovers toolchain files from CWD, not --manifest-path, so it is currently never consulted `rustup toolchain-file resolution behavior`
- ~~Floodlight modifies 8 files from upstream fff v0.10.5, including CLAUDE.md~~ → Exactly 7 files are modified, and CLAUDE.md is not one of them `git diff v0.10.5..HEAD -- crates/`
- ~~bool fff_wait_for_watcher(void *fff_handle, uint64_t timeout_ms)~~ → fff_wait_for_watcher returns struct FffResult *, not bool `fff.h:715`
- ~~Floodlight cannot exclude a folder from the initial scan~~ → The ripgrep walker already enables .ignore files; users can exclude folders today via ~/.ignore `walk/ripgrep.rs:27`
- ~~reserve(1024) on the files Vec triggers RawVec::grow_amortized and memcpys the array~~ → The Vec's in-place-collect specialization already leaves ~25% spare capacity, making reserve(1024) a no-op `file_picker.rs:2114`

