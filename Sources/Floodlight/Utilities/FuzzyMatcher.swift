import Foundation

enum FuzzyMatcher {
    static func score(query: String, candidate: String) -> Int? {
        score(
            normalizedQuery: normalized(query),
            normalizedCandidate: normalized(candidate)
        )
    }

    static func score(normalizedQuery query: String, normalizedCandidate candidate: String) -> Int? {
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

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func isBoundary(_ value: String, at index: String.Index) -> Bool {
        guard index > value.startIndex else { return true }
        let previous = value[value.index(before: index)]
        return previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "."
    }
}
