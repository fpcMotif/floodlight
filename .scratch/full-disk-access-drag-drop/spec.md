## Problem Statement

Full Disk Access (FDA) is essential for Floodlight to index, search, and navigate files across protected user locations on macOS, including `~/Library`, application containers, local backups, developer caches, and cloud storage folders. Without Full Disk Access, Floodlight operates in a degraded search state where file search candidates from protected directories are silently omitted.

However, Apple's Transparency, Consent, and Control (TCC) subsystem does not provide a standard programmatic permission request API for Full Disk Access. Unlike Camera, Microphone, or Screen Recording—which present an OS-level "Allow / Don't Allow" modal sheet directly to the user—Full Disk Access can only be granted by the user manually enabling the application inside `macOS System Settings > Privacy & Security > Full Disk Access`.

In Floodlight's current onboarding and configuration interface, clicking "Grant access" merely launches System Settings and deep-links to the Full Disk Access preference pane (`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`). This creates severe friction and user confusion:

1. **System Settings often omits Floodlight from the list**: Because Floodlight has not yet been explicitly registered or added, macOS does not automatically show Floodlight in the Full Disk Access table for many users.
2. **Manual addition requires seven tedious steps**: The user must find the tiny `+` button at the bottom of the table, authenticate with Touch ID or administrator credentials, navigate through an `NSOpenPanel` file dialog to `/Applications`, locate `Floodlight.app`, click Open, and confirm the toggle. This multi-step hurdle causes significant onboarding drop-off.
3. **No guidance or context is provided**: Once System Settings opens, Floodlight provides no visual assistance, leaving the user with an empty or unfamiliar settings table without instructions on what to do.
4. **No active observation of permission grant**: The current configuration window does not actively poll or detect when Full Disk Access is granted while System Settings is active. The user must manually switch focus back to Floodlight or restart the app for the status to update from "Grant access" to "Granted".

Modern macOS utility and developer tools (such as Screenflare, Codex computer use onboarding, Raycast, Dropover, and CleanShot X) solve this by implementing a **drag-and-drop permission onboarding flow**. Because macOS System Settings tables natively accept `.app` bundle drops to register privacy privileges, dragging the application icon directly into the System Settings list triggers the system authentication dialog and enables the toggle in a single gesture. Floodlight needs this exact fluid, assisted permission experience.

## Solution

Implement an assisted, drag-and-drop Full Disk Access permission onboarding flow consisting of:

1. **Floating Permission Guidance Overlay (`FullDiskAccessGuidancePanel`)**: When the user clicks "Grant access" in the Onboarding or Settings surface, Floodlight opens macOS System Settings to the Full Disk Access pane and concurrently presents a floating, semi-translucent guidance HUD on screen.
2. **Draggable Application Card**: The guidance overlay (and an inline card within the Onboarding/Settings window) displays a prominent draggable tile containing Floodlight's application icon, display name, and a drag handle affordance (`line.3.horizontal`).
3. **Application Bundle Drag Provider**: The draggable tile provides an `NSPasteboardItem` / `NSItemProvider` carrying `Bundle.main.bundleURL` as a file URL (`kUTTypeFileURL` / `public.file-url`). When the user drags and drops this tile into the Full Disk Access table in System Settings, macOS automatically prompts for Touch ID or administrator authorization, adds Floodlight to the list, and switches Full Disk Access to "Allowed".
4. **Live Authorization Polling & Auto-Dismissal**: While the guidance overlay is active, Floodlight initiates a lightweight background monitor (~500ms ticker) combined with workspace and window focus notifications (`NSApplication.didBecomeActiveNotification`, `NSWorkspace.didActivateApplicationNotification`) evaluating `FloodlightFullDiskAccess.isGranted()`. As soon as access is verified:
   - The guidance overlay transitions to a success state ("Full Disk Access Granted ✓") with checkmark animation and haptic feedback.
   - The overlay automatically dismisses after ~1.5 seconds.
   - The underlying `OnboardingSession` updates its `hasFullDiskAccess` state in real time.
   - The Onboarding or Settings view immediately updates the Full Disk Access row to "Granted" with a checkmark.
