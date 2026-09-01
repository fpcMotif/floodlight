import Foundation
import os
import SQLite3

/// One immutable captured or pinned text snippet in Clipboard History.
package struct ClipboardEntry: Identifiable, Equatable, Hashable, Sendable {
    package let id: String
    package let text: String
    package let createdAt: Date
    package let sourceAppBundleID: String?
    package let pinnedAt: Date?

    package var isPinned: Bool {
        pinnedAt != nil
    }

    package init(
        id: String = UUID().uuidString,
        text: String,
        createdAt: Date = .now,
        sourceAppBundleID: String? = nil,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sourceAppBundleID = sourceAppBundleID
        self.pinnedAt = pinnedAt
    }
}

/// Retention period for clipboard history.
package enum ClipboardRetention: Equatable, Sendable {
    case days(Int)
    case forever

    package func cutoffDate(from now: Date = .now) -> Date? {
        switch self {
        case let .days(days):
            now.addingTimeInterval(-Double(days) * 86_400)
        case .forever:
            nil
        }
    }
}

/// A persistent, privacy-respecting local clipboard store powered by SQLite3
/// and an FTS5 trigram index.
package final class ClipboardHistoryStore: @unchecked Sendable {
    package static let maxTextByteCount = 32_000
    package static let inMemoryRecentWindowLimit = 1_000
    package static let searchResultLimit = 200

    private struct State: @unchecked Sendable {
        var db: OpaquePointer?
        var pinnedEntries: [ClipboardEntry]
        var recentEntries: [ClipboardEntry]
        var totalCount: Int
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    package static func inMemory() -> ClipboardHistoryStore {
        (try? ClipboardHistoryStore(databasePath: ":memory:")) ??
            ClipboardHistoryStore(fallback: ())
    }

    private init(fallback: Void) {
        stateLock = OSAllocatedUnfairLock(initialState: State(
            db: nil,
            pinnedEntries: [],
            recentEntries: [],
            totalCount: 0
        ))
    }

    package convenience init(databaseURL: URL? = nil) throws {
        let path: String
        if let databaseURL {
            path = databaseURL.path
        } else {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Floodlight", isDirectory: true)
            try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
            path = appSupport.appendingPathComponent("clipboard.sqlite3").path
        }
        try self.init(databasePath: path)
    }

    package init(databasePath: String) throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databasePath, &dbPointer, flags, nil)
        guard openResult == SQLITE_OK, let db = dbPointer else {
            let errorMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let dbPointer { sqlite3_close(dbPointer) }
            throw NSError(
                domain: "ClipboardHistoryStore",
                code: Int(openResult),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database: \(errorMsg)"]
            )
        }

        Self.initializeSchema(db: db)
        let (pinned, recent, total) = Self.loadInitialWindow(db: db)

        stateLock = OSAllocatedUnfairLock(initialState: State(
            db: db,
            pinnedEntries: pinned,
            recentEntries: recent,
            totalCount: total
        ))
    }

    deinit {
        stateLock.withLock { state in
            if let db = state.db {
                sqlite3_close(db)
                state.db = nil
            }
        }
    }

    // MARK: - Properties

    package var count: Int {
        stateLock.withLock { $0.totalCount }
    }

    package var isEmpty: Bool {
        count == 0
    }

    package var mostRecentEntry: ClipboardEntry? {
        stateLock.withLock { state in
            state.recentEntries.first ?? state.pinnedEntries.max { $0.createdAt < $1.createdAt }
        }
    }

    package var pinnedEntries: [ClipboardEntry] {
        stateLock.withLock { $0.pinnedEntries }
    }

    package var unpinnedEntries: [ClipboardEntry] {
        stateLock.withLock { $0.recentEntries }
    }

    package var allEntries: [ClipboardEntry] {
        search(query: "")
    }

    // MARK: - Recording

    @discardableResult
    package func record(
        text: String,
        sourceAppBundleID: String? = nil,
        date: Date = .now
    ) -> ClipboardEntry? {
        guard text.utf8.count <= Self.maxTextByteCount else {
            return nil
        }

        return stateLock.withLock { state -> ClipboardEntry? in
            guard let db = state.db else { return nil }

            // Consecutive duplicate check
            let latest = state.recentEntries.first
                ?? state.pinnedEntries.max { $0.createdAt < $1.createdAt }
            if let latest, latest.text == text {
                return nil
            }

            let entry = ClipboardEntry(
                id: UUID().uuidString,
                text: text,
                createdAt: date,
                sourceAppBundleID: sourceAppBundleID,
                pinnedAt: nil
            )

            let insertSQL = """
            INSERT INTO clipboard_entries (id, text, created_at, source_app_bundle_id, pinned_at)
            VALUES (?, ?, ?, ?, NULL);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (entry.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (entry.text as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, entry.createdAt.timeIntervalSince1970)
            if let bundleID = entry.sourceAppBundleID {
                sqlite3_bind_text(stmt, 4, (bundleID as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                return nil
            }

            state.recentEntries.insert(entry, at: 0)
            if state.recentEntries.count > Self.inMemoryRecentWindowLimit {
                state.recentEntries.removeLast()
            }
            state.totalCount += 1

            return entry
        }
    }

    // MARK: - Search

    package func search(query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return stateLock.withLock { state -> [ClipboardEntry] in
            guard let db = state.db else { return [] }

            if trimmed.isEmpty {
                return state.pinnedEntries + state.recentEntries
            }

            if trimmed.utf8.count < 3 {
                let pinnedMatches = state.pinnedEntries.filter {
                    $0.text.localizedCaseInsensitiveContains(trimmed)
                }
                let recentMatches = state.recentEntries.filter {
                    $0.text.localizedCaseInsensitiveContains(trimmed)
                }
                return pinnedMatches + recentMatches
            }

            // FTS5 trigram search for queries of 3 or more characters
            let escaped = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let ftsSQL = """
            SELECT id, text, created_at, source_app_bundle_id, pinned_at
            FROM clipboard_entries
            WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?)
            ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, ftsSQL, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (escaped as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(Self.searchResultLimit))

                var results: [ClipboardEntry] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let entry = Self.readEntry(from: stmt) {
                        results.append(entry)
                    }
                }
                return results
            }

            // Fallback to in-memory filter if FTS query preparation fails
            let pinnedMatches = state.pinnedEntries.filter {
                $0.text.localizedCaseInsensitiveContains(trimmed)
            }
            let recentMatches = state.recentEntries.filter {
                $0.text.localizedCaseInsensitiveContains(trimmed)
            }
            return pinnedMatches + recentMatches
        }
    }

    // MARK: - Pinning

    package func pin(id: String, date: Date = .now) {
        stateLock.withLock { state in
            guard let db = state.db else { return }

            let sql = "UPDATE clipboard_entries SET pinned_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }

            if let idx = state.recentEntries.firstIndex(where: { $0.id == id }) {
                let unpinned = state.recentEntries.remove(at: idx)
                let pinned = ClipboardEntry(
                    id: unpinned.id,
                    text: unpinned.text,
                    createdAt: unpinned.createdAt,
                    sourceAppBundleID: unpinned.sourceAppBundleID,
                    pinnedAt: date
                )
                state.pinnedEntries.append(pinned)
                state.pinnedEntries
                    .sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            } else if let idx = state.pinnedEntries.firstIndex(where: { $0.id == id }) {
                let existing = state.pinnedEntries[idx]
                state.pinnedEntries[idx] = ClipboardEntry(
                    id: existing.id,
                    text: existing.text,
                    createdAt: existing.createdAt,
                    sourceAppBundleID: existing.sourceAppBundleID,
                    pinnedAt: date
                )
                state.pinnedEntries
                    .sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            }
        }
    }

    package func unpin(id: String) {
        stateLock.withLock { state in
            guard let db = state.db else { return }

            let sql = "UPDATE clipboard_entries SET pinned_at = NULL WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }

            if let idx = state.pinnedEntries.firstIndex(where: { $0.id == id }) {
                let pinned = state.pinnedEntries.remove(at: idx)
                let unpinned = ClipboardEntry(
                    id: pinned.id,
                    text: pinned.text,
                    createdAt: pinned.createdAt,
                    sourceAppBundleID: pinned.sourceAppBundleID,
                    pinnedAt: nil
                )
                state.recentEntries.append(unpinned)
                state.recentEntries.sort { $0.createdAt > $1.createdAt }
                if state.recentEntries.count > Self.inMemoryRecentWindowLimit {
                    state.recentEntries.removeLast()
                }
            }
        }
    }

    package func togglePin(id: String, date: Date = .now) {
        let isCurrentlyPinned = stateLock.withLock { state in
            state.pinnedEntries.contains { $0.id == id }
        }
        if isCurrentlyPinned {
            unpin(id: id)
        } else {
            pin(id: id, date: date)
        }
    }

    // MARK: - Deletion & Clear

    package func delete(id: String) {
        stateLock.withLock { state in
            guard let db = state.db else { return }

            let sql = "DELETE FROM clipboard_entries WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }

            let removedFromPinned = state.pinnedEntries.firstIndex(where: { $0.id == id })
                .map { state.pinnedEntries.remove(at: $0) } != nil
            let removedFromRecent = state.recentEntries.firstIndex(where: { $0.id == id })
                .map { state.recentEntries.remove(at: $0) } != nil

            if removedFromPinned || removedFromRecent {
                state.totalCount = max(0, state.totalCount - 1)
            }
        }
    }

    package func clear() {
        stateLock.withLock { state in
            guard let db = state.db else { return }

            sqlite3_exec(db, "DELETE FROM clipboard_entries;", nil, nil, nil)
            state.pinnedEntries.removeAll()
            state.recentEntries.removeAll()
            state.totalCount = 0
        }
    }

    // MARK: - Retention Pruning

    package func prune(olderThan cutoff: Date) {
        stateLock.withLock { state in
            guard let db = state.db else { return }

            let sql = "DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }

            state.recentEntries.removeAll { $0.createdAt < cutoff }
            state.totalCount = Self.queryTotalCount(db: db)
        }
    }

    package func prune(retention: ClipboardRetention, now: Date = .now) {
        guard let cutoff = retention.cutoffDate(from: now) else { return }
        prune(olderThan: cutoff)
    }

    // MARK: - Private SQLite Helpers

    private static func initializeSchema(db: OpaquePointer) {
        let schemaSQL = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;

        CREATE TABLE IF NOT EXISTS clipboard_entries (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            source_app_bundle_id TEXT,
            pinned_at REAL
        );

        CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_entries(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clipboard_pinned_at ON clipboard_entries(pinned_at ASC);

        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
            text,
            content='clipboard_entries',
            content_rowid='rowid',
            tokenize='trigram'
        );

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, new.text);
        END;

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        END;

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_au AFTER UPDATE ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES('delete', old.rowid, old.text);
            INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, new.text);
        END;
        """
        sqlite3_exec(db, schemaSQL, nil, nil, nil)
    }

    private static func loadInitialWindow(
        db: OpaquePointer
    ) -> (pinned: [ClipboardEntry], recent: [ClipboardEntry], total: Int) {
        var pinned: [ClipboardEntry] = []
        var recent: [ClipboardEntry] = []

        // Load all pinned entries sorted by pin time ascending
        let pinnedSQL = """
        SELECT id, text, created_at, source_app_bundle_id, pinned_at
        FROM clipboard_entries
        WHERE pinned_at IS NOT NULL
        ORDER BY pinned_at ASC;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pinnedSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = readEntry(from: stmt) {
                    pinned.append(entry)
                }
            }
        }

        // Load newest unpinned entries up to limit
        let recentSQL = """
        SELECT id, text, created_at, source_app_bundle_id, pinned_at
        FROM clipboard_entries
        WHERE pinned_at IS NULL
        ORDER BY created_at DESC
        LIMIT ?;
        """
        if sqlite3_prepare_v2(db, recentSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(inMemoryRecentWindowLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = readEntry(from: stmt) {
                    recent.append(entry)
                }
            }
        }

        let total = queryTotalCount(db: db)
        return (pinned, recent, total)
    }

    private static func queryTotalCount(db: OpaquePointer) -> Int {
        let countSQL = "SELECT COUNT(*) FROM clipboard_entries;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func readEntry(from stmt: OpaquePointer?) -> ClipboardEntry? {
        guard let stmt else { return nil }

        guard let idCString = sqlite3_column_text(stmt, 0),
              let textCString = sqlite3_column_text(stmt, 1)
        else {
            return nil
        }

        let id = String(cString: idCString)
        let text = String(cString: textCString)
        let createdAtTimestamp = sqlite3_column_double(stmt, 2)
        let createdAt = Date(timeIntervalSince1970: createdAtTimestamp)

        let sourceAppBundleID: String? = if sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                                            let bundleIDCString = sqlite3_column_text(stmt, 3)
        {
            String(cString: bundleIDCString)
        } else {
            nil
        }

        let pinnedAt: Date? = if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        } else {
            nil
        }

        return ClipboardEntry(
            id: id,
            text: text,
            createdAt: createdAt,
            sourceAppBundleID: sourceAppBundleID,
            pinnedAt: pinnedAt
        )
    }
}
