import Foundation

package enum FuzzyMatcher {
    /// The structured evidence describing which shape matched and how well.
    package struct MatchEvidence: Equatable, Sendable {
        package enum Shape: Equatable, Sendable {
            case exact
            case namePrefix
            case wordPrefix(offset: Int)
            case acronym(offset: Int)
            case typo(edits: Int, offset: Int)
        }

        package let shape: Shape
        package let score: Int

        package init(shape: Shape, score: Int) {
            self.shape = shape
            self.score = score
        }
    }

    // periphery:ignore - Confident match threshold referenced in test assertions.
    /// The lowest score that counts as a confident match.
    package static let confidentMatchThreshold = 7_000

    /// The base score of each match shape, before its own penalty.
    ///
    /// A shape's published score is its base less a small penalty — candidate
    /// length for a name prefix, word or acronym offset, edit count for a typo
    /// — so the bases are spaced far enough apart that a stronger shape always
    /// outranks a weaker one. `maximumLearningBoost` depends on that spacing.
    package enum ShapeScore {
        package static let exact = 20_000
        package static let namePrefix = 15_000
        package static let wordPrefix = 12_000
        package static let acronym = 10_000
        package static let typo = 9_000

        /// Each further edit drops a typo match a full step down the ladder.
        package static let typoEditPenalty = 1_000

        /// The most edits `editBudget(forQueryLength:)` ever allows.
        package static let maximumTypoEdits = FuzzyMatcher.editBudget(forQueryLength: .max)

        /// The most a shape's own penalty may subtract from its base.
        ///
        /// The penalties are lengths and offsets, and nothing about a candidate
        /// bounds those. Unclamped, a 5,000-character candidate drops a name
        /// prefix from 15,000 onto the acronym rung, and a far-offset one-edit
        /// typo falls below a near-offset two-edit typo — the ladder stops
        /// describing the order the matcher actually produces. Capping keeps
        /// every shape inside a band of its own, which is the whole premise
        /// `maximumLearningBoost` is sized against.
        package static let maximumShapePenalty = 500

        /// A base less its own penalty, never more than `maximumShapePenalty`.
        static func penalised(_ base: Int, by penalty: Int) -> Int {
            base - min(penalty, maximumShapePenalty)
        }

        // periphery:ignore - The ladder exists so the ranking invariant test
        // reads the same numbers the matcher scores with, rather than a copy.
        /// Every band a match can land in, strongest first.
        ///
        /// Both edges, because the gap that matters is between one rung's floor
        /// and the next rung's ceiling — not between their bases, which are all
        /// `maximumShapePenalty` apart from their own floors and so leave the
        /// spacing looking wider than it is.
        ///
        /// A typo always carries at least one edit, so the typo tier enters the
        /// ladder already penalised — 8,000 and 7,000, never 9,000.
        package static let ladder: [(floor: Int, ceiling: Int)] =
            // An exact match carries no penalty of its own: it is the one rung
            // whose floor and ceiling are the same number.
            [(floor: exact, ceiling: exact)]
            + [namePrefix, wordPrefix, acronym].map {
                (floor: penalised($0, by: .max), ceiling: $0)
            }

            + (1...maximumTypoEdits).map { edits in
                let base = typo - edits * typoEditPenalty
                return (floor: penalised(base, by: .max), ceiling: base)
            }
    }

    /// The most any learning signal may add on top of a shape score.
    ///
    /// Source Selection Learning orders results that matched *the same way*; it
    /// must never lift a weaker shape above a stronger one. So the bound is the
    /// narrowest gap between one rung's FLOOR and the next rung's CEILING —
    /// what a real pair of scores can be, not what their bases suggest. The
    /// binding pair is the two typo rungs: a one-edit typo bottoms out at 7,500
    /// and a two-edit typo tops out at 7,000, so 500 is all there is and the
    /// boost has to stay strictly under it. Reading the bases instead gives
    /// 1,000 and a boost that can invert them, which is what
    /// `SearchItemRankingTests` now asserts against.
    ///
    /// `RecentStore` scales its recency and launch components into this bound:
    /// five parts launch count, saturating at 25 launches, to four parts
    /// recency, decaying to nothing over about six weeks. Widening either scale
    /// means revisiting the other, which is why both are described here.
    package static let maximumLearningBoost = 499

    // periphery:ignore - Test-only boundary that normalizes raw query text.
    static func match(query: String, candidate: String) -> MatchEvidence? {
        match(
            normalizedQuery: normalized(query),
            normalizedCandidate: normalized(candidate)
        )
    }

    // periphery:ignore - Test-only boundary that normalizes raw query text.
    static func score(query: String, candidate: String) -> Int? {
        score(
            normalizedQuery: normalized(query),
            normalizedCandidate: normalized(candidate)
        )
    }

    package static func score(
        normalizedQuery query: String,
        normalizedCandidate candidate: String
    ) -> Int? {
        guard !query.isEmpty else { return 1 }
        return match(normalizedQuery: query, normalizedCandidate: candidate)?.score
    }

    package static func scoreASCII(
        normalizedQuery query: [UInt8],
        normalizedCandidate candidate: [UInt8]
    ) -> Int? {
        guard !query.isEmpty else { return 1 }
        return matchASCII(normalizedQuery: query, normalizedCandidate: candidate)?.score
    }

    package static func match(
        normalizedQuery query: String,
        normalizedCandidate candidate: String
    ) -> MatchEvidence? {
        let queryChars = Array(query)
        let candidateChars = Array(candidate)

        guard !queryChars.isEmpty else {
            return nil
        }
        if candidateChars == queryChars {
            return MatchEvidence(shape: .exact, score: ShapeScore.exact)
        }

        if candidateChars.starts(with: queryChars) {
            return MatchEvidence(
                shape: .namePrefix,
                score: ShapeScore.penalised(ShapeScore.namePrefix, by: candidateChars.count)
            )
        }

        let words = extractWords(from: candidateChars)

        if let evidence = findWordPrefix(queryChars: queryChars, in: words) {
            return evidence
        }

        if let evidence = findAcronym(queryChars: queryChars, in: words) {
            return evidence
        }

        return findTypo(queryChars: queryChars, candidateChars: candidateChars, words: words)
    }

    package static func matchASCII(
        normalizedQuery query: [UInt8],
        normalizedCandidate candidate: [UInt8]
    ) -> MatchEvidence? {
        guard !query.isEmpty else {
            return nil
        }
        assert(query.allSatisfy { $0 < 0x80 })
        assert(candidate.allSatisfy { $0 < 0x80 })

        if candidate == query {
            return MatchEvidence(shape: .exact, score: ShapeScore.exact)
        }

        if candidate.starts(with: query) {
            return MatchEvidence(
                shape: .namePrefix,
                score: ShapeScore.penalised(ShapeScore.namePrefix, by: candidate.count)
            )
        }

        let words = extractWordsASCII(from: candidate)

        if let evidence = findWordPrefixASCII(query: query, in: words) {
            return evidence
        }

        if let evidence = findAcronymASCII(query: query, in: words) {
            return evidence
        }

        return findTypoASCII(query: query, candidate: candidate, words: words)
    }

    package static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The set of ASCII letters and digits `value` contains, packed into a 64-bit mask.
    /// A query's mask must be a subset of a candidate's mask before the fuzzy scorer runs.
    package static func characterMask(_ value: String) -> UInt64 {
        value.utf8.reduce(into: 0) { mask, byte in
            let bit: UInt64? = switch byte {
            case 0x61...0x7A:
                UInt64(byte - 0x61)
            case 0x41...0x5A:
                UInt64(byte - 0x41)
            case 0x30...0x39:
                UInt64(byte - 0x30 + 26)
            default:
                nil
            }
            if let bit {
                mask |= 1 << bit
            }
        }
    }

    // MARK: - Private Helpers

    private static func findWordPrefix(
        queryChars: [Character],
        in words: [(offset: Int, chars: ArraySlice<Character>)]
    ) -> MatchEvidence? {
        for word in words where word.offset > 0 && word.chars.starts(with: queryChars) {
            return MatchEvidence(
                shape: .wordPrefix(offset: word.offset),
                score: ShapeScore.penalised(ShapeScore.wordPrefix, by: word.offset)
            )
        }
        return nil
    }

    private static func findWordPrefixASCII(
        query: [UInt8],
        in words: [(offset: Int, bytes: ArraySlice<UInt8>)]
    ) -> MatchEvidence? {
        for word in words where word.offset > 0 && word.bytes.starts(with: query) {
            return MatchEvidence(
                shape: .wordPrefix(offset: word.offset),
                score: ShapeScore.penalised(ShapeScore.wordPrefix, by: word.offset)
            )
        }
        return nil
    }

    private static func findAcronym(
        queryChars: [Character],
        in words: [(offset: Int, chars: ArraySlice<Character>)]
    ) -> MatchEvidence? {
        guard words.count > 1 else { return nil }
        let initials = words.compactMap(\.chars.first)
        guard queryChars.count <= initials.count else { return nil }

        for start in 0...(initials.count - queryChars.count)
            where initials[start..<(start + queryChars.count)].elementsEqual(queryChars)
        {
            return MatchEvidence(
                shape: .acronym(offset: start),
                score: ShapeScore.penalised(ShapeScore.acronym, by: start)
            )
        }
        return nil
    }

    private static func findAcronymASCII(
        query: [UInt8],
        in words: [(offset: Int, bytes: ArraySlice<UInt8>)]
    ) -> MatchEvidence? {
        guard words.count > 1 else { return nil }
        let initials = words.compactMap(\.bytes.first)
        guard query.count <= initials.count else { return nil }

        for start in 0...(initials.count - query.count)
            where initials[start..<(start + query.count)].elementsEqual(query)
        {
            return MatchEvidence(
                shape: .acronym(offset: start),
                score: ShapeScore.penalised(ShapeScore.acronym, by: start)
            )
        }
        return nil
    }

    private static func findTypo(
        queryChars: [Character],
        candidateChars: [Character],
        words: [(offset: Int, chars: ArraySlice<Character>)]
    ) -> MatchEvidence? {
        let budget = editBudget(forQueryLength: queryChars.count)
        guard budget > 0 else { return nil }

        var bestTypo: (edits: Int, offset: Int)?

        if candidateChars.first == queryChars.first,
           let edits = damerauLevenshtein(queryChars, candidateChars, maxEdits: budget),
           edits > 0
        {
            bestTypo = (edits: edits, offset: 0)
        }

        for word in words where word.chars.first == queryChars.first {
            if let edits = damerauLevenshtein(queryChars, word.chars, maxEdits: budget),
               edits > 0
            {
                if let current = bestTypo {
                    if edits < current
                        .edits || (edits == current.edits && word.offset < current.offset)
                    {
                        bestTypo = (edits: edits, offset: word.offset)
                    }
                } else {
                    bestTypo = (edits: edits, offset: word.offset)
                }
            }
        }

        guard let typo = bestTypo else { return nil }
        return MatchEvidence(
            shape: .typo(edits: typo.edits, offset: typo.offset),
            score: ShapeScore.penalised(
                ShapeScore.typo - typo.edits * ShapeScore.typoEditPenalty,
                by: typo.offset
            )
        )
    }

    private static func findTypoASCII(
        query: [UInt8],
        candidate: [UInt8],
        words: [(offset: Int, bytes: ArraySlice<UInt8>)]
    ) -> MatchEvidence? {
        let budget = editBudget(forQueryLength: query.count)
        guard budget > 0 else { return nil }

        var bestTypo: (edits: Int, offset: Int)?

        if candidate.first == query.first,
           let edits = damerauLevenshtein(query, candidate, maxEdits: budget),
           edits > 0
        {
            bestTypo = (edits: edits, offset: 0)
        }

        for word in words where word.bytes.first == query.first {
            if let edits = damerauLevenshtein(query, word.bytes, maxEdits: budget),
               edits > 0
            {
                if let current = bestTypo {
                    if edits < current
                        .edits || (edits == current.edits && word.offset < current.offset)
                    {
                        bestTypo = (edits: edits, offset: word.offset)
                    }
                } else {
                    bestTypo = (edits: edits, offset: word.offset)
                }
            }
        }

        guard let typo = bestTypo else { return nil }
        return MatchEvidence(
            shape: .typo(edits: typo.edits, offset: typo.offset),
            score: ShapeScore.penalised(
                ShapeScore.typo - typo.edits * ShapeScore.typoEditPenalty,
                by: typo.offset
            )
        )
    }

    private static func editBudget(forQueryLength length: Int) -> Int {
        switch length {
        case 0...2: 0
        case 3...5: 1
        default: 2
        }
    }

    package static func isSeparatorChar(_ char: Character) -> Bool {
        char == " " || char == "-" || char == "_" || char == "/" || char == "."
            || char == "&" || char == "," || char == ":" || char == ";"
            || char == "(" || char == ")" || char == "[" || char == "]"
    }

    private static func isSeparatorByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x2D, 0x5F, 0x2F, 0x2E, 0x26, 0x2C, 0x3A, 0x3B, 0x28, 0x29, 0x5B, 0x5D:
            true
        default:
            false
        }
    }

    private static func extractWords(
        from characters: [Character]
    ) -> [(offset: Int, chars: ArraySlice<Character>)] {
        var words: [(offset: Int, chars: ArraySlice<Character>)] = []
        words.reserveCapacity(4)
        var currentWordStart: Int?
        for (index, char) in characters.enumerated() {
            if !isSeparatorChar(char) {
                if currentWordStart == nil {
                    currentWordStart = index
                }
            } else {
                if let start = currentWordStart {
                    words.append((offset: start, chars: characters[start..<index]))
                    currentWordStart = nil
                }
            }
        }
        if let start = currentWordStart {
            words.append((offset: start, chars: characters[start..<characters.count]))
        }
        return words
    }

    private static func extractWordsASCII(
        from bytes: [UInt8]
    ) -> [(offset: Int, bytes: ArraySlice<UInt8>)] {
        var words: [(offset: Int, bytes: ArraySlice<UInt8>)] = []
        var currentWordStart: Int?
        for (index, byte) in bytes.enumerated() {
            if !isSeparatorByte(byte) {
                if currentWordStart == nil {
                    currentWordStart = index
                }
            } else {
                if let start = currentWordStart {
                    words.append((offset: start, bytes: bytes[start..<index]))
                    currentWordStart = nil
                }
            }
        }
        if let start = currentWordStart {
            words.append((offset: start, bytes: bytes[start..<bytes.count]))
        }
        return words
    }

    private static func damerauLevenshtein<
        C1: RandomAccessCollection,
        C2: RandomAccessCollection
    >(
        _ source: C1,
        _ target: C2,
        maxEdits: Int
    ) -> Int? where C1.Element == C2.Element, C1.Element: Equatable, C1.Index == Int,
        C2.Index == Int
    {
        let sourceLength = source.count
        let targetLength = target.count
        if abs(sourceLength - targetLength) > maxEdits { return nil }
        if sourceLength == targetLength, source.elementsEqual(target) { return 0 }

        let cols = targetLength + 1
        let total = (sourceLength + 1) * cols

        return withUnsafeTemporaryAllocation(of: Int.self, capacity: total) { buffer in
            guard let base = buffer.baseAddress else { return nil }
            for index in 0...sourceLength {
                base[index * cols] = index
            }
            for columnIndex in 0...targetLength {
                base[columnIndex] = columnIndex
            }

            let sourceStartIndex = source.startIndex
            let targetStartIndex = target.startIndex

            for rowIndex in 1...sourceLength {
                var rowMin = Int.max
                let rowOffset = rowIndex * cols
                let prevRowOffset = (rowIndex - 1) * cols
                let sourceChar = source[sourceStartIndex + rowIndex - 1]

                for columnIndex in 1...targetLength {
                    let targetChar = target[targetStartIndex + columnIndex - 1]
                    let cost = (sourceChar == targetChar) ? 0 : 1
                    var dist = min(
                        base[prevRowOffset + columnIndex] + 1,
                        base[rowOffset + columnIndex - 1] + 1,
                        base[prevRowOffset + columnIndex - 1] + cost
                    )
                    if rowIndex > 1,
                       columnIndex > 1,
                       sourceChar == target[targetStartIndex + columnIndex - 2],
                       source[sourceStartIndex + rowIndex - 2] == targetChar
                    {
                        let prevPrevRowOffset = (rowIndex - 2) * cols
                        dist = min(dist, base[prevPrevRowOffset + columnIndex - 2] + 1)
                    }
                    base[rowOffset + columnIndex] = dist
                    if dist < rowMin { rowMin = dist }
                }
                if rowMin > maxEdits { return nil }
            }
            let result = base[sourceLength * cols + targetLength]
            return result <= maxEdits ? result : nil
        }
    }
}
