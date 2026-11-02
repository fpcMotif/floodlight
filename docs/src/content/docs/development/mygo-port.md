---
title: Go frontend (MyGo)
description: What the Go port of Floodlight contains, how it is tested, and how to run it beside the Swift app.
---

## At a glance

`frontends/mygo` is Floodlight in Go, drawn by MyGo's native UI on Metal with no webview. It has the Swift app's search panel, Full Disk Access grant flow and clipboard board, over the same Zig core (ADR 0010). It runs beside the Swift app: bundle id `com.floodlight.mygo`, data in `~/Library/Application Support/Floodlight MyGo`, ⌥Space for search and ⌥⇧C for the board.

## Build and run

```bash
make install-zig install-go
```

```bash
make test-mygo
```

```bash
open ".build/mygo/Floodlight MyGo.app"
```

`make test-mygo` runs gofmt, `go vet`, the race-enabled tests and the shared parity fixtures, then builds the app. On macOS it also wraps the binary in an ad-hoc signed bundle.

## How the pieces stack

| Package | Role | Calls the OS? |
|---|---|---|
| `internal/core` | cgo binding to the Zig index: build, map, search, resolve a path | Through the core |
| `internal/match` | Port of the core's matcher, for apps and settings | No |
| `internal/apps` | Scans the app folders, scores names, adds the app bonus of 60 | Reads folders |
| `internal/query` | Calculator, unit conversions, typed web addresses, keyword engines, search modes, System Settings panes | No |
| `internal/search` | The Search Session: one goroutine, one publication per query, latest query wins | Through the core |
| `internal/clipboard` | Classification (ADR 0009), capture rules, the SQLite store on the Swift schema (ADR 0008), the board's list and keys | SQLite only |
| `internal/permission` | The Full Disk Access flow's states and the guidance panel's placement | No |
| `internal/platform` | Every AppKit, Carbon, CoreGraphics, ImageIO and Quick Look call | Yes, macOS only |
| `internal/hotkey` | Carbon hot keys that coexist with MyGo's own | Yes |
| `main` | The panel, board and guidance windows and their views | Through MyGo and `platform` |

Only `platform`, `hotkey` and the views touch the system, so the parity fixtures and view tests run headless, on Linux too.

## Search

Each keystroke calls `Engine.SubmitMode` with the field's text and mode. A one-slot channel holds the waiting query, so a fast typist never builds a backlog. The engine goroutine owns the index handle and every cgo call. It checks for staleness before and after the C search, which cannot be interrupted.

One query publishes one immutable list (ADR 0002):

1. A typed web address, then a keyword engine row (`yt lofi`), then a calculator or conversion answer.
2. Apps, settings and files, scored on one scale: the core's matcher, plus 60 for an app and 30 for a settings pane.
3. At most 79 of those, then the Google row last.

Hits inside `.app` bundles, and bundle folders that duplicate an app, are dropped. Chip counts come from the same list. Tab enters web mode with the keyword engines, Esc and Backspace on an empty field leave it, and Tab on `clip` opens the board, as the Swift `SearchMode` does.

Keys: ↑ ↓ move, Return opens or copies an answer, ⌘Return or ⌘R reveals in Finder, ⌘Y toggles Quick Look, ⌘1–⌘6 pick a chip, Esc hides.

## Clipboard

A goroutine polls the pasteboard's change count every 0.5 s. On a change it reads files, then a PNG or TIFF image with a 128 px thumbnail, then text. It skips concealed, transient and sensitive types, Floodlight's own writes (`com.floodlight.own-write`), a repeat of the newest entry, text over 32,000 bytes and images over 15 MiB. Entries older than 30 days are pruned at launch.

The store is SQLite in WAL mode with the Swift app's `clipboard_entries` table, its trigram full-text table and its triggers. A row the Swift app wrote without a stored classification is classified on read. If the file cannot open, history lives in memory until quit.

The board is 840 × 560 pt with the Swift board's keys: Return pastes, ⌥Return or ⌘C copies only, ⌘Return or ⌘R reveals, Space (empty field) or ⌘Y previews, ⌘K opens the actions menu, ⌘. pins, ⌘D deletes, ⌘1–⌘4 filter. Return writes the entry, hides the board and posts ⌘V to the app that was in front. That needs Accessibility trust; the system prompt is shown once.

## Full Disk Access

The lock button in the search bar shows while the grant is missing. It opens System Settings at the Full Disk Access list and floats a guidance panel under its window, with the app bundle as a drag source. A 0.5 s poll detects the grant, shows it for 1.5 s, closes the panel and rebuilds the index. Without the grant, search works and skips protected folders.

macOS ties the grant to the binary's signature. After each rebuild:

```bash
tccutil reset SystemPolicyAllFiles com.floodlight.mygo
```

## Memory and first summon

- `debug.SetMemoryLimit(25 MiB)`.
- Hiding the panel drops rows, icons, list state and the app list. Hiding the board drops entries, thumbnails and the decoded image. Then `debug.FreeOSMemory()` and `malloc_zone_pressure_relief` return the pages.
- At launch the panel draws one frame off screen, so fonts, glyphs and the Metal pipeline exist before the first ⌥Space.
- `scripts/measure-mygo.sh` reports idle footprint, its split into Go-resident and native memory, summon and query latency, and binary size.

## Parity fixtures

`fixtures/parity/` holds three language-neutral files that every frontend runs through its own test runner:

| File | Checks |
|---|---|
| `search.json` | A file tree and app list; for each query the ranked head of the list, Top Hit, chip counts and the web row; mode transitions |
| `clipboard.json` | Captures in order, each stored with its kind, content, detail, title and subtitle, or skipped with a reason; ages, counts, list order, pinning, search and pruning |
| `board.json` | Key sequences and the action each key asks for; the actions menu per entry |

The Go runner is `frontends/mygo/internal/parity`.

## Known gaps

- The Swift app's learning boost, recents and folder navigation are not ported.
- MyGo exposes no host view behind its Metal view, so the glass is MyGo's own `NSGlassEffectView` (clear style), not one Floodlight installs. See ADR 0012.
- The Objective-C platform layer is built and exercised only on the macOS CI runner.
