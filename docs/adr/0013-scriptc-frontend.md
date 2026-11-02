---
status: proposed
date: 2026-11-02
---

# A scriptc-compiled terminal frontend in `frontends/scriptc/`

Issues #111 and #115 ask for a frontend written in TypeScript and compiled ahead of time to a native binary by [scriptc](https://github.com/vercel-labs/scriptc), with no Node.js or V8 inside. This ADR records whether that works, which frontend came first, and what it costs. The Swift app is unchanged. `Sources/` is not touched.

## Step 0: is scriptc real and usable?

Checked before any frontend code was written.

- **It exists.** `vercel-labs/scriptc`, Apache-2.0, an active Vercel Labs experiment. Pinned at **0.4.7** in `frontends/scriptc/package.json` and `bun.lock`, installed with `bun install`. Native compiler builds ship for darwin-arm64/x64 and Linux.
- **It compiles TypeScript to a native executable without a JS engine.** It uses the TypeScript checker's types, lowers to LLVM, and links a small precompiled runtime (reference counting, strings, arrays, an event loop). The output links only libc/libSystem. Two checks make "no V8" hold here: `scriptc coverage --fail-on node-islands` fails the build if any code would need its optional `libnode` bridge, and `--fail-on dynamic` fails it if any statement falls back to the untyped dynamic tier. The frontend passes both: 703 of 703 statements compile statically.
- **Hello world** (Linux x86-64): 104 KB executable, 1.5 MB RSS, ~3 ms wall-clock including fork/exec. Mac numbers are in the PR.
- **FFI to C** is a JSON manifest (`ffi.json`) plus bodiless `declare function`s. It takes scalars (`i32`, `u32`, `f64`, `bool`…), borrowed UTF-8 spans (`string` → `const uint8_t *, size_t`), and writable byte spans (`mutable-bytes` → `uint8_t *, size_t`). It links static archives, and on Darwin it can link frameworks. Callbacks exist (call-scoped, retained, and foreign-thread delivery onto the event loop). **What it cannot do:** out-parameters, structs by value, variadic calls, owned pointer/string returns, or runtime `dlopen`. So `floodlight_core.h` (`fl_index_open(path, fl_index **out)`, NUL-terminated paths, an `fl_hit` array), termios (`struct termios`) and `posix_spawn` cannot be called directly. A ~300-line C shim (`native/flshim.c`) reshapes each call into what the FFI can express. It keeps one live index handle inside so TypeScript never holds a pointer, takes spans and writes results into caller-owned buffers.
- **What it rejects or degrades**, as hit in practice:
  - `eval`, `new Function` and `vm` throw. `require`/dynamic `import` of unknown modules, Node-API addons, and JSX are refused.
  - A call through an `interface` type compiles, but in the dynamic tier. The file-source seam is an abstract class for that reason.
  - `Number(x)` on a string is dynamic too. `parseInt` is static.
  - Importing an interface without `import type` **built successfully and failed at run time** with a `SyntaxError`. This is the one silent failure found. The coverage gate does not catch it, so the self-test and smoke run are what stand between it and a release.
  - Some generics (generic functions declared inside functions), some union widening, and class reflection are refused at build time with a diagnostic.

**Verdict: feasible.** The gate passed, so the work went ahead.

## Which frontend first: the terminal UI (#115)

The FFI calls a small C shim cleanly, so #111's Cocoa bridge is possible too. The terminal UI still came first, for three reasons:

1. **Fewest unknowns.** It needs termios, `poll`, `write` and `posix_spawn`, all plain C. A Cocoa bridge also has to answer how the AppKit run loop and scriptc's event loop share the main thread. That question is answered below, but only after the TUI proved the rest of the stack.
2. **It tests the whole stack.** TypeScript domain logic, FFI into the Zig core, an OS action, and resource measurement all run end to end in CI without a window server.
3. **It sets the floor.** Its idle memory is the lower bound any scriptc frontend can reach. A Cocoa build adds AppKit and WindowServer costs on top.

### Then the panel (#111), on the same session

The TUI cannot match a launcher's feel on a Mac: no hotkey of its own, a terminal window's chrome, no icons. So `floodlight-panel` adds #111's native GUI on top of the same TypeScript `SearchSession`, apps catalog and core index. The bridge is Objective-C (`native/flpanel.m`, ~350 lines), not Metal: AppKit already draws text, icons and vibrancy well, and a custom Metal pipeline would only add work and memory.

The hard question was the run loop. AppKit wants `-[NSApplication run]` on the main thread, and scriptc's script thread *is* the main thread. The answer is to invert it. TypeScript calls `flp_wait`, which pumps `nextEventMatchingMask:` until something the script cares about happens (the query changed, an arrow key, Enter, Esc, the hotkey, a click) and returns it as an integer. The script updates the session and pushes rows back with `flp_add_row`/`flp_commit`. No script code runs inside an AppKit callback, so scriptc's thread rules hold without its callback machinery.

