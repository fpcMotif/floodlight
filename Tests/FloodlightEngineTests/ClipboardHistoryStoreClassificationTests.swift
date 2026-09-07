import FloodlightTestSupport
import Foundation
import SQLite3
import Testing
@testable import FloodlightEngine

/// What #73 added to Clipboard History: the classification stored with each
/// text entry, the mutation version readers key their caches on, and the
/// case-folded window a short query scans.
struct ClipboardHistoryStoreClassificationTests {
    // MARK: - Classification (#73)

    @Test func recordedTextIsClassifiedOnceAndOtherKindsAreNot() throws {
        let store = ClipboardHistoryStore.inMemory()

        let link = try #require(store.record(text: "https://github.com/fpcMotif/floodlight"))
        #expect(link.textContent == .link(domain: "github.com"))
        let json = try #require(store.record(text: "{\"a\": 1}"))
        #expect(json.textContent == .code(language: "JSON"))
        let file = try #require(store.recordFile(path: "/tmp/a.txt"))
        #expect(file.textContent == nil)
        let image = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 8,
            height: 8,
            displayName: "Screenshot"
        ))
        #expect(image.textContent == nil)

        #expect(store.entry(id: link.id)?.textContent == .link(domain: "github.com"))
    }

    @Test func classificationSurvivesPinUnpinAndReload() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        var linkID = ""

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            let link = try #require(store.record(text: "https://example.org/a"))
            linkID = link.id
            store.pin(id: link.id)
            #expect(store.entry(id: link.id)?.textContent == .link(domain: "example.org"))
            store.unpin(id: link.id)
            #expect(store.entry(id: link.id)?.textContent == .link(domain: "example.org"))
            store.pin(id: link.id)
        }

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            let reloaded = try #require(store.entry(id: linkID))
            #expect(reloaded.isPinned)
            #expect(reloaded.textContent == .link(domain: "example.org"))
            #expect(storedClassification(atPath: dbURL.path, id: linkID) == ["link", "example.org"])
        }
    }

    /// A database from a build that stored no classification loads, gains
    /// the columns, classifies each row the first time it is read, and
    /// writes the result back — so the second open reads it stored.
    @Test func anOlderDatabaseWithoutTheColumnsIsUpgradedOnLoadAndWrittenBack() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        var linkID = ""
        var pathID = ""
        var plainID = ""

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            linkID = try #require(store.record(text: "https://www.example.org/x")).id
            pathID = try #require(store.record(text: "/definitely/missing/file.png")).id
            plainID = try #require(store.record(text: "Acme billing address")).id
            store.pin(id: linkID)
        }
        try dropClassificationColumns(atPath: dbURL.path)
        #expect(storedClassification(atPath: dbURL.path, id: linkID) == nil)

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            #expect(store.entry(id: linkID)?.textContent == .link(domain: "example.org"))
            #expect(
                store.entry(id: pathID)?.textContent ==
                    .path(at: URL(fileURLWithPath: "/definitely/missing/file.png"))
            )
            #expect(store.entry(id: plainID)?.textContent == .plain)
            #expect(store.search(query: "").count == 3)
        }
        #expect(storedClassification(atPath: dbURL.path, id: linkID) == ["link", "example.org"])
        #expect(
            storedClassification(atPath: dbURL.path, id: pathID) ==
                ["path", "file:///definitely/missing/file.png"]
        )
        #expect(storedClassification(atPath: dbURL.path, id: plainID) == ["plain", nil])
    }

    @Test func rowsBeyondTheWindowAreClassifiedWhenTheIndexFindsThem() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }
        var oldestID = ""

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            oldestID = try #require(store.record(
                text: "https://oldest.example.org/first",
                date: base
            )).id
            for index in 0..<ClipboardHistoryStore.inMemoryRecentWindowLimit {
                _ = store.record(
                    text: "filler entry #\(index)",
                    date: base.addingTimeInterval(Double(index + 1))
                )
            }
        }
        try dropClassificationColumns(atPath: dbURL.path)

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            #expect(storedClassification(atPath: dbURL.path, id: oldestID) == nil)
            let found = try #require(store.search(query: "oldest").first)
            #expect(found.id == oldestID)
            #expect(found.textContent == .link(domain: "oldest.example.org"))

            // The write-back and a pin both update the row without touching
            // its text, and the index still answers for it afterwards.
            store.pin(id: oldestID)
            let pinned = try #require(store.search(query: "oldest").first)
            #expect(pinned.isPinned)
            #expect(pinned.textContent == .link(domain: "oldest.example.org"))
        }
        #expect(
            storedClassification(atPath: dbURL.path, id: oldestID) == ["link", "oldest.example.org"]
        )
    }

    // MARK: - Mutation version (#73)

    @Test func mutationVersionMovesOnAcceptedWritesAndOnNothingElse() throws {
        let store = ClipboardHistoryStore.inMemory()
        #expect(store.mutationVersion == 0)

        let entry = try #require(store.record(text: "Snippet"))
        #expect(store.mutationVersion == 1)
        #expect(store.record(text: "Snippet") == nil, "a consecutive duplicate is refused")
        #expect(store.mutationVersion == 1)
        #expect(store.record(text: String(repeating: "x", count: 40_000)) == nil)
        #expect(store.mutationVersion == 1)

        _ = store.search(query: "")
        _ = store.search(query: "Sn")
        _ = store.search(query: "Snippet")
        _ = store.entry(id: entry.id)
        _ = store.imageData(for: entry.id)
        #expect(store.mutationVersion == 1)

        store.pin(id: entry.id)
        #expect(store.mutationVersion == 2)
        store.unpin(id: entry.id)
        #expect(store.mutationVersion == 3)
        store.delete(id: entry.id)
        #expect(store.mutationVersion == 4)
        _ = store.record(text: "Another")
        #expect(store.mutationVersion == 5)
        store.prune(olderThan: .distantFuture)
        #expect(store.mutationVersion == 6)
        store.clear()
        #expect(store.mutationVersion == 7)
    }

    // MARK: - Short queries over the folded window (#73)

    @Test func shortQueriesFoldCaseAcrossScriptsAndMatchImageDimensions() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Café menu"))
        _ = try #require(store.record(text: "Straße 12"))
        _ = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 32,
            height: 16,
            displayName: "Screenshot"
        ))

        #expect(store.search(query: "É").map(\.text) == ["Café menu"])
        #expect(store.search(query: "CA").map(\.text) == ["Café menu"])
        #expect(store.search(query: "ß").map(\.text) == ["Straße 12"])
        #expect(store.search(query: "32").map(\.text) == ["Screenshot"])
        #expect(store.search(query: "×").map(\.text) == ["Screenshot"])
        #expect(store.search(query: "zz").isEmpty)
    }

    @Test func shortQueriesStopMatchingWhatLeavesTheWindow() throws {
        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.record(text: "Xylophone"))
        #expect(store.search(query: "xy").map(\.id) == [entry.id])

        store.delete(id: entry.id)
        #expect(store.search(query: "xy").isEmpty)

        let pruned = try #require(store.record(text: "Xylophone", date: .distantPast))
        store.pin(id: pruned.id)
        let kept = try #require(store.record(text: "Xylophone again", date: .distantPast))
        store.prune(olderThan: .now)
        #expect(store.search(query: "xy").map(\.id) == [pruned.id])
        #expect(store.entry(id: kept.id) == nil)

        store.clear()
        #expect(store.search(query: "xy").isEmpty)
    }

    // MARK: - Raw database helpers

    /// `[kind, detail]` as stored, or `nil` when the row has no stored
    /// classification (or the columns do not exist).
    private func storedClassification(atPath path: String, id: String) -> [String?]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT content_kind, content_detail FROM clipboard_entries WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        ClipboardHistorySQLite.bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let kind = ClipboardHistorySQLite.readText(stmt, index: 0) else { return nil }
        return [kind, ClipboardHistorySQLite.readText(stmt, index: 1)]
    }

    /// Takes the database back to the shape a build before #73 left it in.
    private func dropClassificationColumns(atPath path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ClipboardHistorySQLite.Failure(code: SQLITE_CANTOPEN, message: path)
        }
        defer { sqlite3_close(db) }
        for column in ["content_kind", "content_detail"] {
            let result = sqlite3_exec(
                db,
                "ALTER TABLE clipboard_entries DROP COLUMN \(column);",
                nil,
                nil,
                nil
            )
            guard result == SQLITE_OK else {
                throw ClipboardHistorySQLite.Failure(
                    code: result,
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
    }
}
