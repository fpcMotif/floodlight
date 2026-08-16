import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Drives `SearchCoordinator` through its real pipeline — the query
/// observer, the two-phase search, the generation guard, filter
/// reconciliation, and selection — using scripted catalogs so the
/// assertions are about the coordinator rather than about whatever happens
/// to be installed on the machine running the tests.
///
/// Result Projection tests cover deterministic presentation policy. These
/// integration tests cover the asynchronous half, where a slow Source Search
/// snapshot can land after the user has already typed something else.
@MainActor
class SearchCoordinatorIntegrationTestCase {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "CoordinatorIntegration")
    }

    func makeCoordinator(
        applications: ScriptedCatalog = ScriptedCatalog(),
        settings: ScriptedCatalog = ScriptedCatalog(),
        runner: ScriptedAssistantRunner = ScriptedAssistantRunner(),
        onDismiss: @escaping @MainActor () -> Void = {}
    ) async throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: applications,
                settings: settings
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            rootURL: tree.root,
            assistantRunner: runner,
            onDismiss: onDismiss
        )
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never became true: \(description)", sourceLocation: sourceLocation)
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never became true: \(description)", sourceLocation: sourceLocation)
    }

    /// Lets the debounced indexed pass run to completion.
    func settle(_ coordinator: SearchCoordinator) async throws {
        try await waitUntil("the indexed pass finishes") { !coordinator.isSearching }
    }
}

@MainActor
final class SearchCoordinatorIntegrationTests: SearchCoordinatorIntegrationTestCase {
    // MARK: - The immediate pass

    @Test func typingPublishesTheFirstSourceSnapshot() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let settings = ScriptedCatalog(
            immediate: [SearchFixtures.setting(title: "Keyboard", score: 11_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications, settings: settings)

        coordinator.query = "x"

        try await waitUntil("the first Source Search snapshot arrives") {
            coordinator.results.contains { $0.kind == .systemSetting }
        }
        #expect(coordinator.results
            .contains { $0.id == "application:/Applications/Xcode.app" })
        #expect(coordinator.results.contains { $0.kind == .systemSetting })
        #expect(coordinator.results.contains { $0.id == "web-search" })
        #expect(coordinator.selectedID == coordinator.results.first?.id)
    }

