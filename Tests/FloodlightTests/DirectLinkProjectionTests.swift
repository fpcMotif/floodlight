import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Where the Direct Link row lands among the rows Result Projection already
/// composes — and, as much, what it leaves alone. The recognizer's own
/// accept/reject rules are `DirectLinkTests`'.
@MainActor
struct DirectLinkProjectionTests {
    @Test func anAddressRanksAboveEveryOtherLocalRow() {
        let rows = projectResults(
            query: "x.com/fddddfdf",
            indexed: [SearchFixtures.file(name: "x.com-notes.txt")],
            apps: [
                SearchFixtures.application(name: "Xcode", score: 120_000),
                SearchFixtures.application(
                    id: "keyword-shaped",
                    name: "X",
                    score: SearchItemRanking.keywordEngine
                ),
            ],
            system: []
        )

        #expect(rows.first?.id == "direct-link")
    }

    @Test func theGoogleRowIsStillOfferedBelowTheAddress() {
        let rows = projectResults(query: "abd.com", indexed: [], apps: [], system: [])

        #expect(rows.map(\.id) == ["direct-link", "web-search"])
    }

    @Test func theAddressRowIsCountedUnderNoFilterChip() {
        let publication = SearchResultProjection.project(.local(.init(
            query: "abd.com",
            candidates: [],
            keywordRegistry: catalogRegistry,
            selectedFilter: .all,
            selection: nil,
            progress: .settled
        )))

        #expect(publication.visibleRows.contains { $0.id == "direct-link" })
        for option in publication.filterOptions where option.filter != .all {
            #expect(option.isEmpty)
        }
    }

    @Test func aMultiWordQueryProducesTheSameRowsAsBefore() {
        let apps = [SearchFixtures.application(name: "Safari")]
        let rows = projectResults(query: "safari window", indexed: [], apps: apps, system: [])

        #expect(!rows.contains { $0.id == "direct-link" })
        #expect(rows.map(\.id) == ["application:/Applications/Safari.app", "web-search"])
    }

    @Test func aKeywordAddressedQueryKeepsItsKeywordRowAndGainsNoAddressRow() {
        let rows = projectResults(query: "yt lofi hip hop", indexed: [], apps: [], system: [])

        #expect(rows.first?.id == "keyword-engine:youtube")
        #expect(!rows.contains { $0.id == "direct-link" })
    }

    @Test func arithmeticWithDotsInItIsStillASum() {
        let rows = projectResults(query: "1.5*2", indexed: [], apps: [], system: [])

        #expect(rows.first?.id == "calculator")
        #expect(!rows.contains { $0.id == "direct-link" })
    }

    @Test func anEmptyQueryProducesNoAddressRow() {
        let rows = projectResults(query: "", indexed: [], apps: [], system: [])

        #expect(rows.isEmpty)
    }

    private var catalogRegistry: KeywordEngineRegistry {
        KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
    }
}
