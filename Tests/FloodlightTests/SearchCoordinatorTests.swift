import FloodlightEngine
import Foundation
import Observation
import os
import Testing
@testable import Floodlight

@MainActor
struct SearchCoordinatorTests {
    @Test func publicationReplacementInvalidatesAllResultFacingObservationsTogether() async {
        let coordinator = makeSearchCoordinatorWithInertPresentation()
        await confirmation(expectedCount: 5) { confirm in
            withObservationTracking {
                _ = coordinator.results
            } onChange: {
                confirm()
            }
            withObservationTracking {
                _ = coordinator.filterOptions
            } onChange: {
                confirm()
            }
            withObservationTracking {
                _ = coordinator.selectedFilter
            } onChange: {
                confirm()
            }
            withObservationTracking {
                _ = coordinator.selectedID
            } onChange: {
                confirm()
            }
            withObservationTracking {
                _ = coordinator.isSearching
            } onChange: {
                confirm()
            }

            coordinator.query = "shortcut"
        }

        #expect(!coordinator.results.isEmpty)
        #expect(coordinator.selectedFilter == .all)
        #expect(coordinator.selectedID == coordinator.results.first?.id)
        #expect(coordinator.isSearching)
    }

    @Test func projectionPromotesARealResultOverAnAutomaticWebFallbackSelection() {
        let folder = makeFolder()

        let publication = SearchResultProjection.project(
            .local(
                .init(
                    query: "shortcut",
                    candidates: [folder],
                    keywordRegistry: KeywordEngineCatalog.initialRegistry,
                    selectedFilter: .all,
                    selection: .init(id: "web-search", origin: .automatic),
                    progress: .settled
                )
            )
        )

        #expect(publication.selection?.id == folder.id)
        #expect(publication.selection?.origin == .automatic)
    }

    @Test func projectionPreservesAUserSelectedWebFallback() {
        let folder = makeFolder()
        let web = makeWebResult()

        let publication = SearchResultProjection.project(
            .local(.init(
                query: "shortcut",
                candidates: [folder],
                keywordRegistry: KeywordEngineCatalog.initialRegistry,
                selectedFilter: .all,
                selection: .init(id: web.id, origin: .user),
                progress: .settled
            ))
        )

        #expect(publication.selection == .init(id: web.id, origin: .user))
    }

    @Test func projectionPreservesAnEmptyDynamicFilterUntilSettlementReconciliation() {
        let publication = SearchResultProjection.project(
            .local(.init(
                query: "notes",
                candidates: [],
                keywordRegistry: KeywordEngineCatalog.initialRegistry,
                selectedFilter: .pdfs,
                selection: nil,
                progress: .settled,
                filterContinuity: .preserve
            ))
        )

        #expect(publication.selectedFilter == .pdfs)
        #expect(publication.visibleRows.isEmpty)
        #expect(publication.filterOptions.contains { $0.filter == .pdfs })
    }

    @Test func projectionReconcilesAnEmptyDynamicFilterWhenSearchSettles() {
        let publication = SearchResultProjection.project(
            .local(.init(
                query: "notes",
                candidates: [],
                keywordRegistry: KeywordEngineCatalog.initialRegistry,
                selectedFilter: .pdfs,
                selection: nil,
                progress: .settled,
                filterContinuity: .reconcileWhenSettled
            ))
        )

        #expect(publication.selectedFilter == .all)
        #expect(!publication.filterOptions.contains { $0.filter == .pdfs })
    }

    @Test func calculatorAnswerLeadsResultsForAnExpression() throws {
        let results = projectResults(
            query: "12 * 12",
            indexed: [makeIndexedFile(name: "budget.numbers", score: 5_000)],
            apps: [makeApplication(name: "Calculator", score: 99_000)],
            system: [makeSetting(title: "Keyboard", score: 11_000)]
        )

        let answer = try #require(results.first)
        #expect(answer.id == "calculator")
        #expect(answer.kind == .calculator)
        #expect(answer.title == "144")
        #expect(answer.action == .copy("144"))
    }

