import Foundation

package enum FuzzyMatcher {
    /// The lowest score that counts as a confident match.
    ///
    /// Exact, prefix, and substring hits land far above it. Underneath sits the
    /// subsequence band the per-character loops open at 8_000, where a query's
    /// characters merely happen to appear in order — noise, until consecutive
    /// runs and word boundaries carry a candidate past this cutoff.
    package static let confidentMatchThreshold = 9_000

    static func score(query: String, candidate: String) -> Int? {
        score(
            normalizedQuery: normalized(query),
            normalizedCandidate: normalized(candidate)
        )
    }

    package static func score(normalizedQuery query: String, normalizedCandidate candidate: String) -> Int? {
        guard !query.isEmpty else { return 1 }
        if candidate == query { return 20_000 }
        if candidate.hasPrefix(query) { return 15_000 - candidate.count }
        if let range = candidate.range(of: query) {
            return 12_000 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        var queryIndex = query.startIndex
        var score = 8_000
        var lastMatch: String.Index?
        var consecutive = 0

        for index in candidate.indices where queryIndex < query.endIndex {
            guard candidate[index] == query[queryIndex] else {
                score -= 3
                continue
            }

            if let lastMatch, candidate.index(after: lastMatch) == index {
                consecutive += 1
                score += 80 * consecutive
            } else {
                consecutive = 0
                score -= candidate.distance(from: candidate.startIndex, to: index)
            }

            if index == candidate.startIndex || isBoundary(candidate, at: index) {
                score += 160
            }

            lastMatch = index
            query.formIndex(after: &queryIndex)
        }

        return queryIndex == query.endIndex ? score : nil
    }

    package static func scoreASCII(
        normalizedQuery query: [UInt8],
        normalizedCandidate candidate: [UInt8]
    ) -> Int? {
        guard !query.isEmpty else { return 1 }
        assert(query.allSatisfy { $0 < 0x80 })
        assert(candidate.allSatisfy { $0 < 0x80 })
        if candidate == query { return 20_000 }
        if candidate.starts(with: query) { return 15_000 - candidate.count }

        if query.count <= candidate.count {
            for start in 0...(candidate.count - query.count)
                where candidate[start..<(start + query.count)].elementsEqual(query) {
                return 12_000 - start
            }
        }

        var queryIndex = 0
        var score = 8_000
        var lastMatch: Int?
        var consecutive = 0

        for index in candidate.indices where queryIndex < query.count {
            guard candidate[index] == query[queryIndex] else {
                score -= 3
                continue
            }

            if let lastMatch, lastMatch + 1 == index {
                consecutive += 1
                score += 80 * consecutive
            } else {
                consecutive = 0
                score -= index
            }

            if index == 0 || isASCIIBoundary(candidate[index - 1]) {
                score += 160
            }

            lastMatch = index
            queryIndex += 1
        }

        return queryIndex == query.count ? score : nil
    }

    package static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func isBoundary(_ value: String, at index: String.Index) -> Bool {
        guard index > value.startIndex else { return true }
        let previous = value[value.index(before: index)]
        return previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "."
    }

    private static func isASCIIBoundary(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x2D || byte == 0x5F || byte == 0x2F || byte == 0x2E
    }
}
