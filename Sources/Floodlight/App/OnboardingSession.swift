import Foundation
import Observation

enum FloodlightFullDiskAccess {
    static func isGranted(
        probeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.TCC/TCC.db",
                isDirectory: false
            )
    ) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: probeURL)
            try? handle.close()
            return true
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
final class OnboardingSession {
    static let currentVersion = 2
    static let completedVersionKey = "onboarding-completed-version"

    var activeShortcut: FloodlightShortcut?
    var shortcutMessage: String?
    var launchesAtLogin: Bool
    var launchAtLoginMessage: String?
    var rootURL: URL
    private(set) var hasFullDiskAccess: Bool

    var offersSpotlightReplacement: Bool {
        activeShortcut != .commandSpace
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let fullDiskAccessProvider: () -> Bool

    init(
        activeShortcut: FloodlightShortcut?,
        launchesAtLogin: Bool,
        rootURL: URL,
        defaults: UserDefaults = .standard,
        fullDiskAccessProvider: @escaping () -> Bool = {
            FloodlightFullDiskAccess.isGranted()
        }
    ) {
        self.activeShortcut = activeShortcut
        self.launchesAtLogin = launchesAtLogin
        self.rootURL = rootURL
        self.defaults = defaults
        self.fullDiskAccessProvider = fullDiskAccessProvider
        hasFullDiskAccess = fullDiskAccessProvider()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = fullDiskAccessProvider()
    }

    func complete() {
        defaults.set(Self.currentVersion, forKey: Self.completedVersionKey)
    }

    static func shouldPresent(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["FLOODLIGHT_FORCE_ONBOARDING"] == "1" {
            return true
        }
        return defaults.integer(forKey: completedVersionKey) < currentVersion
    }
}
