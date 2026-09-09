import Foundation

/// Recognizes a query that names a web address outright — `https://abd.com/x`,
/// `x.com/fddddfdf`, a bare `abd.com` — and builds the row that opens it.
///
/// The last of Floodlight's self-naming query shapes to get a recognizer,
/// alongside arithmetic, keyword addressing, and path syntax. Without it a
/// typed address falls through to the default-engine row, whose only job is
/// to search for whatever text is in the field.
///
/// Pure and synchronous: no filesystem, no network, no `NSDataDetector`, no
/// regex. Result Projection calls it inline several times per keystroke, so
/// the rejections that prove a query names no address come first and cost
/// close to nothing — the same reason `PathNavigator.hasPathSyntax` exists.
///
/// Two of its rules are security rather than ergonomics. The scheme
/// allowlist and the userinfo rejection are what keep the search field from
/// becoming an arbitrary-URL opener whose title can disagree with where
/// Return actually goes. Neither should be relaxed to make an edge case work.
package enum DirectLink {
    /// The row for a query that names a web address, or nil for one that
    /// does not. Returning the whole row keeps "what a Direct Link row is"
    /// inside the module that owns it, as `KeywordEngine` does.
    package static func row(for query: String) -> SearchItem? {
        guard let address = address(in: query) else { return nil }
        return SearchItem(
            id: "direct-link",
            title: address.host.hasPrefix("www.")
                ? String(address.host.dropFirst("www.".count))
                : address.host,
            subtitle: address.url.absoluteString,
            kind: .web,
            action: .open(address.url),
            iconSource: .engine(symbol: "link", tint: .blue),
            score: SearchItemRanking.directLink
        )
    }

    /// The address `query` names, with the host the row is titled after.
    private static func address(in query: String) -> (url: URL, host: String)? {
        guard let token = singleToken(in: query) else { return nil }
        // Path Navigation owns local paths. `file://` needs no rule of its
        // own — the scheme allowlist below rejects it.
        guard token.first != "/", token.first != "~" else { return nil }

        let absolute: String
        let afterScheme: Substring
        let scheme = scheme(of: token)
        if let scheme {
            guard scheme.caseInsensitiveCompare("http") == .orderedSame
                || scheme.caseInsensitiveCompare("https") == .orderedSame
            else {
                return nil
            }
            var rest = token[token.index(after: scheme.endIndex)...]
            if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
            absolute = String(token)
            afterScheme = rest
        } else {
            absolute = "https://" + token
            afterScheme = token
        }

        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Email addresses and the `https://apple.com@evil.tld` display spoof,
        // rejected by the same test.
        guard !authority.contains("@") else { return nil }
        // A scheme-less token has to earn its reading as an address. One with
        // a scheme skips this, so `http://localhost:3000` and intranet hosts
        // work while developing.
        guard scheme != nil || namesAKnownHost(authority) else { return nil }
        guard let url = URL(string: absolute), let host = url.host, !host.isEmpty else {
            return nil
        }
        return (url, host)
    }

    /// The one whitespace-delimited token `query` is, or nil if it is blank
    /// or has interior whitespace — prose, or a keyword address, either way
    /// not a Direct Link. A slice rather than a copy: this is the first thing
    /// every keystroke runs, and most keystrokes stop inside it.
    private static func singleToken(in query: String) -> Substring? {
        var start = query.startIndex
        var end = query.endIndex
        while start < end, query[start].isWhitespace {
            query.formIndex(after: &start)
        }
        while end > start, query[query.index(before: end)].isWhitespace {
            query.formIndex(before: &end)
        }
        guard start < end else { return nil }
        let token = query[start..<end]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    /// The `scheme:` prefix `token` declares, or nil — RFC 3986's
    /// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"`, scanned by hand
    /// rather than matched with a regex because this runs on every keystroke.
    ///
    /// `a.com` is a syntactically valid scheme, so `localhost:3000` and
    /// `example.com:8080` are read as schemes and rejected — type the scheme
    /// for those. That is why nothing below strips a `:port`: a token that
    /// reaches the host test with a colon still in it has a colon Foundation
    /// will reject as a port anyway.
    private static func scheme(of token: Substring) -> Substring? {
        guard let first = token.first, isASCIILetter(first) else { return nil }
        var index = token.index(after: token.startIndex)
        while index < token.endIndex {
            let character = token[index]
            if character == ":" { return token[token.startIndex..<index] }
            guard isASCIILetter(character) || isASCIIDigit(character)
                || character == "+" || character == "-" || character == "."
            else {
                return nil
            }
            token.formIndex(after: &index)
        }
        return nil
    }

    /// Whether `authority` reads as a hostname: at least two non-empty
    /// labels, the last of them a known TLD.
    private static func namesAKnownHost(_ authority: Substring) -> Bool {
        guard let lastDot = authority.lastIndex(of: "."),
              !authority.hasPrefix("."),
              !authority.contains("..")
        else {
            return false
        }
        let topLevel = authority[authority.index(after: lastDot)...]
        guard !topLevel.isEmpty, topLevel.allSatisfy(isASCIILetter) else { return false }
        return topLevel.count == 2 || knownGTLDs.contains(topLevel.lowercased())
    }

    /// Deliberately not a public-suffix list: a generated ~1,450-entry table
    /// would blow SwiftLint's `file_length` ratchet, which only ever moves
    /// down. Every two-letter label is taken as a ccTLD instead, and these
    /// are the long gTLDs common enough to be worth typing without a scheme.
    ///
    /// The cost is a knowingly-accepted collision: `readme.md` and `build.sh`
    /// are real ccTLDs and do produce a row. The file rows and the Google row
    /// are both still one arrow key below it.
    private static let knownGTLDs: Set<String> = [
        "app", "biz", "blog", "cloud", "com", "dev", "edu", "gov", "info", "int",
        "mil", "net", "news", "online", "org", "page", "shop", "site", "store",
        "tech", "xyz",
    ]

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
