import Foundation
import XCTest
@testable import FloodlightEngine

/// Harsh, critical stress tests for `FuzzyMatcher` — adversarial inputs,
/// boundary conditions, and pathological strings designed to break the
/// scoring algorithm.
final class FuzzyMatcherStressTests: XCTestCase {

    // MARK: - Single character queries

    func testSingleCharacterQueryMatchesIfPresent() {
        for char in "abcdefghijklmnopqrstuvwxyz" {
            let query = String(char)
            let candidate = "test_\(char)_string"
            XCTAssertNotNil(FuzzyMatcher.score(query: query, candidate: candidate),
                "single char '\(char)' should match")
        }
    }

    func testSingleCharacterQueryDoesNotMatchIfAbsent() {
        for char in "abcdefghijklmnopqrstuvwxyz" {
            let query = String(char)
            let candidate = "bcdfghjklmnpqrstvwxyz" // missing char
            if !candidate.contains(char) {
                XCTAssertNil(FuzzyMatcher.score(query: query, candidate: candidate),
                    "single char '\(char)' should not match candidate without it")
            }
        }
    }

    // MARK: - Very long strings

    func testVeryLongCandidate() {
        let candidate = String(repeating: "a", count: 10_000)
        let query = "a"
        let score = FuzzyMatcher.score(query: query, candidate: candidate)
        // A genuine prefix match, but the prefix band subtracts the full
        // candidate length — 15_000 - 10_000 = 5_000 lands BELOW the
        // confidence threshold. Long candidates bury their own prefixes.
        XCTAssertEqual(score, 15_000 - 10_000)
        XCTAssertLessThan(score!, FuzzyMatcher.confidentMatchThreshold)
    }

    func testVeryLongQuery() {
        let query = String(repeating: "a", count: 1_000)
        let candidate = String(repeating: "a", count: 2_000)
        let score = FuzzyMatcher.score(query: query, candidate: candidate)
        XCTAssertNotNil(score, "long query of all matching chars should match")
    }

    func testVeryLongNonMatchingQuery() {
        let query = String(repeating: "z", count: 1_000)
        let candidate = String(repeating: "a", count: 1_000)
        XCTAssertNil(FuzzyMatcher.score(query: query, candidate: candidate))
    }

    // MARK: - All same character

    func testAllSameCharacterCandidate() {
        let candidate = String(repeating: "a", count: 100)
        // Every query here is a proper prefix, never an exact match, so all
        // land on the same prefix score: 15_000 - candidate.count.
        XCTAssertEqual(FuzzyMatcher.score(query: "a", candidate: candidate), 15_000 - 100)
        XCTAssertEqual(FuzzyMatcher.score(query: "aa", candidate: candidate), 15_000 - 100)
        XCTAssertEqual(FuzzyMatcher.score(query: String(repeating: "a", count: 50), candidate: candidate), 15_000 - 100)
        // ...and the exact match still wins outright.
        XCTAssertEqual(FuzzyMatcher.score(query: candidate, candidate: candidate), 20_000)
    }

    // MARK: - Boundary detection

    func testBoundaryAfterHyphen() {
        let score = FuzzyMatcher.score(query: "s", candidate: "x-safari")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(score!, FuzzyMatcher.confidentMatchThreshold,
            "match after hyphen should get boundary bonus")
    }

    func testBoundaryAfterUnderscore() {
        let score = FuzzyMatcher.score(query: "s", candidate: "x_safari")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(score!, FuzzyMatcher.confidentMatchThreshold)
    }

    func testBoundaryAfterSlash() {
        let score = FuzzyMatcher.score(query: "s", candidate: "x/safari")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(score!, FuzzyMatcher.confidentMatchThreshold)
    }

    func testBoundaryAfterDot() {
        let score = FuzzyMatcher.score(query: "s", candidate: "x.safari")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(score!, FuzzyMatcher.confidentMatchThreshold)
    }

    func testNoBoundaryBonusForMidWordMatch() {
        // Single-character queries always take the substring path, where
        // position (not boundaries) decides the score — so the boundary
        // bonus is only observable in the subsequence band. "sf" is a
        // subsequence of both candidates but a substring of neither.
        let atBoundary = FuzzyMatcher.score(query: "sf", candidate: "s-f")
        let midWord = FuzzyMatcher.score(query: "sf", candidate: "sxf")
        XCTAssertNotNil(midWord)
        XCTAssertNotNil(atBoundary)
        XCTAssertGreaterThan(atBoundary!, midWord!,
            "boundary match should score higher than mid-word match")
    }

    // MARK: - Consecutive character scoring

    func testConsecutiveCharactersScoreHigherThanScattered() {
        let consecutive = FuzzyMatcher.score(query: "saf", candidate: "safari")
        let scattered = FuzzyMatcher.score(query: "sfr", candidate: "safari")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(consecutive!, scattered!,
            "consecutive chars should score higher than scattered")
    }

