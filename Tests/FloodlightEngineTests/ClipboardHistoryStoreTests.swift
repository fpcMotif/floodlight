import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

struct ClipboardHistoryStoreTests {
    private func makeTemporaryDatabaseURL() throws -> (url: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test-clipboard.sqlite3")
        return (dbURL, {
            try? FileManager.default.removeItem(at: tempDir)
        })
    }

    // MARK: - Recording & Size Cap

    @Test func recordingValidTextSucceedsAndPreservesMetadata() throws {
        let store = ClipboardHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let entry = store.record(
            text: "Hello, Floodlight!",
            sourceAppBundleID: "com.apple.Notes",
            date: now
        )

        let unwrapped = try #require(entry)
        #expect(unwrapped.text == "Hello, Floodlight!")
        #expect(unwrapped.sourceAppBundleID == "com.apple.Notes")
        #expect(unwrapped.createdAt == now)
        #expect(!unwrapped.isPinned)
        #expect(store.count == 1)
        #expect(store.mostRecentEntry?.id == unwrapped.id)
    }

    @Test func consecutiveDuplicatesAreCollapsedIntoOneEntry() {
        let store = ClipboardHistoryStore.inMemory()

        let first = store.record(text: "Command C")
        #expect(first != nil)
        #expect(store.count == 1)

        // Pressing ⌘C twice in a row does not create a duplicate row
        let second = store.record(text: "Command C")
        #expect(second == nil)
        #expect(store.count == 1)

        // Interleaving another copy allows the original string to be recorded again
        let third = store.record(text: "Different copy")
        #expect(third != nil)
        #expect(store.count == 2)

        let fourth = store.record(text: "Command C")
        #expect(fourth != nil)
        #expect(store.count == 3)
    }

    @Test func textExceeding32000UTF8BytesIsSkippedEntirely() {
        let store = ClipboardHistoryStore.inMemory()

        // 32,000 bytes exactly is allowed
        let exactSize = String(repeating: "a", count: 32_000)
        #expect(exactSize.utf8.count == 32_000)
        let exactEntry = store.record(text: exactSize)
        #expect(exactEntry != nil)
        #expect(store.count == 1)

        // 32,001 bytes is skipped
        let oversize = String(repeating: "b", count: 32_001)
        #expect(oversize.utf8.count == 32_001)
        let oversizeEntry = store.record(text: oversize)
        #expect(oversizeEntry == nil)
        #expect(store.count == 1)

        // Multi-byte Unicode exceeding 32k bytes is skipped
        let emojiOversize = String(repeating: "🚀", count: 8_001) // 4 bytes each = 32,004 bytes
        #expect(emojiOversize.utf8.count == 32_004)
        let emojiEntry = store.record(text: emojiOversize)
        #expect(emojiEntry == nil)
        #expect(store.count == 1)
    }

    // MARK: - Pinning & Ordering

    @Test func pinnedEntriesAppearInSeparateBlockOnTopSortedByPinTime() throws {
        let store = ClipboardHistoryStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 1_010)
        let t2 = Date(timeIntervalSince1970: 1_020)

        let itemA = try #require(store.record(text: "Item A", date: t0))
        let itemB = try #require(store.record(text: "Item B", date: t1))
        _ = try #require(store.record(text: "Item C", date: t2))

        // Initial order: newest first (C, B, A)
        #expect(store.search(query: "").map(\.text) == ["Item C", "Item B", "Item A"])

        // Pin A at pinTime1, then Pin B at pinTime2
        let pinTime1 = Date(timeIntervalSince1970: 2_000)
        let pinTime2 = Date(timeIntervalSince1970: 2_010)
        store.pin(id: itemA.id, date: pinTime1)
        store.pin(id: itemB.id, date: pinTime2)

        // Pinned block is sorted by pin time ascending (oldest pin first: A, then B),
        // followed by unpinned entries newest-first (C).
        let results = store.search(query: "")
        #expect(results.map(\.text) == ["Item A", "Item B", "Item C"])
        #expect(results[0].isPinned)
        #expect(results[1].isPinned)
        #expect(!results[2].isPinned)

