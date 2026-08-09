import FloodlightEngine
import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class SearchCoordinatorStressTests: XCTestCase {
    // MARK: - moveSelection

    func testMoveSelectionDownAdvancesSelectedID() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstID = try XCTUnwrap(coordinator.results.first?.id)
        let secondID = try XCTUnwrap(coordinator.results.dropFirst().first?.id)

        try coordinator.select(XCTUnwrap(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: 1)

        XCTAssertEqual(coordinator.selectedID, secondID)
    }

    func testMoveSelectionUpMovesBackward() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstID = try XCTUnwrap(coordinator.results.first?.id)
        let secondID = try XCTUnwrap(coordinator.results.dropFirst().first?.id)

        try coordinator.select(XCTUnwrap(coordinator.results.first { $0.id == secondID }))
        coordinator.moveSelection(by: -1)

        XCTAssertEqual(coordinator.selectedID, firstID)
    }

    func testMoveSelectionClampsAtLowerBound() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstID = try XCTUnwrap(coordinator.results.first?.id)

        try coordinator.select(XCTUnwrap(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: -5)

        XCTAssertEqual(coordinator.selectedID, firstID)
    }

    func testMoveSelectionClampsAtUpperBound() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let lastID = try XCTUnwrap(coordinator.results.last?.id)

        try coordinator.select(XCTUnwrap(coordinator.results.first { $0.id == lastID }))
        coordinator.moveSelection(by: 100)

        XCTAssertEqual(coordinator.selectedID, lastID)
    }

    func testMoveSelectionOnEmptyResultsIsNoOp() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)

        coordinator.moveSelection(by: 1)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    func testMoveSelectionWithZeroDeltaKeepsSelection() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstID = try XCTUnwrap(coordinator.results.first?.id)

        try coordinator.select(XCTUnwrap(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: 0)

        XCTAssertEqual(coordinator.selectedID, firstID)
    }

    // MARK: - reset

    func testResetClearsAllState() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        XCTAssertFalse(coordinator.results.isEmpty)

        coordinator.reset()

        XCTAssertEqual(coordinator.query, "")
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertEqual(coordinator.selectedFilter, .all)
        XCTAssertEqual(
            Array(coordinator.filterOptions.prefix(SearchResultFilter.primary.count)).map(\.filter),
            SearchResultFilter.primary
        )
        XCTAssertFalse(coordinator.isSearching)
    }

    func testResetIsIdempotent() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        coordinator.reset()
        let snapshotQuery = coordinator.query
        let snapshotResults = coordinator.results
        let snapshotSelectedID = coordinator.selectedID

        coordinator.reset()

        XCTAssertEqual(coordinator.query, snapshotQuery)
        XCTAssertEqual(coordinator.results, snapshotResults)
        XCTAssertEqual(coordinator.selectedID, snapshotSelectedID)
    }

    // MARK: - selectFilter

    func testSelectFilterChangesFilterAndResetsSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        coordinator.selectFilter(.settings)

        XCTAssertEqual(coordinator.selectedFilter, .settings)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)
    }

    func testSelectFilterWithSameFilterIncrementsFocusGeneration() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        coordinator.selectFilter(.settings)
        let generationBefore = coordinator.focusGeneration

        coordinator.selectFilter(.settings)

        XCTAssertGreaterThan(coordinator.focusGeneration, generationBefore)
        XCTAssertEqual(coordinator.selectedFilter, .settings)
    }

    func testSelectFilterToEmptyFilterClearsSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        coordinator.selectFilter(.folders)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    // MARK: - select

    func testSelectSetsSelectedID() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            XCTFail("expected at least one result")
            return
        }

        coordinator.select(item)

        XCTAssertEqual(coordinator.selectedID, item.id)
    }

    // MARK: - copySelection

    func testCopySelectionWithFileURLWritesPathToPasteboard() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first(where: { $0.fileURL != nil }) else {
            // Skip: no file URL result available for this query
            return
        }
        coordinator.select(item)

        let pasteboard = NSPasteboard(name: NSPasteboard
            .Name("CopySelectionStress-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        // copySelection writes to .general; emulate by capturing the value
        // via the same logic the production code uses.
        let expected = item.fileURL?.path
        coordinator.copySelection()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
    }

    func testCopySelectionWithNoSelectionIsNoOp() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        XCTAssertNil(coordinator.selectedID)

        // Should not crash; nothing to copy.
        coordinator.copySelection()
    }

    // MARK: - previewableSelectionURL

    func testPreviewableSelectionURLIsNilForNonFileSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let webItem = coordinator.results.first(where: { $0.kind == .web }) else {
            // Skip: no web result available
            return
        }
        coordinator.select(webItem)

        XCTAssertNil(coordinator.previewableSelectionURL)
    }

    func testPreviewableSelectionURLIsNilWhenNoSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        XCTAssertNil(coordinator.selectedID)
        XCTAssertNil(coordinator.previewableSelectionURL)
    }

    func testPreviewableSelectionURLReturnsFileURLForFileSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let fileItem = coordinator.results.first(where: { $0.kind == .file }) else {
            // Skip: no file result available for this query
            return
        }
        coordinator.select(fileItem)

        XCTAssertEqual(coordinator.previewableSelectionURL, fileItem.fileURL)
    }

    // MARK: - assistantAnswerState

    func testAssistantAnswerStateIsNilForNonMatchingItem() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            XCTFail("expected at least one result")
            return
        }
        // No assistant run has been triggered.
        XCTAssertNil(coordinator.assistantAnswerState(for: item))
    }

    func testAssistantAnswerStateIsNilWhenNoRunExists() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        let item = SearchItem(
            id: "keyword-engine:claude",
            title: "Ask Claude: test",
            subtitle: "Press Return to ask",
            kind: .assistant,
            action: .askAssistant(command: "claude", arguments: ["-p", "test"]),
            score: SearchItemRanking.keywordEngine
        )
        XCTAssertNil(coordinator.assistantAnswerState(for: item))
    }

    // MARK: - Result Projection edge cases

    func testBuildResultsWithAllEmptySourcesAndEmptyQueryProducesNoWebFallback() {
        let results = projectResults(
            query: "",
            indexed: [],
            apps: [],
            system: []
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testBuildResultsWithEmptyQueryAndLocalMatchesOmitsWebFallback() {
        let file = makeFile(name: "notes.txt", score: 100)
        let results = projectResults(
            query: "",
            indexed: [file],
            apps: [],
            system: []
        )
        XCTAssertFalse(results.contains { $0.kind == .web })
        XCTAssertTrue(results.contains { $0.id == file.id })
    }

    func testBuildResultsDeduplicatesByID() {
        let file = makeFile(name: "notes.txt", score: 100)
        let results = projectResults(
            query: "zzzzz",
            indexed: [file, file],
            apps: [],
            system: []
        )
        XCTAssertEqual(results.filter { $0.id == file.id }.count, 1)
    }

    func testBuildResultsTruncatesAtEightyRows() {
        let indexed = (0..<100).map { makeFile(name: "file-\($0).txt", score: 1_000 - $0) }
        let results = projectResults(
            query: "zzzzz",
            indexed: indexed,
            apps: [],
            system: []
        )
        XCTAssertEqual(results.count, 80)
    }

    func testBuildResultsProducesCalculatorActionForExpression() throws {
        let results = projectResults(
            query: "12 * 12",
            indexed: [],
            apps: [],
            system: []
        )
        let calc = try XCTUnwrap(results.first { $0.kind == .calculator })
        XCTAssertEqual(calc.title, "144")
        XCTAssertEqual(calc.action, .copy("144"))
    }

    func testBuildResultsWebFallbackURLIsGoogleSearch() throws {
        let results = projectResults(
            query: "floodlight",
            indexed: [],
            apps: [],
            system: []
        )
        let web = try XCTUnwrap(results.first { $0.kind == .web })
        guard case let .open(url) = web.action else {
            XCTFail("expected open action")
            return
        }
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.google.com/search?q="))
    }

    // MARK: - query changes

    func testChangingQueryTriggersNewSearch() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstResults = coordinator.results

        coordinator.query = "settings"

        // The new query should produce results; we just assert the pipeline
        // ran (results is non-empty for a real query).
        XCTAssertFalse(coordinator.results.isEmpty)
        XCTAssertNotEqual(firstResults, coordinator.results)
    }

    func testSettingSameQueryValueDoesNotTriggerSearch() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let snapshotResults = coordinator.results

        coordinator.query = "shortcut"

        XCTAssertEqual(coordinator.results, snapshotResults)
    }

    func testSettingEmptyQueryClearsResults() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        XCTAssertFalse(coordinator.results.isEmpty)

        coordinator.query = ""

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertEqual(coordinator.selectedFilter, .all)
    }

    // MARK: - Helpers

    private func makeFile(name: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/Users/example/code/\(name)")
        return SearchItem(
            id: "file:\(url.path)",
            title: name,
            subtitle: "code/\(name)",
            kind: .file,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }
}
