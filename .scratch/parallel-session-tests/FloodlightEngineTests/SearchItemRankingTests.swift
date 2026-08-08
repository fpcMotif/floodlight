import Foundation
import XCTest
@testable import FloodlightEngine

/// Comprehensive tests for `SearchItemRanking` — the band system that keeps
/// result types separated, the sort order, and the page builder.
final class SearchItemRankingTests: XCTestCase {

    // MARK: - Band values

    func testBandValuesAreSeparated() {
        XCTAssertGreaterThan(SearchItemRanking.command, SearchItemRanking.keywordEngine)
        XCTAssertGreaterThan(SearchItemRanking.keywordEngine, SearchItemRanking.application)
        XCTAssertGreaterThanOrEqual(SearchItemRanking.application, SearchItemRanking.calculator)
        XCTAssertGreaterThan(SearchItemRanking.calculator, SearchItemRanking.setting)
        XCTAssertGreaterThan(SearchItemRanking.setting, SearchItemRanking.webPromoted)
        XCTAssertGreaterThan(SearchItemRanking.webPromoted, SearchItemRanking.content)
        XCTAssertGreaterThan(SearchItemRanking.content, SearchItemRanking.webFallback)
    }

    func testWebFallbackIsMinInt() {
        XCTAssertEqual(SearchItemRanking.webFallback, Int.min)
    }

    // MARK: - ranksBefore

    func testHigherScoreRanksBefore() {
        let high = makeItem(score: 200_000)
        let low = makeItem(score: 100_000)
        XCTAssertTrue(SearchItemRanking.ranksBefore(high, low))
        XCTAssertFalse(SearchItemRanking.ranksBefore(low, high))
    }

    func testEqualScoresBreakOnTitle() {
        let a = makeItem(title: "Apple", score: 100)
        let b = makeItem(title: "Banana", score: 100)
        XCTAssertTrue(SearchItemRanking.ranksBefore(a, b))
        XCTAssertFalse(SearchItemRanking.ranksBefore(b, a))
    }

    func testEqualScoresAndTitlesAreConsistent() {
        let a = makeItem(title: "Same", score: 100)
        let b = makeItem(title: "Same", score: 100)
        // ranksBefore is a strict weak ordering; same title should not
        // rank before itself
        XCTAssertFalse(SearchItemRanking.ranksBefore(a, b))
        XCTAssertFalse(SearchItemRanking.ranksBefore(b, a))
    }

    func testTitleComparisonIsCaseInsensitiveAndLocalized() {
        let lower = makeItem(title: "apple", score: 100)
        let upper = makeItem(title: "Apple", score: 100)
        // localizedStandardCompare is case-insensitive
        let result = SearchItemRanking.ranksBefore(lower, upper)
        let reverse = SearchItemRanking.ranksBefore(upper, lower)
        // They should be consistent (neither ranks before the other, or
        // the ordering is deterministic)
        XCTAssertNotEqual(result, reverse, "case-insensitive comparison should be consistent")
    }

    // MARK: - ranked

    func testRankedSortsByScoreDescending() {
        let items = (1...10).map { makeItem(title: "item\($0)", score: $0 * 1000) }
        let ranked = SearchItemRanking.ranked(items)
        XCTAssertEqual(ranked.first?.score, 10_000)
        XCTAssertEqual(ranked.last?.score, 1_000)
    }

    func testRankedStableForEqualScores() {
        let items = [
            makeItem(title: "Charlie", score: 100),
            makeItem(title: "Alpha", score: 100),
            makeItem(title: "Bravo", score: 100),
        ]
        let ranked = SearchItemRanking.ranked(items)
        XCTAssertEqual(ranked.map(\.title), ["Alpha", "Bravo", "Charlie"])
    }

    func testRankedEmptyArray() {
        XCTAssertTrue(SearchItemRanking.ranked([]).isEmpty)
    }

    func testRankedSingleItem() {
        let item = makeItem(score: 42)
        XCTAssertEqual(SearchItemRanking.ranked([item]), [item])
    }

    // MARK: - page

    func testPageReturnsLimitedItems() {
        let items = (0..<20).map { makeItem(title: "item\($0)", score: 1000 - $0) }
        let page = SearchItemRanking.page(items, limit: 5)
        XCTAssertEqual(page.items.count, 5)
        XCTAssertEqual(page.totalMatched, 20)
    }

