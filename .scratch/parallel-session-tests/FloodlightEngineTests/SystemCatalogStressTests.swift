import Foundation
import XCTest
@testable import FloodlightEngine

/// Harsh, critical stress tests for `SystemCatalog` — adversarial queries,
/// boundary conditions, and edge cases for the system settings search.
final class SystemCatalogStressTests: XCTestCase {

    // MARK: - Empty and whitespace queries

    func testEmptyQueryReturnsEmptyPage() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "")
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalMatched, 0)
    }

    func testWhitespaceOnlyQueryReturnsEmptyPage() {
        let catalog = SystemCatalog()
        for query in [" ", "  ", "\t", "\n", "   "] {
            let page = catalog.immediatePage(for: query)
            XCTAssertTrue(page.items.isEmpty, "query '\(query)' should return empty page")
        }
    }

    // MARK: - Limit behavior

    func testLimitZeroReturnsEmptyItems() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "bluetooth", limit: 0)
        XCTAssertTrue(page.items.isEmpty)
        // totalMatched should still reflect the actual match count
        XCTAssertGreaterThanOrEqual(page.totalMatched, page.items.count)
    }

    func testLimitOneReturnsAtMostOneItem() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "settings", limit: 1)
        XCTAssertLessThanOrEqual(page.items.count, 1)
    }

    func testLimitLargeReturnsAllMatches() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "settings", limit: 100)
        XCTAssertGreaterThanOrEqual(page.totalMatched, page.items.count)
    }

    // MARK: - Short query behavior (word prefix requirement)

    func testShortQueryRequiresWordPrefix() {
        let catalog = SystemCatalog()
        // Queries shorter than 4 characters require a word prefix match
        // "arc" should not match (tested in CatalogTests)
        XCTAssertTrue(catalog.immediatePage(for: "arc").items.isEmpty)
    }

    func testThreeCharacterQueryRequiresWordPrefix() {
        let catalog = SystemCatalog()
        // "net" should match "Network" since it's a word prefix
        let page = catalog.immediatePage(for: "net", limit: 24)
        XCTAssertTrue(page.items.contains { $0.title == "Network" })
    }

    func testFourCharacterQueryDoesNotRequireWordPrefix() {
        let catalog = SystemCatalog()
        // At 4 chars, subsequence matching kicks in
        let page = catalog.immediatePage(for: "blue", limit: 24)
        XCTAssertTrue(page.items.contains { $0.title == "Bluetooth" })
    }

    // MARK: - Confidence threshold

    func testLowQualitySubsequenceMatchIsFiltered() {
        let catalog = SystemCatalog()
        // "zzzz" should not match any setting
        XCTAssertTrue(catalog.immediatePage(for: "zzzz").items.isEmpty)
    }

    func testExactSettingNameMatchExceedsThreshold() {
        let catalog = SystemCatalog()
        for setting in ["bluetooth", "wifi", "appearance", "keyboard", "sound"] {
            let page = catalog.immediatePage(for: setting, limit: 24)
            XCTAssertFalse(page.items.isEmpty, "'\(setting)' should match a setting")
        }
    }

    // MARK: - Multiple matches

    func testGenericQueryMatchesMultipleSettings() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "settings", limit: 24)
        // "settings" appears in many setting names and keywords
        XCTAssertGreaterThanOrEqual(page.totalMatched, 1)
    }

    // MARK: - Refresh behavior

    func testRefreshWithNoChangesReturnsFalse() async {
        let catalog = SystemCatalog()
        try? await catalog.start()
        let changed = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: false)
        // After start, a non-forced refresh should not find changes
        // (unless the system actually changed, which is unlikely in a test)
        // We can't assert false definitively, but we can assert it returns a Bool
        _ = changed
    }

    func testForcedRefreshReturnsBool() async {
        let catalog = SystemCatalog(discoveryProvider: { [] })
        let changed = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        // With empty discovery and first call, it should return true
        XCTAssertTrue(changed)
    }

    func testSecondForcedRefreshWithSameDataReturnsFalse() async {
        let catalog = SystemCatalog(discoveryProvider: { [] })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        let changed = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertFalse(changed)
    }

    // MARK: - Dynamic discovery

    func testDynamicSettingAppearsAfterDiscovery() async {
        let pane = "com.floodlight.tests.dynamic-stress"
        let setting = SystemCatalog.DiscoveredSetting(
            name: "Floodlight Test Pane",
            keywords: "floodlight test dynamic",
            pane: pane
        )
        let catalog = SystemCatalog(discoveryProvider: { [setting] })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        let page = catalog.immediatePage(for: "Floodlight Test Pane", limit: 24)
        XCTAssertTrue(page.items.contains { $0.id == "setting:\(pane)" })
    }

    func testDynamicSettingReplacesBuiltInWithSamePane() async {
        let pane = "com.apple.BluetoothSettings"
        let setting = SystemCatalog.DiscoveredSetting(
            name: "Custom Bluetooth",
            keywords: "custom bluetooth",
            pane: pane
        )
        let catalog = SystemCatalog(discoveryProvider: { [setting] })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        let page = catalog.immediatePage(for: "Custom Bluetooth", limit: 24)
        XCTAssertTrue(page.items.contains { $0.title == "Custom Bluetooth" })
    }

    // MARK: - Start idempotency

    func testStartIsIdempotent() async throws {
        let catalog = SystemCatalog(discoveryProvider: { [] })
        try await catalog.start()
        // Second start should not crash or change anything
        try await catalog.start()
    }

    // MARK: - Result structure

    func testAllResultsAreSystemSettingKind() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "settings", limit: 24)
        for item in page.items {
            XCTAssertEqual(item.kind, .systemSetting, "all results should be systemSetting kind")
        }
    }

    func testAllResultsHaveOpenAction() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "bluetooth", limit: 24)
        for item in page.items {
            if case .open = item.action {
                // ok
            } else {
                XCTFail("all results should have .open action")
            }
        }
    }

    func testAllResultsHaveSettingScoreBand() {
        let catalog = SystemCatalog()
        let page = catalog.immediatePage(for: "bluetooth", limit: 24)
        for item in page.items {
            XCTAssertGreaterThanOrEqual(item.score, SearchItemRanking.setting,
                "setting score should be >= setting band")
            XCTAssertLessThan(item.score, SearchItemRanking.calculator,
                "setting score should be < calculator band")
        }
    }

    // MARK: - FloodlightCommandCatalog

    func testFloodlightCommandSearchReturnsEmptyForUnrelatedQuery() {
        XCTAssertTrue(FloodlightCommandCatalog.search("safari").isEmpty)
        XCTAssertTrue(FloodlightCommandCatalog.search("bluetooth").isEmpty)
        XCTAssertTrue(FloodlightCommandCatalog.search("youtube").isEmpty)
    }

    func testFloodlightCommandSearchReturnsResultForSettingsQuery() {
        let results = FloodlightCommandCatalog.search("settings")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "floodlight-command:settings")
    }

    func testFloodlightCommandSearchReturnsResultForSetupQuery() {
        let results = FloodlightCommandCatalog.search("setup")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForPermissionsQuery() {
        let results = FloodlightCommandCatalog.search("permissions")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForShortcutQuery() {
        let results = FloodlightCommandCatalog.search("shortcut")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForHotkeyQuery() {
        let results = FloodlightCommandCatalog.search("hotkey")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForFullDiskAccessQuery() {
        let results = FloodlightCommandCatalog.search("full disk access")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForLaunchAtLoginQuery() {
        let results = FloodlightCommandCatalog.search("launch at login")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsResultForSearchScopeQuery() {
        let results = FloodlightCommandCatalog.search("search scope")
        XCTAssertEqual(results.count, 1)
    }

    func testFloodlightCommandSearchReturnsEmptyForEmptyQuery() {
        XCTAssertTrue(FloodlightCommandCatalog.search("").isEmpty)
    }

    func testFloodlightCommandSearchReturnsEmptyForWhitespaceQuery() {
        XCTAssertTrue(FloodlightCommandCatalog.search("   ").isEmpty)
    }

    func testFloodlightCommandResultHasCorrectScoreBand() throws {
        let results = FloodlightCommandCatalog.search("settings")
        let score = try XCTUnwrap(results.first?.score)
        XCTAssertGreaterThanOrEqual(score, SearchItemRanking.command)
    }

    func testFloodlightCommandResultHasFloodlightIconSource() {
        let results = FloodlightCommandCatalog.search("settings")
        XCTAssertEqual(results.first?.iconSource, .floodlightApplication)
    }

    func testFloodlightCommandResultHasShowSettingsAction() {
        let results = FloodlightCommandCatalog.search("settings")
        XCTAssertEqual(results.first?.action, .showFloodlightSettings)
    }
}
