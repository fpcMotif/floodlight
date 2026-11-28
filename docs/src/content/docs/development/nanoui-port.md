---
title: Architecture (nanoui)
description: How Nanospot structures search, the file index, and clipboard history across app/ and core/.
---

## At a glance

Nanospot's launcher UI lives in `app/`, written in Zig on nanoui 0.9.2. It covers the search panel, the Full Disk Access drag flow, and the clipboard board.

File search runs on the Zig core in `core/`. The core scans the home folder into one memory-mapped index file and searches it without allocating. A C ABI (`core/include/nanospot_core.h`) lets any other frontend use the same index.

Nanospot registers global hotkeys (`⌥Space` for search, `⌥⇧C` for the board), uses bundle identifier `com.nanospot.app`, and stores its data under `~/Library/Application Support/Nanospot`.

## Commits

| Commit | What it did |
|---|---|
| `e7d70e75` | **Core file index.** Scanner, memory-mapped index, SIMD search, C ABI, `make test-core`, a CI job on macOS. |
| `61d92887` | **Zig 0.17.0.** The core calls the kernel through `core/src/sys.zig`. Zig 0.15.2 could not link against the macOS 27 SDK. |
| `57cc8fe4` | **nanoui frontend.** Panel on ⌥Space, Liquid Glass slab, app and file search, the Full Disk Access guidance panel with a drag source. |
| `8daab45f` | **Parity and clipboard.** Layout metrics, filter chips with counts, Top Hit, kind badges, the Google row, and the clipboard board with SQLite storage. |
| `f6cd5c6d` | **Resize fix and hotkey.** No stretched frame when the panel resizes. Clipboard board hotkey set to ⌥⇧C. |

## How the pieces stack

| File | Role |
|---|---|
| `app/src/panel.zig`, `app/src/panel/view.zig`, `app/src/board.zig`, `app/src/chrome.zig` | What you see: the search field, result rows, filter chips, shared tokens, and the clipboard board. nanoui draws them with Metal. |
| `app/src/shell.zig`, `app/src/main.zig` | `Shell` holds the controller state and action transition rules; `main.zig` owns AppKit windows, hotkeys, timers, and OS wiring. |
| `app/src/mac.zig`, `app/src/mac/`, `app/src/permission.zig` | macOS calls that nanoui does not cover: Carbon hotkeys, `os_signpost` probes, the glass slab, the pasteboard, paste delivery, Quick Look, the ⌘K menu, and the Full Disk Access probe. |
| `app/src/bench.zig` | In-process latency benchmark over a 200-app catalog (`zig build bench --release`). |
| `app/src/clipboard.zig`, `app/src/clipboard/` | The clipboard domain model and SQLite + image store. No UI code. |
| `app/src/search.zig` | The catalog: installed apps scored in memory, async worker search, and the mapped file index. |
| `core/` | Scan, index file and search. Reached as a Zig module (`nanospot_core`) or through the C ABI. |

## Search

```text
type in field
  panel.refresh(query)
    Catalog.query(arena, text)
      apps:  core.match.score(app.name, needle) + app_bonus 60
      files: core.search.search(mapped.view, query, hits[80])
      merge, best first, up to max_rows 80
    rows grouped by filter chip (All, Apps, Files, Folders, PDFs, Images)
    last row: search Google for the text
```

- Apps come from the standard app folders and `~/Applications`. Each `*.app` directly inside one counts.
- An app outranks a file with the same score.
- The panel is 760 pt wide. It is 60 pt tall when empty and 560 pt with results. It keeps its top edge when it resizes.
- Return opens the selected row. The top row shows as the Top Hit.

## The file index

### Build

- The scan uses `getattrlistbulk(2)` on macOS and `getdents64(2)` on Linux. It walks depth first with `openat` against the parent folder, so it never builds a full path.
- The index is a struct of arrays. Each name is stored once with its parent id.
- The file is written to a temporary file and renamed into place, so an open index never changes under a reader.

### Search

- An 8-wide SIMD character-mask prefilter skips names that cannot match.
- Names that pass are scored with fzf-v1 scoring into a bounded top-k heap. Once the heap is full, names that cannot beat it are pruned.
- Name matches rank above matches only in a folder name. Space-separated terms must all match.
- Past 200k entries the search splits across threads. A query allocates nothing.

### Measured

Release build, `nscore bench`, on a 4 vCPU Linux container:

| Tree | Index size | Memory (RSS) | Name query |
|---|---|---|---|
| `/usr`, 91k entries | 3.1 MB | 3.3 MB | 0.5–2 ms |
| Synthetic, 1M entries | 37 MB | 36 MB | 2.5–4.5 ms |

