import Foundation

/// Which posture the panel's single field is in: searching local catalogs,
/// or addressing one web engine directly. Web mode remembers enough about
/// how it was entered that exiting can put the user's field back exactly —
/// Tab and Esc are true inverses.
///
/// Shaped like `WebSearchIntent`: values plus a pure, synchronous
/// transition, no I/O, no UI types.
package enum SearchMode: Equatable, Sendable {
    case local
    case web(WebContext)

    package struct WebContext: Equatable, Sendable {
        package let engineID: String
        /// The keyword token exactly as the user typed it (`yt`, `!YT`,
        /// `YouTube`) when keyword completion entered the mode; `nil` when
        /// a plain-query Tab addressed the default engine.
        package let typedKeyword: String?
        /// The query at the moment of entry — compared against the live
        /// query on exit to choose the typed spelling (unedited) or the
        /// primary spelling (edited).
        package let queryAtEntry: String

        package init(engineID: String, typedKeyword: String?, queryAtEntry: String) {
            self.engineID = engineID
            self.typedKeyword = typedKeyword
            self.queryAtEntry = queryAtEntry
        }
    }
}

/// The keys that move the mode, as intents rather than key codes — the
/// field decides what was pressed, this decides what it means.
package enum SearchModeEvent: Equatable, Sendable {
    case tab
    case shiftTab
    case escape
    case backspaceOnEmptyQuery
    case reset
}

extension SearchMode {
    /// The one place mode changes are decided. Takes the current (mode,
    /// query) and an event, returns the next (mode, query text) — the
    /// caller owns publishing both.
    package static func transition(
        from mode: SearchMode,
        query: String,
        event: SearchModeEvent,
        engines: [KeywordEngine] = KeywordEngineCatalog.all,
        defaultEngine: KeywordEngine = KeywordEngineCatalog.defaultEngine
    ) -> (mode: SearchMode, query: String) {
        switch event {
        case .reset:
            return (.local, "")

        case .tab:
            guard case .local = mode else { return (mode, query) }
            return entered(query: query, engines: engines, defaultEngine: defaultEngine)

        case .shiftTab, .escape, .backspaceOnEmptyQuery:
            guard case .web(let context) = mode else { return (mode, query) }
            return (.local, exitFieldText(for: context, query: query, engines: engines))
        }
    }

    /// Keyword completion for Tab: a first word that addresses a URL engine
    /// is absorbed into the mode (remainder becomes the query, even an
    /// empty one — a bare `yt` completes too, unlike the ranked keyword
    /// row). Anything else — plain text, an assistant keyword — enters the
    /// default engine's mode carrying the query unchanged.
    private static func entered(
        query: String,
        engines: [KeywordEngine],
        defaultEngine: KeywordEngine
    ) -> (mode: SearchMode, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKeyword = String(trimmed.prefix { !$0.isWhitespace })
        let keyword = typedKeyword.lowercased()

        let matched = engines.first { engine in
            guard case .webSearch = engine.destination else { return false }
            return engine.keywords.contains(keyword)
        }

        guard let matched else {
            let context = WebContext(
                engineID: defaultEngine.id,
                typedKeyword: nil,
                queryAtEntry: query
            )
            return (.web(context), query)
        }

        let remainder = trimmed.dropFirst(typedKeyword.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let context = WebContext(
            engineID: matched.id,
            typedKeyword: typedKeyword,
            queryAtEntry: remainder
        )
        return (.web(context), remainder)
    }

    /// What the field shows after leaving web mode. A keyword-completed
    /// mode reconstructs `keyword + space + query` so Tab↔Esc round-trip;
    /// the typed spelling survives while the query is unedited, and an
    /// edited query falls back to the engine's primary spelling.
    private static func exitFieldText(
        for context: WebContext,
        query: String,
        engines: [KeywordEngine]
    ) -> String {
        guard let typedKeyword = context.typedKeyword else { return query }

        let spelling: String
        if query == context.queryAtEntry {
            spelling = typedKeyword
        } else {
            let primary = engines
                .first { $0.id == context.engineID }?
                .keywords.first
            spelling = primary ?? typedKeyword
        }
        return query.isEmpty ? spelling : "\(spelling) \(query)"
    }
}
