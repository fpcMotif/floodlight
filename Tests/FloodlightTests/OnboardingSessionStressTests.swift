import AppKit
import Foundation
import Testing
@testable import Floodlight

@MainActor
struct OnboardingSessionStressTests {
    // MARK: - session initialization

    @Test func sessionInitializationSetsProperties() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: true,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { true }
        )

        #expect(session.activeShortcut == .optionSpace)
        #expect(session.launchesAtLogin)
        #expect(session.rootURL == URL(fileURLWithPath: "/Users/example", isDirectory: true))
        #expect(session.hasFullDiskAccess)
    }

    // MARK: - fullDiskAccess

    @Test func fullDiskAccessTrueWhenProviderReturnsTrue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { true }
        )
        #expect(session.hasFullDiskAccess)
    }

    @Test func fullDiskAccessFalseWhenProviderReturnsFalse() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults,
            fullDiskAccessProvider: { false }
        )
        #expect(!session.hasFullDiskAccess)
    }

    // MARK: - offersSpotlightReplacement

    @Test func offersSpotlightReplacementForOptionSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .optionSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        #expect(session.offersSpotlightReplacement)
    }

    @Test func doesNotOfferSpotlightReplacementForCommandSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        #expect(!session.offersSpotlightReplacement)
    }

    @Test func offersSpotlightReplacementChangesWhenShortcutChanges() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        #expect(!session.offersSpotlightReplacement)

        session.activeShortcut = .optionSpace
        #expect(session.offersSpotlightReplacement)

        session.activeShortcut = .commandSpace
        #expect(!session.offersSpotlightReplacement)
    }

    // MARK: - refreshFullDiskAccess

    @Test func refreshFullDiskAccessUpdatesState() throws {
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
        #expect(!session.hasFullDiskAccess)

        providerValue = true
        session.refreshFullDiskAccess()
        #expect(session.hasFullDiskAccess)

        providerValue = false
        session.refreshFullDiskAccess()
        #expect(!session.hasFullDiskAccess)
    }

    // MARK: - complete

    @Test func completeSetsVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = OnboardingSession(
            activeShortcut: .commandSpace,
            launchesAtLogin: false,
            rootURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            defaults: defaults
        )
        session.complete()

        #expect(defaults.integer(forKey: OnboardingSession.completedVersionKey) == OnboardingSession
            .currentVersion)
    }

    @Test func completeIsIdempotent() throws {
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

        #expect(firstVersion == secondVersion)
        #expect(firstVersion == OnboardingSession.currentVersion)
    }

    // MARK: - shouldPresent

    @Test func shouldPresentTrueForFreshDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
    }

    @Test func shouldPresentFalseAfterComplete() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        #expect(!(OnboardingSession.shouldPresent(defaults: defaults, environment: [:])))
    }

    @Test func shouldPresentTrueForOlderVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion - 1,
            forKey: OnboardingSession.completedVersionKey
        )

        #expect(OnboardingSession.shouldPresent(defaults: defaults, environment: [:]))
    }

    @Test func shouldPresentTrueWhenForceOnboarding() throws {
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

    @Test func shouldPresentFalseWhenForceNotOne() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            OnboardingSession.currentVersion,
            forKey: OnboardingSession.completedVersionKey
        )

        #expect(!(OnboardingSession.shouldPresent(
            defaults: defaults,
            environment: ["FLOODLIGHT_FORCE_ONBOARDING": "0"]
        )))
        #expect(!(OnboardingSession.shouldPresent(
            defaults: defaults,
            environment: ["FLOODLIGHT_FORCE_ONBOARDING": "yes"]
        )))
    }

    // MARK: - FloodlightFullDiskAccess

    @Test func fullDiskAccessGrantedForReadableFile() throws {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFDA-\(UUID().uuidString)")
        try Data("probe".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        #expect(FloodlightFullDiskAccess.isGranted(probeURL: probe))
    }

    @Test func fullDiskAccessDeniedForNonexistentFile() {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFDA-missing-\(UUID().uuidString)")
        #expect(!FloodlightFullDiskAccess.isGranted(probeURL: probe))
    }

    // MARK: - FloodlightConfigurationPresentation

    @Test func onboardingPresentationTitlesAndSubtitles() {
        #expect(FloodlightConfigurationPresentation.onboarding.title == "Set up Floodlight")
        #expect(FloodlightConfigurationPresentation.onboarding
            .subtitle == "Choose a shortcut and give Floodlight search access.")
    }

    @Test func settingsPresentationTitlesAndSubtitles() {
        #expect(FloodlightConfigurationPresentation.settings.title == "Settings")
        #expect(FloodlightConfigurationPresentation.settings
            .subtitle == "Manage your shortcut, startup behavior, and search access.")
    }

    @Test func onboardingAndSettingsTitlesDiffer() {
        #expect(FloodlightConfigurationPresentation.onboarding
            .title != FloodlightConfigurationPresentation.settings.title)
        #expect(FloodlightConfigurationPresentation.onboarding
            .subtitle != FloodlightConfigurationPresentation.settings.subtitle)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OnboardingSessionStressTests-\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
