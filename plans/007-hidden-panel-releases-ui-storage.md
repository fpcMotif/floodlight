# Plan 007: A hidden panel releases the UI library's frame storage and text caches

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- frontends/nanoui/src/mac.zig frontends/nanoui/src/main.zig frontends/nanoui/src/tests.zig`
> **Extra check for this plan**: these files had uncommitted changes when
> this plan was written, and the excerpts come from that working tree. Line
> numbers can be off. Find each excerpt with `rg` by its text.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/006-nanoui-benchmarks-cover-real-paths.md`
- **Category**: perf
- **Planned at**: commit `64cc313` plus uncommitted working-tree changes, 2026-11-17

## Why this matters

`frontends/nanoui` is the Zig frontend of Floodlight, a macOS launcher. It
sits hidden in the background most of the day. Its hidden footprint is
46–63 MB, above the repo's own 60 MB budget.

When the panel hides and Session Retention expires, the app calls
`releaseIdleMemory`. That frees the image atlas and the frame buffers. It
does not free the storage the UI library (nanoui 0.9.2) pre-sizes for every
window, nor its cached text layouts. Allocation logging on 2026-11-17 showed
these still allocated while hidden:

| Bytes | Allocations | Allocation site |
|---|---|---|
| 7.3 MB | 20 | `ui.context.Context.begin` (inlined `warmMaps`) |
| 1.1 MB | 2 | hash map of `ui.text_mac.Layout` |
| 1.0 MB | 1 | `ui.paint.paint` instance list |
| 0.85 MB | 4 | hash map of `ui.types.Rect` |
| 0.8 MB | 2 | hash map of `ui.motion.Entry` |

That is 11 MB of about 23 MB of hidden heap. The app has two windows (the
panel and the Full Disk Access guide), and each pre-sizes its own copy.

After this plan, expiry frees that storage, and the hidden footprint drops
by roughly 10 MB.

## Current state

Files:

- `frontends/nanoui/src/mac.zig` — Cocoa adapter. Holds `releaseSurface`.
- `frontends/nanoui/src/main.zig` — app shell. Holds `releaseIdleMemory`.
- `frontends/nanoui/zig-pkg/nanoui-0.9.2-*/src/ui/` — the vendored UI
  library. **Read only. It is a fetched dependency in a git-ignored folder.**

The release path today (`main.zig`):

```zig
    fn releaseIdleMemory(s: *Shell) void {
        s.panel.forgetPresented();
        mac.releaseSurface(s.panel_window);
        if (!s.guide_window.isVisible()) mac.releaseSurface(s.guide_window);
        var it = s.icons.iterator();
        while (it.next()) |e| gpa.free(e.value_ptr.*);
        s.icons.clearRetainingCapacity();
        mac.releaseFreedMemory();
    }
```

What `releaseSurface` frees (`mac.zig`). Note that it already reaches into
the library's `Surface` fields; that is the established pattern:

```zig
pub fn releaseSurface(window: *nanoui.Window) void {
    const s = window.surface orelse return;
    if (s.released or s.is_visible) return;
    s.pending = true;
    s.released = true;
    s.renderer.resize(.{ .w = 1, .h = 1 }, s.scale);
    s.text.images.trimDecoded();
    s.renderer.waitIdle();
    forgetImageAtlas(s);
    forgetFrameBuffers(s);
    _ = s.ctx.arena.reset(.{ .retain_with_limit = 64 * 1024 });
}

fn forgetFrameBuffers(s: *nanoui.Surface) void {
    s.instances.clearAndFree(s.gpa);
    ...
```

The early return `if (s.released or s.is_visible) return;` matters. The
library sets `released = true` itself when the window is occluded
(`surface.zig`, `occlusionChanged`), so on the normal hide path
`releaseSurface` can return before it frees anything:

```zig
        if (was and !self.is_visible) {
            self.pending = true;
            self.released = true;
            self.renderer.resize(.{ .w = 1, .h = 1 }, self.scale);
            self.text.images.trimDecoded();
            _ = self.ctx.arena.reset(.{ .retain_with_limit = 64 * 1024 });
```

Confirm this in step 1 before relying on it.

What the library pre-sizes on a window's first frame (`context.zig`):

