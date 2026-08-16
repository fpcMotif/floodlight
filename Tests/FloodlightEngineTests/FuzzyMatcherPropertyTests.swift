import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

/// Property-based tests for the fuzzy matcher.
///
/// The matcher normalizes both sides before scoring, so the properties
/// target the normalized form: idempotency of normalization, case and
/// diacritic folding, and the strict ordering exact > prefix > substring >
/// subsequence that the bands enforce.
struct FuzzyMatcherPropertyTests {
    // MARK: - Normalization idempotency

    @Test func normalizationIsIdempotent() throws {
        // Stated over real text. Folding is *not* idempotent for degenerate
        // sequences of bare combining marks with no base character — see
        // `FuzzyMatcherDifferentialTests.testNormalizationIsNotIdempotentForBareCombiningMarks`,
        // which pins that case deliberately.
        let realisticText = Gen<String>.frequency([
            (5, .string(
                alphabet: Array(
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_/."
                ),
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

    @Test func normalizationPreservesLengthForAscii() throws {
        try checkProperty(
            "normalize(s).count == s.count for pure ASCII",
            Gen<String>.asciiWithSeparators,
            runs: 400
        ) { value in
            FuzzyMatcher.normalized(value).count == value.count
        }
    }

    // MARK: - Case folding

    @Test func normalizationFoldsCase() throws {
        try checkProperty(
            "normalize(s) == normalize(s.uppercased())",
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { value in
            FuzzyMatcher.normalized(value) == FuzzyMatcher.normalized(value.uppercased())
        }
    }

    @Test func caseDoesNotAffectScore() throws {
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

    @Test func queryCaseDoesNotAffectScore() throws {
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

    @Test func normalizationFoldsDiacritics() {
        #expect(FuzzyMatcher.normalized("café") == FuzzyMatcher.normalized("cafe"))
        #expect(FuzzyMatcher.normalized("naïve") == FuzzyMatcher.normalized("naive"))
        #expect(FuzzyMatcher.normalized("résumé") == FuzzyMatcher.normalized("resume"))
    }

    @Test func diacriticsDoNotAffectScore() {
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "café") == FuzzyMatcher.score(
            query: "cafe",
            candidate: "cafe"
        ))
        #expect(FuzzyMatcher.score(query: "café", candidate: "cafe") == FuzzyMatcher.score(
            query: "cafe",
            candidate: "cafe"
        ))
    }

    // MARK: - Score ordering

    @Test func exactMatchScoresAbovePrefix() throws {
        let candidate = "safari"
        let exact = try #require(FuzzyMatcher.score(query: candidate, candidate: candidate))
        let prefix = try #require(FuzzyMatcher.score(query: "saf", candidate: candidate))
        #expect(exact > prefix)
    }

    @Test func prefixScoresAboveWordPrefix() throws {
        let namePrefix = try #require(FuzzyMatcher.score(
            query: "google",
            candidate: "Google Chrome"
        ))
        let wordPrefix = try #require(FuzzyMatcher.score(
            query: "chrome",
            candidate: "Google Chrome"
        ))
        #expect(namePrefix > wordPrefix)
    }

