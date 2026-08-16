import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing

/// Keyword engines take arbitrary user text and hand it to two things that
/// historically go wrong: a subprocess and a URL.
///
/// The subprocess side is the one that has to be airtight — `arguments` are
/// passed to `Process` directly, never through a shell, so the property to
/// prove is that the remainder arrives as *exactly one argument, byte for
/// byte*, no matter what it contains. The URL side is softer, and this file
/// documents precisely how soft.
struct KeywordEngineInjectionTests {
    private let catalogRegistry = KeywordEngineRegistry(
        engines: KeywordEngineCatalog.all,
        defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
    )

    private let assistantEngine = KeywordEngine(
        id: "claude",
        title: "Ask Claude",
        name: "Claude",
        tint: .purple,
        keywords: ["claude", "!claude"],
        kind: .assistant,
        destination: .assistant(command: "claude", baseArguments: ["-p"])
    )

    private let webEngine = KeywordEngine(
        id: "youtube",
        title: "Search YouTube",
        name: "YouTube",
        tint: .red,
        keywords: ["yt", "youtube", "!yt"],
        kind: .web,
        destination: .webSearch(urlTemplate: "https://www.youtube.com/results?search_query={query}")
    )

    private func assistantArguments(of item: SearchItem) -> [String]? {
        guard case let .askAssistant(_, arguments) = item.action else { return nil }
        return arguments
    }

    private func openedURL(of item: SearchItem) -> URL? {
        guard case let .open(url) = item.action else { return nil }
        return url
    }

    private func searchCatalog(_ query: String) -> [SearchItem] {
        catalogRegistry.addressedResult(for: query).map { [$0] } ?? []
    }

    // MARK: - The subprocess boundary

    @Test func theRemainderIsAlwaysExactlyOneUnmodifiedArgument() throws {
        // The whole safety argument for "Ask Claude" rests on this: whatever
        // the user typed becomes a single `argv` entry, unsplit and
        // unrewritten, so there is no layer left that could interpret it.
        try checkProperty(
            "arguments == baseArguments + [remainder], verbatim",
            Gen<String>.hostile,
            runs: 1_500
        ) { remainder in
            guard !remainder.isEmpty else { return true }
            guard let item = assistantEngine.makeSearchItem(remainder: remainder),
                  let arguments = assistantArguments(of: item)
            else {
                return false
            }
            return arguments == ["-p", "--", remainder]
        }
    }

