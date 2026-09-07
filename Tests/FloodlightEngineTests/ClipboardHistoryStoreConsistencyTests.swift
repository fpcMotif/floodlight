import FloodlightTestSupport
import Foundation
import SQLite3
import Testing
@testable import FloodlightEngine

/// The mirror-only-moves-on-success contract in `ClipboardHistoryStore`, plus
/// the byte-exactness of what a text column round-trips.
///
/// Deliberately not advertised as covering the transient-binding fix: the
/// round-trip below passes equally with the old `(x as NSString).utf8String`
/// and SQLITE_STATIC, because the bridged buffer is autoreleased and outlives
/// the `sqlite3_step` in the same scope. The write-outcome tests do fail on
/// revert — pin/unpin/delete/clear/prune returned Void, so they would not
/// compile — which is the half this file genuinely guards.
struct ClipboardHistoryStoreConsistencyTests {
    private struct Recorded {
        let text: String
        let bundleID: String
    }

    /// A live store whose entries table has been dropped out from under it,
    /// with the mirror as it stood immediately before the drop.
    private struct BrokenStoreFixture {
        let store: ClipboardHistoryStore
        let cleanup: () -> Void
        let pinnedID: String
        let unpinnedID: String
        let countBefore: Int
        let pinnedIDsBefore: [String]
        let unpinnedIDsBefore: [String]
    }

    /// Opens a second raw connection to the same database file and drops the
    /// entries table out from under a live `ClipboardHistoryStore`, returning
    /// the raw SQLite result code for `DROP TABLE` so the caller can verify it
    /// actually succeeded before trusting anything that follows.
    private func dropClipboardEntriesTable(atPath path: String) -> Int32 {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        defer {
            if let db { sqlite3_close(db) }
        }
        guard openResult == SQLITE_OK, let db else { return openResult }
        return sqlite3_exec(db, "DROP TABLE clipboard_entries;", nil, nil, nil)
    }

    // MARK: - A. Text binding round-trip

