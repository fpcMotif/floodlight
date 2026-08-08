import XCTest
@testable import FloodlightEngine

final class KeywordEngineTests: XCTestCase {
    func testKeywordMustBeTheFirstWord() {
        XCTAssertNotNil(KeywordEngineCatalog.match("yt lofi"))
        XCTAssertNil(KeywordEngineCatalog.match("lofi yt"))
    }

    func testKeywordMatchingIsCaseInsensitive() {
        XCTAssertNotNil(KeywordEngineCatalog.match("YT lofi"))
        XCTAssertNotNil(KeywordEngineCatalog.match("Yt Lofi"))
    }

    func testBangAliasesMatchTheSameEngineAsTheWordKeyword() throws {
        let word = try XCTUnwrap(KeywordEngineCatalog.match("yt lofi"))
        let bang = try XCTUnwrap(KeywordEngineCatalog.match("!yt lofi"))
        XCTAssertEqual(word.engine.id, bang.engine.id)
    }

    func testFullWordAliasMatchesTheSameEngineAsTheShortKeyword() throws {
        let short = try XCTUnwrap(KeywordEngineCatalog.match("x election"))
        let long = try XCTUnwrap(KeywordEngineCatalog.match("twitter election"))
        XCTAssertEqual(short.engine.id, long.engine.id)
    }

    func testKeywordIsAWholeWordNotAPrefix() {
        XCTAssertNil(KeywordEngineCatalog.match("ytlofi lofi"))
    }

    func testBareKeywordWithNoRemainderDoesNotMatch() {
        XCTAssertNil(KeywordEngineCatalog.match("yt"))
        XCTAssertNil(KeywordEngineCatalog.match("yt   "))
    }

    func testUnknownKeywordDoesNotMatch() {
        XCTAssertNil(KeywordEngineCatalog.match("zz lofi"))
    }

    func testRemainderIsTrimmedAndPreservesInternalSpacing() throws {
        let match = try XCTUnwrap(KeywordEngineCatalog.match("yt   lofi hip hop  "))
        XCTAssertEqual(match.remainder, "lofi hip hop")
    }

