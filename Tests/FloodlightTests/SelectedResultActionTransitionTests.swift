import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
extension SelectedResultActionPerformerTests {
    @Test("L03: independent opens retain identity when completions reverse")
    func independentOpensRetainIdentityAcrossReverseCompletion() async throws {
        let first = SearchFixtures.file(name: "first.txt")
        let second = SearchFixtures.file(name: "second.txt")
        let firstURL = try #require(first.fileURL)
        let secondURL = try #require(second.fileURL)
        let firstGate = AsyncTestGate()
        let secondGate = AsyncTestGate()
        let harness = makeHarness(openGates: [firstURL: firstGate, secondURL: secondGate])

        harness.performer.activate(first, query: "first query")
        harness.performer.activate(second, query: "second query")
        try await waitUntil {
            let firstWaiting = await firstGate.waitingCount
            let secondWaiting = await secondGate.waitingCount
            return firstWaiting == 1 && secondWaiting == 1
        }

        await secondGate.open()
        try await waitUntil { await harness.learning.count == 1 }
        #expect(await harness.learning.snapshot() == [
            .init(itemID: second.id, url: secondURL, query: "second query"),
        ])

        await firstGate.open()
        try await waitUntil { await harness.learning.count == 2 }
        #expect(await Set(harness.learning.snapshot()) == Set([
            .init(itemID: first.id, url: firstURL, query: "first query"),
            .init(itemID: second.id, url: secondURL, query: "second query"),
        ]))
    }
}