        // Unpinning A allows A to rejoin normal history ordering
        store.unpin(id: itemA.id)
        let afterUnpin = store.search(query: "")
        #expect(afterUnpin.map(\.text) == ["Item B", "Item C", "Item A"])
        #expect(afterUnpin[0].isPinned)
        #expect(!afterUnpin[1].isPinned)
        #expect(!afterUnpin[2].isPinned)
    }

    // MARK: - Deletion & Clear

    @Test func singleEntryDeletionRemovesFromStoreAndSearch() throws {
        let store = ClipboardHistoryStore.inMemory()
        let e1 = try #require(store.record(text: "Alpha"))
        _ = try #require(store.record(text: "Beta"))

        #expect(store.count == 2)
        store.delete(id: e1.id)

        #expect(store.count == 1)
        #expect(store.search(query: "").map(\.text) == ["Beta"])
        #expect(store.search(query: "Alpha").isEmpty)
        #expect(!store.search(query: "Beta").isEmpty)
    }

    @Test func clearWipesAllHistory() throws {
        let store = ClipboardHistoryStore.inMemory()
        let e1 = try #require(store.record(text: "One"))
        _ = try #require(store.record(text: "Two"))
        store.pin(id: e1.id)

        #expect(store.count == 2)
        store.clear()

        #expect(store.isEmpty)
        #expect(store.search(query: "").isEmpty)
        #expect(store.mostRecentEntry == nil)
    }

    // MARK: - Retention Pruning

    @Test func retentionPruningRemovesUnpinnedOldEntriesWhileExemptingPinnedEntries() {
        let store = ClipboardHistoryStore.inMemory()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 10_000_000)

        // 10 days ago
        let old1 = store.record(text: "Old Unpinned", date: now.addingTimeInterval(-10 * day))!
        let oldPinned = store.record(text: "Old Pinned", date: now.addingTimeInterval(-10 * day))!
        store.pin(id: oldPinned.id)

        // 2 days ago
        let recent = store.record(text: "Recent Unpinned", date: now.addingTimeInterval(-2 * day))!

        #expect(store.count == 3)

        // Prune older than 7 days
        let cutoff = now.addingTimeInterval(-7 * day)
        store.prune(olderThan: cutoff)

        #expect(store.count == 2)
        let remaining = store.search(query: "")
        #expect(remaining.map(\.text) == ["Old Pinned", "Recent Unpinned"])
        #expect(!remaining.contains { $0.id == old1.id })
        #expect(remaining.first { $0.id == oldPinned.id }?.isPinned == true)
        #expect(remaining.first { $0.id == recent.id }?.isPinned == false)
    }

    // MARK: - Two-Tier Search (Short Query vs FTS5)

    @Test func emptyQueryReturnsAllInOrder() {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "First")
        _ = store.record(text: "Second")
        _ = store.record(text: "Third")

        let all = store.search(query: "")
        #expect(all.map(\.text) == ["Third", "Second", "First"])
    }

    @Test func shortQueriesFilterInMemoryWindowCaseInsensitively() {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Xcode 16 beta")
        _ = store.record(text: "swift Concurrency")
        _ = store.record(text: "xctest runner")

        // 1 character query
        let xMatches = store.search(query: "x")
        #expect(xMatches.map(\.text) == ["xctest runner", "Xcode 16 beta"])

        // 2 character query
        let swMatches = store.search(query: "sw")
        #expect(swMatches.map(\.text) == ["swift Concurrency"])

        // 2 character query matching uppercase (matches "Concurrency" and "Xcode")
        let coMatches = store.search(query: "CO")
        #expect(coMatches.map(\.text) == ["swift Concurrency", "Xcode 16 beta"])
    }

    @Test func ftsQueriesMatchTrigramAcrossPunctuationAndCode() {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "let greeting = \"Hello, World!\"")
        _ = store.record(text: "https://github.com/fpcMotif/floodlight/issues/50")
        _ = store.record(text: "Invoice total: $1,234.50 USD")
        _ = store.record(text: "function calculateTax(subtotal: Double) -> Double")

        #expect(!store.search(query: "Hello").isEmpty)
        #expect(!store.search(query: "floodlight").isEmpty)
        #expect(!store.search(query: "issues/50").isEmpty)
        #expect(!store.search(query: "1,234").isEmpty)
        #expect(!store.search(query: "calculateTax").isEmpty)
        #expect(store.search(query: "nonexistent query string").isEmpty)
    }

    @Test func ftsQueryPreservesPinnedBlockOnTop() throws {
        let store = ClipboardHistoryStore.inMemory()
        let e1 = try #require(store.record(text: "invoice #101: $50"))
        let e2 = try #require(store.record(text: "invoice #102: $100"))
        let e3 = try #require(store.record(text: "invoice #103: $150"))

        store.pin(id: e1.id)

        let matches = store.search(query: "invoice")
        #expect(matches.count == 3)
        #expect(matches[0].id == e1.id)
        #expect(matches[0].isPinned)
        #expect(matches[1].id == e3.id)
        #expect(matches[2].id == e2.id)
    }

    // MARK: - Disk Persistence Round-Trip

    @Test func diskStorePersistsAndReloadsEntriesPinsAndFTS() throws {
        let (dbURL, cleanup) = try makeTemporaryDatabaseURL()
        defer { cleanup() }

        // Create store 1 and write data
        do {
            let store1 = try ClipboardHistoryStore(databaseURL: dbURL)
            _ = try #require(store1.record(
                text: "Persisted Note",
                sourceAppBundleID: "com.apple.Notes"
            ))
            let e2 = try #require(store1.record(
                text: "Persisted Pinned",
                sourceAppBundleID: "com.apple.Safari"
            ))
            store1.pin(id: e2.id)
            #expect(store1.count == 2)
        }

        // Re-open store 2 from same disk path
        do {
            let store2 = try ClipboardHistoryStore(databaseURL: dbURL)
            #expect(store2.count == 2)

            let all = store2.search(query: "")
            #expect(all.count == 2)
            #expect(all[0].text == "Persisted Pinned")
            #expect(all[0].isPinned)
            #expect(all[0].sourceAppBundleID == "com.apple.Safari")
            #expect(all[1].text == "Persisted Note")
            #expect(!all[1].isPinned)

            // FTS search works on reloaded database
            let searchResults = store2.search(query: "Persisted")
            #expect(searchResults.count == 2)
        }
    }

    // MARK: - File Entries

    @Test func recordingAFilePathPreservesKindAndIndexesNameAndPath() throws {
        let store = ClipboardHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Users/f/Documents/Invoices/Invoice_2026.pdf"

        let entry = store.recordFile(
            path: path,
            sourceAppBundleID: "com.apple.finder",
            date: now
        )

        let unwrapped = try #require(entry)
        #expect(unwrapped.kind == .file)
        #expect(unwrapped.text == path)
        #expect(unwrapped.sourceAppBundleID == "com.apple.finder")
        #expect(unwrapped.createdAt == now)
        #expect(!unwrapped.isPinned)
        #expect(store.count == 1)

        #expect(store.search(query: "Invoice_2026.pdf").map(\.text) == [path])
        #expect(store.search(query: "/Users/f/Documents").map(\.text) == [path])
        #expect(store.search(query: "inv").map(\.text) == [path])
    }

    @Test func consecutiveDuplicateFilePathsAreCollapsed() {
        let store = ClipboardHistoryStore.inMemory()
        let path = "/Users/f/Movies/ProductDemo_4K.mov"

        #expect(store.recordFile(path: path) != nil)
        #expect(store.count == 1)
        #expect(store.recordFile(path: path) == nil)
        #expect(store.count == 1)

        #expect(store.record(text: path) != nil)
        #expect(store.count == 2)
        #expect(store.recordFile(path: path) != nil)
        #expect(store.count == 3)
    }

    @Test func emptyFilePathsAreSkipped() {
        let store = ClipboardHistoryStore.inMemory()
        #expect(store.recordFile(path: "") == nil)
        #expect(store.recordFile(path: "   ") == nil)
        #expect(store.isEmpty)
    }

    @Test func fileEntriesPinDeleteClearAndPruneLikeText() throws {
        let store = ClipboardHistoryStore.inMemory()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 10_000_000)

        let oldFile = try #require(store.recordFile(
            path: "/Users/f/Old/report.pdf",
            date: now.addingTimeInterval(-10 * day)
        ))
        let pinnedFile = try #require(store.recordFile(
            path: "/Users/f/Pinned/keep.pdf",
            date: now.addingTimeInterval(-10 * day)
        ))
        let recentFile = try #require(store.recordFile(
            path: "/Users/f/Recent/notes.txt",
            date: now.addingTimeInterval(-2 * day)
        ))
        store.pin(id: pinnedFile.id)

        store.prune(olderThan: now.addingTimeInterval(-7 * day))
        #expect(store.search(query: "").map(\.id) == [pinnedFile.id, recentFile.id])
        #expect(!store.search(query: "").contains { $0.id == oldFile.id })
        #expect(store.search(query: "").first { $0.id == pinnedFile.id }?.kind == .file)

        store.delete(id: recentFile.id)
        #expect(store.search(query: "").map(\.id) == [pinnedFile.id])

        store.clear()
        #expect(store.isEmpty)
    }

    @Test func diskStorePersistsFileKindAndFTS() throws {
        let (dbURL, cleanup) = try makeTemporaryDatabaseURL()
        defer { cleanup() }
        let path = "/Users/f/devv/floodlight/Package.swift"

        do {
            let store1 = try ClipboardHistoryStore(databaseURL: dbURL)
            _ = try #require(store1.record(text: "plain note"))
            let file = try #require(store1.recordFile(path: path))
            store1.pin(id: file.id)
            #expect(store1.count == 2)
        }

        do {
            let store2 = try ClipboardHistoryStore(databaseURL: dbURL)
            let all = store2.search(query: "")
            #expect(all.count == 2)
            #expect(all[0].kind == .file)
            #expect(all[0].text == path)
            #expect(all[0].isPinned)
            #expect(all[1].kind == .text)
            #expect(store2.search(query: "Package.swift").map(\.kind) == [.file])
        }
    }

    // MARK: - Image Entries

    @Test func recordingAnImagePreservesKindHashDimensionsAndThumbnail() throws {
        let store = ClipboardHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let png = ClipboardImageTestData.png
        let thumbnail = ClipboardImageTestData.thumbnail

        let entry = store.recordImage(
            pngData: png,
            thumbnailPNGData: thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "CleanShot 2026-09-01 at 15.30.png",
            sourceAppBundleID: "com.apple.screencapture",
            date: now
        )

        let unwrapped = try #require(entry)
        #expect(unwrapped.kind == .image)
        #expect(unwrapped.text == "CleanShot 2026-09-01 at 15.30.png")
        #expect(unwrapped.sourceAppBundleID == "com.apple.screencapture")
        #expect(unwrapped.createdAt == now)
        #expect(!unwrapped.isPinned)
        #expect(unwrapped.image?.width == 2_880)
        #expect(unwrapped.image?.height == 1_800)
        #expect(unwrapped.image?.byteCount == png.count)
        #expect(unwrapped.image?.hash == ClipboardImageTestData.pngSHA256)
        #expect(unwrapped.image?.thumbnailPNGData == thumbnail)
        #expect(store.count == 1)

        let loaded = try #require(store.imageData(for: unwrapped.id))
        #expect(loaded.png == png)
        #expect(loaded.tiff == nil)

        #expect(store.search(query: "CleanShot").map(\.id) == [unwrapped.id])
        #expect(store.search(query: "2880").map(\.kind) == [.image])
    }

    @Test func consecutiveDuplicateImageHashesAreCollapsed() {
        let store = ClipboardHistoryStore.inMemory()
        let png = ClipboardImageTestData.png

        #expect(store.recordImage(
            pngData: png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 800,
            height: 600,
            displayName: "first.png"
        ) != nil)
        #expect(store.count == 1)
        #expect(store.recordImage(
            pngData: png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 800,
            height: 600,
            displayName: "again.png"
        ) == nil)
        #expect(store.count == 1)

        #expect(store.recordImage(
            pngData: ClipboardImageTestData.tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 100,
            height: 100,
            displayName: "other.png"
        ) != nil)
        #expect(store.count == 2)
        #expect(store.recordImage(
            pngData: png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 800,
            height: 600,
            displayName: "first-again.png"
        ) != nil)
        #expect(store.count == 3)
    }

    @Test func imagesExceeding15MBAreSkipped() {
        let store = ClipboardHistoryStore.inMemory()
        let oversized = Data(repeating: 0x11, count: ClipboardHistoryStore.maxImageByteCount + 1)

        #expect(store.recordImage(
            pngData: oversized,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 10,
            height: 10,
            displayName: "huge.png"
        ) == nil)
        #expect(store.isEmpty)

        let exact = Data(repeating: 0x22, count: ClipboardHistoryStore.maxImageByteCount)
        #expect(store.recordImage(
            pngData: exact,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 10,
            height: 10,
            displayName: "exact.png"
        ) != nil)
        #expect(store.count == 1)
    }

    @Test func oversizedCompanionRepresentationDoesNotDropAValidImage() throws {
        let store = ClipboardHistoryStore.inMemory()
        let oversized = Data(repeating: 0x11, count: ClipboardHistoryStore.maxImageByteCount + 1)
        let tiff = Data(repeating: 0x33, count: 16)
        let kept = try #require(store.recordImage(
            pngData: oversized,
            tiffData: tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "tiff-only.png"
        ))
        #expect(store.imageData(for: kept.id)?.png == nil)
        #expect(store.imageData(for: kept.id)?.tiff == tiff)
    }

    @Test func imagePayloadInfoReportsPNGPresenceWithoutReadingBlob() throws {
        let store = ClipboardHistoryStore.inMemory()

        let entry = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "CleanShot 2026-09-01 at 15.30.png"
        ))

        let info = try #require(store.imagePayloadInfo(for: entry.id))
        #expect(info.hasPNG)
        #expect(!info.hasTIFF)
        #expect(info.hasPayload)
    }

    @Test func imagePayloadInfoReportsTIFFOnlyEntries() throws {
        let store = ClipboardHistoryStore.inMemory()
        let oversizedPNG = Data(repeating: 0x11, count: ClipboardHistoryStore.maxImageByteCount + 1)
        let tiff = Data(repeating: 0x33, count: 16)

        let entry = try #require(store.recordImage(
            pngData: oversizedPNG,
            tiffData: tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "tiff-only.png"
        ))

        let info = try #require(store.imagePayloadInfo(for: entry.id))
        #expect(!info.hasPNG)
        #expect(info.hasTIFF)
        #expect(info.hasPayload)
    }

    @Test func imagePayloadInfoReturnsNilForTextEntriesAndUnknownIDs() throws {
        let store = ClipboardHistoryStore.inMemory()
        let text = try #require(store.record(text: "Not an image"))

        #expect(store.imagePayloadInfo(for: text.id) == nil)
        #expect(store.imagePayloadInfo(for: "nonexistent-id") == nil)
    }

    @Test func emptyImagePayloadsAreSkipped() {
        let store = ClipboardHistoryStore.inMemory()
        #expect(store.recordImage(
            pngData: Data(),
            tiffData: Data(),
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 1,
            height: 1,
            displayName: "empty.png"
        ) == nil)
        #expect(store.isEmpty)
    }

    @Test func imageEntriesPinDeleteClearAndPruneLikeText() throws {
        let store = ClipboardHistoryStore.inMemory()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 10_000_000)

        let oldImage = try #require(store.recordImage(
            pngData: Data(repeating: 0x01, count: 16),
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 10,
            height: 10,
            displayName: "old.png",
            date: now.addingTimeInterval(-10 * day)
        ))
        let pinnedImage = try #require(store.recordImage(
            pngData: Data(repeating: 0x02, count: 16),
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 20,
            height: 20,
            displayName: "pinned.png",
            date: now.addingTimeInterval(-10 * day)
        ))
        let recentImage = try #require(store.recordImage(
            pngData: Data(repeating: 0x03, count: 16),
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 30,
            height: 30,
            displayName: "recent.png",
            date: now.addingTimeInterval(-2 * day)
        ))
        store.pin(id: pinnedImage.id)

        store.prune(olderThan: now.addingTimeInterval(-7 * day))
        #expect(store.search(query: "").map(\.id) == [pinnedImage.id, recentImage.id])
        #expect(!store.search(query: "").contains { $0.id == oldImage.id })
        #expect(store.search(query: "").first { $0.id == pinnedImage.id }?.kind == .image)
        #expect(store.imageData(for: oldImage.id) == nil)
        // A pruned entry's row is gone entirely, so the cheap query agrees with the blob read.
        #expect(store.imagePayloadInfo(for: oldImage.id) == nil)
        #expect(store.imageData(for: pinnedImage.id)?.png == Data(repeating: 0x02, count: 16))
        #expect(store.imagePayloadInfo(for: pinnedImage.id)?.hasPNG == true)

        store.delete(id: recentImage.id)
        #expect(store.search(query: "").map(\.id) == [pinnedImage.id])
        #expect(store.imageData(for: recentImage.id) == nil)
        #expect(store.imagePayloadInfo(for: recentImage.id) == nil)

        store.clear()
        #expect(store.isEmpty)
        #expect(store.imageData(for: pinnedImage.id) == nil)
        #expect(store.imagePayloadInfo(for: pinnedImage.id) == nil)
    }

    @Test func diskStorePersistsImageKindThumbnailAndPayload() throws {
        let (dbURL, cleanup) = try makeTemporaryDatabaseURL()
        defer { cleanup() }
        let png = ClipboardImageTestData.png
        let thumbnail = ClipboardImageTestData.thumbnail
        var imageID = ""

        do {
            let store1 = try ClipboardHistoryStore(databaseURL: dbURL)
            _ = try #require(store1.record(text: "plain note"))
            let image = try #require(store1.recordImage(
                pngData: png,
                tiffData: ClipboardImageTestData.tiff,
                thumbnailPNGData: thumbnail,
                width: 1_440,
                height: 900,
                displayName: "AppMockup_Dark_v2.png"
            ))
            store1.pin(id: image.id)
            imageID = image.id
            #expect(store1.count == 2)
        }

        do {
            let store2 = try ClipboardHistoryStore(databaseURL: dbURL)
            let all = store2.search(query: "")
            #expect(all.count == 2)
            #expect(all[0].kind == .image)
            #expect(all[0].text == "AppMockup_Dark_v2.png")
            #expect(all[0].isPinned)
            #expect(all[0].image?.width == 1_440)
            #expect(all[0].image?.height == 900)
            #expect(all[0].image?.thumbnailPNGData == thumbnail)
            #expect(all[1].kind == .text)
            #expect(store2.search(query: "AppMockup").map(\.kind) == [.image])
            let loaded = try #require(store2.imageData(for: imageID))
            #expect(loaded.png == png)
            #expect(loaded.tiff == ClipboardImageTestData.tiff)
        }
    }
}
