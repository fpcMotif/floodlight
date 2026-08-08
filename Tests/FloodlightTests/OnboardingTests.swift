import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Floodlight

@MainActor
final class OnboardingTests: XCTestCase {
    func testOnboardingRemainsPendingUntilCompleted() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        session.complete()

        XCTAssertFalse(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
        XCTAssertEqual(
            defaults.integer(forKey: OnboardingSession.completedVersionKey),
            OnboardingSession.currentVersion
        )
    }

    func testForcedOnboardingOverridesCompletedVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        XCTAssertTrue(
            OnboardingSession.shouldPresent(
                defaults: defaults,
                environment: ["FLOODLIGHT_FORCE_ONBOARDING": "1"]
            )
        )
    }

    func testShortcutPreferenceAndFallbackAreStable() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .commandSpace)
        FloodlightShortcut.optionSpace.save(in: defaults)
        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .optionSpace)
        XCTAssertEqual(FloodlightShortcut.optionSpace.fallback, .commandSpace)
        XCTAssertEqual(FloodlightShortcut.commandSpace.fallback, .optionSpace)
    }

    func testSpotlightReplacementIsOfferedForTheFallbackShortcut() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )

        XCTAssertTrue(session.offersSpotlightReplacement)
        session.activeShortcut = .commandSpace
        XCTAssertFalse(session.offersSpotlightReplacement)
    }

    func testFullDiskAccessProbeReflectsReadability() throws {
        let readableProbe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFullDiskAccess-\(UUID().uuidString)")
        try Data("probe".utf8).write(to: readableProbe)
        defer { try? FileManager.default.removeItem(at: readableProbe) }

        XCTAssertTrue(FloodlightFullDiskAccess.isGranted(probeURL: readableProbe))
        XCTAssertFalse(
            FloodlightFullDiskAccess.isGranted(
                probeURL: readableProbe.appendingPathExtension("missing")
            )
        )
    }

    func testOnboardingViewRendersAtTheWindowSize() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { false }
        )

        session.shortcutMessage =
            "Spotlight still owns ⌘ Space. Floodlight kept ⌥ Space active."
        let renderer = ImageRenderer(content: makeView(session: session))
        renderer.proposedSize = ProposedViewSize(width: 760, height: 530)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 760)
        XCTAssertEqual(image.height, 530)

        if let snapshotDirectory = ProcessInfo.processInfo.environment[
            "FLOODLIGHT_ONBOARDING_SNAPSHOT_DIR"
        ] {
            let directory = URL(
                fileURLWithPath: snapshotDirectory,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let setupSession = OnboardingSession(
                activeShortcut: .commandSpace,
                launchesAtLogin: true,
                rootURL: URL(fileURLWithPath: "/Users/JohnDoe", isDirectory: true),
                defaults: defaults,
                fullDiskAccessProvider: { false }
            )
            try writeSnapshot(
                makeView(session: setupSession),
                to: directory.appendingPathComponent("setup.png")
            )

            let settingsSession = OnboardingSession(
                activeShortcut: .optionSpace,
                launchesAtLogin: true,
                rootURL: URL(fileURLWithPath: "/Users/JohnDoe", isDirectory: true),
                defaults: defaults,
                fullDiskAccessProvider: { true }
            )
            try writeSnapshot(
                makeView(session: settingsSession, presentation: .settings),
                to: directory.appendingPathComponent("settings.png")
            )
        }
    }

    func testSettingsPresentationUsesConfigurationWindowDesign() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { true }
        )
        let renderer = ImageRenderer(
            content: makeView(session: session, presentation: .settings)
        )
        renderer.proposedSize = ProposedViewSize(width: 760, height: 530)
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 760)
        XCTAssertEqual(image.height, 530)
        XCTAssertEqual(FloodlightConfigurationPresentation.settings.title, "Settings")
    }

    func testSelectingTheActiveShortcutClearsTheMessageWithoutReregistering() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        session.shortcutMessage = "stale"
        spy.selectOutcome = .requestedShortcutActive(.optionSpace)

        flow.handleShortcutSelection(.optionSpace)

        XCTAssertNil(session.shortcutMessage)
        XCTAssertEqual(session.activeShortcut, .optionSpace)
        XCTAssertEqual(spy.selectedShortcuts, [.optionSpace])
    }

    func testSelectingAnAvailableShortcutAdoptsIt() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        spy.selectOutcome = .requestedShortcutActive(.commandSpace)

        flow.handleShortcutSelection(.commandSpace)

        XCTAssertEqual(session.activeShortcut, .commandSpace)
        XCTAssertNil(session.shortcutMessage)
        XCTAssertEqual(spy.selectedShortcuts, [.commandSpace])
    }

    func testRefusedCommandSpaceReportsSpotlightOwnership() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .optionSpace)

        flow.handleShortcutSelection(.commandSpace)

        XCTAssertEqual(session.activeShortcut, .optionSpace)
        XCTAssertEqual(
            session.shortcutMessage,
            "Spotlight or another app still owns ⌘ Space. Floodlight kept ⌥ Space active."
        )
    }

    func testRefusedOptionSpaceReportsARegistrationFailure() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .commandSpace)

        flow.handleShortcutSelection(.optionSpace)

        XCTAssertEqual(session.activeShortcut, .commandSpace)
        XCTAssertEqual(
            session.shortcutMessage,
            "macOS could not register ⌥ Space. Floodlight kept ⌘ Space active."
        )
    }

    func testSelectionReportsWhenNoShortcutRemainsActive() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { false }
        )
        let flow = OnboardingFlowState(
            session: session,
            selectShortcut: { _ in .noShortcutActive },
            openSpotlightSettings: {}
        )

        flow.handleShortcutSelection(.commandSpace)

        XCTAssertNil(session.activeShortcut)
        XCTAssertEqual(
            session.shortcutMessage,
            "Spotlight or another app still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space to restore it."
        )
    }

    func testBeginningSpotlightReplacementQueuesCommandSpaceAndOpensSettings() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)

        flow.beginSpotlightReplacement()

        XCTAssertEqual(flow.pendingShortcut, .commandSpace)
        XCTAssertEqual(
            session.shortcutMessage,
            "Turn off “Show Spotlight search” in the pane that opens, then return here."
        )
        XCTAssertEqual(spy.spotlightSettingsOpenCount, 1)
        XCTAssertTrue(spy.selectedShortcuts.isEmpty)
    }

    func testRetryingWithoutAPendingShortcutDoesNothing() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)

        flow.retryPendingShortcut()

        XCTAssertNil(session.shortcutMessage)
        XCTAssertTrue(spy.selectedShortcuts.isEmpty)
    }

    func testRetryingAdoptsCommandSpaceOnceSpotlightReleasesIt() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        spy.selectOutcome = .requestedShortcutActive(.commandSpace)

        flow.retryPendingShortcut()

        XCTAssertEqual(session.activeShortcut, .commandSpace)
        XCTAssertEqual(session.shortcutMessage, "⌘ Space is ready.")
        XCTAssertNil(flow.pendingShortcut)
        XCTAssertEqual(spy.selectedShortcuts, [.commandSpace])
    }

    func testRetryingKeepsWaitingWhileSpotlightStillOwnsCommandSpace() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()

        flow.retryPendingShortcut()

        XCTAssertEqual(session.activeShortcut, .optionSpace)
        XCTAssertEqual(
            session.shortcutMessage,
            "Spotlight still owns ⌘ Space. Turn off “Show Spotlight search” and return here."
        )
        XCTAssertEqual(flow.pendingShortcut, .commandSpace)
    }

    func testRetryingReportsWhenNoShortcutRemainsActive() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        spy.selectOutcome = .noShortcutActive

        flow.retryPendingShortcut()

        XCTAssertNil(session.activeShortcut)
        XCTAssertEqual(
            session.shortcutMessage,
            "Spotlight still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space or update Spotlight and try again."
        )
        XCTAssertEqual(flow.pendingShortcut, .commandSpace)
    }

    func testRetryingDropsAPendingShortcutThatIsAlreadyActive() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        session.activeShortcut = .commandSpace

        flow.retryPendingShortcut()

        XCTAssertNil(flow.pendingShortcut)
        XCTAssertTrue(spy.selectedShortcuts.isEmpty)
    }

    func testSelectingAShortcutCancelsThePendingRetry() throws {
        let (flow, _, _) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()

        flow.handleShortcutSelection(.optionSpace)

        XCTAssertNil(flow.pendingShortcut)
    }

    func testFinishingIsRecordedSoDismissalIsNotReported() throws {
        let (flow, _, _) = try makeFlow(activeShortcut: .optionSpace)
        XCTAssertFalse(flow.didFinish)

        flow.markFinished()

        XCTAssertTrue(flow.didFinish)
    }

    private func makeFlow(
        activeShortcut: FloodlightShortcut
    ) throws -> (flow: OnboardingFlowState, session: OnboardingSession, spy: OnboardingFlowSpy) {
        let (defaults, suiteName) = try makeDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: activeShortcut,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { false }
        )
        let spy = OnboardingFlowSpy()
        spy.selectOutcome = .previousShortcutActive(activeShortcut)
        let flow = OnboardingFlowState(
            session: session,
            selectShortcut: spy.selectShortcut,
            openSpotlightSettings: spy.openSpotlightSettings
        )
        return (flow, session, spy)
    }

    private func makeView(
        session: OnboardingSession,
        presentation: FloodlightConfigurationPresentation = .onboarding
    ) -> OnboardingView {
        OnboardingView(
            presentation: presentation,
            session: session,
            onSelectShortcut: { _ in },
            onSetLaunchAtLogin: { _ in },
            onChooseScope: {},
            onOpenSpotlightSettings: {},
            onOpenFullDiskAccess: {},
            onFinish: {}
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FloodlightOnboardingTests-\(UUID().uuidString)"
        return try (XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func writeSnapshot(_ view: OnboardingView, to url: URL) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 530)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        representation.size = NSSize(width: 760, height: 530)
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let data = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try data.write(to: url)
    }
}

@MainActor
private final class OnboardingFlowSpy {
    var selectOutcome = GlobalHotKeyReplacementOutcome.noShortcutActive
    private(set) var selectedShortcuts: [FloodlightShortcut] = []
    private(set) var spotlightSettingsOpenCount = 0

    func selectShortcut(_ shortcut: FloodlightShortcut) -> GlobalHotKeyReplacementOutcome {
        selectedShortcuts.append(shortcut)
        return selectOutcome
    }

    func openSpotlightSettings() {
        spotlightSettingsOpenCount += 1
    }
}
