import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

/// `FuzzyMatcher` has two implementations of one algorithm: a `String`
/// scorer that handles any Unicode, and an ASCII byte scorer
/// (`SystemCatalog` takes the fast path for every setting whose text is
/// pure ASCII, which is nearly all of them). Two implementations of one
/// ranking is a standing invitation to drift, and drift here means the
/// settings list reorders itself depending on which path ran.
///
/// So the central test in this file is differential: for every ASCII input
/// the generators can produce, the two scorers must return *the same
/// number*, not merely the same ordering.
final class FuzzyMatcherDifferentialTests: XCTestCase {
    private let asciiQuery = Gen<String>.string(
        alphabet: Array("abcdefgh -_/."),
        length: 0...8
    )

    private let asciiCandidate = Gen<String>.string(
        alphabet: Array("abcdefgh -_/."),
        length: 0...24
    )

    /// The definition the scorer implements: greedy left-to-right
    /// subsequence matching over the candidate's characters.
    private func isSubsequence(_ query: String, of candidate: String) -> Bool {
        var index = query.startIndex
        for character in candidate where index < query.endIndex {
            if character == query[index] {
                query.formIndex(after: &index)
            }
        }
        return index == query.endIndex
    }

    // MARK: - The two scorers must agree exactly

    func testTheASCIIFastPathReturnsTheSameScoreAsTheStringScorer() throws {
        try checkProperty(
            "scoreASCII == score for ASCII inputs",
            asciiQuery,
            asciiCandidate,
            runs: 3_000
        ) { query, candidate in
            let reference = FuzzyMatcher.score(
                normalizedQuery: query,
                normalizedCandidate: candidate
            )
            let fast = FuzzyMatcher.scoreASCII(
                normalizedQuery: Array(query.utf8),
                normalizedCandidate: Array(candidate.utf8)
            )
            return reference == fast
        }
    }

    func testTheTwoScorersAgreeOnDigitsAndPunctuationToo() throws {
        let alphabet = Array("abz019 -_/.+()[]")
        try checkProperty(
            "scoreASCII == score across a wider ASCII alphabet",
            Gen<String>.string(alphabet: alphabet, length: 0...6),
            Gen<String>.string(alphabet: alphabet, length: 0...20),
            runs: 2_000
        ) { query, candidate in
            FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
                == FuzzyMatcher.scoreASCII(
                    normalizedQuery: Array(query.utf8),
                    normalizedCandidate: Array(candidate.utf8)
                )
        }
    }

    func testTheTwoScorersAgreeOnTheRealSettingsVocabulary() {
        // The exact strings `SystemCatalog` scores in production, so the
        // agreement is checked on the data that actually flows through the
        // fast path rather than only on synthetic alphabets.
        let candidates = [
            "accessibility voiceover zoom display motor hearing",
            "appearance light dark accent color sidebar icon size",
            "bluetooth devices headphones keyboard mouse",
            "displays monitor resolution brightness night shift",
            "general about software update storage airdrop handoff login items",
            "privacy & security location camera microphone full disk access",
            "wi-fi wifi wireless network hotspot",
        ]
        let queries = [
            "", "a", "wi", "wifi", "wi-fi", "display", "displays", "acc", "access",
            "full disk", "login", "night", "zoom", "xyz", "  ", "wifiwifi",
        ]

        for candidate in candidates {
            for query in queries {
                let reference = FuzzyMatcher.score(
                    normalizedQuery: query,
                    normalizedCandidate: candidate
                )
                let fast = FuzzyMatcher.scoreASCII(
                    normalizedQuery: Array(query.utf8),
                    normalizedCandidate: Array(candidate.utf8)
                )
                XCTAssertEqual(reference, fast, "\(query) vs \(candidate)")
            }
        }
    }

    // MARK: - What a score means

