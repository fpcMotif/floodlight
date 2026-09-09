import Foundation
import Testing
@testable import FloodlightEngine

/// One accept/reject case. The recognizer's whole interface is a query in
/// and an optional row out, so a case is exactly that pair: the text typed,
/// and the absolute URL Return would open — or nil for a query that names no
/// address. Adding a case is a row here, not a branch in a test body.
struct DirectLinkCase: Sendable {
    let query: String
    let opens: String?

    static func opens(_ query: String, _ opens: String) -> Self {
        Self(query: query, opens: opens)
    }

    static func rejects(_ query: String) -> Self {
        Self(query: query, opens: nil)
    }
}

struct DirectLinkTests {
    // MARK: - What is and is not a link

    static let matrix: [DirectLinkCase] = [
        .opens("https://abd.com/**", "https://abd.com/**"),
        .opens("http://abd.com/**", "http://abd.com/**"),
        .opens("x.com/fddddfdf", "https://x.com/fddddfdf"),
        .opens("abd.com", "https://abd.com"),
        .opens("http://localhost:3000", "http://localhost:3000"),
        .opens("readme.md", "https://readme.md"),
        .rejects("localhost:3000"),
        // `example.com` is a syntactically valid scheme, so a scheme-less
        // `host:port` is read as a scheme and rejected. Type `http://` for it.
        .rejects("example.com:8080"),
        .rejects("main.swift"),
        .rejects("src/main.swift"),
        .rejects("~/Projects/x.com"),
        .rejects("v1.2.3"),
        .rejects("foo@bar.com"),
        .rejects("https://apple.com@evil.tld"),
        .rejects("javascript:alert(1)"),
        .rejects("file:///etc/hosts"),
        .rejects("yt lofi hip hop"),
    ]

