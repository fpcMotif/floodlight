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
}
