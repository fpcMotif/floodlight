import Foundation
import XCTest
@testable import FloodlightEngine

private final class ApplicationDiscoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var applications: [(name: String, url: URL)]

    init(_ applications: [(name: String, url: URL)]) {
        self.applications = applications
    }

    func snapshot() -> [(name: String, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return applications
    }

    func replace(with applications: [(name: String, url: URL)]) {
        lock.lock()
        self.applications = applications
        lock.unlock()
    }
}

private final class SystemSettingsDiscoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [SystemCatalog.DiscoveredSetting]

    init(_ settings: [SystemCatalog.DiscoveredSetting]) {
        self.settings = settings
    }

    func snapshot() -> [SystemCatalog.DiscoveredSetting] {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func replace(with settings: [SystemCatalog.DiscoveredSetting]) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }
}

final class CatalogTests: XCTestCase {
    func testDiscoversFinderAndUserFacingCoreServicesApplications() throws {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        guard FileManager.default.fileExists(atPath: finderURL.path) else {
            throw XCTSkip("Finder is not installed at the standard path.")
        }

        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FloodlightCoreServicesTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL
        )

        let finder = catalog.immediatePage(for: "finder").items
        XCTAssertTrue(finder.contains { $0.fileURL == finderURL })

        let archiveUtilityURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app"
        )
        if FileManager.default.fileExists(atPath: archiveUtilityURL.path) {
            let archiveUtility = catalog.immediatePage(for: "archive utility").items
            XCTAssertTrue(archiveUtility.contains { $0.fileURL == archiveUtilityURL })
        }

        let dockAgentURL = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app")
        XCTAssertFalse(catalog.immediatePage(for: "dock").items
            .contains { $0.fileURL == dockAgentURL })
    }

    func testDiscoversSymlinkedSystemApplications() async throws {
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safariURL.path) else {
            throw XCTSkip("Safari is not installed at the standard path.")
        }

        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FloodlightCatalogTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL
        )
        try await catalog.start()
        let results = try await catalog.indexedItems(for: "safari")
        XCTAssertTrue(results.contains { $0.fileURL?.lastPathComponent == "Safari.app" })
        XCTAssertEqual(
            results.filter { $0.fileURL?.lastPathComponent == "Safari.app" }.count,
            1
        )
    }

    func testSystemSettingsAvoidLooseShortSubsequences() {
        let catalog = SystemCatalog()
        XCTAssertTrue(catalog.immediatePage(for: "arc").items.isEmpty)
        XCTAssertEqual(catalog.immediatePage(for: "bluetooth").items.first?.title, "Bluetooth")
    }

    func testFloodlightSettingsAreSearchableBySetupTerms() {
        for query in ["settings", "setup", "permissions", "shortcut", "search scope"] {
            let result = FloodlightCommandCatalog.search(query).first
            XCTAssertEqual(result?.id, "floodlight-command:settings", query)
            XCTAssertEqual(result?.action, .showFloodlightSettings, query)
            XCTAssertEqual(result?.iconSource, .floodlightApplication, query)
        }

        XCTAssertTrue(FloodlightCommandCatalog.search("claude").isEmpty)
    }

    func testFastApplicationSearchDoesNotWaitForFFF() throws {
        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FloodlightFastCatalogTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL
        )
        let start = ContinuousClock.now
        let page = catalog.immediatePage(for: "claude")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertGreaterThanOrEqual(page.totalMatched, page.items.count)
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            XCTAssertEqual(page.items.first?.fileURL?.lastPathComponent, "Claude.app")
        }
    }

    func testFastAndIndexedApplicationSearchAgreeOnScore() async throws {
        let suiteName = "FloodlightScoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightScoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let orbital = (
            name: "Orbital Launcher",
            url: URL(fileURLWithPath: "/Applications/Orbital Launcher.app", isDirectory: true)
        )
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL,
            deferDiscovery: true,
            discoveryProvider: { [orbital] }
        )
        try await catalog.start()

        for query in ["orbital", "launcher"] {
            try await assertEventually("The marker index did not return Orbital Launcher") {
                try await catalog.indexedItems(for: query).contains { $0.fileURL == orbital.url }
            }

            let fast = try XCTUnwrap(
                catalog.immediatePage(for: query).items.first { $0.fileURL == orbital.url },
                query
            )
            let indexed = try await catalog.indexedItems(for: query)
                .first { $0.fileURL == orbital.url }
            XCTAssertEqual(try XCTUnwrap(indexed, query).score, fast.score, query)
        }
    }

    func testRefreshTracksApplicationInstallRenameAndRemovalAfterStartup() async throws {
        let suiteName = "FloodlightRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FloodlightRefreshTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let notes = (
            name: "Notes",
            url: URL(fileURLWithPath: "/Applications/Notes.app", isDirectory: true)
        )
        let raycast = (
            name: "Raycast",
            url: URL(fileURLWithPath: "/Applications/Raycast.app", isDirectory: true)
        )
        let discovery = ApplicationDiscoveryFixture([notes])
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL,
            deferDiscovery: true,
            discoveryProvider: { discovery.snapshot() }
        )

        try await catalog.start()
        XCTAssertTrue(catalog.immediatePage(for: "raycast").items.isEmpty)

        discovery.replace(with: [notes, raycast])
        let didAddRaycast = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        XCTAssertTrue(didAddRaycast)
        XCTAssertEqual(catalog.immediatePage(for: "raycast").items.first?.fileURL, raycast.url)
        try await assertEventually("The application marker index did not add Raycast") {
            try await catalog.indexedItems(for: "raycast").contains { $0.fileURL == raycast.url }
        }

        let orbital = (
            name: "Orbital Launcher",
            url: URL(fileURLWithPath: "/Applications/Orbital Launcher.app", isDirectory: true)
        )
        discovery.replace(with: [notes, orbital])
        let didRenameRaycast = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        XCTAssertTrue(didRenameRaycast)
        XCTAssertFalse(catalog.immediatePage(for: "raycast").items
            .contains { $0.fileURL == raycast.url })
        XCTAssertEqual(
            catalog.immediatePage(for: "orbital launcher").items.first?.fileURL,
            orbital.url
        )
        try await assertEventually("The application marker index did not replace renamed Raycast") {
            let oldResults = try await catalog.indexedItems(for: "raycast")
            let newResults = try await catalog.indexedItems(for: "orbital launcher")
            return !oldResults.contains { $0.fileURL == raycast.url }
                && newResults.contains { $0.fileURL == orbital.url }
        }

        discovery.replace(with: [notes])
        let didRemoveOrbital = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        XCTAssertTrue(didRemoveOrbital)
        XCTAssertFalse(
            catalog.immediatePage(for: "orbital launcher").items
                .contains { $0.fileURL == orbital.url }
        )
        try await assertEventually("The application marker index did not remove Orbital") {
            try await catalog.indexedItems(for: "orbital launcher")
                .allSatisfy { $0.fileURL != orbital.url }
        }

        let didChangeAgain = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        XCTAssertFalse(didChangeAgain)
    }

    func testIndexesInstalledSystemSettings() async throws {
        let catalog = SystemCatalog()
        try await catalog.start()

        let appearance = catalog.immediatePage(for: "appearance", limit: 24)
        let wifi = catalog.immediatePage(for: "wifi", limit: 24)

        XCTAssertTrue(appearance.items.contains { $0.title == "Appearance" })
        XCTAssertTrue(wifi.items.contains { $0.title == "Wi-Fi" || $0.title == "Network" })
        XCTAssertGreaterThanOrEqual(appearance.totalMatched, appearance.items.count)
    }

    func testSystemSettingsRefreshTracksInstallRenameAndRemoval() async {
        let pane = "com.floodlight.tests.dynamic-settings"
        let aurora = SystemCatalog.DiscoveredSetting(
            name: "Aurora Controls",
            keywords: "floodlight dynamic fixture",
            pane: pane
        )
        let discovery = SystemSettingsDiscoveryFixture([aurora])
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })

        let didInstall = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didInstall)
        XCTAssertEqual(
            catalog.immediatePage(for: "Aurora Controls").items.first?.id,
            "setting:\(pane)"
        )

        let nebula = SystemCatalog.DiscoveredSetting(
            name: "Nebula Controls",
            keywords: "floodlight renamed fixture",
            pane: pane
        )
        discovery.replace(with: [nebula])
        let didRename = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didRename)
        XCTAssertFalse(
            catalog.immediatePage(for: "Aurora Controls").items
                .contains { $0.id == "setting:\(pane)" }
        )
        XCTAssertEqual(
            catalog.immediatePage(for: "Nebula Controls").items.first?.id,
            "setting:\(pane)"
        )

        discovery.replace(with: [])
        let didRemove = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didRemove)
        XCTAssertFalse(
            catalog.immediatePage(for: "Nebula Controls").items
                .contains { $0.id == "setting:\(pane)" }
        )
    }

    private func assertEventually(
        _ message: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail(message, file: file, line: line)
    }
}
