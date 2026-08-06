import Foundation
import XCTest
@testable import Floodlight

/// A catalog that answers from a fixed list, so a coordinator under test has
/// deterministic sources instead of whatever this machine happens to have
/// installed.
private struct StubCatalog: Catalog {
    var items: [SearchItem] = []

    func start() async throws {}

    func refreshIfNeeded(minimumInterval: TimeInterval, forceDiscovery: Bool) async throws -> Bool {
        false
    }

    func immediatePage(for query: String, limit: Int) -> SearchItemPage {
        SearchItemRanking.page(items, limit: limit)
    }
}

@MainActor
final class SearchCoordinatorTests: XCTestCase {
    /// A coordinator over stub catalogs and a scratch index.
    private func makeCoordinator(
        apps: [SearchItem] = [],
        settings: [SearchItem] = []
    ) throws -> SearchCoordinator {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        let suiteName = "FloodlightCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        return SearchCoordinator(
            index: FFFIndex(
                rootURL: scratch,
                storageURL: scratch.appendingPathComponent("Database", isDirectory: true),
                watch: false
            ),
            applicationCatalog: StubCatalog(items: apps),
            settingsCatalog: StubCatalog(items: settings),
            recentStore: RecentStore(defaults: defaults),
            rootURL: scratch
        )
    }

    func testRealResultReplacesAutomaticWebFallbackSelection() {
        let folder = makeFolder()
        let web = makeWebResult()

        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: web.id,
                results: [folder, web],
                resetSelection: false,
                promoteWebFallback: true
            ),
            folder.id
        )
    }

    func testUserSelectedWebFallbackRemainsSelected() {
        let folder = makeFolder()
        let web = makeWebResult()

        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: web.id,
                results: [folder, web],
                resetSelection: false,
                promoteWebFallback: false
            ),
            web.id
        )
    }

    func testCalculatorAnswerLeadsResultsForAnExpression() throws {
        let results = SearchResultMerge.merge(
            query: "12 * 12",
            indexed: [makeIndexedFile(name: "budget.numbers", score: 5_000)],
            apps: [makeApplication(name: "Calculator", score: 99_000)],
            system: [makeSetting(title: "Keyboard", score: 11_000)]
        )

        let answer = try XCTUnwrap(results.first)
        XCTAssertEqual(answer.id, "calculator")
        XCTAssertEqual(answer.kind, .calculator)
        XCTAssertEqual(answer.title, "144")
        XCTAssertEqual(answer.action, .copy("144"))
    }

    func testQueriesThatAreNotExpressionsSkipTheCalculator() {
        let results = SearchResultMerge.merge(
            query: Self.unmatchedQuery,
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        XCTAssertFalse(results.contains { $0.kind == .calculator })
    }

    func testEverySourceContributesToTheMergedResults() {
        let app = makeApplication(name: "Shortcuts", score: 100_000)
        let setting = makeSetting(title: "Keyboard Shortcuts", score: 11_000)
        let file = makeIndexedFile(name: "shortcut-notes.txt", score: 500)

        let results = SearchResultMerge.merge(
            query: "shortcut",
            indexed: [file],
            apps: [app],
            system: [setting]
        )

        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains("floodlight-command:settings"))
        XCTAssertTrue(ids.contains(app.id))
        XCTAssertTrue(ids.contains(setting.id))
        XCTAssertTrue(ids.contains(file.id))
        XCTAssertTrue(ids.contains("web-search"))
    }

    func testEarlierSourcesWinWhenIdentifiersCollide() throws {
        let commandID = "floodlight-command:settings"
        let appsVersusSystemID = "collision:apps-versus-system"
        let systemVersusIndexedID = "collision:system-versus-indexed"

        let results = SearchResultMerge.merge(
            query: "shortcut",
            indexed: [
                makeIndexedFile(
                    id: systemVersusIndexedID,
                    name: "From indexed",
                    score: 900_000
                ),
            ],
            apps: [
                makeApplication(id: commandID, name: "From apps", score: 900_000),
                makeApplication(id: appsVersusSystemID, name: "From apps", score: 10),
            ],
            system: [
                makeSetting(id: appsVersusSystemID, title: "From system", score: 900_000),
                makeSetting(id: systemVersusIndexedID, title: "From system", score: 20),
            ]
        )

        XCTAssertEqual(results.count, Set(results.map(\.id)).count)

        let command = try XCTUnwrap(results.first { $0.id == commandID })
        XCTAssertEqual(command.title, "Floodlight settings")

        let appsWin = try XCTUnwrap(results.first { $0.id == appsVersusSystemID })
        XCTAssertEqual(appsWin.title, "From apps")
        XCTAssertEqual(appsWin.score, 10)

        let systemWin = try XCTUnwrap(results.first { $0.id == systemVersusIndexedID })
        XCTAssertEqual(systemWin.title, "From system")
        XCTAssertEqual(systemWin.score, 20)
    }

    func testResultsSortByScoreThenNaturalTitleOrder() {
        let results = SearchResultMerge.merge(
            query: Self.unmatchedQuery,
            indexed: [
                makeIndexedFile(name: "Result 10", score: 5),
                makeIndexedFile(name: "Result 9", score: 5),
                makeIndexedFile(name: "Result 2", score: 5),
                makeIndexedFile(name: "Alpha", score: 50),
            ],
            apps: [],
            system: []
        )

        XCTAssertEqual(
            results.prefix(4).map(\.title),
            ["Alpha", "Result 2", "Result 9", "Result 10"]
        )
    }

    func testWebFallbackTrailsResultsWithTheLowestScore() throws {
        let results = SearchResultMerge.merge(
            query: "shortcut",
            indexed: [makeIndexedFile(name: "shortcut-notes.txt", score: 500)],
            apps: [],
            system: []
        )

        let fallback = try XCTUnwrap(results.last)
        XCTAssertEqual(fallback.id, "web-search")
        XCTAssertEqual(fallback.kind, .web)
        XCTAssertEqual(fallback.score, .min)
        XCTAssertEqual(
            fallback.action,
            .open(URL(string: "https://www.google.com/search?q=shortcut")!)
        )
    }

    func testEmptyQueryOmitsTheWebFallback() {
        let results = SearchResultMerge.merge(
            query: "",
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        XCTAssertFalse(results.contains { $0.kind == .web })
    }

    func testMergedResultsTruncateToEightyRows() {
        let indexed = (0..<100).map { index in
            makeIndexedFile(name: "file-\(index).txt", score: 1_000 - index)
        }

        let results = SearchResultMerge.merge(
            query: Self.unmatchedQuery,
            indexed: indexed,
            apps: [],
            system: []
        )

        XCTAssertEqual(results.count, 80)
        XCTAssertEqual(results.first?.score, 1_000)
        XCTAssertEqual(results.last?.score, 921)
        XCTAssertFalse(results.contains { $0.kind == .web })
    }

    func testSelectingAFilterNarrowsPublishedResults() throws {
        let setting = makeSetting(title: "Keyboard Shortcuts", score: 11_000)
        let coordinator = try makeCoordinator(settings: [setting])
        coordinator.query = "shortcut"

        XCTAssertTrue(coordinator.results.contains { $0.kind == .web })
        XCTAssertTrue(coordinator.results.contains { $0.id == "floodlight-command:settings" })

        coordinator.selectFilter(.settings)

        XCTAssertTrue(coordinator.results.contains { $0.id == setting.id })
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })
        XCTAssertFalse(coordinator.results.contains { $0.kind == .web })
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)

        // No source feeding this query can produce a folder, so the filter has
        // nothing to show and the selection clears with it.
        coordinator.selectFilter(.folders)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    func testFilteringReconcilesSelectionWithVisibleResults() throws {
        let setting = makeSetting(title: "Keyboard Shortcuts", score: 11_000)
        let coordinator = try makeCoordinator(settings: [setting])
        coordinator.query = "shortcut"

        let unfiltered = coordinator.results
        XCTAssertGreaterThan(unfiltered.count, 1)
        XCTAssertEqual(coordinator.selectedID, unfiltered.first?.id)

        // A selection the user moved to stays put while it remains visible.
        coordinator.moveSelection(by: 1)
        XCTAssertEqual(coordinator.selectedID, unfiltered[1].id)

        // Filtering that selection away falls back to the first visible row.
        coordinator.selectFilter(.settings)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)

        // Returning to All restores the full list and selects its head.
        coordinator.selectFilter(.all)
        XCTAssertEqual(coordinator.results.map(\.id), unfiltered.map(\.id))
        XCTAssertEqual(coordinator.selectedID, unfiltered.first?.id)
    }

    /// A query the calculator cannot evaluate and whose characters never appear
    /// in the Floodlight command catalog, so only the supplied fixtures merge.
    private static let unmatchedQuery = "zzzzz"

    private func makeFolder() -> SearchItem {
        let url = URL(fileURLWithPath: "/Users/example/code", isDirectory: true)
        return SearchItem(
            id: "folder:\(url.path)",
            title: "code",
            subtitle: "code",
            kind: .folder,
            action: .open(url),
            score: 300_000,
            fileURL: url
        )
    }

    private func makeWebResult() -> SearchItem {
        SearchItem(
            id: "web-search",
            title: "Search the Web",
            subtitle: "Open in your default browser",
            kind: .web,
            action: .open(URL(string: "https://example.com")!),
            score: Int.min
        )
    }

    private func makeIndexedFile(id: String? = nil, name: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/Users/example/code/\(name)")
        return SearchItem(
            id: id ?? "file:\(url.path)",
            title: name,
            subtitle: "code/\(name)",
            kind: .file,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }

    private func makeApplication(id: String? = nil, name: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
        return SearchItem(
            id: id ?? "application:\(url.path)",
            title: name,
            subtitle: "Applications",
            kind: .application,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }

    private func makeSetting(id: String? = nil, title: String, score: Int) -> SearchItem {
        SearchItem(
            id: id ?? "setting:\(title)",
            title: title,
            subtitle: "System Settings",
            kind: .systemSetting,
            action: .open(URL(string: "x-apple.systempreferences:com.apple.\(title)")!),
            score: score
        )
    }
}