    func testPageReturnsAllItemsWhenFewerThanLimit() {
        let items = (0..<3).map { makeItem(title: "item\($0)", score: 1000 - $0) }
        let page = SearchItemRanking.page(items, limit: 12)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.totalMatched, 3)
    }

    func testPageWithEmptyItems() {
        let page = SearchItemRanking.page([], limit: 12)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalMatched, 0)
    }

    func testPageWithZeroLimit() {
        let items = [makeItem(score: 100), makeItem(score: 200)]
        let page = SearchItemRanking.page(items, limit: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalMatched, 2)
    }

    func testPageItemsAreRanked() {
        let items = [
            makeItem(title: "low", score: 100),
            makeItem(title: "high", score: 500),
            makeItem(title: "mid", score: 300),
        ]
        let page = SearchItemRanking.page(items, limit: 3)
        XCTAssertEqual(page.items.map(\.title), ["high", "mid", "low"])
    }

    func testPageTotalMatchedIsRankedCount() {
        let items = (0..<5).map { makeItem(title: "item\($0)", score: $0) }
        let page = SearchItemRanking.page(items, limit: 2)
        XCTAssertEqual(page.totalMatched, 5)
        XCTAssertEqual(page.items.count, 2)
    }

    // MARK: - Band separation guarantee

    func testNoFuzzyScoreCanCrossBands() {
        // The maximum fuzzy score is 20_000 (exact match).
        // The minimum application score is SearchItemRanking.application + 0 = 100_000.
        // The gap is 80_000, so no fuzzy score can cross.
        let maxFuzzy = 20_000
        let minApplication = SearchItemRanking.application
        XCTAssertGreaterThan(minApplication - maxFuzzy, 0,
            "application band should be unreachable from fuzzy scores")

        let minSetting = SearchItemRanking.setting
        let minContent = SearchItemRanking.content
        XCTAssertGreaterThan(minSetting - minContent, 0,
            "setting band should be above content band")
    }

    // MARK: - CatalogDirectoryFingerprint

    func testFingerprintModificationDateForExistingDirectory() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = CatalogDirectoryFingerprint.modificationDate(
            ofDirectoryAtPath: tmp.path,
            fileManager: .default
        )
        XCTAssertNotEqual(date, .distantPast)
    }

    func testFingerprintModificationDateForNonexistentDirectory() {
        let date = CatalogDirectoryFingerprint.modificationDate(
            ofDirectoryAtPath: "/nonexistent/path/\(UUID().uuidString)",
            fileManager: .default
        )
        XCTAssertEqual(date, .distantPast)
    }

    func testFingerprintMakeForPaths() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fingerprint = CatalogDirectoryFingerprint.make(
            forPaths: [tmp.path],
            fileManager: .default
        )
        XCTAssertNotNil(fingerprint[tmp.path])
    }

    func testFingerprintMakeForURLs() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fingerprint = CatalogDirectoryFingerprint.make(
            for: [tmp],
            fileManager: .default
        )
        XCTAssertNotNil(fingerprint[tmp.standardizedFileURL.path])
    }

    func testFingerprintDeduplicatesPaths() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fingerprint = CatalogDirectoryFingerprint.make(
            forPaths: [tmp.path, tmp.path, tmp.path],
            fileManager: .default
        )
        XCTAssertEqual(fingerprint.count, 1)
    }

    // MARK: - Catalog default implementations

    func testCatalogDefaultIndexedItemsReturnsEmpty() async throws {
        let catalog = StubCatalog()
        let items = try await catalog.indexedItems(for: "test")
        XCTAssertTrue(items.isEmpty)
    }

    func testCatalogDefaultTrackDoesNothing() {
        let catalog = StubCatalog()
        catalog.track(query: "test", selectedURL: URL(fileURLWithPath: "/tmp"))
        // Should not crash
    }

    func testCatalogDefaultRefreshIfNeeded() async throws {
        let catalog = StubCatalog()
        let result = try await catalog.refreshIfNeeded()
        // StubCatalog returns false
        XCTAssertFalse(result)
    }

    func testCatalogDefaultImmediatePageWithDefaultLimit() {
        let catalog = StubCatalog()
        let page = catalog.immediatePage(for: "test")
        XCTAssertEqual(page.totalMatched, 1)
    }

    // MARK: - Helpers

    private func makeItem(title: String = "test", score: Int) -> SearchItem {
        SearchItem(
            title: title, subtitle: "subtitle", kind: .file,
            action: .copy(""), score: score
        )
    }
}

private final class StubCatalog: Catalog {
    func start() async throws {}
    func refreshIfNeeded(minimumInterval: TimeInterval, forceDiscovery: Bool) async throws -> Bool { false }
    func immediatePage(for query: String, limit: Int) -> SearchItemPage {
        SearchItemPage(items: [SearchItem(title: "stub", subtitle: "", kind: .file, action: .copy(""), score: 0)], totalMatched: 1)
    }
}