```zig
    fn warmMaps(c: *Context) void {
        c.nodes.ensureTotalCapacity(c.gpa, 4096) catch {};
        c.stack.ensureTotalCapacity(c.gpa, 128) catch {};
        c.rects.ensureTotalCapacity(c.gpa, 4096) catch {};
        c.prev_rects.ensureTotalCapacity(c.gpa, 4096) catch {};
        c.hits.ensureTotalCapacity(c.gpa, 1024) catch {};
        c.next_hits.ensureTotalCapacity(c.gpa, 1024) catch {};
        c.a11y_items.ensureTotalCapacity(c.gpa, 1024) catch {};
        c.helps.ensureTotalCapacity(c.gpa, 1024) catch {};
        c.motion.entries.ensureTotalCapacity(c.gpa, 4096) catch {};
        c.anims.ensureTotalCapacity(c.gpa, 512) catch {};
        ...
```

It runs only under this guard (`context.zig`, `begin`), so freed lists grow
back on demand and are not pre-sized again:

```zig
        if (c.frame == 0 and c.nodes.capacity == 0) c.warmMaps();
```

The text system keeps `layouts`, `previous` and `wraps`
(`text_mac.zig`). One existing function frees all three; find it with
`rg -n 'freeLayouts\(self.gpa, &self.previous\)' -B 12 frontends/nanoui/zig-pkg/*/src/ui/text_mac.zig`.
It also drops fonts and resets the glyph atlas.

App allocator (`main.zig`):

```zig
const gpa = std.heap.smp_allocator;
```

`mac.releaseFreedMemory` calls `malloc_zone_pressure_relief`, which reaches
only the system malloc zones. Zig's `smp_allocator` keeps freed blocks of
32 KiB or less on its own free lists, so app-side frees of small blocks
never return to macOS. The library itself uses the C allocator.

Design record `docs/adr/0015-session-retention.md`, rule 7: "At expiry, a
shell timer runs `Panel.expire()`, clears the icon cache, and returns freed
pages to macOS." This plan makes the code match that rule.

Conventions: comments say why, never what. Domain terms from `CONTEXT.md`:
**Session Retention**, **Search Session**.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format, tests, bench, bundle | `make test-nanoui` | exit 0 |
| Memory benchmark | `make bench-nanoui-memory` | `FLOODLIGHT_MEMORY` lines |

To attribute hidden heap by allocation site, start the bundle's binary in a
scratch home with `MallocStackLogging=lite` and the flag
`--floodlight-memory-session -sessionRetentionSeconds 0`, wait for the line
`FLOODLIGHT_MEMORY phase=idle cycle=3` in its output, then run
`heap -s <pid>`. The rows named `malloc in ui.context...` are the library's.
Seed the scratch home first with `--floodlight-memory-seed`, as
`scripts/bench-nanoui-memory.sh` does.

## Scope

**In scope**:

- `frontends/nanoui/src/mac.zig` (`releaseSurface` and new helpers beside
  `forgetFrameBuffers`)
- `frontends/nanoui/src/main.zig` (`releaseIdleMemory`, the `gpa` constant)
- `frontends/nanoui/src/tests.zig` (new tests)

**Out of scope**:

- Anything under `frontends/nanoui/zig-pkg/`. Never edit the vendored
  library.
- `build.zig.zon` and the nanoui version.
- `Panel.expire`, the retention timer, and `docs/adr/0015-session-retention.md`.
- The 5-minute retention default. Memory held during the window is a
  recorded decision.

## Git workflow

- Branch: `advisor/007-hidden-panel-releases-ui-storage`.
- Commit style: `perf(nanoui): a hidden panel frees the frame storage`.
- Do not push or open a PR unless the operator asks.

## Steps

### Step 1: Record the baseline and confirm the early return

Run `make bench-nanoui-memory` and save the three `phase=idle` lines and the
`phase=expired` line. Run the `heap -s` procedure above and save the top 12
rows. Then confirm, by reading `releaseSurface` and `occlusionChanged`,
whether `s.released` is already true when `releaseIdleMemory` runs after a
normal hide.

**Verify**: your notes hold four footprint numbers and a yes or no on the
early return.

### Step 2: Free the frame buffers even when the library already released

In `releaseSurface`, keep the `is_visible` guard, but do not let
`s.released == true` skip `forgetImageAtlas`, `forgetFrameBuffers`, and the
helper from step 3. Only the `renderer.resize` to 1×1 may be skipped when
the library already did it. Keep `s.renderer.waitIdle()` before releasing
any GPU object.

**Verify**: `make test-nanoui` → exit 0.

### Step 3: Free the pre-sized frame storage

