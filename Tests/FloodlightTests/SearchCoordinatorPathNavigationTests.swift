import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Counts what deep path navigation costs, and where it is paid.
///
/// The claim under test is not "the folder row appears" — `PathNavigator`
/// already owns that, over its own injected file manager. It is that a
/// keystroke buys exactly one resolution, that every later projection of the
/// same query reuses it, and that the directory listings never land on the
/// main thread. All three are only visible from the coordinator seam, which
/// is why these drive a real `FileSystemPathResolver` over a file system the
/// test owns rather than a stubbed resolver.
@MainActor
final class SearchCoordinatorPathNavigationTests: SearchCoordinatorIntegrationTestCase {
    private let fileManager = CountingFileManager()

    /// A coordinator whose path resolution runs over `fileManager`, with the
    /// home directory pointed at an empty folder inside the tree so the
    /// machine's real home cannot add or remove a listing.
    private func makePathCoordinator(
        applications: ScriptedCatalog = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        ),
        rootURL: URL? = nil,
        wrapSourceSearch: (any SourceSearching) -> any SourceSearching = { $0 }
    ) async throws -> (SearchCoordinator, CountingPathResolver) {
        let home = try tree.makeDirectory("EmptyHome")
        let resolver = CountingPathResolver(fileManager: fileManager, homeURL: home)
        let coordinator = try await makeCoordinator(
            applications: applications,
            pathResolver: resolver,
            rootURL: rootURL,
            wrapSourceSearch: wrapSourceSearch
        )
        return (coordinator, resolver)
    }

    private func folderRow(_ coordinator: SearchCoordinator, named name: String) -> SearchItem? {
        coordinator.results.first { $0.kind == .folder && $0.title == name }
    }

    @Test func aPathQueryPublishesItsFolderRowWithTheFirstSnapshot() async throws {
        try tree.makeDirectory("Projects")
        // The indexed pass is held back so that "the first snapshot" is a
        // state the test can still be standing in when it asserts: an
        // application row on screen while the pass is unmistakably unsettled.
        // Without the delay, waiting for the application row could not tell
        // the first publication from the second. The delay is far longer than
        // the assertions need because the suite runs its tests in parallel —
        // a window sized to a quiet machine closes early on a loaded one.
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)],
                indexed: [SearchFixtures.application(name: "Xcode Beta", score: 119_000)],
                indexedDelay: .seconds(30)
            )
        )
        let (coordinator, resolver) = try await makePathCoordinator(applications: applications)

        coordinator.query = "Projects/"

        try await waitUntil("the first Source Search snapshot arrives") {
            coordinator.results.contains { $0.id == "application:/Applications/Xcode.app" }
        }
        // Same publication as the application row, and before the indexed
        // pass has landed: moving the listings off the projection must not
        // cost the folder row a beat.
        #expect(coordinator.isSearching, "the indexed pass must still be outstanding")
        #expect(!coordinator.results.contains { $0.title == "Xcode Beta" })
        #expect(folderRow(coordinator, named: "Projects/") != nil)
        #expect(resolver.resolvedQueries == ["Projects/"])
    }

    @Test func theListingsNeverHappenOnTheMainThread() async throws {
        try tree.makeDirectory("Projects")
        let (coordinator, _) = try await makePathCoordinator()

        coordinator.query = "Projects/"
        try await waitUntil("the folder row arrives") {
            folderRow(coordinator, named: "Projects/") != nil
        }
        try await settle(coordinator)

        #expect(fileManager.directoryListingCount > 0, "the query must really hit the disk")
        #expect(fileManager.mainThreadListingCount == 0)
    }

    @Test func laterSnapshotsAndAFilterSwitchReuseTheResolution() async throws {
        try tree.makeDirectory("Projects")
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)],
                indexed: [SearchFixtures.application(name: "Xcode Beta", score: 119_000)],
                indexedDelay: .milliseconds(20)
            )
        )
        let (coordinator, resolver) = try await makePathCoordinator(applications: applications)

        coordinator.query = "Projects/"
        try await waitUntil("the folder row arrives") {
            folderRow(coordinator, named: "Projects/") != nil
        }
        let afterFirstPublication = fileManager.directoryListingCount
        #expect(afterFirstPublication > 0, "the query must really hit the disk once")

        try await settle(coordinator)
        coordinator.selectFilter(.folders)
        coordinator.selectFilter(.all)
        coordinator.excludeFromSearch(SearchFixtures.application(name: "Xcode"))

        #expect(
            fileManager.directoryListingCount == afterFirstPublication,
            "a view change is a view change: no snapshot or filter may list a directory"
        )
        #expect(resolver.resolvedQueries == ["Projects/"])
        #expect(folderRow(coordinator, named: "Projects/") != nil, "the row survives the reuse")
    }

    @Test func eachNewQueryResolvesExactlyOnce() async throws {
        try tree.makeDirectory("Projects")
        try tree.makeDirectory("Archive")
        let (coordinator, resolver) = try await makePathCoordinator()

        coordinator.query = "Projects/"
        try await waitUntil("the Projects row arrives") {
            folderRow(coordinator, named: "Projects/") != nil
        }
        try await settle(coordinator)
        let afterFirstQuery = fileManager.directoryListingCount
        #expect(afterFirstQuery > 0, "the query must really hit the disk once")

        coordinator.query = "Archive/"
        try await waitUntil("the Archive row arrives") {
            folderRow(coordinator, named: "Archive/") != nil
        }
        try await settle(coordinator)

        #expect(resolver.resolvedQueries == ["Projects/", "Archive/"])
        #expect(
            fileManager.directoryListingCount == afterFirstQuery * 2,
            "the second query costs exactly what the first one did"
        )
        #expect(folderRow(coordinator, named: "Projects/") == nil)
    }

    @Test func repeatingAQueryOnRepresentationCostsNothing() async throws {
        try tree.makeDirectory("Projects")
        let (coordinator, resolver) = try await makePathCoordinator()

        coordinator.query = "Projects/"
        try await waitUntil("the folder row arrives") {
            folderRow(coordinator, named: "Projects/") != nil
        }
        try await settle(coordinator)
        let afterFirstQuery = fileManager.directoryListingCount

        coordinator.prepareForPresentation()
        try await settle(coordinator)

        #expect(fileManager.directoryListingCount == afterFirstQuery)
        #expect(resolver.resolvedQueries == ["Projects/"])
        #expect(folderRow(coordinator, named: "Projects/") != nil)
    }

    @Test func anOrdinarySearchNeverListsADirectory() async throws {
        try tree.makeDirectory("Projects")
        let (coordinator, resolver) = try await makePathCoordinator()

        coordinator.query = "xcode"
        try await waitUntil("the first Source Search snapshot arrives") {
            coordinator.results.contains { $0.id == "application:/Applications/Xcode.app" }
        }
        try await settle(coordinator)

        #expect(fileManager.directoryListingCount == 0)
        #expect(coordinator.results.allSatisfy { $0.kind != .folder })
        // The listing count above would still be zero if the query reached the
        // resolver and the resolver declined it. This is what pins the hop
        // itself: an ordinary query never leaves the main actor for a path
        // lookup that cannot succeed.
        #expect(resolver.resolvedQueries.isEmpty)
    }

    @Test func aCommittedScopeChangeReresolvesTheLiveQuery() async throws {
        let otherTree = try TemporaryTree(label: "CoordinatorPathNavigationScope")
        try otherTree.makeDirectory("Ledger")
        let (coordinator, resolver) = try await makePathCoordinator()

        coordinator.query = "Ledger/"
        try await settle(coordinator)
        #expect(folderRow(coordinator, named: "Ledger/") == nil, "no Ledger under the first scope")

        coordinator.changeRoot(to: otherTree.root)

        try await waitUntil("the folder row follows the committed scope") {
            self.folderRow(coordinator, named: "Ledger/") != nil
        }
        #expect(coordinator.rootURL == otherTree.root.standardizedFileURL)
        #expect(resolver.resolvedQueries == ["Ledger/", "Ledger/"])
    }

    /// Typing another character inside a path query must not blink the folder
    /// row off the top of the list.
    ///
    /// The interim publication is assigned synchronously inside `query.didSet`,
    /// so the state right after the assignment is the frame the user would see
    /// — no waiting, nothing to race. Before the fix, the row was derived from
    /// a `pathResolution` still tagged with the *previous* query, came back
    /// nil, and the Top Hit vanished until the new resolution landed.
    @Test func typingInsideAPathQueryKeepsTheFolderRowOnScreen() async throws {
        try tree.makeDirectory("Projects")
        // A file candidate under the directory so a non-web row exists to
        // absorb the selection — otherwise `reconcile`'s web-search escape
        // hatch fills the gap and hides the drop.
        try tree.makeFile("Projects/notes.md")
        let (coordinator, _) = try await makePathCoordinator()

        coordinator.query = "Projects/"
        try await waitUntil("the folder row resolves") {
            self.folderRow(coordinator, named: "Projects/") != nil
        }
        try await settle(coordinator)

        // The next keystroke. Assert on the publication it produces, not on
        // where things end up once the new resolution lands.
        coordinator.query = "Projects/n"

        #expect(folderRow(coordinator, named: "Projects/") != nil)
    }

    @Test func aCommittedScopeChangeLeavesAnOrdinaryQueryAlone() async throws {
        let otherTree = try TemporaryTree(label: "CoordinatorPathNavigationScope")
        let executions = SearchExecutionCounter()
        let (coordinator, resolver) = try await makePathCoordinator(
            wrapSourceSearch: { executions.counting($0) }
        )

        coordinator.query = "xcode"
        try await settle(coordinator)
        let executionsBefore = executions.count

        coordinator.changeRoot(to: otherTree.root)
        try await waitUntil("the new scope commits") {
            coordinator.rootURL == otherTree.root.standardizedFileURL
        }

        // Re-examining the query on a scope commit must stay a path question.
        // Source Search resumes an active query across a scope change on its
        // own (ADR 0001); the coordinator starting a second Search Execution
        // on top would make a folder swap cost every ordinary query a
        // redundant pass over the catalogs.
        #expect(executions.count == executionsBefore)
        #expect(fileManager.directoryListingCount == 0)
        // Stronger than the listing count, and stronger than what this test
        // used to wait for: "xcode" has no path syntax, so it never reaches
        // the resolver at all — not on the first search, and not on the
        // re-examination a scope commit triggers.
        #expect(resolver.resolvedQueries.isEmpty)
    }
}