    @Test func queriesThatAreNotExpressionsSkipTheCalculator() {
        let results = projectResults(
            query: Self.unmatchedQuery,
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        #expect(!results.contains { $0.kind == .calculator })
    }

    @Test func everySourceContributesToTheMergedResults() {
        let app = makeApplication(name: "Shortcuts", score: 100_000)
        let setting = makeSetting(title: "Keyboard Shortcuts", score: 11_000)
        let file = makeIndexedFile(name: "shortcut-notes.txt", score: 500)

        let results = projectResults(
            query: "shortcut",
            indexed: [file],
            apps: [app],
            system: [setting]
        )

        let ids = Set(results.map(\.id))
        #expect(ids.contains(app.id))
        #expect(ids.contains(setting.id))
        #expect(ids.contains(file.id))
        #expect(ids.contains("web-search"))
    }

    @Test func earlierSourcesWinWhenIdentifiersCollide() throws {
        let appsVersusSystemID = "collision:apps-versus-system"
        let systemVersusIndexedID = "collision:system-versus-indexed"

        let results = projectResults(
            query: "shortcut",
            indexed: [
                makeIndexedFile(
                    id: systemVersusIndexedID,
                    name: "From indexed",
                    score: 900_000
                ),
            ],
            apps: [
                makeApplication(id: appsVersusSystemID, name: "From apps", score: 10),
            ],
            system: [
                makeSetting(id: appsVersusSystemID, title: "From system", score: 900_000),
                makeSetting(id: systemVersusIndexedID, title: "From system", score: 20),
            ]
        )

        #expect(results.count == Set(results.map(\.id)).count)

        let appsWin = try #require(results.first { $0.id == appsVersusSystemID })
        #expect(appsWin.title == "From apps")
        #expect(appsWin.score == 10)

        let systemWin = try #require(results.first { $0.id == systemVersusIndexedID })
        #expect(systemWin.title == "From system")
        #expect(systemWin.score == 20)
    }

    @Test func resultsSortByScoreThenNaturalTitleOrder() {
        let results = projectResults(
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

        #expect(results.prefix(4).map(\.title) == ["Alpha", "Result 2", "Result 9", "Result 10"])
    }

    @Test func webFallbackAppearsLastForNonEmptyQueriesWithLocalMatches() throws {
        let results = projectResults(
            query: "shortcut",
            indexed: [
                makeIndexedFile(name: "shortcut-notes.txt", score: 500),
                makeIndexedFile(name: "shortcut-plan.txt", score: 400),
                makeIndexedFile(name: "shortcut-log.txt", score: 300),
            ],
            apps: [],
            system: []
        )

        let fallback = try #require(results.last)
        #expect(fallback.id == "web-search")
        #expect(fallback.kind == .web)
        let fallbackURL = try #require(URL(string: "https://www.google.com/search?q=shortcut"))
        #expect(fallback.action == .open(fallbackURL))
    }

    @Test func webFallbackIsPositionedAfterWeakLocalMatches() {
        let file = makeIndexedFile(name: "shortcut-notes.txt", score: 500)

        let results = projectResults(
            query: "shortcut",
            indexed: [file],
            apps: [],
            system: []
        )

        #expect(results.count == 2)
        #expect(results.first?.id == file.id)
        #expect(results.last?.id == "web-search")
    }

    @Test func webFallbackIsPositionedAfterLocalMatchesForQuestionShapedQuery() {
        let file = makeIndexedFile(name: "password-notes.txt", score: 500)
        let results = projectResults(
            query: "how do I reset my password",
            indexed: [file],
            apps: [],
            system: []
        )

        #expect(results.first?.id == file.id)
        #expect(results.last?.id == "web-search")
    }

    @Test func webFallbackIsPositionedAfterLocalMatchesForURLShapedQuery() {
        let file = makeIndexedFile(name: "github-notes.txt", score: 500)
        let results = projectResults(
            query: "github.com",
            indexed: [file],
            apps: [],
            system: []
        )

        #expect(results.first?.id == file.id)
        #expect(results.last?.id == "web-search")
    }

    @Test func emptyQueryOmitsTheWebFallback() {
        let results = projectResults(
            query: "",
            indexed: [makeIndexedFile(name: "notes.txt", score: 10)],
            apps: [],
            system: []
        )

        #expect(!results.contains { $0.kind == .web })
    }

    @Test func mergedResultsTruncateToEightyRows() {
        let indexed = (0..<100).map { index in
            makeIndexedFile(name: "file-\(index).txt", score: 1_000 - index)
        }

        let results = projectResults(
            query: Self.unmatchedQuery,
            indexed: indexed,
            apps: [],
            system: []
        )

        #expect(results.count == 80)
        #expect(results.first?.score == 1_000)
        #expect(results.dropLast().last?.score == 922)
        #expect(results.last?.id == "web-search")
    }

    // MARK: - Keyword engines

    @Test func keywordEngineRowOutranksApplicationAndCalculatorMatches() throws {
        let app = makeApplication(name: "Xcode", score: 100_000)

        let results = projectResults(
            query: "yt lofi hip hop",
            indexed: [],
            apps: [app],
            system: []
        )

        let engineIndex = try #require(results.firstIndex { $0.id == "keyword-engine:youtube" })
        let appIndex = try #require(results.firstIndex { $0.id == app.id })
        #expect(engineIndex < appIndex)
    }

    @Test func unmatchedQueryProducesNoKeywordEngineRow() {
        let results = projectResults(
            query: Self.unmatchedQuery,
            indexed: [],
            apps: [],
            system: []
        )

        #expect(!results.contains { $0.id.hasPrefix("keyword-engine:") })
    }

    @Test func keywordEnginesRespectTheSuppliedAvailabilityList() {
        let results = projectResults(
            query: "claude explain this",
            indexed: [],
            apps: [],
            system: [],
            keywordRegistry: KeywordEngineRegistry(
                engines: KeywordEngineCatalog.all.filter { $0.id != "claude" },
                defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
            )
        )

        #expect(!results.contains { $0.id == "keyword-engine:claude" })
    }

    // MARK: - Ask Codex / Ask Claude lifecycle

    @Test func activatingAnAssistantRowDoesNotDismissThePanel() throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        var dismissed = false
        let coordinator = SearchCoordinator(
            assistantRunner: runner,
            onDismiss: { dismissed = true }
        )

        let item = try makeClaudeAskItem(coordinator)
        coordinator.activate(item)

        #expect(!dismissed)
        #expect(coordinator.assistantRun == AssistantRun(itemID: item.id, state: .running))
    }

    @Test func assistantRunTransitionsToAnsweredOnSuccess() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = makeSearchCoordinatorWithInertPresentation(assistantRunner: runner)
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

    @Test func assistantAnswerStateParticipatesInObservation() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = makeSearchCoordinatorWithInertPresentation(assistantRunner: runner)
        let item = try makeClaudeAskItem(coordinator)
        coordinator.activate(item)

        let didObserveChange = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = coordinator.assistantRun
        } onChange: {
            didObserveChange.withLock { $0 = true }
        }

