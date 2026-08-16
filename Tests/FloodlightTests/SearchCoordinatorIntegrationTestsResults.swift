import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
final class SearchCoordinatorIntegrationTestsResults: SearchCoordinatorIntegrationTestCase {
    // MARK: - Preview results

    @Test func onlyAPreviewableFileSelectionExposesAURL() async throws {
        let file = SearchFixtures.file(name: "notes.txt", score: 5_000)
        let folder = SearchFixtures.folder(name: "code", score: 6_000)
        let applications = ScriptedCatalog(immediate: [folder, file])
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "code"
        try await waitUntil("preview candidates arrive") {
            coordinator.results.contains { $0.id == file.id }
        }

        coordinator.select(folder)
        #expect(coordinator.previewableSelectionURL == nil, "a folder is not previewable")

        coordinator.select(file)
        #expect(coordinator.previewableSelectionURL == file.fileURL)
    }

    @Test func projectionSelectsTheFirstRowWhenThereIsNoSelectionAnchor() {
        let file = SearchFixtures.file(name: "notes.txt", score: 5_000)
        let publication = SearchResultProjection.project(
            .local(.init(
                query: "notes",
                candidates: [file],
                keywordRegistry: KeywordEngineCatalog.initialRegistry,
                selectedFilter: .all,
                selection: nil,
                progress: .settled
            ))
        )

        #expect(publication.selection?.id == file.id)
        #expect(publication.selection?.origin == .automatic)
    }

    // MARK: - Publication transitions

    @Test func filterInducedWebSelectionStillYieldsToARealResult() async throws {
        let applications = ScriptedCatalog(.init(
            immediate: [],
            indexed: [SearchFixtures.application(id: "app:late", name: "Late", score: 120_000)],
            indexedDelay: .milliseconds(80)
        ))
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "late"
        try await waitUntil("the web fallback arrives") {
            coordinator.selectedID == "web-search"
        }

        coordinator.selectFilter(.files)
        coordinator.selectFilter(.all)
        #expect(coordinator.selectedID == "web-search")

        try await settle(coordinator)

        #expect(coordinator.selectedID == "app:late")
    }

