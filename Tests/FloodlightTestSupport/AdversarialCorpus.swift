import Foundation

/// Inputs chosen because they break something somewhere.
///
/// Everything here has a reason to exist: shell metacharacters because
/// assistant rows hand a query to a process; URL delimiters because the
/// keyword engines interpolate a query into a URL template; combining
/// marks and ZWJ sequences because `String.count` and `utf8.count` disagree
/// about them and the fuzzy matcher has one path for each; RTL overrides
/// because they make a title render differently from how it compares.
package enum AdversarialCorpus {
    /// Strings every text-taking entry point in the app is expected to
    /// survive without crashing, hanging, or corrupting neighbouring state.
    package static let strings: [String] = [
        "",
        " ",
        "\t",
        "\n",
        "\r\n",
        "   \t \n  ",
        "\u{00A0}",                       // non-breaking space
        "\u{200B}",                       // zero-width space
        "\u{200D}",                       // zero-width joiner
        "\u{FEFF}",                       // BOM
        "\u{202E}drawkcab",               // right-to-left override
        "a\u{0301}",                      // "á" as base + combining acute
        "\u{0301}",                       // lone combining mark
        "é",
        "ﬁle",                            // ligature
        "ＡＰＰ",                          // fullwidth latin
        "İstanbul",                       // dotted capital I, folds oddly
        "ß",
        "ẞ",
        "👨‍👩‍👧‍👦",                          // multi-scalar grapheme cluster
        "🏳️‍🌈",
        "👋🏽",
        "🇦🇶",
        "日本語のファイル名",
        "Кириллица",
        "العربية",
        "\u{1F4A9}\u{FE0F}",
        // Shell and process metacharacters — must never be interpreted.
        "; rm -rf /",
        "$(whoami)",
        "`id`",
        "&& echo pwned",
        "|| true",
        "| tee /tmp/x",
        "> /tmp/out",
        "< /etc/passwd",
        "$HOME",
        "${PATH}",
        "*",
        "~",
        "--help",
        "-",
        "--",
        // URL and query delimiters — must never widen a built URL's meaning
        // beyond the single search parameter it is supposed to fill.
        "?",
        "&",
        "=",
        "#fragment",
        "%00",
        "%s",
        "%n",
        "%@",
        "a&b=c",
        "://",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,<script>",
        // Format strings — several call sites pass user text to NSLog.
        "%1$@ %2$@",
        "%%",
        // Path shapes.
        "../../etc/passwd",
        "/",
        "//",
        "/dev/null",
        ".",
        "..",
        "C:\\Windows",
        "name/with/slashes",
        "name:with:colons",
        // Structural noise.
        "<script>alert(1)</script>",
        "{\"json\": true}",
        "'; DROP TABLE items; --",
        "\u{0000}embedded-nul-ish",
        String(repeating: "a", count: 1_000),
        String(repeating: "ab ", count: 400),
        String(repeating: "🧑‍🚀", count: 200),
    ]

    /// Queries that specifically stress the search pipeline's branch
    /// points: calculator detection, keyword-engine matching, web-intent
    /// promotion, and the short-query word-prefix rule in `SystemCatalog`.
    package static let searchQueries: [String] = [
        "",
        " ",
        "a",
        "ab",
        "abc",
        "abcd",
        "1+1",
        "1 + 1",
        "((((1))))",
        "1/0",
        "1%0",
        "0^0",
        "-0",
        "1,000,000 * 2",
        "2^2^3",
        "how do I reset my password",
        "what?",
        "?",
        "github.com",
        "https://example.com/a?b=c",
        "not a url at all",
        "yt lofi",
        "YT LOFI",
        "!yt lofi",
        "claude explain",
        "codex fix this",
        "yt",
        "yt ",
        " yt lofi ",
        "settings",
        "wifi",
        "bluetooth",
        "zzzzz",
        "\u{202E}yt lofi",
        String(repeating: "x", count: 4_096),
    ]

    /// File extensions the dynamic filters classify — plus ones they must
    /// *not* classify, including case variants and lookalikes.
    package static let fileExtensions: [String] = [
        "pdf", "PDF", "Pdf",
        "png", "jpg", "jpeg", "heic", "gif", "svg", "webp", "tiff", "tif", "bmp", "avif", "heif",
        "txt", "md", "csv", "doc", "docx", "pages", "numbers", "key", "rtf", "xls", "xlsx", "ppt", "pptx",
        "swift", "rs", "ts", "json", "yaml", "zip", "dmg", "app", "",
        "pdf.zip", "notpdf", "pdfx",
    ]

    /// Expressions the calculator must reject — either because they aren't
    /// expressions at all, or because they'd produce a non-finite result.
    package static let rejectedExpressions: [String] = [
        "",
        " ",
        "12",
        "abc",
        "1 + a",
        "1 +",
        "+",
        "()",
        "(1",
        "1)",
        "((1)",
        "1 / 0",
        "1 % 0",
        "1 // 2",
        "1 ** 2",
        "1e5 + 1",
        "0x10 + 1",
        "1.2.3 + 1",
        "1 + 1;",
        "$1 + 1",
        "1 + 1 =",
        "∞ + 1",
    ]

    /// Expressions the calculator *accepts* that look like it shouldn't —
    /// kept separate from the rejection list so the surprising cases are
    /// asserted deliberately rather than discovered in production.
    ///
    /// The zero-width space is the sharp one, and it cuts two ways: a
    /// *trailing* U+200B is removed by
    /// `trimmingCharacters(in: .whitespacesAndNewlines)`, because
    /// Foundation's `CharacterSet` still classifies it as whitespace — so
    /// "1 + 1␋" evaluates fine. An *interior* U+200B is not, because
    /// `Character.isWhitespace` disagrees and `looksLikeExpression`
    /// rejects the whole string. Two different definitions of whitespace,
    /// one expression, opposite answers.
    package static let surprisinglyAcceptedExpressions: [(source: String, value: Double)] = [
        ("1 + 1\u{200B}", 2),
        ("\u{200B}1 + 1", 2),
        ("-1", -1),
        ("+1", 1),
        ("(1)", 1),
        ("00042 + 0", 42),
        ("1,2,3 + 0", 123),
        ("1 + 1\u{00A0}", 2),
        // A trailing decimal point is a valid number to `Double.init`, so
        // "5." is 5 — it is only rejected on its own because it carries no
        // operator character for `looksLikeExpression` to find.
        ("5. + 1", 6),
        (".5 + 1", 1.5),
    ]

    /// The counterpart to the list above: an *interior* zero-width space is
    /// fatal even though a trailing one is invisible to the parser.
    package static let interiorInvisibleRejections: [String] = [
        "1\u{200B}+\u{200B}1",
        "1 +\u{200B} 1",
        "5.",
    ]
}
