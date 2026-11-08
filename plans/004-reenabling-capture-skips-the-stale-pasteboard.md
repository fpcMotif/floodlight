# Plan 004: Turning clipboard capture back on does not record what was copied while it was off

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 64cc313..HEAD -- Sources/Floodlight/Search/ClipboardCaptureService.swift Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`
> Plans 001 and 003 also edit `ClipboardCaptureService.swift`. If either has
> landed, line numbers will differ, but the `poll()` excerpt below must still
> match by text. On a text mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (run after plans 001 and 003 if they are scheduled,
  because all three edit the same file)
- **Category**: bug (privacy)
- **Planned at**: commit `64cc313`, 2026-11-10

## Why this matters

The Swift app records clipboard history and lets the user switch recording off
in settings. The obvious use is: switch it off, copy something private, switch
it back on. Today that private copy is recorded the moment recording is
switched back on, because the service stopped tracking the pasteboard's change
counter while disabled and sees the old copy as new.

After this plan, copies made while capture is disabled are never recorded.

## Current state

Files:

- `Sources/Floodlight/Search/ClipboardCaptureService.swift` — `@MainActor`
  class that polls the pasteboard every 0.5 s.
- `Sources/Floodlight/App/OnboardingSession.swift` — settings model (read
  only for this plan). Its toggle writes the UserDefaults key directly:
  `defaults.set(newValue, forKey: ClipboardCaptureService.enabledDefaultsKey)`.
  It never calls the service.
- `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift` — the tests.

The start of `poll()` (`ClipboardCaptureService.swift:222-228`):

```swift
    func poll() {
        guard isEnabled, !isPaused else { return }

        // Rule 1: changeCount unchanged -> zero work
        let currentChangeCount = observer.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
```

Because the `isEnabled` guard returns first, `lastChangeCount` freezes at its
value from before capture was disabled. When the default flips back to true,
the next poll sees a different change count and records the current
pasteboard.

The service has a setter that would re-baseline
(`ClipboardCaptureService.swift:139-152`), but nothing in `Sources/` calls it:

```swift
    var isEnabled: Bool {
        get {
            if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: Self.enabledDefaultsKey)
            if newValue {
                lastChangeCount = observer.changeCount
            }
        }
    }
```

The paused case is already correct, because `resume()` re-baselines
(`ClipboardCaptureService.swift:217-220`):

```swift
    func resume() {
        isPaused = false
        lastChangeCount = observer.changeCount
    }
```

Test harness facts (`ClipboardCaptureServiceTests.swift`):

- `makeHarness()` returns `service`, `store`, `observer`, `exclusions`. The
  service and the exclusion store share one private `UserDefaults` suite, but
  the harness does not expose it.
- `harness.observer.setContents(string:)` puts text on the fake pasteboard and
  bumps its change count.
- The existing test `sessionResignPausesAndResumeReBaselinesChangeCount` is the
  structural pattern for this plan's tests.

Repo conventions that apply (from `CLAUDE.md`):

- A comment says **why**, never what the next line does. Existing comments
  such as `// Rule 1: ...` stay as written; do not reword or delete them.
- Never hand-format Swift; run `make format`.
- `.swiftlint.yml` thresholds are a ratchet. Do not raise one.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `swift test --filter ClipboardCaptureServiceTests` | all pass |
| Format | `make format` | exit 0 |
| Gates | `make check` | exit 0 |
| Tests | `make test` | exit 0 |

## Scope

**In scope** (the only files you should modify):

- `Sources/Floodlight/Search/ClipboardCaptureService.swift`
- `Tests/FloodlightTests/ClipboardCaptureServiceTests.swift`

**Out of scope** (do NOT touch):

- `Sources/Floodlight/App/OnboardingSession.swift` — do not reroute the toggle
  through the service. The fix in `poll()` makes the service correct no matter
  who writes the default.
- The `isEnabled` setter. Leave it as is.
- `frontends/nanoui/**`.
- When capture starts relative to onboarding (`AppDelegate.swift:49-50`). That
  is a separate, deliberately deferred question.

