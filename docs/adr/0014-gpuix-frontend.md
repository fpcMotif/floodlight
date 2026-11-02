---
status: proposed
date: 2026-11-02
---

# A GPUIX frontend in `frontends/gpuix/`, beside the Swift app

Issue #113 asks for a full Floodlight port with React components on GPUI
through `remorses/gpuix`: same search panel, Full Disk Access flow and
clipboard board as the Swift app, over the same Zig core, idling at 45–60 MB
of physical footprint and summoning in under 30 ms. This ADR records the
feasibility gate and the shape of the port. The Swift app is untouched. The
CI Mac's numbers decide whether this moves to accepted.

## Feasibility gate

**Versions.** `@gpuix/react` and `@gpuix/native` 0.11.0, pinned exactly and
together, as GPUIX asks while it is pre-1.0. React 19.2.9. Runtime: **Bun
1.4.4 only** (`frontends/gpuix/.bun-version`, the same Bun the scriptc job
pins). GPUIX also runs on Node and on hermes-node; neither is used:

- Node's V8 heap floor is higher than JavaScriptCore's, and Node has no
  `bun build --compile`, so it would ship a second runtime install.
- hermes-node gives the smallest binary (GPUIX measures 12 MB plus its 22 MB
  addon), but it is a fork with no `bun:ffi`, no `bun test`, and no
  `--smol`. Size is not the goal here; idle footprint is. It is the first
  thing to try if Bun misses the number.

**Window.** GPUIX opens one ordinary titled `GPUIWindow` and has no option for
a panel, a window level, Spaces, or hiding. The platform layer
(`native/flgx_mac.m`) restyles that window after `render()` returns:

- **Non-activating.** GPUI registers `GPUIPanel` (an `NSPanel` subclass) next
  to `GPUIWindow`, with the same single ivar. The layer swaps the window's
  class to `GPUIPanel` and adds `NSWindowStyleMaskNonactivatingPanel`, so the
  panel takes keys and the app the user came from stays active and can take a
  paste. The swap is refused if the two instance sizes ever differ; the panel
  then activates the app on show, as the Swift panel does today.
- Borderless, status level, `canJoinAllSpaces | fullScreenAuxiliary |
  transient`, clear background, shadow.
- **Glass.** On macOS 26 a clear `NSGlassEffectView` (corner radius 30)
  goes under GPUI's Metal view, in the place GPUI puts its own blurred
  backdrop. Before macOS 26 it is an `NSVisualEffectView`. With Reduce
  Transparency there is no material and React paints a solid surface.
- **No stretched frames.** GPUI's layer has `contentsGravity = top`, so a
  frame drawn at the old size is cropped from the top until the next lands.

**Hotkeys and wake-up.** ⌥Space and ⌥⇧C through Carbon
`RegisterEventHotKey`. GPUIX's frame loop falls back to one `tick()` every
100 ms when no frame is due, and a Carbon event waits in the queue until
AppKit is pumped, so a hidden panel would answer the hotkey up to 100 ms late.
While hidden, the app therefore pumps AppKit itself (`flg_wait`, 500 ms
timeout): the hotkey returns it at once, and the timeout doubles as the 0.5 s
pasteboard poll. While shown, GPUIX pumps and the app reads queued events
every 33 ms.

**Summon path.** Hiding resets React to the empty search bar *before* the
window leaves the screen (alpha 0 at once, `orderOut` 50 ms later), so the
frame left in the window is the right one. A summon is then only
`setFrame` + `orderFront` + `makeKey`, with no React work in front of it.

**Measurements.** Not taken yet: this was written in a Linux container with no
Mac. `make measure-gpuix` in the new `gpuix` CI job takes them on the CI Mac:

| | what | from |
|---|---|---|
| floor | idle footprint of the empty panel 10 s after hide; JS heap | `--bench-empty` |
| app | summon p50/p95, query p50/p95 | `--bench`, through the hotkey handler |
| app | idle footprint, resident, JS heap 10 s after hide | `--bench` |
| size | executable, platform library, GPUIX renderer addon, `.app` | `du` |

Summons go through the same handler a Carbon hotkey reaches; a runner cannot
post a real key press without Accessibility.

## Shape

- **Domain in plain TypeScript** (`src/domain/`), no React, GPUI or native
  imports: Search Session, matcher port, app catalog, calculator, keyword
  engines, System Settings rows, clipboard classification, capture policy,
  board state, the panel's keys, metrics. Ported from the scriptc frontend
  (#126, #132), which already passes the parity fixtures.
- **One native library, loaded with `bun:ffi`**, not a Node-API addon: the
  scriptc frontend's C shims (index through the core's C ABI, SQLite on the
  Swift `clipboard_entries` schema, pasteboard, paste delivery, TCC probe)
  plus the window layer above, linked with `libfloodlight_core.a`. `bun:ffi`
  compiles each binding to a direct call, so a keystroke's search crosses no
  Node-API marshalling, and every call takes borrowed buffers, so nothing
  native is copied onto the JS heap. Image bytes stay in SQLite.
- **React components** (`src/ui/`): search bar, filter chips, result row,
  board list, inspector, footer, actions menu, guidance panel. Sizes come from
  `domain/metrics.ts`, the Swift `FloodlightMetrics`. Only the seven visible
  rows are ever mounted, so a keystroke commits seven rows of mutations
  however long the list is.
- **One window, four surfaces**: search, board, guidance, hidden. The
  guidance panel reuses the window under System Settings; a native view over
  the app icon is the drag source for the Full Disk Access list.
- **Icons** are 96 px PNGs drawn once by `NSWorkspace` into the cache folder,
  one per extension for files. `<img>` loads them on GPUI's background task,
  so neither bytes nor data URLs sit on the JS heap.
- **Hiding releases memory**: rows, entries, menu, icon map and the grown
  SQLite read buffer are dropped and the tree unmounts them; one second later
  (so a quick re-summon does no GC) `Bun.gc(true)` and
  `malloc_zone_pressure_relief`. The compiled binary runs with `--smol`.
- **Own bundle and data**: `com.floodlight.gpuix`, `~/Library/Application
  Support/com.floodlight.gpuix`, `LSUIElement`.

## Tests

`make test-gpuix`: typecheck, then `bun test` — the shared parity fixtures
(search over a real Zig index, panel key paths for every mode exit, capture
policy, board keys), the panel's keys and row text, the controller over the
platform stub (what hiding drops, surface switching, board keys against real
SQLite), and on macOS the React tree on GPUIX's headless renderer. GPUIX's
test renderer does not exist on Linux, so that file skips there.

## Known gaps

- **Unverified on a Mac** at the time of writing: the class swap, the glass
  placement, and the drag source. The CI job runs the code paths; a person
  still has to look at the panel and record it with `screencapture -v`.
- GPUIX has no call to release GPUI's image textures. Unmounting is all the
  app can do; the idle number will say whether that is enough.
- Backspace on an empty field may be consumed by GPUI's input before
  `onKeyDown`; Esc and Shift-Tab still leave web mode.
- Quick Look runs `qlmanage -p` rather than an in-process `QLPreviewPanel`.
- Assistant engines are left out, as in the scriptc port.

## Decision rule

Accepted, with this frontend kept beside the Swift app, if on the CI Mac the
app's idle footprint is at most 60 MB and summon p95 is under 30 ms. If the
empty floor alone is over 60 MB, try hermes-node before giving up. If either
still misses, the numbers go in this file and the directory is deleted.