    @Test(arguments: matrix)
    func recognizesExactlyTheQueriesThatNameAWebAddress(_ testCase: DirectLinkCase) throws {
        let row = DirectLink.row(for: testCase.query)
        guard let opens = testCase.opens else {
            #expect(row == nil)
            return
        }
        guard case let .open(url) = try #require(row).action else {
            Issue.record("a Direct Link row must open a URL")
            return
        }
        #expect(url.absoluteString == opens)
    }

    // MARK: - Scheme allowlist

    @Test(arguments: [
        "javascript:alert(1)",
        "data:text/html,<h1>hi</h1>",
        "mailto:someone@example.com",
        "ftp://files.example.com/pub",
        "file:///etc/hosts",
        "floodlight://open?id=1",
    ])
    func onlyHTTPAndHTTPSAreOpenableFromTheSearchField(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    @Test func theSchemeIsMatchedWithoutRegardToCase() {
        #expect(DirectLink.row(for: "HTTPS://abd.com/x") != nil)
        #expect(DirectLink.row(for: "HtTp://abd.com/x") != nil)
    }

    // MARK: - Normalization

    @Test func aSchemelessAddressIsOpenedOverHTTPS() throws {
        let url = try openedURL(of: "x.com/fddddfdf")
        #expect(url?.absoluteString == "https://x.com/fddddfdf")
    }

    @Test func anAddressWithASchemeIsOpenedExactlyAsTyped() throws {
        let url = try openedURL(of: "http://abd.com/a?b=c#d")
        #expect(url?.absoluteString == "http://abd.com/a?b=c#d")
    }

    @Test func anExplicitSchemeSkipsTheKnownTLDTest() {
        #expect(DirectLink.row(for: "http://localhost:3000") != nil)
        #expect(DirectLink.row(for: "https://intranet/wiki") != nil)
        #expect(DirectLink.row(for: "localhost:3000") == nil)
        #expect(DirectLink.row(for: "intranet/wiki") == nil)
    }

    // MARK: - Userinfo and email

    @Test(arguments: [
        "foo@bar.com",
        "first.last@example.co.uk",
        "https://apple.com@evil.tld",
        "http://apple.com@evil.tld/account",
        "user:password@example.com/x",
    ])
    func userinfoAndEmailAddressesProduceNoRow(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    @Test func anAtSignInsideThePathIsNotUserinfo() throws {
        let url = try openedURL(of: "https://x.com/@floodlight")
        #expect(url?.absoluteString == "https://x.com/@floodlight")
    }

    // MARK: - Known TLDs

    @Test(arguments: ["a.io", "a.co", "a.md", "a.sh", "a.ai", "a.me", "a.uk"])
    func everyTwoLetterLastLabelIsATLD(_ query: String) {
        #expect(DirectLink.row(for: query) != nil)
    }

    @Test(arguments: ["a.com", "a.net", "a.org", "a.dev", "a.app", "a.xyz", "a.cloud"])
    func theCuratedGTLDsAreRecognized(_ query: String) {
        #expect(DirectLink.row(for: query) != nil)
    }

    @Test(arguments: [
        "main.swift",
        "App.tsx",
        "data.json",
        "notes.markdown",
        "v1.2.3",
        "1.5",
        "192.168.0.1",
    ])
    func aLastLabelThatIsNotAKnownTLDProducesNoRow(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    /// The knowingly-accepted collision: every two-letter extension is also
    /// somebody's ccTLD, so a filename ending in one is read as an address.
    /// The file rows and the Google row stay one arrow key below it.
    @Test(arguments: ["readme.md", "build.sh", "script.py", "notes.io"])
    func aFilenameEndingInACCTLDIsReadAsAnAddress(_ query: String) {
        #expect(DirectLink.row(for: query) != nil)
    }

    @Test func aLongGTLDStillWorksWhenTypedWithAScheme() throws {
        #expect(DirectLink.row(for: "studio.photography") == nil)
        let url = try openedURL(of: "https://studio.photography")
        #expect(url?.absoluteString == "https://studio.photography")
    }

    // MARK: - Whitespace and local paths

    @Test(arguments: [
        "",
        "   ",
        "abd.com and more",
        "search x.com",
        "abd.com\nx.com",
    ])
    func aQueryThatIsNotASingleTokenProducesNoRow(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    @Test func surroundingWhitespaceIsTrimmedRatherThanRejected() throws {
        let url = try openedURL(of: "  abd.com/x  ")
        #expect(url?.absoluteString == "https://abd.com/x")
    }

    @Test(arguments: ["/etc", "/Users/example/x.com", "~/Projects", "~/Projects/x.com", "file:///"])
    func pathNavigationKeepsOwningLocalPaths(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    // MARK: - The row

    @Test func theRowNamesItsDestinationAndOpensTheAbsoluteURL() throws {
        let row = try #require(DirectLink.row(for: "https://www.abd.com/path?q=1"))
        let expected = try #require(URL(string: "https://www.abd.com/path?q=1"))

        #expect(row.id == "direct-link")
        #expect(row.title == "abd.com")
        #expect(row.subtitle == "https://www.abd.com/path?q=1")
        #expect(row.kind == .web)
        #expect(row.action == .open(expected))
        #expect(row.iconSource == .engine(symbol: "link", tint: .blue))
        #expect(row.score == SearchItemRanking.directLink)
    }

    @Test func theTitleIsTheHostAndTheSubtitleTheURLItWillOpen() throws {
        let row = try #require(DirectLink.row(for: "x.com/fddddfdf"))

        #expect(row.title == "x.com")
        #expect(row.subtitle == "https://x.com/fddddfdf")
    }

    @Test func aDirectLinkOutranksAMatchedKeywordEngine() {
        #expect(SearchItemRanking.directLink > SearchItemRanking.keywordEngine)
    }

    // MARK: - Adversarial input

    @Test(arguments: [
        String(repeating: ".", count: 64),
        "....",
        ".com",
        "..com",
        "a..com",
        "[::1]:8080",
        "https://",
        "a.com\u{0}",
        "\u{1}\u{2}.com",
        "пример.рф",
        ":",
        "://",
        "?",
        "#",
        "a.com:",
    ])
    func hostileTokensThatNameNoAddressProduceNoRow(_ query: String) {
        #expect(DirectLink.row(for: query) == nil)
    }

    /// Tokens whose answer is Foundation's to give — an over-long host, a
    /// punycode label, an IP literal, an unparseable port. What matters is
    /// that the recognizer hands them over and returns, rather than trapping.
    @Test(arguments: [
        String(repeating: "a", count: 10_000) + ".com",
        "xn--80ak6aa92e.com",
        "http://[::1]:8080",
        "https://%",
        "https://\u{7}.com",
        "a.com:99999999999999999999",
    ])
    func tokensFoundationAdjudicatesNeverTrap(_ query: String) {
        _ = DirectLink.row(for: query)
    }

    private func openedURL(of query: String) throws -> URL? {
        guard case let .open(url) = try #require(DirectLink.row(for: query)).action else {
            return nil
        }
        return url
    }
}
