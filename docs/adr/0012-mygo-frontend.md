---
status: proposed
date: 2026-11-02
---

# A Floodlight frontend in Go and MyGo's native UI

Issue #112 asks for Floodlight's frontend in Go, drawn by MyGo's native UI, idling at 24 MB or less and summoning in under 15 ms. This ADR started as a trial built to answer that with numbers and now records the full port: search panel, Full Disk Access grant flow and clipboard board. It lives in `frontends/mygo/`. It does not touch `Sources/`, and nothing in the Swift app depends on it.

## What MyGo is

`github.com/egoist/mygo` (v0.7.4, released 2026-11-01, MIT). It is maintained: 75 tagged releases. Its `ui` package draws native UI itself, on Metal on macOS, with no webview, HTML, or JavaScript. It reaches AppKit, Metal, and Carbon through `purego` (`dlopen`) instead of cgo. It already has the parts a launcher needs: non-activating `NSPanel`s, show and hide, keyboard input with input methods, virtualized lists, and a headless `ui.Tester`.

One caveat: MyGo `dlopen`s `WebKit.framework` at startup, since a window may host a page. That maps shared-cache pages, but creates no web view and starts no WebKit process.

## Shape

The trial grew into the full port #112 specifies. [Go frontend (MyGo)](../../docs/src/content/docs/development/mygo-port.md) is the guide; this records the decisions.

- **One binary**, `floodlight-mygo`, built with cgo, wrapped on macOS in `Floodlight MyGo.app` (`com.floodlight.mygo`), with its own data folder. Three things need cgo: the core, the clipboard store's system SQLite, and the platform layer.
- **File search** goes through `core/` (ADR 0010) via cgo against `libfloodlight_core.a`. The index lives in the data folder. It opens at launch, rebuilds on a goroutine after launch and after a Full Disk Access grant, and the new mapping replaces the old one on the engine goroutine.
- **One search goroutine** (`internal/search`) owns the index handle and the app list and makes every core call. A one-slot channel holds the waiting query, so the latest query wins; a result that finishes after a newer `Submit` is dropped. Each query publishes one immutable list (ADR 0002): recognizer rows (typed address, keyword engine, calculator, unit conversion), then apps, settings and files on the core's score scale (apps +60, settings +30), at most 80 rows with the Google row last. Chip counts come from the same list.
- **Apps and settings** are scored by a Go port of the core's matcher (`internal/match`), so an app and a file that match equally differ only by the app bonus.
- **Search modes** follow the Swift `SearchMode`: Tab enters web mode with the keyword engines (ADR 0006), Esc, Shift-Tab and Backspace on an empty field leave it, and Tab on `clip` opens the clipboard board.
- **Clipboard** (`internal/clipboard`): a 0.5 s capture goroutine; ADR 0009's classification; SQLite in WAL mode on the Swift `clipboard_entries` schema, trigram FTS table and triggers (ADR 0008), so either app can read the other's history; in-memory fallback. The board's keys are one table, read by the view and by the parity fixtures.
- **Full Disk Access** (`internal/permission`): the Swift coordinator's flow as a state machine over injected effects, and a MyGo guidance window whose app card is a MyGo drag source for the bundle.
- **Platform layer** (`internal/platform`): every AppKit, Carbon, CoreGraphics, ImageIO and Quick Look call, in one Objective-C file behind Go functions, with stubs elsewhere. Domain packages never import it.
- **Window:** MyGo's non-activating panel, set to status level on every Space and over full-screen apps. Its layer's `contentsGravity` is pinned to the visual top, and a resize keeps the top edge and asks for a frame at the new size at once.
- **Glass:** MyGo installs `NSGlassEffectView` itself for `VibrancyGlassClear` and exposes no host view behind its Metal view, so Floodlight uses MyGo's glass rather than its own. Reduce Transparency switches to a solid theme background.
- **Hot keys:** ⌥Space and ⌥⇧C through Carbon's `RegisterEventHotKey` via cgo. The handler skips hot keys with any other signature, so it coexists with MyGo's own.
- **Memory:** `debug.SetMemoryLimit(25 MiB)`. Hiding drops rows, icons, list state, the app list and decoded images, then calls `debug.FreeOSMemory()` and `malloc_zone_pressure_relief`. The index stays mapped; its pages are clean and file-backed.
- **First summon:** at launch the panel draws one frame off screen, so fonts, glyphs and the Metal pipeline are built before the first ⌥Space instead of by it.

