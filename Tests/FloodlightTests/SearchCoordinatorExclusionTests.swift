import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Excluding a row from search: the rule is written, and the row leaves and
/// stays gone — including when a pass that started before the rule existed
/// lands afterwards.
@MainActor
final class SearchCoordinatorExclusionTests: SearchCoordinatorIntegrationTestCase {
    @Test func excludingAnItemRemovesItFromResultsAndPersistsToBlocklist() async throws {
        let clash = SearchFixtures.application(id: "app:clash", name: "Clash", score: 120_000)
        let claude = SearchFixtures.application(id: "app:claude", name: "Claude", score: 110_000)
        let applications = ScriptedCatalog(immediate: [clash, claude])

        let isolated = try IsolatedDefaults()
        let blocklist = BlocklistStore(defaults: isolated.defaults)

        let coordinator = try await makeCoordinator(
            applications: applications,
            blocklist: blocklist
        )

        coordinator.query = "cl"
        try await waitUntil("both candidates appear") {
            coordinator.results.contains { $0.id == clash.id }
                && coordinator.results.contains { $0.id == claude.id }
        }

        coordinator.excludeFromSearch(clash)

        try await waitUntil("clash is excluded from results") {
            !coordinator.results.contains { $0.id == clash.id }
                && coordinator.results.contains { $0.id == claude.id }
        }

        #expect(blocklist.isBlocked(name: clash.title, id: clash.id))
        #expect(coordinator.results.first?.id == claude.id)
    }

    /// A pass in flight when the rule is written was computed without it, and
    /// a source that never consults the blocklist recalls the row every time.
    /// Either way the excluded row must not come back when that pass lands.
    @Test func anExclusionSurvivesAnIndexedPassThatLandsAfterIt() async throws {
        let clash = SearchFixtures.application(id: "app:clash", name: "Clash", score: 120_000)
        let claude = SearchFixtures.application(id: "app:claude", name: "Claude", score: 110_000)
        let applications = ScriptedCatalog()
        applications.setBehavior(
            .init(
                immediate: [clash, claude],
                indexed: [clash, claude],
                indexedDelay: TestBudget.duration(.milliseconds(300))
            ),
            forQuery: "cl"
        )

        let isolated = try IsolatedDefaults()
        let blocklist = BlocklistStore(defaults: isolated.defaults)
        let coordinator = try await makeCoordinator(
            applications: applications,
            blocklist: blocklist
        )

        coordinator.query = "cl"
        try await waitUntil("both candidates appear") {
            coordinator.results.contains { $0.id == clash.id }
                && coordinator.results.contains { $0.id == claude.id }
        }

        coordinator.excludeFromSearch(clash)
        // Let the delayed indexed pass land on top of the exclusion.
        //
        // This waits on the clock rather than on the coordinator because the
        // claim is that a row *stays* absent: before and after the late pass
        // lands the results read identically, so there is no state change to
        // poll for. What matters is only that the wait outlasts the scripted
        // delay — so it scales with it. Scaling one and not the other is what
        // made this assert before the pass had landed, passing without having
        // observed the thing it exists to observe.
        try await Task.sleep(for: TestBudget.duration(.milliseconds(500)))

        #expect(!coordinator.results.contains { $0.id == clash.id })
        #expect(coordinator.results.contains { $0.id == claude.id })
    }
}