## Git workflow

- The repository was on a detached `HEAD` with unrelated uncommitted changes.
  Do not stash, reset, or commit those files.
- Branch: `advisor/004-reenable-capture-stale-pasteboard`
- Conventional Commits, for example `fix(clipboard): ...`.
- Stage only the two in-scope files by path. Do NOT push or open a PR.

## Steps

### Step 1: Write the failing tests first

Add the two tests from the Test plan. Run them.

**Verify**: `swift test --filter ClipboardCaptureServiceTests` → test 1 fails
with the store holding one entry; test 2 passes already. If test 1 passes
before the fix, STOP: the bug is not where this plan says it is.

### Step 2: Track the change count before checking whether capture is enabled

In `poll()`, reorder the opening so the change count is always consumed:

```swift
    func poll() {
        // Rule 1: changeCount unchanged -> zero work
        let currentChangeCount = observer.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // A copy made while capture is off or the session is inactive is
        // consumed here, so turning capture back on cannot record it.
        guard isEnabled, !isPaused else { return }
```

Everything after these lines stays unchanged.

**Verify**: `swift test --filter ClipboardCaptureServiceTests` → all pass,
including `sessionResignPausesAndResumeReBaselinesChangeCount`.

### Step 3: Run all gates

**Verify**: `make format && make check && make test` → all exit 0.

## Test plan

Add to `struct ClipboardCaptureServiceTests`, modeled on
`sessionResignPausesAndResumeReBaselinesChangeCount`. Use the service's own
`isEnabled` property to switch capture off. To switch it back on the way the
settings screen does (writing the default without the service), the test needs
the harness's `UserDefaults`: add a `defaults: UserDefaults` field to the
private `Harness` struct and return the suite `makeHarness` already creates.

1. `aCopyMadeWhileCaptureIsDisabledIsNotRecordedWhenItIsReenabled`
   - `harness.service.isEnabled = false`
   - `harness.observer.setContents(string: "copied while off")`,
     `harness.service.poll()` → store is empty
   - `harness.defaults.set(true, forKey: ClipboardCaptureService.enabledDefaultsKey)`
   - `harness.service.poll()` → store is still empty (this is the regression)
   - `harness.observer.setContents(string: "copied after")`,
     `harness.service.poll()` → store count is 1 and the newest text is
     `"copied after"`
2. `disablingCaptureStopsRecording` — disable through
   `harness.defaults.set(false, ...)`, copy, poll, expect an empty store.

The tests file uses `harness.store.isEmpty`, `harness.store.count`, and
`harness.store.mostRecentEntry?.text`; reuse those helpers.

Verification: `make test` → exit 0, including 2 new tests.

## Done criteria

- [ ] `make check` exits 0
- [ ] `make test` exits 0; the 2 new tests exist and pass
- [ ] In `poll()`, the line `lastChangeCount = currentChangeCount` appears
      before the line `guard isEnabled, !isPaused else { return }`
      (`rg -n "lastChangeCount = currentChangeCount|guard isEnabled, !isPaused" Sources/Floodlight/Search/ClipboardCaptureService.swift`
      lists them in that order)
- [ ] `git status --short` shows no modified files outside the in-scope list
      other than files that were already modified before you started
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `poll()` excerpt does not match the live code by text.
- Test 1 passes before the fix is applied.
- An existing test fails after the reorder. Report its name; do not change its
  expectations.
- `make check` fails on a SwiftLint length threshold. Do not raise it.

## Maintenance notes

- The service now reads the pasteboard change count on every poll even while
  disabled. That is one integer read every 0.5 s.
- The `isEnabled` setter's re-baseline is now redundant but harmless. Removing
  it is optional cleanup for a later change.
- Related and deferred: capture starts at launch, before the first-run
  onboarding screen where the user can switch it off
  (`Sources/Floodlight/App/AppDelegate.swift:49-50`). Whether to delay capture
  until onboarding completes is a product decision.
- The Zig frontend (`frontends/nanoui`) was not checked for an equivalent
  toggle.
