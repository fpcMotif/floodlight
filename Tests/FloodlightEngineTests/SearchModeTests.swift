import XCTest
@testable import FloodlightEngine

/// The Tab↔Esc state machine, exercised the same way `WebSearchIntentTests`
/// exercises promotion: pure inputs in, (mode, query) out, no coordinator.
final class SearchModeTests: XCTestCase {
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

    // MARK: - Entering web mode with Tab

    func testTabOnAPlainQueryEntersDefaultEngineModeCarryingTheQuery() {
        let result = transition(from: .local, query: "swift concurrency", event: .tab)

        XCTAssertEqual(
            result.mode,
            webContext(engineID: "google", queryAtEntry: "swift concurrency")
        )
        XCTAssertEqual(result.query, "swift concurrency")
    }

    func testTabOnAnEmptyQueryEntersDefaultEngineModeWithoutFiringAnything() {
        let result = transition(from: .local, query: "", event: .tab)

        XCTAssertEqual(result.mode, webContext(engineID: "google", queryAtEntry: ""))
        XCTAssertEqual(result.query, "")
    }

    func testTabAfterAKeywordCompletesIntoThatEngineAbsorbingTheKeyword() {
        let result = transition(from: .local, query: "yt lofi", event: .tab)

        XCTAssertEqual(
            result.mode,
            webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        )
        XCTAssertEqual(result.query, "lofi")
    }