    @Test func textBindingRoundTripsExactBytesForAdversarialAndExtremeStrings() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }

        let extras = [
            "",
            String(repeating: "a", count: 30_000),
            "quote \" and 'single' and \\backslash",
            "日本語 — non-ASCII",
        ]
        let strings = AdversarialCorpus.strings + extras

        var expected: [String: Recorded] = [:]

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            for (index, text) in strings.enumerated() {
                let bundleID = "com.floodlight.test.source.\(index)-é"
                // `record` returns nil for a consecutive duplicate and for text
                // over the byte cap; both are skips, not failures.
                guard let entry = store.record(text: text, sourceAppBundleID: bundleID) else {
                    continue
                }
                expected[entry.id] = Recorded(text: text, bundleID: bundleID)
            }
        }

        #expect(!expected.isEmpty)

        let reopened = try ClipboardHistoryStore(databaseURL: dbURL)
        for (id, recorded) in expected {
            let entry = try #require(reopened.entry(id: id))
            #expect(entry.text == recorded.text)
            #expect(entry.sourceAppBundleID == recorded.bundleID)
        }
    }

    /// An interior NUL used to cut the text on both sides — length `-1` on the
    /// bind meant `strlen`, and `String(cString:)` on the read stopped at the
    /// same byte — so the mirror held the whole string while the row on disk
    /// held a prefix. Clipboard text is whatever another application put on the
    /// pasteboard, so this is reachable, not theoretical.
    @Test func textWithAnInteriorNULRoundTripsWholeThroughAReopenedStore() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        let text = "\u{0000}embedded-nul-ish"
        var entryID = ""

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            let entry = try #require(store.record(text: text))
            entryID = entry.id
            #expect(entry.text == text)
        }

        let reopened = try ClipboardHistoryStore(databaseURL: dbURL)
        let reread = try #require(reopened.entry(id: entryID))
        #expect(reread.text == text)
    }

    @Test func imageDisplayNameWithNonASCIIAndQuotesRoundTripsThroughReopenedStore() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }

        let displayName = "スクリーンショット \"2026\" 'quote'.png"
        var imageID = ""

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            let entry = try #require(store.recordImage(
                pngData: ClipboardImageTestData.png,
                thumbnailPNGData: ClipboardImageTestData.thumbnail,
                width: 400,
                height: 300,
                displayName: displayName,
                sourceAppBundleID: "com.floodlight.test.image-source-é"
            ))
            imageID = entry.id
        }

        let reopened = try ClipboardHistoryStore(databaseURL: dbURL)
        let entry = try #require(reopened.entry(id: imageID))
        #expect(entry.text == displayName)
        #expect(entry.kind == .image)
        #expect(entry.sourceAppBundleID == "com.floodlight.test.image-source-é")
    }

    // MARK: - B. Failure path: the mirror does not move when SQLite rejects the write

    /// Fresh setup for every failure-path test: an on-disk store with several
    /// entries (one pinned), and the entries table dropped out from under it
    /// through a second raw connection. Callers get back a snapshot of the
    /// mirror taken immediately before the drop, to assert against afterward.
    private func makeStoreWithDroppedEntriesTable() throws -> BrokenStoreFixture {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        let store = try ClipboardHistoryStore(databaseURL: dbURL)
        let first = try #require(store.record(text: "Alpha"))
        let second = try #require(store.record(text: "Beta"))
        _ = try #require(store.record(text: "Gamma"))
        try #require(store.pin(id: first.id))

        let countBefore = store.count
        let pinnedIDsBefore = store.pinnedEntries.map(\.id)
        let unpinnedIDsBefore = store.unpinnedEntries.map(\.id)

        try #require(dropClipboardEntriesTable(atPath: dbURL.path) == SQLITE_OK)

        return BrokenStoreFixture(
            store: store,
            cleanup: cleanup,
            pinnedID: first.id,
            unpinnedID: second.id,
            countBefore: countBefore,
            pinnedIDsBefore: pinnedIDsBefore,
            unpinnedIDsBefore: unpinnedIDsBefore
        )
    }

    /// The claim every write-outcome test below shares: a refused write left
    /// the in-memory mirror exactly as it was, by count and by both orderings.
    private func expectMirrorUnchanged(
        _ fixture: BrokenStoreFixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(fixture.store.count == fixture.countBefore, sourceLocation: sourceLocation)
        #expect(
            fixture.store.pinnedEntries.map(\.id) == fixture.pinnedIDsBefore,
            sourceLocation: sourceLocation
        )
        #expect(
            fixture.store.unpinnedEntries.map(\.id) == fixture.unpinnedIDsBefore,
            sourceLocation: sourceLocation
        )
    }

    @Test func clearReturnsFalseAndLeavesMirrorUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.clear() == false)
        expectMirrorUnchanged(fixture)
    }

    @Test func deleteReturnsFalseAndLeavesMirrorUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.delete(id: fixture.unpinnedID) == false)
        expectMirrorUnchanged(fixture)
    }

    @Test func pinReturnsFalseAndLeavesMirrorUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.pin(id: fixture.unpinnedID) == false)
        expectMirrorUnchanged(fixture)
    }

    @Test func unpinReturnsFalseAndLeavesMirrorUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.unpin(id: fixture.pinnedID) == false)
        expectMirrorUnchanged(fixture)
    }

    @Test func pruneOlderThanReturnsFalseAndLeavesMirrorUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.prune(olderThan: .distantFuture) == false)
        expectMirrorUnchanged(fixture)
    }

    @Test func recordReturnsNilAndCountUnchangedWhenTableIsGone() throws {
        let fixture = try makeStoreWithDroppedEntriesTable()
        defer { fixture.cleanup() }

        #expect(fixture.store.record(text: "after the table is gone") == nil)
        #expect(fixture.store.count == fixture.countBefore)
    }

    // MARK: - C. Unopenable / damaged database

    @Test func garbageBytesFileFailsToInitialize() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        try Data("not a sqlite database, just garbage bytes".utf8).write(to: dbURL)

        #expect(throws: (any Error).self) {
            _ = try ClipboardHistoryStore(databaseURL: dbURL)
        }
    }

    /// A database the process cannot write is refused at construction rather
    /// than opened and written against: the store the caller falls back to is
    /// in memory, so nothing it shows claims to be persisted.
    @Test func readOnlyDatabaseIsRefusedRatherThanOpenedForWriting() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        let directory = dbURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            cleanup()
        }

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            _ = try #require(store.record(text: "written while still writable"))
        }

        // The directory too, so SQLite cannot create the -wal/-shm sidecars.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: dbURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )

        #expect(throws: (any Error).self) {
            _ = try ClipboardHistoryStore(databaseURL: dbURL)
        }
    }

    @Test func pathWithUncreatableParentDirectoryFailsToInitialize() {
        let path = "/dev/null/floodlight-test-\(UUID().uuidString)/clipboard.sqlite3"

        #expect(throws: (any Error).self) {
            _ = try ClipboardHistoryStore(databaseURL: URL(fileURLWithPath: path))
        }
    }

    @Test func inMemoryStoreStillWorksAfterUnopenableDatabaseFailures() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        try Data("garbage, not a sqlite database".utf8).write(to: dbURL)
        #expect(throws: (any Error).self) {
            _ = try ClipboardHistoryStore(databaseURL: dbURL)
        }

        let uncreatablePath = "/dev/null/floodlight-test-\(UUID().uuidString)/clipboard.sqlite3"
        #expect(throws: (any Error).self) {
            _ = try ClipboardHistoryStore(databaseURL: URL(fileURLWithPath: uncreatablePath))
        }

        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.record(text: "still works after failures"))
        let reread = try #require(store.entry(id: entry.id))
        #expect(reread.text == "still works after failures")
    }

    // MARK: - D. Success still reports success

    @Test func pinUnpinDeleteAndPruneReturnTrueOnAHealthyStore() throws {
        let store = ClipboardHistoryStore.inMemory()
        let first = try #require(store.record(text: "Alpha"))
        _ = try #require(store.record(text: "Beta"))

        #expect(store.pin(id: first.id) == true)
        #expect(store.unpin(id: first.id) == true)
        #expect(store.delete(id: first.id) == true)
        #expect(store.prune(olderThan: .distantFuture) == true)
        #expect(store.clear() == true)
    }

    @Test func pruneForeverRetentionReturnsTrueAndKeepsEntries() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Alpha"))
        _ = try #require(store.record(text: "Beta"))

        #expect(store.prune(retention: .forever) == true)
        #expect(store.count == 2)
    }
}