    @Test func wordPrefixScoresAboveAcronym() throws {
        let wordPrefix = try #require(FuzzyMatcher.score(
            query: "chrome",
            candidate: "Google Chrome"
        ))
        let acronym = try #require(FuzzyMatcher.score(query: "gc", candidate: "Google Chrome"))
        #expect(wordPrefix > acronym)
    }

    @Test func acronymScoresAboveTypo() throws {
        let acronym = try #require(FuzzyMatcher.score(query: "gc", candidate: "Google Chrome"))
        let typo = try #require(FuzzyMatcher.score(query: "gogle", candidate: "Google Chrome"))
        #expect(acronym > typo)
    }

    @Test func fullOrderingExactPrefixWordPrefixAcronymTypo() throws {
        let candidate = "Google Chrome"
        let exact = try #require(FuzzyMatcher.score(query: "google chrome", candidate: candidate))
        let prefix = try #require(FuzzyMatcher.score(query: "google", candidate: candidate))
        let wordPrefix = try #require(FuzzyMatcher.score(query: "chrome", candidate: candidate))
        let acronym = try #require(FuzzyMatcher.score(query: "gc", candidate: candidate))
        let typo = try #require(FuzzyMatcher.score(query: "gogle", candidate: candidate))
        #expect(exact > prefix)
        #expect(prefix > wordPrefix)
        #expect(wordPrefix > acronym)
        #expect(acronym > typo)
    }

    // MARK: - Empty query

    @Test func emptyQueryReturnsOneForScoreAndNilForEvidence() throws {
        try checkProperty(
            "score('', c) == 1 and match('', c) == nil for any c",
            Gen<String>.hostile,
            runs: 400
        ) { candidate in
            FuzzyMatcher.score(query: "", candidate: candidate) == 1
                && FuzzyMatcher.match(query: "", candidate: candidate) == nil
        }
    }

    @Test func emptyQueryOnEmptyCandidateReturnsOne() {
        #expect(FuzzyMatcher.score(query: "", candidate: "") == 1)
        #expect(FuzzyMatcher.match(query: "", candidate: "") == nil)
    }

    // MARK: - Non-match

    @Test func shortQueryNonMatchReturnsNil() throws {
        try checkProperty(
            "score(query, candidate) == nil when 1-2 char query has chars not in candidate",
            Gen<String>.string(alphabet: Array("abcdefghijklmnopqrstuvwxyz"), length: 1...2),
            Gen<String>.lowercaseASCII,
            runs: 400
        ) { query, candidate in
            let queryChars = Set(query)
            let candidateChars = Set(candidate)
            if queryChars.isSubset(of: candidateChars) { return true }
            return FuzzyMatcher.score(query: query, candidate: candidate) == nil
        }
    }

    @Test func queryWithCharsNotInCandidateReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "abc") == nil)
        #expect(FuzzyMatcher.score(query: "z", candidate: "abc") == nil)
    }

    // MARK: - ASCII / string equivalence

    @Test func aSCIIFastPathMatchesStringScorer() {
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
                #expect(FuzzyMatcher.score(
                    normalizedQuery: query,
                    normalizedCandidate: candidate
                ) == FuzzyMatcher.scoreASCII(
                    normalizedQuery: Array(query.utf8),
                    normalizedCandidate: Array(candidate.utf8)
                ), "\(query) in \(candidate)")
            }
        }
    }

    @Test func aSCIIFastPathMatchesForRandomAscii() throws {
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

    @Test func confidentMatchThresholdIsBelowExactBand() {
        #expect(FuzzyMatcher.confidentMatchThreshold < 20_000)
        #expect(FuzzyMatcher.confidentMatchThreshold < 15_000)
    }

    @Test func exactMatchExceedsConfidenceThreshold() throws {
        #expect(try #require(FuzzyMatcher.score(query: "test", candidate: "test")) > FuzzyMatcher
            .confidentMatchThreshold)
    }

    @Test func prefixMatchExceedsConfidenceThreshold() throws {
        #expect(try #require(FuzzyMatcher.score(query: "tes", candidate: "test")) > FuzzyMatcher
            .confidentMatchThreshold)
    }

    @Test func looseSubsequencesAreRejected() {
        // The matcher rejects arbitrary scattered subsequences like 'sfr' in 'safari'
        #expect(FuzzyMatcher.score(query: "sfr", candidate: "safari") == nil)
        #expect(FuzzyMatcher.score(query: "gh", candidate: "Grapher") == nil)
        #expect(FuzzyMatcher.score(query: "gh", candidate: "Google Chrome") == nil)
        #expect(FuzzyMatcher.score(query: "gh", candidate: "Zed Nightly") == nil)
    }

    // MARK: - Score determinism

    @Test func scoreIsDeterministic() throws {
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
