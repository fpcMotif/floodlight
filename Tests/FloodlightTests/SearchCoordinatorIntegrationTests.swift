import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest
@testable import Floodlight

/// Drives `SearchCoordinator` through its real pipeline — the query
/// observer, the two-phase search, the generation guard, filter
/// reconciliation, and selection — using scripted catalogs so the
/// assertions are about the coordinator rather than about whatever happens
/// to be installed on the machine running the tests.
///
/// The existing coordinator tests call `buildResults` directly, which skips
/// the part most likely to break: the asynchronous half, where a slow
/// indexed pass can land after the user has already typed something else.
@MainActor
final class SearchCoordinatorIntegrationTests: XCTestCase {

    private var tree: TemporaryTree!

    override func setUpWithError() throws {
        tree = try TemporaryTree(label: "CoordinatorIntegration")
    }

    override func tearDown() {
        tree = nil
    }

    private func makeIndex() throws -> FFFIndex {
        FFFIndex(
            rootURL: tree.root,
            storageURL: tree.root.appendingPathComponent(".index", isDirectory: true),
            enableContentIndexing: false,
            includeBinaryFiles: false,
            watch: false
        )
    }

    /// Builds a coordinator over a *started* index.
    ///
    /// Starting it matters more than it looks: `scheduleSearch` runs the
    /// file search and the application search as sibling `async let`s, so
    /// an unstarted index throwing takes the whole `do` block to its
    /// `catch` and the indexed application results are discarded with it.
    /// A coordinator built over a cold index silently never merges its
    /// second pass.
    private func makeCoordinator(
        applications: ScriptedCatalog = ScriptedCatalog(),
        settings: ScriptedCatalog = ScriptedCatalog(),
        runner: ScriptedAssistantRunner = ScriptedAssistantRunner()
    ) async throws -> SearchCoordinator {
        let index = try makeIndex()
        try await index.start()
        return SearchCoordinator(
            index: index,
            applicationCatalog: applications,
            settingsCatalog: settings,
            recentStore: RecentStore(defaults: try IsolatedDefaults().defaults),
            rootURL: tree.root,
            assistantRunner: runner
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never became true: \(description)", file: file, line: line)
    }

    /// Lets the debounced indexed pass run to completion.
    private func settle(_ coordinator: SearchCoordinator) async throws {
        try await waitUntil("the indexed pass finishes") { !coordinator.isSearching }
    }

    // MARK: - The immediate pass

    func testTypingPublishesImmediateResultsSynchronously() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let settings = ScriptedCatalog(
            immediate: [SearchFixtures.setting(title: "Keyboard", score: 11_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications, settings: settings)

        coordinator.query = "x"

        // No awaiting: the first page has to be on screen before the next
        // keystroke, which is the whole point of the immediate pass.
        XCTAssertTrue(coordinator.results.contains { $0.id == "application:/Applications/Xcode.app" })
        XCTAssertTrue(coordinator.results.contains { $0.kind == .systemSetting })
        XCTAssertTrue(coordinator.results.contains { $0.id == "web-search" })
        XCTAssertTrue(coordinator.isSearching, "the asynchronous pass should be pending")
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)
    }

    func testTheIndexedPassMergesItsResultsIn() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)],
                indexed: [SearchFixtures.application(name: "Xcode Beta", score: 119_000)]
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        XCTAssertFalse(coordinator.results.contains { $0.title == "Xcode Beta" })

        try await settle(coordinator)

        XCTAssertTrue(coordinator.results.contains { $0.title == "Xcode Beta" })
        XCTAssertTrue(coordinator.results.contains { $0.title == "Xcode" })
    }

    func testAnEmptyQueryClearsEverythingImmediately() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        XCTAssertFalse(coordinator.results.isEmpty)

        coordinator.query = ""

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertFalse(coordinator.isSearching)
        XCTAssertEqual(coordinator.selectedFilter, .all)
    }

    func testAWhitespaceOnlyQueryIsTreatedAsEmpty() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )

        for query in [" ", "\t", "\n", "   \n\t "] {
            coordinator.query = query
            XCTAssertTrue(coordinator.results.isEmpty, String(reflecting: query))
            XCTAssertNil(coordinator.selectedID)
        }
    }

    func testAssigningTheSameQueryTwiceDoesNotResearch() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        let afterFirst = applications.queries.count
        coordinator.query = "xcode"

        XCTAssertEqual(
            applications.queries.count,
            afterFirst,
            "the didSet guard should ignore an identical assignment"
        )
    }

    func testTheQueryIsTrimmedBeforeReachingTheCatalogs() async throws {
        let applications = ScriptedCatalog(immediate: [])
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "  xcode \n "

        XCTAssertEqual(applications.queries, ["xcode"])
    }

    // MARK: - Staleness and the generation guard

    func testASlowIndexedPassForAnOldQueryNeverOverwritesANewerOne() async throws {
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

        XCTAssertTrue(coordinator.results.contains { $0.id == "app:fresh" })
        XCTAssertFalse(
            coordinator.results.contains { $0.id == "app:stale" },
            "results from an abandoned query leaked into the current one"
        )
        XCTAssertFalse(coordinator.results.contains { $0.id == "app:slow" })
    }

    func testRapidTypingLeavesOnlyTheFinalQuerysResults() async throws {
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

        XCTAssertTrue(coordinator.results.contains { $0.id == "app:search" })
        for stale in ["s", "se", "sea", "sear", "searc"] {
            XCTAssertFalse(
                coordinator.results.contains { $0.id == "app:\(stale)" },
                "\(stale) should have been superseded"
            )
        }
    }

    func testAFailingIndexedPassFallsBackToTheImmediateResults() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode")],
                indexedError: TestError.scripted("index unavailable")
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        try await settle(coordinator)

        XCTAssertTrue(
            coordinator.results.contains { $0.title == "Xcode" },
            "a failed indexed pass must not clear what the immediate pass found"
        )
        XCTAssertTrue(coordinator.results.contains { $0.id == "web-search" })
        XCTAssertFalse(coordinator.isSearching)
    }

    func testResetCancelsInFlightWorkAndClearsPublishedState() async throws {
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

        XCTAssertEqual(coordinator.query, "")
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
        XCTAssertEqual(coordinator.selectedFilter, .all)
        XCTAssertFalse(coordinator.isSearching)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            coordinator.results.isEmpty,
            "a cancelled search must not repopulate the panel after a reset"
        )
    }

    func testResetDoesNotItselfTriggerASearch() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "xcode"
        let afterTyping = applications.queries.count
        coordinator.reset()

        XCTAssertEqual(
            applications.queries.count,
            afterTyping,
            "the isResetting guard should suppress the search that clearing the query would start"
        )
    }

    // MARK: - Selection

    func testSelectionClampsAtBothEndsOfTheList() async throws {
        let applications = ScriptedCatalog(
            immediate: (0..<5).map {
                SearchFixtures.application(id: "app:\($0)", name: "App \($0)", score: 120_000 - $0)
            }
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "app"

        let ids = coordinator.results.map(\.id)
        XCTAssertEqual(coordinator.selectedID, ids.first)

        coordinator.moveSelection(by: -1)
        XCTAssertEqual(coordinator.selectedID, ids.first, "up from the top stays at the top")

        coordinator.moveSelection(by: 1_000)
        XCTAssertEqual(coordinator.selectedID, ids.last, "a huge jump clamps to the last row")

        coordinator.moveSelection(by: 1)
        XCTAssertEqual(coordinator.selectedID, ids.last)

        coordinator.moveSelection(by: -1_000)
        XCTAssertEqual(coordinator.selectedID, ids.first)
    }

    func testMovingSelectionOnAnEmptyListIsANoOp() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.moveSelection(by: 1)
        XCTAssertNil(coordinator.selectedID)
        coordinator.moveSelection(by: -1)
        XCTAssertNil(coordinator.selectedID)
    }

    func testAUserDrivenSelectionSurvivesTheIndexedPass() async throws {
        // Once the user has arrowed down, a late-landing result set must not
        // yank the selection back to the top.
        let applications = ScriptedCatalog(
            .init(
                immediate: (0..<4).map {
                    SearchFixtures.application(id: "app:\($0)", name: "App \($0)", score: 120_000 - $0)
                },
                indexed: [SearchFixtures.application(id: "app:late", name: "App Late", score: 100)],
                indexedDelay: .milliseconds(120)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "app"
        coordinator.moveSelection(by: 2)
        let chosen = coordinator.selectedID
        XCTAssertEqual(chosen, "app:2")

        try await settle(coordinator)

        XCTAssertEqual(coordinator.selectedID, chosen, "the indexed pass stole the user's selection")
    }

    func testAnAutomaticWebFallbackSelectionYieldsToARealResult() async throws {
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
        XCTAssertEqual(coordinator.selectedID, "web-search")

        try await settle(coordinator)

        XCTAssertEqual(coordinator.selectedID, "app:late")
    }

    func testAnExplicitlyChosenWebFallbackKeepsTheSelection() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [],
                indexed: [SearchFixtures.application(id: "app:late", name: "Late", score: 120_000)],
                indexedDelay: .milliseconds(80)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "late"
        let web = try XCTUnwrap(coordinator.results.first { $0.id == "web-search" })
        coordinator.select(web)

        try await settle(coordinator)

        XCTAssertEqual(
            coordinator.selectedID,
            "web-search",
            "a deliberate selection must not be overridden by a later result"
        )
    }

    // MARK: - Filters

    func testSelectingAFilterNarrowsResultsAndResetsSelection() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let settings = ScriptedCatalog(
            immediate: [SearchFixtures.setting(title: "Keyboard", score: 11_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications, settings: settings)
        coordinator.query = "k"

        coordinator.selectFilter(.applications)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .application })
        XCTAssertEqual(coordinator.selectedID, coordinator.results.first?.id)

        coordinator.selectFilter(.settings)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .systemSetting })

        coordinator.selectFilter(.all)
        XCTAssertTrue(coordinator.results.contains { $0.kind == .web })
    }

    func testReselectingTheActiveFilterOnlyRefocusesTheField() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )
        coordinator.query = "xcode"
        coordinator.selectFilter(.applications)

        let resultsBefore = coordinator.results.map(\.id)
        let focusBefore = coordinator.focusGeneration

        coordinator.selectFilter(.applications)

        XCTAssertEqual(coordinator.results.map(\.id), resultsBefore)
        XCTAssertEqual(coordinator.focusGeneration, focusBefore + 1)
    }

    func testAFilterWithNoMatchesEmptiesTheListAndTheSelection() async throws {
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )
        coordinator.query = "xcode"

        coordinator.selectFilter(.folders)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertNil(coordinator.selectedID)
    }

    func testFilterCountsPreferTheCatalogTotalOverTheVisibleCount() async throws {
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

        let option = try XCTUnwrap(
            coordinator.filterOptions.first { $0.filter == .applications }
        )
        XCTAssertEqual(option.count, 137)
    }

    func testDynamicFiltersOnlyAppearOnceTheyHaveResults() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"

        XCTAssertFalse(coordinator.filterOptions.contains { $0.filter == .pdfs })

        // A selected dynamic filter stays visible even at zero, so the chip
        // the user is standing on cannot vanish underneath them.
        coordinator.selectFilter(.pdfs)
        XCTAssertTrue(coordinator.filterOptions.contains { $0.filter == .pdfs })
    }

    func testThePrimaryFiltersAreAlwaysPresentInOrder() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "anything"

        XCTAssertEqual(
            Array(coordinator.filterOptions.prefix(4)).map(\.filter),
            SearchResultFilter.primary
        )
    }

    func testAnEmptiedDynamicFilterFallsBackToAllOnceLoadingFinishes() async throws {
        // Standing on "PDFs" while the results change out from under you
        // must not strand the panel on an empty chip.
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.start()
        try await waitUntil("startup completes") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }

        coordinator.query = "xcode"
        coordinator.selectFilter(.pdfs)
        XCTAssertEqual(coordinator.selectedFilter, .pdfs)

        try await settle(coordinator)

        XCTAssertEqual(
            coordinator.selectedFilter,
            .all,
            "an empty dynamic filter should hand back to All once the search settles"
        )
    }

    func testLoadingFlagsReportEachCatalogSeparately() async throws {
        let coordinator = try await makeCoordinator()

        // Before `start()`, both catalogs are still loading.
        XCTAssertEqual(
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading,
            true
        )
        XCTAssertEqual(
            coordinator.filterOptions.first { $0.filter == .all }?.isLoading,
            true
        )

        coordinator.start()
        try await waitUntil("both catalogs finish loading") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }
        XCTAssertEqual(
            coordinator.filterOptions.first { $0.filter == .all }?.isLoading,
            false
        )
    }

    // MARK: - Startup

    func testStartupIsIdempotent() async throws {
        let applications = ScriptedCatalog()
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.start()
        coordinator.start()
        coordinator.start()
        try await waitUntil("startup completes") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }

        XCTAssertEqual(applications.starts, 1, "start() must only run once per launch")
    }

    func testAFailingCatalogStartStillClearsTheLoadingFlags() async throws {
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
        XCTAssertEqual(
            coordinator.filterOptions.first { $0.filter == .all }?.isLoading,
            false
        )
    }

    func testStartupResolvesWhichAssistantEnginesAreInstalled() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)

        coordinator.start()
        try await waitUntil("availability is probed") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }
        try await waitUntil("the engine list is adopted") {
            !coordinator.buildResults(
                query: "claude explain this",
                indexed: [],
                apps: [],
                system: [],
                keywordEngines: KeywordEngineCatalog.all
            ).isEmpty
        }

        let checked = await runner.checkedCommands
        XCTAssertEqual(checked.sorted(), ["claude", "codex"])
    }

    func testPreparingForPresentationRefocusesAndResearches() async throws {
        let applications = ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await settle(coordinator)

        let focusBefore = coordinator.focusGeneration
        let queriesBefore = applications.queries.count

        coordinator.prepareForPresentation()

        XCTAssertEqual(coordinator.focusGeneration, focusBefore + 1)
        XCTAssertGreaterThan(
            applications.queries.count,
            queriesBefore,
            "re-presenting with a live query should re-run the search"
        )
    }

    func testPreparingForPresentationWithNoQueryDoesNotSearch() async throws {
        let applications = ScriptedCatalog()
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.prepareForPresentation()

        XCTAssertEqual(coordinator.focusGeneration, 1)
        XCTAssertTrue(applications.queries.isEmpty)
    }

    // MARK: - Assistant lifecycle

    private func assistantRow(_ coordinator: SearchCoordinator) throws -> SearchItem {
        try XCTUnwrap(
            coordinator.buildResults(
                query: "claude explain this function",
                indexed: [],
                apps: [],
                system: [],
                keywordEngines: KeywordEngineCatalog.all
            ).first { $0.id == "keyword-engine:claude" }
        )
    }

    func testAnAssistantAnswerIsOnlyOfferedToItsOwnRow() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(with: .success("Because it sums the list."))
        try await waitUntil("the answer arrives") {
            coordinator.assistantAnswerState(for: row) == .answered("Because it sums the list.")
        }

        let otherRow = SearchFixtures.application(name: "Xcode")
        XCTAssertNil(
            coordinator.assistantAnswerState(for: otherRow),
            "an answer must never render under an unrelated row"
        )
    }

    func testTwoConsecutiveAsksDiscardTheFirstAnswer() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.waitForPendingRun()
        coordinator.activate(row)

        // Both asks may briefly be in flight — the first is cancelled the
        // instant the second starts — so resolve whatever is pending and
        // assert that exactly one answer reaches the panel.
        try await runner.resolveAll(with: .success("second answer"))

        try await waitUntil("the surviving ask answers") {
            coordinator.assistantAnswerState(for: row) == .answered("second answer")
        }
        XCTAssertEqual(coordinator.assistantRun?.itemID, row.id)
        let cancelled = await runner.cancellations
        XCTAssertGreaterThanOrEqual(cancelled, 1, "the superseded ask should be cancelled")
    }

    func testAMissingBinaryReportsAnInstallHint() async throws {
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

    func testATimeoutReportsAHumanMessageRatherThanAnErrorDescription() async throws {
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

    func testAnEmptyStderrFallsBackToAGenericFailure() async throws {
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

    func testAnUnknownErrorFallsBackToAGenericFailure() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        let row = try assistantRow(coordinator)

        coordinator.activate(row)
        try await runner.resolveNext(with: .failure(TestError.scripted("something odd")))

        try await waitUntil("the generic failure surfaces") {
            coordinator.assistantAnswerState(for: row) == .failed("That ask failed.")
        }
    }

    func testEditingTheQueryClearsTheAnswerSynchronously() async throws {
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

        XCTAssertNil(
            coordinator.assistantRun,
            "a stale answer must never linger under a new query"
        )
    }

    func testActivatingAnAssistantRowKeepsThePanelOpen() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let coordinator = try await makeCoordinator(runner: runner)
        var dismissed = false
        coordinator.onDismiss = { dismissed = true }

        coordinator.activate(try assistantRow(coordinator))

        XCTAssertFalse(dismissed)
        XCTAssertEqual(coordinator.assistantRun?.state, .running)
    }

    func testTheSettingsCommandDismissesAndOpensSettings() async throws {
        let coordinator = try await makeCoordinator()
        var dismissed = false
        var openedSettings = false
        coordinator.onDismiss = { dismissed = true }
        coordinator.onShowSettings = { openedSettings = true }

        let command = try XCTUnwrap(
            coordinator.buildResults(query: "settings", indexed: [], apps: [], system: [])
                .first { $0.id == "floodlight-command:settings" }
        )
        coordinator.activate(command)

        XCTAssertTrue(dismissed)
        XCTAssertTrue(openedSettings)
    }

    // MARK: - Preview

    func testOnlyAPreviewableFileSelectionExposesAURL() async throws {
        let file = SearchFixtures.file(name: "notes.txt", score: 5_000)
        let folder = SearchFixtures.folder(name: "code", score: 6_000)
        let applications = ScriptedCatalog(immediate: [folder, file])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "code"

        coordinator.select(folder)
        XCTAssertNil(coordinator.previewableSelectionURL, "a folder is not previewable")

        coordinator.select(file)
        XCTAssertEqual(coordinator.previewableSelectionURL, file.fileURL)
    }

    func testNoSelectionFallsBackToTheFirstRow() async throws {
        let file = SearchFixtures.file(name: "notes.txt", score: 5_000)
        let coordinator = try await makeCoordinator(
            applications: ScriptedCatalog(immediate: [file])
        )
        coordinator.query = "notes"
        coordinator.selectedID = nil

        XCTAssertEqual(coordinator.previewableSelectionURL, file.fileURL)
    }

    // MARK: - buildResults as a pure function

    func testMergedResultsAreAlwaysDeduplicatedRankedAndCapped() async throws {
        let coordinator = try await makeCoordinator()

        try checkProperty(
            "buildResults de-duplicates, ranks, and caps at 80",
            SearchGenerators.items(count: 0...40),
            SearchGenerators.items(count: 0...40),
            SearchGenerators.items(count: 0...40),
            runs: 300
        ) { indexed, apps, system in
            let results = coordinator.buildResults(
                query: "zzzzz",
                indexed: indexed,
                apps: apps,
                system: system
            )
            let ids = results.map(\.id)
            return ids.count == Set(ids).count
                && results.count <= 80
                && zip(results, results.dropFirst()).allSatisfy { $0.score >= $1.score }
        }
    }

    func testMergedResultsAreDeterministic() async throws {
        let coordinator = try await makeCoordinator()

        try checkProperty(
            "the same inputs always produce the same merged list",
            SearchGenerators.items(count: 0...30),
            Gen<String>.element(of: AdversarialCorpus.searchQueries),
            runs: 300
        ) { items, query in
            let first = coordinator.buildResults(
                query: query, indexed: items, apps: [], system: []
            )
            let second = coordinator.buildResults(
                query: query, indexed: items, apps: [], system: []
            )
            return first.map(\.id) == second.map(\.id)
        }
    }

    func testAWebRowExistsForEveryNonEmptyQueryAndNeverForAnEmptyOne() async throws {
        let coordinator = try await makeCoordinator()

        try checkProperty(
            "the web fallback tracks query emptiness",
            Gen<String>.hostile,
            runs: 600
        ) { query in
            let results = coordinator.buildResults(
                query: query, indexed: [], apps: [], system: []
            )
            let hasWebRow = results.contains { $0.id == "web-search" }
            guard !query.isEmpty else { return !hasWebRow }
            // A query that cannot be percent-encoded produces no row; every
            // other non-empty query must.
            let encodable = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) != nil
            return hasWebRow == encodable
        }
    }

    func testBuildingResultsNeverTrapsOnHostileQueries() async throws {
        let coordinator = try await makeCoordinator()

        for query in AdversarialCorpus.strings + AdversarialCorpus.searchQueries {
            let results = coordinator.buildResults(
                query: query,
                indexed: [SearchFixtures.file(name: "notes.txt")],
                apps: [SearchFixtures.application(name: "Xcode")],
                system: [SearchFixtures.setting(title: "Keyboard")]
            )
            XCTAssertLessThanOrEqual(results.count, 80, String(reflecting: query))
            XCTAssertEqual(
                results.count,
                Set(results.map(\.id)).count,
                String(reflecting: query)
            )
        }
    }

    func testTheCoordinatorSurvivesAFloodOfQueriesWithoutLosingCoherence() async throws {
        // A stress pass over the whole observer → search → publish loop:
        // hundreds of query mutations back to back, then a check that the
        // final state matches the final query and nothing was left behind.
        let applications = ScriptedCatalog()
        for index in 0..<200 {
            applications.setBehavior(
                .init(
                    immediate: [SearchFixtures.application(id: "app:\(index)", name: "App \(index)")],
                    indexed: [SearchFixtures.application(id: "idx:\(index)", name: "Indexed \(index)")],
                    indexedDelay: .milliseconds(index.isMultiple(of: 7) ? 40 : 0)
                ),
                forQuery: "q\(index)"
            )
        }
        let coordinator = try await makeCoordinator(applications: applications)

        for index in 0..<200 {
            coordinator.query = "q\(index)"
        }
        try await settle(coordinator)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(coordinator.results.contains { $0.id == "app:199" })
        XCTAssertTrue(
            coordinator.results.allSatisfy { item in
                !item.id.hasPrefix("app:") || item.id == "app:199"
            },
            "results from abandoned queries survived the flood"
        )
        let ids = coordinator.results.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
