import Foundation

/// A destination reachable by typing a short keyword as the first word of a
/// query — `yt lofi hip hop` for YouTube, `claude explain this` for an AI
/// ask. This is the one table both Floodlight's search bar and the PopClip
/// integration guide read from, so the two surfaces can never drift apart:
/// a URL-template engine mirrors PopClip's "Open URL %s" action, and an
/// assistant engine mirrors its "Shell Script %s" action.
package struct KeywordEngine: Sendable, Identifiable {
    private static let urlQueryValueAllowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
    )

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
    /// The verb phrase ("Search YouTube") used where the row's context
    /// can't supply it: the field's mode token and the Tab-completion hint.
    package let title: String
    /// The bare engine noun ("YouTube") — the row's title. Rows name the
    /// destination rather than narrating it ("Search YouTube for …"): the
    /// query they act on is already in the field, and a title that doesn't
    /// change per keystroke doesn't reflow while typing.
    package let name: String
    /// The brand tint behind the engine's icon tile.
    package let tint: SearchItemIconTint
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
        name: String,
        tint: SearchItemIconTint,
        keywords: [String],
        kind: SearchItemKind,
        destination: Destination
    ) {
        self.id = id
        self.title = title
        self.name = name
        self.tint = tint
        self.keywords = keywords
        self.kind = kind
        self.destination = destination
    }

    package var symbolName: String {
        switch id {
        case "youtube": "play.rectangle.fill"
        case "google": "g.circle.fill"
        case "github": "chevron.left.forwardslash.chevron.right"
        case "twitter": "at"
        case "wikipedia": "book.closed.fill"
        case "stackoverflow": "bubble.left.and.bubble.right.fill"
        case "codex", "claude": "sparkles"
        default: kind.symbolName
        }
    }

    /// The destination's bare host ("youtube.com"), parsed out of the URL
    /// template so the row's subtitle can never drift from where the row
    /// actually goes. `nil` for an assistant engine or an unparseable
    /// template.
    package var host: String? {
        guard case let .webSearch(urlTemplate) = destination else { return nil }
        let placeholderFree = urlTemplate.replacingOccurrences(of: "{query}", with: "")
        guard let host = URL(string: placeholderFree)?.host(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst("www.".count)) : host
    }

    /// The engine's results page for `query`, or `nil` for an assistant
    /// engine or a query that can't be percent-encoded into the template.
    /// Every surface that opens an engine in a browser — the keyword row,
    /// the fallback row, web mode — derives its URL here, so they can
    /// never drift apart.
    package func searchURL(for query: String) -> URL? {
        guard case let .webSearch(urlTemplate) = destination else { return nil }
        guard
            let encoded = query.addingPercentEncoding(
                withAllowedCharacters: Self.urlQueryValueAllowed
            ),
            let url = URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
        else {
            return nil
        }
        return url
    }

    /// The row subtitle for a `.webSearch` engine — the destination's host,
    /// so every engine row reads differently and says where the search
    /// goes. `nil` for an assistant engine, matching `searchURL(for:)`.
    package var searchSubtitle: String? {
        guard case .webSearch = destination else { return nil }
        return host ?? "Open in your default browser"
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
                  let subtitle = searchSubtitle
            else {
                return nil
            }
            return SearchItem(
                id: rowID,
                title: name,
                subtitle: subtitle,
                kind: kind,
                action: .open(url),
                iconSource: .engine(symbol: symbolName, tint: tint),
                score: SearchItemRanking.keywordEngine
            )
        case let .assistant(command, baseArguments):
            return SearchItem(
                id: rowID,
                title: "\(title): \(remainder)",
                subtitle: "Press Return to ask",
                kind: kind,
                action: .askAssistant(
                    command: command,
                    arguments: baseArguments + ["--", remainder]
                ),
                score: SearchItemRanking.keywordEngine
            )
        }
    }
}

