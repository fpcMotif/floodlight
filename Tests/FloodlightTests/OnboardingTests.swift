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
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
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
