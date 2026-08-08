import FloodlightEngine
import FloodlightTestSupport
import XCTest

final class SourceSearchEngineTests: XCTestCase {
    private enum Failure: Error { case expected }

    func testImmediateThenSettledSnapshotsAreComplete() async throws {
        let app = SearchFixtures.application(name: "Notes")
        let file = SearchFixtures.file(name: "notes.txt")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(indexed: [file]),
            applications: ScriptedCatalog(immediate: [app]),
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("notes", immediate: true).makeAsyncIterator()
        let first = await iterator.next()
        let immediate = try XCTUnwrap(first)
        XCTAssertEqual(immediate.candidates, [app])
        XCTAssertFalse(immediate.isSettled)
        var nextSnapshot = await awaitNext(&iterator)
        var settled = try XCTUnwrap(nextSnapshot)
        while !settled.isSettled {
            nextSnapshot = await awaitNext(&iterator)
            settled = try XCTUnwrap(nextSnapshot)
        }
        XCTAssertTrue(settled.isSettled)
        XCTAssertEqual(Set(settled.candidates), Set([app, file]))
        XCTAssertEqual(settled.totalMatches[.application], 1)
        XCTAssertEqual(settled.totalMatches[.file], 1)
    }

    func testNewerQueryFinishesAndSuppressesOlderExecution() async {
        let files = ScriptedFileSource(
            indexed: [SearchFixtures.file(name: "old")],
            indexedDelay: .seconds(1)
        )
        let engine = SourceSearchEngine(
            files: files,
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
        var old = await engine.search("old", immediate: true).makeAsyncIterator()
        _ = await old.next()
        _ = await engine.search("new", immediate: true)
        let oldEnd = await old.next()
        XCTAssertNil(oldEnd)
    }

    func testCancelledCallerCannotSupersedeCurrentExecution() async throws {
        let file = SearchFixtures.file(name: "current.txt")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(indexed: [file], indexedDelay: .milliseconds(50)),
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
        var current = await engine.search("current", immediate: true).makeAsyncIterator()
        _ = await current.next()
        let stale = Task {
            try? await Task.sleep(for: .seconds(1))
            return await engine.search("stale", immediate: true)
        }
        stale.cancel()
        _ = await stale.value

        let settled = try await nextSettled(&current)

        XCTAssertEqual(settled.candidates, [file])
    }

    func testIndexedFailureKeepsHealthyCandidatesAndMarksDegraded() async throws {
        let app = SearchFixtures.application(name: "Finder")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(indexedError: Failure.expected),
            applications: ScriptedCatalog(.init(indexed: [app])),
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("fi", immediate: true).makeAsyncIterator()
        _ = await iterator.next()
        let next = await iterator.next()
        let settled = try XCTUnwrap(next)
        XCTAssertEqual(settled.candidates, [app])
        XCTAssertTrue(settled.isDegraded)
        XCTAssertTrue(settled.isSettled)
    }

    func testCancelFinishesStream() async {
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("query", immediate: true).makeAsyncIterator()
        _ = await iterator.next()
        await engine.cancel()
        var end = await iterator.next()
        while end != nil {
            end = await iterator.next()
        }
        XCTAssertNil(end)
    }

    func testSelectionLearningUsesRetainedProvenance() async throws {
        let file = SearchFixtures.file(name: "report.txt")
        let app = SearchFixtures.application(name: "Preview")
        let files = ScriptedFileSource(indexed: [file])
        let applications = ScriptedCatalog(.init(indexed: [app]))
        let engine = SourceSearchEngine(
            files: files,
            applications: applications,
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("rep", immediate: true).makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await engine.search("different query", immediate: true)
        try await engine.trackSelection(
            of: file.id,
            selectedURL: XCTUnwrap(file.fileURL),
            for: "rep"
        )
        try await engine.trackSelection(of: app.id, selectedURL: XCTUnwrap(app.fileURL), for: "rep")
        XCTAssertEqual(files.tracked.map(\.query), ["rep"])
        XCTAssertEqual(applications.tracked.map(\.query), ["rep"])
    }

    func testSelectionLearningUsesProvenanceFromSelectedQuery() async throws {
        let application = SearchFixtures.application(name: "Shared")
        let fileURL = URL(fileURLWithPath: "/tmp/shared")
        let file = SearchItem(
            id: application.id,
            title: "Shared",
            subtitle: fileURL.path,
            kind: .file,
            action: .open(fileURL),
            score: 1,
            fileURL: fileURL
        )
        let files = ScriptedFileSource(indexed: [file])
        let applications = ScriptedCatalog(immediate: [application])
        applications.setBehavior(.init(), forQuery: "new")
        let engine = SourceSearchEngine(
            files: files,
            applications: applications,
            settings: ScriptedCatalog()
        )
        _ = try await settledSnapshot(from: engine, query: "old")
        _ = try await settledSnapshot(from: engine, query: "new")

        try await engine.trackSelection(
            of: application.id,
            selectedURL: XCTUnwrap(application.fileURL),
            for: "old"
        )

        XCTAssertEqual(applications.tracked.map(\.query), ["old"])
        XCTAssertTrue(files.tracked.isEmpty)
    }

    func testSettledSnapshotIncludesCatalogResultsLoadedByStart() async throws {
        let app = SearchFixtures.application(name: "Calendar")
        let setting = SearchFixtures.setting(title: "Calendar Settings")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: ScriptedCatalog(.init(immediateAfterStart: [app])),
            settings: ScriptedCatalog(.init(immediateAfterStart: [setting]))
        )

        let settled = try await settledSnapshot(from: engine, query: "cal")

        XCTAssertEqual(Set(settled.candidates), Set([app, setting]))
        XCTAssertFalse(settled.pendingKinds.contains(.systemSetting))
    }

    func testRefreshChangeAppearsInCurrentSnapshot() async throws {
        let app = SearchFixtures.application(name: "Fresh App")
        let applications = ScriptedCatalog(.init(
            refreshReportsChange: true,
            immediateAfterRefresh: [app]
        ))
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )

        let settled = try await settledSnapshot(from: engine, query: "fresh")

        XCTAssertEqual(settled.candidates, [app])
        XCTAssertEqual(applications.refreshes, 1)
    }

