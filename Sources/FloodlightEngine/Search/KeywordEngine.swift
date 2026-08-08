import Foundation

/// A destination reachable by typing a short keyword as the first word of a
/// query — `yt lofi hip hop` for YouTube, `claude explain this` for an AI
/// ask. This is the one table both Floodlight's search bar and the PopClip
/// integration guide read from, so the two surfaces can never drift apart:
/// a URL-template engine mirrors PopClip's "Open URL %s" action, and an
/// assistant engine mirrors its "Shell Script %s" action.
package struct KeywordEngine: Sendable, Identifiable {
    /// Where a matched query goes: a browser-opened URL, or an installed
    /// CLI run locally with the remainder of the query as its last argument.
    package enum Destination: Sendable {
        /// `urlTemplate` must contain the literal placeholder `{query}`,
        /// replaced with the percent-encoded remainder before opening.
        case webSearch(urlTemplate: String)
        /// `command` is a bare executable name (never a shell string); the
        /// remainder of the query is appended to `baseArguments` as one
        /// argument, never interpolated into anything a shell re-parses.
        case assistant(command: String, baseArguments: [String])
    }

    package let id: String
    package let title: String
    /// Case-insensitive first-word triggers, including any bang alias
    /// (`"x"`, `"twitter"`, `"!x"`). Matched against the query's first
    /// whitespace-delimited token only. Order is meaningful: the first
    /// entry is the engine's primary/canonical spelling — what
    /// `SearchMode.exitFieldText` reconstructs in the field on exiting web
    /// mode once the query has been edited and the originally-typed
    /// spelling no longer applies.
    package let keywords: [String]
    package let kind: SearchItemKind
    package let destination: Destination

    package init(
        id: String,
        title: String,
        keywords: [String],
        kind: SearchItemKind,
        destination: Destination
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.kind = kind
        self.destination = destination
    }

    package var symbolName: String {
        switch id {
        case "youtube": "play.rectangle.fill"
        case "google": "magnifyingglass.circle.fill"
        case "github": "code"
        case "twitter": "at"
        case "wikipedia": "book.closed.fill"
        case "stackoverflow": "bubble.left.and.bubble.right.fill"
        case "codex", "claude": "sparkles"
        default: kind.symbolName
        }
    }

    /// The engine's results page for `query`, or `nil` for an assistant
    /// engine or a query that can't be percent-encoded into the template.
    /// Every surface that opens an engine in a browser — the keyword row,
    /// the fallback row, web mode — derives its URL here, so they can
    /// never drift apart.
    package func searchURL(for query: String) -> URL? {
        guard case let .webSearch(urlTemplate) = destination else { return nil }
        guard
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
        else {
            return nil
        }
        return url
    }

    /// The row title for a `.webSearch` engine's results page, or `nil` for
    /// an assistant engine — `nil` `query` reads as "not typed yet" (web
    /// mode's bare-keyword state) rather than "for empty string". Shares
    /// one format across the keyword row, web mode, and the fallback row,
    /// the same guarantee `searchURL(for:)` already gives the URL itself.
    package func searchTitle(for query: String) -> String? {
        guard case .webSearch = destination else { return nil }
        return query.isEmpty ? title : "\(title) for “\(query)”"
    }

    /// The row identifier a keyword match produces for this engine —
    /// shared by `makeSearchItem` and anything else that needs to
    /// recognize "the row this engine's keyword match would rank," such as
    /// the Tab-completion affordance on that row.
    package var rowID: String {
        "keyword-engine:\(id)"
    }

    /// Builds the row for a matched `remainder`, or `nil` if the remainder
    /// can't become a valid URL (a `.webSearch` destination only).
    package func makeSearchItem(remainder: String) -> SearchItem? {
        switch destination {
        case .webSearch:
            guard let url = searchURL(for: remainder),
                  let title = searchTitle(for: remainder)
            else {
                return nil
            }
            return SearchItem(
                id: rowID,
                title: title,
                subtitle: "Open in your default browser",
                kind: kind,
                action: .open(url),
                score: SearchItemRanking.keywordEngine
            )
        case let .assistant(command, baseArguments):
            return SearchItem(
                id: rowID,
                title: "\(title): \(remainder)",
                subtitle: "Press Return to ask",
                kind: kind,
                action: .askAssistant(command: command, arguments: baseArguments + [remainder]),
                score: SearchItemRanking.keywordEngine
            )
        }
    }
}