    @Test func anEmptiedDynamicFilterFallsBackToAllOnceLoadingFinishes() async throws {
        // Standing on "PDFs" while the results change out from under you
        // must not strand the panel on an empty chip.
        let applications = ScriptedCatalog(.init(
            immediate: [SearchFixtures.application(name: "Xcode")],
            indexed: [SearchFixtures.application(name: "Xcode")],
            indexedDelay: .milliseconds(120)
        ))
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.start()
        try await waitUntil("startup completes") {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }

        coordinator.query = "xcode"
        try await waitUntil("a non-settled snapshot arrives") {
            coordinator.isSearching
                && coordinator.results.contains { $0.kind == .application }
        }
        coordinator.selectFilter(.pdfs)
        #expect(coordinator.selectedFilter == .pdfs)
        #expect(coordinator.filterOptions.contains { $0.filter == .pdfs })

        try await settle(coordinator)

        #expect(
            coordinator.selectedFilter == .all,
            "an empty dynamic filter should hand back to All once the search settles"
        )
    }

    @Test func warmUpCompletingDuringAnActiveQueryPublishesOneCoherentResult() async throws {
        let application = SearchFixtures.application(name: "Xcode", score: 120_000)
        let applications = ScriptedCatalog(.init(
            immediate: [],
            totalMatched: 37,
            indexedDelay: .milliseconds(150),
            startDelay: .milliseconds(100),
            immediateAfterStart: [application]
        ))
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.start()
        coordinator.query = "xcode"
        try await waitUntil("warm-up completes while source work remains pending") {
            coordinator.isSearching
                && coordinator.results.contains { $0.id == application.id }
        }
        #expect(coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == true)

        try await waitUntil("warm-up and the active query settle") {
            !coordinator.isSearching
                && coordinator.results.contains { $0.id == application.id }
                && coordinator.filterOptions.first { $0.filter == .applications }?.count == 37
        }

        #expect(coordinator.selectedFilter == .all)
        #expect(coordinator.selectedID == coordinator.results.first?.id)
        #expect(coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false)
    }

    // MARK: - Result building

    @Test func mergedResultsAreAlwaysDeduplicatedRankedAndCapped() throws {
        try checkProperty(
            "Result Projection de-duplicates, ranks, and caps at 80",
            SearchGenerators.items(count: 0...40),
            SearchGenerators.items(count: 0...40),
            SearchGenerators.items(count: 0...40),
            runs: 300
        ) { indexed, apps, system in
            let results = projectResults(
                query: "zzzzz",
                indexed: indexed,
                apps: apps,
                system: system
            )
            let ids = results.map(\.id)
            let localResults = results.filter { $0.kind != .web }
            return ids.count == Set(ids).count
                && results.count <= 80
                && (results.last?.kind == .web || results.isEmpty)
                && zip(localResults, localResults.dropFirst()).allSatisfy { $0.score >= $1.score }
        }
    }

    @Test func mergedResultsAreDeterministic() throws {
        try checkProperty(
            "the same inputs always produce the same merged list",
            SearchGenerators.items(count: 0...30),
            Gen<String>.element(of: AdversarialCorpus.searchQueries),
            runs: 300
        ) { items, query in
            let first = projectResults(
                query: query, indexed: items, apps: [], system: []
            )
            let second = projectResults(
                query: query, indexed: items, apps: [], system: []
            )
            return first.map(\.id) == second.map(\.id)
        }
    }

    @Test func AWebRowExistsForEveryNonEmptyQueryAndNeverForAnEmptyOne() throws {
        try checkProperty(
            "the web fallback tracks query emptiness",
            Gen<String>.hostile,
            runs: 600
        ) { query in
            let results = projectResults(
                query: query, indexed: [], apps: [], system: []
            )
            let hasWebRow = results.contains { $0.id == "web-search" }
            guard !query.isEmpty else { return !hasWebRow }
            // A query that cannot be percent-encoded produces no row; every
            // other non-empty query must.
            let encodable = query
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) != nil
            return hasWebRow == encodable
        }
    }

    @Test func buildingResultsNeverTrapsOnHostileQueries() {
        for query in AdversarialCorpus.strings + AdversarialCorpus.searchQueries {
            let results = projectResults(
                query: query,
                indexed: [SearchFixtures.file(name: "notes.txt")],
                apps: [SearchFixtures.application(name: "Xcode")],
                system: [SearchFixtures.setting(title: "Keyboard")]
            )
            #expect(results.count <= 80, "\(String(reflecting: query))")
            #expect(results.count == Set(results.map(\.id)).count, "\(String(reflecting: query))")
        }
    }

    @Test func theCoordinatorSurvivesAFloodOfQueriesWithoutLosingCoherence() async throws {
        // A stress pass over the whole observer → search → publish loop:
        // hundreds of query mutations back to back, then a check that the
        // final state matches the final query and nothing was left behind.
        let applications = ScriptedCatalog()
        for index in 0..<200 {
            applications.setBehavior(
                .init(
                    immediate: [
                        SearchFixtures.application(
                            id: "app:\(index)",
                            name: "App \(index)"
                        ),
                    ],
                    indexed: [
                        SearchFixtures.application(
                            id: "idx:\(index)",
                            name: "Indexed \(index)"
                        ),
                    ],
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

        #expect(coordinator.results.contains { $0.id == "app:199" })
        #expect(coordinator.results.allSatisfy { item in
            !item.id.hasPrefix("app:") || item.id == "app:199"
        }, "results from abandoned queries survived the flood")
        let ids = coordinator.results.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func ANewKeystrokeKeepsTheSettledRowsUntilTheNextSnapshotLands() async throws {
        // Stale-while-revalidate: while the new Search Execution runs, the
        // rows already on screen stay exactly as they are. Clearing them
        // collapsed the list to the synthetic rows for a frame or two per
        // keystroke — the visible jump this guards against.
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)],
                indexedDelay: .milliseconds(200)
            )
        )
        let coordinator = try await makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await settle(coordinator)
        let settledIDs = coordinator.results.map(\.id)
        let settledSelection = coordinator.selectedID
        #expect(!settledIDs.isEmpty)

        coordinator.query = "xcode c"

        // Synchronous — no snapshot for the new query can have landed yet.
        #expect(
            coordinator.results.map(\.id) == settledIDs,
            "a keystroke must not reshuffle or collapse the visible rows"
        )
        #expect(coordinator.selectedID == settledSelection)
        #expect(coordinator.isSearching)

        try await settle(coordinator)
    }
}