Not ported: the Swift app's learning boost, recents, folder navigation and assistant engines.
## Measured

`make measure-mygo` on the `xcode-27` CI runner runs two programs:

1. `cmd/emptywindow`: the smallest MyGo app shaped like the launcher. It shows an empty panel, waits for its first frame, hides it, frees the heap, and idles 10 s.
2. `floodlight-mygo -measure`: the whole app, board and guidance windows and the clipboard capture loop included, over the home-folder index, with a temporary data folder. It summons the panel once cold and 10 times warm, timing each from the hot key to the first painted frame. It runs 10 queries 5 times each through the same `Submit` the text field uses. Then it hides, idles 10 s, and reads `task_info(TASK_VM_INFO)` for resident size and `phys_footprint`.

The hot key is pressed with a synthesized ⌥Space through the HID event tap where the runner allows it (`hotkey_path: carbon`). Otherwise the run calls the hot key's own handler on the main thread (`hotkey_path: handler`), which skips only the Carbon dispatch.

First run, 2026-11-02, `xcode-27` runner, MyGo v0.7.4, Go 1.27.3:

| measure | empty window | launcher |
|---|---|---|
| phys_footprint, idle 10 s after hide | 22.3 MB | 30.7 MB |
| RSS, idle 10 s after hide | 91.6 MB | 114.9 MB |
| Go heap in use, idle | | 4.1 MB |
| ⌥Space → first painted frame (Carbon path), warm p50 / cold | | 15.4 ms / 334 ms |
| query p50 / p95, keystroke → rows on the main thread | | 6.8 ms / 29.7 ms |
| binary, stripped | 9.0 MB | 9.3 MB |

The index covered `/Users/runner`: 374,481 entries, built in 13.4 s.

RSS counts shared, clean pages: AppKit, Metal, the WebKit framework, and the mapped index. phys_footprint is the figure macOS charges the app.

Against #112's targets, MyGo itself fits: the empty window idles at 22.3 MB. The launcher is about 7 MB over 24 MB. Warm summon is at the 15 ms target; the first summon after launch is not.

Each CI run's step summary repeats these measurements. Since the full port it also reports the footprint after launch, and splits the idle footprint into what the Go runtime holds resident (heap in use, heap kept idle, stacks, runtime metadata) and the native rest (AppKit, Metal, MyGo's glyph atlas and textures, SQLite). That split is the breakdown #112 asks for before a footprint fix is chosen. The 2 Nov numbers above predate the off-screen warm frame, which targets the 334 ms first summon.

## Decision to make

Accept this ADR only if the numbers beat the Swift app by enough to pay for a second UI stack. The feature gap that blocked the trial (Quick Look, settings, clipboard, the grant flow) is closed; `fixtures/parity/` is what says so. Otherwise the port stays as a measured data point, and ADR 0010's core goes into the Swift shell alone.

## Gate

`make install-zig install-go && make test-mygo`: gofmt, `go vet`, race-enabled tests (core binding, matcher, app ranking, query recognizers, engine ordering and staleness, clipboard store and capture, the grant flow, the shared parity fixtures, and the panel and board views through `ui.Tester`), stripped release builds, and on macOS the ad-hoc signed app bundle. Everything but the platform layer and the hot keys also builds and tests on Linux. Go is pinned by version and SHA-256 in `scripts/tool-versions.env`, like Zig. The **MyGo frontend** CI job runs the gate, then `scripts/measure-mygo.sh`.