5. **Inline Draggable Affordance**: In addition to the floating overlay, the Full Disk Access row inside the Onboarding and Settings surfaces is enhanced with a draggable application badge so users can drag directly from the Floodlight window into System Settings.
6. **Accessible Fallback**: For users unable to drag and drop or running in an environment without standard bundle dragging, clear step-by-step secondary instructions ("Or click + in System Settings and select Floodlight from Applications") are prominently displayed.

## User Stories

### Guidance Overlay and Initiation

1. As a Floodlight user in onboarding, I want clicking "Grant access" on the Full Disk Access row to launch System Settings directly to the Full Disk Access pane, so that I don't have to search through macOS settings categories.
2. As a Floodlight user, I want clicking "Grant access" to present a floating guidance overlay on screen alongside System Settings, so that I have clear instructions on how to complete the authorization.
3. As a Floodlight user, I want the guidance overlay to feature an upward arrow and the text "Drag Floodlight into the Full Disk Access list", so that the target drop area is immediately obvious.
4. As a Floodlight user, I want the guidance overlay to remain floating above other windows while I interact with System Settings, so that it remains visible during the drag gesture.
5. As a Floodlight user, I want the guidance overlay to appear on the same display and near the System Settings window, so that the drag distance is minimal.
6. As a Floodlight user, I want a close button (`✕`) on the guidance overlay and the ability to press Escape, so that I can dismiss the guidance at any time if I do not wish to proceed.
7. As a Floodlight user who dismissed the guidance overlay, I want to be able to click "Grant access" again to re-summon the overlay and retry the flow.

### Drag and Drop Gesture

8. As a Floodlight user, I want the guidance overlay to contain a draggable card showing Floodlight's app icon, name, and a drag handle, so that I intuitively know it can be picked up with the mouse or trackpad.
9. As a Floodlight user, I want to be able to drag the Floodlight card out of the guidance overlay and see an authentic macOS drag snapshot (app icon and name) follow the cursor, so that visual feedback during the drag is clear.
10. As a Floodlight user, I want to drop the dragged card anywhere into the Full Disk Access table in System Settings, so that macOS accepts the application bundle and registers it for the permission.
11. As a Floodlight user dropping the application card into System Settings, I want macOS to trigger the system authentication prompt (Touch ID or password) without requiring me to browse files in Finder.
12. As a Floodlight user, I want an inline draggable card directly in the Onboarding and Settings window's Full Disk Access row, so that I can drag directly from Floodlight's window if I prefer not to use the floating overlay.

### Live Detection and Feedback

13. As a Floodlight user who just completed the drop and Touch ID authorization, I want Floodlight to detect the granted permission within 500ms without requiring any manual "Verify" click, so that the experience feels immediate and modern.
14. As a Floodlight user upon permission grant, I want the guidance overlay to transition to a green checkmark with "Full Disk Access Granted", so that I receive unambiguous confirmation that the action succeeded.
15. As a Floodlight user upon permission grant, I want the guidance overlay to automatically fade out and dismiss after 1.5 seconds, so that I do not need to clean up floating windows manually.
16. As a Floodlight user, I want the Onboarding window's Full Disk Access row to update immediately from "Grant access" to "Granted" with a checkmark as soon as permission is detected, so that the configuration state is always honest.
17. As a Floodlight user going through initial setup, I want the onboarding "Continue" / "Done" button to reflect the new readiness state immediately once Full Disk Access is granted, so that I can smoothly finish setup.
18. As a Floodlight user, I want the background polling ticker to automatically stop as soon as Full Disk Access is confirmed or the guidance overlay is dismissed, so that background CPU and battery consumption remain strictly zero.

### Edge Cases, Accessibility, and Appearance

19. As a Floodlight user who prefers keyboard navigation or cannot drag and drop, I want the guidance overlay to provide a secondary text tip: "Or click + in System Settings and choose Floodlight in Applications", so that I am never blocked by the drag gesture.
20. As a developer running Floodlight from Xcode or a command-line build where `Bundle.main.bundleURL` is not a `.app` bundle, I want the app to detect the development environment and offer appropriate manual instructions rather than attempting to drag an invalid binary.
21. As a Floodlight user running in Light or Dark appearance, I want the guidance overlay to adopt macOS native Liquid Glass translucency and materials, so that it looks like an authentic Apple system accessory.
22. As a Floodlight user who already granted Full Disk Access, I want the row to display "Granted" and a "Revoke…" button that opens System Settings directly without showing the drag-and-drop guidance overlay, so that unnecessary guidance is avoided.
23. As a Floodlight user who closes the main configuration window while the guidance overlay is active, I want the guidance overlay to close automatically, so that orphaned helper windows are never left on the desktop.