- A borderless, non-activating `NSPanel` at pop-up level that joins all Spaces and full-screen apps. It takes keyboard focus without stealing activation from the app underneath, the way Alfred and Raycast do.
- An `NSVisualEffectView` background that follows light and dark mode. Rows are drawn in one view: Finder icons, matched characters in semibold, the path truncated from the head.
- ⌥Space through Carbon `RegisterEventHotKey`, which needs no Accessibility permission. ⌘Space stays Spotlight's.
- Hiding drops the rows and the icon cache, so idle memory falls back to the baseline between summons.
- The panel is built and smoke-tested on macOS only. Its coverage gate (no Node islands, no dynamic tier) runs there too.

## Shape

```
frontends/scriptc/
  src/session.ts   SearchSession: query → one ranked publication, mode, filter, selection
  src/match.ts     fuzzy matcher for names (prefix, word starts/acronyms, runs)
  src/apps.ts      .app bundles in the standard folders, read once at start
  src/files.ts     FileSource over floodlight-core via the shim
  src/screen.ts    double-buffered cell grid; per-row diff; DEC 2026 sync
  src/view.ts      layout: prompt, filter chips, badged rows, notice, footer
  src/keys.ts      raw bytes → keys (CSI/SS3, split UTF-8, lone-ESC timing)
  src/main.ts      the TUI loop, plus --bench / --exit-after-paint / --idle-report
  src/panel.ts     the panel loop (macOS), plus --smoke
  src/index-file.ts  index location, open, background rebuild
  src/core-match.ts  port of the core matcher, for app and setting scores
  src/engines.ts   keyword engines, web mode rows, typed web addresses
  src/calculator.ts  arithmetic and unit conversions
  src/settings.ts  System Settings panes
  src/filters.ts   result filters and counts
  src/clip-*.ts    clipboard entry, capture policy, store seam, SQLite store, board
  src/board-view.ts  the board split view
  src/fda.ts       the Full Disk Access grant flow
  src/agent.ts     floodlight-clipd, the capture agent
  native/flshim.c  the C shim: termios, poll/read/write, posix_spawn, core
  native/flpanel.m the Cocoa shim: NSPanel, rows view, Carbon hotkey
  native/flclip.c  Clipboard History on SQLite, the Swift schema
  native/flmac.m   the platform layer: pasteboard, paste, TCC (stub elsewhere)
  launch/floodlight-popup  floating-terminal launcher for a global hotkey
```

- **One thread, latest wins without cancellation.** The loop blocks in `poll`. Once input arrives it drains every pending byte, applies all keys to the query text, and runs one search for the final text. A burst of typing or a paste costs one query, not one per key. Nothing is ever in flight to cancel. Arrow keys flush the pending query first, so they always move over current results.
- **Index lifecycle.** The index (`~/Library/Application Support/com.floodlight.tui/files.flix`) is `mmap`ed at start. If it is missing or older than 15 minutes, the shim rebuilds it on a pthread. The rebuild writes a temp file and renames it (ADR 0010), and the script thread swaps handles when `fls_index_poll` reports the rebuild done. TypeScript never runs off the main thread, which scriptc forbids anyway.
- **Opening.** Enter runs `/usr/bin/open`; ⌥Enter runs `open -R`. Both go through `posix_spawn` with `POSIX_SPAWN_SETSID`, so the opener survives the popup terminal closing the instant the TUI exits.
- **Rendering.** Each frame is drawn into a back buffer. Per row, only the span from the first to the last changed cell is written, inside a synchronized-update bracket, so there is no flicker. Wide (CJK, emoji) and zero-width characters are handled, and no run ever splits a wide character.
- **Global hotkey.** A terminal program cannot own one. `launch/floodlight-popup` opens a borderless Ghostty, kitty, Alacritty or WezTerm window (or a Terminal.app window) running the TUI. Bind it with Shortcuts.app (a "Run Shell Script" action with a keyboard shortcut), skhd or Hammerspoon. Window creation dominates summon latency on that path, not the TUI.

## Measured

On the Linux CI-class container (x86-64), indexing `/usr` (91k entries), from `make measure-scriptc`:

| metric | value |
|---|---|
| binary size (stripped) | 557 KB |
| `main()` → first paint | 3.6 ms |
| idle RSS / footprint | 2.4 MB / 2.5 MB |
| query p50 / p95, search only | 0.95 / 2.2 ms |
| query p50 / p95, keystroke → frame | 1.0 / 2.2 ms |
| RSS with the index fully paged in | 6.1 MB |

The xcode-27 Mac runner numbers, including exec → first paint from the kernel's process start time, are in the PR and in the `scriptc frontend` job summary on every run.

## The full port (#115)

