import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Drives Clipboard Search through its interface with an in-memory store:
/// record entries, ask for a publication, move the selection, issue commands,
/// and read the facts it publishes. Nothing here renders a view, and nothing
/// asserts on how a row identifier is spelled.
@MainActor
struct ClipboardSearchTests {
    private let tree: TemporaryTree
    private let previewDirectory: URL

    init() throws {
        tree = try TemporaryTree(label: "ClipboardSearch")
        previewDirectory = tree.root.appendingPathComponent("previews", isDirectory: true)
    }

    private func makeSearch(
        store: ClipboardHistoryStore,
        now: @escaping () -> Date = { .now }
    ) -> ClipboardSearch {
        ClipboardSearch(store: store, previewDirectory: previewDirectory, now: now)
    }

    private func publish(
        _ search: ClipboardSearch,
        query: String = "",
        filter: SearchResultFilter = .all,
        selection: SearchResultSelection? = nil
    ) -> SearchResultPublication {
        search.publication(query: query, selectedFilter: filter, selection: selection)
    }

    private func row(
        titled title: String,
        in publication: SearchResultPublication
    ) throws -> SearchItem {
        try #require(publication.visibleRows.first { $0.title == title })
    }

    // MARK: - Rows

    @Test func publicationListsPinnedThenRecentEntriesAndInspectsTheFirst() throws {
        let store = ClipboardHistoryStore.inMemory()
        let old = try #require(store.record(text: "Old copy"))
        _ = store.record(text: "New copy")
        _ = store.record(text: "Newest copy")
        store.pin(id: old.id)

        let search = makeSearch(store: store)
        let publication = publish(search)

        #expect(publication.visibleRows.map(\.title) == ["Old copy", "Newest copy", "New copy"])
        #expect(publication.visibleRows[0].isPinned)
        #expect(publication.selection?.id == publication.visibleRows[0].id)
        guard case let .text(detail) = search.inspector else {
            Issue.record("the first row should be inspected as soon as it is published")
            return
        }
        #expect(detail.body == "Old copy")
        #expect(search.isSelectionPinned)
    }