/// The resolved destinations Keyword-Addressed Search may use right now.
/// Callers ask this value domain questions instead of sharing its engine
/// arrays and keyword lookup representation.
package struct KeywordEngineRegistry: Sendable {
    package struct WebModeAddress: Equatable, Sendable {
        package let engineID: String
        package let typedKeyword: String
        package let remainder: String
    }

    private let keywordLookup: [String: KeywordEngine]
    private let webKeywordLookup: [String: KeywordEngine]
    private let webEngines: [KeywordEngine]
    private let enginesByID: [String: KeywordEngine]
    private let defaultWebEngine: KeywordEngine

    package init(
        engines: [KeywordEngine],
        defaultWebEngineID: String
    ) {
        precondition(
            Set(engines.map(\.id)).count == engines.count,
            "Keyword engine IDs must be unique"
        )
        guard let defaultWebEngine = engines.first(where: { $0.id == defaultWebEngineID })
        else {
            preconditionFailure("The default web engine must belong to the registry")
        }
        guard case .webSearch = defaultWebEngine.destination else {
            preconditionFailure("The default keyword engine must be a web destination")
        }

        var keywordLookup: [String: KeywordEngine] = [:]
        var webKeywordLookup: [String: KeywordEngine] = [:]
        keywordLookup.reserveCapacity(engines.reduce(into: 0) { count, engine in
            count += engine.keywords.count
        })
        for engine in engines {
            for keyword in engine.keywords {
                let normalizedKeyword = keyword.lowercased()
                if keywordLookup[normalizedKeyword] == nil {
                    keywordLookup[normalizedKeyword] = engine
                }
                if case .webSearch = engine.destination,
                   webKeywordLookup[normalizedKeyword] == nil
                {
                    webKeywordLookup[normalizedKeyword] = engine
                }
            }
        }
        self.keywordLookup = keywordLookup
        self.webKeywordLookup = webKeywordLookup
        webEngines = engines.filter {
            if case .webSearch = $0.destination { return true }
            return false
        }
        enginesByID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        self.defaultWebEngine = defaultWebEngine
    }

    package var defaultWebEngineID: String {
        defaultWebEngine.id
    }

    package func addressedResult(for query: String) -> SearchItem? {
        guard let address = Self.parseAddress(query),
              !address.remainder.isEmpty,
              let engine = keywordLookup[address.typedKeyword.lowercased()]
        else {
            return nil
        }
        return engine.makeSearchItem(remainder: address.remainder)
    }

    package func webModeAddress(for query: String) -> WebModeAddress? {
        guard let address = Self.parseAddress(query),
              let engine = webKeywordLookup[address.typedKeyword.lowercased()]
        else {
            return nil
        }
        return WebModeAddress(
            engineID: engine.id,
            typedKeyword: address.typedKeyword,
            remainder: address.remainder
        )
    }

    package func defaultWebResult(for query: String) -> SearchItem? {
        guard let url = defaultWebEngine.searchURL(for: query),
              let subtitle = defaultWebEngine.searchSubtitle
        else {
            return nil
        }
        return SearchItem(
            id: "web-search",
            title: defaultWebEngine.name,
            subtitle: subtitle,
            kind: .web,
            action: .open(url),
            iconSource: .engine(
                symbol: defaultWebEngine.symbolName,
                tint: defaultWebEngine.tint
            ),
            score: 0
        )
    }

    package func webModeResults(
        for query: String,
        activeEngineID: String
    ) -> [SearchItem] {
        let ordered = webEngines.filter { $0.id == activeEngineID }
            + webEngines.filter { $0.id != activeEngineID }
        return ordered.enumerated().compactMap { position, engine in
            guard let url = engine.searchURL(for: query),
                  let subtitle = engine.searchSubtitle
            else {
                return nil
            }
            return SearchItem(
                id: "web-mode:\(engine.id)",
                title: engine.name,
                subtitle: subtitle,
                kind: .web,
                action: .open(url),
                iconSource: .engine(symbol: engine.symbolName, tint: engine.tint),
                score: SearchItemRanking.keywordEngine - position
            )
        }
    }

    package func webEngine(id: String) -> KeywordEngine? {
        guard let engine = enginesByID[id], case .webSearch = engine.destination else {
            return nil
        }
        return engine
    }

    package func canonicalKeyword(for engineID: String) -> String? {
        enginesByID[engineID]?.keywords.first
    }

    package func tabCompletionTitle(
        for query: String,
        resultID: SearchItem.ID
    ) -> String? {
        guard let address = Self.parseAddress(query),
              !address.remainder.isEmpty,
              let engine = webKeywordLookup[address.typedKeyword.lowercased()],
              engine.rowID == resultID
        else {
            return nil
        }
        return engine.title
    }

    private static func parseAddress(_ query: String) -> (
        typedKeyword: String,
        remainder: String
    )? {
        let end = query.endIndex
        var keywordStart = query.startIndex
        while keywordStart < end, query[keywordStart].isWhitespace {
            query.formIndex(after: &keywordStart)
        }
        guard keywordStart < end else { return nil }
        guard let separator = query[keywordStart...].firstIndex(where: \.isWhitespace) else {
            return (String(query[keywordStart..<end]), "")
        }

        var remainderStart = separator
        while remainderStart < end, query[remainderStart].isWhitespace {
            query.formIndex(after: &remainderStart)
        }
        guard remainderStart < end else {
            return (String(query[keywordStart..<separator]), "")
        }

        var remainderEnd = end
        while remainderEnd > remainderStart {
            let previous = query.index(before: remainderEnd)
            guard query[previous].isWhitespace else { break }
            remainderEnd = previous
        }
        return (
            typedKeyword: String(query[keywordStart..<separator]),
            remainder: String(query[remainderStart..<remainderEnd])
        )
    }
}

