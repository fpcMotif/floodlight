import FloodlightEngine
import Foundation
import XCTest
@testable import Floodlight

/// Harsh, critical stress tests for `SearchCoordinator` — adversarial
/// inputs, boundary conditions, and edge cases for the search coordinator.
@MainActor
final class SearchCoordinatorStressTests: XCTestCase {

    // MARK: - moveSelection

    func testMoveSelectionDownThenUp() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        XCTAssertGreaterThan(coordinator.results.count, 1)

        let firstID = coordinator.selectedID
        coordinator.moveSelection(by: 1)
        XCTAssertNotEqual(coordinator.selectedID, firstID)

        coordinator.moveSelection(by: -1)
        XCTAssertEqual(coordinator.selectedID, firstID)
    }

    func testMoveSelectionClampsAtTopAndBottom() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        XCTAssertGreaterThan(coordinator.results.count, 0)

        // Move way up — should clamp at 0
        coordinator.moveSelection(by: -100)
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)

        // Move way down — should clamp at last
        coordinator.moveSelection(by: 100)
        XCTAssertEqual(coordinator.selectedID, coordinator.results.last?.id)
    }

    func testMoveSelectionOnEmptyResultsDoesNothing() {
        let coordinator = SearchCoordinator()
        coordinator.query = "zzzzzzzzzzzzz"
        XCTAssertTrue(coordinator.results.isEmpty)
        coordinator.moveSelection(by: 1)
        XCTAssertNil(coordinator.selectedID)
    }

    func testMoveSelectionByZeroStaysPut() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        let currentID = coordinator.selectedID
        coordinator.moveSelection(by: 0)
        XCTAssertEqual(coordinator.selectedID, currentID)
    }

    // MARK: - reset

    func testResetClearsAllState() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        XCTAssertFalse(coordinator.results.isEmpty)
        XCTAssertFalse(coordinator.query.isEmpty)
        XCTAssertNotNil(coordinator.selectedID)

        coordinator.reset()

        XCTAssertTrue(coordinator.query.isEmpty)
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertFalse(coordinator.isSearching)
        XCTAssertEqual(coordinator.selectedFilter, .all)
    }

    func testResetIsIdempotent() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        coordinator.reset()
        coordinator.reset()
        XCTAssertTrue(coordinator.query.isEmpty)
        XCTAssertTrue(coordinator.results.isEmpty)
    }

    // MARK: - selectFilter

    func testSelectFilterChangesSelectedFilter() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        XCTAssertEqual(coordinator.selectedFilter, .all)

        coordinator.selectFilter(.settings)
        XCTAssertEqual(coordinator.selectedFilter, .settings)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })
    }

    func testSelectSameFilterIncrementsFocusGeneration() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        let genBefore = coordinator.focusGeneration

        coordinator.selectFilter(.all)
        XCTAssertEqual(coordinator.focusGeneration, genBefore + 1)
    }

    func testSelectFilterToEmptyFilterClearsSelection() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        coordinator.selectFilter(.folders)
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    // MARK: - select

    func testSelectSetsSelectedID() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            return XCTFail("expected results")
        }
        coordinator.select(item)
        XCTAssertEqual(coordinator.selectedID, item.id)
    }

    func testSelectingNilDoesNotCrash() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        // Selecting an item that's not in results should still set the ID
        let fakeItem = SearchItem(
            title: "fake", subtitle: "", kind: .file,
            action: .copy(""), score: 0
        )
        coordinator.select(fakeItem)
        XCTAssertEqual(coordinator.selectedID, fakeItem.id)
    }

    // MARK: - copySelection

    func testCopySelectionWithFileURL() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"

        // Find a result with a file URL
        guard let item = coordinator.results.first(where: { $0.fileURL != nil }) else {
            return XCTSkip("no file URL result available")
        }
        coordinator.select(item)
        coordinator.copySelection()

        let pasteboard = NSPasteboard.general
        let copied = pasteboard.string(forType: .string)
        XCTAssertNotNil(copied)
    }

    func testCopySelectionWithNoSelectionDoesNothing() {
        let coordinator = SearchCoordinator()
        coordinator.query = "zzzzzzzzz"
        coordinator.copySelection()
        // Should not crash
    }

    // MARK: - previewableSelectionURL

    func testPreviewableSelectionURLIsNilForNonFileSelection() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        // The first result is likely a command or web result, not a file
        if let item = coordinator.results.first, item.kind != .file {
            coordinator.select(item)
            XCTAssertNil(coordinator.previewableSelectionURL)
        }
    }

    func testPreviewableSelectionURLIsNilWhenNoSelection() {
        let coordinator = SearchCoordinator()
        coordinator.query = "zzzzzzzzz"
        XCTAssertNil(coordinator.previewableSelectionURL)
    }

    // MARK: - assistantAnswerState

    func testAssistantAnswerStateReturnsNilForNonMatchingItem() {
        let coordinator = SearchCoordinator()
        let item = SearchItem(
            title: "test", subtitle: "", kind: .file,
            action: .copy(""), score: 0
        )
        XCTAssertNil(coordinator.assistantAnswerState(for: item))
    }

    func testAssistantAnswerStateReturnsNilWhenNoRunExists() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            return XCTFail("expected results")
        }
        XCTAssertNil(coordinator.assistantAnswerState(for: item))
    }

    // MARK: - buildResults edge cases

    func testBuildResultsWithAllEmptySources() {
        let coordinator = SearchCoordinator()
        let results = coordinator.buildResults(
            query: "test",
            indexed: [],
            apps: [],
            system: []
        )
        // Should still have the web fallback
        XCTAssertTrue(results.contains { $0.id == "web-search" })
    }

    func testBuildResultsWithEmptyQueryProducesNoWebFallback() {
        let coordinator = SearchCoordinator()
        let results = coordinator.buildResults(
            query: "",
            indexed: [],
            apps: [],
            system: []
        )
        XCTAssertFalse(results.contains { $0.kind == .web })
        XCTAssertFalse(results.contains { $0.kind == .calculator })
    }

    func testBuildResultsDeduplicatesByID() {
        let coordinator = SearchCoordinator()
        let file = makeFile(id: "dup-id", name: "file1", score: 100)
        let app = makeApp(id: "dup-id", name: "app1", score: 200)

        let results = coordinator.buildResults(
            query: "test",
            indexed: [file],
            apps: [app],
            system: []
        )
        XCTAssertEqual(results.filter { $0.id == "dup-id" }.count, 1)
        // Earlier source (apps) wins
        XCTAssertEqual(results.first { $0.id == "dup-id" }?.title, "app1")
    }

    func testBuildResultsTruncatesAt80() {
        let coordinator = SearchCoordinator()
        let indexed = (0..<200).map { makeFile(name: "file-\($0)", score: 1000 - $0) }
        let results = coordinator.buildResults(
            query: "zzzzz",
            indexed: indexed,
            apps: [],
            system: []
        )
        XCTAssertEqual(results.count, 80)
    }

    func testBuildResultsCalculatorItemHasCorrectAction() throws {
        let coordinator = SearchCoordinator()
        let results = coordinator.buildResults(
            query: "2 + 3",
            indexed: [],
            apps: [],
            system: []
        )
        let calc = try XCTUnwrap(results.first { $0.id == "calculator" })
        XCTAssertEqual(calc.action, .copy("5"))
        XCTAssertEqual(calc.kind, .calculator)
    }

    func testBuildResultsWebFallbackHasCorrectURL() throws {
        let coordinator = SearchCoordinator()
        let results = coordinator.buildResults(
            query: "test query",
            indexed: [],
            apps: [],
            system: []
        )
        let web = try XCTUnwrap(results.first { $0.id == "web-search" })
        guard case .open(let url) = web.action else {
            return XCTFail("expected .open action")
        }
        XCTAssertTrue(url.absoluteString.contains("google.com"))
        XCTAssertTrue(url.absoluteString.contains("test%20query"))
    }

    // MARK: - reconciledSelectionID edge cases

    func testReconciledSelectionIDWithEmptyResultsReturnsNil() {
        XCTAssertNil(SearchCoordinator.reconciledSelectionID(
            previousSelection: nil,
            results: [],
            resetSelection: false,
            promoteWebFallback: false
        ))
    }

    func testReconciledSelectionIDWithResetReturnsFirst() {
        let items = [makeFile(name: "a", score: 100), makeFile(name: "b", score: 50)]
        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: "b",
                results: items,
                resetSelection: true,
                promoteWebFallback: false
            ),
            "a"
        )
    }

    func testReconciledSelectionIDPreservesPreviousIfPresent() {
        let items = [makeFile(name: "a", score: 100), makeFile(name: "b", score: 50)]
        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: items.last?.id,
                results: items,
                resetSelection: false,
                promoteWebFallback: false
            ),
            items.last?.id
        )
    }

    func testReconciledSelectionIDFallsBackToFirstIfPreviousNotPresent() {
        let items = [makeFile(name: "a", score: 100), makeFile(name: "b", score: 50)]
        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: "nonexistent",
                results: items,
                resetSelection: false,
                promoteWebFallback: false
            ),
            items.first?.id
        )
    }

    // MARK: - Query changes

    func testQueryChangeTriggersNewSearch() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        let firstResults = coordinator.results

        coordinator.query = "settings"
        let secondResults = coordinator.results

        // Results should be different for different queries
        XCTAssertNotEqual(
            Set(firstResults.map(\.id)),
            Set(secondResults.map(\.id))
        )
    }

    func testSettingQueryToSameValueDoesNotTriggerSearch() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        let results = coordinator.results
        coordinator.query = "shortcut" // same value
        XCTAssertEqual(coordinator.results, results)
    }

    func testSettingQueryToEmptyClearsResults() {
        let coordinator = SearchCoordinator()
        coordinator.query = "shortcut"
        XCTAssertFalse(coordinator.results.isEmpty)

        coordinator.query = ""
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertEqual(coordinator.selectedFilter, .all)
    }

    // MARK: - Helpers

    private func makeFile(id: String? = nil, name: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/Users/test/\(name)")
        return SearchItem(
            id: id ?? "file:\(url.path)",
            title: name, subtitle: "test/\(name)",
            kind: .file, action: .open(url), score: score, fileURL: url
        )
    }

    private func makeApp(id: String? = nil, name: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
        return SearchItem(
            id: id ?? "application:\(url.path)",
            title: name, subtitle: "Applications",
            kind: .application, action: .open(url), score: score, fileURL: url
        )
    }
}
