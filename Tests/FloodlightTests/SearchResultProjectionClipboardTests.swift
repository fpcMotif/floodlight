import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

struct SearchResultProjectionClipboardTests {
    /// The row title is the entry's text collapsed to one line. The
    /// projection does that over UTF-8 bytes (#73); this is the Character
    /// definition it must agree with, on every newline Swift knows and on
    /// the adversarial corpus.
    @Test func textRowTitlesCollapseLinesExactlyAsACharacterWalkWould() {
        let crafted = [
            "a\r\nb", "\n\na\n\n", "a\u{85}b", "a\u{2028}b\u{2029}c", "e\u{301}\nx",
            "  a  \n  b  ", "a\n\n\nb", "\u{85}", "×\n÷", "\r\n", " \n ", "a \n \nb",
            "\u{0B}v\u{0C}f", "\u{FEFF}\nx", "🦊\n🦊", "\u{C2}", "\u{E2}\u{80}",
        ]
        let now = Date(timeIntervalSince1970: 2_120)
        for text in crafted + AdversarialCorpus.strings {
            let entry = ClipboardEntry(id: "t", text: text, createdAt: now)
            // A copied path is titled by its file name, not its text.
            if case .path? = entry.textContent { continue }
            let reference = text.split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let expected = reference.isEmpty ? "(Empty text)" : reference
            let title = SearchResultProjection.project(
                .clipboard(.init(entries: [entry], selection: nil, now: now))
            ).allRows[0].title
            #expect(title == expected, "text \(text.debugDescription)")
        }
    }

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
                entries: [pinned, unpinned],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)
        #expect(publication.allRows.count == 2)
        #expect(publication.filterOptions.map(\.filter) == [.all, .text, .files, .images])
        #expect(publication.progress == .settled)

        let firstRow = publication.visibleRows[0]
        #expect(firstRow.id == "clipboard:entry-1")
        #expect(firstRow.title == "Pinned multi-line address line 2")
        #expect(firstRow.isPinned)
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
                entries: [file, folder],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)

        let fileRow = publication.visibleRows[0]
        #expect(fileRow.id == "clipboard:file-1")
        #expect(fileRow.title == "Invoice_2026.pdf")
        #expect(fileRow.subtitle == "Clipboard · 2m · Invoices")
        #expect(!fileRow.isPinned)
        #expect(fileRow.kind == .clipboard)
        #expect(fileRow.fileURL == URL(fileURLWithPath: path))
        #expect(fileRow.iconSource == .inferred)
        #expect(fileRow.action == .copyFiles([path]))

        let folderRow = publication.visibleRows[1]
        #expect(folderRow.title == "floodlight")
        #expect(folderRow.isPinned)
        #expect(folderRow.subtitle == "Clipboard · 2m · devv")
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
                entries: [image, pinned],
                selection: nil,
                now: now
            ))
        )

        #expect(publication.visibleRows.count == 2)

        let imageRow = publication.visibleRows[0]
        #expect(imageRow.id == "clipboard:image-1")
        #expect(imageRow.title == "CleanShot 2026-09-01 at 15.30.png")
        #expect(imageRow.subtitle == "Clipboard · 2m · 2880×1800")
        #expect(imageRow.kind == .clipboard)
        #expect(imageRow.fileSize == 1_400_000)
        #expect(imageRow.iconSource == .thumbnail(thumbnail))
        #expect(imageRow.action == .copyImage(id: "image-1"))

        let pinnedRow = publication.visibleRows[1]
        #expect(pinnedRow.title == "AppMockup_Dark_v2.png")
        #expect(pinnedRow.isPinned)
        #expect(pinnedRow.subtitle == "Clipboard · 2m · 1440×900")
        #expect(pinnedRow.fileSize == 480_000)
        #expect(pinnedRow.action == .copyImage(id: "image-2"))
    }

    /// Copied text that names a file is a path row whether or not the file
    /// exists (#73): the row carries the URL, the parent folder, and the
    /// kind's icon, and the selection — not the projection — decides
    /// whether anything can be opened.
    @Test func clipboardProjectionKeepsACopiedPathAsAPathRowWhenTheFileIsGone() {
        let created = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120)
        let path = "/definitely/missing/Screens/shot.png"
        let entry = ClipboardEntry(id: "path-1", text: path, createdAt: created)

        let publication = SearchResultProjection.project(
            .clipboard(.init(entries: [entry], selection: nil, now: now))
        )

        let row = publication.visibleRows[0]
        #expect(row.id == "clipboard:path-1")
        #expect(row.title == "shot.png")
        #expect(row.subtitle == "Clipboard · 2m · Screens")
        #expect(row.iconSource == .engine(symbol: "photo", tint: .cyan))
        #expect(row.fileURL == URL(fileURLWithPath: path))
        #expect(row.action == .copy(path))
        #expect(publication.filterOptions.map(\.count) == [1, 1, 0, 0])
    }

    /// A publication is its rows scoped by the filter, so Clipboard Search
    /// can keep one publication's rows and rerun only the scoping.
    @Test func clipboardProjectionComposesFromItsRowsAndTheirScoping() {
        let created = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120)
        let entries = [
            ClipboardEntry(id: "text-1", text: "#3498DB", createdAt: created),
            ClipboardEntry(id: "file-1", text: "/Users/f/a.pdf", kind: .file, createdAt: created),
        ]
        let selection = SearchResultSelection(id: "clipboard:file-1", origin: .user)

        let whole = SearchResultProjection.project(
            .clipboard(.init(
                entries: entries,
                selectedFilter: .files,
                selection: selection,
                now: now
            ))
        )
        let composed = SearchResultProjection.clipboardPublication(
            rows: whole.allRows,
            selectedFilter: .files,
            selection: selection
        )

        #expect(composed == whole)
        #expect(composed.visibleRows.map(\.id) == ["clipboard:file-1"])
        #expect(composed.allRows[0].iconSource == .engine(
            symbol: "paintpalette.fill",
            tint: .purple
        ))
        #expect(composed.selection?.id == "clipboard:file-1")
    }

    @Test func clipboardProjectionPublishesTypeChipsAndScopesVisibleRows() {
        let created = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 2_120)
        let text = ClipboardEntry(
            id: "text-1",
            text: "Acme billing address",
            createdAt: created
        )
        let file = ClipboardEntry(
            id: "file-1",
            text: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf",
            kind: .file,
            createdAt: created
        )
        let image = ClipboardEntry(
            id: "image-1",
            text: "Screenshot 2026-09-01.png",
            kind: .image,
            createdAt: created,
            image: ClipboardImageMetadata(
                hash: "abc",
                width: 2_880,
                height: 1_800,
                byteCount: 1_400_000,
                thumbnailPNGData: Data(repeating: 0xEF, count: 32)
            )
        )
        let entries = [text, file, image]

        let all = SearchResultProjection.project(
            .clipboard(.init(
                entries: entries,
                selectedFilter: .all,
                selection: nil,
                now: now
            ))
        )

        #expect(all.filterOptions.map(\.filter) == [.all, .text, .files, .images])
        #expect(all.filterOptions.map(\.count) == [3, 1, 1, 1])
        #expect(all.filterOptions.allSatisfy { !$0.isLoading })
        #expect(all.selectedFilter == .all)
        #expect(all.visibleRows.map(\.id) == [
            "clipboard:text-1",
            "clipboard:file-1",
            "clipboard:image-1",
        ])

        let textOnly = SearchResultProjection.project(
            .clipboard(.init(
                entries: entries,
                selectedFilter: .text,
                selection: nil,
                now: now
            ))
        )
        #expect(textOnly.selectedFilter == .text)
        #expect(textOnly.visibleRows.map(\.id) == ["clipboard:text-1"])
        #expect(textOnly.filterOptions.map(\.count) == [3, 1, 1, 1])

        let filesOnly = SearchResultProjection.project(
            .clipboard(.init(
                entries: entries,
                selectedFilter: .files,
                selection: nil,
                now: now
            ))
        )
        #expect(filesOnly.visibleRows.map(\.id) == ["clipboard:file-1"])

        let imagesOnly = SearchResultProjection.project(
            .clipboard(.init(
                entries: entries,
                selectedFilter: .images,
                selection: nil,
                now: now
            ))
        )
        #expect(imagesOnly.visibleRows.map(\.id) == ["clipboard:image-1"])
    }
}
