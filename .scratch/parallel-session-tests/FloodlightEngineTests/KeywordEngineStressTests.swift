import Foundation
import XCTest
@testable import FloodlightEngine

/// Harsh, critical stress tests for `KeywordEngine` and `KeywordEngineCatalog`
/// — adversarial inputs, boundary conditions, and edge cases for the
/// keyword-triggered search routing.
final class KeywordEngineStressTests: XCTestCase {

    // MARK: - Match edge cases

    func testMatchWithEmptyQueryReturnsNil() {
        XCTAssertNil(KeywordEngineCatalog.match(""))
        XCTAssertNil(KeywordEngineCatalog.match(" "))
        XCTAssertNil(KeywordEngineCatalog.match("   "))
    }

    func testMatchWithOnlyWhitespaceAfterKeywordReturnsNil() {
        XCTAssertNil(KeywordEngineCatalog.match("yt "))
        XCTAssertNil(KeywordEngineCatalog.match("yt  "))
        XCTAssertNil(KeywordEngineCatalog.match("yt\t"))
        XCTAssertNil(KeywordEngineCatalog.match("yt\n"))
    }

    func testMatchWithTabSeparator() {
        let match = KeywordEngineCatalog.match("yt\tlofi")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.remainder, "lofi")
    }

    func testMatchWithNewlineSeparator() {
        let match = KeywordEngineCatalog.match("yt\nlofi")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.remainder, "lofi")
    }

    func testMatchWithMultipleSeparators() {
        let match = KeywordEngineCatalog.match("yt   lofi   hip   hop")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.remainder, "lofi   hip   hop")
    }

    // MARK: - Keyword case insensitivity

    func testAllKeywordVariations() {
        for keyword in ["yt", "YT", "Yt", "yT"] {
            XCTAssertNotNil(KeywordEngineCatalog.match("\(keyword) lofi"),
                "'\(keyword)' should match")
        }
    }

    func testBangAliasCaseInsensitivity() {
        for keyword in ["!yt", "!YT", "!Yt", "!yT"] {
            XCTAssertNotNil(KeywordEngineCatalog.match("\(keyword) lofi"),
                "'\(keyword)' should match")
        }
    }

    // MARK: - Remainder edge cases

    func testRemainderWithSpecialCharacters() throws {
        let match = try XCTUnwrap(KeywordEngineCatalog.match("yt hello world & friends"))
        XCTAssertEqual(match.remainder, "hello world & friends")
    }

    func testRemainderWithUnicodeCharacters() throws {
        let match = try XCTUnwrap(KeywordEngineCatalog.match("yt café résumé"))
        XCTAssertEqual(match.remainder, "café résumé")
    }

    func testRemainderWithNumbers() throws {
        let match = try XCTUnwrap(KeywordEngineCatalog.match("yt 123 456"))
        XCTAssertEqual(match.remainder, "123 456")
    }

    func testRemainderWithOnlyNumbers() throws {
        let match = try XCTUnwrap(KeywordEngineCatalog.match("yt 42"))
        XCTAssertEqual(match.remainder, "42")
    }

    // MARK: - All keyword engines

    func testAllEnginesHaveUniqueIDs() {
        let ids = KeywordEngineCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "engine IDs should be unique")
    }

    func testAllEnginesHaveAtLeastOneKeyword() {
        for engine in KeywordEngineCatalog.all {
            XCTAssertFalse(engine.keywords.isEmpty, "engine '\(engine.id)' should have keywords")
        }
    }

    func testAllEnginesHaveNonEmptyTitle() {
        for engine in KeywordEngineCatalog.all {
            XCTAssertFalse(engine.title.isEmpty, "engine '\(engine.id)' should have a title")
        }
    }

    func testWebSearchEnginesHaveURLTemplateWithPlaceholder() {
        for engine in KeywordEngineCatalog.all {
            if case .webSearch(let template) = engine.destination {
                XCTAssertTrue(template.contains("{query}"),
                    "engine '\(engine.id)' URL template should contain {query}")
            }
        }
    }

    func testAssistantEnginesHaveCommandAndBaseArguments() {
        for engine in KeywordEngineCatalog.all {
            if case .assistant(let command, let baseArgs) = engine.destination {
                XCTAssertFalse(command.isEmpty, "engine '\(engine.id)' command should not be empty")
                XCTAssertNotNil(baseArgs, "engine '\(engine.id)' baseArguments should not be nil")
            }
        }
    }

    // MARK: - makeSearchItem

    func testWebSearchMakeSearchItemProducesValidURL() throws {
        let engine = KeywordEngineCatalog.all.first { $0.id == "youtube" }!
        let item = try XCTUnwrap(engine.makeSearchItem(remainder: "lofi hip hop"))
        guard case .open(let url) = item.action else {
            return XCTFail("expected .open action")
        }
        XCTAssertTrue(url.absoluteString.contains("lofi"))
        XCTAssertTrue(url.absoluteString.contains("hip"))
        XCTAssertTrue(url.absoluteString.contains("hop"))
    }

    func testWebSearchMakeSearchItemPercentEncodesQuery() throws {
        let engine = KeywordEngineCatalog.all.first { $0.id == "twitter" }!
        let item = try XCTUnwrap(engine.makeSearchItem(remainder: "hello world & friends"))
        guard case .open(let url) = item.action else {
            return XCTFail("expected .open action")
        }
        XCTAssertTrue(url.absoluteString.contains("hello%20world"))
    }

    func testAssistantMakeSearchItemProducesCorrectAction() throws {
        let engine = KeywordEngineCatalog.all.first { $0.id == "claude" }!
        let item = try XCTUnwrap(engine.makeSearchItem(remainder: "explain this"))
        XCTAssertEqual(item.action, .askAssistant(command: "claude", arguments: ["-p", "explain this"]))
    }

    func testWebSearchMakeSearchItemWithEmptyRemainder() {
        let engine = KeywordEngineCatalog.all.first { $0.id == "twitter" }!
        // Empty remainder still produces an item (the URL just has empty query)
        let item = engine.makeSearchItem(remainder: "")
        // The URL template should still produce a valid URL
        if let item, case .open(let url) = item.action {
            XCTAssertTrue(url.absoluteString.contains("x.com"))
        }
    }

    // MARK: - Search with custom engine lists

    func testSearchWithEmptyEngineListReturnsEmpty() {
        XCTAssertTrue(KeywordEngineCatalog.search("yt lofi", in: []).isEmpty)
    }

    func testSearchWithOnlyWebEngines() {
        let webEngines = KeywordEngineCatalog.all.filter { $0.kind == .web }
        XCTAssertFalse(KeywordEngineCatalog.search("yt lofi", in: webEngines).isEmpty)
        XCTAssertTrue(KeywordEngineCatalog.search("claude hi", in: webEngines).isEmpty)
    }

    func testSearchWithOnlyAssistantEngines() {
        let assistantEngines = KeywordEngineCatalog.all.filter { $0.kind == .assistant }
        XCTAssertFalse(KeywordEngineCatalog.search("claude hi", in: assistantEngines).isEmpty)
        XCTAssertTrue(KeywordEngineCatalog.search("yt lofi", in: assistantEngines).isEmpty)
    }

    // MARK: - Available engines

    func testAvailableEnginesWithAllCommandsAvailable() async {
        let runner = StubRunner(available: ["codex", "claude"])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)
        XCTAssertEqual(available.count, KeywordEngineCatalog.all.count)
    }

    func testAvailableEnginesWithNoCommandsAvailable() async {
        let runner = StubRunner(available: [])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)
        XCTAssertTrue(available.allSatisfy { $0.kind != .assistant })
    }

    func testAvailableEnginesWithPartialCommands() async {
        let runner = StubRunner(available: ["claude"])
        let available = await KeywordEngineCatalog.availableEngines(runner: runner)
        XCTAssertTrue(available.contains { $0.id == "claude" })
        XCTAssertFalse(available.contains { $0.id == "codex" })
        XCTAssertTrue(available.contains { $0.id == "twitter" })
        XCTAssertTrue(available.contains { $0.id == "youtube" })
    }

    // MARK: - Keyword as prefix vs whole word

    func testKeywordPrefixDoesNotMatch() {
        XCTAssertNil(KeywordEngineCatalog.match("ytl lofi"))
        XCTAssertNil(KeywordEngineCatalog.match("ytlofi"))
        XCTAssertNil(KeywordEngineCatalog.match("ytube lofi"))
    }

    func testKeywordMustBeFirstWord() {
        XCTAssertNil(KeywordEngineCatalog.match("lofi yt hip hop"))
        XCTAssertNil(KeywordEngineCatalog.match("play yt lofi"))
    }

    // MARK: - Multiple keyword engines with same keyword

    func testFirstEngineWinsWhenKeywordsOverlap() {
        let engine1 = KeywordEngine(id: "e1", title: "Engine 1", keywords: ["test"], kind: .web,
                                    destination: .webSearch(urlTemplate: "https://e1.com/{query}"))
        let engine2 = KeywordEngine(id: "e2", title: "Engine 2", keywords: ["test"], kind: .web,
                                    destination: .webSearch(urlTemplate: "https://e2.com/{query}"))
        let match = KeywordEngineCatalog.match("test query", in: [engine1, engine2])
        XCTAssertEqual(match?.engine.id, "e1")
    }

    // MARK: - Score is always keywordEngine band

    func testAllKeywordEngineItemsHaveKeywordEngineScore() throws {
        let queries = [
            "yt lofi", "x election", "claude explain", "codex fix", "youtube music",
            "twitter news", "!yt video", "!x post", "!claude code", "!codex run",
        ]
        for query in queries {
            let items = KeywordEngineCatalog.search(query)
            for item in items {
                XCTAssertEqual(item.score, SearchItemRanking.keywordEngine,
                    "keyword engine item for '\(query)' should have keywordEngine score")
            }
        }
    }

    // MARK: - Helpers

    private struct StubRunner: AssistantProcessRunning {
        let available: Set<String>
        func isAvailable(command: String) async -> Bool { available.contains(command) }
        func run(command: String, arguments: [String]) async throws -> String { "" }
    }
}
