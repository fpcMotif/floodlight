import XCTest
@testable import FloodlightEngine

final class FuzzyMatcherTests: XCTestCase {
    // MARK: - 1. Exact Match

    func testExactMatchProducesExactEvidenceAndScore() throws {
        let evidence = try XCTUnwrap(match(query: "safari", candidate: "Safari"))
        XCTAssertEqual(evidence.shape, .exact)
        XCTAssertEqual(evidence.score, 20_000)
    }

    // MARK: - 2. Name Prefix

    func testNamePrefixProducesNamePrefixEvidenceAndScore() throws {
        let candidate = "Safari"
        let evidence = try XCTUnwrap(match(query: "saf", candidate: candidate))
        XCTAssertEqual(evidence.shape, .namePrefix)
        XCTAssertEqual(evidence.score, 15_000 - candidate.count)
    }

    // MARK: - 3. Word Prefix

    func testWordPrefixMatchesMiddleWordAndScoresByOffset() throws {
        let candidate = "Google Chrome"
        let evidence = try XCTUnwrap(match(query: "chrome", candidate: candidate))
        XCTAssertEqual(evidence.shape, .wordPrefix(offset: 7))
        XCTAssertEqual(evidence.score, 12_000 - 7)
    }

    func testWordPrefixAfterPunctuationBoundary() throws {
        let candidate = "wi-fi network"
        let evidence = try XCTUnwrap(match(query: "fi", candidate: candidate))
        XCTAssertEqual(evidence.shape, .wordPrefix(offset: 3))
        XCTAssertEqual(evidence.score, 12_000 - 3)
    }

    // MARK: - 4. Acronym

    func testAcronymMatchesInitialsAtStart() throws {
        let candidate = "Google Chrome"
        let evidence = try XCTUnwrap(match(query: "gc", candidate: candidate))
        XCTAssertEqual(evidence.shape, .acronym(offset: 0))
        XCTAssertEqual(evidence.score, 10_000)
    }

    func testAcronymMatchesThreeWordInitials() throws {
        let candidate = "Visual Studio Code"
        let evidence = try XCTUnwrap(match(query: "vsc", candidate: candidate))
        XCTAssertEqual(evidence.shape, .acronym(offset: 0))
        XCTAssertEqual(evidence.score, 10_000)
    }

    func testAcronymMatchesSubsequenceOfInitialsWithOffset() throws {
        let candidate = "Visual Studio Code"
        let evidence = try XCTUnwrap(match(query: "sc", candidate: candidate))
        XCTAssertEqual(evidence.shape, .acronym(offset: 1))
        XCTAssertEqual(evidence.score, 10_000 - 1)
    }

    // MARK: - 5. Typos (Damerau-Levenshtein)

    func testTypoToleranceRejectsTwoLetterQueries() {
        // Two-letter queries get 0 edit budget: precision over recall
        XCTAssertNil(match(query: "gh", candidate: "Grapher"))
        XCTAssertNil(match(query: "gh", candidate: "Google Chrome"))
        XCTAssertNil(match(query: "gh", candidate: "Zed Nightly"))
        XCTAssertNil(match(query: "go", candidate: "Ghostty"))

        // But exact / prefix on 2 letters still matches
        let ghosttyEvidence = match(query: "gh", candidate: "Ghostty")
        XCTAssertEqual(ghosttyEvidence?.shape, .namePrefix)
    }

    func testTypoToleranceAllowsOneEditForThreeToFiveCharacters() throws {
        // Transposition (1 edit in Damerau-Levenshtein)
        let raycast = try XCTUnwrap(match(query: "ryacast", candidate: "Raycast"))
        XCTAssertEqual(raycast.shape, .typo(edits: 1, offset: 0))
        XCTAssertEqual(raycast.score, 9_000 - 1_000)

        // Missing letter in 3-5 char query (1 edit)
        let safari = try XCTUnwrap(match(query: "safri", candidate: "Safari"))
        XCTAssertEqual(safari.shape, .typo(edits: 1, offset: 0))
        XCTAssertEqual(safari.score, 9_000 - 1_000)

        let finder = try XCTUnwrap(match(query: "fnder", candidate: "Finder"))
        XCTAssertEqual(finder.shape, .typo(edits: 1, offset: 0))
        XCTAssertEqual(finder.score, 9_000 - 1_000)

        // Extra letter in 3-5 char query (1 edit)
        let ghostty = try XCTUnwrap(match(query: "ghosty", candidate: "Ghostty"))
        XCTAssertEqual(ghostty.shape, .typo(edits: 1, offset: 0))
        XCTAssertEqual(ghostty.score, 9_000 - 1_000)
    }

    func testTypoToleranceAllowsTwoEditsForSixOrMoreCharacters() throws {
        // 2 edits on 6+ character query
        let raycast = try XCTUnwrap(match(query: "raaycst", candidate: "Raycast"))
        XCTAssertEqual(raycast.shape, .typo(edits: 2, offset: 0))
        XCTAssertEqual(raycast.score, 9_000 - 2_000)
    }

