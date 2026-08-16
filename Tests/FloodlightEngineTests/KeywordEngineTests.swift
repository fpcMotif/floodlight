import Foundation
import Testing
@testable import FloodlightEngine

struct KeywordEngineTests {
    private let catalogRegistry = KeywordEngineRegistry(
        engines: KeywordEngineCatalog.all,
        defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
    )

    @Test func registryBuildsTheAddressedResultWithoutExposingLookupStorage() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let shortAlias = try #require(registry.addressedResult(for: "YT lofi hip hop"))
        let bangAlias = try #require(registry.addressedResult(for: "!yt lofi hip hop"))

        #expect(shortAlias.id == "keyword-engine:youtube")
        #expect(bangAlias == shortAlias)
        #expect(registry.addressedResult(for: "yt") == nil)
        #expect(registry.addressedResult(for: "lofi yt") == nil)
    }

    @Test func registryKeepsTheFirstDestinationForACollidingKeyword() throws {
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

        let result = try #require(registry.addressedResult(for: "DUP value"))
        #expect(result.id == "keyword-engine:first")
    }

    @Test func webModeCollisionResolutionConsidersOnlyWebDestinations() throws {
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

        #expect(registry.addressedResult(for: "go query")?.id == "keyword-engine:assistant")
        #expect(try #require(registry.webModeAddress(for: "go query")).engineID == "web")
    }

    @Test func registryResolvesWebModeEntryButNeverCompletesAnAssistantKeyword() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let addressed = try #require(registry.webModeAddress(for: "YouTube  lofi "))
        #expect(addressed.engineID == "youtube")
        #expect(addressed.typedKeyword == "YouTube")
        #expect(addressed.remainder == "lofi")

        let bare = try #require(registry.webModeAddress(for: "!yt"))
        #expect(bare.engineID == "youtube")
        #expect(bare.remainder.isEmpty)

        #expect(registry.webModeAddress(for: "claude explain this") == nil)
    }

    @Test func registryBuildsTheConfiguredDefaultWebResult() throws {
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

        let result = try #require(registry.defaultWebResult(for: "swift concurrency"))
        #expect(result.id == "web-search")
        #expect(try result.action == .open(
            #require(URL(string: "https://example.com/?q=swift%20concurrency"))
        ))
    }

    @Test func registryBuildsActiveFirstWebModeRowsInCatalogueOrder() {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )

        let rows = registry.webModeResults(for: "swift", activeEngineID: "youtube")

        #expect(rows.first?.id == "web-mode:youtube")
        #expect(rows.count == 6)
        #expect(!(rows.contains { $0.kind == .assistant }))
        #expect(rows.dropFirst().map(\.id) == [
            "web-mode:google",
            "web-mode:wikipedia",
            "web-mode:github",
            "web-mode:stackoverflow",
            "web-mode:twitter",
        ])
    }

    @Test func registryAnswersModeAndTabPresentationQuestions() throws {
        let registry = KeywordEngineRegistry(
            engines: KeywordEngineCatalog.all,
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
        let addressedResult = try #require(registry.addressedResult(for: "yt lofi"))

        #expect(registry.defaultWebEngineID == "google")
        #expect(registry.webEngine(id: "youtube")?.title == "Search YouTube")
        #expect(registry.webEngine(id: "claude") == nil)
        #expect(registry.canonicalKeyword(for: "youtube") == "yt")
        #expect(registry
            .tabCompletionTitle(for: "yt lofi", resultID: addressedResult.id) == "Search YouTube")
        #expect(registry.tabCompletionTitle(
            for: "claude explain",
            resultID: "keyword-engine:claude"
        ) == nil)
        #expect(registry.tabCompletionTitle(for: "yt lofi", resultID: "some-other-row") == nil)
    }

    @Test func catalogPublishesOnlyUsableDestinationsInResolvedRegistry() async {
        let initial = KeywordEngineCatalog.initialRegistry
        #expect(initial.addressedResult(for: "claude explain this") == nil)
        #expect(initial.addressedResult(for: "yt lofi") != nil)

        let runner = StubAssistantProcessRunner(availableCommands: ["claude"])
        let resolved = await KeywordEngineCatalog.availableRegistry(runner: runner)
        #expect(resolved.addressedResult(for: "claude explain this") != nil)
        #expect(resolved.addressedResult(for: "codex explain this") == nil)
    }

    @Test func everyShippingEngineDerivesItsHostFromItsURLTemplate() {
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
                #expect(engine.host == expected[engine.id], "\(engine.id)")
            case .assistant:
                #expect(engine.host == nil, "\(engine.id): an assistant has no host to name")
            }
        }
    }

    @Test func webRowsNameTheDestinationAndCarryItsIconAndHost() throws {
        let addressed = try #require(catalogRegistry.addressedResult(for: "yt lofi"))
        #expect(addressed.title == "YouTube")
        #expect(addressed.subtitle == "youtube.com")
        #expect(addressed.iconSource == .engine(symbol: "play.rectangle.fill", tint: .red))

        let fallback = try #require(catalogRegistry.defaultWebResult(for: "lofi"))
        #expect(fallback.title == "Google")
        #expect(fallback.subtitle == "google.com")
        #expect(fallback.iconSource == SearchItemIconSource.engine(
            symbol: "g.circle.fill",
            tint: .blue
        ))

        let modeRows = catalogRegistry.webModeResults(for: "lofi", activeEngineID: "google")
        #expect(modeRows.map(\.title) == [
            "Google", "Wikipedia", "GitHub", "Stack Overflow", "Twitter/X", "YouTube",
        ])
        #expect(modeRows.map(\.subtitle) == [
            "google.com", "en.wikipedia.org", "github.com", "stackoverflow.com", "x.com",
            "youtube.com",
        ])
        #expect(modeRows.allSatisfy {
            if case .engine = $0.iconSource { true } else { false }
        })
    }

    private func searchCatalog(_ query: String) -> [SearchItem] {
        catalogRegistry.addressedResult(for: query).map { [$0] } ?? []
    }

    @Test func keywordMustBeTheFirstWord() {
        #expect(catalogRegistry.addressedResult(for: "yt lofi") != nil)
        #expect(catalogRegistry.addressedResult(for: "lofi yt") == nil)
    }

    @Test func keywordMatchingIsCaseInsensitive() {
        #expect(catalogRegistry.addressedResult(for: "YT lofi") != nil)
        #expect(catalogRegistry.addressedResult(for: "Yt Lofi") != nil)
    }

    @Test func bangAliasesMatchTheSameEngineAsTheWordKeyword() throws {
        let word = try #require(catalogRegistry.addressedResult(for: "yt lofi"))
        let bang = try #require(catalogRegistry.addressedResult(for: "!yt lofi"))
        #expect(word.id == bang.id)
    }

    @Test func fullWordAliasMatchesTheSameEngineAsTheShortKeyword() throws {
        let short = try #require(catalogRegistry.addressedResult(for: "x election"))
        let long = try #require(catalogRegistry.addressedResult(for: "twitter election"))
        #expect(short.id == long.id)
    }

    @Test func keywordIsAWholeWordNotAPrefix() {
        #expect(catalogRegistry.addressedResult(for: "ytlofi lofi") == nil)
    }

    @Test func bareKeywordWithNoRemainderDoesNotMatch() {
        #expect(catalogRegistry.addressedResult(for: "yt") == nil)
        #expect(catalogRegistry.addressedResult(for: "yt   ") == nil)
    }

    @Test func unknownKeywordDoesNotMatch() {
        #expect(catalogRegistry.addressedResult(for: "zz lofi") == nil)
    }

    @Test func remainderIsTrimmedAndPreservesInternalSpacing() throws {
        let result = try #require(catalogRegistry.addressedResult(for: "yt   lofi hip hop  "))
        guard case let .open(url) = result.action else {
            Issue.record("expected an .open action")
            return
        }
        #expect(url.query == "search_query=lofi%20hip%20hop")
    }

    @Test func searchBuildsAWebSearchItemForTwitter() throws {
        let items = searchCatalog("x floodlight app")
        let item = try #require(items.first)

        #expect(item.kind == .web)
        #expect(item.score == SearchItemRanking.keywordEngine)
        guard case let .open(url) = item.action else {
            Issue.record("expected an .open action")
            return
        }
        #expect(url.absoluteString == "https://x.com/search?q=floodlight%20app")
    }

    @Test func searchBuildsAWebSearchItemForYouTube() throws {
        let items = searchCatalog("yt lofi hip hop")
        let item = try #require(items.first)

        guard case let .open(url) = item.action else {
            Issue.record("expected an .open action")
            return
        }
        #expect(url
            .absoluteString == "https://www.youtube.com/results?search_query=lofi%20hip%20hop")
    }

    @Test func searchBuildsAnAssistantSearchItemForClaude() throws {
        let items = searchCatalog("claude explain this function")
        let item = try #require(items.first)

        #expect(item.kind == .assistant)
        #expect(item.score == SearchItemRanking.keywordEngine)
        #expect(item.action == .askAssistant(
            command: "claude",
            arguments: ["-p", "--", "explain this function"]
        ))
    }

    @Test func searchBuildsAnAssistantSearchItemForCodex() throws {
        let items = searchCatalog("codex fix the flaky test")
        let item = try #require(items.first)

        #expect(item.action == .askAssistant(
            command: "codex",
            arguments: ["exec", "--", "fix the flaky test"]
        ))
    }

    @Test func searchReturnsNothingForAnUnmatchedQuery() {
        #expect(searchCatalog("budget report").isEmpty)
    }

    /// The query text always travels to the CLI as a single, discrete
    /// argument — never folded into a shell string — so quotes and shell
    /// metacharacters in the query can't do anything unexpected.
    @Test func queryTextTravelsAsAPlainArgumentRegardlessOfShellMetacharacters() throws {
        let items = searchCatalog("claude `rm -rf ~` && echo pwned")
        let item = try #require(items.first)
        #expect(item.action == .askAssistant(
            command: "claude",
            arguments: ["-p", "--", "`rm -rf ~` && echo pwned"]
        ))
    }

    @Test func searchRespectsTheSuppliedEngineList() {
        let registry = KeywordEngineRegistry(
            engines: [KeywordEngineCatalog.defaultEngine],
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
        #expect(registry.addressedResult(for: "yt lofi") == nil)
    }

    @Test func availableEnginesAlwaysIncludesWebSearchEngines() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        #expect(available.addressedResult(for: "twitter floodlight") != nil)
        #expect(available.addressedResult(for: "youtube floodlight") != nil)
    }

    @Test func availableEnginesDropsAssistantEnginesWithNoInstalledBinary() async {
        let runner = StubAssistantProcessRunner(availableCommands: ["claude"])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        #expect(available.addressedResult(for: "claude explain this") != nil)
        #expect(available.addressedResult(for: "codex explain this") == nil)
    }

    @Test func availableEnginesIsEmptyOfAssistantsWhenNothingIsInstalled() async {
        let runner = StubAssistantProcessRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableRegistry(runner: runner)

        #expect(available.addressedResult(for: "claude explain this") == nil)
        #expect(available.addressedResult(for: "codex explain this") == nil)
    }

    // MARK: - Preset web engines (#29)

    @Test func everyPresetEngineBuildsItsExpectedSearchURL() throws {
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
            let item = try #require(searchCatalog(query).first, "\(query)")
            #expect(item.kind == .web, "\(query)")
            guard case let .open(url) = item.action else {
                Issue.record("expected an .open action for \(query)")
                return
            }
            #expect(url.absoluteString == expected, "\(query)")
        }
    }

    @Test func everyPresetKeywordSpellingAddressesItsEngine() {
        let spellings: [(keyword: String, engineID: String)] = [
            ("g", "google"), ("google", "google"), ("!g", "google"),
            ("wiki", "wikipedia"), ("wikipedia", "wikipedia"), ("!wiki", "wikipedia"),
            ("gh", "github"), ("github", "github"), ("!gh", "github"),
            ("so", "stackoverflow"), ("stackoverflow", "stackoverflow"), ("!so", "stackoverflow"),
        ]

        for (keyword, engineID) in spellings {
            #expect(
                catalogRegistry.addressedResult(for: "\(keyword) anything")?
                    .id == "keyword-engine:\(engineID)",
                "\(keyword)"
            )
        }
    }

    @Test func thereIsDeliberatelyNoSingleLetterWikipediaKeyword() {
        // Rejected during grilling for its accidental first-word hit rate.
        #expect(catalogRegistry.addressedResult(for: "w hidden files") == nil)
    }

    @Test func theDefaultEngineIsGoogleAndComesFromTheTable() {
        #expect(KeywordEngineCatalog.defaultEngine.id == "google")
        #expect(KeywordEngineCatalog.all
            .contains { $0.id == KeywordEngineCatalog.defaultEngine.id })
    }

    @Test func webSearchEnginesListsOnlyURLEnginesInTableOrder() {
        let rows = catalogRegistry.webModeResults(for: "query", activeEngineID: "google")
        #expect(rows.map(\.id) == [
            "web-mode:google",
            "web-mode:wikipedia",
            "web-mode:github",
            "web-mode:stackoverflow",
            "web-mode:twitter",
            "web-mode:youtube",
        ])
        #expect(rows.allSatisfy { $0.kind == .web })
    }

    @Test func searchURLPercentEncodesSpacesAndReservedCharacters() throws {
        let url = try #require(KeywordEngineCatalog.defaultEngine.searchURL(for: "café & crème #1"))
        #expect(url.host == "www.google.com")
        #expect(!(url.absoluteString.contains(" ")))
        #expect(url.fragment == nil, "a '#' in the query must never become a fragment")
    }

    /// The table-integrity requirement from the spec's Testing Decisions —
    /// "each preset engine yields a well-formed URL for a query containing
    /// spaces and reserved characters" — for every URL engine, not just the
    /// default one `testSearchURLPercentEncodesSpacesAndReservedCharacters`
    /// already covers.
    @Test func everyURLEngineProducesAWellFormedURLForSpacesAndReservedCharacters() throws {
        let query = "café & crème #1/2?"
        for engine in KeywordEngineCatalog.all where engine.kind == .web {
            let url = try #require(engine.searchURL(for: query), "\(engine.id)")
            #expect(!(url.absoluteString.contains(" ")), "\(engine.id)")
            #expect(url.fragment == nil, "'#' must never become a fragment: \(engine.id)")
            #expect(url.host != nil, "\(engine.id)")
        }
    }

    @Test func searchURLForAnAssistantEngineIsNil() throws {
        let claude = try #require(KeywordEngineCatalog.all.first { $0.id == "claude" })
        #expect(claude.searchURL(for: "anything") == nil)
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
