import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

/// Property-based tests for the fuzzy matcher.
///
/// The matcher normalizes both sides before scoring, so the properties
/// target the normalized form: idempotency of normalization, case and
/// diacritic folding, and the strict ordering exact > prefix > substring >
/// subsequence that the bands enforce.
final class FuzzyMatcherPropertyTests: XCTestCase {
    // MARK: - Normalization idempotency

    func testNormalizationIsIdempotent() throws {
        // Stated over real text. Folding is *not* idempotent for degenerate
        // sequences of bare combining marks with no base character — see
        // `FuzzyMatcherDifferentialTests.testNormalizationIsNotIdempotentForBareCombiningMarks`,
        // which pins that case deliberately.
        let realisticText = Gen<String>.frequency([
            (5, .string(
                alphabet: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_/."),
                length: 0...20
            )),
            (3, .string(alphabet: Array("éüñçåøßÆΩàèìòùÄÖÜ"), length: 0...10)),
            (2, .string(alphabet: Array("日本語のファイル한국어Кириллица"), length: 0...10)),
            (1, .string(alphabet: Array("👨‍👩‍👧‍👦🇦🇶👋🏽🧑‍🚀"), length: 0...4)),
        ])
        try checkProperty(
            "normalize(normalize(s)) == normalize(s) for real text",
            realisticText,
            runs: 400
        ) { value in
            let once = FuzzyMatcher.normalized(value)
            let twice = FuzzyMatcher.normalized(once)
            return once == twice
        }
    }

    func testNormalizationPreservesLengthForAscii() throws {
        try checkProperty(
            "normalize(s).count == s.count for pure ASCII",
            Gen<String>.asciiWithSeparators,
            runs: 400
        ) { value in
            FuzzyMatcher.normalized(value).count == value.count
        }
    }

    // MARK: - Case folding

