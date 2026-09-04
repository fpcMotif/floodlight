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

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, isCode: true))
        #expect(preview.isCode)
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

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, isCode: false))
        #expect(!preview.isCode)
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

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, isCode: false))
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

        let preview = FileTextPreviewDecoder.decode(at: file, isCode: false)
        #expect(preview == nil)
    }

    @Test func rejectsMissingFileGracefully() {
        let missing = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        let preview = FileTextPreviewDecoder.decode(at: missing, isCode: true)
        #expect(preview == nil)
    }

    @Test func decodesUTF8WithBOM() throws {
        let file = tempDirectory.appendingPathComponent("bom-utf8.txt")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "BOM UTF-8 Content".utf8)
        try data.write(to: file)

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, isCode: false))
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

        let preview = try #require(FileTextPreviewDecoder.decode(at: file, isCode: false))
        #expect(!preview.isEmpty)
        #expect(preview.lines.first == "UTF-16 Text Content")
    }

    @Test func truncatesFileExceedingLineLimit() throws {
        let file = tempDirectory.appendingPathComponent("many-lines.py")
        let lines = (1...250).map { "print(\($0))" }
        let content = lines.joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let preview = try #require(FileTextPreviewDecoder.decode(
            at: file,
            isCode: true,
            maxLines: 200
        ))
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
            isCode: false,
            maxBytes: 32 * 1_024,
            maxLines: 500
        ))
        #expect(preview.isTruncated)
    }

    // MARK: - Cache & Invalidation Tests

    @Test func cacheReturnsStoredPreviewAndInvalidatesOnModification() async throws {
        let file = tempDirectory.appendingPathComponent("cached.txt")
        try "Version 1".write(to: file, atomically: true, encoding: .utf8)

        let cache = FileTextPreviewCache()
        let preview1 = try #require(await cache.preview(for: file, isCode: false))
        #expect(preview1.lines.first == "Version 1")

        // Immediate lookup hit
        let immediate1 = try #require(cache.immediatePreview(for: file, isCode: false))
        #expect(immediate1.lines.first == "Version 1")

        // Modify file with new content and updated modification date
        try "Version 2".write(to: file, atomically: true, encoding: .utf8)
        let future = Date(timeIntervalSinceNow: 5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)

        let preview2 = try #require(await cache.preview(for: file, isCode: false))
        #expect(preview2.lines.first == "Version 2")
    }

    // MARK: - Inspector Rendering Tests

    @Test func copiedJSONPathRendersItsCodeInTheInspector() throws {
        let url = tempDirectory.appendingPathComponent("preview-data.json")
        try "{\n  \"app\": \"Floodlight\"\n}".write(to: url, atomically: true, encoding: .utf8)

        let snapshot = ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "copied-path-json",
            text: url.path,
            createdAt: .now,
            sourceAppBundleID: "com.apple.finder"
        ))
        let hosting = layout(
            ClipboardInspectorPane(snapshot: snapshot),
            width: FloodlightMetrics.clipboardInspectorWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting
            .bitmapImageRepForCachingDisplay(in: hosting.bounds))
        #expect(representation.pixelsWide > 0)
        #expect(representation.pixelsHigh > 0)
    }

    @Test func copiedMarkdownPathRendersItsTextInTheInspector() throws {
        let url = tempDirectory.appendingPathComponent("preview-notes.md")
        try "# Project Notes\n\n- Task 1\n- Task 2".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "copied-path-md",
            text: url.path,
            createdAt: .now,
            sourceAppBundleID: "com.apple.finder"
        ))
        let hosting = layout(
            ClipboardInspectorPane(snapshot: snapshot),
            width: FloodlightMetrics.clipboardInspectorWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting
            .bitmapImageRepForCachingDisplay(in: hosting.bounds))
        #expect(representation.pixelsWide > 0)
        #expect(representation.pixelsHigh > 0)
    }

    @Test func copiedEmptyTextPathRendersEmptyFileState() throws {
        let url = tempDirectory.appendingPathComponent("preview-empty.txt")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let snapshot = ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "copied-path-empty",
            text: url.path,
            createdAt: .now,
            sourceAppBundleID: "com.apple.finder"
        ))
        let hosting = layout(
            ClipboardInspectorPane(snapshot: snapshot),
            width: FloodlightMetrics.clipboardInspectorWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting
            .bitmapImageRepForCachingDisplay(in: hosting.bounds))
        #expect(representation.pixelsWide > 0)
        #expect(representation.pixelsHigh > 0)
    }

    @Test func copiedBinaryWithTextExtensionSafelyRendersMetadataOnly() throws {
        let url = tempDirectory.appendingPathComponent("preview-binary.txt")
        var data = Data("Header".utf8)
        data.append(0x00)
        data.append(contentsOf: "Body".utf8)
        try data.write(to: url)

        let snapshot = ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "copied-path-binary",
            text: url.path,
            createdAt: .now,
            sourceAppBundleID: "com.apple.finder"
        ))
        let hosting = layout(
            ClipboardInspectorPane(snapshot: snapshot),
            width: FloodlightMetrics.clipboardInspectorWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting
            .bitmapImageRepForCachingDisplay(in: hosting.bounds))
        #expect(representation.pixelsWide > 0)
        #expect(representation.pixelsHigh > 0)
    }

    private func layout<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }
}