        await runner.complete(with: .success("Observed answer."))
        try await waitUntil {
            coordinator.assistantAnswerState(for: item) == .answered("Observed answer.")
        }
        #expect(coordinator.assistantAnswerState(for: item) == .answered("Observed answer."))
        #expect(
            didObserveChange.withLock { $0 },
            "assistant run changes must invalidate Observation tracking"
        )
    }

    @Test func assistantRunTransitionsToFailedOnError() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = makeSearchCoordinatorWithInertPresentation(assistantRunner: runner)
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

    @Test func editingTheQueryCancelsAndClearsAnInFlightAssistantRun() async throws {
        let runner = FakeAssistantProcessRunner(availableCommands: ["claude"])
        let coordinator = makeSearchCoordinatorWithInertPresentation(assistantRunner: runner)
        let item = try makeClaudeAskItem(coordinator)

        coordinator.query = "claude explain this function"
        coordinator.activate(item)
        #expect(coordinator.assistantRun != nil)
        try await waitUntil { await runner.hasPendingRun }

        coordinator.query = "claude explain this function differently"

        // Cancellation clears the published state synchronously — no
        // stale answer should ever render under the new query.
        #expect(coordinator.assistantRun == nil)
        try await waitUntil { await runner.cancelledCount == 1 }
    }

    /// Builds the "Ask Claude" row directly through Result Projection — the
    /// coordinator's live pipeline only includes it once `start()` resolves
    /// availability, which these tests don't drive (that's covered by
    /// `KeywordEngineCatalog.availableRegistry` tests in FloodlightEngine).
    private func makeClaudeAskItem(_ coordinator: SearchCoordinator) throws -> SearchItem {
        let results = projectResults(
            query: "claude explain this function",
            indexed: [],
            apps: [],
            system: [],
            keywordRegistry: KeywordEngineRegistry(
                engines: KeywordEngineCatalog.all,
                defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
            )
        )
        return try #require(results.first { $0.id == "keyword-engine:claude" })
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
        Issue.record("condition was never satisfied within \(timeout)s")
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

    var hasPendingRun: Bool {
        !pendingContinuations.isEmpty
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
