import XCTest
@testable import Floodlight

final class FuzzyMatcherTests: XCTestCase {
    func testExactMatchRanksAbovePrefixAndSubsequence() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.score(query: "safari", candidate: "Safari"))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "saf", candidate: "Safari"))
        let subsequence = try XCTUnwrap(FuzzyMatcher.score(query: "sfr", candidate: "Safari"))

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, subsequence)
    }

    func testMissingCharactersDoNotMatch() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "Safari"))
    }

    func testEmptyQueryMatchesForRecentItems() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: "Safari"), 1)
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
}
