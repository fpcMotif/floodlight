import Foundation
import Testing
@testable import Floodlight

/// Who Return pastes into (#66): the app that was frontmost at summon, never
/// Floodlight itself, and the previous target while Floodlight has kept the
/// front since it last hid.
struct PasteTargetDeliveryTests {
    private let ghostty = PasteTargetDelivery.Target(name: "Ghostty", processIdentifier: 4_242)
    private let zed = PasteTargetDelivery.Target(name: "Zed", processIdentifier: 5_151)
    private let ownProcessIdentifier: pid_t = 99

    @Test func aForeignFrontmostApplicationBecomesTheTarget() {
        #expect(PasteTargetDelivery.resolveTarget(
            frontmost: ghostty,
            ownProcessIdentifier: ownProcessIdentifier,
            previous: zed,
            previousIsRunning: true
        ) == ghostty)
    }

    @Test func floodlightItselfKeepsTheRunningPreviousTarget() {
        let floodlight = PasteTargetDelivery.Target(
            name: "Floodlight",
            processIdentifier: ownProcessIdentifier
        )
        #expect(PasteTargetDelivery.resolveTarget(
            frontmost: floodlight,
            ownProcessIdentifier: ownProcessIdentifier,
            previous: zed,
            previousIsRunning: true
        ) == zed)
        #expect(PasteTargetDelivery.resolveTarget(
            frontmost: floodlight,
            ownProcessIdentifier: ownProcessIdentifier,
            previous: zed,
            previousIsRunning: false
        ) == nil)
    }

    @Test func noFrontmostApplicationAndNoPreviousTargetMeansNoTarget() {
        #expect(PasteTargetDelivery.resolveTarget(
            frontmost: nil,
            ownProcessIdentifier: ownProcessIdentifier,
            previous: nil,
            previousIsRunning: false
        ) == nil)
    }
}
