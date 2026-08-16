import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Drives the Tab↔Esc web mode through `SearchCoordinator`'s published
/// surface — the same seam `SearchCoordinatorIntegrationTests` uses:
/// scripted catalogs in, assertions on `results`, `mode`, `selectedID`,
/// and `filterOptions` out. Never on internal call order.
@MainActor
struct SearchCoordinatorWebModeTests {
    private let tree: TemporaryTree

    private static let presetOrder = [
        "google", "wikipedia", "github", "stackoverflow", "twitter", "youtube",
    ]

    init() throws {
        tree = try TemporaryTree(label: "CoordinatorWebMode")
    }

    private func makeCoordinator(
        applications: ScriptedCatalog = ScriptedCatalog(),
        settings: ScriptedCatalog = ScriptedCatalog(),
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
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: onDismiss
        )
    }

    private func openedURL(of item: SearchItem?) -> URL? {
        guard case let .open(url) = item?.action else { return nil }
        return url
    }

    private func waitUntil(
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

    // MARK: - Entering web mode

    @Test func tabPublishesOnePresetEngineRowEachWithTheDefaultEngineFirst() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift concurrency"

        coordinator.handleTab()

        #expect(coordinator.results.map(\.id) == Self.presetOrder.map { "web-mode:\($0)" })
        #expect(coordinator.results.allSatisfy { $0.kind == .web })
        #expect(coordinator.selectedID == "web-mode:google")
    }

    @Test func keywordTabPutsThatEngineFirstAndTheRestInTableOrder() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"

        coordinator.handleTab()

        #expect(coordinator.query == "lofi", "the keyword is absorbed into the token")
        #expect(coordinator.results.map(\.id) == ["web-mode:youtube"] + Self.presetOrder.dropLast()
            .map { "web-mode:\($0)" })
        #expect(coordinator.selectedID == "web-mode:youtube")
        #expect(coordinator.results.first?.title == "YouTube")
        #expect(coordinator.results.first?.subtitle == "youtube.com")
    }

    @Test func webModeRowTitlesStayStableWhileURLsTrackTheLiveQuery() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "lofi"
        coordinator.handleTab()
        let titleBefore = coordinator.results.first?.title

        coordinator.query = "lofi beats"

        // The title names the destination, so it must not reflow per
        // keystroke; the live query rides in the URL the row opens.
        let first = coordinator.results.first
        #expect(first?.title == "Google")
        #expect(first?.title == titleBefore)
        #expect(openedURL(of: first)?
            .absoluteString == "https://www.google.com/search?q=lofi%20beats")
    }

    @Test func webModeRowsCarryThePercentEncodedEngineURL() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi hip hop"

        coordinator.handleTab()

        #expect(openedURL(of: coordinator.results.first)?
            .absoluteString == "https://www.youtube.com/results?search_query=lofi%20hip%20hop")
    }

    @Test func arrowSelectionSwitchesEngineAndSurvivesFurtherTyping() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift"
        coordinator.handleTab()

        coordinator.moveSelection(by: 1)
        #expect(coordinator.selectedID == "web-mode:wikipedia")

        coordinator.query = "swift actors"
        #expect(
            coordinator.selectedID == "web-mode:wikipedia",
            "typing must not steal the engine the user arrowed to"
        )
    }

    @Test func tabWhileInWebModeChangesNothing() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift"
        coordinator.handleTab()
        let before = (coordinator.mode, coordinator.query, coordinator.results.map(\.id))

        coordinator.handleTab()

        #expect(coordinator.mode == before.0)
        #expect(coordinator.query == before.1)
        #expect(coordinator.results.map(\.id) == before.2)
    }

    // MARK: - The local passes pause

    @Test func typingInWebModeNeverTouchesTheLocalCatalogs() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        coordinator.handleTab()
        let queriesBefore = applications.queries.count

        coordinator.query = "xcode concurrency"
        coordinator.query = "xcode concurrency crash"

        #expect(
            applications.queries.count == queriesBefore,
            "the immediate and indexed passes pause while web mode is active"
        )
        #expect(!coordinator.isSearching)
    }

    @Test func anInFlightLocalSnapshotCannotOverwriteWebModeRows() async throws {
        let applications = ScriptedCatalog(.init(
            immediate: [SearchFixtures.application(id: "app:immediate", name: "Immediate")],
            indexed: [SearchFixtures.application(id: "app:late", name: "Late")],
            indexedDelay: .milliseconds(150)
        ))
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "late"
        try await waitUntil("the local execution starts") {
            coordinator.results.contains { $0.id == "app:immediate" }
        }

        coordinator.handleTab()
        try await Task.sleep(for: .milliseconds(250))

        #expect(coordinator.results.allSatisfy { $0.id.hasPrefix("web-mode:") })
        #expect(!coordinator.results.contains { $0.id == "app:late" })
    }

    @Test func oldLocalStreamTerminationCannotCancelTheRestoredLocalExecution() async throws {
        let applications = ScriptedCatalog()
        applications.setBehavior(
            .init(
                immediate: [SearchFixtures.application(id: "app:old", name: "Old")],
                indexedDelay: .milliseconds(200)
            ),
            forQuery: "old"
        )
        applications.setBehavior(
            .init(immediate: [SearchFixtures.application(id: "app:new", name: "New")]),
            forQuery: "new"
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "old"
        try await waitUntil("the old local execution starts") {
            coordinator.results.contains { $0.id == "app:old" }
        }

        coordinator.handleTab()
        coordinator.query = "new"
        coordinator.handleEscape()
        try await waitUntil("the restored local execution settles") {
            !coordinator.isSearching && coordinator.results.contains { $0.id == "app:new" }
        }
        try await Task.sleep(for: .milliseconds(250))

        #expect(coordinator.results.contains { $0.id == "app:new" })
        #expect(!coordinator.results.contains { $0.id == "app:old" })
    }

    // MARK: - Return semantics

    @Test func returnOnAnEmptyWebModeQueryDoesNothing() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })

        coordinator.handleTab()
        #expect(coordinator.results.first?.title == "Google")

        coordinator.openSelection()

        #expect(!dismissed, "an empty web-mode query must never fire a search")
    }

    @Test func clickingARowWithAnEmptyQueryAlsoDoesNothing() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })

        coordinator.handleTab()
        let row = try #require(coordinator.results.last)

        coordinator.activate(row)

        #expect(!dismissed)
        #expect(coordinator.selectedID == row.id, "the click still selects the row")
    }

    // MARK: - Exiting web mode

    @Test func escapeRestoresLocalResultsForTheReconstructedQuery() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "yt lofi"
        coordinator.handleTab()

        coordinator.handleEscape()

        #expect(coordinator.mode == .local)
        #expect(coordinator.query == "yt lofi")
        try await waitUntil("the reconstructed local results arrive") {
            coordinator.results.contains { $0.id == "keyword-engine:youtube" }
        }
        #expect(
            coordinator.results.contains { $0.id == "keyword-engine:youtube" },
            "the reconstructed query addresses the same engine's ranked row"
        )
        #expect(!coordinator.results.contains { $0.id.hasPrefix("web-mode:") })
    }

    @Test func escapeInWebModeDoesNotDismissButASecondEscapeDoes() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })
        coordinator.query = "swift"
        coordinator.handleTab()

        coordinator.handleEscape()
        #expect(!dismissed, "the first Esc only exits the mode")
        #expect(coordinator.mode == .local)

        coordinator.handleEscape()
        #expect(dismissed, "the second Esc dismisses the panel as today")
    }

    @Test func shiftTabAndBackspaceOnEmptyQueryExitTheMode() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "yt lofi"
        coordinator.handleTab()
        coordinator.handleShiftTab()
        #expect(coordinator.mode == .local)
        #expect(coordinator.query == "yt lofi")

        coordinator.query = "yt"
        coordinator.handleTab()
        #expect(coordinator.query.isEmpty)
        coordinator.handleBackspaceOnEmptyQuery()
        #expect(coordinator.mode == .local)
        #expect(coordinator.query == "yt", "the bare keyword round-trips back into the field")
    }

    // MARK: - Filter chips

    @Test func nonDefaultFilterIsSuppressedInWebModeAndRestoredOnExit() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await waitUntil("the application result arrives") {
            coordinator.results.contains { $0.kind == .application }
        }
        coordinator.selectFilter(.applications)
        #expect(coordinator.selectedFilter == .applications)

        coordinator.handleTab()
        coordinator.query = "xcode editor"
        #expect(
            coordinator.filterOptions.isEmpty,
            "local-only controls must not suggest they filter web engines"
        )

        coordinator.handleEscape()
        try await waitUntil("filtered local results return") {
            !coordinator.results.isEmpty && !coordinator.isSearching
        }
        #expect(coordinator.selectedFilter == .applications)
        #expect(coordinator.results.allSatisfy { $0.kind == .application })
    }

    // MARK: - Reset

    @Test func resetReturnsTheModeToLocalAlongsideTheQuery() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"
        coordinator.handleTab()

        coordinator.reset()

        #expect(coordinator.mode == .local)
        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.isEmpty)
    }

    // MARK: - The keyword row's Tab affordance

    @Test func theKeywordRowAdvertisesTabCompletionForURLEngines() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"

        try await waitUntil("the addressed-search row arrives") {
            coordinator.results.contains { $0.id == "keyword-engine:youtube" }
        }
        let row = try #require(coordinator.results.first { $0.id == "keyword-engine:youtube" })
        #expect(coordinator.tabCompletionHint(for: row) == "Search YouTube")

        let other = try #require(coordinator.results.first { $0.id == "web-search" })
        #expect(coordinator.tabCompletionHint(for: other) == nil)
    }

    @Test func noTabAffordanceWithoutAKeywordMatch() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "budget report"

        for row in coordinator.results {
            #expect(coordinator.tabCompletionHint(for: row) == nil, "\(row.id)")
        }
    }

    // MARK: - The fallback row sources the table

    @Test func theFallbackRowDerivesTitleAndURLFromTheDefaultEngine() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "quaternion slerp"

        try await waitUntil("the web fallback arrives") {
            coordinator.results.contains { $0.id == "web-search" }
        }
        let fallback = try #require(coordinator.results.first { $0.id == "web-search" })
        #expect(fallback.title == "Google")
        #expect(fallback.subtitle == "google.com")
        #expect(openedURL(of: fallback)?
            .absoluteString == "https://www.google.com/search?q=quaternion%20slerp")
    }
}
