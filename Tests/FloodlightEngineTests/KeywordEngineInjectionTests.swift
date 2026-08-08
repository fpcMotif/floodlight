import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

/// Keyword engines take arbitrary user text and hand it to two things that
/// historically go wrong: a subprocess and a URL.
///
/// The subprocess side is the one that has to be airtight — `arguments` are
/// passed to `Process` directly, never through a shell, so the property to
/// prove is that the remainder arrives as *exactly one argument, byte for
/// byte*, no matter what it contains. The URL side is softer, and this file
/// documents precisely how soft.
final class KeywordEngineInjectionTests: XCTestCase {

    private let assistantEngine = KeywordEngine(
        id: "claude",
        title: "Ask Claude",
        keywords: ["claude", "!claude"],
        kind: .assistant,
        destination: .assistant(command: "claude", baseArguments: ["-p"])
    )

    private let webEngine = KeywordEngine(
        id: "youtube",
        title: "Search YouTube",
        keywords: ["yt", "youtube", "!yt"],
        kind: .web,
        destination: .webSearch(urlTemplate: "https://www.youtube.com/results?search_query={query}")
    )

    private func assistantArguments(of item: SearchItem) -> [String]? {
        guard case .askAssistant(_, let arguments) = item.action else { return nil }
        return arguments
    }

    private func openedURL(of item: SearchItem) -> URL? {
        guard case .open(let url) = item.action else { return nil }
        return url
    }

    // MARK: - The subprocess boundary

    func testTheRemainderIsAlwaysExactlyOneUnmodifiedArgument() throws {
        // The whole safety argument for "Ask Claude" rests on this: whatever
        // the user typed becomes a single `argv` entry, unsplit and
        // unrewritten, so there is no layer left that could interpret it.
        try checkProperty(
            "arguments == baseArguments + [remainder], verbatim",
            Gen<String>.hostile,
            runs: 1_500
        ) { remainder in
            guard !remainder.isEmpty else { return true }
            guard let item = self.assistantEngine.makeSearchItem(remainder: remainder),
                  let arguments = self.assistantArguments(of: item) else {
                return false
            }
            return arguments == ["-p", remainder]
        }
    }