    func testNormalizationFoldsCase() throws {
        try checkProperty(
            "normalize(s) == normalize(s.uppercased())",
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { value in
            FuzzyMatcher.normalized(value) == FuzzyMatcher.normalized(value.uppercased())
        }
    }

    func testCaseDoesNotAffectScore() throws {
        try checkProperty(
            "score(s, c) == score(s, c.uppercased())",
            Gen<String>.lowercaseASCII,
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { query, candidate in
            FuzzyMatcher.score(query: query, candidate: candidate)
                == FuzzyMatcher.score(query: query, candidate: candidate.uppercased())
        }
    }

    func testQueryCaseDoesNotAffectScore() throws {
        try checkProperty(
            "score match regardless of query case",
            Gen<String>.lowercaseASCII,
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { query, candidate in
            FuzzyMatcher.score(query: query, candidate: candidate)
                == FuzzyMatcher.score(query: query.uppercased(), candidate: candidate)
        }
    }

    // MARK: - Diacritic folding

    func testNormalizationFoldsDiacritics() {
        XCTAssertEqual(FuzzyMatcher.normalized("café"), FuzzyMatcher.normalized("cafe"))
        XCTAssertEqual(FuzzyMatcher.normalized("naïve"), FuzzyMatcher.normalized("naive"))
        XCTAssertEqual(FuzzyMatcher.normalized("résumé"), FuzzyMatcher.normalized("resume"))
    }

    func testDiacriticsDoNotAffectScore() {
        XCTAssertEqual(
            FuzzyMatcher.score(query: "cafe", candidate: "café"),
            FuzzyMatcher.score(query: "cafe", candidate: "cafe")
        )
        XCTAssertEqual(
            FuzzyMatcher.score(query: "café", candidate: "cafe"),
            FuzzyMatcher.score(query: "cafe", candidate: "cafe")
        )
    }

    // MARK: - Score ordering

    func testExactMatchScoresAbovePrefix() throws {
        let candidate = "safari"
        let exact = try XCTUnwrap(FuzzyMatcher.score(query: candidate, candidate: candidate))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "saf", candidate: candidate))
        XCTAssertGreaterThan(exact, prefix)
    }

    func testPrefixScoresAboveSubstring() throws {
        let candidate = "safari"
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "saf", candidate: candidate))
        let substring = try XCTUnwrap(FuzzyMatcher.score(query: "far", candidate: candidate))
        XCTAssertGreaterThan(prefix, substring)
    }

    func testSubstringScoresAboveSubsequence() throws {
        let candidate = "safari"
        let substring = try XCTUnwrap(FuzzyMatcher.score(query: "far", candidate: candidate))
        let subsequence = try XCTUnwrap(FuzzyMatcher.score(query: "sfr", candidate: candidate))
        XCTAssertGreaterThan(substring, subsequence)
    }

    func testFullOrderingExactPrefixSubstringSubsequence() throws {
        let candidate = "spotlight"
        let exact = try XCTUnwrap(FuzzyMatcher.score(query: "spotlight", candidate: candidate))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "spot", candidate: candidate))
        let substring = try XCTUnwrap(FuzzyMatcher.score(query: "pot", candidate: candidate))
        let subsequence = try XCTUnwrap(FuzzyMatcher.score(query: "spt", candidate: candidate))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, substring)
        XCTAssertGreaterThan(substring, subsequence)
    }

    // MARK: - Empty query

    func testEmptyQueryReturnsOne() throws {
        try checkProperty(
            "score('', c) == 1 for any c",
            Gen<String>.hostile,
            runs: 400
        ) { candidate in
            FuzzyMatcher.score(query: "", candidate: candidate) == 1
        }
    }

    func testEmptyQueryOnEmptyCandidateReturnsOne() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: ""), 1)
    }

    // MARK: - Non-match

    func testNonMatchReturnsNil() throws {
        try checkProperty(
            "score(query, candidate) == nil when query chars not in candidate",
            Gen<String>.lowercaseASCII,
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { query, candidate in
            // If the query contains a character not present in the candidate,
            // the score must be nil.
            let queryChars = Set(query)
            let candidateChars = Set(candidate)
            if queryChars.isSubset(of: candidateChars) { return true }
            return FuzzyMatcher.score(query: query, candidate: candidate) == nil
        }
    }

    func testQueryWithCharsNotInCandidateReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "abc"))
        XCTAssertNil(FuzzyMatcher.score(query: "z", candidate: "abc"))
    }

    // MARK: - ASCII / string equivalence

    func testASCIIFastPathMatchesStringScorer() throws {
        let queries = ["", "a", "app", "wifi", "privacy", "sftwre", "x y", "zzz", "abc", "test"]
        let candidates = [
            "appearance light dark",
            "wi-fi wifi wireless network",
            "privacy & security",
            "software update macos",
            "users_groups/password",
            "short",
            "abcdefghijklmnopqrstuvwxyz",
            "hello world foo bar",
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

    func testASCIIFastPathMatchesForRandomAscii() throws {
        try checkProperty(
            "scoreASCII == score for ASCII strings",
            Gen<String>.asciiWithSeparators,
            Gen<String>.asciiWithSeparators,
            runs: 400
        ) { query, candidate in
            FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
                == FuzzyMatcher.scoreASCII(
                    normalizedQuery: Array(query.utf8),
                    normalizedCandidate: Array(candidate.utf8)
                )
        }
    }

    // MARK: - Confidence threshold

    func testConfidentMatchThresholdIsBelowExactBand() {
        XCTAssertLessThan(FuzzyMatcher.confidentMatchThreshold, 20_000)
        XCTAssertLessThan(FuzzyMatcher.confidentMatchThreshold, 15_000)
    }

    func testExactMatchExceedsConfidenceThreshold() {
        XCTAssertGreaterThan(
            FuzzyMatcher.score(query: "test", candidate: "test")!,
            FuzzyMatcher.confidentMatchThreshold
        )
    }

    func testPrefixMatchExceedsConfidenceThreshold() {
        XCTAssertGreaterThan(
            FuzzyMatcher.score(query: "tes", candidate: "test")!,
            FuzzyMatcher.confidentMatchThreshold
        )
    }

    func testSubsequenceBelowThresholdMayStillMatch() {
        // A weak subsequence can land below the confidence threshold even
        // though it technically "matches" — the threshold is what separates
        // signal from noise.
        let score = FuzzyMatcher.score(query: "sfr", candidate: "safari")
        XCTAssertNotNil(score)
    }

    // MARK: - Score determinism

    func testScoreIsDeterministic() throws {
        try checkProperty(
            "score(q, c) == score(q, c) on repeat calls",
            Gen<String>.hostile,
            Gen<String>.hostile,
            runs: 300
        ) { query, candidate in
            FuzzyMatcher.score(query: query, candidate: candidate)
                == FuzzyMatcher.score(query: query, candidate: candidate)
        }
    }
}
