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

    // periphery:ignore - Fast path ASCII score calculation tested against general path.
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
            return MatchEvidence(shape: .exact, score: 20_000)
        }

        if candidateChars.starts(with: queryChars) {
            return MatchEvidence(shape: .namePrefix, score: 15_000 - candidateChars.count)
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
            return MatchEvidence(shape: .exact, score: 20_000)
        }

        if candidate.starts(with: query) {
            return MatchEvidence(shape: .namePrefix, score: 15_000 - candidate.count)
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

    // MARK: - Private Helpers

    private static func findWordPrefix(
        queryChars: [Character],
        in words: [(offset: Int, chars: [Character])]
    ) -> MatchEvidence? {
        var bestOffset: Int?
        for word in words where word.offset > 0 && word.chars.starts(with: queryChars) {
            if let current = bestOffset {
                if word.offset < current {
                    bestOffset = word.offset
                }
            } else {
                bestOffset = word.offset
            }
        }
        return bestOffset.map { MatchEvidence(shape: .wordPrefix(offset: $0), score: 12_000 - $0) }
    }

    private static func findWordPrefixASCII(
        query: [UInt8],
        in words: [(offset: Int, bytes: ArraySlice<UInt8>)]
    ) -> MatchEvidence? {
        var bestOffset: Int?
        for word in words where word.offset > 0 && word.bytes.starts(with: query) {
            if let current = bestOffset {
                if word.offset < current {
                    bestOffset = word.offset
                }
            } else {
                bestOffset = word.offset
            }
        }
        return bestOffset.map { MatchEvidence(shape: .wordPrefix(offset: $0), score: 12_000 - $0) }
    }

    private static func findAcronym(
        queryChars: [Character],
        in words: [(offset: Int, chars: [Character])]
    ) -> MatchEvidence? {
        guard words.count > 1 else { return nil }
        let initials = words.compactMap(\.chars.first)
        guard queryChars.count <= initials.count else { return nil }

        for start in 0...(initials.count - queryChars.count)
            where initials[start..<(start + queryChars.count)].elementsEqual(queryChars)
        {
            return MatchEvidence(shape: .acronym(offset: start), score: 10_000 - start)
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
            return MatchEvidence(shape: .acronym(offset: start), score: 10_000 - start)
        }
        return nil
    }

    private static func findTypo(
        queryChars: [Character],
        candidateChars: [Character],
        words: [(offset: Int, chars: [Character])]
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
            score: 9_000 - (typo.edits * 1_000) - typo.offset
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
            score: 9_000 - (typo.edits * 1_000) - typo.offset
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
    ) -> [(offset: Int, chars: [Character])] {
        var words: [(offset: Int, chars: [Character])] = []
        var currentWordStart: Int?
        for (index, char) in characters.enumerated() {
            if !isSeparatorChar(char) {
                if currentWordStart == nil {
                    currentWordStart = index
                }
            } else {
                if let start = currentWordStart {
                    words.append((offset: start, chars: Array(characters[start..<index])))
                    currentWordStart = nil
                }
            }
        }
        if let start = currentWordStart {
            words.append((offset: start, chars: Array(characters[start..<characters.count])))
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
