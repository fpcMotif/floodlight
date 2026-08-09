---
status: accepted
date: 2026-08-08
---

# Put running-app activation behind RunningApplicationActivating

Selecting an application row used to always call `NSWorkspace.openApplication`, which resolves the target through Launch Services even when the app is already running and only needs to come to front — the dominant case for a launcher, since re-summoning an open app is far more common than a cold launch. `SelectedResultActionPerformer` now tries `RunningApplicationActivating.activateIfRunning(bundleURL:)` first and only falls through to `SelectedResultActionEffects.open(_:asApplication:)` when no running instance is found. ADR 0005 moved this policy out of `SearchCoordinator` without changing the fast-path decision.

The production conformer, `WorkspaceRunningApplicationActivator`, matches the selected bundle URL against `NSWorkspace.shared.runningApplications` — an array AppKit already keeps warm in-process — and calls `NSRunningApplication.activate()` directly, skipping Launch Services entirely for the already-open case. This abstraction exists so the fast path is unit-testable with a scripted fake instead of only being exercisable by actually launching applications in CI.

## Consequences

Switching to an already-open application is now near-instant and independently testable via a scripted `RunningApplicationActivating`. Cold launches are unchanged, still reaching `NSWorkspace.openApplication` through the ADR 0005 effects adapter. Non-application `.open` items (files, folders, web URLs) never consult the activator — there is no OS-level equivalent of "this file is already the frontmost document" to activate against. Scripted performer tests cover fallback ordering and consequences; the thin AppKit integration remains part of the manual smoke matrix.
