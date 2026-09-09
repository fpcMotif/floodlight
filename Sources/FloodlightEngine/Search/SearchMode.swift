import Foundation

/// Which posture the panel's single field is in: searching local catalogs,
/// or addressing one web engine directly. Web mode remembers enough about
/// how it was entered that exiting can put the user's field back exactly —
/// Tab and Esc are true inverses.
///
/// Pure values plus a synchronous transition, no I/O, no UI types.
package enum SearchMode: Equatable, Sendable {
    case local
    case web(WebContext)
    case clipboard(ClipboardContext)

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

    package struct ClipboardContext: Equatable, Sendable {
        /// The keyword token as typed (`clip`, `CLIP`) when keyword
        /// completion entered the mode; `nil` when the clipboard shortcut
        /// entered it directly.
        package let typedKeyword: String?
        package let queryAtEntry: String

        package init(typedKeyword: String? = "clip", queryAtEntry: String = "") {
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
    /// The global clipboard shortcut fired. Whether that dismisses an
    /// already-open board is a presentation decision made above this
    /// pure transition, not a mode decision.
    case clipboardShortcut
}

extension SearchMode {
    /// The one place mode changes are decided. Takes the current (mode,
    /// query) and an event, returns the next (mode, query text) — the
    /// caller owns publishing both.
    package static func transition(
        from mode: SearchMode,
        query: String,
        event: SearchModeEvent,
        registry: KeywordEngineRegistry = KeywordEngineCatalog.initialRegistry
    ) -> (mode: SearchMode, query: String) {
        switch event {
        case .reset:
            return (.local, "")

        case .tab:
            guard case .local = mode else { return (mode, query) }
            return entered(query: query, registry: registry)

        case .clipboardShortcut:
            guard case .clipboard = mode else {
                return (.clipboard(ClipboardContext(typedKeyword: nil, queryAtEntry: "")), "")
            }
            return (mode, query)

        case .shiftTab, .escape, .backspaceOnEmptyQuery:
            switch mode {
            case let .web(context):
                return (.local, exitFieldText(for: context, query: query, registry: registry))
            case let .clipboard(context):
                return (.local, exitClipboardFieldText(for: context, query: query))
            case .local:
                return (mode, query)
            }
        }
    }

    /// Keyword completion for Tab: a first word that addresses a URL engine
    /// is absorbed into the mode (remainder becomes the query, even an
    /// empty one — a bare `yt` completes too, unlike the ranked keyword
    /// row). Anything else — plain text, an assistant keyword — enters the
    /// default engine's mode carrying the query unchanged.
    private static func entered(
        query: String,
        registry: KeywordEngineRegistry
    ) -> (mode: SearchMode, query: String) {
        if let token = KeywordEngineRegistry.parseAddress(query),
           token.typedKeyword.lowercased() == "clip"
        {
            let context = ClipboardContext(
                typedKeyword: token.typedKeyword,
                queryAtEntry: token.remainder
            )
            return (.clipboard(context), token.remainder)
        }

        guard let address = registry.webModeAddress(for: query) else {
            let context = WebContext(
                engineID: registry.defaultWebEngineID,
                typedKeyword: nil,
                queryAtEntry: query
            )
            return (.web(context), query)
        }

        let context = WebContext(
            engineID: address.engineID,
            typedKeyword: address.typedKeyword,
            queryAtEntry: address.remainder
        )
        return (.web(context), address.remainder)
    }

    /// What the field shows after leaving web mode. A keyword-completed
    /// mode reconstructs `keyword + space + query` so Tab↔Esc round-trip;
    /// the typed spelling survives while the query is unedited, and an
    /// edited query falls back to the engine's primary spelling.
    private static func exitFieldText(
        for context: WebContext,
        query: String,
        registry: KeywordEngineRegistry
    ) -> String {
        guard let typedKeyword = context.typedKeyword else { return query }

        let spelling: String = if query == context.queryAtEntry {
            typedKeyword
        } else {
            registry.canonicalKeyword(for: context.engineID) ?? typedKeyword
        }
        return query.isEmpty ? spelling : "\(spelling) \(query)"
    }

    private static func exitClipboardFieldText(
        for context: ClipboardContext,
        query: String
    ) -> String {
        guard let typedKeyword = context.typedKeyword else { return query }

        let spelling: String = if query == context.queryAtEntry {
            typedKeyword
        } else {
            "clip"
        }
        return query.isEmpty ? spelling : "\(spelling) \(query)"
    }
}
