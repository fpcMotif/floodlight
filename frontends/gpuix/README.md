# Floodlight GPUIX

Floodlight's panel, clipboard board and Full Disk Access flow as React
components painted by GPUI through [GPUIX](https://github.com/remorses/gpuix),
on Bun. Files are searched through the Zig core in `core/`. Design, gate and
numbers: [ADR 0014](../../docs/adr/0014-gpuix-frontend.md).

## Build

```sh
make install-zig     # at the repository root, once
cd frontends/gpuix
make                 # build/libfloodlight_gpuix.dylib and "build/Floodlight GPUIX.app"
make test            # typecheck + bun test (parity fixtures, controller, UI on macOS)
make run             # run from source with bun --smol
make measure         # idle footprint, JS heap, summon and query latency, sizes
```

Needs Bun 1.4.4 (`.bun-version`), clang, SQLite (part of macOS;
`libsqlite3-dev` on Linux, where only the library and the tests build).

## Use

Launch `build/Floodlight GPUIX.app`. It has no Dock icon.

| key | action |
|---|---|
| ⌥Space | show or hide the search panel |
| ⌥⇧C | show or hide the clipboard board |

Search: ↑ ↓ move, Return opens (a calculator answer is copied), ⌘Return
reveals in Finder, ⌘Y Quick Looks, ⌘1–⌘6 pick a filter chip, Tab enters web
mode (or the board, after `clip`), Shift-Tab or Esc leaves it, Esc hides, ⌘G
starts the Full Disk Access grant while the notice shows.

Board: Return pastes into the app you came from, ⌥Return or ⌘C copies,
⌘Return or ⌘R reveals, Space (empty field) or ⌘Y previews, ⌘K opens the
actions menu, ⌘. pins, ⌘D deletes, ⌘1–⌘4 filter, Backspace on an empty field
goes back to search.

The index and the history live in `~/Library/Application
Support/com.floodlight.gpuix`, apart from the Swift app's. The history uses
the Swift `clipboard_entries` schema.

macOS ties the Full Disk Access grant to the binary's code hash, so after
every rebuild:

```sh
tccutil reset SystemPolicyAllFiles com.floodlight.gpuix
```

## Layout

| path | what |
|---|---|
| `src/domain/` | plain TypeScript the tests run headless: search session, matcher, engines, calculator, clipboard model, board, panel keys, metrics |
| `src/platform/` | the `bun:ffi` bindings and what wraps them: core index, SQLite store, icons |
| `src/app/controller.ts` | surfaces, show/hide, the AppKit pump while hidden, memory release |
| `src/ui/` | React components |
| `native/` | C and Objective-C: index, SQLite, pasteboard, TCC, window, hotkeys, glass |
