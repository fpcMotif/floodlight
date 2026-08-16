import Foundation
import Testing
@testable import FloodlightEngine

/// Stress tests for the fuzzy matcher: single-character queries, very long
/// strings, all-same-character candidates, and the boundary/consecutive
/// scoring paths that the property tests only sample.
struct FuzzyMatcherStressTests {
    // MARK: - Single-character queries

    @Test func singleCharacterQueryMatchesWordStarts() {
        let candidate = "the quick brown fox jumps over the lazy dog"
        for char in ["t", "q", "b", "f", "j", "o", "l", "d"] {
            let query = String(char)
            #expect(
                FuzzyMatcher.score(query: query, candidate: candidate) != nil,
                "char '\(char)' should match word start"
            )
        }
    }

    @Test func singleCharacterQueryReturnsNilIfAbsent() {
        #expect(FuzzyMatcher.score(query: "z", candidate: "aaaaaaa") == nil)
        #expect(FuzzyMatcher.score(query: "q", candidate: "bcdef") == nil)
    }

    @Test func singleCharacterAtStartScoresHigherThanLaterWord() throws {
        let atStart = try #require(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let inLaterWord = try #require(FuzzyMatcher.score(query: "a", candidate: "foo bar abc"))
        #expect(atStart > inLaterWord)
    }

    @Test func aCharacterAfterASeparatorMatchesAsWordPrefix() throws {
        let afterSep = try #require(FuzzyMatcher.score(query: "b", candidate: "a-b"))
        #expect(afterSep == 12_000 - 2)
    }

    // MARK: - Very long strings

    @Test func veryLongCandidateWithMatchAtEnd() {
        let prefix = String(repeating: "x ", count: 5_000)
        let candidate = prefix + "target"
        #expect(FuzzyMatcher.score(query: "target", candidate: candidate) != nil)
    }

    @Test func veryLongQueryLongerThanCandidateReturnsNil() {
        let query = String(repeating: "a", count: 1_000)
        let candidate = "aaa"
        #expect(FuzzyMatcher.score(query: query, candidate: candidate) == nil)
    }

    @Test func veryLongExactMatch() {
        let value = String(repeating: "ab", count: 5_000)
        #expect(FuzzyMatcher.score(query: value, candidate: value) == 20_000)
    }

    @Test func veryLongPrefixMatch() throws {
        let value = String(repeating: "ab", count: 5_000)
        let prefix = String(repeating: "ab", count: 100)
        let score = try #require(FuzzyMatcher.score(query: prefix, candidate: value))
        #expect(score == 15_000 - value.count)
    }

    // MARK: - All-same-character candidates

    @Test func allSameCharacterCandidateMatchesSingleChar() {
        let candidate = String(repeating: "a", count: 100)
        #expect(FuzzyMatcher.score(query: "a", candidate: candidate) != nil)
    }

    @Test func allSameCharacterCandidateMatchesRepeatedQuery() {
        let candidate = String(repeating: "a", count: 100)
        let query = String(repeating: "a", count: 50)
        #expect(FuzzyMatcher.score(query: query, candidate: candidate) != nil)
    }

    @Test func allSameCharacterCandidateRejectsDifferentChar() {
        let candidate = String(repeating: "a", count: 100)
        #expect(FuzzyMatcher.score(query: "b", candidate: candidate) == nil)
    }

    @Test func scatteredCharactersDoNotMatch() {
        let candidate = "a x a x a x a x a"
        #expect(FuzzyMatcher.score(query: "aaaaa", candidate: candidate) == nil)
    }

    // MARK: - Boundary detection

    /// The boundary bonus lives only in the *subsequence* branch. A
    /// single-character query against "x-a" takes the substring branch
    /// instead (12_000 minus the offset), where a separator only pushes the
    /// match further right and therefore scores it *lower*. These use
    /// two-character queries so the candidates are genuinely non-contiguous
    /// and the bonus is actually reachable.
    @Test func hyphenIsABoundary() throws {
        let afterHyphen = try #require(FuzzyMatcher.score(query: "ab", candidate: "a-b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        #expect(afterHyphen == 10_000)
        #expect(noBoundary == nil, "scattered letters without a boundary must not match")
    }

    @Test func underscoreIsABoundary() throws {
        let afterUnderscore = try #require(FuzzyMatcher.score(query: "ab", candidate: "a_b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        #expect(afterUnderscore == 10_000)
        #expect(noBoundary == nil)
    }

    @Test func slashIsABoundary() throws {
        let afterSlash = try #require(FuzzyMatcher.score(query: "ab", candidate: "a/b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        #expect(afterSlash == 10_000)
        #expect(noBoundary == nil)
    }

    @Test func dotIsABoundary() throws {
        let afterDot = try #require(FuzzyMatcher.score(query: "ab", candidate: "a.b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        #expect(afterDot == 10_000)
        #expect(noBoundary == nil)
    }

    @Test func spaceIsABoundary() throws {
        let afterSpace = try #require(FuzzyMatcher.score(query: "ab", candidate: "a b"))
        let noBoundary = FuzzyMatcher.score(query: "ab", candidate: "azb")
        #expect(afterSpace == 10_000)
        #expect(noBoundary == nil)
    }

    @Test func startOfStringScoresHigherThanLaterWord() throws {
        let atStart = try #require(FuzzyMatcher.score(query: "a", candidate: "abc"))
        let notAtStart = try #require(FuzzyMatcher.score(query: "a", candidate: "x abc"))
        #expect(atStart > notAtStart)
    }

    // MARK: - Score scale values

    @Test func exactMatchScoreIs20000() {
        #expect(FuzzyMatcher.score(query: "test", candidate: "test") == 20_000)
    }

    @Test func prefixMatchScoreIs15000MinusCount() throws {
        let candidate = "spotlight"
        let score = try #require(FuzzyMatcher.score(query: "spot", candidate: candidate))
        #expect(score == 15_000 - candidate.count)
    }

    @Test func wordPrefixMatchScoreIs12000MinusStart() throws {
        let candidate = "spot light"
        let query = "light"
        let score = try #require(FuzzyMatcher.score(query: query, candidate: candidate))
        #expect(score == 12_000 - 5)
    }

    @Test func acronymMatchScoreIs10000MinusOffset() throws {
        let candidate = "spot light"
        let score = try #require(FuzzyMatcher.score(query: "sl", candidate: candidate))
        #expect(score == 10_000)
    }

    @Test func exactBeatsPrefixBeatsWordPrefixBeatsAcronymBeatsTypo() throws {
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

    // MARK: - ASCII fast path

    @Test func aSCIIFastPathExactMatch() {
        #expect(FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("test".utf8),
            normalizedCandidate: Array("test".utf8)
        ) == 20_000)
    }

    @Test func aSCIIFastPathPrefixMatch() throws {
        let candidate = Array("spotlight".utf8)
        let score = try #require(FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("spot".utf8),
            normalizedCandidate: candidate
        ))
        #expect(score == 15_000 - candidate.count)
    }

    @Test func aSCIIFastPathNonMatchReturnsNil() {
        #expect(FuzzyMatcher.scoreASCII(
            normalizedQuery: Array("xyz".utf8),
            normalizedCandidate: Array("abc".utf8)
        ) == nil)
    }

    @Test func aSCIIFastPathEmptyQueryReturnsOne() {
        #expect(FuzzyMatcher.scoreASCII(
            normalizedQuery: [],
            normalizedCandidate: Array("abc".utf8)
        ) == 1)
    }

    @Test func aSCIIFastPathMatchesStringScorerAcrossCorpus() {
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

    // MARK: - Normalization edge cases

    @Test func normalizationHandlesEmptyString() {
        #expect(FuzzyMatcher.normalized("").isEmpty)
    }

    @Test func normalizationHandlesWhitespace() {
        #expect(FuzzyMatcher.normalized("  Hello  World  ").lowercased() == "  hello  world  ")
    }

    @Test func normalizationFoldsCaseAndDiacriticsTogether() {
        #expect(FuzzyMatcher.normalized("Café") == FuzzyMatcher.normalized("cafe"))
        #expect(FuzzyMatcher.normalized("NAÏVE") == FuzzyMatcher.normalized("naive"))
    }

    @Test func normalizationIsIdempotent() {
        for value in ["café", "NAÏVE", "hello", "", "  ", "İstanbul"] {
            let once = FuzzyMatcher.normalized(value)
            let twice = FuzzyMatcher.normalized(once)
            #expect(once == twice, "\(value)")
        }
    }

    // MARK: - Query longer than candidate

    @Test func queryLongerThanCandidateReturnsNil() {
        #expect(FuzzyMatcher.score(query: "abcdef", candidate: "abc") == nil)
        #expect(FuzzyMatcher.score(query: "long query", candidate: "short") == nil)
    }

    @Test func querySameLengthAsCandidateButDifferentReturnsNil() {
        #expect(FuzzyMatcher.score(query: "abc", candidate: "xyz") == nil)
    }

    @Test func querySameLengthAsCandidateAndSameReturnsExact() {
        #expect(FuzzyMatcher.score(query: "abc", candidate: "abc") == 20_000)
    }

    // MARK: - Reversed query

    @Test func reversedQueryDoesNotMatchUnlessPalindrome() {
        let candidate = "spotlight"
        let reversed = String(candidate.reversed())
        #expect(FuzzyMatcher.score(query: reversed, candidate: candidate) == nil)
    }

    @Test func reversedQueryMatchesPalindrome() {
        let palindrome = "racecar"
        let reversed = String(palindrome.reversed())
        #expect(FuzzyMatcher.score(query: reversed, candidate: palindrome) == 20_000)
    }

    // MARK: - Score determinism

    @Test func scoreIsDeterministicAcrossRepeatedCalls() {
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
            #expect(first == second)
            #expect(second == third)
        }
    }

    @Test func scoreDoesNotDependOnCallOrder() {
        let query = "sfr"
        let candidate = "safari"
        _ = FuzzyMatcher.score(query: "abc", candidate: "xyz")
        let first = FuzzyMatcher.score(query: query, candidate: candidate)
        _ = FuzzyMatcher.score(query: "xyz", candidate: "abc")
        let second = FuzzyMatcher.score(query: query, candidate: candidate)
        #expect(first == second)
    }
}
