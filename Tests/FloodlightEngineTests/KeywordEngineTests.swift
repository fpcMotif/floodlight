import XCTest
@testable import FloodlightEngine

final class KeywordEngineTests: XCTestCase {
    private let catalogRegistry = KeywordEngineRegistry(
        engines: KeywordEngineCatalog.all,
        defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
    )

    func testRegistryBuildsTheAddressedResultWithoutExposingLookupStorage() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let shortAlias = try XCTUnwrap(registry.addressedResult(for: "YT lofi hip hop"))
        let bangAlias = try XCTUnwrap(registry.addressedResult(for: "!yt lofi hip hop"))

        XCTAssertEqual(shortAlias.id, "keyword-engine:youtube")
        XCTAssertEqual(bangAlias, shortAlias)
        XCTAssertNil(registry.addressedResult(for: "yt"))
        XCTAssertNil(registry.addressedResult(for: "lofi yt"))
    }

    func testRegistryKeepsTheFirstDestinationForACollidingKeyword() throws {
        let first = KeywordEngine(
            id: "first",
            title: "First",
            name: "First",
            tint: .blue,
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://first.example/?q={query}")
        )
        let second = KeywordEngine(
            id: "second",
            title: "Second",
            name: "Second",
            tint: .blue,
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://second.example/?q={query}")
        )
        let registry = KeywordEngineRegistry(
            engines: [first, second],
            defaultWebEngineID: first.id
        )

        let result = try XCTUnwrap(registry.addressedResult(for: "DUP value"))
        XCTAssertEqual(result.id, "keyword-engine:first")
    }

    func testWebModeCollisionResolutionConsidersOnlyWebDestinations() throws {
        let assistant = KeywordEngine(
            id: "assistant",
            title: "Ask Assistant",
            name: "Assistant",
            tint: .purple,
            keywords: ["go"],
            kind: .assistant,
            destination: .assistant(command: "assistant", baseArguments: [])
        )
        let web = KeywordEngine(
            id: "web",
            title: "Search Web",
            name: "Web",
            tint: .blue,
            keywords: ["go"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/?q={query}")
        )
        let registry = KeywordEngineRegistry(
            engines: [assistant, web],
            defaultWebEngineID: web.id
        )

        XCTAssertEqual(registry.addressedResult(for: "go query")?.id, "keyword-engine:assistant")
        XCTAssertEqual(try XCTUnwrap(registry.webModeAddress(for: "go query")).engineID, "web")
    }

    func testRegistryResolvesWebModeEntryButNeverCompletesAnAssistantKeyword() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let addressed = try XCTUnwrap(registry.webModeAddress(for: "YouTube  lofi "))
        XCTAssertEqual(addressed.engineID, "youtube")
        XCTAssertEqual(addressed.typedKeyword, "YouTube")
        XCTAssertEqual(addressed.remainder, "lofi")

        let bare = try XCTUnwrap(registry.webModeAddress(for: "!yt"))
        XCTAssertEqual(bare.engineID, "youtube")
        XCTAssertEqual(bare.remainder, "")

        XCTAssertNil(registry.webModeAddress(for: "claude explain this"))
    }

    func testRegistryBuildsTheConfiguredDefaultWebResult() throws {
        let example = KeywordEngine(
            id: "example",
            title: "Search Example",
            name: "Example",
            tint: .blue,
            keywords: ["ex"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/?q={query}")
        )
        let registry = KeywordEngineRegistry(engines: [example], defaultWebEngineID: example.id)

        let result = try XCTUnwrap(
            registry.defaultWebResult(for: "swift concurrency", promoted: true)
        )
        XCTAssertEqual(result.id, "web-search")
        XCTAssertEqual(result.score, SearchItemRanking.webPromoted)
        XCTAssertEqual(
            result.action,
            try .open(XCTUnwrap(URL(string: "https://example.com/?q=swift%20concurrency")))
        )
    }

    func testRegistryBuildsActiveFirstWebModeRowsInCatalogueOrder() {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let rows = registry.webModeResults(for: "swift", activeEngineID: "youtube")

        XCTAssertEqual(rows.first?.id, "web-mode:youtube")
        XCTAssertEqual(rows.count, 6)
        XCTAssertFalse(rows.contains { $0.kind == .assistant })
        XCTAssertEqual(rows.dropFirst().map(\.id), [
            "web-mode:google",
            "web-mode:wikipedia",
            "web-mode:github",
            "web-mode:stackoverflow",
            "web-mode:twitter",
        ])
    }

    func testRegistryAnswersModeAndTabPresentationQuestions() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
        let addressedResult = try XCTUnwrap(registry.addressedResult(for: "yt lofi"))

        XCTAssertEqual(registry.defaultWebEngineID, "google")
        XCTAssertEqual(registry.webEngine(id: "youtube")?.title, "Search YouTube")
        XCTAssertNil(registry.webEngine(id: "claude"))
        XCTAssertEqual(registry.canonicalKeyword(for: "youtube"), "yt")
        XCTAssertEqual(
            registry.tabCompletionTitle(for: "yt lofi", resultID: addressedResult.id),
            "Search YouTube"
        )
        XCTAssertNil(registry.tabCompletionTitle(
            for: "claude explain",
            resultID: "keyword-engine:claude"
        ))
        XCTAssertNil(registry.tabCompletionTitle(for: "yt lofi", resultID: "some-other-row"))
    }

    func testCatalogPublishesOnlyUsableDestinationsInResolvedRegistry() async {
        let initial = KeywordEngineCatalog.initialRegistry
        XCTAssertNil(initial.addressedResult(for: "claude explain this"))
        XCTAssertNotNil(initial.addressedResult(for: "yt lofi"))

        let runner = StubAssistantProcessRunner(availableCommands: ["claude"])
        let resolved = await KeywordEngineCatalog.availableRegistry(runner: runner)
        XCTAssertNotNil(resolved.addressedResult(for: "claude explain this"))
        XCTAssertNil(resolved.addressedResult(for: "codex explain this"))
    }

    func testEveryShippingEngineDerivesItsHostFromItsURLTemplate() {
        let expected: [String: String] = [
            "google": "google.com",
            "youtube": "youtube.com",
            "wikipedia": "en.wikipedia.org",
            "github": "github.com",
            "stackoverflow": "stackoverflow.com",
            "twitter": "x.com",
        ]
        for engine in KeywordEngineCatalog.all {
            switch engine.destination {
            case .webSearch:
                XCTAssertEqual(engine.host, expected[engine.id], engine.id)
            case .assistant:
                XCTAssertNil(engine.host, "\(engine.id): an assistant has no host to name")
            }
        }
    }

    func testWebRowsNameTheDestinationAndCarryItsIconAndHost() throws {
        let addressed = try XCTUnwrap(catalogRegistry.addressedResult(for: "yt lofi"))
        XCTAssertEqual(addressed.title, "YouTube")
        XCTAssertEqual(addressed.subtitle, "youtube.com")
        XCTAssertEqual(
            addressed.iconSource,
            .engine(symbol: "play.rectangle.fill", tint: .red)
        )

        let fallback = try XCTUnwrap(
            catalogRegistry.defaultWebResult(for: "lofi", promoted: false)
        )
        XCTAssertEqual(fallback.title, "Google")
        XCTAssertEqual(fallback.subtitle, "google.com")
        XCTAssertEqual(
            fallback.iconSource,
            .engine(symbol: "magnifyingglass", tint: .blue)
        )

        let modeRows = catalogRegistry.webModeResults(for: "lofi", activeEngineID: "google")
        XCTAssertEqual(modeRows.map(\.title), [
            "Google", "Wikipedia", "GitHub", "Stack Overflow", "Twitter/X", "YouTube",
        ])
        XCTAssertEqual(modeRows.map(\.subtitle), [
            "google.com", "en.wikipedia.org", "github.com", "stackoverflow.com", "x.com",
            "youtube.com",
        ])
        XCTAssertTrue(modeRows.allSatisfy {
            if case .engine = $0.iconSource { true } else { false }
        })
    }

    private func searchCatalog(_ query: String) -> [SearchItem] {
        catalogRegistry.addressedResult(for: query).map { [$0] } ?? []
    }

    func testKeywordMustBeTheFirstWord() {
        XCTAssertNotNil(catalogRegistry.addressedResult(for: "yt lofi"))
        XCTAssertNil(catalogRegistry.addressedResult(for: "lofi yt"))
    }

    func testKeywordMatchingIsCaseInsensitive() {
        XCTAssertNotNil(catalogRegistry.addressedResult(for: "YT lofi"))
        XCTAssertNotNil(catalogRegistry.addressedResult(for: "Yt Lofi"))
    }

    func testBangAliasesMatchTheSameEngineAsTheWordKeyword() throws {
        let word = try XCTUnwrap(catalogRegistry.addressedResult(for: "yt lofi"))
        let bang = try XCTUnwrap(catalogRegistry.addressedResult(for: "!yt lofi"))
        XCTAssertEqual(word.id, bang.id)
    }

    func testFullWordAliasMatchesTheSameEngineAsTheShortKeyword() throws {
        let short = try XCTUnwrap(catalogRegistry.addressedResult(for: "x election"))
        let long = try XCTUnwrap(catalogRegistry.addressedResult(for: "twitter election"))
        XCTAssertEqual(short.id, long.id)
    }

    func testKeywordIsAWholeWordNotAPrefix() {
        XCTAssertNil(catalogRegistry.addressedResult(for: "ytlofi lofi"))
    }

    func testBareKeywordWithNoRemainderDoesNotMatch() {
        XCTAssertNil(catalogRegistry.addressedResult(for: "yt"))
        XCTAssertNil(catalogRegistry.addressedResult(for: "yt   "))
    }

    func testUnknownKeywordDoesNotMatch() {
        XCTAssertNil(catalogRegistry.addressedResult(for: "zz lofi"))
    }

    func testRemainderIsTrimmedAndPreservesInternalSpacing() throws {
        let result = try XCTUnwrap(catalogRegistry.addressedResult(for: "yt   lofi hip hop  "))
        guard case let .open(url) = result.action else {
            return XCTFail("expected an .open action")
        }
        XCTAssertEqual(url.query, "search_query=lofi%20hip%20hop")
    }

    func testSearchBuildsAWebSearchItemForTwitter() throws {
        let items = searchCatalog("x floodlight app")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.kind, .web)
        XCTAssertEqual(item.score, SearchItemRanking.keywordEngine)
        guard case let .open(url) = item.action else {
            return XCTFail("expected an .open action")
        }
        XCTAssertEqual(url.absoluteString, "https://x.com/search?q=floodlight%20app")
    }

    func testSearchBuildsAWebSearchItemForYouTube() throws {
        let items = searchCatalog("yt lofi hip hop")
        let item = try XCTUnwrap(items.first)

        guard case let .open(url) = item.action else {
            return XCTFail("expected an .open action")
        }
        XCTAssertEqual(
            url.absoluteString,
            "https://www.youtube.com/results?search_query=lofi%20hip%20hop"
        )
    }

    func testSearchBuildsAnAssistantSearchItemForClaude() throws {
        let items = searchCatalog("claude explain this function")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.kind, .assistant)
        XCTAssertEqual(item.score, SearchItemRanking.keywordEngine)
        XCTAssertEqual(
            item.action,
            .askAssistant(command: "claude", arguments: ["-p", "--", "explain this function"])
        )
    }

    func testSearchBuildsAnAssistantSearchItemForCodex() throws {
        let items = searchCatalog("codex fix the flaky test")
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(
            item.action,
            .askAssistant(command: "codex", arguments: ["exec", "--", "fix the flaky test"])
        )
    }

    func testSearchReturnsNothingForAnUnmatchedQuery() {
        XCTAssertTrue(searchCatalog("budget report").isEmpty)
    }

    /// The query text always travels to the CLI as a single, discrete
    /// argument — never folded into a shell string — so quotes and shell
    /// metacharacters in the query can't do anything unexpected.
    func testQueryTextTravelsAsAPlainArgumentRegardlessOfShellMetacharacters() throws {
        let items = searchCatalog("claude `rm -rf ~` && echo pwned")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(
            item.action,
            .askAssistant(
                command: "claude",
                arguments: ["-p", "--", "`rm -rf ~` && echo pwned"]
            )
        )
    }

    func testSearchRespectsTheSuppliedEngineList() {
        let registry = KeywordEngineRegistry(
            engines: [KeywordEngineCatalog.defaultEngine],
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
        XCTAssertNil(registry.addressedResult(for: "yt lofi"))
    }

    func testAvailableEnginesAlwaysIncludesWebSearchEngines() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        XCTAssertNotNil(available.addressedResult(for: "twitter floodlight"))
        XCTAssertNotNil(available.addressedResult(for: "youtube floodlight"))
    }

    func testAvailableEnginesDropsAssistantEnginesWithNoInstalledBinary() async {
        let runner = StubAssistantProcessRunner(availableCommands: ["claude"])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        XCTAssertNotNil(available.addressedResult(for: "claude explain this"))
        XCTAssertNil(available.addressedResult(for: "codex explain this"))
    }

    func testAvailableEnginesIsEmptyOfAssistantsWhenNothingIsInstalled() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        XCTAssertNil(available.addressedResult(for: "claude explain this"))
        XCTAssertNil(available.addressedResult(for: "codex explain this"))
    }

    // MARK: - Preset web engines (#29)

    func testEveryPresetEngineBuildsItsExpectedSearchURL() throws {
        let expectations: [(query: String, url: String)] = [
            ("g swift concurrency", "https://www.google.com/search?q=swift%20concurrency"),
            (
                "wiki alan turing",
                "https://en.wikipedia.org/wiki/Special:Search?search=alan%20turing"
            ),
            ("gh swift-testing", "https://github.com/search?q=swift-testing"),
            ("so nsurlsession retry", "https://stackoverflow.com/search?q=nsurlsession%20retry"),
        ]

        for (query, expected) in expectations {
            let item = try XCTUnwrap(searchCatalog(query).first, query)
            XCTAssertEqual(item.kind, .web, query)
            guard case let .open(url) = item.action else {
                return XCTFail("expected an .open action for \(query)")
            }
            XCTAssertEqual(url.absoluteString, expected, query)
        }
    }

    func testEveryPresetKeywordSpellingAddressesItsEngine() {
        let spellings: [(keyword: String, engineID: String)] = [
            ("g", "google"), ("google", "google"), ("!g", "google"),
            ("wiki", "wikipedia"), ("wikipedia", "wikipedia"), ("!wiki", "wikipedia"),
            ("gh", "github"), ("github", "github"), ("!gh", "github"),
            ("so", "stackoverflow"), ("stackoverflow", "stackoverflow"), ("!so", "stackoverflow"),
        ]

        for (keyword, engineID) in spellings {
            XCTAssertEqual(
                catalogRegistry.addressedResult(for: "\(keyword) anything")?.id,
                "keyword-engine:\(engineID)",
                keyword
            )
        }
    }

    func testThereIsDeliberatelyNoSingleLetterWikipediaKeyword() {
        // Rejected during grilling for its accidental first-word hit rate.
        XCTAssertNil(catalogRegistry.addressedResult(for: "w hidden files"))
    }

    func testTheDefaultEngineIsGoogleAndComesFromTheTable() {
        XCTAssertEqual(KeywordEngineCatalog.defaultEngine.id, "google")
        XCTAssertTrue(KeywordEngineCatalog.all
            .contains { $0.id == KeywordEngineCatalog.defaultEngine.id })
    }

    func testWebSearchEnginesListsOnlyURLEnginesInTableOrder() {
        let rows = catalogRegistry.webModeResults(for: "query", activeEngineID: "google")
        XCTAssertEqual(
            rows.map(\.id),
            [
                "web-mode:google",
                "web-mode:wikipedia",
                "web-mode:github",
                "web-mode:stackoverflow",
                "web-mode:twitter",
                "web-mode:youtube",
            ]
        )
        XCTAssertTrue(rows.allSatisfy { $0.kind == .web })
    }

    func testSearchURLPercentEncodesSpacesAndReservedCharacters() throws {
        let url = try XCTUnwrap(
            KeywordEngineCatalog.defaultEngine.searchURL(for: "café & crème #1")
        )
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertNil(url.fragment, "a '#' in the query must never become a fragment")
    }

    /// The table-integrity requirement from the spec's Testing Decisions —
    /// "each preset engine yields a well-formed URL for a query containing
    /// spaces and reserved characters" — for every URL engine, not just the
    /// default one `testSearchURLPercentEncodesSpacesAndReservedCharacters`
    /// already covers.
    func testEveryURLEngineProducesAWellFormedURLForSpacesAndReservedCharacters() throws {
        let query = "café & crème #1/2?"
        for engine in KeywordEngineCatalog.all where engine.kind == .web {
            let url = try XCTUnwrap(engine.searchURL(for: query), engine.id)
            XCTAssertFalse(url.absoluteString.contains(" "), engine.id)
            XCTAssertNil(url.fragment, "'#' must never become a fragment: \(engine.id)")
            XCTAssertNotNil(url.host, engine.id)
        }
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
