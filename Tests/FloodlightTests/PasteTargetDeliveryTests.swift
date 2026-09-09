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

    private enum Interruption: CaseIterable, Sendable {
        case cancellation
        case focusLoss
        case secureInput
        case permissionLoss
        case termination
        case sleepFailure
    }

    @MainActor
    private final class DeliveryHarness {
        var trusted = true
        var secureInput = false
        var running = true
        var frontmost = true
        var activations = 0
        var posts = 0
        var prompts = 0
        var sleeps: [Int] = []
        var onSleep: (Int) throws -> Void = { _ in }

        var effects: PasteTargetDelivery.Effects {
            PasteTargetDelivery.Effects(
                isTrusted: { self.trusted },
                isSecureInputEnabled: { self.secureInput },
                application: { _ in
                    PasteTargetDelivery.Application(
                        isRunning: { self.running },
                        activate: { self.activations += 1 }
                    )
                },
                isFrontmost: { _ in self.frontmost },
                sleep: {
                    self.sleeps.append($0)
                    try self.onSleep($0)
                },
                postCommandV: { self.posts += 1
                    return true
                },
                promptForAccessibility: { self.prompts += 1 }
            )
        }

        func interrupt(_ interruption: Interruption) throws {
            switch interruption {
            case .cancellation:
                // Deliberately return normally from sleep: cancellation must
                // also be checked when a dependency does not throw.
                withUnsafeCurrentTask { $0?.cancel() }
            case .focusLoss: frontmost = false
            case .secureInput: secureInput = true
            case .permissionLoss: trusted = false
            case .termination: running = false
            case .sleepFailure: throw CancellationError()
            }
        }
    }

    @Test @MainActor func normalDeliveryActivatesWaitsAndPostsOnce() async {
        let harness = DeliveryHarness()
        harness.frontmost = false
        harness.onSleep = { _ in harness.frontmost = true }
        let delivery = PasteTargetDelivery(effects: harness.effects, target: ghostty)
        await delivery.deliver()
        #expect(harness.activations == 1)
        #expect(harness.sleeps == [15, 80])
        #expect(harness.posts == 1)
        #expect(harness.prompts == 0)
        #expect(delivery.target == ghostty)
    }

    @Test(arguments: Interruption.allCases)
    @MainActor private func interruptionDuringSettleNeverPosts(_ interruption: Interruption) async {
        let harness = DeliveryHarness()
        harness.onSleep = { _ in try harness.interrupt(interruption) }
        let delivery = PasteTargetDelivery(effects: harness.effects, target: ghostty)
        // Keep cancellation local to the delivery task, not the test runner.
        await Task { await delivery.deliver() }.value
        #expect(harness.sleeps == [80])
        #expect(harness.posts == 0)
        #expect(harness.activations == 0)
        #expect(harness.prompts == 0)
    }

    @Test(arguments: Interruption.allCases.filter { $0 != .focusLoss })
    @MainActor private func interruptionDuringActivationPollNeverPosts(
        _ interruption: Interruption
    ) async {
        let harness = DeliveryHarness()
        harness.frontmost = false
        harness.onSleep = { _ in
            harness.frontmost = true
            try harness.interrupt(interruption)
        }
        let delivery = PasteTargetDelivery(effects: harness.effects, target: ghostty)
        await Task { await delivery.deliver() }.value
        #expect(harness.sleeps == [15])
        #expect(harness.posts == 0)
        #expect(harness.prompts == 0)
    }

    @Test @MainActor func cancelledBeforeDeliveryHasNoEffects() async {
        let harness = DeliveryHarness()
        let delivery = PasteTargetDelivery(effects: harness.effects, target: ghostty)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await delivery.deliver()
        }.value
        #expect(harness.activations == 0)
        #expect(harness.sleeps.isEmpty)
        #expect(harness.posts == 0)
        #expect(harness.prompts == 0)
    }

    @Test @MainActor func activationTimeoutDoesNotPaste() async {
        let harness = DeliveryHarness()
        harness.frontmost = false
        await PasteTargetDelivery(effects: harness.effects, target: ghostty).deliver()
        #expect(harness.activations == 1)
        #expect(harness.sleeps == Array(repeating: 15, count: 40))
        #expect(harness.posts == 0)
    }

    @Test @MainActor func missingPermissionRemainsCopyOnlyAndPromptsOnce() async throws {
        let suite = "PasteTargetDeliveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let harness = DeliveryHarness()
        harness.trusted = false
        let delivery = PasteTargetDelivery(
            defaults: defaults,
            effects: harness.effects,
            target: ghostty
        )
        await delivery.deliver()
        await delivery.deliver()
        #expect(!delivery.isAvailable)
        #expect(harness.prompts == 1)
        #expect(harness.posts == 0)
        #expect(harness.activations == 0)
        #expect(harness.sleeps.isEmpty)
    }

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