    func testTabOnABareKeywordEntersThatEngineWithAnEmptyQuery() {
        let result = transition(from: .local, query: "yt", event: .tab)

        XCTAssertEqual(
            result.mode,
            webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "")
        )
        XCTAssertEqual(result.query, "")
    }

    func testTabHonoursFullWordAndBangSpellings() {
        let fullWord = transition(from: .local, query: "youtube lofi", event: .tab)
        XCTAssertEqual(
            fullWord.mode,
            webContext(engineID: "youtube", typedKeyword: "youtube", queryAtEntry: "lofi")
        )

        let bang = transition(from: .local, query: "!yt lofi", event: .tab)
        XCTAssertEqual(
            bang.mode,
            webContext(engineID: "youtube", typedKeyword: "!yt", queryAtEntry: "lofi")
        )
    }

    func testTabMatchesKeywordsCaseInsensitivelyButRemembersTheTypedSpelling() {
        let result = transition(from: .local, query: "YT lofi", event: .tab)

        XCTAssertEqual(
            result.mode,
            webContext(engineID: "youtube", typedKeyword: "YT", queryAtEntry: "lofi")
        )
        XCTAssertEqual(result.query, "lofi")
    }

    func testTabAfterAnAssistantKeywordFallsThroughToTheDefaultEngine() {
        // "claude …" + Tab behaves as plain-query Tab until #27 decides
        // otherwise: Google mode carrying the full typed text.
        let result = transition(from: .local, query: "claude explain this", event: .tab)

        XCTAssertEqual(
            result.mode,
            webContext(engineID: "google", queryAtEntry: "claude explain this")
        )
        XCTAssertEqual(result.query, "claude explain this")
    }

    func testTabWhileAlreadyInWebModeIsANoOp() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .tab)

        XCTAssertEqual(result.mode, mode)
        XCTAssertEqual(result.query, "lofi")
    }

    func testTabPreservesTheRemainderWhitespaceConventionsOfKeywordMatching() {
        let result = transition(from: .local, query: "yt   lofi hip hop  ", event: .tab)

        XCTAssertEqual(result.query, "lofi hip hop")
        XCTAssertEqual(
            result.mode,
            webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi hip hop")
        )
    }

    // MARK: - Exiting web mode

    func testEscapeExitsAKeywordEnteredModeReconstructingTheTypedSpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .escape)

        XCTAssertEqual(result.mode, .local)
        XCTAssertEqual(result.query, "yt lofi")
    }

    func testEscapeAfterEditingTheQueryReconstructsThePrimarySpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "YouTube", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "jazz", event: .escape)

        XCTAssertEqual(result.mode, .local)
        XCTAssertEqual(result.query, "yt jazz")
    }

    func testEscapeWithAnUneditedQueryKeepsTheBangSpelling() {
        let mode = webContext(engineID: "youtube", typedKeyword: "!yt", queryAtEntry: "lofi")
        let result = transition(from: mode, query: "lofi", event: .escape)

        XCTAssertEqual(result.query, "!yt lofi")
    }

    func testEscapeExitsAPlainTabModeLeavingTheQueryUntouched() {
        let mode = webContext(engineID: "google", queryAtEntry: "swift concurrency")
        let result = transition(from: mode, query: "swift concurrency", event: .escape)

        XCTAssertEqual(result.mode, .local)
        XCTAssertEqual(result.query, "swift concurrency")
    }

    func testExitingABareKeywordModeReconstructsJustTheKeyword() {
        let mode = webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "")
        let result = transition(from: mode, query: "", event: .escape)

        XCTAssertEqual(result.mode, .local)
        XCTAssertEqual(result.query, "yt")
    }

    func testShiftTabAndBackspaceOnEmptyExitExactlyLikeEscape() {
        let mode = webContext(engineID: "github", typedKeyword: "gh", queryAtEntry: "swift")

        for event in [SearchModeEvent.shiftTab, .backspaceOnEmptyQuery] {
            let result = transition(from: mode, query: "swift", event: event)
            XCTAssertEqual(result.mode, .local, "\(event)")
            XCTAssertEqual(result.query, "gh swift", "\(event)")
        }
    }

    func testTabThenEscapeRoundTripsTheOriginalField() {
        let entered = transition(from: .local, query: "yt lofi", event: .tab)
        let exited = transition(from: entered.mode, query: entered.query, event: .escape)

        XCTAssertEqual(exited.mode, .local)
        XCTAssertEqual(exited.query, "yt lofi")

        // And Tab again re-enters the *same* engine, not Google.
        let reentered = transition(from: exited.mode, query: exited.query, event: .tab)
        XCTAssertEqual(
            reentered.mode,
            webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi")
        )
    }

    // MARK: - Events that don't apply

    func testExitEventsInLocalModeAreIdentity() {
        for event in [SearchModeEvent.escape, .shiftTab, .backspaceOnEmptyQuery] {
            let result = transition(from: .local, query: "notes", event: event)
            XCTAssertEqual(result.mode, .local, "\(event)")
            XCTAssertEqual(result.query, "notes", "\(event)")
        }
    }

    // MARK: - Reset

    func testResetReturnsToLocalModeWithAnEmptyQueryFromAnywhere() {
        let fromWeb = transition(
            from: webContext(engineID: "youtube", typedKeyword: "yt", queryAtEntry: "lofi"),
            query: "lofi",
            event: .reset
        )
        XCTAssertEqual(fromWeb.mode, .local)
        XCTAssertEqual(fromWeb.query, "")

        let fromLocal = transition(from: .local, query: "notes", event: .reset)
        XCTAssertEqual(fromLocal.mode, .local)
        XCTAssertEqual(fromLocal.query, "")
    }

    // MARK: - Injected engine tables

    func testTransitionConsultsOnlyURLEnginesFromTheSuppliedTable() {
        let custom = KeywordEngine(
            id: "example",
            title: "Search Example",
            keywords: ["ex"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/?q={query}")
        )

        let matched = SearchMode.transition(
            from: .local,
            query: "ex thing",
            event: .tab,
            engines: [custom]
        )
        XCTAssertEqual(
            matched.mode,
            webContext(engineID: "example", typedKeyword: "ex", queryAtEntry: "thing")
        )

        // The shipping table's keywords aren't in the injected table, so
        // they fall through to the default engine like any plain query.
        let unmatched = SearchMode.transition(
            from: .local,
            query: "yt lofi",
            event: .tab,
            engines: [custom]
        )
        XCTAssertEqual(
            unmatched.mode,
            webContext(engineID: "google", queryAtEntry: "yt lofi")
        )
    }
}
