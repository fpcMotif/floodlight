---
status: accepted
date: 2026-11-02
---

# File search runs on a memory-mapped Zig index in `core/`

Nanospot runs file search on `nanospot-core`, a Zig engine in `core/` imported directly by `app/` and exposed to external embedders through `core/include/nanospot_core.h`.

## Why

Code-search engines for editor workspaces keep content caches, trigram heaps, LMDB stores, and thread pools in dirty memory that macOS cannot evict under pressure. At home-folder scale, a launcher needs one thing per keystroke: ranked file and folder names with near-zero dirty memory.

## Shape

- **Scan.** `getattrlistbulk(2)` on macOS and `getdents64(2)` on Linux read names and entry types in 64 KB batches without a `stat` per file. The depth-first walk opens each child via `openat` against its parent descriptor. It skips hidden entries and generated trees (`node_modules`, `DerivedData`, `.build`, `target`).
- **Index.** A struct-of-arrays table stores name mask, path mask, parent id, name offset and length, flags, and depth. The table stores each name once. Writes go through a temporary sibling file and an atomic rename, then map read-only with `mmap` so pages stay clean and evictable.
- **Search.** An 8-wide SIMD 32-bit character-mask compare rejects non-matching entries before fzf-v1 scoring. A bounded min-heap keeps the top `k` hits and prunes candidates whose upper bound cannot beat the floor. Name matches outrank folder-only matches. Tables over 200k entries split across up to eight threads, and queries allocate nothing.
- **Lifecycle.** `FileIndex` (`core/src/file_index.zig`) owns the File Index from open to atomic swap. `search.Catalog` (`app/src/search.zig`) owns `FileIndex`, the worker thread, and main-thread `poll` swap gating so callers never manage `View` lifetimes. One scan runs at a time, and concurrent rebuild requests coalesce into one follow-up scan. A failed scan keeps the last good mapping, and `open` removes stale temporary files.
- **Syscalls.** `core/src/sys.zig` calls Linux syscalls directly on Linux and libSystem on macOS. Only the `nscore` CLI uses `std.Io`.

## Measured

Release build (`nscore bench`) on a 4-vCPU Linux container:

| Corpus | Entries | Index file | RSS after bench | Name query p50 | Path query (`lib/x`) p50 |
|---|---|---|---|---|---|
| `/usr` (real scan, 49 ms warm) | 91k | 3.1 MB | 3.3 MB | 0.5–2.0 ms | 2.0 ms |
| Synthetic home folder | 1M | 37 MB | 36 MB | 2.5–4.5 ms | 70 ms |

## Known gaps

- **Path queries do not prune.** Terms containing `/` lack a tight score upper bound, so the matcher scores every mask survivor.
- **Full-scan refresh.** `Catalog.rebuildIndex` refreshes `FileIndex` by scanning `$HOME` on a joinable background thread. Next, `poll` swaps the mapped file once no worker search holds the old mapping.

## Gate

`make install-zig && make test-core` runs host unit tests and an `nscore` CLI smoke benchmark. It also cross-builds the other target OS so both `getattrlistbulk` and `getdents64` scanners compile on every run.