Add `fn forgetFrameStorage(s: *nanoui.Surface) void` beside
`forgetFrameBuffers`. For the context `s.ctx`, call `clearAndFree(c.gpa)` on
each list and map that `warmMaps` pre-sizes: `nodes`, `stack`, `rects`,
`prev_rects`, `hits`, `next_hits`, `a11y_items`, `helps`, `motion.entries`,
`anims`. Read `context.zig` for the exact type of each: an `ArrayList` uses
`clearAndFree`, a hash map uses `clearAndFree` too, and a field that is
neither must be left alone. Do not touch `scroll`, `scroll_x`, `overscroll`,
`scrollbars`, `edits` or `focus`: they hold state the user expects back.

Call it from `releaseSurface` after `forgetFrameBuffers`.

**Verify**: `make test-nanoui` → exit 0, and the test from the test plan
passes.

### Step 4: Free cached text layouts

In the same helper, free the text system's layouts and wraps. Prefer the
library's own function found in "Current state" if it is `pub` and if it
keeps the font tables usable for the next frame. If it is not `pub`, free
`s.text.layouts`, `s.text.previous` and `s.text.wraps` directly, using the
same calls that function uses. Do not release fonts by hand.

**Verify**: `make test-nanoui` → exit 0. The snapshot step at the end of
`make test-nanoui` still writes `.build/nanoui-panel.png`.

### Step 5: Let app-side frees return to macOS

In `main.zig` change `const gpa = std.heap.smp_allocator;` to
`std.heap.c_allocator`. Check `build.zig`: the app module must link libc
(`linkSystem(app)` links system frameworks; confirm `link_libc` is on or
add it in `linkSystem`). If `build.zig` needs a change, STOP: it is out of
scope and needs the operator's approval.

**Verify**: `make test-nanoui` → exit 0, and the three original
`FLOODLIGHT_BENCH` p99 values stay under 10 µs.

### Step 6: Measure

Run `make bench-nanoui-memory` three times and the `heap -s` procedure once.

**Verify**: the median `phase=idle cycle=3` footprint is at least 6 MB below
the step 1 baseline, and no `heap -s` row for `ui.context.Context.begin`
exceeds 1 MB.

## Test plan

Add to `tests.zig`, modeled on the tests that use `ui.Tester` (for example
`BoardFixture`):

- "a released surface draws the same frame again": build a frame with a
  populated result list, call the new storage release on the tester's
  context, build the frame again, and expect the same text to be present
  (`tester.hasText`). If the tester exposes no `Surface`, test the helper
  that takes a `*ui.Context` instead and split `forgetFrameStorage` so its
  context part is callable with one.
- "scroll position survives a release": scroll a list, release, build a
  frame, and expect the scroll offset unchanged.

Verification: `make test-nanoui` → all pass, including 2 new tests.

## Done criteria

- [ ] `make test-nanoui` exits 0.
- [ ] Median `phase=idle cycle=3` footprint is at least 6 MB lower than the
      baseline recorded in step 1.
- [ ] `heap -s` shows no `ui.context.Context.begin` row above 1 MB while
      hidden.
- [ ] `git status --short frontends/nanoui/zig-pkg` prints nothing.
- [ ] `git status --short` lists only in-scope files.
- [ ] `hotkey_to_built_frame` p99 (from plan 006) rose by less than 2x.
      Report both values.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Plan 006 has not landed (`rg -n 'hotkey_to_built_frame' frontends/nanoui/src/bench.zig`
  finds nothing).
- A field named in step 3 does not exist in `context.zig`, or freeing it
  makes any existing test fail twice.
- Freeing layouts crashes or leaves text blank on the next frame.
- Step 5 needs a `build.zig` change.
- The footprint drops by less than 3 MB after steps 2–5. Report the
  `heap -s` output; the remaining memory is somewhere this plan did not
  expect.

## Maintenance notes

- This plan reaches into nanoui's `Surface` and `Context` fields. A nanoui
  upgrade can rename them. The right long-term home is a `trim()` function
  in nanoui itself; propose it upstream.
- The first frame after expiry now re-grows these lists. Plan 006's
  `hotkey_to_built_frame` is the gate for that cost.
- Deferred: the two glyph atlas textures (4 MiB each at creation) and the
  12 MB of IOSurface and IOAccelerator memory that stays while hidden. Both
  need a look at how the Metal layer drops its drawables.
- Deferred: ColorSync keeps about 4 MB of colour tables after image decode.
  That is system memory and needs its own investigation.
