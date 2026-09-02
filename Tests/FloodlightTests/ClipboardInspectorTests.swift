import FloodlightEngine
import Foundation
import Testing
@testable import Floodlight

struct ClipboardInspectorTests {
    @Test func textSnapshotShowsFullBodySourceAndTimestamp() {
        let created = Date(timeIntervalSince1970: 1_785_250_800)
        let entry = ClipboardEntry(
            id: "text-1",
            text: "Pinned multi-line\naddress line 2",
            createdAt: created,
            sourceAppBundleID: "com.apple.Notes"
        )

        let snapshot = ClipboardInspector.snapshot(for: entry)

        guard case let .text(detail) = snapshot else {
            Issue.record("expected a text inspector snapshot")
            return
        }
        #expect(detail.body == "Pinned multi-line\naddress line 2")
        #expect(detail.sourceApp == "Notes")
        #expect(detail.createdAt == created)
        #expect(detail.title == "Pinned multi-line address line 2")
    }

    @Test func fileSnapshotShowsNamePathAndSource() {
        let created = Date(timeIntervalSince1970: 1_785_250_800)
        let path = "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"
        let entry = ClipboardEntry(
            id: "file-1",
            text: path,
            kind: .file,
            createdAt: created,
            sourceAppBundleID: "com.apple.finder"
        )

        let snapshot = ClipboardInspector.snapshot(for: entry)

        guard case let .file(detail) = snapshot else {
            Issue.record("expected a file inspector snapshot")
            return
        }
        #expect(detail.name == "Invoice_Q3_Final.pdf")
        #expect(detail.path == path)
        #expect(detail.type == "PDF")
        #expect(detail.sourceApp == "Finder")
        #expect(detail.createdAt == created)
        #expect(detail.fileURL == URL(fileURLWithPath: path))
    }

    @Test func imageSnapshotShowsNameDimensionsAndPreviewBytes() {
        let created = Date(timeIntervalSince1970: 1_785_250_800)
        let thumbnail = Data(repeating: 0xEF, count: 32)
        let png = Data(repeating: 0xAB, count: 64)
        let entry = ClipboardEntry(
            id: "image-1",
            text: "Screenshot 2026-09-01.png",
            kind: .image,
            createdAt: created,
            sourceAppBundleID: "com.cleanshot.CleanShotX",
            image: ClipboardImageMetadata(
                hash: "abc",
                width: 2_880,
                height: 1_800,
                byteCount: 1_400_000,
                thumbnailPNGData: thumbnail
            )
        )

        let snapshot = ClipboardInspector.snapshot(for: entry, imagePNG: png)

        guard case let .image(detail) = snapshot else {
            Issue.record("expected an image inspector snapshot")
            return
        }
        #expect(detail.name == "Screenshot 2026-09-01.png")
        #expect(detail.width == 2_880)
        #expect(detail.height == 1_800)
        #expect(detail.byteCount == 1_400_000)
        #expect(detail.previewPNG == png)
        #expect(detail.sourceApp == "CleanShotX")
        #expect(detail.createdAt == created)
    }

    @Test func urlSnapshotClassifiesAsLinkAndExtractsDomain() {
        let entry = ClipboardEntry(
            id: "url-1",
            text: "https://www.reddit.com/r/MacOS/comments/123",
            createdAt: .now,
            sourceAppBundleID: "com.apple.Safari"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("expected text snapshot for URL")
            return
        }
        #expect(detail.contentType == .link)
        #expect(detail.domain == "reddit.com")
        #expect(detail.sourceApp == "Safari")
        #expect(detail.characterCount > 0)
    }

    @Test func hexColorSnapshotClassifiesAsColorAndExtractsHex() {
        let entry = ClipboardEntry(
            id: "color-1",
            text: "#3498db",
            createdAt: .now,
            sourceAppBundleID: "com.figma.Desktop"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("expected text snapshot for color")
            return
        }
        #expect(detail.contentType == .color)
        #expect(detail.colorHex == "#3498DB")
    }

