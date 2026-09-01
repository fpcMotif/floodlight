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
}
