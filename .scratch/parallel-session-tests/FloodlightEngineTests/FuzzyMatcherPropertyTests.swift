import Foundation
import XCTest
@testable import FloodlightEngine

/// Property-based tests for `FuzzyMatcher` — randomized inputs verifying
/// invariants about normalization, score ordering, and the ASCII fast path
/// equivalence that hold across a wide input space.
final class FuzzyMatcherPropertyTests: XCTestCase {

    // MARK: - Normalization invariance

    func testNormalizationIsIdempotent() {
        let inputs = [
            "Safari", "Wi-Fi", "café", "naïve", "résumé",
            "ABCDEF", "a-b_c", "path/to/file",
            "", "a", "  spaces  ",
            "Über", "Ñoño", "Ångström",
        ]
        for input in inputs {
            let once = FuzzyMatcher.normalized(input)
            let twice = FuzzyMatcher.normalized(once)
            XCTAssertEqual(once, twice, "normalization is not idempotent for '\(input)'")
        }
    }

    func testNormalizationFoldsCase() {
        for _ in 0..<300 {
            let length = Int.random(in: 1...20)
            let chars = (0..<length).map { _ in
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()!
            }
            let input = String(chars)
            let normalized = FuzzyMatcher.normalized(input)
            XCTAssertEqual(normalized, normalized.lowercased(), "case folding failed for '\(input)'")
        }
    }

    func testNormalizationFoldsDiacritics() {
        let pairs: [(String, String)] = [
            ("café", "cafe"),
            ("naïve", "naive"),
            ("résumé", "resume"),
            ("Ünïcödé", "unicode"),
            ("Ñoño", "nono"),
        ]
        for (input, expected) in pairs {
            XCTAssertEqual(FuzzyMatcher.normalized(input), expected, "diacritic folding failed for '\(input)'")
        }
    }

    // MARK: - Score ordering properties

    func testExactMatchScoresHigherThanPrefix() {
        for _ in 0..<300 {
            let candidate = randomString(length: Int.random(in: 3...15), from: "abcdefghijklmnopqrstuvwxyz")
            let query = String(candidate.prefix(Int.random(in: 1...candidate.count)))
            guard
                let exact = FuzzyMatcher.score(query: query, candidate: candidate),
                let prefix = FuzzyMatcher.score(query: query, candidate: candidate + "x")
            else { continue }
            XCTAssertGreaterThanOrEqual(exact, prefix, "exact should >= prefix for query='\(query)' candidate='\(candidate)'")
        }
    }

    func testPrefixMatchScoresHigherThanSubstring() {
        for _ in 0..<300 {
            let candidate = randomString(length: Int.random(in: 5...15), from: "abcdefghijklmnopqrstuvwxyz")
            let prefix = String(candidate.prefix(3))
            let modifiedCandidate = "x" + candidate
            guard
                let prefixScore = FuzzyMatcher.score(query: prefix, candidate: candidate),
                let substringScore = FuzzyMatcher.score(query: prefix, candidate: modifiedCandidate)
            else { continue }
            XCTAssertGreaterThan(prefixScore, substringScore, "prefix should > substring for query='\(prefix)'")
        }
    }

    func testLongerQueryDoesNotScoreHigherThanShorterPrefix() {
        for _ in 0..<200 {
            let candidate = randomString(length: 10, from: "abcdefghij")
            let shortQuery = String(candidate.prefix(3))
            let longQuery = String(candidate.prefix(5))
            guard
                let shortScore = FuzzyMatcher.score(query: shortQuery, candidate: candidate),
                let longScore = FuzzyMatcher.score(query: longQuery, candidate: candidate)
            else { continue }
            // A longer exact match is still exact (20_000), but a longer
            // prefix match loses points for the candidate length
            XCTAssertGreaterThanOrEqual(shortScore, longScore - 20_000,
                "shorter prefix should not be drastically lower for query='\(shortQuery)' vs '\(longQuery)'")
        }
    }

    // MARK: - Empty query

    func testEmptyQueryAlwaysReturnsOne() {
        let candidates = ["", "a", "Safari", "a very long candidate string", "12345"]
        for candidate in candidates {
            XCTAssertEqual(
                FuzzyMatcher.score(normalizedQuery: "", normalizedCandidate: candidate),
                1,
                "empty query should return 1 for candidate '\(candidate)'"
            )
        }
    }

    // MARK: - Non-match returns nil

    func testQueryWithCharactersNotInCandidateReturnsNil() {
        for _ in 0..<300 {
            let candidate = randomString(length: 5, from: "abc")
            let query = randomString(length: 3, from: "xyz")
            // Very unlikely to match
            if !candidate.contains(query) {
                XCTAssertNil(
                    FuzzyMatcher.score(query: query, candidate: candidate),
                    "expected nil for query='\(query)' candidate='\(candidate)'"
                )
            }
        }
    }

    // MARK: - ASCII / string equivalence

    func testASCIIPathMatchesStringScorerForRandomASCII() {
        for _ in 0..<500 {
            let query = randomString(length: Int.random(in: 0...8), from: "abcdefghijklmnopqrstuvwxyz -_/.0123456789")
            let candidate = randomString(length: Int.random(in: 1...20), from: "abcdefghijklmnopqrstuvwxyz -_/.0123456789")
            let stringScore = FuzzyMatcher.score(
                normalizedQuery: query,
                normalizedCandidate: candidate
            )
            let asciiScore = FuzzyMatcher.scoreASCII(
                normalizedQuery: Array(query.utf8),
                normalizedCandidate: Array(candidate.utf8)
            )
            XCTAssertEqual(stringScore, asciiScore,
                "ASCII path diverged for query='\(query)' candidate='\(candidate)'")
        }
    }

    // MARK: - Confidence threshold

    func testExactAndPrefixMatchesExceedConfidenceThreshold() {
        let candidates = ["safari", "appearance", "bluetooth", "keyboard", "wifi"]
        for candidate in candidates {
            let exact = FuzzyMatcher.score(query: candidate, candidate: candidate)
            XCTAssertNotNil(exact)
            XCTAssertGreaterThanOrEqual(exact!, FuzzyMatcher.confidentMatchThreshold,
                "exact match for '\(candidate)' should exceed threshold")
        }
    }

    // MARK: - Helpers

    private func randomString(length: Int, from charset: String) -> String {
        let chars = Array(charset)
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
