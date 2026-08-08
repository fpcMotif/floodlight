import FloodlightEngine
import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class SearchCoordinatorTests: XCTestCase {
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
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
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
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: Self.unmatchedQuery,
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        XCTAssertFalse(results.contains { $0.kind == .calculator })
    }

    func testEverySourceContributesToTheMergedResults() {
        let coordinator = SearchCoordinator()
        let app = makeApplication(name: "Shortcuts", score: 100_000)
        let setting = makeSetting(title: "Keyboard Shortcuts", score: 11_000)
        let file = makeIndexedFile(name: "shortcut-notes.txt", score: 500)

        let results = coordinator.buildResults(
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
        let coordinator = SearchCoordinator()
        let commandID = "floodlight-command:settings"
        let appsVersusSystemID = "collision:apps-versus-system"
        let systemVersusIndexedID = "collision:system-versus-indexed"

        let results = coordinator.buildResults(
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
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
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
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
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
            try .open(XCTUnwrap(URL(string: "https://www.google.com/search?q=shortcut")))
        )
    }

    func testEmptyQueryOmitsTheWebFallback() {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "",
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        XCTAssertFalse(results.contains { $0.kind == .web })
    }

    func testMergedResultsTruncateToEightyRows() {
        let coordinator = SearchCoordinator()
        let indexed = (0..<100).map { index in
            makeIndexedFile(name: "file-\(index).txt", score: 1_000 - index)
        }

        let results = coordinator.buildResults(
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

    func testSelectingAFilterNarrowsPublishedResults() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"

        XCTAssertTrue(coordinator.results.contains { $0.kind == .web })
        XCTAssertTrue(coordinator.results.contains { $0.id == "floodlight-command:settings" })

        coordinator.selectFilter(.settings)

        XCTAssertFalse(coordinator.results.isEmpty)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })
        XCTAssertFalse(coordinator.results.contains { $0.kind == .web })
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)

        // No source feeding this query can produce a folder, so the filter has
        // nothing to show and the selection clears with it.
        coordinator.selectFilter(.folders)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    func testApplySelectedFilterReconcilesSelectionWithVisibleResults() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        let unfiltered = coordinator.results
        XCTAssertGreaterThan(unfiltered.count, 1)

        coordinator.selectedID = unfiltered.last?.id
        coordinator.applySelectedFilter(resetSelection: false)

        XCTAssertEqual(coordinator.selectedID, unfiltered.last?.id)

        coordinator.applySelectedFilter(resetSelection: true)

        XCTAssertEqual(coordinator.selectedID, unfiltered.first?.id)

        coordinator.selectFilter(.settings)
        let visible = coordinator.results
        XCTAssertFalse(visible.isEmpty)
        XCTAssertFalse(visible.contains { $0.id == "web-search" })

        coordinator.selectedID = "web-search"
        coordinator.applySelectedFilter(resetSelection: false)

        XCTAssertEqual(coordinator.results.map(\.id), visible.map(\.id))
        XCTAssertEqual(coordinator.selectedID, visible.first?.id)
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
