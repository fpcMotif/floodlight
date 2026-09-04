## Problem Statement

In Issue #63, Floodlight introduced drag-and-drop Full Disk Access permission onboarding via a floating guidance HUD (`FullDiskAccessGuidancePanel`). While this eliminated the seven-step manual file picker journey, user testing on modern macOS desktops revealed a critical spatial disconnect:

1. **Massive Spatial Gap**: The floating guidance HUD is statically anchored to the bottom-center of the entire display (`screen.visibleFrame.midX`, `screen.visibleFrame.minY + 80`). Meanwhile, macOS opens the System Settings window in the center or upper-right of the screen. On standard (1440×900 pt) and high-resolution displays (e.g. 1728×1117 pt MacBook Pro, 2560×1440 pt Studio Display), the guidance card sits hundreds of points away from the Full Disk Access list.
2. **Awkward Diagonal Drag Gesture**: To grant permission, the user must click and hold the draggable application card at the bottom of their screen and drag it diagonally across open terminal windows, menu bars, and wallpaper background up into System Settings. This long-distance drag is awkward on trackpads, easily drops prematurely, and fails the design promise of a quick, frictionless authorization.
3. **Misleading Directional Guidance**: The banner says `"↑ Drag Floodlight into the Full Disk Access list"` with an upward arrow (`arrow.up`). But because the HUD is located at the bottom of the display while System Settings may be positioned to the right or top-left, the upward arrow points into arbitrary wallpaper or unrelated background applications (such as Boom 3D or Terminal) rather than into the System Settings table.
4. **Desynchronization When Moving Windows**: If the user repositions the System Settings window to see what they are doing, the guidance HUD remains pinned to the bottom of the screen, exacerbating the disconnect.

Leading macOS apps that use this pattern (such as Screenflare and Codex) anchor their guidance card **directly to the bottom edge of the target System Settings window**. The user drags the application card a mere 40–60 points straight up into the privacy list. Floodlight needs this window-anchored spatial attachment.

## Solution

Implement dynamic **System Settings Window Anchoring** for the Full Disk Access guidance HUD:

1. **Target Window Geometry Resolution**: When System Settings opens to the Full Disk Access pane, Floodlight queries macOS Window Services to detect the on-screen frame of the System Settings window (`com.apple.systempreferences` / `"System Settings"`).
2. **Attached Edge Docking**: Position the floating guidance HUD attached directly to the **bottom edge of the System Settings window**, centered along the window's width or aligned with its right-hand details pane where the Full Disk Access table lives:
   - The HUD rests immediately over or overlapping the lower margin of System Settings, so the upward arrow (`arrow.up`) points directly into the privacy table.
   - The drag distance from the Floodlight card to the drop target table is reduced from hundreds of points to ~50 points.
3. **Dynamic Position Tracking**: While the guidance HUD is presented, the coordinator tracks the target window's position during its periodic lifecycle tick (~500ms). If the user drags or repositions the System Settings window, the guidance HUD follows smoothly, maintaining spatial lock.
4. **Hierarchical Fallback Anchoring**:
   - **Tier 1 (Preferred)**: Anchored to the bottom edge of the System Settings window.
   - **Tier 2 (Secondary)**: If System Settings is minimized, obscured, or not yet registered, anchor to the bottom edge of Floodlight's own Configuration/Settings window.
   - **Tier 3 (Safety Fallback)**: If neither window can be resolved, fall back cleanly to the bottom-center of the active display.
5. **Screen Containment Clamping**: The calculated frame is always clamped to the active screen's visible frame (`visibleFrame`), ensuring the guidance HUD is never pushed off-screen or hidden behind the macOS Dock or menu bar.

## User Stories

### Window Anchoring and Alignment

