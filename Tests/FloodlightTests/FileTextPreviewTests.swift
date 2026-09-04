import AppKit
import FloodlightEngine
import Foundation
import SwiftUI
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct FileTextPreviewTests {
    private let tempDirectory: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTextPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectory = dir
    }

    // MARK: - Classification Tests

    @Test func classifiesCodeAndTextFileExtensionsCorrectly() {
        let jsonEntry = ClipboardEntry(
            id: "f-json",
            text: "/tmp/data.json",
            kind: .file,
            createdAt: .now
        )
        guard case let .file(jsonDetail) = ClipboardInspector.snapshot(for: jsonEntry) else {
            Issue.record("expected file snapshot")
            return
        }
        #expect(jsonDetail.contentType == .code)
        #expect(jsonDetail.isCode)
        #expect(jsonDetail.isText)
        #expect(jsonDetail.type == "JSON")

        let pyEntry = ClipboardEntry(
            id: "f-py",
            text: "/tmp/script.PY", // mixed/uppercase case test
            kind: .file,
            createdAt: .now
        )
        guard case let .file(pyDetail) = ClipboardInspector.snapshot(for: pyEntry) else {
            Issue.record("expected file snapshot")
            return
        }
        #expect(pyDetail.contentType == .code)
        #expect(pyDetail.isCode)
        #expect(pyDetail.isText)
        #expect(pyDetail.type == "Python Script" || pyDetail.type == "Source Code")

        let mdEntry = ClipboardEntry(
            id: "f-md",
            text: "/tmp/README.md",
            kind: .file,
            createdAt: .now
        )
        guard case let .file(mdDetail) = ClipboardInspector.snapshot(for: mdEntry) else {
            Issue.record("expected file snapshot")
            return
        }
        #expect(mdDetail.contentType == .text)
        #expect(!mdDetail.isCode)
        #expect(mdDetail.isText)
        #expect(mdDetail.type == "Markdown")

        let txtEntry = ClipboardEntry(
            id: "f-txt",
            text: "/tmp/notes.TXT",
            kind: .file,
            createdAt: .now
        )
        guard case let .file(txtDetail) = ClipboardInspector.snapshot(for: txtEntry) else {
            Issue.record("expected file snapshot")
            return
        }
        #expect(txtDetail.contentType == .text)
        #expect(!txtDetail.isCode)
        #expect(txtDetail.isText)
        #expect(txtDetail.type == "Plain Text")

        let pdfEntry = ClipboardEntry(
            id: "f-pdf",
            text: "/tmp/doc.pdf",
            kind: .file,
            createdAt: .now
        )
        guard case let .file(pdfDetail) = ClipboardInspector.snapshot(for: pdfEntry) else {
            Issue.record("expected file snapshot")
            return
        }
        #expect(pdfDetail.contentType == .file)
        #expect(!pdfDetail.isCode)
        #expect(!pdfDetail.isText)
        #expect(pdfDetail.type == "PDF")
    }

    @Test func localPathTextEntryClassifiesAsTextOrCodeFile() {
        let entry = ClipboardEntry(
            id: "t-json",
            text: "/tmp/config.json",
            createdAt: .now
        )
        guard case let .file(detail) = ClipboardInspector.snapshot(for: entry) else {
            Issue.record("expected file snapshot for local json path")
            return
        }
        #expect(detail.contentType == .code)
        #expect(detail.isCode)
        #expect(detail.isText)
    }

    // MARK: - Decoder Tests

    @Test func decodesJSONContent() throws {
        let file = tempDirectory.appendingPathComponent("sample.json")
        let jsonString = """
        {
          "name": "Floodlight",
          "version": 1
        }
        """
        try jsonString.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(!preview.isEmpty)
        #expect(!preview.isTruncated)
        #expect(preview.lines.count == 4)
        #expect(preview.lines[0] == "{")
        #expect(preview.lines[1] == "  \"name\": \"Floodlight\",")
    }

    @Test func decodesMarkdownContentPreservingLines() throws {
        let file = tempDirectory.appendingPathComponent("notes.md")
        let mdString = "# Heading\n\nFirst paragraph with notes.\nLine 2."
        try mdString.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(!preview.isEmpty)
        #expect(!preview.isTruncated)
        #expect(preview.lines.count == 4)
        #expect(preview.lines[0] == "# Heading")
        #expect(preview.lines[1].isEmpty)
        #expect(preview.lines[2] == "First paragraph with notes.")
    }

    @Test func detectsEmptyFileExplicitly() throws {
        let file = tempDirectory.appendingPathComponent("empty.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(preview.isEmpty)
        #expect(!preview.isTruncated)
        #expect(preview.lines.isEmpty)
    }

    @Test func rejectsBinaryFileWithTextExtension() throws {
        let file = tempDirectory.appendingPathComponent("binary.txt")
        var data = Data("Some leading text".utf8)
        data.append(0x00) // NUL byte indicator of binary data
        data.append(contentsOf: "trailing text".utf8)
        try data.write(to: file)

        let preview = FileTextPreviewDecoder.decode(at: file)
        #expect(preview == nil)
    }

    @Test func rejectsMissingFileGracefully() {
        let missing = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        let preview = FileTextPreviewDecoder.decode(at: missing)
        #expect(preview == nil)
    }

    @Test func decodesUTF8WithBOM() throws {
        let file = tempDirectory.appendingPathComponent("bom-utf8.txt")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "BOM UTF-8 Content".utf8)
        try data.write(to: file)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(!preview.isEmpty)
        #expect(preview.lines.first == "BOM UTF-8 Content")
    }

    @Test func decodesUTF16WithBOM() throws {
        let file = tempDirectory.appendingPathComponent("bom-utf16.txt")
        let text = "UTF-16 Text Content"
        guard let data = text.data(using: .utf16) else {
            Issue.record("failed to encode utf16")
            return
        }
        try data.write(to: file)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(!preview.isEmpty)
        #expect(preview.lines.first == "UTF-16 Text Content")
    }

    @Test func truncatesFileExceedingLineLimit() throws {
        let file = tempDirectory.appendingPathComponent("many-lines.py")
        let lines = (1...250).map { "print(\($0))" }
        let content = lines.joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, maxLines: 200))
        #expect(preview.isTruncated)
        #expect(preview.lines.count == 200)
        #expect(preview.lines.first == "print(1)")
        #expect(preview.lines.last == "print(200)")
    }

    @Test func truncatesFileExceedingByteLimit() throws {
        let file = tempDirectory.appendingPathComponent("large-bytes.txt")
        let chunk = String(repeating: "A", count: 1_000) + "\n"
        let content = String(repeating: chunk, count: 100) // 100 KB
        try content.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(
            at: file,
            maxBytes: 32 * 1_024,
            maxLines: 500
        ))
        #expect(preview.isTruncated)
        #expect(preview.lines.last == String(repeating: "A", count: 1_000))
    }

    @Test func rejectsInvalidUTF8() throws {
        let file = tempDirectory.appendingPathComponent("invalid-utf8.txt")
        let data = Data([0x48, 0x69, 0xFF, 0xFE, 0x41])
        try data.write(to: file)

        let preview = FileTextPreviewDecoder.decode(at: file)
        #expect(preview == nil)
    }

    @Test func byteTruncationNeverSplitsAMultibyteCharacter() throws {
        let file = tempDirectory.appendingPathComponent("multibyte.txt")
        let sourceLine = "日本語テキスト🙂"
        let content = Array(repeating: sourceLine, count: 100).joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, maxBytes: 1_000))
        #expect(preview.isTruncated)
        #expect(!preview.lines.isEmpty)
        for line in preview.lines {
            #expect(line == sourceLine)
        }
    }

    @Test func decodesUnicodeContentAndFilenames() throws {
        let file = tempDirectory.appendingPathComponent("笔记-🙂.txt")
        try "héllo wörld\n日本語".write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(preview.lines.count == 2)
        #expect(preview.lines[0] == "héllo wörld")
        #expect(preview.lines[1] == "日本語")
    }

    @Test func bomOnlyFileIsEmpty() throws {
        let file = tempDirectory.appendingPathComponent("bom-only.txt")
        try Data([0xEF, 0xBB, 0xBF]).write(to: file)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file))
        #expect(preview.isEmpty)
        #expect(preview.lines.isEmpty)
    }

    @Test func directoryWithTextExtensionIsRejected() throws {
        let directory = tempDirectory.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let preview = FileTextPreviewDecoder.decode(at: directory)
        #expect(preview == nil)
    }

    // MARK: - Cache & Invalidation Tests

    @Test func cacheReturnsStoredPreviewAndInvalidatesOnModification() async throws {
        let file = tempDirectory.appendingPathComponent("cached.txt")
        try "Version 1".write(to: file, atomically: true, encoding: .utf8)

        let cache = FileTextPreviewCache()
        let preview1 = try #require(await cache.preview(for: file))
        #expect(preview1.lines.first == "Version 1")

        // Immediate lookup hit
        let immediate1 = try #require(cache.immediatePreview(for: file))
        #expect(immediate1.lines.first == "Version 1")

        // Modify file with new content and updated modification date
        try "Version 2".write(to: file, atomically: true, encoding: .utf8)
        let future = Date(timeIntervalSinceNow: 5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)

        let preview2 = try #require(await cache.preview(for: file))
        #expect(preview2.lines.first == "Version 2")
    }

    // MARK: - Inspector Rendering Tests

    @Test(arguments: [
        ("preview-data.json", "{\n  \"app\": \"Floodlight\"\n}"),
        ("preview-notes.md", "# Project Notes\n\n- Task 1\n- Task 2"),
        ("preview-notes.txt", "First line\n\nThird line"),
        ("preview-script.py", "import sys\n\nprint(sys.argv)"),
    ])
    func copiedTextFilePathsRenderTheirContentsInTheInspector(
        filename: String,
        content: String
    ) async throws {
        let url = tempDirectory.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let entrySnapshot = snapshot(forPath: url.path)

        let (coldWindow, cold) = mount(entrySnapshot)
        defer { coldWindow.orderOut(nil) }

        _ = await FileTextPreviewCache.shared.preview(for: url)

        let (referenceWindow, reference) = mount(entrySnapshot)
        defer { referenceWindow.orderOut(nil) }

        let (controlWindow, control) = mount(metadataOnlyControl(entrySnapshot))
        defer { controlWindow.orderOut(nil) }

        try await waitUntil("warm preview differs from metadata-only rendering") {
            try bitmap(reference) != bitmap(control)
        }
        try await waitUntil("cold preview converges") {
            try bitmap(cold) == bitmap(reference)
        }
    }

    @Test func nativeFileEntryAndCopiedPathRenderIdentically() async throws {
        let url = tempDirectory.appendingPathComponent("native-vs-copied.json")
        try "{\n  \"native\": true\n}".write(to: url, atomically: true, encoding: .utf8)

        _ = await FileTextPreviewCache.shared.preview(for: url)

        let (fileWindow, fileHosting) = mount(snapshot(forPath: url.path, kind: .file))
        defer { fileWindow.orderOut(nil) }
        let (textWindow, textHosting) = mount(snapshot(forPath: url.path, kind: .text))
        defer { textWindow.orderOut(nil) }

        try await waitUntil("native file entry and copied path render identically") {
            try bitmap(fileHosting) == bitmap(textHosting)
        }
    }

    @Test func changingSelectionReplacesThePreview() async throws {
        let urlA = tempDirectory.appendingPathComponent("a.json")
        let contentA = (1...12).map { "line \($0): value-\($0)" }.joined(separator: "\n")
        try contentA.write(to: urlA, atomically: true, encoding: .utf8)

        let urlB = tempDirectory.appendingPathComponent("b.json")
        try "line 1\nline 2\nline 3".write(to: urlB, atomically: true, encoding: .utf8)

        let snapshotA = snapshot(forPath: urlA.path)
        let snapshotB = snapshot(forPath: urlB.path)

        let (window, hosting) = mount(snapshotA)
        defer { window.orderOut(nil) }

        _ = await FileTextPreviewCache.shared.preview(for: urlA)
        let (referenceAWindow, referenceA) = mount(snapshotA)
        defer { referenceAWindow.orderOut(nil) }
        try await waitUntil("file A converges") { try bitmap(hosting) == bitmap(referenceA) }
        let bitmapA = try bitmap(hosting)

        hosting.rootView = ClipboardInspectorPane(snapshot: snapshotB)
        _ = await FileTextPreviewCache.shared.preview(for: urlB)
        let (referenceBWindow, referenceB) = mount(snapshotB)
        defer { referenceBWindow.orderOut(nil) }
        try await waitUntil("file B converges") { try bitmap(hosting) == bitmap(referenceB) }

        let bitmapB = try bitmap(hosting)
        #expect(bitmapB != bitmapA)
    }

    @Test(arguments: ["binary", "missing", "directory"])
    func unreadableFilesFallBackToMetadataOnly(scenario: String) async throws {
        let url: URL
        switch scenario {
        case "binary":
            url = tempDirectory.appendingPathComponent("unreadable-binary.txt")
            var data = Data("Header".utf8)
            data.append(0x00)
            data.append(contentsOf: "Body".utf8)
            try data.write(to: url)
        case "missing":
            url = tempDirectory
                .appendingPathComponent("unreadable-missing-\(UUID().uuidString).json")
        case "directory":
            url = tempDirectory.appendingPathComponent("unreadable-directory.md")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        default:
            Issue.record("unexpected scenario: \(scenario)")
            return
        }

        let entrySnapshot = snapshot(forPath: url.path)
        let (window, hosting) = mount(entrySnapshot)
        defer { window.orderOut(nil) }
        let (controlWindow, control) = mount(metadataOnlyControl(entrySnapshot))
        defer { controlWindow.orderOut(nil) }

        try await waitUntil("falls back to metadata-only rendering") {
            try bitmap(hosting) == bitmap(control)
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root ignores file permissions"))
    func permissionDeniedFileFallsBackToMetadataOnly() async throws {
        let url = tempDirectory.appendingPathComponent("secret.txt")
        try "Top secret".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }

        let entrySnapshot = snapshot(forPath: url.path)
        let (window, hosting) = mount(entrySnapshot)
        defer { window.orderOut(nil) }
        let (controlWindow, control) = mount(metadataOnlyControl(entrySnapshot))
        defer { controlWindow.orderOut(nil) }

        try await waitUntil("permission-denied file falls back to metadata-only") {
            try bitmap(hosting) == bitmap(control)
        }
    }

    @Test func emptyFileRendersAnExplicitEmptyState() async throws {
        let url = tempDirectory.appendingPathComponent("empty-state.txt")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let entrySnapshot = snapshot(forPath: url.path)
        _ = await FileTextPreviewCache.shared.preview(for: url)

        let (emptyWindow, emptyHosting) = mount(entrySnapshot)
        defer { emptyWindow.orderOut(nil) }

        let (controlWindow, control) = mount(metadataOnlyControl(entrySnapshot))
        defer { controlWindow.orderOut(nil) }
        try await waitUntil("empty-file state differs from metadata-only rendering") {
            try bitmap(emptyHosting) != bitmap(control)
        }
        let emptyBitmap = try bitmap(emptyHosting)

        try "Line 1".write(to: url, atomically: true, encoding: .utf8)
        let future = Date(timeIntervalSinceNow: 5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
        _ = await FileTextPreviewCache.shared.preview(for: url)

        let (oneLineWindow, oneLineHosting) = mount(entrySnapshot)
        defer { oneLineWindow.orderOut(nil) }
        try await waitUntil("one-line file differs from the empty-file state") {
            try bitmap(oneLineHosting) != emptyBitmap
        }
    }

    // MARK: - Test Helpers

    /// `.task` only runs for a view that is inside a window, so the hosting
    /// view is mounted in an offscreen borderless window rather than left
    /// free-floating.
    private func mount(
        _ snapshot: ClipboardInspector?
    ) -> (NSWindow, NSHostingView<ClipboardInspectorPane>) {
        let width = FloodlightMetrics.clipboardInspectorWidth
        let height = FloodlightMetrics.expandedPanelHeight
        let hosting = NSHostingView(rootView: ClipboardInspectorPane(snapshot: snapshot))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// Rasterises the hosting view. Non-optional on purpose: a comparison of
    /// two missing bitmaps must fail loudly rather than pass as `nil == nil`.
    private func bitmap(
        _ hosting: NSView,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Data {
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            sourceLocation: sourceLocation
        )
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return try #require(representation.tiffRepresentation, sourceLocation: sourceLocation)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never became true: \(description)", sourceLocation: sourceLocation)
    }

    private func snapshot(
        forPath path: String,
        kind: ClipboardEntryKind = .text
    ) -> ClipboardInspector {
        ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "snapshot-\(path)",
            text: path,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_785_250_800),
            sourceAppBundleID: "com.apple.finder"
        ))
    }

    private func metadataOnlyControl(_ snapshot: ClipboardInspector) -> ClipboardInspector {
        guard case let .file(detail) = snapshot else { return snapshot }
        return .file(ClipboardInspector.FileDetail(
            name: detail.name,
            path: detail.path,
            type: detail.type,
            contentType: detail.contentType,
            byteCount: detail.byteCount,
            isVideo: detail.isVideo,
            isImage: detail.isImage,
            isText: false,
            isCode: false,
            sourceApp: detail.sourceApp,
            sourceAppBundleID: detail.sourceAppBundleID,
            createdAt: detail.createdAt,
            formattedDate: detail.formattedDate,
            fileURL: detail.fileURL
        ))
    }
}
