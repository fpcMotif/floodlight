import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing

struct SearchTransitionContractTests {
    @Test("S01: superseded work cannot publish over the current query")
    func supersededCompletionCannotPublish() async throws {
        let old = SearchFixtures.file(name: "old.txt")
        let current = SearchFixtures.file(name: "current.txt")
        let gate = AsyncTestGate()
        let files = ScriptedFileSource()
        files.setIndexed([old], forQuery: "old", gatedBy: gate)
        files.setIndexed([current], forQuery: "current")
        let engine = makeEngine(files: files)
        var oldStream = await engine.search("old", immediate: true).makeAsyncIterator()
        _ = await oldStream.next()
        try await waitUntilBlocked(gate)

        var currentStream = await engine.search("current", immediate: true).makeAsyncIterator()
        let settled = try await nextSettled(&currentStream)
        await gate.open()

        #expect(settled.candidates == [current])
        #expect(await oldStream.next() == nil)
    }

    @Test("S02: cancelled work cannot publish after its source completes")
    func cancelledCompletionCannotPublish() async throws {
        let gate = AsyncTestGate()
        let files = ScriptedFileSource()
        files.setIndexed(
            [SearchFixtures.file(name: "cancelled.txt")],
            forQuery: "cancelled",
            gatedBy: gate
        )
        let engine = makeEngine(files: files)
        var stream = await engine.search("cancelled", immediate: true).makeAsyncIterator()
        _ = await stream.next()
        try await waitUntilBlocked(gate)

        await engine.cancel()
        await gate.open()

        #expect(await stream.next() == nil)
    }

    private func makeEngine(files: ScriptedFileSource) -> SourceSearchEngine {
        SourceSearchEngine(
            files: files,
            applications: ScriptedCatalog(),
            settings: ScriptedCatalog()
        )
    }

    @concurrent
    private func nextSettled(
        _ iterator: inout AsyncStream<SearchSnapshot>.AsyncIterator
    ) async throws -> SearchSnapshot {
        while let snapshot = await iterator.next() {
            if snapshot.isSettled { return snapshot }
        }
        throw TestError.scripted("stream ended before a settled snapshot")
    }

    private func waitUntilBlocked(_ gate: AsyncTestGate) async throws {
        let deadline = ContinuousClock.now + TestBudget.duration(.seconds(5))
        while await gate.waitingCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw TestError.scripted("source did not reach its completion barrier")
            }
            await Task.yield()
        }
    }
}