    func testWarmUpRefreshUpdatesSettledLiveStream() async throws {
        let original = SearchFixtures.application(name: "Original")
        let refreshed = SearchFixtures.application(name: "Refreshed")
        let applications = ScriptedCatalog(immediate: [original])
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("app", immediate: true).makeAsyncIterator()
        _ = try await nextSettled(&iterator)
        applications.setBehavior(.init(
            immediate: [original],
            refreshReportsChange: true,
            immediateAfterRefresh: [refreshed]
        ))

        await engine.warmUp()
        let updated = try await nextSettled(&iterator)

        XCTAssertEqual(updated.candidates, [refreshed])
    }

    func testWarmUpRefreshFailureUpdatesLiveStreamDegradation() async throws {
        let app = SearchFixtures.application(name: "Healthy")
        let applications = ScriptedCatalog(immediate: [app])
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("healthy", immediate: true).makeAsyncIterator()
        _ = try await nextSettled(&iterator)
        applications.setBehavior(.init(
            immediate: [app],
            refreshError: Failure.expected
        ))

        await engine.warmUp()
        let updated = try await nextSettled(&iterator)

        XCTAssertEqual(updated.candidates, [app])
        XCTAssertTrue(updated.isDegraded)
    }

    func testWarmUpStartupRecoveryUpdatesSettledLiveStream() async throws {
        let app = SearchFixtures.application(name: "Recovered")
        let applications = ScriptedCatalog(.init(
            startError: Failure.expected,
            immediateAfterStart: [app],
            startFailures: 1
        ))
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("recovered", immediate: true).makeAsyncIterator()
        let degraded = try await nextSettled(&iterator)
        XCTAssertTrue(degraded.isDegraded)

        await engine.warmUp()
        let recovered = try await nextSettled(&iterator)

        XCTAssertEqual(recovered.candidates, [app])
        XCTAssertFalse(recovered.isDegraded)
    }