    @Test func hexColorSnapshotExposesRGBComponents() {
        let entry = ClipboardEntry(
            id: "color-2",
            text: "#3498DB",
            createdAt: .now,
            sourceAppBundleID: "com.figma.Desktop"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("expected text snapshot for color")
            return
        }
        #expect(detail.contentType == .color)
        #expect(detail.colorHex == "#3498DB")
        #expect(
            detail.colorComponents == ClipboardInspector.ColorComponents(
                red: 52,
                green: 152,
                blue: 219,
                alpha: nil
            )
        )
        #expect(detail.colorComponents?.rgbDescription == "rgb(52, 152, 219)")
    }

    @Test func shortAndAlphaHexColorsParse() {
        #expect(
            ClipboardInspector.parseHexColorComponents("#fff") ==
                ClipboardInspector.ColorComponents(red: 255, green: 255, blue: 255, alpha: nil)
        )

        let withAlpha = ClipboardInspector.parseHexColorComponents("#3498DB80")
        #expect(
            withAlpha == ClipboardInspector.ColorComponents(
                red: 52,
                green: 152,
                blue: 219,
                alpha: 128
            )
        )
        #expect(withAlpha?.rgbDescription.hasPrefix("rgba(52, 152, 219, 0.50") == true)

        #expect(ClipboardInspector.parseHexColorComponents("#12345") == nil)
        #expect(ClipboardInspector.parseHexColorComponents("3498DB") == nil)
    }

    @Test func codeLinesKeepEmptyLinesStripCarriageReturnsAndCap() {
        #expect(ClipboardInspector.codeLines("a\n\nb\r\nc") == ["a", "", "b", "c"])
        #expect(ClipboardInspector.codeLines("x\ny\nz", limit: 2) == ["x", "y"])
        #expect(ClipboardInspector.codeLines("") == [""])
    }

    @Test func jsonSnapshotClassifiesAsCode() {
        let entry = ClipboardEntry(
            id: "json-1",
            text: "{\n  \"name\": \"floodlight\",\n  \"version\": 1\n}",
            createdAt: .now,
            sourceAppBundleID: "com.microsoft.VSCode"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("expected text snapshot for JSON")
            return
        }
        #expect(detail.contentType == .code)
        #expect(detail.codeLanguage == "JSON")
        #expect(detail.lineCount == 4)
        #expect(detail.wordCount == 6)
    }

    @Test func videoFileSnapshotClassifiesAsVideo() {
        let path = "/Users/f/Movies/demo.mp4"
        let entry = ClipboardEntry(
            id: "file-video",
            text: path,
            kind: .file,
            createdAt: .now
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .file(detail) = snapshot else {
            Issue.record("expected file snapshot for video")
            return
        }
        #expect(detail.contentType == .video)
        #expect(detail.isVideo)
        #expect(!detail.isImage)
    }

    @Test func localFilePathTextEntryClassifiesAsFile() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let entry = ClipboardEntry(
            id: "path-1",
            text: tempFile.path,
            createdAt: .now,
            sourceAppBundleID: "com.apple.finder"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .file(detail) = snapshot else {
            Issue.record("expected file snapshot for local image path")
            return
        }
        #expect(detail.name == "test-screenshot.png")
        #expect(detail.isImage)
        #expect(detail.sourceApp == "Finder")
        #expect(detail.fileURL == tempFile)
    }

    @Test func crlfMultilineTextIsNotClassifiedAsALocalPath() {
        #expect(ClipboardInspector.parseLocalPath("/tmp/shot.png") != nil)
        #expect(ClipboardInspector.parseLocalPath("/tmp/shot.png\r\nmore") == nil)
        #expect(ClipboardInspector.parseLocalPath("~/Desktop/a.png\nb") == nil)

        let entry = ClipboardEntry(
            id: "crlf-path",
            text: "/tmp/shot.png\r\nnot a path",
            createdAt: .now
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("CRLF text must stay a text snapshot, not a file path")
            return
        }
        #expect(detail.contentType == .text)
        #expect(detail.body == "/tmp/shot.png\r\nnot a path")
    }

    @Test func unknownSourceAppFallsBackToTheBundleIDLastComponent() {
        let entry = ClipboardEntry(
            id: "unknown-app",
            text: "snippet",
            createdAt: .now,
            sourceAppBundleID: "com.example.NotAnInstalledApp"
        )
        let snapshot = ClipboardInspector.snapshot(for: entry)
        guard case let .text(detail) = snapshot else {
            Issue.record("expected text snapshot")
            return
        }
        #expect(detail.sourceApp == "NotAnInstalledApp")
        #expect(detail.sourceAppBundleID == "com.example.NotAnInstalledApp")
    }
}
