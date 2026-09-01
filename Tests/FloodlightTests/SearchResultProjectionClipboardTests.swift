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
}
