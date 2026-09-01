import Testing
@testable import FloodlightEngine

/// The Tab↔Esc state machine: pure inputs in, (mode, query) out, no coordinator.
struct SearchModeTests {
    private func transition(
        from mode: SearchMode,
        query: String,
        event: SearchModeEvent
    ) -> (mode: SearchMode, query: String) {
        SearchMode.transition(from: mode, query: query, event: event)
    }

    private func webContext(
        engineID: String,
        typedKeyword: String? = nil,
        queryAtEntry: String
    ) -> SearchMode {
        .web(
            SearchMode.WebContext(
                engineID: engineID,
                typedKeyword: typedKeyword,
                queryAtEntry: queryAtEntry
            )
        )
    }

    private func clipboardContext(
        typedKeyword: String = "clip",
        queryAtEntry: String
    ) -> SearchMode {
        .clipboard(
            SearchMode.ClipboardContext(
                typedKeyword: typedKeyword,
                queryAtEntry: queryAtEntry
            )
        )
    }

    // MARK: - Entering clipboard mode with Tab

    @Test func tabOnBareClipEntersClipboardModeWithEmptyQuery() {
        let result = transition(from: .local, query: "clip", event: .tab)

        #expect(result.mode == clipboardContext(typedKeyword: "clip", queryAtEntry: ""))
        #expect(result.query.isEmpty)
    }

    @Test func tabOnClipWithRemainderEntersClipboardModeWithRemainder() {
        let result = transition(from: .local, query: "clip invoice", event: .tab)

        #expect(result.mode == clipboardContext(typedKeyword: "clip", queryAtEntry: "invoice"))
        #expect(result.query == "invoice")
    }

