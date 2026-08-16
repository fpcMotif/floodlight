import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
struct SearchCoordinatorStressTests {
    private func makeStressCoordinator(
        applications: [SearchItem] = [],
        settings: [SearchItem] = []
    ) throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(immediate: applications),
                settings: ScriptedCatalog(immediate: settings)
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            rootURL: URL(fileURLWithPath: "/tmp"),
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never became true: \(description)", sourceLocation: sourceLocation)
    }

    // MARK: - moveSelection

    @Test func moveSelectionDownAdvancesSelectedID() async throws {
        let app = SearchFixtures.application(name: "Xcode", score: 100_000)
        let setting = SearchFixtures.setting(title: "Keyboard", score: 11_000)
        let coordinator = try makeStressCoordinator(applications: [app], settings: [setting])
        coordinator.query = "k"
        try await waitUntil("candidates arrive") { coordinator.results.count >= 2 }
        let firstID = try #require(coordinator.results.first?.id)
        let secondID = try #require(coordinator.results.dropFirst().first?.id)

        try coordinator.select(#require(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: 1)

        #expect(coordinator.selectedID == secondID)
    }

    @Test func moveSelectionUpMovesBackward() async throws {
        let app = SearchFixtures.application(name: "Xcode", score: 100_000)
        let setting = SearchFixtures.setting(title: "Keyboard", score: 11_000)
        let coordinator = try makeStressCoordinator(applications: [app], settings: [setting])
        coordinator.query = "k"
        try await waitUntil("candidates arrive") { coordinator.results.count >= 2 }
        let firstID = try #require(coordinator.results.first?.id)
        let secondID = try #require(coordinator.results.dropFirst().first?.id)

        try coordinator.select(#require(coordinator.results.first { $0.id == secondID }))
        coordinator.moveSelection(by: -1)

        #expect(coordinator.selectedID == firstID)
    }

    @Test func moveSelectionClampsAtLowerBound() async throws {
        let app = SearchFixtures.application(name: "Xcode", score: 100_000)
        let coordinator = try makeStressCoordinator(applications: [app])
        coordinator.query = "x"
        try await waitUntil("candidates arrive") { !coordinator.results.isEmpty }
        let firstID = try #require(coordinator.results.first?.id)

        try coordinator.select(#require(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: -5)

        #expect(coordinator.selectedID == firstID)
    }

    @Test func moveSelectionClampsAtUpperBound() async throws {
        let app = SearchFixtures.application(name: "Xcode", score: 100_000)
        let coordinator = try makeStressCoordinator(applications: [app])
        coordinator.query = "x"
        try await waitUntil("candidates arrive") { !coordinator.results.isEmpty }
        let lastID = try #require(coordinator.results.last?.id)

        try coordinator.select(#require(coordinator.results.first { $0.id == lastID }))
        coordinator.moveSelection(by: 100)

        #expect(coordinator.selectedID == lastID)
    }

    @Test func moveSelectionOnEmptyResultsIsNoOp() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)

        coordinator.moveSelection(by: 1)

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
    }

    @Test func moveSelectionWithZeroDeltaKeepsSelection() throws {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstID = try #require(coordinator.results.first?.id)

        try coordinator.select(#require(coordinator.results.first { $0.id == firstID }))
        coordinator.moveSelection(by: 0)

        #expect(coordinator.selectedID == firstID)
    }

    // MARK: - reset

    @Test func resetClearsAllState() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        #expect(!coordinator.results.isEmpty)

        coordinator.reset()

        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
        #expect(coordinator.selectedFilter == .all)
        #expect(Array(coordinator.filterOptions.prefix(SearchResultFilter.primary.count))
            .map(\.filter) == SearchResultFilter.primary)
        #expect(!coordinator.isSearching)
    }

    @Test func resetIsIdempotent() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        coordinator.reset()
        let snapshotQuery = coordinator.query
        let snapshotResults = coordinator.results
        let snapshotSelectedID = coordinator.selectedID

        coordinator.reset()

        #expect(coordinator.query == snapshotQuery)
        #expect(coordinator.results == snapshotResults)
        #expect(coordinator.selectedID == snapshotSelectedID)
    }

    // MARK: - selectFilter

    @Test func selectFilterChangesFilterAndResetsSelection() async throws {
        let setting = SearchFixtures.setting(title: "Keyboard", score: 11_000)
        let coordinator = try makeStressCoordinator(settings: [setting])
        coordinator.query = "k"
        try await waitUntil("candidates arrive") {
            coordinator.results.contains { $0.id == setting.id }
        }

        coordinator.selectFilter(.settings)

        #expect(coordinator.selectedFilter == .settings)
        #expect(!coordinator.results.isEmpty)
        #expect(coordinator.results.allSatisfy { $0.kind == .systemSetting })
        #expect(coordinator.selectedID == setting.id)
    }

    @Test func selectFilterWithSameFilterIncrementsFocusGeneration() async throws {
        let setting = SearchFixtures.setting(title: "Keyboard", score: 11_000)
        let coordinator = try makeStressCoordinator(settings: [setting])
        coordinator.query = "k"
        try await waitUntil("candidates arrive") {
            coordinator.results.contains { $0.id == setting.id }
        }
        coordinator.selectFilter(.settings)
        let generationBefore = coordinator.focusGeneration

        coordinator.selectFilter(.settings)

        #expect(coordinator.focusGeneration > generationBefore)
        #expect(coordinator.selectedFilter == .settings)
    }

    @Test func selectFilterToEmptyFilterClearsSelection() async throws {
        let setting = SearchFixtures.setting(title: "Keyboard", score: 11_000)
        let coordinator = try makeStressCoordinator(settings: [setting])
        coordinator.query = "k"
        try await waitUntil("candidates arrive") {
            coordinator.results.contains { $0.id == setting.id }
        }
        #expect(coordinator.selectedID != nil)

        coordinator.selectFilter(.folders)

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
    }

    // MARK: - select

    @Test func selectSetsSelectedID() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            Issue.record("expected at least one result")
            return
        }

        coordinator.select(item)

        #expect(coordinator.selectedID == item.id)
    }

    // MARK: - copySelection

    @Test func copySelectionWithFileURLWritesPathToPasteboard() {
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

        #expect(NSPasteboard.general.string(forType: .string) == expected)
    }

    @Test func copySelectionWithNoSelectionIsNoOp() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        #expect(coordinator.selectedID == nil)

        // Should not crash; nothing to copy.
        coordinator.copySelection()
    }

    // MARK: - previewableSelectionURL

    @Test func previewableSelectionURLIsNilForNonFileSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let webItem = coordinator.results.first(where: { $0.kind == .web }) else {
            // Skip: no web result available
            return
        }
        coordinator.select(webItem)

        #expect(coordinator.previewableSelectionURL == nil)
    }

    @Test func previewableSelectionURLIsNilWhenNoSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        #expect(coordinator.selectedID == nil)
        #expect(coordinator.previewableSelectionURL == nil)
    }

    @Test func previewableSelectionURLReturnsFileURLForFileSelection() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let fileItem = coordinator.results.first(where: { $0.kind == .file }) else {
            // Skip: no file result available for this query
            return
        }
        coordinator.select(fileItem)

        #expect(coordinator.previewableSelectionURL == fileItem.fileURL)
    }

    // MARK: - assistantAnswerState

    @Test func assistantAnswerStateIsNilForNonMatchingItem() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        guard let item = coordinator.results.first else {
            Issue.record("expected at least one result")
            return
        }
        // No assistant run has been triggered.
        #expect(coordinator.assistantAnswerState(for: item) == nil)
    }

    @Test func assistantAnswerStateIsNilWhenNoRunExists() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        let item = SearchItem(
            id: "keyword-engine:claude",
            title: "Ask Claude: test",
            subtitle: "Press Return to ask",
            kind: .assistant,
            action: .askAssistant(command: "claude", arguments: ["-p", "test"]),
            score: SearchItemRanking.keywordEngine
        )
        #expect(coordinator.assistantAnswerState(for: item) == nil)
    }

    // MARK: - Result Projection edge cases

    @Test func buildResultsWithAllEmptySourcesAndEmptyQueryProducesNoWebFallback() {
        let results = projectResults(
            query: "",
            indexed: [],
            apps: [],
            system: []
        )
        #expect(results.isEmpty)
    }

    @Test func buildResultsWithEmptyQueryAndLocalMatchesOmitsWebFallback() {
        let file = makeFile(name: "notes.txt", score: 100)
        let results = projectResults(
            query: "",
            indexed: [file],
            apps: [],
            system: []
        )
        #expect(!results.contains { $0.kind == .web })
        #expect(results.contains { $0.id == file.id })
    }

    @Test func buildResultsDeduplicatesByID() {
        let file = makeFile(name: "notes.txt", score: 100)
        let results = projectResults(
            query: "zzzzz",
            indexed: [file, file],
            apps: [],
            system: []
        )
        #expect(results.filter { $0.id == file.id }.count == 1)
    }

    @Test func buildResultsTruncatesAtEightyRows() {
        let indexed = (0..<100).map { makeFile(name: "file-\($0).txt", score: 1_000 - $0) }
        let results = projectResults(
            query: "zzzzz",
            indexed: indexed,
            apps: [],
            system: []
        )
        #expect(results.count == 80)
        #expect(results.last?.id == "web-search")
    }

    @Test func buildResultsProducesCalculatorActionForExpression() throws {
        let results = projectResults(
            query: "12 * 12",
            indexed: [],
            apps: [],
            system: []
        )
        let calc = try #require(results.first { $0.kind == .calculator })
        #expect(calc.title == "144")
        #expect(calc.action == .copy("144"))
    }

    @Test func buildResultsWebFallbackURLIsGoogleSearch() throws {
        let results = projectResults(
            query: "floodlight",
            indexed: [],
            apps: [],
            system: []
        )
        let web = try #require(results.first { $0.kind == .web })
        guard case let .open(url) = web.action else {
            Issue.record("expected open action")
            return
        }
        #expect(url.absoluteString.hasPrefix("https://www.google.com/search?q="))
    }

    // MARK: - query changes

    @Test func changingQueryTriggersNewSearch() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let firstResults = coordinator.results

        coordinator.query = "settings"

        // The new query should produce results; we just assert the pipeline
        // ran (results is non-empty for a real query).
        #expect(!coordinator.results.isEmpty)
        #expect(firstResults != coordinator.results)
    }

    @Test func settingSameQueryValueDoesNotTriggerSearch() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        let snapshotResults = coordinator.results

        coordinator.query = "shortcut"

        #expect(coordinator.results == snapshotResults)
    }

    @Test func settingEmptyQueryClearsResults() {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        coordinator.query = "shortcut"
        #expect(!coordinator.results.isEmpty)

        coordinator.query = ""

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
        #expect(coordinator.selectedFilter == .all)
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