The TUI now does what the Swift app does in search, the Full Disk Access
grant and Clipboard History, adapted to a terminal where a feature needs a
window. The domain is plain TypeScript with no native calls, shared with the
Cocoa panel:

- **Search Session** (`session.ts`). One immutable publication per query
  (ADR 0002): at most 80 rows, the Google row always last, filter counts from
  the same list. Local rows rank in the core's score space: a file scores
  what the Zig core gave it, an app what `core-match.ts` (a port of
  `core/src/match.zig`) gives its name, plus 60. File hits inside `.app`
  bundles and folder hits that duplicate an app are dropped. Typed addresses
  (`engines.ts`, the Swift `DirectLink`), keyword engines (ADR 0006),
  arithmetic and unit conversions (`calculator.ts`) rank above that space,
  as in the Swift app. System Settings panes (`settings.ts`) score like an
  app, with a bonus of 30. Tab, Shift-Tab, Esc and Backspace-on-empty move
  between local, web and clipboard modes as `SearchMode` does.
- **Clipboard** (`clip-entry.ts`, `clip-capture.ts`, `clip-board.ts`).
  ADR 0009's classification with the Swift board's titles and subtitles; the
  capture gates (concealed, transient, own write, repeat, 32,000-byte text,
  15 MiB image); the board's list order, filters, actions menu and keys. Keys
  reach the board as logical names (`return`, `cmd+d`), so one fixture
  drives every frontend.
- **Store** (`native/flclip.c`). SQLite in WAL mode on the Swift app's
  `clipboard_entries` schema, migrations and trigram FTS table (ADR 0008):
  every pinned entry plus the 1000 newest, or up to 200 matches. If the file
  will not open, history lives in memory for the run.
- **Platform layer** (`native/flmac.m`, a stub elsewhere). Every AppKit,
  CoreGraphics, ImageIO and TCC call: the pasteboard, ⌘V to the paste target,
  app names, the Full Disk Access probe and the host terminal's bundle. The
  domain modules never call the OS, so the parity fixtures run headless.

| Shared contract | In the TUI |
|---|---|
| Carbon hotkey, non-activating panel | `floodlight-popup` (⌥Space) and `floodlight-popup --board` (⌥⇧C), bound in Shortcuts.app, skhd or Hammerspoon |
| Paste target | The launcher records the frontmost app (`lsappinfo`) and passes `--paste-pid`; ⌘V is posted after the TUI exits |
| Liquid Glass, resize without stale frames | Not applicable: the TUI fills its terminal and redraws on resize |
| Icons and thumbnails | A kind badge per row; images show dimensions and size |
| Quick Look | Ctrl-Y (Space on an empty board query) runs `qlmanage -p` |
| Full Disk Access guidance panel | A notice row; Ctrl-G opens Settings at the list and reveals the terminal app for dragging; a 1 s poll sees the grant and rebuilds the index |
| Board at 840 × 560 pt | A split view at 3/7 list, 4/7 inspector of the terminal's width |
| Clipboard capture | `floodlight-clipd`, a second scriptc binary run by launchd, polls every 0.5 s |
| ⌘ keys | ⌥ stands in for ⌘, with Ctrl chords as a second spelling |

### Parity fixtures

`fixtures/parity/` at the repository root holds the shared seam: a file
tree, an app list and queries with their ranked rows, Top Hit and counts
(`search.json`); captures with the stored entry or "skipped"
(`clipboard.json`); and board key sequences with the action they request
(`board.json`). The self-test indexes the tree with the real Zig core and
runs every case through the same entry points the TUI uses.

## Known gaps

- **Assistant engines** (`claude`, `codex`) are left out of keyword search:
  they need a process runner and a result view the terminal does not have.
- **Bitmap image previews** in the terminal are out of scope; Quick Look
  shows them.
- **No live file updates** beyond the start-up staleness rebuild and the
  rebuild after a Full Disk Access grant, the same gap ADR 0010 has.
- **The platform layer is checked on macOS only.** On Linux it is a stub, so
  paste, copy and capture do nothing there; the domain and the store are
  tested on both.
- **scriptc is experimental.** The ABI between the compiler and its runtime pack is versioned (`scr_runtime_abi_v22`), and the pin moves only on purpose.

## Gate

`make test-scriptc` (CI job **scriptc frontend**, xcode-27) runs:

1. the self-test, compiled by scriptc: matcher, key parser, session, every frame replayed through a VT emulator and compared cell by cell, and the parity fixtures;
2. the coverage gate for the TUI and the capture agent: no Node islands, no dynamic tier;
3. a smoke run of the stripped binaries against a real index and store on a pipe: search, calculator, web mode, capture gates, board pin and delete, the Full Disk Access notice, and app search for Terminal.app on macOS.

`make measure-scriptc` writes the size, cold start, idle memory and latency table to the job summary.
