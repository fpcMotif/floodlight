---
status: proposed
date: 2026-11-02
---

# A trial launcher frontend in Go and MyGo's native UI

Issue #112 asks whether Floodlight's frontend could move to Go, drawn by MyGo's native UI, to get the idle memory floor near 20 MB and summon time under 15 ms. This ADR records a trial built to answer that with numbers. The trial lives in `frontends/mygo/`. It does not touch `Sources/`, and nothing in the Swift app depends on it.

## What MyGo is

`github.com/egoist/mygo` (v0.7.4, released 2026-11-01, MIT). It is maintained: 75 tagged releases. Its `ui` package draws native UI itself, on Metal on macOS, with no webview, HTML, or JavaScript. It reaches AppKit, Metal, and Carbon through `purego` (`dlopen`) instead of cgo. It already has the parts a launcher needs: non-activating `NSPanel`s, show and hide, keyboard input with input methods, virtualized lists, and a headless `ui.Tester`.

One caveat: MyGo `dlopen`s `WebKit.framework` at startup, since a window may host a page. That maps shared-cache pages, but creates no web view and starts no WebKit process.

## Shape

- **One binary**, `floodlight-mygo`, built with cgo. Two things need cgo: the core and the hot key.
- **File search** goes through `core/` (ADR 0010) via cgo against `libfloodlight_core.a` and `floodlight_core.h`. The index covers the home folder, or `FLOODLIGHT_MYGO_ROOT`. At startup the app opens the last index at once, rebuilds it on a goroutine, and swaps the new one in. There is no fsearch daemon.
- **One search goroutine** (`internal/search`) owns the index handle and the app list and makes every cgo call. The UI calls `Submit` per keystroke. Only the newest query counts: a waiting query is replaced in a one-slot channel, and a result that finishes after a newer `Submit` is dropped. A C search can't be interrupted, so the engine checks for staleness before and after the C call. Index swaps run on the same goroutine, so no search ever reads an unmapped index.
- **App search** scans `/Applications`, `~/Applications`, and `/System/Applications`, one folder deep, on every show. It ranks prefix, then word start, then substring, then letters in order.
- **Panel:** query field and results. ↑/↓ choose, ↵ opens, ⌘↵ reveals in Finder, Esc hides.
- **Hot key:** ⌥Space through Carbon's `RegisterEventHotKey`, called via cgo (`internal/hotkey`). It needs no Accessibility permission. Our handler skips hot keys with any other signature, so it coexists with MyGo's own handler.
- **Memory:** `debug.SetMemoryLimit(25 MiB)` at start. On every hide the panel drops its query, rows, and list state, the engine drops the app list, and then `debug.FreeOSMemory()` returns the freed pages to macOS. The index stays mapped. Its pages are clean and file-backed, so the system can evict them.

Out of scope: clipboard, inspector, settings, QuickLook, accessibility parity with the Swift app.

## Measured

`make measure-mygo` on the `xcode-27` CI runner runs two programs:

1. `cmd/emptywindow`: the smallest MyGo app shaped like the launcher. It shows an empty panel, waits for its first frame, hides it, frees the heap, and idles 10 s.
2. `floodlight-mygo -measure`: the real panel, home-folder index included. It summons the panel once cold and 10 times warm, timing each from the hot key to the first painted frame. It runs 10 queries 5 times each through the same `Submit` the text field uses. Then it hides, idles 10 s, and reads `task_info(TASK_VM_INFO)` for resident size and `phys_footprint`.

The hot key is pressed with a synthesized ⌥Space through the HID event tap where the runner allows it (`hotkey_path: carbon`). Otherwise the run calls the hot key's own handler on the main thread (`hotkey_path: handler`), which skips only the Carbon dispatch.

Numbers are in the PR that adds this ADR and in each CI run's step summary.

## Decision to make

Accept this ADR only if the numbers beat the Swift app by enough to pay for a second UI stack, and the feature gap (QuickLook, accessibility, settings, clipboard) has a plan. Otherwise the trial stays as a measured data point, and ADR 0010's core goes into the Swift shell alone.

## Gate

`make install-zig install-go && make test-mygo`: gofmt, `go vet`, race-enabled tests (core binding, app ranking, engine ordering and staleness, and the panel view through `ui.Tester`), and stripped release builds. Go is pinned by version and SHA-256 in `scripts/tool-versions.env`, like Zig. The **MyGo frontend** CI job runs the gate, then `scripts/measure-mygo.sh`.