Queries that contain `/` do not prune yet and take about 70 ms at 1M entries. See [ADR 0010](https://github.com/fpcMotif/nanospot/blob/main/docs/adr/0010-zig-file-index-core.md).

### Lifecycle in the app

1. At launch, the last index, `~/Library/Application Support/Nanospot/names.flix`, opens at once.
2. If Full Disk Access is granted, a background thread rebuilds the index from `$HOME`. The new index replaces the old mapping on the main thread.
3. When access is granted later, the index rebuilds again, because folders that were closed to the scan are now open.

`FileIndex` in `core/src/file_index.zig` owns these steps. One scan runs at a time, and requests that arrive during a scan share one follow-up scan. A failed scan keeps the last index.

### C ABI

```c
int      ns_index_build(const char *root, const char *out_path);   /* entry count, or < 0 */
int      ns_index_open(const char *path, ns_index **out);          /* read-only mmap */
uint32_t ns_search(const ns_index *, const char *query, ns_hit *out, uint32_t cap); /* cap <= 256 */
uint32_t ns_relative_path(const ns_index *, uint32_t id, char *buf, uint32_t cap);
bool     ns_is_dir(const ns_index *, uint32_t id);
void     ns_index_close(ns_index *);
```

One open handle is safe to search from many threads at once.

## Clipboard

### Capture

The shell polls every 0.5 s.

- It reads the pasteboard change count. When the count changes, it reads files, then images (PNG or TIFF), then text.
- Text is kept up to 32,000 bytes. Images are kept up to 15 MiB, with a 128 px thumbnail.
- Nanospot's own writes are skipped by a marker type (`com.nanospot.own-write`). Concealed and transient types, such as passwords, are skipped too.
- A copy that repeats the newest entry is skipped. Entries older than 30 days are pruned at launch.

### Classification

Classification follows [ADR 0011](https://github.com/fpcMotif/nanospot/blob/main/docs/adr/0011-nano-clipboard-history.md). Each entry has a **kind**: text, file or image. Text also gets a **content** type: plain, link (with its domain), color (hex or rgb), code (JSON, HTML or other code), or path.

### Store

SQLite at `~/Library/Application Support/Nanospot/clipboard.sqlite3`, in WAL mode, table `entries`. The app falls back to an in-memory database if the file cannot open. A list shows pinned entries first, then the newest. It holds the 1000 newest entries, or up to 200 matches for a search.

### The board

The board opens on ⌥⇧C. It is 760 × 560 pt: a 320 pt list, a 425 pt inspector and a 32 pt footer.

| Key | Action |
|---|---|
| `↵` | Paste into the previous app with ⌘V (needs Accessibility) |
| `⌥↵` or `⌘C` | Copy only |
| `⌘↵` or `⌘R` | Reveal in Finder |
| `Space` or `⌘Y` | Quick Look preview |
| `⌘K` | Actions menu |
| `⌘.` | Pin |
| `⌘D` | Delete |
| `⌘1`–`⌘4` | Filter: All, Text, Files, Images |

## Reuse map for another frontend

| Part | Reusable | Notes |
|---|---|---|
| `core/` index and search | As is | Zig module (`nanospot_core`) or the C ABI. Any language with C FFI can call it. |
| `app/src/clipboard.zig` model and store | As is | No UI code. It needs the system `sqlite3` library. |
| `app/src/search.zig` catalog | As is | Merges apps and files into ranked rows. |
| `app/src/permission.zig` grant flow | Logic only | The flow's states are reusable. The guidance panel is nanoui UI. |
| `app/src/mac.zig` | macOS only | Hotkeys, pasteboard, paste delivery and Quick Look work for any macOS frontend. The glass slab assumes an `NSWindow`. |
| `app/src/panel.zig`, `app/src/board.zig` | Rewrite | nanoui views. Layout tokens live in `chrome.zig` and `board.zig`. |

## Pitfalls

- **Full Disk Access resets when code-signing identity changes.** Run `tccutil reset SystemPolicyAllFiles com.nanospot.app`, then drag the app into the list again.
- **Resizing a Metal window shows a stale frame.** The window grows before a frame at the new size is presented, and Core Animation scales the old frame to fit. Pin the layer with `contentsGravity` and redraw just after the resize (`f6cd5c6d`).
- **Zig 0.17 has no `std.fs` file API.** Use `std.Io` or `core/src/sys.zig`. A parameter cannot share a name with a top-level declaration.
- **jj refuses large files.** `testing/fff-exploration/…/trace.jsonl` is 85.8 MiB. Commit named paths only.
- **The glass is clear by design.** Desktop text shows through the rows.

## Latency probe and benchmark baseline

### Signpost intervals

The release binary emits `os_signpost` intervals on subsystem `com.nanospot.app` in category `PointsOfInterest`:

| Interval name | Start | End |
|---|---|---|
| `hot key → first presented frame` | Hot key or reopen orders the panel in (`Entrance.orderedIn`) | First Metal frame with a drawable reveals the window (`Entrance.reveal`) |
| `keystroke → Panel publication` | Query text changes in `Panel.refresh` | Ranked rows and active filter chips are published to `Panel.visible` |
| `Return → action handed to macOS` | `Return` submits the selected action in `Shell.panelRequest` | `Shell.applyPanel` finishes handing the action to macOS |

When Instruments is not recording, `os_signpost_enabled` returns `false` and the probe costs one branch check. To inspect the intervals in Instruments, build `zig build bundle --release` inside `app/`, open Instruments with the **Points of Interest** or **Logging** template, and target `app/zig-out/Nanospot.app`. You can also stream the intervals from a terminal:

```sh
/usr/bin/log stream --signpost --style compact --predicate 'subsystem == "com.nanospot.app"'
```

### In-process benchmark

`zig build bench --release` runs `Panel` against a 200-app catalog for 2000 warm iterations. It prints `p50` and `p99` in microseconds and exits non-zero if a `p99` exceeds its budget in `app/src/bench.zig`.

| Metric | Budget p99 (µs) |
|---|---|
| `keystroke → publication` | 10.00 |
| `hotkey → laid-out frame` | 10.00 |
| `Return → action` | 10.00 |
| `keystroke → built frame` | 4300.00 |
| `first frame with icons` | 46000.00 |
| `hotkey → built frame` | 1500.00 |

### 240 fps screen-recording procedure

Use a 240 fps camera to compare Nanospot and Nanolight end to end on the same Mac.

#### Setup

1. Build the release bundle with `cd app && ../.tools/bin/zig build bundle --release`.
2. Launch `app/zig-out/Nanospot.app` and `/Applications/Nanolight.app` on the same Mac. Summon each app once so caches and permissions are warm.
3. Mount a 240 fps camera on a stand. Frame the `Space`, `C`, and `Return` keys together with the panel area on screen.
4. Set display brightness above 75% and turn off True Tone and Night Shift.

#### What to film

Record five trials for Nanospot and five trials for Nanolight across three interactions:

1. **Summon**: hold the modifier key and press the trigger key (`⌥Space` for Nanospot) until the panel appears.
2. **First keystroke**: focus the empty search panel and press `C` until the first result rows appear.
3. **Return**: select `Calculator` as the Top Hit and press `Return` until the panel closes.

#### How to count frames

1. Open the 240 fps `.mov` file in QuickTime Player or `ffmpeg`. Step through the video one frame at a time.
2. Record frame $F_0$ as the first frame where the key cap reaches the bottom of its travel.
3. Record frame $F_1$ as the first frame where the screen shows the new state.
4. Compute the frame count $N = F_1 - F_0$ and the latency $T = N \times 4.17\text{ ms}$ ($1000 / 240$). Compare the five-trial median for Nanospot against Nanolight.

#### Baseline comparison (Nanospot vs Nanolight)

Measured on the same Mac mini (macOS 27.2):

| Interaction | Nanospot baseline | Nanolight 0.2.11 | Cause of initial gap |
|---|---|---|---|
| **Summon** (`hot key → first presented frame`) | 256.0 ms (~61 frames at 240 fps) | 12.2 ms (~3 frames at 240 fps) | `orderIn` sets `alpha = 0` before `show()`, so `occlusionState` stays occluded until the 250 ms fallback timer (`revealAnyway`) fires. |
| **First keystroke** (`keystroke → publication`) | 12.0 ms with file index (2.08 µs apps-only) | < 1.0 ms in-process (18.3 ms presented, ~4 frames at 240 fps) | `Catalog.query` searches the full mapped home-folder file index synchronously on the main thread before publishing app rows. |
| **Return** (`Return → action handed to macOS`) | 45.0 ms end-to-end (0.71 µs to hook) | 0.51 ms (< 1 frame at 240 fps) | `Shell.panelRequest` defers `applyPanel` via `dispatchMain` after the full frame finishes and calls synchronous `openURL:`. |

## Checks

| Command | What it runs |
|---|---|
| `make test-nanoui` | `zig fmt` check, unit tests, 200-app latency benchmark (`zig build bench --release`), app bundle, panel snapshot |
| `make test-core` | `zig fmt`, engine tests, cross-build, CLI smoke and bench |

## Open items

- Path queries with `/` are not pruned yet.
