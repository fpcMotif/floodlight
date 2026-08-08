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

    func testWebFallbackTrailsResultsWithTheLowestScoreWhenLocalMatchesAreHealthy() throws {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "shortcut",
            indexed: [
                makeIndexedFile(name: "shortcut-notes.txt", score: 500),
                makeIndexedFile(name: "shortcut-plan.txt", score: 400),
                makeIndexedFile(name: "shortcut-log.txt", score: 300),
            ],
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

    func testWebFallbackIsPromotedWhenLocalMatchesAreWeak() throws {
        let coordinator = SearchCoordinator()
        let file = makeIndexedFile(name: "shortcut-notes.txt", score: 500)

        let results = coordinator.buildResults(
            query: "shortcut",
            indexed: [file],
            apps: [],
            system: []
        )

        let fallback = try XCTUnwrap(results.first { $0.id == "web-search" })
        XCTAssertEqual(fallback.score, SearchItemRanking.webPromoted)
        // A promoted web row outranks the one weak file match it's competing
        // with, even though it still trails higher-priority bands like
        // Floodlight's own commands.
        let fallbackIndex = try XCTUnwrap(results.firstIndex { $0.id == "web-search" })
        let fileIndex = try XCTUnwrap(results.firstIndex { $0.id == file.id })
        XCTAssertLessThan(fallbackIndex, fileIndex)
    }

    func testWebFallbackIsPromotedForAQuestionShapedQueryEvenWithManyLocalMatches() throws {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "how do I reset my password",
            indexed: [
                makeIndexedFile(name: "password-notes.txt", score: 500),
                makeIndexedFile(name: "password-plan.txt", score: 400),
                makeIndexedFile(name: "password-log.txt", score: 300),
            ],
            apps: [],
            system: []
        )

        let fallback = try XCTUnwrap(results.first { $0.id == "web-search" })
        XCTAssertEqual(fallback.score, SearchItemRanking.webPromoted)
    }

    func testWebFallbackIsPromotedForAURLShapedQuery() throws {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "github.com",
            indexed: [
                makeIndexedFile(name: "github-notes.txt", score: 500),
                makeIndexedFile(name: "github-plan.txt", score: 400),
                makeIndexedFile(name: "github-log.txt", score: 300),
            ],
            apps: [],
            system: []
        )

        let fallback = try XCTUnwrap(results.first { $0.id == "web-search" })
        XCTAssertEqual(fallback.score, SearchItemRanking.webPromoted)
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

    // MARK: - Keyword engines

    func testKeywordEngineRowOutranksApplicationAndCalculatorMatches() throws {
        let coordinator = SearchCoordinator()
        let app = makeApplication(name: "Xcode", score: 100_000)

        let results = coordinator.buildResults(
            query: "yt lofi hip hop",
            indexed: [],
            apps: [app],
            system: []
        )

        let engineIndex = try XCTUnwrap(results.firstIndex { $0.id == "keyword-engine:youtube" })
        let appIndex = try XCTUnwrap(results.firstIndex { $0.id == app.id })
        XCTAssertLessThan(engineIndex, appIndex)
    }

    func testKeywordEngineRowDefersToFloodlightCommands() throws {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "yt lofi hip hop",
            indexed: [],
            apps: [],
            system: []
        )

        // "yt lofi hip hop" doesn't fuzzy-match the settings command, so
        // assert the ranking relationship directly instead.
        let engine = try XCTUnwrap(results.first { $0.id == "keyword-engine:youtube" })
        XCTAssertLessThan(engine.score, SearchItemRanking.command)
    }

    func testUnmatchedQueryProducesNoKeywordEngineRow() {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: Self.unmatchedQuery,
            indexed: [],
            apps: [],
            system: []
        )

        XCTAssertFalse(results.contains { $0.id.hasPrefix("keyword-engine:") })
    }

    func testKeywordEnginesRespectTheSuppliedAvailabilityList() {
        let coordinator = SearchCoordinator()

        let results = coordinator.buildResults(
            query: "claude explain this",
            indexed: [],
            apps: [],
            system: [],
            keywordEngines: KeywordEngineCatalog.all.filter { $0.id != "claude" }
        )

        XCTAssertFalse(results.contains { $0.id == "keyword-engine:claude" })
    }

    // MARK: - Ask Codex / Ask Claude lifecycle

    func testActivatingAnAssistantRowDoesNotDismissThePanel() throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = SearchCoordinator(assistantRunner: runner)
        var dismissed = false
        coordinator.onDismiss = { dismissed = true }

        let item = try makeClaudeAskItem(coordinator)
        coordinator.activate(item)

        XCTAssertFalse(dismissed)
        XCTAssertEqual(coordinator.assistantRun, AssistantRun(itemID: item.id, state: .running))
    }

    func testAssistantRunTransitionsToAnsweredOnSuccess() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = SearchCoordinator(assistantRunner: runner)
        let item = try makeClaudeAskItem(coordinator)

        coordinator.activate(item)
        await runner.complete(with: .success("It returns the sum."))

        try await waitUntil {
            coordinator.assistantRun == AssistantRun(
                itemID: item.id,
                state: .answered("It returns the sum.")
            )
        }
    }

    func testAssistantRunTransitionsToFailedOnError() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = SearchCoordinator(assistantRunner: runner)
        let item = try makeClaudeAskItem(coordinator)

        coordinator.activate(item)
        await runner.complete(with: .failure(AssistantProcessError.nonZeroExit(
            status: 1,
            message: "network error"
        )))

        try await waitUntil {
            coordinator.assistantRun == AssistantRun(
                itemID: item.id,
                state: .failed("network error")
            )
        }
    }

    func testEditingTheQueryCancelsAndClearsAnInFlightAssistantRun() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = SearchCoordinator(assistantRunner: runner)
        let item = try makeClaudeAskItem(coordinator)

        coordinator.query = "claude explain this function"
        coordinator.activate(item)
        XCTAssertNotNil(coordinator.assistantRun)

        coordinator.query = "claude explain this function differently"

        // Cancellation clears the published state synchronously — no
        // stale answer should ever render under the new query.
        XCTAssertNil(coordinator.assistantRun)
        try await waitUntil { await runner.cancelledCount == 1 }
    }

    func testAssistantEngineWithNoInstalledBinaryProducesNoRow() {
        let runner = FakeAssistantProcessRunner(availableCommands: [])
        let coordinator = SearchCoordinator(assistantRunner: runner)

        let results = coordinator.buildResults(
            query: "claude explain this function",
            indexed: [],
            apps: [],
            system: [],
            keywordEngines: []
        )

        XCTAssertFalse(results.contains { $0.id == "keyword-engine:claude" })
    }

    /// Builds the "Ask Claude" row directly through `buildResults` — the
    /// coordinator's live pipeline only includes it once `start()` resolves
    /// availability, which these tests don't drive (that's covered by
    /// `KeywordEngineCatalog.availableEngines` tests in FloodlightEngine).
    private func makeClaudeAskItem(_ coordinator: SearchCoordinator) throws -> SearchItem {
        let results = coordinator.buildResults(
            query: "claude explain this function",
            indexed: [],
            apps: [],
            system: [],
            keywordEngines: KeywordEngineCatalog.all
        )
        return try XCTUnwrap(results.first { $0.id == "keyword-engine:claude" })
    }

    /// Polls `condition` on a short interval, matching the polling style
    /// already used for FFF scan completion in `SearchPerformanceTests`.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was never satisfied within \(timeout)s")
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