1. As a Floodlight user clicking "Grant access", I want the floating guidance card to appear attached directly to the bottom of the System Settings window, so that the guidance is immediately adjacent to the settings table.
2. As a Floodlight user, I want the guidance card to be positioned such that dragging the Floodlight icon requires only a short upward motion of ~50 points, so that the drag gesture is effortless and reliable on trackpads.
3. As a Floodlight user looking at the guidance card's upward arrow, I want the arrow to point directly into the Full Disk Access list in System Settings, so that the visual instructions are unambiguous.
4. As a Floodlight user who moves the System Settings window to a different part of the screen, I want the guidance card to follow the window, so that the attachment is preserved while I organize my desktop.
5. As a Floodlight user on a multi-monitor workstation, I want the guidance card to anchor to the System Settings window on whichever display it is placed, so that the helper never appears on the wrong monitor.
6. As a Floodlight user whose System Settings window is positioned close to the bottom of the screen, I want the guidance card to dock inside or clamp within the screen's visible boundaries, so that it is never hidden behind the macOS Dock.
7. As a Floodlight user whose System Settings window is near the top of the screen, I want the guidance card to stay attached to its bottom edge, so that the spatial relationship remains constant.

### Fallback and Robustness

8. As a Floodlight user whose System Settings takes a few moments to launch, I want the guidance card to initially anchor to the Floodlight Configuration window and then smoothly relocate to System Settings once it appears, so that there is no jarring delay.
9. As a Floodlight user in an environment where macOS Window Services restricts window enumeration, I want the guidance card to fall back gracefully to the Floodlight Settings window or screen center, so that the app never crashes or hangs.
10. As a Floodlight user who minimizes or closes System Settings, I want the guidance card to detect the closure and automatically dismiss or re-anchor, so that orphaned floating panels do not clutter my desktop.
11. As a Floodlight user who drags the Floodlight card from the inline configuration row in Floodlight's own Settings window, I want that inline drag to remain fully functional, so that I have the choice of dragging from either location.
12. As a Floodlight user who grants Full Disk Access, I want the attached guidance card to display the success confirmation directly below System Settings and fade out, so that the celebratory feedback is located right where I was looking.

### Interaction and Accessibility

13. As a Floodlight user, I want the attached guidance panel to remain non-activating, so that clicking or dragging from it does not deactivate System Settings or close any open macOS authentication sheets.
14. As a Floodlight user, I want the guidance panel to have a subtle shadow and visual separation from the System Settings window, so that it looks like a distinct, interactable accessory.
15. As a Floodlight user, I want to be able to drag the guidance panel itself by its background if I want to adjust its position manually, so that it never obstructs content I need to see.
16. As a Floodlight user who manually repositions the guidance card, I want my manual placement to be respected until System Settings moves again, so that user intent always overrides automatic docking.
17. As a Floodlight user, I want the close button (`✕`) on the attached card to remain easily clickable, so that dismissing the flow is immediate at all times.

## Implementation Decisions

### Target Window Geometry Resolver (`SystemSettingsWindowLocator`)

- **Dedicated Geometry Resolution Service**: Introduce a main-actor service protocol and implementation that locates the on-screen bounding rectangle of the target application window.
- **Window Enumeration Strategy**:
  - Uses `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`.
  - Filters entries for owner process names matching `"System Settings"` or `"System Preferences"`, and bundle identifier `"com.apple.systempreferences"`.
  - Selects the primary on-screen window (layer 0, non-empty bounds, alpha > 0.5) with the highest window ID / frontmost order.
  - Extracts `kCGWindowBounds` as a `CGRect` in screen coordinates.
- **Coordinate System Normalization**:
  - `CGWindowListCopyWindowInfo` returns rectangles in Quartz global display coordinates (origin at top-left of primary display, y increasing downward).
  - AppKit `NSWindow` and `NSScreen` use Cocoa coordinates (origin at bottom-left of primary display, y increasing upward).
  - The resolver encapsulates the coordinate flip (`cocoaY = primaryScreenHeight - (quartzY + quartzHeight)`), vending clean Cocoa `NSRect` values.

### Anchoring Computation Policy (`GuidancePanelAnchorPolicy`)