    func testShellMetacharactersSurviveIntactRatherThanBeingEscapedOrStripped() {
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
            XCTAssertEqual(
                assistantArguments(of: item ?? SearchFixtures.assistant()),
                ["-p", payload],
                String(reflecting: payload)
            )
        }
    }

    func testALeadingDashRemainderIsNotSeparatedFromItsCommand() {
        // A remainder like "--help" is still one argument in the last
        // position. It could be *interpreted* as a flag by the CLI itself,
        // which is the CLI's business — what matters here is that the
        // engine does not split it into several.
        let item = assistantEngine.makeSearchItem(remainder: "--dangerously-skip-permissions")
        XCTAssertEqual(
            assistantArguments(of: item ?? SearchFixtures.assistant())?.count,
            2
        )
    }

    func testTheCommandItselfIsNeverDerivedFromUserText() throws {
        // A query must never be able to influence *which* executable runs,
        // only what is passed to it.
        try checkProperty(
            "the command is fixed regardless of the remainder",
            Gen<String>.hostile,
            runs: 800
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = self.assistantEngine.makeSearchItem(remainder: remainder),
                  case .askAssistant(let command, _) = item.action else {
                return remainder.isEmpty
            }
            return command == "claude"
        }
    }

    func testAssistantRowsNeverBecomeOpenActions() throws {
        try checkProperty(
            "an assistant engine only ever produces .askAssistant",
            Gen<String>.hostile,
            runs: 500
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = self.assistantEngine.makeSearchItem(remainder: remainder) else {
                return true
            }
            if case .askAssistant = item.action { return true }
            return false
        }
    }

    // MARK: - The URL boundary

    func testEveryRemainderProducesAURLOnTheSameHost() throws {
        // Host confusion would be the serious failure: a remainder that
        // redirected the row to a different site.
        try checkProperty(
            "the built URL always stays on youtube.com",
            Gen<String>.hostile,
            runs: 1_500
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = self.webEngine.makeSearchItem(remainder: remainder),
                  let url = self.openedURL(of: item) else {
                // A remainder that cannot be encoded yields no row at all,
                // which is also safe.
                return true
            }
            return url.host == "www.youtube.com"
                && url.scheme == "https"
                && url.path == "/results"
        }
    }

    func testTheFragmentAndPathCannotBeInjectedThroughTheRemainder() throws {
        try checkProperty(
            "'#' and path traversal are percent-encoded away",
            Gen<String>.hostile,
            runs: 800
        ) { remainder in
            guard !remainder.isEmpty,
                  let item = self.webEngine.makeSearchItem(remainder: remainder),
                  let url = self.openedURL(of: item) else {
                return true
            }
            return url.fragment == nil && url.path == "/results"
        }
    }

    func testTheSearchTermRoundTripsThroughPercentEncoding() throws {
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
                  !remainder.contains(where: { "&=+?/".contains($0) }) else {
                return true
            }
            guard let item = self.webEngine.makeSearchItem(remainder: remainder),
                  let url = self.openedURL(of: item),
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

    func testARemainderContainingAmpersandsWidensTheQueryStringIntoExtraParameters() throws {
        // A real, currently-live gap, pinned so it is a known one.
        //
        // The remainder is encoded with `.urlQueryAllowed`, which *permits*
        // `&`, `=`, `+`, `?` and `/` — they are legal inside a query
        // component. So a query like `yt lofi&list=PL123` does not search
        // for the literal text "lofi&list=PL123"; it opens YouTube with a
        // second parameter the user never intended.
        //
        // Blast radius is limited: the scheme, host, and path are fixed, so
        // this can add or override parameters on a known site but cannot
        // redirect anywhere. Fixing it means encoding with a stricter
        // character set (`.alphanumerics` plus a small allowance), which is
        // a product change, not a test change.
        let item = try XCTUnwrap(webEngine.makeSearchItem(remainder: "lofi&list=PLABC&index=3"))
        let url = try XCTUnwrap(openedURL(of: item))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "www.youtube.com", "the host is still not injectable")
        XCTAssertEqual(
            components.queryItems?.map(\.name),
            ["search_query", "list", "index"],
            "delimiters in the remainder become additional query parameters"
        )
        XCTAssertEqual(components.queryItems?.first?.value, "lofi")
    }

    func testAPlusSignInTheRemainderIsPreservedAndWillDecodeAsASpace() throws {
        // The other half of the same gap: `+` survives encoding, and most
        // servers read `+` in a query as a space.
        let item = try XCTUnwrap(webEngine.makeSearchItem(remainder: "c++ tutorial"))
        let url = try XCTUnwrap(openedURL(of: item))
        XCTAssertTrue(url.absoluteString.contains("c++"))
        XCTAssertFalse(url.absoluteString.contains("c%2B%2B"))
    }

    func testSpacesAndUnicodeArePercentEncoded() throws {
        let item = try XCTUnwrap(webEngine.makeSearchItem(remainder: "日本語 lofi"))
        let url = try XCTUnwrap(openedURL(of: item))
        XCTAssertFalse(url.absoluteString.contains(" "), "a raw space must never reach the URL")
        XCTAssertTrue(url.absoluteString.contains("%20"))
        XCTAssertTrue(url.absoluteString.contains("%E6%97%A5"))
    }

    func testATemplateWithoutThePlaceholderStillProducesAStableURL() {
        // Defensive: an engine defined with a malformed template must not
        // produce a row whose URL varies with the query.
        let broken = KeywordEngine(
            id: "broken",
            title: "Broken",
            keywords: ["br"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://example.com/search")
        )
        let first = openedURL(of: broken.makeSearchItem(remainder: "one") ?? SearchFixtures.web())
        let second = openedURL(of: broken.makeSearchItem(remainder: "two") ?? SearchFixtures.web())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.absoluteString, "https://example.com/search")
    }

    func testATemplateThatCannotFormAURLProducesNoRow() {
        let broken = KeywordEngine(
            id: "broken",
            title: "Broken",
            keywords: ["br"],
            kind: .web,
            destination: .webSearch(urlTemplate: "ht tp://not a url/{query}")
        )
        XCTAssertNil(broken.makeSearchItem(remainder: "anything"))
    }

    // MARK: - Matching

    func testTheKeywordMustBeTheFirstWholeWord() throws {
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
            KeywordEngineCatalog.match("\(other) \(keyword) something") == nil
        }
    }

    func testASecondWordThatIsItselfAKeywordDoesNotHijackTheRow() {
        // The other side of the same coin: only the *first* word addresses
        // an engine, so "x yt lofi" is a Twitter search for "yt lofi", not
        // a YouTube search.
        let match = KeywordEngineCatalog.match("x yt lofi")
        XCTAssertEqual(match?.engine.id, "twitter")
        XCTAssertEqual(match?.remainder, "yt lofi")
    }

    func testKeywordMatchingIgnoresCaseInEveryForm() throws {
        try checkProperty(
            "keyword matching is case-insensitive",
            Gen<String>.element(of: ["yt", "YT", "Yt", "yT", "YouTube", "YOUTUBE"]),
            runs: 200
        ) { keyword in
            KeywordEngineCatalog.match("\(keyword) lofi")?.engine.id == "youtube"
        }
    }

    func testAnyWhitespaceCharacterSeparatesTheKeywordFromItsRemainder() {
        // `firstIndex(where: \.isWhitespace)` accepts more than a space, so
        // a pasted query with a tab or newline still addresses the engine.
        for separator in [" ", "\t", "\n", "\r\n", "  ", " \t "] {
            let match = KeywordEngineCatalog.match("yt\(separator)lofi hip hop")
            XCTAssertEqual(match?.engine.id, "youtube", String(reflecting: separator))
            XCTAssertEqual(match?.remainder, "lofi hip hop", String(reflecting: separator))
        }
    }

    func testInternalSpacingInTheRemainderIsPreservedExactly() throws {
        try checkProperty(
            "only the edges of the remainder are trimmed",
            Gen<String>.string(alphabet: Array("ab  \t"), length: 1...12),
            runs: 400
        ) { raw in
            let expected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty else {
                return KeywordEngineCatalog.match("yt \(raw)") == nil
            }
            return KeywordEngineCatalog.match("yt \(raw)")?.remainder == expected
        }
    }

    func testABareKeywordNeverMatchesSoTypingDoesNotFireEarly() {
        for query in ["yt", "yt ", " yt ", "yt\t", "claude", "  claude  ", "!yt"] {
            XCTAssertNil(
                KeywordEngineCatalog.match(query),
                "\(String(reflecting: query)) must not match while the user is still typing"
            )
        }
    }

    func testAPrefixOfAKeywordIsNotAKeyword() {
        for query in ["y lofi", "yout lofi", "clau explain", "cod fix", "ytx lofi"] {
            XCTAssertNil(KeywordEngineCatalog.match(query), query)
        }
    }

    func testTheFirstEngineListedWinsAKeywordCollision() {
        // `match` uses `first(where:)`, so ordering is the tie-break. Pinned
        // because it is the only thing preventing a later engine from
        // shadowing an earlier one.
        let first = KeywordEngine(
            id: "first",
            title: "First",
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://first.example/{query}")
        )
        let second = KeywordEngine(
            id: "second",
            title: "Second",
            keywords: ["dup"],
            kind: .web,
            destination: .webSearch(urlTemplate: "https://second.example/{query}")
        )
        XCTAssertEqual(
            KeywordEngineCatalog.match("dup query", in: [first, second])?.engine.id,
            "first"
        )
        XCTAssertEqual(
            KeywordEngineCatalog.match("dup query", in: [second, first])?.engine.id,
            "second"
        )
    }

    func testSearchingWithNoEnginesReturnsNothing() throws {
        try checkProperty(
            "an empty engine list produces no rows",
            Gen<String>.element(of: AdversarialCorpus.searchQueries),
            runs: 200
        ) { query in
            KeywordEngineCatalog.search(query, in: []).isEmpty
        }
    }

    func testEveryMatchedQueryProducesExactlyOneRow() throws {
        try checkProperty(
            "search returns zero or one row, never more",
            Gen<String>.element(of: AdversarialCorpus.searchQueries + [
                "yt a", "youtube a", "!yt a", "claude a", "codex a", "x a", "twitter a",
            ]),
            runs: 400
        ) { query in
            KeywordEngineCatalog.search(query).count <= 1
        }
    }

    func testTheShippingCatalogueHasNoAmbiguousKeywords() {
        // Two engines claiming one keyword would make the row depend on
        // declaration order — fine as a tie-break rule, not fine as a
        // shipping configuration.
        var seen: [String: String] = [:]
        for engine in KeywordEngineCatalog.all {
            for keyword in engine.keywords {
                XCTAssertNil(
                    seen[keyword],
                    "'\(keyword)' is claimed by both \(seen[keyword] ?? "") and \(engine.id)"
                )
                seen[keyword] = engine.id
                XCTAssertEqual(keyword, keyword.lowercased(), "keywords must be pre-lowercased")
                XCTAssertFalse(keyword.contains(where: \.isWhitespace), keyword)
            }
        }
        XCTAssertEqual(
            Set(KeywordEngineCatalog.all.map(\.id)).count,
            KeywordEngineCatalog.all.count,
            "engine ids must be unique — they become row identifiers"
        )
    }

    func testEveryShippingEngineProducesAUsableRow() throws {
        for engine in KeywordEngineCatalog.all {
            let item = try XCTUnwrap(
                engine.makeSearchItem(remainder: "test query"),
                engine.id
            )
            XCTAssertEqual(item.id, "keyword-engine:\(engine.id)")
            XCTAssertEqual(item.kind, engine.kind)
            XCTAssertEqual(item.score, SearchItemRanking.keywordEngine)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.subtitle.isEmpty)
            XCTAssertTrue(
                item.title.contains("test query"),
                "the row should echo what was typed: \(item.title)"
            )
        }
    }

    // MARK: - Availability

    func testWebEnginesAreAlwaysAvailableAndAssistantsAreGated() async {
        let webEngineIDs: Set<String> = [
            "google", "duckduckgo", "wikipedia", "github", "stackoverflow", "twitter", "youtube",
        ]

        let none = ScriptedAssistantRunner(availableCommands: [])
        let available = await KeywordEngineCatalog.availableEngines(runner: none)
        XCTAssertEqual(Set(available.map(\.id)), webEngineIDs)
        XCTAssertTrue(available.allSatisfy { $0.kind == .web })

        let both = ScriptedAssistantRunner(availableCommands: ["claude", "codex"])
        let all = await KeywordEngineCatalog.availableEngines(runner: both)
        XCTAssertEqual(Set(all.map(\.id)), webEngineIDs.union(["claude", "codex"]))
    }

    func testOnlyInstalledAssistantsSurvive() async {
        let onlyClaude = ScriptedAssistantRunner(availableCommands: ["claude"])
        let available = await KeywordEngineCatalog.availableEngines(runner: onlyClaude)

        XCTAssertTrue(available.contains { $0.id == "claude" })
        XCTAssertFalse(available.contains { $0.id == "codex" })
    }

    func testAvailabilityIsCheckedOncePerAssistantEngine() async {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude", "codex"])
        _ = await KeywordEngineCatalog.availableEngines(runner: runner)

        let checked = await runner.checkedCommands
        XCTAssertEqual(checked.sorted(), ["claude", "codex"])
        XCTAssertEqual(
            checked.count,
            Set(checked).count,
            "each CLI should only be probed once at startup"
        )
    }

    func testAvailabilityPreservesTheCatalogueOrder() async {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude", "codex"])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)
        XCTAssertEqual(available.map(\.id), KeywordEngineCatalog.all.map(\.id))
    }
}
