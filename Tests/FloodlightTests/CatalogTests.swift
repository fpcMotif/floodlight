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
}
