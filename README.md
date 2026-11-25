# Nanospot

Nanospot is a keyboard-first macOS launcher written in Zig on [nanoui](https://github.com/justrach/nanoui) over `nanospot-core`, a zero-allocation memory-mapped file index.

It searches applications, files, folders, and the web from one Liquid Glass panel. It also keeps a local Clipboard History board with a live preview pane and direct paste into the active app.

## Features

- `⌥Space` summons the search panel from any space.
- `⌥⇧C` opens Clipboard History with text, file, and image filters.
- `nanospot-core` scans `$HOME` with `getattrlistbulk` into a memory-mapped File Index. Queries run an 8-wide SIMD mask prefilter, fzf-v1 scoring, and a bounded top-k heap with zero allocations.
- Application ranking boosts prefix matches. An empty query lists your most-opened apps under Suggestions (`⌘2` to `⌘6`).
- Inline query completion draws from local query history, Top Hit titles, and Google suggestions.
- Web queries detect direct links and add Google, YouTube, X, and Grok rows.
- Clipboard History stores entries in SQLite and content-addressed image files. It classifies each copy once (`plain`, `link`, `color`, `code`, or `path`) and compacts 7-day-old PNGs to AVIF.
- Clipboard Inspector previews numbered code lines, color swatches, images, and file heads. `Space` opens Quick Look and `⌘K` opens the actions menu.
- Session Retention keeps a hidden search or clipboard session in memory for five minutes. Expiry releases its surfaces and memory pages.
- A Full Disk Access guidance card lets you drag Nanospot straight into System Settings.

## Requirements

- macOS 14 or newer
- Zig 0.17.0 (`make install-zig` fetches the checksum-pinned toolchain into `.tools/`)

## Build and run

```sh
make install-zig
make run
```

Build a signed `Nanospot.app` bundle in `app/zig-out/Nanospot.app`:

```sh
make bundle
open app/zig-out/Nanospot.app
```

## Quality gates

`make check` runs the same mechanical gates locally and in CI:

```sh
make check                # core + app fmt check, unit tests, cross-build, release benches, bundle codesign, and snapshot
make format               # format core/ and app/ with pinned zig fmt
make bench-nanoui-memory  # verify idle and post-retention footprint budgets
make docs                 # build the Astro site in docs/ with bun
```

| Gate | Script | What it verifies |
| --- | --- | --- |
| `make test-core` | `scripts/test-core.sh` | `zig fmt --check`, engine unit tests, Linux/macOS cross-build, and `nscore` index/search/bench smoke test. |
| `make test-nanoui` | `scripts/test-nanoui.sh` | `zig fmt --check`, offscreen `ui.Tester` unit and state-machine tests, `NANOSPOT_BENCH` p99 latency budgets, `com.nanospot.app` bundle codesign requirement, and headless PNG snapshot. |

## Architecture

```text
app/src/main.zig (Shell: windows, hotkeys, timers, worker dispatch, OS wiring)
  ├─ Presence (app/src/presence.zig: hidden / entering / shown state machine)
  ├─ Panel (app/src/panel.zig + panel/view.zig + panel/suggestions.zig)
  │   ├─ search.Catalog (app/src/search.zig: apps, worker thread, FileIndex swap gating)
  │   │   └─ FileIndex (core/src/file_index.zig: scan, mmap, atomic swap, SIMD top-k search)
  │   ├─ list.List (app/src/list.zig: arena-owned rows, filter counts, selection)
  │   └─ Board (app/src/board.zig: Clipboard History rows, Clipboard Inspector, footer actions)
  │       └─ clipboard.Store (app/src/clipboard/: SQLite + image files, single-pass classification)
  ├─ permission.Flow + Guidance (app/src/permission.zig: Full Disk Access grant flow)
  └─ mac (app/src/mac/: Carbon hotkeys, Liquid Glass slab, NSPasteboard, Quick Look, TCC)
```

[`GLOSSARY.md`](GLOSSARY.md) defines the domain terms, and [`docs/adr/`](docs/adr/) records the architectural decisions.

## Comments

A comment says **why** because the code already says what.

- A `///` doc comment states the **contract**: invariants, preconditions, units, ownership, and thread rules.
- A `//` line comment states the **reason**: constraints, measurements, or subtle failure modes avoided.

## Privacy and storage

Nanospot indexes your home folder and keeps all state under `~/Library/Application Support/Nanospot`. That folder holds the File Index (`names.flix`), Clipboard History (`clipboard.sqlite3` and `clipboard-images/`), query history, and app open counts. Clipboard Capture skips password-manager copies, transient pasteboard types, and Nanospot's own `com.nanospot.own-write` writes before storage.

Grant **Full Disk Access** in System Settings → Privacy & Security so Nanospot can index protected folders. Grant **Accessibility** so Return can paste directly into the previous app.

## License

Nanospot is available under the [MIT License](LICENSE).