    func testAllConsecutiveMatchesHighestSubsequenceScore() {
        let allConsecutive = FuzzyMatcher.score(query: "safar", candidate: "safari")
        let someScattered = FuzzyMatcher.score(query: "sfai", candidate: "safari")
        XCTAssertNotNil(allConsecutive)
        XCTAssertNotNil(someScattered)
        XCTAssertGreaterThan(allConsecutive!, someScattered!)
    }

    // MARK: - Score scale

    func testExactMatchScore() {
        XCTAssertEqual(FuzzyMatcher.score(query: "safari", candidate: "safari"), 20_000)
    }

    func testPrefixMatchScore() {
        let score = FuzzyMatcher.score(query: "saf", candidate: "safari")
        XCTAssertEqual(score, 15_000 - "safari".count)
    }

    func testSubstringMatchScore() {
        let score = FuzzyMatcher.score(query: "far", candidate: "safari")
        XCTAssertEqual(score, 12_000 - 2) // "far" starts at index 2
    }

    func testSubsequenceMatchStartsAt8000() {
        let score = FuzzyMatcher.score(query: "sfr", candidate: "safari")
        XCTAssertNotNil(score)
        XCTAssertLessThan(score!, 9_000, "subsequence match should be below confidence threshold")
        XCTAssertGreaterThanOrEqual(score!, 0, "subsequence score should be non-negative")
    }

    // MARK: - ASCII fast path specifics

    func testASCIIExactMatch() {
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("test".utf8),
            normalizedCandidate: Array("test".utf8)
        )
        XCTAssertEqual(score, 20_000)
    }

    func testASCIIPrefixMatch() {
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("te".utf8),
            normalizedCandidate: Array("test".utf8)
        )
        XCTAssertEqual(score, 15_000 - 4)
    }

    func testASCIISubsequenceMatch() {
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("ts".utf8),
            normalizedCandidate: Array("test".utf8)
        )
        XCTAssertNotNil(score)
        XCTAssertLessThan(score!, 9_000)
    }

    func testASCIINonMatchReturnsNil() {
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("xyz".utf8),
            normalizedCandidate: Array("test".utf8)
        )
        XCTAssertNil(score)
    }

    func testASCIIEmptyQueryReturnsOne() {
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: [],
            normalizedCandidate: Array("test".utf8)
        )
        XCTAssertEqual(score, 1)
    }

    // MARK: - Normalization edge cases

    func testNormalizeEmptyString() {
        XCTAssertEqual(FuzzyMatcher.normalized(""), "")
    }

    func testNormalizeAlreadyLowercase() {
        XCTAssertEqual(FuzzyMatcher.normalized("safari"), "safari")
    }

    func testNormalizeUppercase() {
        XCTAssertEqual(FuzzyMatcher.normalized("SAFARI"), "safari")
    }

    func testNormalizeMixedCase() {
        XCTAssertEqual(FuzzyMatcher.normalized("SaFaRi"), "safari")
    }

    func testNormalizeWithNumbers() {
        XCTAssertEqual(FuzzyMatcher.normalized("Test123"), "test123")
    }

    func testNormalizeWithSpecialChars() {
        XCTAssertEqual(FuzzyMatcher.normalized("Wi-Fi_Connection"), "wi-fi_connection")
    }

    // MARK: - Query longer than candidate

    func testQueryLongerThanCandidateReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "safari browser", candidate: "safari"))
        XCTAssertNil(FuzzyMatcher.score(query: "abcdef", candidate: "abc"))
    }

    // MARK: - Identical query and candidate

    func testIdenticalQueryAndCandidate() {
        for word in ["a", "ab", "test", "safari", "keyboard", "a very long sentence"] {
            XCTAssertEqual(FuzzyMatcher.score(query: word, candidate: word), 20_000,
                "identical query and candidate should score 20_000 for '\(word)'")
        }
    }

    // MARK: - Reversed query

    func testReversedQueryDoesNotMatch() {
        XCTAssertNil(FuzzyMatcher.score(query: "irfas", candidate: "safari"))
        XCTAssertNil(FuzzyMatcher.score(query: "retupmoc", candidate: "computer"))
    }

    // MARK: - Partial match at end

    func testMatchAtEndOfCandidate() {
        let score = FuzzyMatcher.score(query: "ri", candidate: "safari")
        XCTAssertNotNil(score)
        // "ri" starts at index 4 in "safari"
        XCTAssertEqual(score, 12_000 - 4)
    }

    // MARK: - Score is deterministic

    func testScoreIsDeterministic() {
        let queries = ["saf", "sfr", "safari", "xyz", ""]
        let candidates = ["safari", "appearance", "test", ""]
        for query in queries {
            for candidate in candidates {
                let score1 = FuzzyMatcher.score(query: query, candidate: candidate)
                let score2 = FuzzyMatcher.score(query: query, candidate: candidate)
                XCTAssertEqual(score1, score2, "score is not deterministic for query='\(query)' candidate='\(candidate)'")
            }
        }
    }
}
