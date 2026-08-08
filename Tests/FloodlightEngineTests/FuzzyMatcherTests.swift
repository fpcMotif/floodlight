import XCTest
@testable import FloodlightEngine

final class FuzzyMatcherTests: XCTestCase {
    func testExactMatchRanksAbovePrefixAndSubsequence() throws {
        let exact = try XCTUnwrap(score(query: "safari", candidate: "Safari"))
        let prefix = try XCTUnwrap(score(query: "saf", candidate: "Safari"))
        let subsequence = try XCTUnwrap(score(query: "sfr", candidate: "Safari"))

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, subsequence)
    }

    func testMissingCharactersDoNotMatch() {
        XCTAssertNil(score(query: "xyz", candidate: "Safari"))
    }

    func testEmptyQueryMatchesForRecentItems() {
        XCTAssertEqual(score(query: "", candidate: "Safari"), 1)
    }

    func testASCIIFastPathMatchesStringScorer() {
        let queries = ["", "a", "app", "wifi", "privacy", "sftwre", "x y", "zzz"]
        let candidates = [
            "appearance light dark",
            "wi-fi wifi wireless network",
            "privacy & security",
            "software update macos",
            "users_groups/password",
            "short",
        ]

        for query in queries {
            for candidate in candidates {
                XCTAssertEqual(
                    FuzzyMatcher.score(
                        normalizedQuery: query,
                        normalizedCandidate: candidate
                    ),
                    FuzzyMatcher.scoreASCII(
                        normalizedQuery: Array(query.utf8),
                        normalizedCandidate: Array(candidate.utf8)
                    ),
                    "\(query) in \(candidate)"
                )
            }
        }
    }

    /// Scores a raw query against a raw candidate, the way a catalog does.
    ///
    /// The engine has no unnormalized entry point — every caller normalizes
    /// once at the catalog boundary and scores many candidates against the
    /// result — so the tests normalize here rather than keeping a production
    /// wrapper alive that only tests call.
    private func score(query: String, candidate: String) -> Int? {
        FuzzyMatcher.score(
            normalizedQuery: FuzzyMatcher.normalized(query),
            normalizedCandidate: FuzzyMatcher.normalized(candidate)
        )
    }
}