## Implementation Decisions

### Full Disk Access Flow Coordinator (`FullDiskAccessGrantCoordinator`)

- **Dedicated Flow State Machine**: Introduce a main-actor observable coordinator that manages the lifecycle of the Full Disk Access grant flow. It maintains the current grant phase:
  ```swift
  enum FullDiskAccessGrantPhase: Equatable, Sendable {
      case idle
      case presentingGuidance(appURL: URL, isPolling: Bool)
      case granted
      case dismissed
  }
  ```
- **Lifecycle & Actions**:
  - `beginGrantFlow()`: Opens System Settings to the Full Disk Access URL (`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`), presents the floating guidance panel, starts the periodic permission polling ticker (~500ms), and observes `NSApplication.didBecomeActiveNotification` and `NSWorkspace.didActivateApplicationNotification`.
  - `poll()`: Probes `FloodlightFullDiskAccess.isGranted()`. When `true`, transitions to `.granted`, schedules automatic panel dismissal after 1.5 seconds, notifies `OnboardingSession.refreshFullDiskAccess()`, and cancels polling.
  - `dismiss()`: Hides the guidance panel, invalidates the polling timer, and transitions to `.dismissed`.
- **Single-Instance Enforcement**: Only one guidance panel can exist at any time. Subsequent invocations while active refocus the existing panel.

### Floating Guidance Window (`FullDiskAccessGuidancePanel`)

- **Window Configuration**:
  - `NSPanel` subclass configured with style mask `[.borderless, .nonactivatingPanel]`.
  - Level set to `.floating` (or `.popUpMenu`) so it floats above normal application and System Settings windows without stealing active keyboard focus from System Settings.
  - Transparent background (`isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`).
  - Positioned dynamically centered on the active screen or aligned to the lower-center of the main display.
  - Automatically cleaned up on app termination or configuration window dismissal.
- **Visual Design & SwiftUI View (`FullDiskAccessGuidanceView`)**:
  - Encased in a rounded visual effect view with continuous curvature (corner radius 18pt), subtle border stroke, and drop shadow.
  - Upper banner: Directional arrow icon (`arrow.up`) and instruction: "Drag Floodlight into the Full Disk Access list", with a subtle close button (`✕`) in the top-right corner.
  - Draggable application pill: A styled container containing Floodlight's app icon (32×32 pt), title ("Floodlight"), and a drag affordance (`line.3.horizontal`).
  - Success transition: When phase transitions to `.granted`, the card smoothly animates to a checkmark icon with "Full Disk Access Granted", playing a standard system feedback sound/haptic.

### Drag & Drop Mechanics (`ApplicationBundleDragSource`)

- **Pasteboard Item Writing**: The draggable tile implements SwiftUI `.draggable(appBundleURL)` or AppKit `NSDraggingSource` vending `NSPasteboardItem` with `NSPasteboard.PasteboardType.fileURL` matching `Bundle.main.bundleURL` (`kUTTypeFileURL`).
- **Drag Image Snapshot**: When dragged, macOS renders an application icon badge under the cursor, conforming to macOS dragging conventions.
- **Drop Acceptance in System Settings**: System Settings `NSTableView` natively recognizes dragged `.app` file URLs. Upon receiving the drop, macOS triggers the authorization prompt, adds the application bundle identifier to TCC, and toggles the switch to allowed.

### Inline Configuration Window Support

- **Inline Draggable Affordance**: Enhance `searchAccessSection` in `OnboardingView.swift` so that when Full Disk Access is not yet granted, the row provides both the "Grant access" button (which opens System Settings and the floating HUD) and an inline draggable application badge, enabling users to drag directly from the Floodlight window without needing the floating overlay.
- **Session State Binding**: `OnboardingSession.refreshFullDiskAccess()` is called immediately whenever `FullDiskAccessGrantCoordinator` observes authorization or when the configuration window regains key window status.

