import Foundation

/// Whether a query signals "I want the web", so the web-search row should be
/// promoted out of its default last place.
///
/// Two independent triggers promote the row: the query reads as a question
/// or a URL, or the local catalogs came back thin. Either is enough — a
/// question-shaped query with no local competition and a well-matched file
/// name both count as intent, for different reasons.
package enum WebSearchIntent {
    /// At or below this many local matches (apps + settings + files +
    /// content, combined), local results are too thin to trust on their own.
    package static let weakMatchThreshold = 2

    private static let questionWords: Set<String> = [
        "how", "what", "why", "who", "when", "where",
        "is", "are", "can", "does", "do", "should", "will", "which",
    ]

    package static func shouldPromote(query: String, localMatchCount: Int) -> Bool {
        guard !query.isEmpty else { return false }
        return localMatchCount <= weakMatchThreshold
            || looksLikeQuestion(query)
            || looksLikeURL(query)
    }

    package static func looksLikeQuestion(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        guard let firstWord = trimmed.split(separator: " ").first else { return false }
        return questionWords.contains(firstWord.lowercased())
    }

    package static func looksLikeURL(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return false
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range) else { return false }
        return match.range == range
    }
}
