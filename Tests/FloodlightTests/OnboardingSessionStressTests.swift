import AppKit
import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class OnboardingSessionStressTests: XCTestCase {
    // MARK: - session initialization

    func testSessionInitializationSetsProperties() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { true }
        )

        XCTAssertEqual(session.activeShortcut, .optionSpace)
        XCTAssertTrue(session.launchesAtLogin)
        XCTAssertEqual(session.rootURL, URL(fileURLWithPath: "/Users/example", isDirectory: true))
        XCTAssertTrue(session.hasFullDiskAccess)
    }

    // MARK: - fullDiskAccess

    func testFullDiskAccessTrueWhenProviderReturnsTrue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { true }
        )
        XCTAssertTrue(session.hasFullDiskAccess)
    }

    func testFullDiskAccessFalseWhenProviderReturnsFalse() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { false }
        )
        XCTAssertFalse(session.hasFullDiskAccess)
    }

    // MARK: - offersSpotlightReplacement

    func testOffersSpotlightReplacementForOptionSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        XCTAssertTrue(session.offersSpotlightReplacement)
    }

    func testDoesNotOfferSpotlightReplacementForCommandSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        XCTAssertFalse(session.offersSpotlightReplacement)
    }

    func testOffersSpotlightReplacementChangesWhenShortcutChanges() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        XCTAssertFalse(session.offersSpotlightReplacement)

        session.activeShortcut = .optionSpace
        XCTAssertTrue(session.offersSpotlightReplacement)

        session.activeShortcut = .commandSpace
        XCTAssertFalse(session.offersSpotlightReplacement)
    }

    // MARK: - refreshFullDiskAccess

    func testRefreshFullDiskAccessUpdatesState() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var providerValue = false
        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { providerValue }
        )
        XCTAssertFalse(session.hasFullDiskAccess)

        providerValue = true
        session.refreshFullDiskAccess()
        XCTAssertTrue(session.hasFullDiskAccess)

        providerValue = false
        session.refreshFullDiskAccess()
        XCTAssertFalse(session.hasFullDiskAccess)
    }

    // MARK: - complete

    func testCompleteSetsVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        session.complete()

        XCTAssertEqual(
            defaults.integer(forKey: OnboardingSession.completedVersionKey),
            OnboardingSession.currentVersion
        )
    }

    func testCompleteIsIdempotent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        session.complete()
        let firstVersion = defaults.integer(forKey: OnboardingSession.completedVersionKey)

        session.complete()
        let secondVersion = defaults.integer(forKey: OnboardingSession.completedVersionKey)

        XCTAssertEqual(firstVersion, secondVersion)
        XCTAssertEqual(firstVersion, OnboardingSession.currentVersion)
    }

    // MARK: - shouldPresent

    func testShouldPresentTrueForFreshDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
    }

    func testShouldPresentFalseAfterComplete() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        XCTAssertFalse(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
    }

    func testShouldPresentTrueForOlderVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion - 1,
            forKey: OnboardingSession.completedVersionKey
        )

        XCTAssertTrue(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
    }

    func testShouldPresentTrueWhenForceOnboarding() throws {
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

    func testShouldPresentFalseWhenForceNotOne() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        XCTAssertFalse(
            OnboardingSession.shouldPresent(
                defaults: defaults,
                environment: ["FLOODLIGHT_FORCE_ONBOARDING": "0"]
            )
        )
        XCTAssertFalse(
            OnboardingSession.shouldPresent(
                defaults: defaults,
                environment: ["FLOODLIGHT_FORCE_ONBOARDING": "yes"]
            )
        )
    }

    // MARK: - FloodlightFullDiskAccess

    func testFullDiskAccessGrantedForReadableFile() throws {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFDA-\(UUID().uuidString)")
        try Data("probe".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        XCTAssertTrue(FloodlightFullDiskAccess.isGranted(probeURL: probe))
    }

    func testFullDiskAccessDeniedForNonexistentFile() {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFDA-missing-\(UUID().uuidString)")
        XCTAssertFalse(FloodlightFullDiskAccess.isGranted(probeURL: probe))
    }

    // MARK: - FloodlightConfigurationPresentation

    func testOnboardingPresentationTitlesAndSubtitles() {
        XCTAssertEqual(FloodlightConfigurationPresentation.onboarding.title, "Set up Floodlight")
        XCTAssertEqual(
            FloodlightConfigurationPresentation.onboarding.subtitle,
            "Choose a shortcut and give Floodlight search access."
        )
    }

    func testSettingsPresentationTitlesAndSubtitles() {
        XCTAssertEqual(FloodlightConfigurationPresentation.settings.title, "Settings")
        XCTAssertEqual(
            FloodlightConfigurationPresentation.settings.subtitle,
            "Manage your shortcut, startup behavior, and search access."
        )
    }

    func testOnboardingAndSettingsTitlesDiffer() {
        XCTAssertNotEqual(
            FloodlightConfigurationPresentation.onboarding.title,
            FloodlightConfigurationPresentation.settings.title
        )
        XCTAssertNotEqual(
            FloodlightConfigurationPresentation.onboarding.subtitle,
            FloodlightConfigurationPresentation.settings.subtitle
        )
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OnboardingSessionStressTests-\(UUID().uuidString)"
        return try (XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