/// The fixed destination presets and the startup availability resolver that
/// publishes them as a `KeywordEngineRegistry`.
package enum KeywordEngineCatalog {
    /// The engine a resolved registry uses when nothing explicitly addresses
    /// another web destination.
    package static let defaultEngine = KeywordEngine(
        id: "google",
        title: "Search Google",
        name: "Google",
        tint: .blue,
        keywords: ["g", "google", "!g"],
        kind: .web,
        destination: .webSearch(urlTemplate: "https://www.google.com/search?q={query}")
    )

    package static let all: [KeywordEngine] = [
        defaultEngine,
        KeywordEngine(
            id: "wikipedia",
            title: "Search Wikipedia",
            name: "Wikipedia",
            tint: .gray,
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
            name: "GitHub",
            tint: .primary,
            keywords: ["gh", "github", "!gh"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://github.com/search?q={query}")
        ),
        KeywordEngine(
            id: "stackoverflow",
            title: "Search Stack Overflow",
            name: "Stack Overflow",
            tint: .orange,
            keywords: ["so", "stackoverflow", "!so"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://stackoverflow.com/search?q={query}")
        ),
        KeywordEngine(
            id: "twitter",
            title: "Search Twitter/X",
            name: "Twitter/X",
            tint: .cyan,
            keywords: ["x", "twitter", "!x"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://x.com/search?q={query}")
        ),
        KeywordEngine(
            id: "youtube",
            title: "Search YouTube",
            name: "YouTube",
            tint: .red,
            keywords: ["yt", "youtube", "!yt"],
            kind: .web,
            destination: .webSearch(
                urlTemplate: "https://www.youtube.com/results?search_query={query}"
            )
        ),
        KeywordEngine(
            id: "codex",
            title: "Ask Codex",
            name: "Codex",
            tint: .purple,
            keywords: ["codex", "!codex"],
            kind: .assistant,
            destination: .assistant(command: "codex", baseArguments: ["exec"])
        ),
        KeywordEngine(
            id: "claude",
            title: "Ask Claude",
            name: "Claude",
            tint: .purple,
            keywords: ["claude", "!claude"],
            kind: .assistant,
            destination: .assistant(command: "claude", baseArguments: ["-p"])
        ),
    ]

    package static let initialRegistry = KeywordEngineRegistry(
        engines: all.filter {
            if case .webSearch = $0.destination { return true }
            return false
        },
        defaultWebEngineID: defaultEngine.id
    )

    package static func availableRegistry(
        runner: any AssistantProcessRunning
    ) async -> KeywordEngineRegistry {
        let engines = await availableEngines(runner: runner)
        return KeywordEngineRegistry(
            engines: engines,
            defaultWebEngineID: defaultEngine.id
        )
    }

    /// Filters `all` down to what this Mac can actually run: web-search
    /// engines are always available, and an assistant engine only survives
    /// if its CLI resolves on this machine — an unresolvable "Ask Codex" row
    /// would be guaranteed to fail every time it's selected.
    private static func availableEngines(runner: any AssistantProcessRunning) async
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
