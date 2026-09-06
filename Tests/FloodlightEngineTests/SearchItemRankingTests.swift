import Foundation
import Testing
@testable import FloodlightEngine

/// `SearchItemRanking.topRanked(_:limit:)` is the one selection primitive the
/// engine's search path is allowed to use — the ast-grep rule
/// `search-path-no-full-sort` bans `.sorted()` everywhere else under
/// `Sources/FloodlightEngine/Search`. That only holds if bounded selection is
/// observably identical to the full sort it replaces, so these tests compare
/// it against `sorted(by:).prefix(limit)` rather than against a hand-written
/// expectation.
///
/// Selection publishes whatever order the scores describe, so the last test
/// here guards the scores themselves: the spacing between match shapes has to
/// stay wider than anything Source Selection Learning adds on top of them.
struct SearchItemRankingTests {
    @Test func topRankedMatchesFullSortThenPrefix() {
        for candidateCount in [0, 1, 2, 7, 12, 13, 64, 257] {
            let items = makeItems(count: candidateCount)
            let expected = items.sorted(by: SearchItemRanking.ranksBefore)

            for limit in [1, 2, 12, 24, candidateCount, candidateCount + 5] where limit > 0 {
                #expect(
                    SearchItemRanking.topRanked(items, limit: limit).map(\.id) == expected
                        .prefix(limit).map(\.id),
                    "candidates=\(candidateCount) limit=\(limit)"
                )
            }
        }
    }

    @Test func topRankedBreaksScoreTiesOnTitleLikeTheFullSort() {
        // Every item scores the same, so the title tiebreak in `ranksBefore` is
        // the only thing ordering them. A selection that ignored the tiebreak
        // would still return "the top 3" — just not the same three.
        let items = ["delta", "alpha", "charlie", "bravo", "echo"].enumerated()
            .map { index, title in
                makeItem(id: "tie:\(index)", title: title, score: 500)
            }

        #expect(SearchItemRanking.topRanked(items, limit: 3).map(\.title) == [
            "alpha",
            "bravo",
            "charlie",
        ])
    }

    @Test func topRankedReturnsNothingForNonPositiveLimit() {
        let items = makeItems(count: 10)

        #expect(SearchItemRanking.topRanked(items, limit: 0).isEmpty)
        #expect(SearchItemRanking.topRanked(items, limit: -1).isEmpty)
    }

    @Test func topRankedKeepsTheBestWhenCandidatesArriveWorstFirst() {
        // Ascending input is the adversarial case for a bounded heap: every
        // candidate displaces the current worst, so the sift path runs on every
        // element.
        let ascending = (0..<200).map { makeItem(id: "asc:\($0)", title: "Item", score: $0) }

        #expect(SearchItemRanking.topRanked(ascending, limit: 3).map(\.score) == [199, 198, 197])
        #expect(SearchItemRanking.topRanked(ascending.reversed(), limit: 3).map(\.score) == [
            199,
            198,
            197,
        ])
    }

    @Test func pageRanksAndReportsTheTotalRatherThanThePageSize() {
        let items = makeItems(count: 40)

        let page = SearchItemRanking.page(items, limit: 5)

        #expect(page.items.count == 5)
        #expect(page.totalMatched == 40)
        #expect(page.items.map(\.id) == items.sorted(by: SearchItemRanking.ranksBefore).prefix(5)
            .map(\.id))
    }

    // MARK: - The learning boost against the match-shape ladder

    /// `SearchModelInvariantTests` keeps the *bands* far enough apart that no
    /// match score crosses one. This keeps the match *shapes* far enough apart
    /// that no learning boost crosses one.
    ///
    /// Learning orders results that matched the same way, so its whole range
    /// has to fit inside the narrowest step of the shape ladder. Otherwise an
    /// app someone opens constantly, reached only by correcting their typo,
    /// climbs over the app whose name they actually typed the start of.
    @Test func theLearningBoostIsSmallerThanEveryGapBetweenMatchShapes() {
        struct Shape: Sendable {
            let name: String
            let band: (floor: Int, ceiling: Int)
        }

        let shapeNames = [
            "exact",
            "namePrefix",
            "wordPrefix",
            "acronym",
            "typo(1 edit)",
            "typo(2 edits)",
        ]
        let ladder = FuzzyMatcher.ShapeScore.ladder
        #expect(
            ladder.count == shapeNames.count,
            "A new match shape needs a name and a gap check here"
        )

        let shapes = zip(shapeNames, ladder).map(Shape.init)
        let maxBoost = FuzzyMatcher.maximumLearningBoost

        // Floor against ceiling, not base against base.
        //
        // Every rung is a band, because each shape subtracts its own penalty —
        // candidate length, word or acronym offset. The worst a stronger shape
        // can score is its floor; the best a weaker one can score is its
        // ceiling. That difference is the only gap a learning boost has to fit
        // inside. Comparing bases measures a gap no real pair of scores ever
        // has, and reports room that is not there.
        for (higher, lower) in zip(shapes, shapes.dropFirst()) {
            let gap = higher.band.floor - lower.band.ceiling
            #expect(
                gap > maxBoost,
                """
                \(higher.name) can score as low as \(higher.band.floor) and \
                \(lower.name) as high as \(lower.band.ceiling) — a gap of \(gap), \
                which a learning boost of up to \(maxBoost) closes.
                """
            )
        }
    }

    /// The tightest rung, asserted against the matcher rather than the ladder.
    ///
    /// The gap check above reads constants. This one reads scores the matcher
    /// actually produced, so a penalty that stops being clamped fails here even
    /// if the ladder still claims otherwise. Both typos, one edit against two,
    /// because that pair is where the margin is smallest.
    @Test func aTwoEditTypoCannotBeLearnedPastAOneEditTypo() throws {
        let oneEdit = try #require(FuzzyMatcher.match(query: "chrome", candidate: "Google Chrom"))
        let twoEdits = try #require(FuzzyMatcher.match(query: "chrome", candidate: "Chromas"))

        #expect(oneEdit.score > twoEdits.score + FuzzyMatcher.maximumLearningBoost)
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
