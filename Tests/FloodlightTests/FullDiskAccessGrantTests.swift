import AppKit
import FloodlightEngine
import Foundation
import SwiftUI
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct FullDiskAccessGrantTests {
    private final class Spy {
        var openSettingsCallCount = 0
        var fullDiskAccessGranted = false
        var onGrantedCallCount = 0
        var onDismissedCallCount = 0
        var bundleURL = URL(fileURLWithPath: "/Applications/Floodlight.app")

        func openSettings() {
            openSettingsCallCount += 1
        }

        func fullDiskAccessProvider() -> Bool {
            fullDiskAccessGranted
        }

        func onGranted() {
            onGrantedCallCount += 1
        }

        func onDismissed() {
            onDismissedCallCount += 1
        }
    }

    @Test func beginningGrantFlowOpensSettingsAndEntersGuidancePhase() {
        let spy = Spy()
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: spy.onGranted,
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )

        #expect(coordinator.phase == .idle)
        coordinator.beginGrantFlow()

        #expect(spy.openSettingsCallCount == 1)
        guard case let .presentingGuidance(appURL, isPolling) = coordinator.phase else {
            Issue.record("expected presentingGuidance phase")
            return
        }
        #expect(appURL == spy.bundleURL)
        #expect(isPolling)
    }

    @Test func beginningGrantFlowWhenAlreadyGrantedTransitionsDirectly() {
        let spy = Spy()
        spy.fullDiskAccessGranted = true
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: spy.onGranted,
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )

        coordinator.beginGrantFlow()

        #expect(spy.openSettingsCallCount == 0)
        #expect(coordinator.phase == .granted)
        #expect(spy.onGrantedCallCount == 1)
    }

    @Test func pollingWhileDeniedRemainsInGuidancePhase() {
        let spy = Spy()
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: spy.onGranted,
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )

        coordinator.beginGrantFlow()
        coordinator.poll()

        guard case let .presentingGuidance(_, isPolling) = coordinator.phase else {
            Issue.record("expected presentingGuidance phase")
            return
        }
        #expect(isPolling)
        #expect(spy.onGrantedCallCount == 0)
    }

    @Test func pollingWhenGrantedTransitionsToGrantedAndCeasesPolling() {
        let spy = Spy()
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: spy.onGranted,
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )

        coordinator.beginGrantFlow()
        spy.fullDiskAccessGranted = true
        coordinator.poll()

        #expect(coordinator.phase == .granted)
        #expect(spy.onGrantedCallCount == 1)
    }

    @Test func dismissingCeasesPollingAndCallsDismissed() {
        let spy = Spy()
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: spy.onGranted,
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )

        coordinator.beginGrantFlow()
        coordinator.dismiss()

        #expect(coordinator.phase == .dismissed)
        #expect(spy.onDismissedCallCount == 1)
    }

    @Test func guidanceViewRendersInLightAndDarkMode() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Floodlight.app")
        let view = FullDiskAccessGuidanceView(
            phase: .presentingGuidance(appURL: bundleURL, isPolling: true),
            appName: "Floodlight",
            onDismiss: {}
        )

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 380, height: 110)
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0)
        #expect(image.height > 0)

        let grantedView = FullDiskAccessGuidanceView(
            phase: .granted,
            appName: "Floodlight",
            onDismiss: {}
        )
        let grantedRenderer = ImageRenderer(content: grantedView)
        grantedRenderer.proposedSize = ProposedViewSize(width: 380, height: 110)
        let grantedImage = try #require(grantedRenderer.cgImage)
        #expect(grantedImage.width > 0)
        #expect(grantedImage.height > 0)
    }

    @Test func flowStateIntegratesWithFullDiskAccessGrantCoordinator() {
        let spy = Spy()
        var session: OnboardingSession!
        let coordinator = FullDiskAccessGrantCoordinator(
            openSettings: spy.openSettings,
            fullDiskAccessProvider: spy.fullDiskAccessProvider,
            bundleURL: { spy.bundleURL },
            onGranted: {
                spy.onGranted()
                session?.refreshFullDiskAccess()
            },
            onDismissed: spy.onDismissed,
            autoPresentPanel: false
        )
        session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example"),
            fullDiskAccessProvider: spy.fullDiskAccessProvider
        )
        let flow = OnboardingFlowState(
            session: session,
            selectShortcut: { _, _ in .noShortcutActive },
            openSpotlightSettings: {},
            fullDiskAccessCoordinator: coordinator
        )

        flow.beginFullDiskAccessGrant()

        #expect(spy.openSettingsCallCount == 1)
        #expect(!session.hasFullDiskAccess)

        spy.fullDiskAccessGranted = true
        coordinator.poll()

        #expect(session.hasFullDiskAccess)
        #expect(spy.onGrantedCallCount == 1)

        flow.markFinished()
        #expect(coordinator.phase == .dismissed)
    }
}