/// A controllable `AssistantProcessRunning` — `run` suspends until the test
/// calls `complete(with:)`, so tests can observe the coordinator's
/// `.running` state before deciding how (and whether) the ask finishes.
private actor FakeAssistantProcessRunner: AssistantProcessRunning {
    private let availableCommands: Set<String>
    private var pendingContinuations: [CheckedContinuation<String, Error>] = []
    private(set) var cancelledCount = 0

    init(availableCommands: Set<String>) {
        self.availableCommands = availableCommands
    }

    func isAvailable(command: String) async -> Bool {
        availableCommands.contains(command)
    }

    func run(command: String, arguments: [String]) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelPendingRuns() }
        }
    }

    /// Mirrors what the real runner does on cancellation — terminating the
    /// process, which resumes its continuation — so a cancelled `run` call
    /// actually completes instead of leaking a permanently-suspended task.
    private func cancelPendingRuns() {
        cancelledCount += 1
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Resolves the oldest still-pending `run` call.
    /// Resolves the oldest still-pending `run` call — waiting, if needed,
    /// for the coordinator's task to actually reach `run()` and register
    /// its continuation, since creating a `Task` only schedules it and a
    /// caller can otherwise race ahead of it.
    func complete(with result: Result<String, Error>) async {
        while pendingContinuations.isEmpty {
            await Task.yield()
        }
        pendingContinuations.removeFirst().resume(with: result)
    }
}
