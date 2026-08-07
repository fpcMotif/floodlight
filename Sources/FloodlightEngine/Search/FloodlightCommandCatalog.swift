import Foundation

package enum FloodlightCommandCatalog {
    private static let settingsCandidate = FuzzyMatcher.normalized(
        "Floodlight settings setup preferences permissions keyboard shortcut hotkey "
            + "search scope folders full disk access launch at login"
    )

    package static func search(_ query: String) -> [SearchItem] {
        let normalizedQuery = FuzzyMatcher.normalized(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard
            !normalizedQuery.isEmpty,
            let score = FuzzyMatcher.score(
                normalizedQuery: normalizedQuery,
                normalizedCandidate: settingsCandidate
            ),
            score >= FuzzyMatcher.confidentMatchThreshold
        else {
            return []
        }

        return [
            SearchItem(
                id: "floodlight-command:settings",
                title: "Floodlight settings",
                subtitle: "Shortcut, search access, and launch at login",
                kind: .systemSetting,
                action: .showFloodlightSettings,
                iconSource: .floodlightApplication,
                score: 200_000 + score
            ),
        ]
    }
}
