import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest
@testable import Floodlight

/// Drives the Tab↔Esc web mode through `SearchCoordinator`'s published
/// surface — the same seam `SearchCoordinatorIntegrationTests` uses:
/// scripted catalogs in, assertions on `results`, `mode`, `selectedID`,
/// and `filterOptions` out. Never on internal call order.
@MainActor
final class SearchCoordinatorWebModeTests: XCTestCase {
    private nonisolated(unsafe) var tree: TemporaryTree!

    private static let presetOrder = [
        "google", "wikipedia", "github", "stackoverflow", "twitter", "youtube",
    ]

    override func setUpWithError() throws {
        tree = try TemporaryTree(label: "CoordinatorWebMode")
    }

    override func tearDown() {
        tree = nil
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

    // MARK: - Entering web mode

    func testTabPublishesOnePresetEngineRowEachWithTheDefaultEngineFirst() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift concurrency"

        coordinator.handleTab()

        XCTAssertEqual(
            coordinator.results.map(\.id),
            Self.presetOrder.map { "web-mode:\($0)" }
        )
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .web })
        XCTAssertEqual(coordinator.selectedID, "web-mode:google")
    }

    func testKeywordTabPutsThatEngineFirstAndTheRestInTableOrder() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"

        coordinator.handleTab()

        XCTAssertEqual(coordinator.query, "lofi", "the keyword is absorbed into the token")
        XCTAssertEqual(
            coordinator.results.map(\.id),
            ["web-mode:youtube"] + Self.presetOrder.dropLast().map { "web-mode:\($0)" }
        )
        XCTAssertEqual(coordinator.selectedID, "web-mode:youtube")
        XCTAssertEqual(coordinator.results.first?.title, "YouTube")
        XCTAssertEqual(coordinator.results.first?.subtitle, "youtube.com")
    }

    func testWebModeRowTitlesStayStableWhileURLsTrackTheLiveQuery() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "lofi"
        coordinator.handleTab()
        let titleBefore = coordinator.results.first?.title

        coordinator.query = "lofi beats"

        // The title names the destination, so it must not reflow per
        // keystroke; the live query rides in the URL the row opens.
        let first = coordinator.results.first
        XCTAssertEqual(first?.title, "Google")
        XCTAssertEqual(first?.title, titleBefore)
        XCTAssertEqual(
            openedURL(of: first)?.absoluteString,
            "https://www.google.com/search?q=lofi%20beats"
        )
    }

    func testWebModeRowsCarryThePercentEncodedEngineURL() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi hip hop"

        coordinator.handleTab()

        XCTAssertEqual(
            openedURL(of: coordinator.results.first)?.absoluteString,
            "https://www.youtube.com/results?search_query=lofi%20hip%20hop"
        )
    }

    func testArrowSelectionSwitchesEngineAndSurvivesFurtherTyping() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift"
        coordinator.handleTab()

        coordinator.moveSelection(by: 1)
        XCTAssertEqual(coordinator.selectedID, "web-mode:wikipedia")

        coordinator.query = "swift actors"
        XCTAssertEqual(
            coordinator.selectedID,
            "web-mode:wikipedia",
            "typing must not steal the engine the user arrowed to"
        )
    }

    func testTabWhileInWebModeChangesNothing() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "swift"
        coordinator.handleTab()
        let before = (coordinator.mode, coordinator.query, coordinator.results.map(\.id))

        coordinator.handleTab()

        XCTAssertEqual(coordinator.mode, before.0)
        XCTAssertEqual(coordinator.query, before.1)
        XCTAssertEqual(coordinator.results.map(\.id), before.2)
    }

    // MARK: - The local passes pause

    func testTypingInWebModeNeverTouchesTheLocalCatalogs() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        coordinator.handleTab()
        let queriesBefore = applications.queries.count

        coordinator.query = "xcode concurrency"
        coordinator.query = "xcode concurrency crash"

        XCTAssertEqual(
            applications.queries.count,
            queriesBefore,
            "the immediate and indexed passes pause while web mode is active"
        )
        XCTAssertFalse(coordinator.isSearching)
    }

    func testAnInFlightLocalSnapshotCannotOverwriteWebModeRows() async throws {
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

        XCTAssertTrue(coordinator.results.allSatisfy { $0.id.hasPrefix("web-mode:") })
        XCTAssertFalse(coordinator.results.contains { $0.id == "app:late" })
    }

    func testOldLocalStreamTerminationCannotCancelTheRestoredLocalExecution() async throws {
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

        XCTAssertTrue(coordinator.results.contains { $0.id == "app:new" })
        XCTAssertFalse(coordinator.results.contains { $0.id == "app:old" })
    }

    // MARK: - Return semantics

    func testReturnOnAnEmptyWebModeQueryDoesNothing() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })

        coordinator.handleTab()
        XCTAssertEqual(coordinator.results.first?.title, "Google")

        coordinator.openSelection()

        XCTAssertFalse(dismissed, "an empty web-mode query must never fire a search")
    }

    func testClickingARowWithAnEmptyQueryAlsoDoesNothing() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })

        coordinator.handleTab()
        let row = try XCTUnwrap(coordinator.results.last)

        coordinator.activate(row)

        XCTAssertFalse(dismissed)
        XCTAssertEqual(coordinator.selectedID, row.id, "the click still selects the row")
    }

    // MARK: - Exiting web mode

    func testEscapeRestoresLocalResultsForTheReconstructedQuery() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "yt lofi"
        coordinator.handleTab()

        coordinator.handleEscape()

        XCTAssertEqual(coordinator.mode, .local)
        XCTAssertEqual(coordinator.query, "yt lofi")
        try await waitUntil("the reconstructed local results arrive") {
            coordinator.results.contains { $0.id == "keyword-engine:youtube" }
        }
        XCTAssertTrue(
            coordinator.results.contains { $0.id == "keyword-engine:youtube" },
            "the reconstructed query addresses the same engine's ranked row"
        )
        XCTAssertFalse(coordinator.results.contains { $0.id.hasPrefix("web-mode:") })
    }

    func testEscapeInWebModeDoesNotDismissButASecondEscapeDoes() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })
        coordinator.query = "swift"
        coordinator.handleTab()

        coordinator.handleEscape()
        XCTAssertFalse(dismissed, "the first Esc only exits the mode")
        XCTAssertEqual(coordinator.mode, .local)

        coordinator.handleEscape()
        XCTAssertTrue(dismissed, "the second Esc dismisses the panel as today")
    }

    func testShiftTabAndBackspaceOnEmptyQueryExitTheMode() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "yt lofi"
        coordinator.handleTab()
        coordinator.handleShiftTab()
        XCTAssertEqual(coordinator.mode, .local)
        XCTAssertEqual(coordinator.query, "yt lofi")

        coordinator.query = "yt"
        coordinator.handleTab()
        XCTAssertEqual(coordinator.query, "")
        coordinator.handleBackspaceOnEmptyQuery()
        XCTAssertEqual(coordinator.mode, .local)
        XCTAssertEqual(coordinator.query, "yt", "the bare keyword round-trips back into the field")
    }

    // MARK: - Filter chips

    func testNonDefaultFilterIsSuppressedInWebModeAndRestoredOnExit() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await waitUntil("the application result arrives") {
            coordinator.results.contains { $0.kind == .application }
        }
        coordinator.selectFilter(.applications)
        XCTAssertEqual(coordinator.selectedFilter, .applications)

        coordinator.handleTab()
        coordinator.query = "xcode editor"
        XCTAssertTrue(
            coordinator.filterOptions.isEmpty,
            "local-only controls must not suggest they filter web engines"
        )

        coordinator.handleEscape()
        try await waitUntil("filtered local results return") {
            !coordinator.results.isEmpty && !coordinator.isSearching
        }
        XCTAssertEqual(coordinator.selectedFilter, .applications)
        XCTAssertTrue(coordinator.results.allSatisfy { $0.kind == .application })
    }

    // MARK: - Reset

    func testResetReturnsTheModeToLocalAlongsideTheQuery() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"
        coordinator.handleTab()

        coordinator.reset()

        XCTAssertEqual(coordinator.mode, .local)
        XCTAssertEqual(coordinator.query, "")
        XCTAssertTrue(coordinator.results.isEmpty)
    }

    // MARK: - The keyword row's Tab affordance

    func testTheKeywordRowAdvertisesTabCompletionForURLEngines() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "yt lofi"

        try await waitUntil("the addressed-search row arrives") {
            coordinator.results.contains { $0.id == "keyword-engine:youtube" }
        }
        let row = try XCTUnwrap(coordinator.results.first { $0.id == "keyword-engine:youtube" })
        XCTAssertEqual(coordinator.tabCompletionHint(for: row), "Search YouTube")

        let other = try XCTUnwrap(coordinator.results.first { $0.id == "web-search" })
        XCTAssertNil(coordinator.tabCompletionHint(for: other))
    }

    func testNoTabAffordanceWithoutAKeywordMatch() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "budget report"

        for row in coordinator.results {
            XCTAssertNil(coordinator.tabCompletionHint(for: row), row.id)
        }
    }

    // MARK: - The fallback row sources the table

    func testTheFallbackRowDerivesTitleAndURLFromTheDefaultEngine() async throws {
        let coordinator = try await makeCoordinator()
        coordinator.query = "quaternion slerp"

        try await waitUntil("the web fallback arrives") {
            coordinator.results.contains { $0.id == "web-search" }
        }
        let fallback = try XCTUnwrap(coordinator.results.first { $0.id == "web-search" })
        XCTAssertEqual(fallback.title, "Google")
        XCTAssertEqual(fallback.subtitle, "google.com")
        XCTAssertEqual(
            openedURL(of: fallback)?.absoluteString,
            "https://www.google.com/search?q=quaternion%20slerp"
        )
    }
}