    func testTypoToleranceRejectsMoreEditsThanBudget() {
        // 3-5 char query with 2 edits -> rejected (budget is 1)
        XCTAssertNil(match(query: "sfri", candidate: "Safari")) // 2 deletions: 'a', 'a'
        // 6+ char query with 3 edits -> rejected (budget is 2)
        XCTAssertNil(match(query: "rcst", candidate: "Raycast")) // 3 deletions: 'a', 'y', 'a'
    }

    func testTypoToleranceAnchorsFirstCharacter() {
        // First letter mismatch is rejected even within edit budget
        XCTAssertNil(match(query: "chrome", candidate: "Home"))
        XCTAssertNil(match(query: "afari", candidate: "Safari"))
    }

    func testTypoMatchesAgainstIndividualWordsInCandidate() throws {
        // 'gogle' matches 'Google' in 'Google Chrome'
        let google = try XCTUnwrap(match(query: "gogle", candidate: "Google Chrome"))
        XCTAssertEqual(google.shape, .typo(edits: 1, offset: 0))
        XCTAssertEqual(google.score, 9_000 - 1_000)

        // 'chrom' (prefix) vs 'chrme' (typo) in 'Google Chrome'
        let chromeTypo = try XCTUnwrap(match(query: "chrme", candidate: "Google Chrome"))
        XCTAssertEqual(chromeTypo.shape, .typo(edits: 1, offset: 7))
        XCTAssertEqual(chromeTypo.score, 9_000 - 1_000 - 7)
    }

    // MARK: - Ranking Order Between Shapes

    func testStructuralShapesStrictlyOutrankTypoMatches() throws {
        let exact = try XCTUnwrap(match(query: "safari", candidate: "Safari")?.score)
        let prefix = try XCTUnwrap(match(query: "saf", candidate: "Safari")?.score)
        let wordPrefix = try XCTUnwrap(match(query: "chrome", candidate: "Google Chrome")?.score)
        let acronym = try XCTUnwrap(match(query: "gc", candidate: "Google Chrome")?.score)
        let typo = try XCTUnwrap(match(query: "safri", candidate: "Safari")?.score)

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, wordPrefix)
        XCTAssertGreaterThan(wordPrefix, acronym)
        XCTAssertGreaterThan(acronym, typo)
    }

    // MARK: - Unicode / Diacritics

    func testDiacriticsAndCaseAreNormalized() throws {
        let match = try XCTUnwrap(match(query: "unicode", candidate: "Ünïcodé-café.jpg"))
        XCTAssertEqual(match.shape, .namePrefix)
    }

    // MARK: - ASCII Fast Path Equivalence

    func testASCIIFastPathMatchesUnicodePath() {
        let queries = [
            "", "a", "gh", "gc", "vsc", "saf", "safari", "safri", "chrome", "chrme",
            "ryacast", "gogle", "login", "wifi", "bluetooth", "zzz",
        ]
        let candidates = [
            "Safari",
            "Ghostty",
            "Grapher",
            "Google Chrome",
            "Visual Studio Code",
            "Raycast",
            "Login Items & Extensions",
            "Wi-Fi",
            "Bluetooth",
            "appearance light dark",
            "users_groups/password",
        ]

        for query in queries {
            let normQ = FuzzyMatcher.normalized(query)
            let queryBytes = Array(normQ.utf8)
            for candidate in candidates {
                let normC = FuzzyMatcher.normalized(candidate)
                let candBytes = Array(normC.utf8)

                let unicodeEvidence = FuzzyMatcher.match(
                    normalizedQuery: normQ,
                    normalizedCandidate: normC
                )
                let asciiEvidence = FuzzyMatcher.matchASCII(
                    normalizedQuery: queryBytes,
                    normalizedCandidate: candBytes
                )

                XCTAssertEqual(
                    unicodeEvidence,
                    asciiEvidence,
                    "Mismatch for query '\(query)' in candidate '\(candidate)'"
                )

                let unicodeScore = FuzzyMatcher.score(
                    normalizedQuery: normQ,
                    normalizedCandidate: normC
                )
                let asciiScore = FuzzyMatcher.scoreASCII(
                    normalizedQuery: queryBytes,
                    normalizedCandidate: candBytes
                )

                XCTAssertEqual(
                    unicodeScore,
                    asciiScore,
                    "Score mismatch for query '\(query)' in candidate '\(candidate)'"
                )
            }
        }
    }

    // MARK: - Helpers

    private func match(query: String, candidate: String) -> FuzzyMatcher.MatchEvidence? {
        FuzzyMatcher.match(
            normalizedQuery: FuzzyMatcher.normalized(query),
            normalizedCandidate: FuzzyMatcher.normalized(candidate)
        )
    }

    private func score(query: String, candidate: String) -> Int? {
        FuzzyMatcher.score(
            normalizedQuery: FuzzyMatcher.normalized(query),
            normalizedCandidate: FuzzyMatcher.normalized(candidate)
        )
    }
}
