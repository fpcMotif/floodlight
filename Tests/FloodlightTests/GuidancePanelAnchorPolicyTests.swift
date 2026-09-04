import AppKit
import Foundation
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct GuidancePanelAnchorPolicyTests {
    @Test func centeredTargetWindowPositionsHUDDirectlyBelowWithOverlap() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let target = NSRect(x: 400, y: 300, width: 640, height: 480)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: target,
            parentWindow: nil,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.width == 380)
        #expect(frame.height == 110)
        #expect(frame.origin.x == 530)
        #expect(frame.origin.y == 210)
    }

    @Test func targetWindowNearBottomClampsWithinScreenBounds() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let target = NSRect(x: 400, y: 40, width: 640, height: 480)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: target,
            parentWindow: nil,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.origin.y == 8)
        #expect(frame.origin.x == 530)
    }

    @Test func targetWindowNearRightClampsWithinScreenBounds() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let target = NSRect(x: 1_200, y: 300, width: 400, height: 400)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: target,
            parentWindow: nil,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.maxX <= screen.maxX - 12)
        #expect(frame.width == 380)
    }

    @Test func targetWindowNearLeftClampsWithinScreenBounds() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let target = NSRect(x: -100, y: 300, width: 400, height: 400)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: target,
            parentWindow: nil,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.minX >= screen.minX + 12)
        #expect(frame.width == 380)
    }

    @Test func fallbackToParentWindowWhenTargetIsMissing() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let parent = NSRect(x: 200, y: 200, width: 600, height: 400)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: nil,
            parentWindow: parent,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.origin.x == 310)
        #expect(frame.origin.y == 106)
    }

    @Test func fallbackToScreenCenterWhenBothAreMissing() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let panelSize = NSSize(width: 380, height: 110)

        let frame = GuidancePanelAnchorPolicy.computeFrame(
            targetWindow: nil,
            parentWindow: nil,
            screen: screen,
            panelSize: panelSize
        )

        #expect(frame.origin.x == 530)
        #expect(frame.origin.y == 80)
    }

    @Test func quartzToCocoaCoordinateConversionInvertsYFromTopLeft() {
        let quartzRect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let cocoaRect = SystemSettingsWindowLocator.convertToCocoa(
            quartzBounds: quartzRect,
            primaryScreenHeight: 900
        )

        #expect(cocoaRect.origin.x == 100)
        #expect(cocoaRect.origin.y == 500)
        #expect(cocoaRect.width == 400)
        #expect(cocoaRect.height == 300)
    }

    @Test func coordinatorTrackingUpdatesPanelFrameWhenTargetWindowMoves() {
        var currentTarget: NSRect? = NSRect(x: 400, y: 300, width: 640, height: 480)
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: {},
            fullDiskAccessProvider: { false },
            bundleURL: { URL(fileURLWithPath: "/Applications/Floodlight.app") },
            targetWindowLocator: { currentTarget },
            autoPresentPanel: true
        )

        coordinator.beginGrantFlow()
        guard let panel = coordinator.activeGuidancePanel else {
            Issue.record("expected activeGuidancePanel")
            return
        }

        let initialOrigin = panel.frame.origin
        #expect(initialOrigin.x > 0)
        #expect(initialOrigin.y > 0)

        // Move target window by 100 points
        currentTarget = NSRect(x: 500, y: 350, width: 640, height: 480)
        coordinator.poll()

        let movedOrigin = panel.frame.origin
        #expect(movedOrigin.x != initialOrigin.x)

        coordinator.dismiss()
    }
}