    @Test func shellMetacharactersSurviveIntactRatherThanBeingEscapedOrStripped() {
        // Escaping would be a bug too: the argument goes to `execve`, so an
        // escaped `;` would reach the CLI as a literal backslash-semicolon.
        // The correct behaviour is to change nothing at all.
        let payloads = [
            "; rm -rf /",
            "$(whoami)",
            "`id`",
            "a && b || c",
            "| tee /tmp/x",
            "> /tmp/out",
            "$HOME/${PATH}",
            "--version",
            "-",
            "--",
            "*",
            "~",
            "\\'\"",
            "line one\nline two",
            "tab\there",
            "null-ish \u{0000} inside",
        ]

        for payload in payloads {
            let item = assistantEngine.makeSearchItem(remainder: payload)
            #expect(
                assistantArguments(of: item ?? SearchFixtures.assistant()) == ["-p", "--", payload],
                "\(String(reflecting: payload))"
            )
        }
    }

    @Test func aLeadingDashRemainderIsNotSeparatedFromItsCommand() {
        // The option terminator keeps a leading-dash query from changing the
        // assistant CLI's permissions, configuration, or execution mode.
        let item = assistantEngine.makeSearchItem(remainder: "--dangerously-skip-permissions")
        #expect(assistantArguments(of: item ?? SearchFixtures.assistant()) == [
            "-p",
            "--",
            "--dangerously-skip-permissions",
        ])
    }

    @Test func theCommandItselfIsNeverDerivedFromUserText() throws {
        // A query must never be able to influence *which* executable runs,
        // only what is passed to it.
        try checkProperty(
            "the command is fixed regardless of the remainder",
            Gen<String>.hostile,
            runs: 800
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = assistantEngine.makeSearchItem(remainder: remainder),
                  case let .askAssistant(command, _) = item.action
            else {
                return remainder.isEmpty
            }
            return command == "claude"
        }
    }

    @Test func assistantRowsNeverBecomeOpenActions() throws {
        try checkProperty(
            "an assistant engine only ever produces .askAssistant",
            Gen<String>.hostile,
            runs: 500
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = assistantEngine.makeSearchItem(remainder: remainder)
            else {
                return true
            }
            if case .askAssistant = item.action { return true }
            return false
        }
    }

    // MARK: - The URL boundary

    @Test func everyRemainderProducesAURLOnTheSameHost() throws {
        // Host confusion would be the serious failure: a remainder that
        // redirected the row to a different site.
        try checkProperty(
            "the built URL always stays on youtube.com",
            Gen<String>.hostile,
            runs: 1_500
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = webEngine.makeSearchItem(remainder: remainder),
                  let url = openedURL(of: item)
            else {
                // A remainder that cannot be encoded yields no row at all,
                // which is also safe.
                return true
            }
            return url.host == "www.youtube.com"
                && url.scheme == "https"
                && url.path == "/results"
        }
    }

    @Test func theFragmentAndPathCannotBeInjectedThroughTheRemainder() throws {
        try checkProperty(
            "'#' and path traversal are percent-encoded away",
            Gen<String>.hostile,
            runs: 800
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = webEngine.makeSearchItem(remainder: remainder),
                  let url = openedURL(of: item)
            else {
                return true
            }
            return url.fragment == nil && url.path == "/results"
        }
    }

    @Test func theSearchTermRoundTripsThroughPercentEncoding() throws {
        try checkProperty(
            "the remainder can be recovered from the query string",
            Gen<String>.hostile,
            runs: 800
        ) { remainder in
            // Restricted to remainders with no URL-query delimiters, since
            // those are precisely the ones that do *not* round-trip — see
            // the injection test below.
            // Remainders carrying URL-query delimiters are skipped: those
            // are precisely the ones that do not round-trip, and they get
            // their own test below.
            guard !remainder.isEmpty,
                  !remainder.contains(where: { "&=+?/".contains($0) })
            else {
                return true
            }
            guard let item = webEngine.makeSearchItem(remainder: remainder),
                  let url = openedURL(of: item),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let rawQuery = components.percentEncodedQuery,
                  rawQuery.hasPrefix("search_query=")
            else {
                return false
            }
            // Decoded from the raw query rather than through `queryItems`,
            // which applies its own normalization on top.
            let encodedValue = String(rawQuery.dropFirst("search_query=".count))
            return encodedValue.removingPercentEncoding == remainder
        }
    }

    @Test func aQueryRemainderCannotInjectAdditionalURLParameters() throws {
        let item = try #require(webEngine.makeSearchItem(remainder: "lofi&list=PLABC&index=3"))
        let url = try #require(openedURL(of: item))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.host == "www.youtube.com")
        #expect(components.queryItems?.map(\.name) == ["search_query"])
        #expect(components.queryItems?.first?.value == "lofi&list=PLABC&index=3")
    }

    @Test func aPlusSignInTheRemainderIsEncodedAsLiteralText() throws {
        let item = try #require(webEngine.makeSearchItem(remainder: "c++ tutorial"))
        let url = try #require(openedURL(of: item))
        #expect(!(url.absoluteString.contains("c++")))
        #expect(url.absoluteString.contains("c%2B%2B"))
    }

    @Test func spacesAndUnicodeArePercentEncoded() throws {
        let item = try #require(webEngine.makeSearchItem(remainder: "日本語 lofi"))
        let url = try #require(openedURL(of: item))
        #expect(!(url.absoluteString.contains(" ")), "a raw space must never reach the URL")
        #expect(url.absoluteString.contains("%20"))
        #expect(url.absoluteString.contains("%E6%97%A5"))
    }

    @Test func aTemplateWithoutThePlaceholderStillProducesAStableURL() {
        // Defensive: an engine defined with a malformed template must not
        // produce a row whose URL varies with the query.
        let broken = KeywordEngine(
            id: "broken",
            title: "Broken",
            name: "Broken",
            tint: .blue,
            keywords: ["br"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/search")
        )
        let first = openedURL(of: broken.makeSearchItem(remainder: "one") ?? SearchFixtures.web())
        let second = openedURL(of: broken.makeSearchItem(remainder: "two") ?? SearchFixtures.web())
        #expect(first == second)
        #expect(first?.absoluteString == "https://example.com/search")
    }

    @Test func aTemplateThatCannotFormAURLProducesNoRow() {
        let broken = KeywordEngine(
            id: "broken",
            title: "Broken",
            name: "Broken",
            tint: .blue,
            keywords: ["br"],
            kind: .web,
            destination: .webSearch(urlTemplate: "ht tp://not a url/{query}")
        )
        #expect(broken.makeSearchItem(remainder: "anything") == nil)
    }

    // MARK: - Matching

    @Test func theKeywordMustBeTheFirstWholeWord() throws {
        // The leading word has to be something no engine claims — "x" is
        // itself a Twitter keyword, which is exactly how the first version
        // of this property falsified itself.
        let claimed = Set(KeywordEngineCatalog.all.flatMap(\.keywords))
        try checkProperty(
            "a keyword anywhere but first does not match",
            Gen<String>.element(of: ["yt", "youtube", "!yt", "claude", "codex"]),
            Gen<String>.lowercaseASCII.filter { !$0.isEmpty && !claimed.contains($0) },
            runs: 500
        ) { keyword, other in
            catalogRegistry.addressedResult(for: "\(other) \(keyword) something") == nil
        }
    }

    @Test func aSecondWordThatIsItselfAKeywordDoesNotHijackTheRow() throws {
        // The other side of the same coin: only the *first* word addresses
        // an engine, so "x yt lofi" is a Twitter search for "yt lofi", not
        // a YouTube search.
        let result = try #require(catalogRegistry.addressedResult(for: "x yt lofi"))
        let url = try #require(openedURL(of: result))
        #expect(result.id == "keyword-engine:twitter")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?
            .value == "yt lofi")
    }

    @Test func keywordMatchingIgnoresCaseInEveryForm() throws {
        try checkProperty(
            "keyword matching is case-insensitive",
            Gen<String>.element(of: ["yt", "YT", "Yt", "yT", "YouTube", "YOUTUBE"]),
            runs: 200
        ) { keyword in
            catalogRegistry.addressedResult(for: "\(keyword) lofi")?.id
                == "keyword-engine:youtube"
        }
    }

    @Test func anyWhitespaceCharacterSeparatesTheKeywordFromItsRemainder() throws {
        // `firstIndex(where: \.isWhitespace)` accepts more than a space, so
        // a pasted query with a tab or newline still addresses the engine.
        for separator in [" ", "\t", "\n", "\r\n", "  ", " \t "] {
            let result = try #require(
                catalogRegistry.addressedResult(for: "yt\(separator)lofi hip hop"),
                "\(String(reflecting: separator))"
            )
            let url = try #require(openedURL(of: result), "\(String(reflecting: separator))")
            #expect(result.id == "keyword-engine:youtube", "\(String(reflecting: separator))")
            #expect(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?
                    .value == "lofi hip hop",
                "\(String(reflecting: separator))"
            )
        }
    }

    @Test func internalSpacingInTheRemainderIsPreservedExactly() throws {
        try checkProperty(
            "only the edges of the remainder are trimmed",
            Gen<String>.string(alphabet: Array("ab  \t"), length: 1...12),
            runs: 400
        ) { raw in
            let expected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty else {
                return catalogRegistry.addressedResult(for: "yt \(raw)") == nil
            }
            guard let result = catalogRegistry.addressedResult(for: "yt \(raw)"),
                  let url = openedURL(of: result)
            else {
                return false
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value == expected
        }
    }

    @Test func aBareKeywordNeverMatchesSoTypingDoesNotFireEarly() {
        for query in ["yt", "yt ", " yt ", "yt\t", "claude", "  claude  ", "!yt"] {
            #expect(
                catalogRegistry.addressedResult(for: query) == nil,
                "\(String(reflecting: query)) must not match while the user is still typing"
            )
        }
    }

    @Test func aPrefixOfAKeywordIsNotAKeyword() {
        for query in ["y lofi", "yout lofi", "clau explain", "cod fix", "ytx lofi"] {
            #expect(catalogRegistry.addressedResult(for: query) == nil, "\(query)")
        }
    }

    @Test func theFirstEngineListedWinsAKeywordCollision() {
        // Registry construction keeps the first engine for each keyword, so
        // ordering is the tie-break.
        let first = KeywordEngine(
            id: "first",
            title: "First",
            name: "First",
            tint: .blue,
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://first.example/{query}")
        )
        let second = KeywordEngine(
            id: "second",
            title: "Second",
            name: "Second",
            tint: .blue,
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://second.example/{query}")
        )
        let firstRegistry = KeywordEngineRegistry(
            engines: [first, second],
            defaultWebEngineID: first.id
        )
        let secondRegistry = KeywordEngineRegistry(
            engines: [second, first],
            defaultWebEngineID: second.id
        )
        #expect(firstRegistry.addressedResult(for: "dup query")?.id == "keyword-engine:first")
        #expect(secondRegistry.addressedResult(for: "dup query")?.id == "keyword-engine:second")
    }

    @Test func aRegistryWithOnlyItsDefaultHasNoOptionalAddressedDestinations() {
        let registry = KeywordEngineRegistry(
            engines: [KeywordEngineCatalog.defaultEngine],
            defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
        )
        for query in ["yt lofi", "claude explain", "codex fix", "wiki floodlight"] {
            #expect(registry.addressedResult(for: query) == nil, "\(query)")
        }
    }

    @Test func everyMatchedQueryProducesExactlyOneRow() throws {
        try checkProperty(
            "search returns zero or one row, never more",
            Gen<String>.element(of: AdversarialCorpus.searchQueries + [
                "yt a", "youtube a", "!yt a", "claude a", "codex a", "x a", "twitter a",
            ]),
            runs: 400
        ) { query in
            searchCatalog(query).count <= 1
        }
    }

    @Test func theShippingCatalogueHasNoAmbiguousKeywords() {
        // Two engines claiming one keyword would make the row depend on
        // declaration order — fine as a tie-break rule, not fine as a
        // shipping configuration.
        var seen: [String: String] = [:]
        for engine in KeywordEngineCatalog.all {
            for keyword in engine.keywords {
                #expect(
                    seen[keyword] == nil,
                    "'\(keyword)' is claimed by both \(seen[keyword] ?? "") and \(engine.id)"
                )
                seen[keyword] = engine.id
                #expect(keyword == keyword.lowercased(), "keywords must be pre-lowercased")
                let hasWhitespace = keyword.contains(where: \.isWhitespace)
                #expect(!hasWhitespace, "\(keyword)")
            }
        }
        #expect(
            Set(KeywordEngineCatalog.all.map(\.id)).count == KeywordEngineCatalog.all.count,
            "engine ids must be unique — they become row identifiers"
        )
    }

    @Test func everyShippingEngineProducesAUsableRow() throws {
        for engine in KeywordEngineCatalog.all {
            let item = try #require(engine.makeSearchItem(remainder: "test query"), "\(engine.id)")
            #expect(item.id == "keyword-engine:\(engine.id)")
            #expect(item.kind == engine.kind)
            #expect(item.score == SearchItemRanking.keywordEngine)
            #expect(!(item.title.isEmpty))
            #expect(!(item.subtitle.isEmpty))
            switch engine.destination {
            case .webSearch:
                // A web row names its destination and echoes the query
                // through the URL it opens, not through a title that
                // reflows on every keystroke.
                #expect(item.title == engine.name)
                #expect(item.subtitle == engine.host)
                #expect(item.iconSource == .engine(symbol: engine.symbolName, tint: engine.tint))
                #expect(
                    openedURL(of: item)?.absoluteString.contains("test%20query") == true,
                    "the row's URL should carry what was typed: \(item.action)"
                )
            case .assistant:
                #expect(
                    item.title.contains("test query"),
                    "the row should echo what was typed: \(item.title)"
                )
            }
        }
    }

    // MARK: - Availability

    @Test func webEnginesAreAlwaysAvailableAndAssistantsAreGated() async {
        let none = ScriptedAssistantRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableRegistry(runner: none)
        #expect(available.webModeResults(for: "query", activeEngineID: "google").map(\.id) == [
            "web-mode:google",
            "web-mode:wikipedia",
            "web-mode:github",
            "web-mode:stackoverflow",
            "web-mode:twitter",
            "web-mode:youtube",
        ])
        #expect(available.addressedResult(for: "claude query") == nil)
        #expect(available.addressedResult(for: "codex query") == nil)

        let both = ScriptedAssistantRunner(availableCommands: ["claude", "codex"])
        let all = await KeywordEngineCatalog.availableRegistry(runner: both)
        #expect(all.addressedResult(for: "claude query") != nil)
        #expect(all.addressedResult(for: "codex query") != nil)
    }

    @Test func onlyInstalledAssistantsSurvive() async {
        let onlyClaude = ScriptedAssistantRunner(availableCommands: ["claude"])
        let available = await KeywordEngineCatalog.availableRegistry(runner: onlyClaude)

        #expect(available.addressedResult(for: "claude query") != nil)
        #expect(available.addressedResult(for: "codex query") == nil)
    }

    @Test func availabilityIsCheckedOncePerAssistantEngine() async {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude", "codex"])
        _ = await KeywordEngineCatalog.availableRegistry(runner: runner)

        let checked = await runner.checkedCommands
        #expect(checked.sorted() == ["claude", "codex"])
        #expect(
            checked.count == Set(checked).count,
            "each CLI should only be probed once at startup"
        )
    }
}
