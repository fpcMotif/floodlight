import Foundation
import XCTest
@testable import FloodlightEngine

/// `SearchItemRanking.topRanked(_:limit:)` is the one selection primitive the
/// engine's search path is allowed to use — the ast-grep rule
/// `search-path-no-full-sort` bans `.sorted()` everywhere else under
/// `Sources/FloodlightEngine/Search`. That only holds if bounded selection is
/// observably identical to the full sort it replaces, so these tests compare
/// it against `sorted(by:).prefix(limit)` rather than against a hand-written
/// expectation.
final class SearchItemRankingTests: XCTestCase {
    func testTopRankedMatchesFullSortThenPrefix() {
        for candidateCount in [0, 1, 2, 7, 12, 13, 64, 257] {
            let items = makeItems(count: candidateCount)
            let expected = items.sorted(by: SearchItemRanking.ranksBefore)

            for limit in [1, 2, 12, 24, candidateCount, candidateCount + 5] where limit > 0 {
                XCTAssertEqual(
                    SearchItemRanking.topRanked(items, limit: limit).map(\.id),
                    expected.prefix(limit).map(\.id),
                    "candidates=\(candidateCount) limit=\(limit)"
                )
            }
        }
    }

    func testTopRankedBreaksScoreTiesOnTitleLikeTheFullSort() {
        // Every item scores the same, so the title tiebreak in `ranksBefore` is
        // the only thing ordering them. A selection that ignored the tiebreak
        // would still return "the top 3" — just not the same three.
        let items = ["delta", "alpha", "charlie", "bravo", "echo"].enumerated()
            .map { index, title in
                makeItem(id: "tie:\(index)", title: title, score: 500)
            }

        XCTAssertEqual(
            SearchItemRanking.topRanked(items, limit: 3).map(\.title),
            ["alpha", "bravo", "charlie"]
        )
    }

    func testTopRankedReturnsNothingForNonPositiveLimit() {
        let items = makeItems(count: 10)

        XCTAssertTrue(SearchItemRanking.topRanked(items, limit: 0).isEmpty)
        XCTAssertTrue(SearchItemRanking.topRanked(items, limit: -1).isEmpty)
    }

    func testTopRankedKeepsTheBestWhenCandidatesArriveWorstFirst() {
        // Ascending input is the adversarial case for a bounded heap: every
        // candidate displaces the current worst, so the sift path runs on every
        // element.
        let ascending = (0..<200).map { makeItem(id: "asc:\($0)", title: "Item", score: $0) }

        XCTAssertEqual(
            SearchItemRanking.topRanked(ascending, limit: 3).map(\.score),
            [199, 198, 197]
        )
        XCTAssertEqual(
            SearchItemRanking.topRanked(ascending.reversed(), limit: 3).map(\.score),
            [199, 198, 197]
        )
    }

    func testPageRanksAndReportsTheTotalRatherThanThePageSize() {
        let items = makeItems(count: 40)

        let page = SearchItemRanking.page(items, limit: 5)

        XCTAssertEqual(page.items.count, 5)
        XCTAssertEqual(page.totalMatched, 40)
        XCTAssertEqual(
            page.items.map(\.id),
            items.sorted(by: SearchItemRanking.ranksBefore).prefix(5).map(\.id)
        )
    }

    private func makeItems(count: Int) -> [SearchItem] {
        // A deterministic but deliberately unsorted spread. Scores repeat so the
        // title tiebreak is exercised at every size; titles are unique so
        // `ranksBefore` is a strict total order over the fixture. Items equal on
        // *both* keys are interchangeable under any correct selection, so a
        // fixture containing them could not tell a bug from a permutation.
        (0..<count).map { index in
            makeItem(
                id: "item:\(index)",
                title: "Item \(String(format: "%04d", (index * 37) % 1_009))",
                score: (index * 17) % 25
            )
        }
    }

    private func makeItem(id: String, title: String, score: Int) -> SearchItem {
        let url = URL(fileURLWithPath: "/tmp/\(id)")
        return SearchItem(
            id: id,
            title: title,
            subtitle: url.path,
            kind: .file,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }
}