    @Test func queryAndFilterScopeTheRowsAndTheChipCounts() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Invoice #101")
        _ = store.record(text: "Receipt #202")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3.pdf"))
        _ = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 32,
            height: 16,
            displayName: "Invoice screenshot"
        ))

        let search = makeSearch(store: store)
        let everything = publish(search)
        #expect(everything.filterOptions.map(\.filter) == [.all, .text, .files, .images])
        #expect(everything.filterOptions.map(\.count) == [4, 2, 1, 1])
        #expect(everything.visibleRows.count == 4)

        let files = publish(search, filter: .files)
        #expect(files.selectedFilter == .files)
        #expect(files.visibleRows.map(\.title) == ["Invoice_Q3.pdf"])

        let invoices = publish(search, query: "Invoice", filter: .text)
        #expect(invoices.visibleRows.map(\.title) == ["Invoice #101"])

        let nothing = publish(search, query: "zzz")
        #expect(nothing.visibleRows.isEmpty)
        #expect(search.inspector == nil)
    }

    @Test func aFilterOutsideClipboardModeFallsBackToAll() {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Snippet")

        let search = makeSearch(store: store)
        let publication = publish(search, filter: .applications)

        #expect(publication.selectedFilter == .all)
        #expect(publication.visibleRows.count == 1)
    }

    @Test func rowAgesAreReadAgainstTheInjectedClock() throws {
        let store = ClipboardHistoryStore.inMemory()
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try #require(store.record(text: "Five minutes ago", date: recorded))

        let search = makeSearch(store: store, now: { recorded.addingTimeInterval(5 * 60) })
        let publication = publish(search)

        #expect(publication.visibleRows[0].subtitle == "Clipboard · 5m")
    }

    @Test func aRowMapsBackToItsEntryAndAForeignRowToNothing() throws {
        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.record(text: "Snippet"))

        let search = makeSearch(store: store)
        let publication = publish(search)

        #expect(ClipboardSearch.entryID(forRowID: publication.visibleRows[0].id) == entry.id)
        #expect(ClipboardSearch.entryID(forRowID: "calculator") == nil)
    }

    // MARK: - Selection facts

    @Test func movingTheSelectionRepublishesTheInspectorAndFinderLocation() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        let path = "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"
        _ = try #require(store.recordFile(path: path))

        let search = makeSearch(store: store)
        let publication = publish(search)

        guard case let .file(file) = search.inspector else {
            Issue.record("the newest file entry should be inspected first")
            return
        }
        #expect(file.name == "Invoice_Q3_Final.pdf")
        #expect(search.selectionFileURL == URL(fileURLWithPath: path))

        try search.selectionDidMove(to: row(titled: "Acme billing address", in: publication))
        guard case let .text(text) = search.inspector else {
            Issue.record("moving the selection should inspect the text entry")
            return
        }
        #expect(text.body == "Acme billing address")
        #expect(search.selectionFileURL == nil)
        #expect(!search.isSelectionPreviewable)
    }

    @Test func leavingTheSelectionBehindClearsEveryPublishedFact() throws {
        let store = ClipboardHistoryStore.inMemory()
        let fileURL = tree.root.appendingPathComponent("shot.png")
        try Data("shot-bytes".utf8).write(to: fileURL)
        _ = try #require(store.recordFile(path: fileURL.path))

        let search = makeSearch(store: store)
        _ = publish(search)
        #expect(search.inspector != nil)
        #expect(search.isSelectionPreviewable)
        #expect(search.selectionFileURL == fileURL)

        search.selectionDidMove(to: nil)

        #expect(search.inspector == nil)
        #expect(!search.isSelectionPinned)
        #expect(!search.isSelectionPreviewable)
        #expect(search.selectionFileURL == nil)
        #expect(search.materializePreviewURL() == nil)
    }

    @Test func imageSelectionPublishesItsSnapshotWithoutMaterializingAPreview() throws {
        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            tiffData: nil,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "Screenshot"
        ))

        let search = makeSearch(store: store)
        _ = publish(search)

        guard case let .image(detail) = search.inspector else {
            Issue.record("selecting an image entry should publish an image snapshot")
            return
        }
        #expect(detail.entryID == entry.id)
        #expect(detail.width == 2_880)
        #expect(detail.height == 1_800)
        #expect(detail.thumbnailPNG == ClipboardImageTestData.thumbnail)
        #expect(detail.hasFullImage)
        #expect(search.isSelectionPreviewable)

        // Browsing writes nothing. The temporary file belongs to the preview
        // action, and only once the user actually takes it.
        #expect(!FileManager.default.fileExists(atPath: previewDirectory.path))

        let previewURL = try #require(search.materializePreviewURL())
        #expect(previewURL.deletingLastPathComponent() == previewDirectory)
        #expect(try Data(contentsOf: previewURL) == ClipboardImageTestData.png)
    }

    @Test func anImageWithOnlyATIFFPayloadStillHasAFullImage() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.recordImage(
            pngData: nil,
            tiffData: ClipboardImageTestData.tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 64,
            height: 32,
            displayName: "Screenshot"
        ))

        let search = makeSearch(store: store)
        _ = publish(search)

        guard case let .image(detail) = search.inspector else {
            Issue.record("selecting an image entry should publish an image snapshot")
            return
        }
        #expect(detail.hasFullImage)
        #expect(detail.thumbnailPNG == ClipboardImageTestData.thumbnail)

        let previewURL = try #require(search.materializePreviewURL())
        #expect(previewURL.pathExtension == "tiff")
        #expect(try Data(contentsOf: previewURL) == ClipboardImageTestData.tiff)
    }

    @Test func previewabilityAgreesWithWhatThePreviewActionCanOpen() throws {
        let store = ClipboardHistoryStore.inMemory()
        let shotURL = tree.root.appendingPathComponent("shot.png")
        try Data("shot-bytes".utf8).write(to: shotURL)
        let movieURL = tree.root.appendingPathComponent("sample.mp4")
        try Data("video-bytes".utf8).write(to: movieURL)
        _ = try #require(store.record(text: "just some copied words"))
        _ = try #require(store.record(text: "/definitely/missing/file.png"))
        _ = try #require(store.record(text: shotURL.path))
        _ = try #require(store.recordFile(path: movieURL.path))
        _ = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 100,
            height: 100,
            displayName: "Screenshot"
        ))

        let search = makeSearch(store: store)
        let publication = publish(search)
        #expect(publication.visibleRows.count == 5)

        // The Actions menu reads the published flag and Space materializes
        // the URL; the two must never disagree about the same row.
        var previewable: [String: Bool] = [:]
        for item in publication.visibleRows {
            search.selectionDidMove(to: item)
            #expect(search.isSelectionPreviewable == (search.materializePreviewURL() != nil))
            previewable[item.title] = search.isSelectionPreviewable
        }
        #expect(previewable == [
            "just some copied words": false,
            "file.png": false,
            "shot.png": true,
            "sample.mp4": true,
            "Screenshot": true,
        ])

        try search.selectionDidMove(to: row(titled: "shot.png", in: publication))
        #expect(search.materializePreviewURL() == shotURL)
        try search.selectionDidMove(to: row(titled: "sample.mp4", in: publication))
        #expect(search.materializePreviewURL() == movieURL)
    }

    @Test func aCopiedPathToAMissingFileStillReadsAsAPathButOpensNothing() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "/definitely/missing/Reports/report.pdf"))

        let search = makeSearch(store: store)
        let publication = publish(search)
        let row = try row(titled: "report.pdf", in: publication)

        // The row keeps saying what was copied…
        #expect(row.fileURL == URL(fileURLWithPath: "/definitely/missing/Reports/report.pdf"))
        #expect(row.subtitle == "Clipboard · just now · Reports")
        #expect(row.iconSource == .inferred)
        // …while the selection, the one place that stats the path, offers
        // neither Quick Look nor "Show in Finder" for it.
        #expect(publication.selection?.id == row.id)
        #expect(!search.isSelectionPreviewable)
        #expect(search.selectionFileURL == nil)
        #expect(search.materializePreviewURL() == nil)
        guard case let .file(detail) = search.inspector else {
            Issue.record("a copied path is inspected as the file it names")
            return
        }
        #expect(detail.name == "report.pdf")
        #expect(detail.byteCount == nil)
    }

    // MARK: - Memoized rows (#73)

    /// The rows are reused when nothing they depend on has changed, and
    /// rebuilt the moment something has. A row's age is what makes the
    /// difference observable: a reused row still says what the clock said
    /// when it was built.
    @Test func rowsAreReusedAcrossChipSwitchesAndRebuiltByAKeystrokeOrAWrite() throws {
        let store = ClipboardHistoryStore.inMemory()
        // On a minute boundary, so every read below falls inside one minute
        // until the last, which crosses it.
        let minuteStart = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let snippet = try #require(store.record(
            text: "Snippet",
            date: minuteStart.addingTimeInterval(-30)
        ))
        _ = try #require(store.record(text: "Tick", date: minuteStart))
        var now = minuteStart
        let search = makeSearch(store: store, now: { now })
        func ages(_ publication: SearchResultPublication) -> [String] {
            publication.visibleRows.map(\.subtitle)
        }

        #expect(ages(publish(search)) == ["Clipboard · just now", "Clipboard · just now"])

        // Fifty-nine seconds on, Snippet is 89 seconds old. A chip switch
        // over the same query and history reuses the rows as they were built.
        now = minuteStart.addingTimeInterval(59)
        let chipSwitch = publish(search, filter: .text)
        #expect(chipSwitch.selectedFilter == .text)
        #expect(ages(chipSwitch) == ["Clipboard · just now", "Clipboard · just now"])

        // A different query is a keystroke: the rows are rebuilt.
        #expect(ages(publish(search, query: "Sni")) == ["Clipboard · 1m"])
        // Back on the first query the memo is one deep, so this rebuilds too.
        #expect(ages(publish(search)) == ["Clipboard · just now", "Clipboard · 1m"])

        // A store write invalidates rows the same query would otherwise reuse.
        store.pin(id: snippet.id)
        let afterPin = publish(search)
        #expect(afterPin.visibleRows.map(\.title) == ["Snippet", "Tick"])
        #expect(afterPin.visibleRows[0].isPinned)
        #expect(ages(afterPin) == ["Clipboard · 1m", "Clipboard · just now"])

        // And so does the clock ticking into the next minute: Tick turns a
        // minute old exactly then, which reused rows would not show.
        now = minuteStart.addingTimeInterval(60)
        #expect(ages(publish(search)) == ["Clipboard · 1m", "Clipboard · 1m"])
    }

    /// The icon, title, and subtitle a row gets are read off the
    /// classification the store recorded with the entry; nothing here
    /// classifies a fixture by hand.
    @Test func rowsRecordedThroughTheStoreCarryTheirKindsIconTitleAndSubtitle() throws {
        let store = ClipboardHistoryStore.inMemory()
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try #require(store.record(
            text: "Acme billing address",
            sourceAppBundleID: "com.apple.Notes",
            date: recorded
        ))
        _ = try #require(store.record(text: "{\"name\": \"floodlight\"}", date: recorded))
        _ = try #require(store.record(text: "#3498DB", date: recorded))
        _ = try #require(store.record(text: "https://www.example.org/docs", date: recorded))
        _ = try #require(store.record(text: "/Users/f/Screens/shot.png", date: recorded))

        let search = makeSearch(store: store, now: { recorded.addingTimeInterval(120) })
        let rows = publish(search).visibleRows

        #expect(rows.map(\.title) == [
            "shot.png",
            "https://www.example.org/docs",
            "#3498DB",
            "{\"name\": \"floodlight\"}",
            "Acme billing address",
        ])
        #expect(rows.map(\.iconSource) == [
            .engine(symbol: "photo", tint: .cyan),
            .engine(symbol: "link", tint: .blue),
            .engine(symbol: "paintpalette.fill", tint: .purple),
            .engine(symbol: "curlybraces", tint: .cyan),
            .engine(symbol: "doc.text", tint: .gray),
        ])
        #expect(rows.map(\.subtitle) == [
            "Clipboard · 2m · Screens",
            "Clipboard · 2m",
            "Clipboard · 2m",
            "Clipboard · 2m",
            "Notes · 2m",
        ])
    }

    @Test func aCommandOnTheSelectionRepublishesFreshRows() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Keep"))
        _ = try #require(store.record(text: "Drop"))

        let search = makeSearch(store: store)
        let before = publish(search)
        #expect(before.visibleRows.map(\.title) == ["Drop", "Keep"])

        #expect(search.deleteSelection())
        let after = publish(search)
        #expect(after.visibleRows.map(\.title) == ["Keep"])
    }

    @Test func thePreviewDirectoryDefaultsToFloodlightsOwnFolderUnderTemporaryItems() throws {
        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "Screenshot"
        ))
        let expected = ClipboardImageTestData.previewURL(entryID: entry.id)
        try? FileManager.default.removeItem(at: expected)
        defer { try? FileManager.default.removeItem(at: expected) }

        let search = ClipboardSearch(store: store)
        _ = publish(search)

        #expect(search.materializePreviewURL() == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Commands

    @Test func pinningTheSelectionUpdatesItsFactsBeforeTheNextPublication() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "First"))
        _ = try #require(store.record(text: "Second"))

        let search = makeSearch(store: store)
        let publication = publish(search)
        let first = try row(titled: "First", in: publication)
        search.selectionDidMove(to: first)
        #expect(!search.isSelectionPinned)

        #expect(search.pinSelection())
        #expect(search.isSelectionPinned)
        guard case let .text(pinned) = search.inspector else {
            Issue.record("pinning should leave the entry inspected")
            return
        }
        #expect(pinned.pinnedAt != nil)

        // The pinned entry leads the next publication and stays selected.
        let republished = publish(
            search,
            selection: SearchResultSelection(id: first.id, origin: .user)
        )
        #expect(republished.visibleRows.map(\.title) == ["First", "Second"])
        #expect(republished.visibleRows[0].isPinned)
        #expect(republished.selection?.id == republished.visibleRows[0].id)

        #expect(search.unpinSelection())
        #expect(!search.isSelectionPinned)
        #expect(search.togglePinSelection())
        #expect(search.isSelectionPinned)
        #expect(search.togglePinSelection())
        #expect(!search.isSelectionPinned)
    }

    @Test func deletingTheSelectionClearsItsFactsUntilTheNextPublication() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Keep me"))
        _ = try #require(store.record(text: "Delete me"))

        let search = makeSearch(store: store)
        _ = publish(search)
        guard case let .text(detail) = search.inspector, detail.body == "Delete me" else {
            Issue.record("the newest entry should be inspected first")
            return
        }

        #expect(search.deleteSelection())
        #expect(search.inspector == nil)
        #expect(store.count == 1)

        let republished = publish(search)
        #expect(republished.visibleRows.map(\.title) == ["Keep me"])
        guard case let .text(remaining) = search.inspector else {
            Issue.record("the remaining entry should be inspected")
            return
        }
        #expect(remaining.body == "Keep me")
    }

    @Test func commandsTellTheSessionOnlyWhenTheStoreAcceptedTheWrite() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Snippet"))

        let search = makeSearch(store: store)
        var changes = 0
        search.historyDidChange = { changes += 1 }

        // Nothing is selected before the first publication, so there is
        // nothing to pin and nothing to report.
        #expect(!search.togglePinSelection())
        #expect(!search.deleteSelection())
        #expect(changes == 0)

        _ = publish(search)
        #expect(search.togglePinSelection())
        #expect(changes == 1)
        #expect(search.deleteSelection())
        #expect(changes == 2)

        // The entry is gone; a second delete has nothing to apply to.
        #expect(!search.deleteSelection())
        #expect(changes == 2)
    }

    // MARK: - Payloads

    @Test func restorePayloadsCarryTextFileReferencesAndImageBytes() throws {
        let store = ClipboardHistoryStore.inMemory()
        let text = try #require(store.record(text: "Exact Multi-line\nText"))
        let file = try #require(store.recordFile(path: "/Users/f/Documents/Invoice.pdf"))
        let image = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            tiffData: ClipboardImageTestData.tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "Screenshot"
        ))

        let search = makeSearch(store: store)

        #expect(search.restorePayload(for: text.id) == .text("Exact Multi-line\nText"))
        #expect(search.restorePayload(for: file.id) == .files(["/Users/f/Documents/Invoice.pdf"]))
        #expect(search.restorePayload(for: image.id) == .image(ClipboardImagePayload(
            png: ClipboardImageTestData.png,
            tiff: ClipboardImageTestData.tiff
        )))
        #expect(search.restorePayload(for: "no-such-entry") == nil)
    }

    @Test func fullImageBytesAreReadOnDemandAndNeverForOtherKinds() throws {
        let store = ClipboardHistoryStore.inMemory()
        let text = try #require(store.record(text: "words"))
        let image = try #require(store.recordImage(
            pngData: nil,
            tiffData: ClipboardImageTestData.tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "Screenshot"
        ))

        let search = makeSearch(store: store)

        #expect(search.fullImageData(for: image.id) == ClipboardImageTestData.tiff)
        #expect(search.fullImageData(for: text.id) == nil)
    }
}
