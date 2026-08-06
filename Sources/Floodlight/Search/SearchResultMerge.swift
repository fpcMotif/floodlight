import Foundation

/// Merges everything a query produced into the one list Floodlight shows.
///
/// The catalogs, the file index, the calculator and the web fallback each
/// answer independently and in their own time. This is where those answers
/// become an order: bands first, then title, with earlier sources winning an
/// identifier collision and the web fallback always last.
///
/// Kept apart from `SearchCoordinator` so the merge can be exercised on its
/// own terms — the coordinator's job is scheduling and selection, not
/// deciding what a result list looks like.
enum SearchResultMerge {
    /// The identifier of the always-present web fallback row.
    static let webSearchResultID = "web-search"

    /// The most rows the panel will ever hold.
    ///
    /// Well past what fits on screen; the cap exists so a broad query cannot
    /// hand SwiftUI an unbounded list.
    static let maximumResults = 80

    /// - Parameters:
    ///   - indexed: file and folder matches from the FFF index.
    ///   - apps: application matches.
    ///   - system: System Settings matches.
    static func merge(
        query: String,
        indexed: [SearchItem],
        apps: [SearchItem],
        system: [SearchItem]
    ) -> [SearchItem] {
        var output: [SearchItem] = []

        if let value = Calculator.evaluate(query) {
            let answer = Calculator.format(value)
            output.append(
                SearchItem(
                    id: "calculator",
                    title: answer,
                    subtitle: "\(query) = \(answer) · Press Return to copy",
                    kind: .calculator,
                    action: .copy(answer),
                    score: SearchItemRanking.calculator
                )
            )
        }

        output.append(contentsOf: FloodlightCommandCatalog.search(query))
        output.append(contentsOf: apps)
        output.append(contentsOf: system)
        output.append(contentsOf: indexed)

        // First writer of an id wins, so the order above is also the
        // precedence order when two sources describe the same thing.
        var seen = Set<String>()
        output = SearchItemRanking.ranked(output.filter { seen.insert($0.id).inserted })

        if let fallback = webFallback(for: query) {
            output.append(fallback)
        }

        return Array(output.prefix(maximumResults))
    }

    /// The "search the web" row, or nil when there is nothing to search for.
    static func webFallback(for query: String) -> SearchItem? {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)")
        else {
            return nil
        }
        return SearchItem(
            id: webSearchResultID,
            title: "Search the Web for “\(query)”",
            subtitle: "Open in your default browser",
            kind: .web,
            action: .open(url),
            score: SearchItemRanking.webFallback
        )
    }
}
