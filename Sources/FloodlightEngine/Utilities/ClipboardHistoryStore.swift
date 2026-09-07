import Foundation
import os
import SQLite3

/// A persistent, privacy-respecting local clipboard store powered by SQLite3
/// and an FTS5 trigram index.
package final class ClipboardHistoryStore: @unchecked Sendable {
    package static let maxTextByteCount = 32_000
    package static let maxImageByteCount = 15 * 1_024 * 1_024
    package static let inMemoryRecentWindowLimit = 1_000
    package static let searchResultLimit = 200

    /// How long a statement waits for another connection's write lock before
    /// giving up. Long enough to outlast a concurrent write, short enough that
    /// a genuinely stuck database still fails rather than hanging a keystroke.
    private static let busyTimeoutMilliseconds: Int32 = 2_000

    private struct State: @unchecked Sendable {
        var db: OpaquePointer?
        var pinnedEntries: [ClipboardEntry]
        var recentEntries: [ClipboardEntry]
        /// Every windowed entry's text — and an image's dimensions — with case
        /// folded once, keyed by entry id, so a one- or two-character query
        /// is a plain substring scan rather than a locale-aware comparison
        /// per entry per keystroke (#73).
        var searchKeys: [String: String]
        var mutationVersion: UInt64 = 0

        init(db: OpaquePointer?, pinnedEntries: [ClipboardEntry], recentEntries: [ClipboardEntry]) {
            self.db = db
            self.pinnedEntries = pinnedEntries
            self.recentEntries = recentEntries
            searchKeys = Dictionary(
                uniqueKeysWithValues: (pinnedEntries + recentEntries).map {
                    ($0.id, ClipboardHistoryStore.searchKey(for: $0))
                }
            )
        }

        /// A newly recorded entry heads the window. Whatever the window no
        /// longer holds stays on disk, where the trigram index still finds it.
        mutating func admit(_ entry: ClipboardEntry) {
            recentEntries.insert(entry, at: 0)
            searchKeys[entry.id] = ClipboardHistoryStore.searchKey(for: entry)
            trimRecentWindow()
        }

        mutating func trimRecentWindow() {
            while recentEntries.count > ClipboardHistoryStore.inMemoryRecentWindowLimit {
                searchKeys[recentEntries.removeLast().id] = nil
            }
        }

        mutating func remove(where shouldRemove: (ClipboardEntry) -> Bool) {
            for entry in pinnedEntries where shouldRemove(entry) {
                searchKeys[entry.id] = nil
            }
            for entry in recentEntries where shouldRemove(entry) {
                searchKeys[entry.id] = nil
            }
            pinnedEntries.removeAll(where: shouldRemove)
            recentEntries.removeAll(where: shouldRemove)
        }

        mutating func removeAll() {
            pinnedEntries.removeAll()
            recentEntries.removeAll()
            searchKeys.removeAll()
        }
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    private static let log = Logger(
        subsystem: "com.floodlight.app",
        category: "clipboard-history"
    )

    package static func inMemory() -> ClipboardHistoryStore {
        (try? ClipboardHistoryStore(databasePath: ":memory:")) ??
            ClipboardHistoryStore(state: State(db: nil, pinnedEntries: [], recentEntries: []))
    }

    private init(state: State) {
        stateLock = OSAllocatedUnfairLock(initialState: state)
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

    package convenience init(databasePath: String) throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databasePath, &dbPointer, flags, nil)
        guard openResult == SQLITE_OK, let db = dbPointer else {
            let errorMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let dbPointer { sqlite3_close(dbPointer) }
            Self.logFailure(
                operation: "database open",
                message: "\(errorMsg) — falling back to in-memory history"
            )
            throw NSError(
                domain: "ClipboardHistoryStore",
                code: Int(openResult),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database: \(errorMsg)"]
            )
        }

        // A second connection holding the write lock is a transient condition,
        // not a broken database — wait for it rather than treating the schema
        // step below as unrecoverable and dropping the user's history into an
        // in-memory store for the rest of the session.
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)

        // A database we cannot prepare is not a database we should write to: throw,
        // and let the caller fall back to the in-memory store it already builds.
        do {
            try ClipboardHistorySQLite.initializeSchema(db: db)
        } catch {
            Self.logFailure(
                operation: "schema initialization",
                message: "\(error) — falling back to in-memory history"
            )
            sqlite3_close(db)
            throw error
        }

        let (pinned, recent) = ClipboardHistorySQLite.loadInitialWindow(
            db: db,
            recentLimit: Self.inMemoryRecentWindowLimit
        )

        self.init(state: State(db: db, pinnedEntries: pinned, recentEntries: recent))
    }

    deinit {
        stateLock.withLock { state in
            if let db = state.db {
                sqlite3_close(db)
                state.db = nil
            }
        }
    }

    /// How many writes this store has accepted since it opened. A reader that
    /// caches anything derived from the entries compares this before trusting
    /// its cache: it moves on record, pin, unpin, delete, clear, and prune,
    /// and on nothing else.
    package var mutationVersion: UInt64 {
        stateLock.withLock(\.mutationVersion)
    }

    package func entry(id: String) -> ClipboardEntry? {
        stateLock.withLock { state in
            if let pinned = state.pinnedEntries.first(where: { $0.id == id }) {
                return pinned
            }
            if let recent = state.recentEntries.first(where: { $0.id == id }) {
                return recent
            }
            guard let db = state.db else { return nil }
            return ClipboardHistorySQLite.fetchEntry(db: db, id: id)
        }
    }

    // MARK: - Recording

    @discardableResult
    package func record(
        text: String,
        sourceAppBundleID: String? = nil,
        date: Date = .now
    ) -> ClipboardEntry? {
        insert(
            text: text,
            kind: .text,
            sourceAppBundleID: sourceAppBundleID,
            date: date
        )
    }

    @discardableResult
    package func recordFile(
        path: String,
        sourceAppBundleID: String? = nil,
        date: Date = .now
    ) -> ClipboardEntry? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return insert(
            text: trimmed,
            kind: .file,
            sourceAppBundleID: sourceAppBundleID,
            date: date
        )
    }

    @discardableResult
    package func recordImage(
        pngData: Data? = nil,
        tiffData: Data? = nil,
        thumbnailPNGData: Data,
        width: Int,
        height: Int,
        displayName: String,
        sourceAppBundleID: String? = nil,
        date: Date = .now
    ) -> ClipboardEntry? {
        let png = Self.cappedImageData(pngData)
        let tiff = Self.cappedImageData(tiffData)
        guard let primary = png ?? tiff else { return nil }
        let hash = ClipboardHistorySQLite.sha256Hex(primary)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = name.isEmpty ? "\(width)×\(height)" : name
        let metadata = ClipboardImageMetadata(
            hash: hash,
            width: width,
            height: height,
            byteCount: primary.count,
            thumbnailPNGData: thumbnailPNGData
        )

        return stateLock.withLock { state -> ClipboardEntry? in
            guard let db = state.db else { return nil }

            let latest = state.recentEntries.first
                ?? state.pinnedEntries.max { $0.createdAt < $1.createdAt }
            if let latest, latest.kind == .image, latest.image?.hash == hash {
                return nil
            }

            let entry = ClipboardEntry(
                id: UUID().uuidString,
                text: searchable,
                kind: .image,
                createdAt: date,
                sourceAppBundleID: sourceAppBundleID,
                pinnedAt: nil,
                image: metadata
            )

            let insertSQL = """
            INSERT INTO clipboard_entries (
                id, text, kind, created_at, source_app_bundle_id, pinned_at,
                image_hash, image_width, image_height, image_byte_count,
                thumbnail_png, png_data, tiff_data
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?);
            """
            let accepted = Self.write(db: db, sql: insertSQL, operation: "record image") { stmt in
                ClipboardHistorySQLite.bindText(stmt, index: 1, value: entry.id)
                ClipboardHistorySQLite.bindText(stmt, index: 2, value: entry.text)
                ClipboardHistorySQLite.bindText(stmt, index: 3, value: entry.kind.rawValue)
                sqlite3_bind_double(stmt, 4, entry.createdAt.timeIntervalSince1970)
                ClipboardHistorySQLite.bindText(stmt, index: 5, value: entry.sourceAppBundleID)
                ClipboardHistorySQLite.bindText(stmt, index: 6, value: hash)
                sqlite3_bind_int64(stmt, 7, Int64(width))
                sqlite3_bind_int64(stmt, 8, Int64(height))
                sqlite3_bind_int64(stmt, 9, Int64(primary.count))
                ClipboardHistorySQLite.bindBlob(stmt, index: 10, data: thumbnailPNGData)
                ClipboardHistorySQLite.bindBlob(stmt, index: 11, data: png)
                ClipboardHistorySQLite.bindBlob(stmt, index: 12, data: tiff)
            }
            guard accepted else { return nil }

            state.admit(entry)
            state.mutationVersion &+= 1
            return entry
        }
    }

    package func imageData(for id: String) -> ClipboardImagePayload? {
        stateLock.withLock { state in
            guard let db = state.db else { return nil }
            let sql = "SELECT png_data, tiff_data FROM clipboard_entries WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            ClipboardHistorySQLite.bindText(stmt, index: 1, value: id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let png = ClipboardHistorySQLite.readBlob(stmt, index: 0)
            let tiff = ClipboardHistorySQLite.readBlob(stmt, index: 1)
            guard png != nil || tiff != nil else { return nil }
            return ClipboardImagePayload(png: png, tiff: tiff)
        }
    }

    private func insert(
        text: String,
        kind: ClipboardEntryKind,
        sourceAppBundleID: String?,
        date: Date
    ) -> ClipboardEntry? {
        guard text.utf8.count <= Self.maxTextByteCount else {
            return nil
        }

        return stateLock.withLock { state -> ClipboardEntry? in
            guard let db = state.db else { return nil }

            let latest = state.recentEntries.first
                ?? state.pinnedEntries.max { $0.createdAt < $1.createdAt }
            if let latest, latest.text == text, latest.kind == kind {
                return nil
            }

            let entry = ClipboardEntry(
                id: UUID().uuidString,
                text: text,
                kind: kind,
                createdAt: date,
                sourceAppBundleID: sourceAppBundleID,
                pinnedAt: nil
            )

            let insertSQL = """
            INSERT INTO clipboard_entries (
                id, text, kind, created_at, source_app_bundle_id, pinned_at,
                content_kind, content_detail
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?);
            """
            let stored = entry.textContent?.storedForm
            let accepted = Self.write(db: db, sql: insertSQL, operation: "record") { stmt in
                ClipboardHistorySQLite.bindText(stmt, index: 1, value: entry.id)
                ClipboardHistorySQLite.bindText(stmt, index: 2, value: entry.text)
                ClipboardHistorySQLite.bindText(stmt, index: 3, value: entry.kind.rawValue)
                sqlite3_bind_double(stmt, 4, entry.createdAt.timeIntervalSince1970)
                ClipboardHistorySQLite.bindText(stmt, index: 5, value: entry.sourceAppBundleID)
                ClipboardHistorySQLite.bindText(stmt, index: 6, value: stored?.kind)
                ClipboardHistorySQLite.bindText(stmt, index: 7, value: stored?.detail)
            }
            guard accepted else { return nil }

            state.admit(entry)
            state.mutationVersion &+= 1
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
                return Self.windowMatches(in: state, query: trimmed)
            }

            // FTS5 trigram search for queries of 3 or more characters
            let escaped = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if let matches = ClipboardHistorySQLite.fetchMatches(
                db: db,
                ftsQuery: escaped,
                limit: Self.searchResultLimit
            ) {
                return matches
            }

            // Fallback to in-memory filter if FTS query preparation fails
            return Self.windowMatches(in: state, query: trimmed)
        }
    }

    /// Pinned entries first, then recent, each kept if its folded search key
    /// contains the folded query — the substring scan a query too short for
    /// the trigram index gets.
    private static func windowMatches(in state: State, query: String) -> [ClipboardEntry] {
        let folded = fold(query)
        func matches(_ entry: ClipboardEntry) -> Bool {
            state.searchKeys[entry.id]?.contains(folded) == true
        }
        return state.pinnedEntries.filter(matches) + state.recentEntries.filter(matches)
    }

    /// What a short query is matched against: the text, plus an image's
    /// dimensions, with case folded the way the query will be.
    private static func searchKey(for entry: ClipboardEntry) -> String {
        guard let image = entry.image else { return fold(entry.text) }
        return fold(entry.text) + " \(image.width)×\(image.height)"
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: .current)
    }

    private static func cappedImageData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxImageByteCount else {
            return nil
        }
        return data
    }

    // MARK: - Writes

    /// Runs one write statement and reports whether SQLite accepted it, logging the
    /// message when it did not. The in-memory mirror is the caller's to update, and
    /// only once this has returned `true`.
    private static func write(
        db: OpaquePointer,
        sql: String,
        operation: String,
        bind: (OpaquePointer?) -> Void
    ) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logFailure(operation: operation, message: String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            logFailure(operation: operation, message: String(cString: sqlite3_errmsg(db)))
            return false
        }
        return true
    }

    /// The one place a write failure is worded, so every path says why the
    /// board did not move in the same shape.
    private static func logFailure(operation: String, message: String) {
        log.error(
            "Clipboard history \(operation, privacy: .public) failed: \(message, privacy: .public)"
        )
    }

    // MARK: - Pinning

    @discardableResult
    package func pin(id: String, date: Date = .now) -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }

            let accepted = Self.write(
                db: db,
                sql: "UPDATE clipboard_entries SET pinned_at = ? WHERE id = ?;",
                operation: "pin"
            ) { stmt in
                sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                ClipboardHistorySQLite.bindText(stmt, index: 2, value: id)
            }
            guard accepted else { return false }
            state.mutationVersion &+= 1

            if let idx = state.recentEntries.firstIndex(where: { $0.id == id }) {
                let unpinned = state.recentEntries.remove(at: idx)
                state.pinnedEntries.append(unpinned.withPinnedAt(date))
                state.pinnedEntries
                    .sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            } else if let idx = state.pinnedEntries.firstIndex(where: { $0.id == id }) {
                let existing = state.pinnedEntries[idx]
                state.pinnedEntries[idx] = existing.withPinnedAt(date)
                state.pinnedEntries
                    .sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            }
            return true
        }
    }

    @discardableResult
    package func unpin(id: String) -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }

            let accepted = Self.write(
                db: db,
                sql: "UPDATE clipboard_entries SET pinned_at = NULL WHERE id = ?;",
                operation: "unpin"
            ) { stmt in
                ClipboardHistorySQLite.bindText(stmt, index: 1, value: id)
            }
            guard accepted else { return false }
            state.mutationVersion &+= 1

            if let idx = state.pinnedEntries.firstIndex(where: { $0.id == id }) {
                let pinned = state.pinnedEntries.remove(at: idx)
                state.recentEntries.append(pinned.withPinnedAt(nil))
                state.recentEntries.sort { $0.createdAt > $1.createdAt }
                state.trimRecentWindow()
            }
            return true
        }
    }

    // MARK: - Deletion & Clear

    @discardableResult
    package func delete(id: String) -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }

            let accepted = Self.write(
                db: db,
                sql: "DELETE FROM clipboard_entries WHERE id = ?;",
                operation: "delete"
            ) { stmt in
                ClipboardHistorySQLite.bindText(stmt, index: 1, value: id)
            }
            guard accepted else { return false }

            state.remove { $0.id == id }
            state.mutationVersion &+= 1
            return true
        }
    }

    @discardableResult
    package func clear() -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }

            let accepted = Self.write(
                db: db,
                sql: "DELETE FROM clipboard_entries;",
                operation: "clear"
            ) { _ in }
            guard accepted else { return false }

            state.removeAll()
            state.mutationVersion &+= 1
            return true
        }
    }

    // MARK: - Retention Pruning

    @discardableResult
    package func prune(olderThan cutoff: Date) -> Bool {
        stateLock.withLock { state in
            guard let db = state.db else { return false }

            let accepted = Self.write(
                db: db,
                sql: "DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?;",
                operation: "prune"
            ) { stmt in
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            }
            guard accepted else { return false }

            state.remove { !$0.isPinned && $0.createdAt < cutoff }
            state.mutationVersion &+= 1
            return true
        }
    }

    /// `.forever` has nothing to prune, which is success — there is no cutoff to run.
    @discardableResult
    package func prune(retention: ClipboardRetention, now: Date = .now) -> Bool {
        guard let cutoff = retention.cutoffDate(from: now) else { return true }
        return prune(olderThan: cutoff)
    }
}
