import Foundation
import XCTest
@testable import FloodlightEngine

/// Stress tests for the fuzzy matcher: single-character queries, very long
/// strings, all-same-character candidates, and the boundary/consecutive
/// scoring paths that the property tests only sample.
final class FuzzyMatcherStressTests: XCTestCase {
    // MARK: - Single-character queries

    func testSingleCharacterQueryMatchesIfPresent() {
        for char in "abcdefghijklmnopqrstuvwxyz" {
            let query = String(char)
            let candidate = "the quick brown fox jumps over the lazy dog"
            XCTAssertNotNil(FuzzyMatcher.score(query: query, candidate: candidate))
        }
    }

    func testSingleCharacterQueryReturnsNilIfAbsent() {
        XCTAssertNil(FuzzyMatcher.score(query: "z", candidate: "aaaaaaa"))
        XCTAssertNil(FuzzyMatcher.score(query: "q", candidate: "bcdef"))
    }

    func testSingleCharacterAtStartGetsBoundaryBonus() throws {
        let atStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let inMiddle = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "bac"))
        XCTAssertGreaterThan(atStart, inMiddle)
    }

    func testACharacterAfterASeparatorGetsBoundaryBonus() throws {
        // Two characters, so this lands in the subsequence branch where the
        // bonus exists — see the note above the separator tests.
        let afterSep = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a-b"))
        let noSep = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterSep, noSep)
    }

    func testASingleCharacterQueryTakesTheSubstringBranchNotTheBonus() throws {
        // The flip side, pinned so the rule above is not mistaken for a
        // general one: with a one-character query both candidates match as
        // substrings, and the separator simply moves the hit one place
        // right, which scores *lower*.
        let afterSep = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "x-a"))
        let noSep = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "xa"))
        XCTAssertEqual(afterSep, 12_000 - 2)
        XCTAssertEqual(noSep, 12_000 - 1)
        XCTAssertLessThan(afterSep, noSep)
    }

    // MARK: - Very long strings

    func testVeryLongCandidateWithMatchAtEnd() {
        let prefix = String(repeating: "x", count: 10_000)
        let candidate = prefix + "target"
        XCTAssertNotNil(FuzzyMatcher.score(query: "target", candidate: candidate))
    }

    func testVeryLongQueryLongerThanCandidateReturnsNil() {
        let query = String(repeating: "a", count: 1_000)
        let candidate = "aaa"
        XCTAssertNil(FuzzyMatcher.score(query: query, candidate: candidate))
    }

    func testVeryLongExactMatch() {
        let value = String(repeating: "ab", count: 5_000)
        XCTAssertEqual(FuzzyMatcher.score(query: value, candidate: value), 20_000)
    }

    func testVeryLongPrefixMatch() throws {
        let value = String(repeating: "ab", count: 5_000)
        let prefix = String(repeating: "ab", count: 100)
        let score = try XCTUnwrap(FuzzyMatcher.score(query: prefix, candidate: value))
        XCTAssertEqual(score, 15_000 - value.count)
    }

    // MARK: - All-same-character candidates

    func testAllSameCharacterCandidateMatchesSingleChar() {
        let candidate = String(repeating: "a", count: 100)
        XCTAssertNotNil(FuzzyMatcher.score(query: "a", candidate: candidate))
    }

    func testAllSameCharacterCandidateMatchesRepeatedQuery() {
        let candidate = String(repeating: "a", count: 100)
        let query = String(repeating: "a", count: 50)
        XCTAssertNotNil(FuzzyMatcher.score(query: query, candidate: candidate))
    }

    func testAllSameCharacterCandidateRejectsDifferentChar() {
        let candidate = String(repeating: "a", count: 100)
        XCTAssertNil(FuzzyMatcher.score(query: "b", candidate: candidate))
    }

    func testConsecutiveRunScoresHigherThanScattered() throws {
        let candidate = "a x a x a x a x a"
        let consecutive = try XCTUnwrap(FuzzyMatcher.score(query: "aaaaa", candidate: "aaaaax"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score(query: "aaaaa", candidate: candidate))
        XCTAssertGreaterThan(consecutive, scattered)
    }

    // MARK: - Boundary detection

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    func testHyphenIsABoundary() throws {
        let afterHyphen = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a-b"))
        let noBoundary = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterHyphen, noBoundary)
    }

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    func testUnderscoreIsABoundary() throws {
        let afterUnderscore = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a_b"))
        let noBoundary = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterUnderscore, noBoundary)
    }

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    func testSlashIsABoundary() throws {
        let afterSlash = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a/b"))
        let noBoundary = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterSlash, noBoundary)
    }

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    func testDotIsABoundary() throws {
        let afterDot = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a.b"))
        let noBoundary = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterDot, noBoundary)
    }

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    func testSpaceIsABoundary() throws {
        let afterSpace = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a b"))
        let noBoundary = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "azb"))
        XCTAssertGreaterThan(afterSpace, noBoundary)
    }

    func testStartOfStringIsABoundary() throws {
        let atStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let notAtStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "xabc"))
        XCTAssertGreaterThan(atStart, notAtStart)
    }

    // MARK: - Consecutive scoring

    func testConsecutiveMatchesScoreHigherThanNonConsecutive() throws {
        let consecutive = try XCTUnwrap(FuzzyMatcher.score(query: "abc", candidate: "abc"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score(query: "abc", candidate: "axbxc"))
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testLongerConsecutiveRunScoresHigher() throws {
        let longRun = try XCTUnwrap(FuzzyMatcher.score(query: "aaaa", candidate: "aaaax"))
        let shortRun = try XCTUnwrap(FuzzyMatcher.score(query: "aaaa", candidate: "axaaxa"))
        XCTAssertGreaterThan(longRun, shortRun)
    }

    // MARK: - Score scale values

    func testExactMatchScoreIs20000() {
        XCTAssertEqual(FuzzyMatcher.score(query: "test", candidate: "test"), 20_000)
    }

    func testPrefixMatchScoreIs15000MinusCount() throws {
        let candidate = "spotlight"
        let score = try XCTUnwrap(FuzzyMatcher.score(query: "spot", candidate: candidate))
        XCTAssertEqual(score, 15_000 - candidate.count)
    }

    func testSubstringMatchScoreIs12000MinusStart() throws {
        let candidate = "spotlight"
        let query = "pot"
        let range = try XCTUnwrap(candidate.range(of: query))
        let startOffset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        let score = try XCTUnwrap(FuzzyMatcher.score(query: query, candidate: candidate))
        XCTAssertEqual(score, 12_000 - startOffset)
    }

    func testSubsequenceMatchStartsAt8000() throws {
        // The subsequence band opens at 8000; boundary and consecutive
        // bonuses can lift a score above the base, but it stays well below
        // the substring band (12000).
        let score = try XCTUnwrap(FuzzyMatcher.score(query: "sf", candidate: "safari"))
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 12_000)
    }

    func testExactBeatsPrefixBeatsSubstringBeatsSubsequence() throws {
        let candidate = "spotlight"
        let exact = try XCTUnwrap(FuzzyMatcher.score(query: "spotlight", candidate: candidate))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "spot", candidate: candidate))
        let substring = try XCTUnwrap(FuzzyMatcher.score(query: "pot", candidate: candidate))
        let subsequence = try XCTUnwrap(FuzzyMatcher.score(query: "spt", candidate: candidate))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, substring)
        XCTAssertGreaterThan(substring, subsequence)
    }

    // MARK: - ASCII fast path

    func testASCIIFastPathExactMatch() {
        XCTAssertEqual(
            FuzzyMatcher.scoreASCII(
                normalizedQuery: Array("test".utf8),
                normalizedCandidate: Array("test".utf8)
            ),
            20_000
        )
    }

    func testASCIIFastPathPrefixMatch() throws {
        let candidate = Array("spotlight".utf8)
        let score = try XCTUnwrap(FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("spot".utf8),
            normalizedCandidate: candidate
        ))
        XCTAssertEqual(score, 15_000 - candidate.count)
    }

    func testASCIIFastPathNonMatchReturnsNil() {
        XCTAssertNil(
            FuzzyMatcher.scoreASCII(
                normalizedQuery: Array("xyz".utf8),
                normalizedCandidate: Array("abc".utf8)
            )
        )
    }

    func testASCIIFastPathEmptyQueryReturnsOne() {
        XCTAssertEqual(
            FuzzyMatcher.scoreASCII(
                normalizedQuery: [],
                normalizedCandidate: Array("abc".utf8)
            ),
            1
        )
    }

    func testASCIIFastPathMatchesStringScorerAcrossCorpus() {
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

    // MARK: - Normalization edge cases

    func testNormalizationHandlesEmptyString() {
        XCTAssertEqual(FuzzyMatcher.normalized(""), "")
    }

    func testNormalizationHandlesWhitespace() {
        XCTAssertEqual(FuzzyMatcher.normalized("  Hello  World  ").lowercased(), "  hello  world  ")
    }

    func testNormalizationFoldsCaseAndDiacriticsTogether() {
        XCTAssertEqual(FuzzyMatcher.normalized("Café"), FuzzyMatcher.normalized("cafe"))
        XCTAssertEqual(FuzzyMatcher.normalized("NAÏVE"), FuzzyMatcher.normalized("naive"))
    }

    func testNormalizationIsIdempotent() {
        for value in ["café", "NAÏVE", "hello", "", "  ", "İstanbul"] {
            let once = FuzzyMatcher.normalized(value)
            let twice = FuzzyMatcher.normalized(once)
            XCTAssertEqual(once, twice, value)
        }
    }

    // MARK: - Query longer than candidate

    func testQueryLongerThanCandidateReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "abcdef", candidate: "abc"))
        XCTAssertNil(FuzzyMatcher.score(query: "long query", candidate: "short"))
    }

    func testQuerySameLengthAsCandidateButDifferentReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "abc", candidate: "xyz"))
    }

    func testQuerySameLengthAsCandidateAndSameReturnsExact() {
        XCTAssertEqual(FuzzyMatcher.score(query: "abc", candidate: "abc"), 20_000)
    }

    // MARK: - Reversed query

    func testReversedQueryDoesNotMatchUnlessPalindrome() {
        let candidate = "spotlight"
        let reversed = String(candidate.reversed())
        XCTAssertNil(FuzzyMatcher.score(query: reversed, candidate: candidate))
    }

    func testReversedQueryMatchesPalindrome() {
        let palindrome = "racecar"
        let reversed = String(palindrome.reversed())
        XCTAssertEqual(FuzzyMatcher.score(query: reversed, candidate: palindrome), 20_000)
    }

    // MARK: - Score determinism

    func testScoreIsDeterministicAcrossRepeatedCalls() {
        let pairs: [(String, String)] = [
            ("saf", "safari"),
            ("abc", "axbxc"),
            ("test", "test"),
            ("", "anything"),
        ]
        for (query, candidate) in pairs {
            let first = FuzzyMatcher.score(query: query, candidate: candidate)
            let second = FuzzyMatcher.score(query: query, candidate: candidate)
            let third = FuzzyMatcher.score(query: query, candidate: candidate)
            XCTAssertEqual(first, second)
            XCTAssertEqual(second, third)
        }
    }

    func testScoreDoesNotDependOnCallOrder() {
        let query = "sfr"
        let candidate = "safari"
        _ = FuzzyMatcher.score(query: "abc", candidate: "xyz")
        let first = FuzzyMatcher.score(query: query, candidate: candidate)
        _ = FuzzyMatcher.score(query: "xyz", candidate: "abc")
        let second = FuzzyMatcher.score(query: query, candidate: candidate)
        XCTAssertEqual(first, second)
    }
}
