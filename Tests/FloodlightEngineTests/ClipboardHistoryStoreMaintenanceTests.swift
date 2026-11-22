import FloodlightTestSupport
import Foundation
import SQLite3
import Testing
@testable import FloodlightEngine

struct ClipboardHistoryStoreMaintenanceTests {
    @Test func compactShrinksTheFileAfterClear() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }

        let store = try ClipboardHistoryStore(databaseURL: dbURL)
        let padding = String(repeating: "x", count: 30_000)
        for index in 0..<200 {
            _ = try #require(store.record(text: "entry-\(index)-\(padding)"))
        }

        #expect(store.compact())
        let beforeSize = try fileSize(at: dbURL)
        #expect(beforeSize > 0)

        #expect(store.clear())
        #expect(store.compact())
        let afterSize = try fileSize(at: dbURL)
        #expect(afterSize * 4 < beforeSize)
    }

    @Test func compactConvertsADatabaseCreatedWithoutAutoVacuum() throws {
        let (dbURL, cleanup) = try TemporaryDirectory.makeClipboardDatabase()
        defer { cleanup() }

        try runSQLite(at: dbURL, sql: "CREATE TABLE seed(col);")

        do {
            let store = try ClipboardHistoryStore(databaseURL: dbURL)
            #expect(store.compact())
        }

        #expect(try readAutoVacuumMode(at: dbURL) == 2)
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func runSQLite(at url: URL, sql: String) throws {
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
        defer { if let rawDB { sqlite3_close(rawDB) } }
        let db = try #require(rawDB)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func readAutoVacuumMode(at url: URL) throws -> Int32 {
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
        defer { if let rawDB { sqlite3_close(rawDB) } }
        let db = try #require(rawDB)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA auto_vacuum;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }
}