    func testAScoreExistsExactlyWhenTheQueryIsASubsequence() throws {
        // The single defining property of the matcher: no score means "the
        // characters aren't there, in order", and nothing else.
        try checkProperty(
            "score != nil iff query is a subsequence of candidate",
            asciiQuery,
            asciiCandidate,
            runs: 2_000
        ) { query, candidate in
            let scored = FuzzyMatcher.score(
                normalizedQuery: query,
                normalizedCandidate: candidate
            ) != nil
            return scored == self.isSubsequence(query, of: candidate)
        }
    }

    func testAnEmptyQueryAlwaysScoresOne() throws {
        try checkProperty(
            "an empty query is the recent-items sentinel",
            Gen<String>.hostile,
            runs: 300
        ) { candidate in
            FuzzyMatcher.score(normalizedQuery: "", normalizedCandidate: candidate) == 1
                && FuzzyMatcher.scoreASCII(
                    normalizedQuery: [],
                    normalizedCandidate: Array(candidate.utf8)
                ) == 1
        }
    }

    func testAnEmptyCandidateOnlyMatchesAnEmptyQuery() throws {
        try checkProperty(
            "nothing but the empty query matches an empty candidate",
            asciiQuery,
            runs: 300
        ) { query in
            let score = FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: "")
            return query.isEmpty ? score == 1 : score == nil
        }
    }

    func testIdenticalStringsAlwaysScoreTheExactMatchCeiling() throws {
        try checkProperty(
            "candidate == query scores 20_000",
            asciiCandidate.filter { !$0.isEmpty },
            runs: 400
        ) { value in
            FuzzyMatcher.score(normalizedQuery: value, normalizedCandidate: value) == 20_000
        }
    }

    func testScoringIsDeterministic() throws {
        try checkProperty(
            "the same inputs always produce the same score",
            asciiQuery,
            asciiCandidate,
            runs: 500
        ) { query, candidate in
            FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
                == FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
        }
    }

    // MARK: - Band ordering

    func testMatchQualityBandsAreOrderedForRealisticLengths() throws {
        // Exact beats prefix beats substring beats subsequence — the whole
        // reason the scorer returns wide, separated constants.
        try checkProperty(
            "exact > prefix > substring > subsequence",
            Gen<String>.string(alphabet: Array("abcdef"), length: 2...5),
            runs: 400
        ) { core in
            let exact = FuzzyMatcher.score(normalizedQuery: core, normalizedCandidate: core)
            let prefix = FuzzyMatcher.score(
                normalizedQuery: core,
                normalizedCandidate: core + "zzz"
            )
            let substring = FuzzyMatcher.score(
                normalizedQuery: core,
                normalizedCandidate: "zzz" + core
            )
            let scattered = FuzzyMatcher.score(
                normalizedQuery: core,
                normalizedCandidate: core.map { "\($0)z" }.joined()
            )
            guard let exact, let prefix, let substring, let scattered else { return false }
            return exact > prefix && prefix > substring && substring > scattered
        }
    }

    func testAPrefixMatchScoresByCandidateLength() throws {
        // Padding starts at 1: with none, the candidate *equals* the query
        // and takes the exact-match branch instead.
        try checkProperty(
            "a prefix hit is 15_000 minus the candidate's length",
            Gen<Int>.int(in: 1...400),
            runs: 200
        ) { padding in
            let candidate = "wifi" + String(repeating: "x", count: padding)
            return FuzzyMatcher.score(normalizedQuery: "wifi", normalizedCandidate: candidate)
                == 15_000 - candidate.count
        }
    }

    func testASubstringMatchScoresByItsOffset() throws {
        try checkProperty(
            "a substring hit is 12_000 minus its offset",
            Gen<Int>.int(in: 1...200),
            runs: 200
        ) { offset in
            let candidate = String(repeating: "x", count: offset) + "wifi"
            return FuzzyMatcher.score(normalizedQuery: "wifi", normalizedCandidate: candidate)
                == 12_000 - offset
        }
    }

    func testWordBoundariesEarnABonusOverMidWordMatches() {
        // "fd" against "full disk" hits two word starts; against "affiliated"
        // it hits none. The boundary bonus is what makes the first rank
        // higher, which is what makes typing initials work at all.
        let boundary = FuzzyMatcher.score(
            normalizedQuery: "fd",
            normalizedCandidate: "full disk access"
        )
        let midWord = FuzzyMatcher.score(
            normalizedQuery: "fd",
            normalizedCandidate: "affiliated"
        )
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary ?? 0, midWord ?? 0)

        for separator in [" ", "-", "_", "/", "."] {
            let separated = FuzzyMatcher.score(
                normalizedQuery: "ab",
                normalizedCandidate: "a\(separator)b"
            )
            let joined = FuzzyMatcher.score(
                normalizedQuery: "ab",
                normalizedCandidate: "azb"
            )
            XCTAssertGreaterThan(
                separated ?? 0,
                joined ?? 0,
                "'\(separator)' should count as a word boundary"
            )
        }
    }

    func testConsecutiveRunsBeatScatteredCharacters() throws {
        try checkProperty(
            "a contiguous run outscores the same characters spread out",
            Gen<String>.string(alphabet: Array("abcdef"), length: 3...5),
            runs: 300
        ) { core in
            let contiguous = FuzzyMatcher.score(
                normalizedQuery: core,
                normalizedCandidate: "zzz" + core + "zzz"
            )
            let scattered = FuzzyMatcher.score(
                normalizedQuery: core,
                normalizedCandidate: "zzz" + core.map { "\($0)z" }.joined()
            )
            guard let contiguous, let scattered else { return false }
            return contiguous > scattered
        }
    }

    // MARK: - The confidence threshold

    func testTheConfidenceThresholdSitsAboveTheSubsequenceFloor() {
        // Subsequence scoring starts at 8_000 and the threshold is 9_000,
        // so a bare "the letters happen to appear in order" match is never
        // confident on its own — which is what stops "arc" from matching
        // "Accessibility" in the settings list.
        XCTAssertEqual(FuzzyMatcher.confidentMatchThreshold, 9_000)

        // A genuine but loose subsequence of a real settings candidate:
        // "aiy" appears in "accessibility …", spread across the word.
        let loose = FuzzyMatcher.score(
            normalizedQuery: "aiy",
            normalizedCandidate: "accessibility voiceover zoom display motor hearing"
        )
        XCTAssertNotNil(loose, "the characters do appear in order")
        XCTAssertLessThan(
            loose ?? .max,
            FuzzyMatcher.confidentMatchThreshold,
            "a loose subsequence must not clear the confidence bar"
        )

        // The synthetic worst case: three characters scattered across a
        // long candidate, matching in order and nothing else.
        let scattered = FuzzyMatcher.score(
            normalizedQuery: "abc",
            normalizedCandidate: "axxxxxxxxxbxxxxxxxxxc"
        )
        XCTAssertNotNil(scattered)
        XCTAssertLessThan(scattered ?? .max, FuzzyMatcher.confidentMatchThreshold)

        // "arc" is rejected for a different reason worth separating: it is
        // not a subsequence of that candidate at all, so it never even
        // reaches the threshold check.
        XCTAssertNil(
            FuzzyMatcher.score(
                normalizedQuery: "arc",
                normalizedCandidate: "accessibility voiceover zoom display motor hearing"
            )
        )
    }

    func testAVeryLongCandidateCanPushAGenuinePrefixMatchBelowConfidence() throws {
        // Sharp edge, pinned deliberately: a prefix hit scores
        // `15_000 - candidate.count`, so once a candidate passes ~6_000
        // characters even an exact prefix match drops under the confidence
        // threshold and disappears from the settings list. Nothing in the
        // shipping catalogue is near that, but the arithmetic is worth
        // stating out loud.
        let shortCandidate = "wifi" + String(repeating: "x", count: 1_000)
        XCTAssertGreaterThan(
            try XCTUnwrap(
                FuzzyMatcher.score(normalizedQuery: "wifi", normalizedCandidate: shortCandidate)
            ),
            FuzzyMatcher.confidentMatchThreshold
        )

        let hugeCandidate = "wifi" + String(repeating: "x", count: 6_000)
        XCTAssertLessThan(
            try XCTUnwrap(
                FuzzyMatcher.score(normalizedQuery: "wifi", normalizedCandidate: hugeCandidate)
            ),
            FuzzyMatcher.confidentMatchThreshold
        )

        // And past 15_000 characters the score turns negative outright.
        let absurdCandidate = "wifi" + String(repeating: "x", count: 20_000)
        XCTAssertLessThan(
            try XCTUnwrap(
                FuzzyMatcher.score(normalizedQuery: "wifi", normalizedCandidate: absurdCandidate)
            ),
            0
        )
    }

    // MARK: - Normalization

    func testNormalizationFoldsCaseAndDiacritics() throws {
        try checkProperty(
            "normalization is case- and diacritic-insensitive",
            Gen<String>.element(of: [
                "Café", "CAFÉ", "cafe\u{0301}", "café", "CAFE",
            ]),
            runs: 100
        ) { value in
            FuzzyMatcher.normalized(value) == "cafe"
        }
    }

    func testNormalizationIsIdempotentForRealText() throws {
        // Real text — anything with actual base characters — folds to a
        // fixed point in one pass. Degenerate sequences of *bare* combining
        // marks do not; that case is pinned separately below.
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
            "normalizing twice equals normalizing once for real text",
            realisticText,
            runs: 800
        ) { value in
            let once = FuzzyMatcher.normalized(value)
            return FuzzyMatcher.normalized(once) == once
        }
    }

    func testNormalizationIsNotIdempotentForBareCombiningMarks() {
        // Found by the property above before it was narrowed. A string of
        // combining marks with no base character folds differently on the
        // second pass, because each pass re-composes what the previous one
        // left behind.
        //
        // It cannot bite in practice — `normalized` is applied exactly once
        // to each side before scoring, never to its own output — but the
        // function is not the fixed-point operation its name suggests, and
        // that is worth stating.
        // Rather than pin one fragile literal, enumerate the invisible /
        // combining scalars that reach the matcher through file names and
        // assert that at least one arrangement is non-idempotent. If that
        // ever stops being true, folding became a fixed-point operation and
        // the property above can widen to cover everything.
        let scalars = [
            "\u{200B}",
            "\u{200D}",
            "\u{FEFF}",
            "\u{202E}",
            "\u{0301}",
            "\u{0328}",
            "\u{00A0}",
            "\u{2028}",
            " ",
        ]
        var offenders: [String] = []
        for first in scalars {
            for second in scalars {
                for third in scalars {
                    let value = first + second + third
                    let once = FuzzyMatcher.normalized(value)
                    if FuzzyMatcher.normalized(once) != once {
                        offenders.append(value.unicodeScalars.map {
                            String(format: "U+%04X", $0.value)
                        }.joined(separator: " "))
                    }
                }
            }
        }

        XCTAssertFalse(
            offenders.isEmpty,
            "normalization now looks idempotent; widen testNormalizationIsIdempotentForRealText"
        )

        // The scorer stays self-consistent regardless, which is what
        // actually matters: one normalization pass per side, compared once.
        for offender in [" \u{0328}\u{0301}", "\u{00A0}\u{0301}"] {
            XCTAssertEqual(
                FuzzyMatcher.score(query: offender, candidate: offender),
                20_000,
                "a value must always match itself, idempotent folding or not"
            )
        }
    }

    func testTheConvenienceScorerNormalizesBothSides() {
        // The two-argument form is what callers outside the hot path use;
        // it must fold before scoring, or "Café" would not match "cafe".
        XCTAssertEqual(FuzzyMatcher.score(query: "CAFÉ", candidate: "cafe"), 20_000)
        XCTAssertEqual(FuzzyMatcher.score(query: "café", candidate: "CAFE"), 20_000)
        XCTAssertEqual(FuzzyMatcher.score(query: "WIFI", candidate: "wifi settings"), 15_000 - 13)
    }

    func testNormalizationNeverTrapsOnHostileInput() throws {
        try checkProperty(
            "normalized() is total",
            Gen<String>.hostile,
            runs: 800
        ) { value in
            _ = FuzzyMatcher.normalized(value)
            return true
        }
    }

    func testScoringNeverTrapsOnHostileUnicode() throws {
        // Emoji, combining marks, and RTL overrides all reach the String
        // scorer through file names. It must return a number or nil for
        // every one of them, never trap on an index.
        try checkProperty(
            "the String scorer is total over Unicode",
            Gen<String>.hostile,
            Gen<String>.hostile,
            runs: 1_500
        ) { query, candidate in
            let normalizedQuery = FuzzyMatcher.normalized(query)
            let normalizedCandidate = FuzzyMatcher.normalized(candidate)
            _ = FuzzyMatcher.score(
                normalizedQuery: normalizedQuery,
                normalizedCandidate: normalizedCandidate
            )
            return true
        }
    }

    func testMultiScalarGraphemesAreScoredAsSingleCharacters() {
        // A flag or a family emoji is one `Character` but several scalars.
        // The String scorer walks `Character`s, so an emoji query must
        // match its own emoji exactly rather than half of it.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(
            FuzzyMatcher.score(normalizedQuery: family, normalizedCandidate: family),
            20_000
        )
        XCTAssertNotNil(
            FuzzyMatcher.score(
                normalizedQuery: family,
                normalizedCandidate: "photo of \(family) at home"
            )
        )
        XCTAssertNil(
            FuzzyMatcher.score(normalizedQuery: family, normalizedCandidate: "👨"),
            "a single scalar must not satisfy a whole-cluster query"
        )
    }

    // MARK: - Scale

    func testScoringALongCandidateStaysFastEnoughForEveryKeystroke() {
        // The settings catalogue is scored on every keystroke. A quadratic
        // blowup here would be felt immediately, so the budget is asserted
        // rather than assumed.
        let candidate = String(repeating: "system settings network wifi ", count: 400)
        let query = "wifi"
        let start = ContinuousClock.now
        for _ in 0..<200 {
            _ = FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
        }
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testTheASCIIPathHandlesAWorstCaseSubsequenceScanWithoutBlowingUp() {
        // The pathological shape for the substring pre-scan: a query that
        // almost matches everywhere and only fully matches at the end.
        let candidate = Array(String(repeating: "a", count: 20_000).utf8) + Array("b".utf8)
        let query = Array(String(repeating: "a", count: 100).utf8) + Array("b".utf8)

        let start = ContinuousClock.now
        let score = FuzzyMatcher.scoreASCII(
            normalizedQuery: query,
            normalizedCandidate: candidate
        )
        let elapsed = start.duration(to: .now)

        XCTAssertNotNil(score)
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testScoringSurvivesConcurrentUseFromManyThreads() {
        // Both scorers are pure statics, but `normalized` reaches into
        // `Locale.current`. Hammering it from many threads is how a hidden
        // shared cache would show up.
        let results = ConcurrentBag<Int?>()
        hammerConcurrently(concurrency: 12, iterations: 300) { _, _ in
            results.append(
                FuzzyMatcher.score(query: "WiFi", candidate: "Wi-Fi wireless network hotspot")
            )
        }
        let distinct = Set(results.values.map { $0 ?? -1 })
        XCTAssertEqual(distinct.count, 1, "concurrent scoring produced different answers")
    }
}