/// Counts the Search Executions a coordinator starts, by standing in front of
/// a real `SourceSearchEngine` and forwarding everything.
private final class SearchExecutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var searches = 0

    var count: Int {
        lock.withLock { searches }
    }

    func counting(_ underlying: any SourceSearching) -> any SourceSearching {
        CountedSourceSearch(underlying: underlying) { [self] in
            lock.withLock { searches += 1 }
        }
    }
}

private struct CountedSourceSearch: SourceSearching {
    let underlying: any SourceSearching
    let onSearch: @Sendable () -> Void

    func warmUp() async {
        await underlying.warmUp()
    }

    func search(_ query: String, immediate: Bool) async -> AsyncStream<SearchSnapshot> {
        onSearch()
        return await underlying.search(query, immediate: immediate)
    }

    func cancel() async {
        await underlying.cancel()
    }

    func changeScope(to url: URL) async throws {
        try await underlying.changeScope(to: url)
    }

    func rebuild() async throws {
        try await underlying.rebuild()
    }

    func trackSelection(
        of candidateID: SearchItem.ID,
        selectedURL: URL,
        for query: String
    ) async {
        await underlying.trackSelection(of: candidateID, selectedURL: selectedURL, for: query)
    }
}

/// `FileSystemPathResolver` with a tally of the queries it was asked to
/// resolve. Wrapping the real resolver rather than replacing it keeps the
/// production resolution rules — and the filesystem access they make — in
/// the test, which is the whole point of counting.
private final class CountingPathResolver: PathResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private let underlying: FileSystemPathResolver

    init(fileManager: CountingFileManager, homeURL: URL) {
        underlying = FileSystemPathResolver(fileManager: { fileManager }, homeURL: homeURL)
    }

    var resolvedQueries: [String] {
        lock.withLock { queries }
    }

    func resolve(query: String, rootURL: URL?) async -> ResolvedPath? {
        lock.withLock { queries.append(query) }
        return await underlying.resolve(query: query, rootURL: rootURL)
    }
}