### Fallbacks & Development Handling

- **Bundle Validation**: Check if `Bundle.main.bundleURL.pathExtension == "app"`. If running unbundled (e.g. CLI runner or Xcode preview), the drag item is disabled and clear guidance instructs the user on development testing without crashing or vending invalid URLs.
- **Manual Instructions**: A subtle secondary label ("Or click + in System Settings and select Floodlight") provides a clear alternative for users using assistive technologies or switch controls.

## Testing Decisions

A good test drives the feature through its external boundaries and asserts observable state transitions and published outputs: whether System Settings was requested to open, whether the drag item provider encodes the application bundle file URL correctly, whether the grant state machine transitions to granted upon successful TCC probe, and whether the UI reflects the granted status without inspecting internal private timers.

Testing seams:

- **`FullDiskAccessGrantCoordinator` State Machine (Highest Seam)**:
  - Direct unit test with scripted dependencies (`openSettings: () -> Void`, `fullDiskAccessProvider: () -> Bool`, `bundleURL: () -> URL`):
    - Invoking `beginGrantFlow()` triggers `openSettings` and enters `.presentingGuidance`.
    - Polling while `fullDiskAccessProvider` returns `false` stays in `.presentingGuidance`.
    - Polling when `fullDiskAccessProvider` returns `true` transitions to `.granted`, invokes `onGranted` callback, and schedules dismissal.
    - Calling `dismiss()` transitions to `.dismissed` and ceases polling.
    - Re-invoking `beginGrantFlow()` while already presented re-focuses without duplicate panels.
  - Prior art: `OnboardingFlowState` tests in `Tests/FloodlightTests/OnboardingTests.swift`.
- **Drag Item Provider Seam (`ApplicationBundleDragSource`)**:
  - Unit test asserting that the drag payload produces `NSPasteboard.PasteboardType.fileURL` matching the provided application bundle URL and conforms to `public.file-url`.
  - Verifies behavior when `bundleURL` is a valid `.app` bundle versus an unbundled path.
- **`OnboardingSession` Integration**:
  - Verifies that `refreshFullDiskAccess()` updates `hasFullDiskAccess` dynamically and triggers view updates through Observation.
  - Tests that `OnboardingSession` correctly initialises with injected `fullDiskAccessProvider`.
- **SwiftUI View Rendering & Visual Snapshots**:
  - `ImageRenderer` snapshots of `FullDiskAccessGuidanceView` in `.presentingGuidance` and `.granted` states in both Light and Dark mode appearances, ensuring layout stability at proposed sizes (width ~380pt, height ~110pt).
  - Prior art: `OnboardingTests.onboardingViewRendersAtTheWindowSize()`.
- **Real-macOS Verification Plan**:
  - Verified on a real Mac with macOS 14 / 15 / 26:
    1. Clicking "Grant access" launches System Settings > Full Disk Access.
    2. Floating overlay appears at the bottom of the screen.
    3. Dragging the Floodlight icon into System Settings prompts for Touch ID / password.
    4. Upon authorization, overlay transitions to "Granted ✓" and dismisses automatically.
    5. Onboarding window updates to "Granted".

## Out of Scope

- Direct manipulation of macOS TCC SQLite database (`com.apple.TCC/TCC.db`), which is protected by System Integrity Protection (SIP).
- Requesting permissions not needed by Floodlight (e.g. Accessibility, Screen Recording, Microphone, Camera).
- Automated programmatic bypass of macOS user consent.
- Generating custom enterprise Mobile Device Management (MDM) configuration profiles (`.mobileconfig`).

## Further Notes

- **Reference Implementations**: Screenflare (shown in user-provided screenshot) and Codex computer use permission onboarding both employ this exact drag-and-drop HUD pattern. CleanShot X, Dropover, and Raycast also rely on this mechanism for Full Disk Access and Accessibility.
- **Deep Link URL Compatibility**:
  - Primary (macOS 13+): `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`
  - Fallback (macOS 12 and earlier): `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
- **Visual Design Compliance**: Follows Floodlight's design tokens and styling conventions (visual effect materials, 18pt radius, SF Pro type ramp, high-contrast drag handle).
