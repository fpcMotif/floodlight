import Testing
@testable import FloodlightEngine

struct FuzzyMatcherTests {
    // MARK: - 1. Exact Match

    @Test func exactMatchProducesExactEvidenceAndScore() throws {
        let evidence = try #require(match(query: "safari", candidate: "Safari"))
        #expect(evidence.shape == .exact)
        #expect(evidence.score == 20_000)
    }

    // MARK: - 2. Name Prefix

    @Test func namePrefixProducesNamePrefixEvidenceAndScore() throws {
        let candidate = "Safari"
        let evidence = try #require(match(query: "saf", candidate: candidate))
        #expect(evidence.shape == .namePrefix)
        #expect(evidence.score == 15_000 - candidate.count)
    }

    // MARK: - 3. Word Prefix

    @Test func wordPrefixMatchesMiddleWordAndScoresByOffset() throws {
        let candidate = "Google Chrome"
        let evidence = try #require(match(query: "chrome", candidate: candidate))
        #expect(evidence.shape == .wordPrefix(offset: 7))
        #expect(evidence.score == 12_000 - 7)
    }

    @Test func wordPrefixAfterPunctuationBoundary() throws {
        let candidate = "wi-fi network"
        let evidence = try #require(match(query: "fi", candidate: candidate))
        #expect(evidence.shape == .wordPrefix(offset: 3))
        #expect(evidence.score == 12_000 - 3)
    }

    // MARK: - 4. Acronym

    @Test func acronymMatchesInitialsAtStart() throws {
        let candidate = "Google Chrome"
        let evidence = try #require(match(query: "gc", candidate: candidate))
        #expect(evidence.shape == .acronym(offset: 0))
        #expect(evidence.score == 10_000)
    }

    @Test func acronymMatchesThreeWordInitials() throws {
        let candidate = "Visual Studio Code"
        let evidence = try #require(match(query: "vsc", candidate: candidate))
        #expect(evidence.shape == .acronym(offset: 0))
        #expect(evidence.score == 10_000)
    }

    @Test func acronymMatchesSubsequenceOfInitialsWithOffset() throws {
        let candidate = "Visual Studio Code"
        let evidence = try #require(match(query: "sc", candidate: candidate))
        #expect(evidence.shape == .acronym(offset: 1))
        #expect(evidence.score == 10_000 - 1)
    }

    // MARK: - 5. Typos (Damerau-Levenshtein)

    @Test func typoToleranceRejectsTwoLetterQueries() {
        // Two-letter queries get 0 edit budget: precision over recall
        #expect(match(query: "gh", candidate: "Grapher") == nil)
        #expect(match(query: "gh", candidate: "Google Chrome") == nil)
        #expect(match(query: "gh", candidate: "Zed Nightly") == nil)
        #expect(match(query: "go", candidate: "Ghostty") == nil)

        // But exact / prefix on 2 letters still matches
        let ghosttyEvidence = match(query: "gh", candidate: "Ghostty")
        #expect(ghosttyEvidence?.shape == .namePrefix)
    }

    @Test func typoToleranceAllowsOneEditForThreeToFiveCharacters() throws {
        // Missing letter in 5-char query (1 edit)
        let safari = try #require(match(query: "safri", candidate: "Safari"))
        #expect(safari.shape == .typo(edits: 1, offset: 0))
        #expect(safari.score == 9_000 - 1_000)

        // Missing letter in 5-char query (1 edit)
        let finder = try #require(match(query: "fnder", candidate: "Finder"))
        #expect(finder.shape == .typo(edits: 1, offset: 0))
        #expect(finder.score == 9_000 - 1_000)

        // Missing letter in 5-char query (1 edit)
        let google = try #require(match(query: "gogle", candidate: "Google"))
        #expect(google.shape == .typo(edits: 1, offset: 0))
        #expect(google.score == 9_000 - 1_000)
    }

    @Test func typoToleranceAllowsUpToTwoEditsForSixOrMoreCharacters() throws {
        // 1 edit transposition on 7-char query
        let raycast = try #require(match(query: "ryacast", candidate: "Raycast"))
        #expect(raycast.shape == .typo(edits: 1, offset: 0))
        #expect(raycast.score == 9_000 - 1_000)

        // 1 edit deletion on 6-char query
        let ghostty = try #require(match(query: "ghosty", candidate: "Ghostty"))
        #expect(ghostty.shape == .typo(edits: 1, offset: 0))
        #expect(ghostty.score == 9_000 - 1_000)

        // 2 edits on 7-char query
        let raycastTwoEdits = try #require(match(query: "raaycst", candidate: "Raycast"))
        #expect(raycastTwoEdits.shape == .typo(edits: 2, offset: 0))
        #expect(raycastTwoEdits.score == 9_000 - 2_000)
    }

    @Test func typoToleranceRejectsMoreEditsThanBudget() {
        // 3-5 char query with 2 edits -> rejected (budget is 1)
        #expect(match(query: "sfri", candidate: "Safari") == nil) // 2 deletions: 'a', 'a'
        // 6+ char query with 3 edits -> rejected (budget is 2)
        #expect(match(query: "rcst", candidate: "Raycast") == nil) // 3 deletions: 'a', 'y', 'a'
    }

    @Test func typoToleranceAnchorsFirstCharacter() {
        // First letter mismatch is rejected even within edit budget
        #expect(match(query: "chrome", candidate: "Home") == nil)
        #expect(match(query: "afari", candidate: "Safari") == nil)
    }

    @Test func typoMatchesAgainstIndividualWordsInCandidate() throws {
        // 'gogle' matches 'Google' in 'Google Chrome'
        let google = try #require(match(query: "gogle", candidate: "Google Chrome"))
        #expect(google.shape == .typo(edits: 1, offset: 0))
        #expect(google.score == 9_000 - 1_000)

        // 'chrom' (prefix) vs 'chrme' (typo) in 'Google Chrome'
        let chromeTypo = try #require(match(query: "chrme", candidate: "Google Chrome"))
        #expect(chromeTypo.shape == .typo(edits: 1, offset: 7))
        #expect(chromeTypo.score == 9_000 - 1_000 - 7)
    }

    // MARK: - Ranking Order Between Shapes

    @Test func structuralShapesStrictlyOutrankTypoMatches() throws {
        let exact = try #require(match(query: "safari", candidate: "Safari")?.score)
        let prefix = try #require(match(query: "saf", candidate: "Safari")?.score)
        let wordPrefix = try #require(match(query: "chrome", candidate: "Google Chrome")?.score)
        let acronym = try #require(match(query: "gc", candidate: "Google Chrome")?.score)
        let typo = try #require(match(query: "safri", candidate: "Safari")?.score)

        #expect(exact > prefix)
        #expect(prefix > wordPrefix)
        #expect(wordPrefix > acronym)
        #expect(acronym > typo)
    }

    // MARK: - Unicode / Diacritics

    @Test func diacriticsAndCaseAreNormalized() throws {
        let match = try #require(match(query: "unicode", candidate: "Ünïcodé-café.jpg"))
        #expect(match.shape == .namePrefix)
    }

    // MARK: - ASCII Fast Path Equivalence

    @Test func aSCIIFastPathMatchesUnicodePath() {
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

                #expect(
                    unicodeEvidence == asciiEvidence,
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

                #expect(
                    unicodeScore == asciiScore,
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
