import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
final class OnboardingTests {
    @Test func onboardingRemainsPendingUntilCompleted() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        session.complete()

        #expect(!(OnboardingSession.shouldPresent(defaults: defaults, environment: [:])))
        #expect(defaults.integer(forKey: OnboardingSession.completedVersionKey) == OnboardingSession
            .currentVersion)
    }

    @Test func forcedOnboardingOverridesCompletedVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        #expect(OnboardingSession.shouldPresent(
            defaults: defaults,
            environment: ["FLOODLIGHT_FORCE_ONBOARDING": "1"]
        ))
    }

    @Test func shortcutPreferenceAndFallbackAreStable() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(FloodlightShortcut.preferred(in: defaults) == .commandSpace)
        FloodlightShortcut.optionSpace.save(in: defaults)
        #expect(FloodlightShortcut.preferred(in: defaults) == .optionSpace)
        #expect(FloodlightShortcut.optionSpace.fallback == .commandSpace)
        #expect(FloodlightShortcut.commandSpace.fallback == .optionSpace)
    }

    @Test func spotlightReplacementIsOfferedForTheFallbackShortcut() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )

        #expect(session.offersSpotlightReplacement)
        session.activeShortcut = .commandSpace
        #expect(!session.offersSpotlightReplacement)
    }

    @Test func fullDiskAccessProbeReflectsReadability() throws {
        let readableProbe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFullDiskAccess-\(UUID().uuidString)")
        try Data("probe".utf8).write(to: readableProbe)
        defer { try? FileManager.default.removeItem(at: readableProbe) }

        #expect(FloodlightFullDiskAccess.isGranted(probeURL: readableProbe))
        #expect(!(FloodlightFullDiskAccess.isGranted(
            probeURL: readableProbe.appendingPathExtension("missing")
        )))
    }

    @Test func onboardingViewRendersAtTheWindowSize() throws {
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
        let image = try #require(renderer.cgImage)
        #expect(image.width == 760)
        #expect(image.height == 530)

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

    @Test func settingsPresentationUsesConfigurationWindowDesign() throws {
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

        let image = try #require(renderer.cgImage)
        #expect(image.width == 760)
        #expect(image.height == 530)
        #expect(FloodlightConfigurationPresentation.settings.title == "Settings")
    }

    @Test func selectingTheActiveShortcutClearsTheMessageWithoutReregistering() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        session.shortcutMessage = "stale"
        spy.selectOutcome = .requestedShortcutActive(.optionSpace)

        flow.handleShortcutSelection(.optionSpace)

        #expect(session.shortcutMessage == nil)
        #expect(session.activeShortcut == .optionSpace)
        #expect(spy.selectedShortcuts == [.optionSpace])
    }

    @Test func selectingAnAvailableShortcutAdoptsIt() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        spy.selectOutcome = .requestedShortcutActive(.commandSpace)

        flow.handleShortcutSelection(.commandSpace)

        #expect(session.activeShortcut == .commandSpace)
        #expect(session.shortcutMessage == nil)
        #expect(spy.selectedShortcuts == [.commandSpace])
    }

    @Test func refusedCommandSpaceReportsSpotlightOwnership() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .optionSpace)

        flow.handleShortcutSelection(.commandSpace)

        #expect(session.activeShortcut == .optionSpace)
        #expect(session
            .shortcutMessage ==
            "Spotlight or another app still owns ⌘ Space. Floodlight kept ⌥ Space active.")
    }

    @Test func refusedOptionSpaceReportsARegistrationFailure() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .commandSpace)

        flow.handleShortcutSelection(.optionSpace)

        #expect(session.activeShortcut == .commandSpace)
        #expect(session
            .shortcutMessage == "macOS could not register ⌥ Space. Floodlight kept ⌘ Space active.")
    }

    @Test func selectionReportsWhenNoShortcutRemainsActive() throws {
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

        #expect(session.activeShortcut == nil)
        #expect(session
            .shortcutMessage ==
            "Spotlight or another app still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space to restore it.")
    }

    @Test func beginningSpotlightReplacementQueuesCommandSpaceAndOpensSettings() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)

        flow.beginSpotlightReplacement()

        #expect(flow.pendingShortcut == .commandSpace)
        #expect(session
            .shortcutMessage ==
            "Turn off “Show Spotlight search” in the pane that opens, then return here.")
        #expect(spy.spotlightSettingsOpenCount == 1)
        #expect(spy.selectedShortcuts.isEmpty)
    }

    @Test func retryingWithoutAPendingShortcutDoesNothing() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)

        flow.retryPendingShortcut()

        #expect(session.shortcutMessage == nil)
        #expect(spy.selectedShortcuts.isEmpty)
    }

    @Test func retryingAdoptsCommandSpaceOnceSpotlightReleasesIt() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        spy.selectOutcome = .requestedShortcutActive(.commandSpace)

        flow.retryPendingShortcut()

        #expect(session.activeShortcut == .commandSpace)
        #expect(session.shortcutMessage == "⌘ Space is ready.")
        #expect(flow.pendingShortcut == nil)
        #expect(spy.selectedShortcuts == [.commandSpace])
    }

    @Test func retryingKeepsWaitingWhileSpotlightStillOwnsCommandSpace() throws {
        let (flow, session, _) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()

        flow.retryPendingShortcut()

        #expect(session.activeShortcut == .optionSpace)
        #expect(session
            .shortcutMessage ==
            "Spotlight still owns ⌘ Space. Turn off “Show Spotlight search” and return here.")
        #expect(flow.pendingShortcut == .commandSpace)
    }

    @Test func retryingReportsWhenNoShortcutRemainsActive() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        spy.selectOutcome = .noShortcutActive

        flow.retryPendingShortcut()

        #expect(session.activeShortcut == nil)
        #expect(session
            .shortcutMessage ==
            "Spotlight still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space or update Spotlight and try again.")
        #expect(flow.pendingShortcut == .commandSpace)
    }

    @Test func retryingDropsAPendingShortcutThatIsAlreadyActive() throws {
        let (flow, session, spy) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()
        session.activeShortcut = .commandSpace

        flow.retryPendingShortcut()

        #expect(flow.pendingShortcut == nil)
        #expect(spy.selectedShortcuts.isEmpty)
    }

    @Test func selectingAShortcutCancelsThePendingRetry() throws {
        let (flow, _, _) = try makeFlow(activeShortcut: .optionSpace)
        flow.beginSpotlightReplacement()

        flow.handleShortcutSelection(.optionSpace)

        #expect(flow.pendingShortcut == nil)
    }

    @Test func finishingIsRecordedSoDismissalIsNotReported() throws {
        let (flow, _, _) = try makeFlow(activeShortcut: .optionSpace)
        #expect(!flow.didFinish)

        flow.markFinished()

        #expect(flow.didFinish)
    }

    private func makeFlow(
        activeShortcut: FloodlightShortcut
    ) throws -> (flow: OnboardingFlowState, session: OnboardingSession, spy: OnboardingFlowSpy) {
        let (defaults, _) = try makeDefaults()

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

    private var retainedDefaults: [RetainedDefaults] = []

    private func makeDefaults() throws -> (UserDefaults, String) {
        let isolated = RetainedDefaults(prefix: "FloodlightOnboardingTests")
        retainedDefaults.append(isolated)
        return (isolated.defaults, isolated.suiteName)
    }

    private func writeSnapshot(_ view: OnboardingView, to url: URL) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 530)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try #require(hostingView
            .bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        representation.size = NSSize(width: 760, height: 530)
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
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

private final class RetainedDefaults {
    let defaults: UserDefaults
    let suiteName: String

    init(prefix: String) {
        suiteName = "\(prefix)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