    func testFailedScopeChangeResumesActiveQueryOnSameStream() async throws {
        let file = SearchFixtures.file(name: "report.txt")
        let files = ScriptedFileSource(indexed: [file], changeScopeError: Failure.expected)
        let engine = SourceSearchEngine(
            files: files,
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
        var iterator = await engine.search("report", immediate: true).makeAsyncIterator()
        _ = await iterator.next()

        do {
            try await engine.changeScope(to: URL(fileURLWithPath: "/unavailable"))
            XCTFail("Expected scope change to fail")
        } catch Failure.expected {}

        let next = await iterator.next()
        let invalidated = try XCTUnwrap(next)
        XCTAssertTrue(invalidated.candidates.isEmpty)
        let resumed = try await nextSettled(&iterator)
        XCTAssertEqual(resumed.candidates, [file])
    }

    func testNewQueryDuringScopeChangeRemainsCurrent() async throws {
        let file = SearchFixtures.file(name: "result.txt")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(
                indexed: [file],
                changeScopeDelay: .milliseconds(50)
            ),
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
        var old = await engine.search("old", immediate: true).makeAsyncIterator()
        _ = await old.next()
        let scopeChange = Task {
            try await engine.changeScope(to: URL(fileURLWithPath: "/new-scope"))
        }
        try await Task.sleep(for: .milliseconds(10))
        let newStream = Task { await engine.search("new", immediate: true) }

        try await scopeChange.value
        var current = await newStream.value.makeAsyncIterator()
        let settled = try await nextSettled(&current)

        XCTAssertEqual(settled.candidates, [file])
        var oldEnd = await old.next()
        while oldEnd != nil {
            oldEnd = await old.next()
        }
        XCTAssertNil(oldEnd)
    }

    func testLatestOfTwoQueriesWaitingOnScopeChangeWins() async throws {
        let first = SearchFixtures.application(name: "First")
        let second = SearchFixtures.application(name: "Second")
        let applications = ScriptedCatalog()
        applications.setBehavior(.init(immediate: [first]), forQuery: "first")
        applications.setBehavior(.init(immediate: [second]), forQuery: "second")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(changeScopeDelay: .milliseconds(100)),
            applications: applications,
            settings: ScriptedCatalog()
        )
        let scopeChange = Task {
            try await engine.changeScope(to: URL(fileURLWithPath: "/new-scope"))
        }
        try await Task.sleep(for: .milliseconds(10))
        let firstQuery = Task { await engine.search("first", immediate: true) }
        try await Task.sleep(for: .milliseconds(10))
        let secondQuery = Task { await engine.search("second", immediate: true) }

        try await scopeChange.value
        var firstIterator = await firstQuery.value.makeAsyncIterator()
        var secondIterator = await secondQuery.value.makeAsyncIterator()
        let firstEnd = await firstIterator.next()
        let settled = try await nextSettled(&secondIterator)

        XCTAssertNil(firstEnd)
        XCTAssertEqual(settled.candidates, [second])
    }

    func testCancelledQueryWaitingOnScopeChangeDoesNotSuppressActiveQuery() async throws {
        let original = SearchFixtures.application(name: "Original")
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(changeScopeDelay: .milliseconds(100)),
            applications: ScriptedCatalog(immediate: [original]),
            settings: ScriptedCatalog()
        )
        var active = await engine.search("original", immediate: true).makeAsyncIterator()
        _ = try await nextSettled(&active)
        let scopeChange = Task {
            try await engine.changeScope(to: URL(fileURLWithPath: "/new-scope"))
        }
        try await Task.sleep(for: .milliseconds(10))
        let cancelled = Task { await engine.search("cancelled", immediate: true) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()

        try await scopeChange.value
        _ = await cancelled.value
        let resumed = try await nextSettled(&active)

        XCTAssertEqual(resumed.candidates, [original])
    }

    func testFailedStartupIsRetriedByLaterSearch() async throws {
        let app = SearchFixtures.application(name: "Retry App")
        let applications = ScriptedCatalog(.init(
            startError: Failure.expected,
            immediateAfterStart: [app],
            startFailures: 1
        ))
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )

        let first = try await settledSnapshot(from: engine, query: "retry")
        XCTAssertTrue(first.isDegraded)
        let second = try await settledSnapshot(from: engine, query: "retry")

        XCTAssertFalse(second.isDegraded)
        XCTAssertEqual(second.candidates, [app])
        XCTAssertEqual(applications.starts, 2)
    }

    func testRebuildBeforeWarmUpStartsFilesFirst() async throws {
        let files = ScriptedFileSource()
        let engine = SourceSearchEngine(
            files: files,
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )

        try await engine.rebuild()

        XCTAssertEqual(files.lifecycle, ["start", "rebuild"])
    }

    func testConcurrentStartupFailureAndRetryRemainSingleFlight() async {
        let applications = ScriptedCatalog(.init(
            startDelay: .milliseconds(30),
            startError: Failure.expected,
            startFailures: 1
        ))
        let engine = SourceSearchEngine(
            files: ScriptedFileSource(),
            applications: applications,
            settings: ScriptedCatalog()
        )
        var callers: [Task<Void, Never>] = []
        for _ in 0..<60 {
            callers.append(Task { await engine.warmUp() })
            try? await Task.sleep(for: .milliseconds(1))
        }

        for caller in callers {
            await caller.value
        }

        XCTAssertEqual(applications.starts, 2)
        XCTAssertEqual(applications.maximumConcurrentStarts, 1)
    }

    private func settledSnapshot(
        from engine: SourceSearchEngine,
        query: String
    ) async throws -> SearchSnapshot {
        var iterator = await engine.search(query, immediate: true).makeAsyncIterator()
        return try await nextSettled(&iterator)
    }

    private func nextSettled(
        _ iterator: inout AsyncStream<SearchSnapshot>.AsyncIterator
    ) async throws -> SearchSnapshot {
        while let snapshot = await iterator.next() {
            if snapshot.isSettled { return snapshot }
        }
        throw Failure.expected
    }

    private func awaitNext(
        _ iterator: inout AsyncStream<SearchSnapshot>.AsyncIterator
    ) async -> SearchSnapshot? {
        await iterator.next()
    }
}