/// The fixed set of keyword engines and the pure parser that matches a
/// query's first word against them — the explicit-address counterpart to
/// `WebSearchIntent`'s auto-detected promotion of the default web row.
package enum KeywordEngineCatalog {
    /// The engine a web destination falls back to when nothing addresses one
    /// explicitly. Exactly three consumers read this: the local-mode web
    /// fallback row, plain-query Tab, and nothing else.
    package static let defaultEngine = KeywordEngine(
        id: "google",
        title: "Search Google",
        keywords: ["g", "google", "!g"],
        kind: .web,
        destination: .webSearch(urlTemplate: "https://www.google.com/search?q={query}")
    )

    package static let all: [KeywordEngine] = [
        defaultEngine,
        KeywordEngine(
            id: "wikipedia",
            title: "Search Wikipedia",
            // Deliberately no single-letter "w": its accidental first-word
            // hit rate in natural queries is too high.
            keywords: ["wiki", "wikipedia", "!wiki"],
            kind: .web,
            destination: .webSearch(
                urlTemplate: "https://en.wikipedia.org/wiki/Special:Search?search={query}"
            )
        ),
        KeywordEngine(
            id: "github",
            title: "Search GitHub",
            keywords: ["gh", "github", "!gh"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://github.com/search?q={query}")
        ),
        KeywordEngine(
            id: "stackoverflow",
            title: "Search Stack Overflow",
            keywords: ["so", "stackoverflow", "!so"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://stackoverflow.com/search?q={query}")
        ),
        KeywordEngine(
            id: "twitter",
            title: "Search Twitter/X",
            keywords: ["x", "twitter", "!x"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://x.com/search?q={query}")
        ),
        KeywordEngine(
            id: "youtube",
            title: "Search YouTube",
            keywords: ["yt", "youtube", "!yt"],
            kind: .web,
            destination: .webSearch(
                urlTemplate: "https://www.youtube.com/results?search_query={query}"
            )
        ),
        KeywordEngine(
            id: "codex",
            title: "Ask Codex",
            keywords: ["codex", "!codex"],
            kind: .assistant,
            destination: .assistant(command: "codex", baseArguments: ["exec"])
        ),
        KeywordEngine(
            id: "claude",
            title: "Ask Claude",
            keywords: ["claude", "!claude"],
            kind: .assistant,
            destination: .assistant(command: "claude", baseArguments: ["-p"])
        ),
    ]

    /// The URL-template preset engines in table order — the exact set web
    /// mode shows one row per, and the order those rows keep after the
    /// active engine is moved to the front.
    package static var webSearchEngines: [KeywordEngine] {
        all.filter { engine in
            if case .webSearch = engine.destination { return true }
            return false
        }
    }

    /// Matches `query`'s first whitespace-delimited token against `engines`'
    /// keywords, case-insensitively. A bare keyword with nothing after it —
    /// or a keyword that isn't in first position — is not a match, so a
    /// query still being typed doesn't fire early and a keyword that shows
    /// up mid-sentence doesn't hijack the row.
    package static func match(
        _ query: String,
        in engines: [KeywordEngine] = KeywordEngineCatalog.all
    ) -> (engine: KeywordEngine, remainder: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(where: \.isWhitespace) else { return nil }

        let keyword = trimmed[trimmed.startIndex..<spaceIndex].lowercased()
        let remainder = trimmed[trimmed.index(after: spaceIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        guard let engine = engines.first(where: { $0.keywords.contains(keyword) })
        else { return nil }

        return (engine, remainder)
    }

    package static func search(
        _ query: String,
        in engines: [KeywordEngine] = KeywordEngineCatalog.all
    ) -> [SearchItem] {
        guard let match = match(query, in: engines) else { return [] }
        guard let item = match.engine.makeSearchItem(remainder: match.remainder) else { return [] }
        return [item]
    }

    /// Filters `all` down to what this Mac can actually run: web-search
    /// engines are always available, and an assistant engine only survives
    /// if its CLI resolves on this machine — an unresolvable "Ask Codex" row
    /// would be guaranteed to fail every time it's selected.
    package static func availableEngines(runner: any AssistantProcessRunning) async
        -> [KeywordEngine]
    {
        var available: [KeywordEngine] = []
        for engine in all {
            switch engine.destination {
            case .webSearch:
                available.append(engine)
            case let .assistant(command, _):
                if await runner.isAvailable(command: command) {
                    available.append(engine)
                }
            }
        }
        return available
    }
}