    @Test func theIndexedPassMergesItsResultsIn() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)],
                indexed: [SearchFixtures.application(name: "Xcode Beta", score: 119_000)]
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        #expect(!coordinator.results.contains { $0.title == "Xcode Beta" })

        try await settle(coordinator)

        #expect(coordinator.results.contains { $0.title == "Xcode Beta" })
        #expect(coordinator.results.contains { $0.title == "Xcode" })
    }

    @Test func anEmptyQueryClearsEverythingImmediately() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        try await waitUntil("the first Source Search snapshot arrives") {
            !coordinator.results.isEmpty
        }
        #expect(!coordinator.results.isEmpty)

        coordinator.query = ""

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
        #expect(!coordinator.isSearching)
        #expect(coordinator.selectedFilter == .all)
    }

    @Test func AWhitespaceOnlyQueryIsTreatedAsEmpty() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )

        for query in [" ", "\t", "\n", "   \n\t "] {
            coordinator.query = query
            #expect(coordinator.results.isEmpty, "\(String(reflecting: query))")
            #expect(coordinator.selectedID == nil)
        }
    }

    @Test func assigningTheSameQueryTwiceDoesNotResearch() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        let afterFirst = applications.queries.count
        coordinator.query = "xcode"

        #expect(
            applications.queries.count == afterFirst,
            "the didSet guard should ignore an identical assignment"
        )
    }

    @Test func theQueryIsTrimmedBeforeReachingTheCatalogs() async throws {
        let applications = ScriptedCatalog(immediate: [])
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "  xcode \n "

        try await waitUntil("the normalized query reaches the catalog") {
            !applications.queries.isEmpty
        }
        #expect(applications.queries.allSatisfy { $0 == "xcode" })
    }

    // MARK: - Staleness and the generation guard

    @Test func ASlowIndexedPassForAnOldQueryNeverOverwritesANewerOne() async throws {
        // The race that matters: the user types "a", the indexed pass for
        // "a" takes 300ms, and meanwhile they finish typing "ab". The "a"
        // results must never appear under "ab".
        let applications = ScriptedCatalog()
        applications.setBehavior(
            .init(
                immediate: [SearchFixtures.application(id: "app:slow", name: "Slow")],
                indexed: [SearchFixtures.application(id: "app:stale", name: "Stale")],
                indexedDelay: .milliseconds(300)
            ),
            forQuery: "a"
        )
        applications.setBehavior(
            .init(
                immediate: [SearchFixtures.application(id: "app:fast", name: "Fast")],
                indexed: [SearchFixtures.application(id: "app:fresh", name: "Fresh")]
            ),
            forQuery: "ab"
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "a"
        coordinator.query = "ab"

        try await settle(coordinator)
        // Give the abandoned "a" pass more than enough time to land.
        try await Task.sleep(for: .milliseconds(500))

        #expect(coordinator.results.contains { $0.id == "app:fresh" })
        #expect(
            !coordinator.results.contains { $0.id == "app:stale" },
            "results from an abandoned query leaked into the current one"
        )
        #expect(!coordinator.results.contains { $0.id == "app:slow" })
    }

    @Test func rapidTypingLeavesOnlyTheFinalQuerysResults() async throws {
        let applications = ScriptedCatalog()
        for query in ["s", "se", "sea", "sear", "searc", "search"] {
            applications.setBehavior(
                .init(immediate: [SearchFixtures.application(id: "app:\(query)", name: query)]),
                forQuery: query
            )
        }
        let coordinator = try await makeCoordinator(applications: applications)

        for query in ["s", "se", "sea", "sear", "searc", "search"] {
            coordinator.query = query
        }
        try await settle(coordinator)

        #expect(coordinator.results.contains { $0.id == "app:search" })
        for stale in ["s", "se", "sea", "sear", "searc"] {
            #expect(
                !coordinator.results.contains { $0.id == "app:\(stale)" },
                "\(stale) should have been superseded"
            )
        }
    }

    @Test func AFailingIndexedPassFallsBackToTheImmediateResults() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode")],
                indexedError: TestError.scripted("index unavailable")
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        try await settle(coordinator)

        #expect(
            coordinator.results.contains { $0.title == "Xcode" },
            "a failed indexed pass must not clear what the immediate pass found"
        )
        #expect(coordinator.results.contains { $0.id == "web-search" })
        #expect(!coordinator.isSearching)
    }

    @Test func resetCancelsInFlightWorkAndClearsPublishedState() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode")],
                indexed: [SearchFixtures.application(name: "Xcode Beta")],
                indexedDelay: .milliseconds(400)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        coordinator.selectFilter(.applications)
        coordinator.reset()

        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
        #expect(coordinator.selectedFilter == .all)
        #expect(!coordinator.isSearching)

        try await Task.sleep(for: .milliseconds(600))
        #expect(
            coordinator.results.isEmpty,
            "a cancelled search must not repopulate the panel after a reset"
        )
    }

    @Test func resetDoesNotItselfTriggerASearch() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        let afterTyping = applications.queries.count
        coordinator.reset()

        #expect(
            applications.queries.count == afterTyping,
            "the isResetting guard should suppress the search that clearing the query would start"
        )
    }

    // MARK: - Selection

    @Test func selectionClampsAtBothEndsOfTheList() async throws {
        let applications = ScriptedCatalog(
            immediate: (0..<5).map {
                SearchFixtures.application(id: "app:\($0)", name: "App \($0)", score: 120_000 - $0)
            }
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "app"

        let ids = coordinator.results.map(\.id)
        #expect(coordinator.selectedID == ids.first)

        coordinator.moveSelection(by: -1)
        #expect(coordinator.selectedID == ids.first, "up from the top stays at the top")

        coordinator.moveSelection(by: 1_000)
        #expect(coordinator.selectedID == ids.last, "a huge jump clamps to the last row")

        coordinator.moveSelection(by: 1)
        #expect(coordinator.selectedID == ids.last)

        coordinator.moveSelection(by: -1_000)
        #expect(coordinator.selectedID == ids.first)
    }

    @Test func movingSelectionOnAnEmptyListIsANoOp() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.moveSelection(by: 1)
        #expect(coordinator.selectedID == nil)
        coordinator.moveSelection(by: -1)
        #expect(coordinator.selectedID == nil)
    }

    @Test func AUserDrivenSelectionSurvivesTheIndexedPass() async throws {
        // Once the user has arrowed down, a late-landing result set must not
        // yank the selection back to the top.
        let initialApps = (0..<4).map {
            SearchFixtures.application(
                id: "app:\($0)",
                name: "App \($0)",
                score: 120_000 - $0
            )
        }
        let applications = ScriptedCatalog(
            .init(
                immediate: initialApps,
                indexed: initialApps + [
                    SearchFixtures.application(
                        id: "app:late",
                        name: "App Late",
                        score: 100
                    ),
                ],
                indexedDelay: .milliseconds(300)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "app"
        try await waitUntil("the immediate applications arrive", timeout: 10) {
            coordinator.results.filter { $0.kind == .application }.count == 4
        }
        coordinator.moveSelection(by: 2)
        let chosen = coordinator.selectedID
        #expect(chosen == "app:2")

        try await settle(coordinator)

        #expect(coordinator.selectedID == chosen, "the indexed pass stole the user's selection")
    }

    @Test func anAutomaticWebFallbackSelectionYieldsToARealResult() async throws {
        // With no local matches the web row is selected by default. As soon
        // as a real result lands, the selection should move to it — but only
        // because the user never chose the web row themselves.
        let applications = ScriptedCatalog(
            .init(
                immediate: [],
                indexed: [SearchFixtures.application(id: "app:late", name: "Late", score: 120_000)],
                indexedDelay: .milliseconds(80)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "late"
        try await waitUntil("the web fallback arrives") {
            coordinator.selectedID == "web-search"
        }
        #expect(coordinator.selectedID == "web-search")

        try await settle(coordinator)

        #expect(coordinator.selectedID == "app:late")
    }

    @Test func anExplicitlyChosenWebFallbackKeepsTheSelection() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [],
                indexed: [SearchFixtures.application(id: "app:late", name: "Late", score: 120_000)],
                indexedDelay: .milliseconds(80)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "late"
        try await waitUntil("the web fallback arrives") {
            coordinator.results.contains { $0.id == "web-search" }
        }
        let web = try #require(coordinator.results.first { $0.id == "web-search" })
        coordinator.select(web)

        try await settle(coordinator)

        #expect(
            coordinator.selectedID == "web-search",
            "a deliberate selection must not be overridden by a later result"
        )
    }

    // MARK: - Filters

    @Test func selectingAFilterNarrowsResultsAndResetsSelection() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let settings = ScriptedCatalog(
            immediate: [SearchFixtures.setting(title: "Keyboard", score: 11_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications, settings: settings)
        coordinator.query = "k"
        try await waitUntil("application and settings candidates arrive") {
            coordinator.results.contains { $0.kind == .application }
                && coordinator.results.contains { $0.kind == .systemSetting }
        }

        coordinator.selectFilter(.applications)
        #expect(coordinator.results.allSatisfy { $0.kind == .application })
        #expect(coordinator.selectedID == coordinator.results.first?.id)

        coordinator.selectFilter(.settings)
        #expect(coordinator.results.allSatisfy { $0.kind == .systemSetting })

        coordinator.selectFilter(.all)
        #expect(coordinator.results.contains { $0.kind == .web })
    }

    @Test func reselectingTheActiveFilterOnlyRefocusesTheField() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )
        coordinator.query = "xcode"
        coordinator.selectFilter(.applications)

        let resultsBefore = coordinator.results.map(\.id)
        let focusBefore = coordinator.focusGeneration

        coordinator.selectFilter(.applications)

        #expect(coordinator.results.map(\.id) == resultsBefore)
        #expect(coordinator.focusGeneration == focusBefore + 1)
    }

    @Test func AFilterWithNoMatchesEmptiesTheListAndTheSelection() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )
        coordinator.query = "xcode"

        coordinator.selectFilter(.folders)

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.selectedID == nil)
    }

    @Test func filterCountsPreferTheCatalogTotalOverTheVisibleCount() async throws {
        // The chip should say how many results exist, not how many fit in
        // the page the coordinator asked for.
        let applications = ScriptedCatalog(
            .init(
                immediate: (0..<12).map {
                    SearchFixtures.application(id: "app:\($0)", name: "App \($0)")
                },
                totalMatched: 137
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "app"
        try await waitUntil("the application total arrives") {
            coordinator.filterOptions.first { $0.filter == .applications }?.count == 137
        }

        let option = try #require(coordinator.filterOptions.first { $0.filter == .applications })
        #expect(option.count == 137)
    }

    @Test func dynamicFiltersOnlyAppearOnceTheyHaveResults() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"

        #expect(!coordinator.filterOptions.contains { $0.filter == .pdfs })

        // A selected dynamic filter stays visible even at zero, so the chip
        // the user is standing on cannot vanish underneath them.
        coordinator.selectFilter(.pdfs)
        #expect(coordinator.filterOptions.contains { $0.filter == .pdfs })
    }

    @Test func thePrimaryFiltersAreAlwaysPresentInOrder() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "anything"

        #expect(Array(coordinator.filterOptions.prefix(4)).map(\.filter) == SearchResultFilter
            .primary)
    }

    @Test func loadingFlagsReportEachCatalogSeparately() async throws {
        let coordinator = try await makeCoordinator()

        // Before `start()`, both catalogs are still loading.
        #expect(coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == true)
        #expect(coordinator.filterOptions.first { $0.filter == .all }?.isLoading == true)

        coordinator.start()
        try await waitUntil("both catalogs finish loading") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }
        #expect(coordinator.filterOptions.first { $0.filter == .all }?.isLoading == false)
    }

    // MARK: - Startup

    @Test func startupIsIdempotent() async throws {
        let applications = ScriptedCatalog()
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.start()
        coordinator.start()
        coordinator.start()
        try await waitUntil("startup completes") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }

        #expect(applications.starts == 1, "start() must only run once per launch")
    }

    @Test func AFailingCatalogStartStillClearsTheLoadingFlags() async throws {
        // If a catalog throws on startup the chips must not spin forever.
        let applications = ScriptedCatalog(.init(startError: TestError.scripted("no disk access")))
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.start()
        try await waitUntil("the failure is absorbed") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }
        // `.settings` is a dynamic chip and stays hidden at zero results,
        // so the aggregate `.all` flag is what proves both catalogs
        // finished loading.
        #expect(coordinator.filterOptions.first { $0.filter == .all }?.isLoading == false)
    }

    @Test func startupResolvesWhichAssistantEnginesAreInstalled() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        coordinator.query = "claude explain this"
        #expect(!coordinator.results.contains { $0.id == "keyword-engine:claude" })

        coordinator.start()
        try await waitUntil("the resolved registry is adopted") {
            coordinator.results.contains { $0.id == "keyword-engine:claude" }
        }

        let checked = await runner.checkedCommands
        #expect(checked.sorted() == ["claude", "codex"])

        coordinator.query = "codex explain this"
        try await settle(coordinator)
        #expect(!coordinator.results.contains { $0.id == "keyword-engine:codex" })
    }

    @Test func preparingForPresentationRefocusesAndResearches() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await settle(coordinator)

        let focusBefore = coordinator.focusGeneration
        let queriesBefore = applications.queries.count

        coordinator.prepareForPresentation()

        #expect(coordinator.focusGeneration == focusBefore + 1)
        try await waitUntil("presentation starts a fresh Source Search") {
            applications.queries.count > queriesBefore
        }
        #expect(
            applications.queries.count > queriesBefore,
            "re-presenting with a live query should re-run the search"
        )
    }

    @Test func preparingForPresentationWithNoQueryDoesNotSearch() async throws {
        let applications = ScriptedCatalog()
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.prepareForPresentation()

        #expect(coordinator.focusGeneration == 1)
        #expect(applications.queries.isEmpty)
    }

    // MARK: - Assistant lifecycle

    private func assistantRow(_ coordinator: SearchCoordinator) throws -> SearchItem {
        try #require(projectResults(
            query: "claude explain this function",
            indexed: [],
            apps: [],
            system: [],
            keywordRegistry: KeywordEngineRegistry(
                engines: KeywordEngineCatalog.all,
                defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
            )
        ).first { $0.id == "keyword-engine:claude" })
    }

    @Test func anAssistantAnswerIsOnlyOfferedToItsOwnRow() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(with: .success("Because it sums the list."))
        try await waitUntil("the answer arrives") {
            coordinator.assistantAnswerState(for: row) == .answered("Because it sums the list.")
        }

        let otherRow = SearchFixtures.application(name: "Xcode")
        #expect(
            coordinator.assistantAnswerState(for: otherRow) == nil,
            "an answer must never render under an unrelated row"
        )
    }

    @Test func twoConsecutiveAsksDiscardTheFirstAnswer() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.waitForPendingRun()
        coordinator.activate(row)

        // Cancelling the first ask removes its continuation asynchronously
        // from the scripted runner. Wait until that settles and only the
        // replacement ask is pending before resolving — otherwise resolveAll
        // can hand the success to the superseded ask.
        try await waitUntil("the superseded ask is cancelled") {
            let cancellations = await runner.cancellations
            let pending = await runner.pendingCount
            return cancellations >= 1 && pending == 1
        }
        try await runner.resolveNext(with: .success("second answer"))

        try await waitUntil("the surviving ask answers") {
            coordinator.assistantAnswerState(for: row) == .answered("second answer")
        }
        #expect(coordinator.assistantRun?.itemID == row.id)
        let cancelled = await runner.cancellations
        #expect(cancelled >= 1, "the superseded ask should be cancelled")
    }

    @Test func AMissingBinaryReportsAnInstallHint() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: [])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(
            with: .failure(AssistantProcessError.executableNotFound("claude"))
        )

        try await waitUntil("the failure surfaces") {
            coordinator.assistantAnswerState(for: row) == .failed("claude isn't installed.")
        }
    }

    @Test func ATimeoutReportsAHumanMessageRatherThanAnErrorDescription() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(with: .failure(AssistantProcessError.timedOut))

        try await waitUntil("the timeout surfaces") {
            coordinator.assistantAnswerState(for: row)
                == .failed("That ask took too long and was stopped.")
        }
    }

    @Test func anEmptyStderrFallsBackToAGenericFailure() async throws {
        // `nonZeroExit` with an empty message falls through to the generic
        // catch, so the panel never shows a blank error row.
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(
            with: .failure(AssistantProcessError.nonZeroExit(status: 3, message: ""))
        )

        try await waitUntil("the generic failure surfaces") {
            coordinator.assistantAnswerState(for: row) == .failed("That ask failed.")
        }
    }

    @Test func anUnknownErrorFallsBackToAGenericFailure() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(with: .failure(TestError.scripted("something odd")))

        try await waitUntil("the generic failure surfaces") {
            coordinator.assistantAnswerState(for: row) == .failed("That ask failed.")
        }
    }

    @Test func editingTheQueryClearsTheAnswerSynchronously() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.query = "claude explain this function"
        coordinator.activate(row)
        try await runner.resolveNext(with: .success("an answer"))
        try await waitUntil("the answer arrives") {
            coordinator.assistantAnswerState(for: row) == .answered("an answer")
        }

        coordinator.query = "claude explain something else"

        #expect(
            coordinator.assistantRun == nil,
            "a stale answer must never linger under a new query"
        )
    }

    @Test func activatingAnAssistantRowKeepsThePanelOpen() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        var dismissed = false
        let coordinator = try await makeCoordinator(
            runner: runner,
            onDismiss: { dismissed = true }
        )

        try coordinator.activate(assistantRow(coordinator))

        #expect(!dismissed)
        #expect(coordinator.assistantRun?.state == .running)
    }
}