- **Anchor Math**:
  - Given a target `NSRect` (System Settings window) and HUD size `(width: 380, height: 110)`:
    - `originX = targetRect.midX - (hudWidth / 2)` (or offset toward the right half where the detail pane sits, clamped to `targetRect.maxX - hudWidth - 16`).
    - `originY = targetRect.minY - hudHeight + 20` (providing a 20pt overlap on the bottom chrome of System Settings, matching Screenflare's visual appearance).
  - Clamping:
    - Ensure `originX >= screen.visibleFrame.minX + 12` and `originX + hudWidth <= screen.visibleFrame.maxX - 12`.
    - Ensure `originY >= screen.visibleFrame.minY + 8`.
- **Prototype Anchor Logic**:
  ```swift
  struct GuidancePanelAnchorPolicy {
      static func computeFrame(
          targetWindow: NSRect?,
          parentWindow: NSRect?,
          screen: NSRect,
          panelSize: NSSize = NSSize(width: 380, height: 110)
      ) -> NSRect {
          if let target = targetWindow {
              let x = target.midX - (panelSize.width / 2)
              let y = target.minY - panelSize.height + 24
              return clamp(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), in: screen)
          }
          if let parent = parentWindow {
              let x = parent.midX - (panelSize.width / 2)
              let y = parent.minY - panelSize.height + 16
              return clamp(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), in: screen)
          }
          let x = screen.midX - (panelSize.width / 2)
          let y = screen.minY + 80
          return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
      }
  }
  ```

### FullDiskAccessGrantCoordinator Updates

- **Periodic Anchor Tracking**:
  - During `FullDiskAccessGrantCoordinator.poll()`, invoke the window locator.
  - If a valid target window rect is returned and has changed by more than 4 points from the last tracked position, animate `FullDiskAccessGuidancePanel` to the updated anchor position (`setFrame(_:display:animate:)`).
- **Initial Snapping**:
  - When `beginGrantFlow()` is invoked, immediately open System Settings, locate its window after a short initial delay (~150ms) to allow the OS to place the window, and snap the HUD directly to the bottom of System Settings.

### Guidance Panel Styling Refinements

- **Visual Docking Notch / Edge**:
  - Enhance `FullDiskAccessGuidanceView` to incorporate an elevated backdrop with visual effect materials that complement macOS System Settings' dark/light appearance.
  - Ensure the panel remains movable by window background (`isMovableByWindowBackground = true`) so if a user wants to nudge it, manual positioning is allowed.

## Testing Decisions

A good test drives the geometry resolution and anchoring policies through external inputs and asserts observable frames and coordinate mappings, without mocking private WindowServer hooks or touching the real user's display layout during CI.

Testing seams:

1. **`GuidancePanelAnchorPolicy` Pure Calculation Seam (Highest Seam)**:
   - Unit tests covering:
     - Target window in center of screen $\rightarrow$ HUD positioned immediately below target, centered along X.
     - Target window at bottom edge of screen $\rightarrow$ HUD clamped within screen `visibleFrame` above Dock margin.
     - Target window at left/right screen edge $\rightarrow$ HUD clamped horizontally without clipping.
     - Missing target window with present parent window $\rightarrow$ HUD anchors to parent window bottom.
     - Missing target and parent windows $\rightarrow$ HUD falls back to screen bottom-center.
     - Multi-display coordinate conversion: Quartz top-left inverted coordinates correctly map to Cocoa bottom-left coordinates across secondary displays.
2. **`FullDiskAccessGrantCoordinator` Tracking Seam**:
   - Inject a scripted `WindowLocator` closure `() -> NSRect?` into the coordinator:
     - Coordinator initial appearance calls locator and adopts position.
     - Changing the locator's returned rect during periodic polling updates the panel's target frame.
     - Locator returning `nil` keeps existing position or falls back gracefully without crashing.
3. **Real-macOS Visual Verification**:
   - Test on macOS 14/15/26:
     1. Open Floodlight Settings and click "Grant access".
     2. System Settings opens to Full Disk Access.
     3. Verify HUD docks right below the System Settings window.
     4. Move System Settings: verify HUD tracks smoothly.
     5. Drag Floodlight icon up into the list: verify ~50pt drag distance and successful drop.

## Out of Scope

- Injecting synthetic mouse events or automating the drop into System Settings (macOS security blocks synthetic drags into TCC lists).
- Intercepting other applications' windows outside System Settings and Floodlight.
- Subclassing or swizzling System Settings' private views.

## Further Notes

- **Prior Art Comparison**:
  - Issue #63 placed the HUD at `screen.minY + 80` (bottom of display).
  - This spec updates the HUD positioning to anchor to `System Settings.minY - panelHeight + overlap`, directly resolving the user feedback and screenshot in Issue #64.
- **Reference Image**: User-provided Image #1 demonstrates the existing defect where the HUD sits stranded at the bottom of the screen while System Settings is in the upper half.
