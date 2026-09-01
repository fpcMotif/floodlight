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
}
