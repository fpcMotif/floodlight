import Foundation
import Testing
@testable import FloodlightEngine

/// The one classifier every Clipboard Entry consumer reads (#73): what it
/// decides for each kind of copied text, and that its stored form reads back
/// as what was stored.
struct ClipboardTextContentTests {
    @Test func linksClassifyByHostWithoutTheWWWPrefix() {
        #expect(
            ClipboardTextContent.classify("https://www.reddit.com/r/MacOS/comments/123") ==
                .link(domain: "reddit.com")
        )
        #expect(
            ClipboardTextContent.classify("  http://example.org/path?q=1  ") ==
                .link(domain: "example.org")
        )
        #expect(ClipboardTextContent.classify("ftp://example.org/file") == .plain)
        #expect(ClipboardTextContent.classify("https://") == .plain)
        #expect(ClipboardTextContent.classify("see https://example.org") == .plain)
    }

    @Test func hexColoursDecodeToComponents() {
        #expect(
            ClipboardTextContent.classify("#3498db") ==
                .color(ClipboardColorComponents(red: 52, green: 152, blue: 219, alpha: nil))
        )
        #expect(
            ClipboardTextContent.classify("#fff") ==
                .color(ClipboardColorComponents(red: 255, green: 255, blue: 255, alpha: nil))
        )
        #expect(
            ClipboardTextContent.classify("#3498DB80") ==
                .color(ClipboardColorComponents(red: 52, green: 152, blue: 219, alpha: 128))
        )
        #expect(ClipboardTextContent.classify("#12345") == .plain)
        #expect(ClipboardTextContent.classify("3498DB") == .plain)
        // Fullwidth digits satisfy `Character.isHexDigit` but decode to nothing.
        #expect(ClipboardTextContent.classify("#ＦＦＦ") == .plain)
    }

    @Test func colourComponentsDescribeThemselvesAsRGB() {
        let opaque = ClipboardColorComponents(red: 52, green: 152, blue: 219, alpha: nil)
        #expect(opaque.rgbDescription == "rgb(52, 152, 219)")
        let translucent = ClipboardColorComponents(red: 52, green: 152, blue: 219, alpha: 128)
        #expect(translucent.rgbDescription.hasPrefix("rgba(52, 152, 219, 0.50"))
    }

    @Test func codeClassifiesByShapeWithALanguageHint() {
        #expect(
            ClipboardTextContent.classify("{\n  \"name\": \"floodlight\",\n  \"version\": 1\n}") ==
                .code(language: "JSON")
        )
        #expect(ClipboardTextContent.classify("[1, 2, 3]") == .code(language: "JSON"))
        #expect(ClipboardTextContent.classify("{not json}") == .plain)
        #expect(
            ClipboardTextContent.classify("func performSearch() async throws {}") ==
                .code(language: "Code")
        )
        #expect(
            ClipboardTextContent.classify("export const x = 1") == .code(language: "Code")
        )
        #expect(ClipboardTextContent.classify("<!DOCTYPE html><p>x</p>") == .code(language: "HTML"))
        #expect(ClipboardTextContent.classify("<div>x</div>") == .code(language: "HTML"))
        #expect(ClipboardTextContent.classify("Acme billing address") == .plain)
    }

    @Test func singleLineLocalPathsResolveToFileURLsWhetherOrNotTheyExist() {
        #expect(
            ClipboardTextContent.classify("/definitely/missing/file.png") ==
                .path(at: URL(fileURLWithPath: "/definitely/missing/file.png"))
        )
        #expect(
            ClipboardTextContent.classify("  /tmp/shot.png  ") ==
                .path(at: URL(fileURLWithPath: "/tmp/shot.png"))
        )
        #expect(
            ClipboardTextContent.classify("~/Desktop/a.png") ==
                .path(at: URL(fileURLWithPath: NSString(string: "~/Desktop/a.png")
                        .expandingTildeInPath))
        )
        #expect(
            ClipboardTextContent.classify("file:///tmp/a%20b.txt") ==
                .path(at: URL(fileURLWithPath: "/tmp/a b.txt"))
        )
        // `\r\n` is one Character; a path never spans a line either way.
        #expect(ClipboardTextContent.classify("/tmp/shot.png\r\nmore") == .plain)
        #expect(ClipboardTextContent.classify("~/Desktop/a.png\nb") == .plain)
        #expect(ClipboardTextContent.classify("file://") == .plain)
        #expect(ClipboardTextContent.classify("relative/path.txt") == .plain)
    }

    @Test func aPathCarriesTheNamesTheListShowsResolvedOnce() {
        let content = ClipboardPathContent(url: URL(fileURLWithPath: "/Users/f/Screens/shot.png"))
        #expect(content.name == "shot.png")
        #expect(content.parentFolderName == "Screens")
        #expect(content.fileExtension == "png")

        let root = ClipboardPathContent(url: URL(fileURLWithPath: "/"))
        #expect(root.name == "/")
        #expect(root.parentFolderName == nil)
        #expect(root.fileExtension.isEmpty)

        let topLevel = ClipboardPathContent(url: URL(fileURLWithPath: "/Applications"))
        #expect(topLevel.name == "Applications")
        #expect(topLevel.parentFolderName == nil)
    }

    @Test func aPathWinsOverEveryOtherReading() {
        // A path can look like code to the keyword scan; it is still a path.
        #expect(
            ClipboardTextContent.classify("/usr/lib/import module.swift") ==
                .path(at: URL(fileURLWithPath: "/usr/lib/import module.swift"))
        )
    }

    @Test func storedFormsRoundTrip() {
        let contents: [ClipboardTextContent] = [
            .plain,
            .link(domain: "example.org"),
            .color(ClipboardColorComponents(red: 1, green: 2, blue: 3, alpha: nil)),
            .color(ClipboardColorComponents(red: 1, green: 2, blue: 3, alpha: 4)),
            .code(language: "JSON"),
            .path(at: URL(fileURLWithPath: "/tmp/a b.txt")),
            .path(at: URL(fileURLWithPath: "/tmp", isDirectory: true)),
        ]
        for content in contents {
            let stored = content.storedForm
            #expect(
                ClipboardTextContent(storedKind: stored.kind, storedDetail: stored.detail) ==
                    content
            )
        }
        #expect(
            ClipboardColorComponents(red: 1, green: 2, blue: 3, alpha: 4).hexDescription ==
                "#01020304"
        )
    }

    @Test func unreadableStoredFormsReadAsNothingSoTheRowIsClassifiedAgain() {
        #expect(ClipboardTextContent(storedKind: nil, storedDetail: nil) == nil)
        #expect(ClipboardTextContent(storedKind: "link", storedDetail: nil) == nil)
        #expect(ClipboardTextContent(storedKind: "color", storedDetail: "#zz") == nil)
        #expect(ClipboardTextContent(storedKind: "path", storedDetail: "https://x") == nil)
        #expect(ClipboardTextContent(storedKind: "novel", storedDetail: "x") == nil)
        #expect(ClipboardTextContent(storedKind: "plain", storedDetail: nil) == .plain)
    }

    @Test func aTextEntryClassifiesItselfAndOtherKindsCarryNothing() {
        #expect(ClipboardEntry(text: "https://example.org")
            .textContent == .link(domain: "example.org"))
        #expect(ClipboardEntry(text: "/tmp/a.txt", kind: .file).textContent == nil)
        #expect(ClipboardEntry(text: "Screenshot", kind: .image).textContent == nil)
        // A stored classification is trusted over a fresh reading.
        let stored = ClipboardEntry(text: "https://example.org", textContent: .plain)
        #expect(stored.textContent == .plain)
    }
}
