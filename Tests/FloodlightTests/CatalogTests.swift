import Foundation
import XCTest
@testable import Floodlight

final class CatalogTests: XCTestCase {
    func testDiscoversSymlinkedSystemApplications() async throws {
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safariURL.path) else {
            throw XCTSkip("Safari is not installed at the standard path.")
        }

        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL
        )
        try await catalog.start()
        let results = try await catalog.search("safari")
        XCTAssertTrue(results.contains { $0.fileURL?.lastPathComponent == "Safari.app" })
    }

    func testSystemSettingsAvoidLooseShortSubsequences() {
        XCTAssertTrue(SystemCatalog.search("arc").isEmpty)
        XCTAssertEqual(SystemCatalog.search("bluetooth").first?.title, "Bluetooth")
    }

    func testFastApplicationSearchDoesNotWaitForFFF() throws {
        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightFastCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            supportURL: supportURL
        )
        let start = ContinuousClock.now
        let page = catalog.fastSearchPage("claude")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertGreaterThanOrEqual(page.totalMatched, page.items.count)
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            XCTAssertEqual(page.items.first?.fileURL?.lastPathComponent, "Claude.app")
        }
    }

    func testIndexesInstalledSystemSettings() async {
        await SystemCatalog.start()

        let appearance = SystemCatalog.searchPage("appearance", limit: 24)
        let wifi = SystemCatalog.searchPage("wifi", limit: 24)

        XCTAssertTrue(appearance.items.contains { $0.title == "Appearance" })
        XCTAssertTrue(wifi.items.contains { $0.title == "Wi-Fi" || $0.title == "Network" })
        XCTAssertGreaterThanOrEqual(appearance.totalMatched, appearance.items.count)
    }
}
