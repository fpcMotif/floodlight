import Foundation
import XCTest
@testable import FloodlightEngine

/// Stress tests for the fuzzy matcher: single-character queries, very long
/// strings, all-same-character candidates, and the boundary/consecutive
/// scoring paths that the property tests only sample.
final class FuzzyMatcherStressTests: XCTestCase {
    // MARK: - Single-character queries

    func testSingleCharacterQueryMatchesWordStarts() {
        let candidate = "the quick brown fox jumps over the lazy dog"
        for char in ["t", "q", "b", "f", "j", "o", "l", "d"] {
            let query = String(char)
            XCTAssertNotNil(
                FuzzyMatcher.score(query: query, candidate: candidate),
                "char '\(char)' should match word start"
            )
        }
    }

    func testSingleCharacterQueryReturnsNilIfAbsent() {
        XCTAssertNil(FuzzyMatcher.score(query: "z", candidate: "aaaaaaa"))
        XCTAssertNil(FuzzyMatcher.score(query: "q", candidate: "bcdef"))
    }

    func testSingleCharacterAtStartScoresHigherThanLaterWord() throws {
        let atStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let inLaterWord = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "foo bar abc"))
        XCTAssertGreaterThan(atStart, inLaterWord)
    }

    func testACharacterAfterASeparatorMatchesAsWordPrefix() throws {
        let afterSep = try XCTUnwrap(FuzzyMatcher.score(query: "b", candidate: "a-b"))
        XCTAssertEqual(afterSep, 12_000 - 2)
    }

    // MARK: - Very long strings

    func testVeryLongCandidateWithMatchAtEnd() {
        let prefix = String(repeating: "x ", count: 5_000)
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

    func testScatteredCharactersDoNotMatch() {
        let candidate = "a x a x a x a x a"
        XCTAssertNil(FuzzyMatcher.score(query: "aaaaa", candidate: candidate))
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
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        XCTAssertEqual(afterHyphen, 10_000)
        XCTAssertNil(noBoundary, "scattered letters without a boundary must not match")
    }

    func testUnderscoreIsABoundary() throws {
        let afterUnderscore = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a_b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        XCTAssertEqual(afterUnderscore, 10_000)
        XCTAssertNil(noBoundary)
    }

    func testSlashIsABoundary() throws {
        let afterSlash = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a/b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        XCTAssertEqual(afterSlash, 10_000)
        XCTAssertNil(noBoundary)
    }

    func testDotIsABoundary() throws {
        let afterDot = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a.b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        XCTAssertEqual(afterDot, 10_000)
        XCTAssertNil(noBoundary)
    }

    func testSpaceIsABoundary() throws {
        let afterSpace = try XCTUnwrap(FuzzyMatcher.score(query: "ab", candidate: "a b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        XCTAssertEqual(afterSpace, 10_000)
        XCTAssertNil(noBoundary)
    }

    func testStartOfStringScoresHigherThanLaterWord() throws {
        let atStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let notAtStart = try XCTUnwrap(FuzzyMatcher.score(query: "a", candidate: "x abc"))
        XCTAssertGreaterThan(atStart, notAtStart)
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

    func testWordPrefixMatchScoreIs12000MinusStart() throws {
        let candidate = "spot light"
        let query = "light"
        let score = try XCTUnwrap(FuzzyMatcher.score(query: query, candidate: candidate))
        XCTAssertEqual(score, 12_000 - 5)
    }

    func testAcronymMatchScoreIs10000MinusOffset() throws {
        let candidate = "spot light"
        let score = try XCTUnwrap(FuzzyMatcher.score(query: "sl", candidate: candidate))
        XCTAssertEqual(score, 10_000)
    }

    func testExactBeatsPrefixBeatsWordPrefixBeatsAcronymBeatsTypo() throws {
        let candidate = "Google Chrome"
        let exact = try XCTUnwrap(FuzzyMatcher.score(query: "google chrome", candidate: candidate))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "google", candidate: candidate))
        let wordPrefix = try XCTUnwrap(FuzzyMatcher.score(query: "chrome", candidate: candidate))
        let acronym = try XCTUnwrap(FuzzyMatcher.score(query: "gc", candidate: candidate))
        let typo = try XCTUnwrap(FuzzyMatcher.score(query: "gogle", candidate: candidate))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, wordPrefix)
        XCTAssertGreaterThan(wordPrefix, acronym)
        XCTAssertGreaterThan(acronym, typo)
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
