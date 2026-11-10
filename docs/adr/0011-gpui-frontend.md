---
status: proposed
date: 2026-11-02
---

# A GPUI frontend in `frontends/gpui/`, beside the Swift app

Issue #109 asks for a Rust frontend on Zed's GPUI with a resident floor near 20 MB and a panel that opens in under 10 ms. This ADR records the first slice: a panel that searches apps and files, built in `frontends/gpui/`, measured on the CI Mac. The Swift app in `Sources/` is untouched and stays the product. Whether GPUI replaces it is decided by the numbers this slice produces, not by this ADR.

## Why a second frontend, not a rewrite

ADR 0010 declined a UI rewrite because the Swift shell carries QuickLook, accessibility, onboarding, and a tested coordinator. That still holds. What it did not have was a measured floor for the alternative. #109 claims GPUI can hold ~20 MB idle; nobody has checked. A separate directory with its own build, gates, and CI job gets that number without putting the shipping app at risk, and can be deleted in one commit if the number is bad.

## Shape

- **GPUI pinned by git rev.** `gpui` and `gpui_platform` come from `zed-industries/zed` at the v0.233.10 tag's commit, `350f33871e84d5ed83a403523e9490b9bf014a94`. Zed's own `[patch.crates-io]` for `async-task` is repeated in our workspace, because a git dependency does not inherit its parent's patches. The toolchain is pinned to Zed's (`rust-toolchain.toml`, 1.94.1).
- **Shaders compile at launch** (`runtime_shaders`). The precompiled path runs `xcrun metal`, which Xcode 26 and later ship as a separate download. Runtime compilation costs launch time, once, before the panel is ever shown, so it does not touch hotkey latency.
- **Files through the Zig core.** `floodlight_search` links `libfloodlight_core.a` (built by `make gpui-core` with the pinned Zig) through a hand-written extern block for `core/include/floodlight_core.h`. bindgen would add libclang to every build for seven functions. The index lives at `~/Library/Caches/Floodlight/gpui-files.flix` and covers the home folder. The last index opens at once; a fresh scan replaces it in the background.
- **Apps by folder scan.** `.app` bundles under `/Applications`, `~/Applications`, and `/System/Applications`, two levels deep. They rank with a Rust port of `core/src/match.zig`. The core's C ABI only searches its own index file, and scoring a few hundred names in-process is cheaper than writing them to one. The port carries the Zig tests case for case.
- **Panel.** A borderless `WindowKind::PopUp` (a non-activating NSPanel), so showing it never steals activation from the app the user was in. The process runs as an accessory app: no Dock icon, no menu bar. Arrows move the selection, Enter opens through NSWorkspace, ⌘Enter reveals in Finder, Esc hides.
- **Hotkey ⌥Space** through Carbon `RegisterEventHotKey`, the only system-wide hotkey API that needs no accessibility permission. ⌘Space stays Spotlight's.
- **Hiding drops per-query state.** The query and rows are replaced with fresh empty values. The window goes transparent, draws two empty frames so GPUI's two-frame line-layout cache holds nothing, then orders out, and `malloc_zone_pressure_relief` returns the freed pages. The glyph atlas is kept: GPUI exposes no way to clear it, and it is what makes the next show fast.

## How it is measured

`make bench-gpui` runs the release binary twice on the CI Mac:

- `--bench-empty`: a blank GPUI window shown and hidden through the hotkey handler, then idle for 10 s. This is GPUI's floor, before any of Floodlight.
- `--bench`: the real panel over the runner's home folder. It is shown 23 times through the hotkey handler (3 warm-up), typed into, and hidden. Then it runs a fixed query set through the same search path keystrokes use, idles hidden for 10 s, and samples `resident_size` and `phys_footprint` from `TASK_VM_INFO`.

Hotkey latency starts when the Carbon handler runs. A CI runner cannot post a real key press without the accessibility permission. So the bench sends a `kEventHotKeyPressed` event to the same handler, and the time from the HID event to that handler is not counted. Two end points are reported: the frame built (the panel's `render`), and the next vsync after it (an upper bound on "on screen").

## Known gaps

- No icons yet, so there are no image caches to drop. Icons are where #109's downsampling and eviction work starts.
- No FSEvents. A launch is the refresh, as in ADR 0010.
- Typing goes through raw key events, not an input handler, so there is no IME composition and no ⌘V into the query.
- Out of scope for this slice: the clipboard board, the inspector, settings, and onboarding.

## Decision rule

This moves to accepted, with a plan to port the clipboard board, if the full panel's idle `phys_footprint` stays within #109's 25 MB and hotkey-to-frame stays under 10 ms on the CI Mac. If either misses, the numbers go in this file and the directory is deleted.