    @Test func tabOnClipPreservesTypedCasingAndWhitespace() {
        let result = transition(from: .local, query: "CLIP   notes and tasks  ", event: .tab)

        #expect(result.mode == clipboardContext(
            typedKeyword: "CLIP",
            queryAtEntry: "notes and tasks"
        ))
        #expect(result.query == "notes and tasks")
    }

    @Test func tabWhileAlreadyInClipboardModeIsANoOp() {
        let mode = clipboardContext(typedKeyword: "clip", queryAtEntry: "test")
        let result = transition(from: mode, query: "test", event: .tab)

        #expect(result.mode == mode)
        #expect(result.query == "test")
    }

    // MARK: - Exiting clipboard mode

    @Test func escapeExitsClipboardModeReconstructingTheTypedSpelling() {
        let mode = clipboardContext(typedKeyword: "clip", queryAtEntry: "invoice")
        let result = transition(from: mode, query: "invoice", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "clip invoice")
    }

    @Test func escapeAfterEditingQueryInClipboardModeReconstructsCanonicalSpelling() {
        let mode = clipboardContext(typedKeyword: "CLIP", queryAtEntry: "invoice")
        let result = transition(from: mode, query: "receipt", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "clip receipt")
    }

    @Test func escapeOnBareClipModeReconstructsJustTheKeyword() {
        let mode = clipboardContext(typedKeyword: "clip", queryAtEntry: "")
        let result = transition(from: mode, query: "", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "clip")
    }

    @Test(arguments: [SearchModeEvent.shiftTab, .backspaceOnEmptyQuery])
    func shiftTabAndBackspaceOnEmptyExitClipboardModeExactlyLikeEscape(event: SearchModeEvent) {
        let mode = clipboardContext(typedKeyword: "clip", queryAtEntry: "address")
        let result = transition(from: mode, query: "address", event: event)
        #expect(result.mode == .local, "\(event)")
        #expect(result.query == "clip address", "\(event)")
    }

    @Test func tabThenEscapeRoundTripsTheOriginalFieldInClipboardMode() {
        let entered = transition(from: .local, query: "clip invoice", event: .tab)
        let exited = transition(from: entered.mode, query: entered.query, event: .escape)

        #expect(exited.mode == .local)
        #expect(exited.query == "clip invoice")
    }

    @Test func resetExitsClipboardModeToEmptyLocal() {
        let fromClip = transition(
            from: clipboardContext(typedKeyword: "clip", queryAtEntry: "test"),
            query: "test",
            event: .reset
        )
        #expect(fromClip.mode == .local)
        #expect(fromClip.query.isEmpty)
    }

    // MARK: - Entering web mode with Tab

    @Test func tabOnAPlainQueryEntersDefaultEngineModeCarryingTheQuery() {
        let result = transition(from: .local, query: "swift concurrency", event: .tab)

        #expect(result.mode == webContext(engineID: "google", queryAtEntry: "swift concurrency"))
        #expect(result.query == "swift concurrency")
    }

    @Test func tabOnAnEmptyQueryEntersDefaultEngineModeWithoutFiringAnything() {
        let result = transition(from: .local, query: "", event: .tab)

        #expect(result.mode == webContext(engineID: "google", queryAtEntry: ""))
        #expect(result.query.isEmpty)
    }

    @Test func tabAfterAKeywordCompletesIntoThatEngineAbsorbingTheKeyword() {
        let result = transition(from: .local, query: "yt lofi", event: .tab)

        #expect(result.mode == webContext(
            engineID: "youtube",
            typedKeyword: "yt",
            queryAtEntry: "lofi"
        ))
        #expect(result.query == "lofi")
    }

    @Test func tabOnABareKeywordEntersThatEngineWithAnEmptyQuery() {
        let result = transition(from: .local, query: "yt", event: .tab)

        #expect(result.mode == webContext(
            engineID: "youtube",
            typedKeyword: "yt",
            queryAtEntry: ""
        ))
        #expect(result.query.isEmpty)
    }

    @Test func tabHonoursFullWordAndBangSpellings() {
        let fullWord = transition(from: .local, query: "youtube lofi", event: .tab)
        #expect(fullWord.mode == webContext(
            engineID: "youtube",
            typedKeyword: "youtube",
            queryAtEntry: "lofi"
        ))

        let bang = transition(from: .local, query: "!yt lofi", event: .tab)
        #expect(bang.mode == webContext(
            engineID: "youtube",
            typedKeyword: "!yt",
            queryAtEntry: "lofi"
        ))
    }

    @Test func tabMatchesKeywordsCaseInsensitivelyButRemembersTheTypedSpelling() {
        let result = transition(from: .local, query: "YT lofi", event: .tab)

        #expect(result.mode == webContext(
            engineID: "youtube",
            typedKeyword: "YT",
            queryAtEntry: "lofi"
        ))
        #expect(result.query == "lofi")
    }

    @Test func tabAfterAnAssistantKeywordFallsThroughToTheDefaultEngine() {
        // "claude …" + Tab behaves as plain-query Tab until #27 decides
        // otherwise: Google mode carrying the full typed text.
        let result = transition(from: .local, query: "claude explain this", event: .tab)

        #expect(result.mode == webContext(engineID: "google", queryAtEntry: "claude explain this"))
        #expect(result.query == "claude explain this")
    }

    @Test func tabWhileAlreadyInWebModeIsANoOp() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .tab)

        #expect(result.mode == mode)
        #expect(result.query == "lofi")
    }

    @Test func tabPreservesTheRemainderWhitespaceConventionsOfKeywordMatching() {
        let result = transition(from: .local, query: "yt   lofi hip hop  ", event: .tab)

        #expect(result.query == "lofi hip hop")
        #expect(result.mode == webContext(
            engineID: "youtube",
            typedKeyword: "yt",
            queryAtEntry: "lofi hip hop"
        ))
    }

    // MARK: - Exiting web mode

    @Test func escapeExitsAKeywordEnteredModeReconstructingTheTypedSpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "yt lofi")
    }

    @Test func escapeAfterEditingTheQueryReconstructsThePrimarySpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "YouTube", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "jazz", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "yt jazz")
    }

    @Test func escapeWithAnUneditedQueryKeepsTheBangSpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "!yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .escape)

        #expect(result.query == "!yt lofi")
    }

    @Test func escapeExitsAPlainTabModeLeavingTheQueryUntouched() {
        let mode = webContext(engineID: "google", queryAtEntry: "swift concurrency")
        let result = transition(from: mode, query: "swift concurrency", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "swift concurrency")
    }

    @Test func exitingABareKeywordModeReconstructsJustTheKeyword() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "")
        let result = transition(from: mode, query: "", event: .escape)

        #expect(result.mode == .local)
        #expect(result.query == "yt")
    }

    @Test(arguments: [SearchModeEvent.shiftTab, .backspaceOnEmptyQuery])
    func shiftTabAndBackspaceOnEmptyExitExactlyLikeEscape(event: SearchModeEvent) {
        let mode = webContext(engineID: "github", typedKeyword: "gh", queryAtEntry: "swift")
        let result = transition(from: mode, query: "swift", event: event)
        #expect(result.mode == .local, "\(event)")
        #expect(result.query == "gh swift", "\(event)")
    }

    @Test func tabThenEscapeRoundTripsTheOriginalField() {
        let entered = transition(from: .local, query: "yt lofi", event: .tab)
        let exited = transition(from: entered.mode, query: entered.query, event: .escape)

        #expect(exited.mode == .local)
        #expect(exited.query == "yt lofi")

        // And Tab again re-enters the *same* engine, not Google.
        let reentered = transition(from: exited.mode, query: exited.query, event: .tab)
        #expect(reentered.mode == webContext(
            engineID: "youtube",
            typedKeyword: "yt",
            queryAtEntry: "lofi"
        ))
    }

    // MARK: - Events that don't apply

    @Test(arguments: [SearchModeEvent.escape, .shiftTab, .backspaceOnEmptyQuery])
    func exitEventsInLocalModeAreIdentity(event: SearchModeEvent) {
        let result = transition(from: .local, query: "notes", event: event)
        #expect(result.mode == .local, "\(event)")
        #expect(result.query == "notes", "\(event)")
    }

    // MARK: - Reset

    @Test func resetReturnsToLocalModeWithAnEmptyQueryFromAnywhere() {
        let fromWeb = transition(
            from: webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi"),
            query: "lofi",
            event: .reset
        )
        #expect(fromWeb.mode == .local)
        #expect(fromWeb.query.isEmpty)

        let fromLocal = transition(from: .local, query: "notes", event: .reset)
        #expect(fromLocal.mode == .local)
        #expect(fromLocal.query.isEmpty)
    }

    // MARK: - Injected engine tables

    @Test func transitionConsultsOnlyURLEnginesFromTheSuppliedTable() {
        let custom = KeywordEngine(
            id: "example",
            title: "Search Example",
            name: "Example",
            tint: .blue,
            keywords: ["ex"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/?q={query}")
        )

        let matched = SearchMode.transition(
            from: .local,
            query: "ex thing",
            event: .tab,
            registry: KeywordEngineRegistry(engines: [custom], defaultWebEngineID: custom.id)
        )
        #expect(matched.mode == webContext(
            engineID: "example",
            typedKeyword: "ex",
            queryAtEntry: "thing"
        ))

        // The shipping table's keywords aren't in the injected table, so
        // they fall through to the default engine like any plain query.
        let unmatched = SearchMode.transition(
            from: .local,
            query: "yt lofi",
            event: .tab,
            registry: KeywordEngineRegistry(engines: [custom], defaultWebEngineID: custom.id)
        )
        #expect(unmatched.mode == webContext(engineID: "example", queryAtEntry: "yt lofi"))
    }
}
