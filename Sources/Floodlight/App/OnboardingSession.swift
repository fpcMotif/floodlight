// periphery:ignore - Module import required for FloodlightEngine types.
import FloodlightEngine
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
    var blocklistVersion = 0

    var blocklistRules: [BlocklistRule] {
        _ = blocklistVersion
        return blocklistStore.rules
    }

    var offersSpotlightReplacement: Bool {
        activeShortcut != .commandSpace
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let fullDiskAccessProvider: () -> Bool
    @ObservationIgnored
    private let blocklistStore: BlocklistStore
    init(
        activeShortcut: FloodlightShortcut?,
        launchesAtLogin: Bool,
        rootURL: URL,
        defaults: UserDefaults = .standard,
        blocklistStore: BlocklistStore = BlocklistStore(),
        fullDiskAccessProvider: @escaping () -> Bool = {
            FloodlightFullDiskAccess.isGranted()
        }
    ) {
        self.activeShortcut = activeShortcut
        self.launchesAtLogin = launchesAtLogin
        self.rootURL = rootURL
        self.defaults = defaults
        self.blocklistStore = blocklistStore
        self.fullDiskAccessProvider = fullDiskAccessProvider
        hasFullDiskAccess = fullDiskAccessProvider()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = fullDiskAccessProvider()
    }

    func blockItem(name: String) {
        blocklistStore.block(name: name)
        blocklistVersion += 1
    }

    func unblockRule(_ rule: BlocklistRule) {
        switch rule {
        case let .name(name):
            blocklistStore.unblock(name: name)
        case let .id(id):
            blocklistStore.unblock(id: id)
        }
        blocklistVersion += 1
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
