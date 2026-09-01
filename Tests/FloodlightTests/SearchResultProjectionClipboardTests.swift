import FloodlightEngine
import Foundation
import Testing
@testable import Floodlight

struct SearchResultProjectionClipboardTests {
    @Test func clipboardProjectionGeneratesRowsInExactOrderWithMetadata() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120) // 120s later = 2m later

        let pinned = ClipboardEntry(
            id: "entry-1",
            text: "Pinned multi-line\naddress line 2",
            createdAt: t0,
            sourceAppBundleID: "com.apple.Notes",
            pinnedAt: t1
        )
        let unpinned = ClipboardEntry(
            id: "entry-2",
            text: "https://vendor.example/inv/2214",
            createdAt: t1,
            sourceAppBundleID: "company.thebrowser.Arc",
            pinnedAt: nil
        )

        let publication = SearchResultProjection.project(
            .clipboard(.init(
                query: "inv",
                entries: [pinned, unpinned],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)
        #expect(publication.allRows.count == 2)
        #expect(publication.filterOptions.isEmpty)
        #expect(publication.progress == .settled)

        let firstRow = publication.visibleRows[0]
        #expect(firstRow.id == "clipboard:entry-1")
        #expect(firstRow.title == "📌 Pinned multi-line address line 2")
        #expect(firstRow.subtitle == "Notes · 18m")
        #expect(firstRow.kind == .clipboard)
        #expect(firstRow.action == .copy("Pinned multi-line\naddress line 2"))

        let secondRow = publication.visibleRows[1]
        #expect(secondRow.id == "clipboard:entry-2")
        #expect(secondRow.title == "https://vendor.example/inv/2214")
        #expect(secondRow.subtitle == "Arc · 2m")
        #expect(secondRow.kind == .clipboard)
        #expect(secondRow.action == .copy("https://vendor.example/inv/2214"))
    }

    @Test func clipboardProjectionRendersFileEntriesWithNamePathAndFileURL() {
        let created = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120)
        let path = "/Users/f/Documents/Invoices/Invoice_2026.pdf"
        let folderPath = "/Users/f/devv/floodlight"

        let file = ClipboardEntry(
            id: "file-1",
            text: path,
            kind: .file,
            createdAt: created
        )
        let folder = ClipboardEntry(
            id: "file-2",
            text: folderPath,
            kind: .file,
            createdAt: created,
            pinnedAt: now
        )

        let publication = SearchResultProjection.project(
            .clipboard(.init(
                query: "invoice",
                entries: [file, folder],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)

        let fileRow = publication.visibleRows[0]
        #expect(fileRow.id == "clipboard:file-1")
        #expect(fileRow.title == "Invoice_2026.pdf")
        #expect(fileRow.subtitle == path)
        #expect(fileRow.kind == .clipboard)
        #expect(fileRow.fileURL == URL(fileURLWithPath: path))
        #expect(fileRow.iconSource == .inferred)
        #expect(fileRow.action == .copyFiles([path]))

        let folderRow = publication.visibleRows[1]
        #expect(folderRow.title == "📌 floodlight")
        #expect(folderRow.subtitle == folderPath)
        #expect(folderRow.fileURL == URL(fileURLWithPath: folderPath))
        #expect(folderRow.action == .copyFiles([folderPath]))
    }

    @Test func clipboardProjectionRendersImageEntriesWithThumbnailDimensionsAndTimestamp() {
        let created = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120)
        let thumbnail = Data(repeating: 0xEF, count: 32)

        let image = ClipboardEntry(
            id: "image-1",
            text: "CleanShot 2026-09-01 at 15.30.png",
            kind: .image,
            createdAt: created,
            image: ClipboardImageMetadata(
                hash: "abc",
                width: 2_880,
                height: 1_800,
                byteCount: 1_400_000,
                thumbnailPNGData: thumbnail
            )
        )
        let pinned = ClipboardEntry(
            id: "image-2",
            text: "AppMockup_Dark_v2.png",
            kind: .image,
            createdAt: created,
            pinnedAt: now,
            image: ClipboardImageMetadata(
                hash: "def",
                width: 1_440,
                height: 900,
                byteCount: 480_000,
                thumbnailPNGData: thumbnail
            )
        )

        let publication = SearchResultProjection.project(
            .clipboard(.init(
                query: "screenshot",
                entries: [image, pinned],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)

        let imageRow = publication.visibleRows[0]
        #expect(imageRow.id == "clipboard:image-1")
        #expect(imageRow.title == "CleanShot 2026-09-01 at 15.30.png")
        #expect(imageRow.subtitle == "2880×1800 · 2m")
        #expect(imageRow.kind == .clipboard)
        #expect(imageRow.fileSize == 1_400_000)
        #expect(imageRow.iconSource == .thumbnail(thumbnail))
        #expect(imageRow.action == .copyImage(id: "image-1"))

        let pinnedRow = publication.visibleRows[1]
        #expect(pinnedRow.title == "📌 AppMockup_Dark_v2.png")
        #expect(pinnedRow.subtitle == "1440×900 · 2m")
        #expect(pinnedRow.fileSize == 480_000)
        #expect(pinnedRow.action == .copyImage(id: "image-2"))
    }
}
