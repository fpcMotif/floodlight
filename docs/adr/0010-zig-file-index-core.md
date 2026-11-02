---
status: proposed
date: 2026-11-02
---

# File search moves to a memory-mapped Zig index in `core/`

File search will run on `floodlight-core`, a Zig engine in `core/` that the Swift shell links as a static library through `core/include/floodlight_core.h`. It replaces FFF for file search only. Applications, System Settings, the clipboard, and the UI stay in Swift. This ADR covers the engine. Wiring it behind the `FileSource` seam is the next change, and that change is what flips this ADR to accepted.

## Why

FFF is a code-search engine built for an editor's project root. Floodlight points it at the home folder, where its defaults go the wrong way. It keeps a content cache (128 MB at home-folder scale until #121 capped it), keeps a bigram index of every text file, writes LMDB frecency stores, and runs a thread pool. Every one of those lives in dirty heap memory, which macOS cannot drop under pressure. A launcher needs one thing on each keystroke: names, ranked.

Issues #110, #116, and #118 set the goal as a lower memory floor and less per-keystroke work. They proposed a full Zig rewrite including the UI. This ADR takes the part of that plan that can be measured today: the index and the matcher. A UI rewrite would give up QuickLook, accessibility, onboarding, and the tested shell for a few MB of AppKit baseline. It is not proposed here.

## Shape

- **Scan:** `getattrlistbulk(2)` on macOS returns names and types in 64 KB batches, with no `stat` per file. `getdents64(2)` does the same job on Linux, so the engine builds and benchmarks off a Mac. The walk is depth-first with one directory fd per level, and each child is opened with `openat` against its parent, so no full path is ever built. Hidden entries and generated trees (`node_modules`, `DerivedData`, `.build`, …) are skipped.
- **Index:** a struct-of-arrays table: name mask, path mask, parent id, name offset and length, flags, and depth. Each name is stored once. Paths are rebuilt from parent links only when a query needs them. The file is written through a temporary file and a rename, and opened with one read-only `mmap`. The pages are clean and file-backed, so the system can evict them and fault them back in. This is the main memory claim: the index never counts as dirty memory.
- **Search:** a 32-bit character mask per entry rejects candidates eight at a time with one SIMD compare. Survivors are scored with fzf's v1 two-pass window. A bounded min-heap keeps the top k. Once the heap is full, each candidate is first checked against an upper bound on its best possible score. A candidate that cannot place is usually rejected by one prefix compare. Name matches always outrank folder-only matches, the order Spotlight uses, which lets the path fallback be pruned too. Tables over 200k entries split across up to eight threads. A query allocates nothing.

- **Syscalls, not `std.Io`:** the engine reaches the kernel through `core/src/sys.zig`: `openat`, `pwrite`, `ftruncate`, `renameat`, `mmap`. That goes straight to Linux syscalls on Linux and to libSystem on macOS. Every call is one blocking syscall on a path that is already off the main thread, so an event-loop handle would add nothing, and Zig's reworked I/O API has no way into the hot path. Only the `flcore` CLI uses `std.Io`.
- **Zig 0.17.0:** 0.15.2 cannot link against the macOS 27 SDK's libSystem stubs. Its build runner fails with every libc symbol undefined on the `xcode-27` runner.

## Live updates

The index stays current without a full rescan. `core/src/live.zig` wraps one mapped file in a *generation*: the file, a tombstone bitset, and an overlay.

- **Events in:** FSEvents through the CoreServices C API on macOS, one stream for the whole tree with file-level events, delivered on a private dispatch queue. inotify on Linux, one watch per indexed folder, so the same path runs under `make test-core` off a Mac. A shell with its own source calls `fl_live_notify`. Each event names a path; the engine looks at the disk (one `openat` probe) rather than trusting the event's verb, because FSEvents coalesces and inotify splits a rename in two. Dropped-event flags, a queue overflow, and a moved root ask for a rescan of the subtree instead.
- **Tombstones:** a deleted mapped entry gets a bit. A deleted folder takes its whole subtree in one forward pass, since every descendant follows its first child and every parent precedes its children. Search skips set bits after the mask test, so the check costs nothing for the rejected majority.
- **Overlay:** new entries sit in a small heap table with stored paths. Its ids start at 2³¹, so one `u32` names either kind. It is append-only between swaps, so an id keeps naming the same entry for the whole generation. A folder that appears with contents (moved in, unpacked) is listed into the overlay at once, off the lock, if it fits.
- **Compaction:** every change marks its folder dirty. Past `overlay_limit` changes (4096 by default), a background thread builds a fresh table: clean folders are copied from the old mapping, dirty folders are listed again with one `getdents64` / `getattrlistbulk` pass, and folders new since the last write are walked. The file goes through the existing temporary-file-and-rename path, is mapped, and swapped in under the write lock. Events that arrived while the table was built are queued and replayed onto the new generation in the same critical section, so nothing falls between the old listing and the new one.
- **Reads stay allocation-free:** a query takes a shared lock and walks the mapping, the bitset, and the overlay with stack buffers only. The overlay's slots are fixed at four times `overlay_limit` when the generation is created; past that, entries wait for the compaction already queued.
- **Ids carry a generation:** `fl_live_search` returns the generation its hits belong to. `fl_live_relative_path` takes it back and answers nothing once a swap has replaced it, rather than a different file's path.

On the `/usr` corpus (91k entries, release build, same container): a compaction takes 26 ms end to end, tombstoning `share` (most of the tree) 0.3 ms, and resolving a path for an event 9 µs. Compaction is linear in entries; the write lock is held only for the swap.

## Measured

On this repo's Linux CI-class container (4 vCPU), release build, numbers from `flcore bench`:

| corpus | entries | index file | RSS after bench | name query p50 | path query (`lib/x`) p50 |
|---|---|---|---|---|---|
| `/usr` (real scan, 49 ms warm) | 91k | 3.1 MB | 3.3 MB | 0.5–2.0 ms | 2.0 ms |
| synthetic home folder | 1M | 37 MB | 36 MB | 2.5–4.5 ms | 70 ms |

RSS here means the whole process, with the index fully paged in. Against the issue's figure of about 358 MB for FFF, that is one to two orders of magnitude, and the remainder is evictable. No Mac numbers yet. `make test-core` runs the same bench on the macOS CI runner.

## Known gaps

- **Path queries do not prune.** A term containing `/` has no tight score bound, so every mask survivor gets scored. A per-directory pre-match is the next step if path queries matter.
- **Event lookups are linear in the worst case.** Resolving a path finds each folder's child run with one vectorised scan of the parent column, not a hash. Fine at event rates (9 µs on 91k entries); a child index would be the fix if a million-entry tree shows it.
- **inotify has a watch limit.** Linux watches each folder, and a tree past `max_user_watches` goes partly unwatched. Linux is the test platform, not a shipping one, so this stays.
- **FSEvents is compile-checked, not run, in CI on Linux.** The cross-build keeps it compiling; the macOS runner is where it runs.
- **No content search.** FFF's grep keeps that job until the Swift side decides whether content search earns its memory.

## Gate

`make install-zig && make test-core`: unit tests on the host (including create, rename, and delete through the live index, searches racing compactions, and the overlay bound triggering one), a release cross-build for the other OS so both scanners and both watchers keep compiling, and a CLI smoke run that ends in `flcore bench`. Zig is pinned by version and SHA-256 in `scripts/tool-versions.env`, like every other gate tool.