    func testSearchBuildsAWebSearchItemForTwitter() throws {
        let items = KeywordEngineCatalog.search("x floodlight app")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.kind, .web)
        XCTAssertEqual(item.score, SearchItemRanking.keywordEngine)
        guard case .open(let url) = item.action else {
            return XCTFail("expected an .open action")
        }
        XCTAssertEqual(url.absoluteString, "https://x.com/search?q=floodlight%20app")
    }

    func testSearchBuildsAWebSearchItemForYouTube() throws {
        let items = KeywordEngineCatalog.search("yt lofi hip hop")
        let item = try XCTUnwrap(items.first)

        guard case .open(let url) = item.action else {
            return XCTFail("expected an .open action")
        }
        XCTAssertEqual(url.absoluteString, "https://www.youtube.com/results?search_query=lofi%20hip%20hop")
    }

    func testSearchBuildsAnAssistantSearchItemForClaude() throws {
        let items = KeywordEngineCatalog.search("claude explain this function")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.kind, .assistant)
        XCTAssertEqual(item.score, SearchItemRanking.keywordEngine)
        XCTAssertEqual(item.action, .askAssistant(command: "claude", arguments: ["-p", "explain this function"]))
    }

    func testSearchBuildsAnAssistantSearchItemForCodex() throws {
        let items = KeywordEngineCatalog.search("codex fix the flaky test")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.action, .askAssistant(command: "codex", arguments: ["exec", "fix the flaky test"]))
    }

    func testSearchReturnsNothingForAnUnmatchedQuery() {
        XCTAssertTrue(KeywordEngineCatalog.search("budget report").isEmpty)
    }

    /// The query text always travels to the CLI as a single, discrete
    /// argument — never folded into a shell string — so quotes and shell
    /// metacharacters in the query can't do anything unexpected.
    func testQueryTextTravelsAsAPlainArgumentRegardlessOfShellMetacharacters() throws {
        let items = KeywordEngineCatalog.search("claude `rm -rf ~` && echo pwned")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(
            item.action,
            .askAssistant(command: "claude", arguments: ["-p", "`rm -rf ~` && echo pwned"])
        )
    }

    func testSearchRespectsTheSuppliedEngineList() {
        let items = KeywordEngineCatalog.search("yt lofi", in: [])
        XCTAssertTrue(items.isEmpty)
    }

    func testAvailableEnginesAlwaysIncludesWebSearchEngines() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)

        XCTAssertTrue(available.contains { $0.id == "twitter" })
        XCTAssertTrue(available.contains { $0.id == "youtube" })
    }

    func testAvailableEnginesDropsAssistantEnginesWithNoInstalledBinary() async {
        let runner = StubAssistantProcessRunner(availableCommands: ["claude"])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)

        XCTAssertTrue(available.contains { $0.id == "claude" })
        XCTAssertFalse(available.contains { $0.id == "codex" })
    }

    func testAvailableEnginesIsEmptyOfAssistantsWhenNothingIsInstalled() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)

        XCTAssertFalse(available.contains { $0.kind == .assistant })
    }

    // MARK: - Preset web engines (#29)

    func testEveryPresetEngineBuildsItsExpectedSearchURL() throws {
        let expectations: [(query: String, url: String)] = [
            ("g swift concurrency", "https://www.google.com/search?q=swift%20concurrency"),
            ("ddg swift concurrency", "https://duckduckgo.com/?q=swift%20concurrency"),
            ("wiki alan turing", "https://en.wikipedia.org/wiki/Special:Search?search=alan%20turing"),
            ("gh swift-testing", "https://github.com/search?q=swift-testing"),
            ("so nsurlsession retry", "https://stackoverflow.com/search?q=nsurlsession%20retry"),
        ]

        for (query, expected) in expectations {
            let item = try XCTUnwrap(KeywordEngineCatalog.search(query).first, query)
            XCTAssertEqual(item.kind, .web, query)
            guard case .open(let url) = item.action else {
                return XCTFail("expected an .open action for \(query)")
            }
            XCTAssertEqual(url.absoluteString, expected, query)
        }
    }

    func testEveryPresetKeywordSpellingAddressesItsEngine() {
        let spellings: [(keyword: String, engineID: String)] = [
            ("g", "google"), ("google", "google"), ("!g", "google"),
            ("ddg", "duckduckgo"), ("duckduckgo", "duckduckgo"), ("!ddg", "duckduckgo"),
            ("wiki", "wikipedia"), ("wikipedia", "wikipedia"), ("!wiki", "wikipedia"),
            ("gh", "github"), ("github", "github"), ("!gh", "github"),
            ("so", "stackoverflow"), ("stackoverflow", "stackoverflow"), ("!so", "stackoverflow"),
        ]

        for (keyword, engineID) in spellings {
            XCTAssertEqual(
                KeywordEngineCatalog.match("\(keyword) anything")?.engine.id,
                engineID,
                keyword
            )
        }
    }

    func testThereIsDeliberatelyNoSingleLetterWikipediaKeyword() {
        // Rejected during grilling for its accidental first-word hit rate.
        XCTAssertNil(KeywordEngineCatalog.match("w hidden files"))
    }

    func testTheDefaultEngineIsGoogleAndComesFromTheTable() {
        XCTAssertEqual(KeywordEngineCatalog.defaultEngine.id, "google")
        XCTAssertTrue(KeywordEngineCatalog.all.contains { $0.id == KeywordEngineCatalog.defaultEngine.id })
    }

    func testWebSearchEnginesListsOnlyURLEnginesInTableOrder() {
        let engines = KeywordEngineCatalog.webSearchEngines
        XCTAssertEqual(
            engines.map(\.id),
            ["google", "duckduckgo", "wikipedia", "github", "stackoverflow", "twitter", "youtube"]
        )
        XCTAssertTrue(engines.allSatisfy { engine in
            if case .webSearch = engine.destination { return true }
            return false
        })
    }

    func testSearchURLPercentEncodesSpacesAndReservedCharacters() throws {
        let url = try XCTUnwrap(
            KeywordEngineCatalog.defaultEngine.searchURL(for: "café & crème #1")
        )
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertNil(url.fragment, "a '#' in the query must never become a fragment")
    }

    func testSearchURLForAnAssistantEngineIsNil() throws {
        let claude = try XCTUnwrap(KeywordEngineCatalog.all.first { $0.id == "claude" })
        XCTAssertNil(claude.searchURL(for: "anything"))
    }
}

private struct StubAssistantProcessRunner: AssistantProcessRunning {
    let availableCommands: Set<String>

    func isAvailable(command: String) async -> Bool {
        availableCommands.contains(command)
    }

    func run(command: String, arguments: [String]) async throws -> String {
        ""
    }
}
