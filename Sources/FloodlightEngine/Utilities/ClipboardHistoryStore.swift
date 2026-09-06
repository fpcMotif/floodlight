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

        ClipboardHistorySQLite.initializeSchema(db: db)
        let (pinned, recent, total) = ClipboardHistorySQLite.loadInitialWindow(
            db: db,
            recentLimit: Self.inMemoryRecentWindowLimit
        )

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

    package func entry(id: String) -> ClipboardEntry? {
        stateLock.withLock { state in
            if let pinned = state.pinnedEntries.first(where: { $0.id == id }) {
                return pinned
            }
            if let recent = state.recentEntries.first(where: { $0.id == id }) {
                return recent
            }
            guard let db = state.db else { return nil }
            let sql = """
            SELECT \(ClipboardHistorySQLite.entryColumns)
            FROM clipboard_entries
            WHERE id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return ClipboardHistorySQLite.readEntry(from: stmt)
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
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (entry.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (entry.text as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (entry.kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, entry.createdAt.timeIntervalSince1970)
            if let bundleID = entry.sourceAppBundleID {
                sqlite3_bind_text(stmt, 5, (bundleID as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 7, Int64(width))
            sqlite3_bind_int64(stmt, 8, Int64(height))
            sqlite3_bind_int64(stmt, 9, Int64(primary.count))
            ClipboardHistorySQLite.bindBlob(stmt, index: 10, data: thumbnailPNGData)
            ClipboardHistorySQLite.bindBlob(stmt, index: 11, data: png)
            ClipboardHistorySQLite.bindBlob(stmt, index: 12, data: tiff)

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

    package func imageData(for id: String) -> ClipboardImagePayload? {
        stateLock.withLock { state in
            guard let db = state.db else { return nil }
            let sql = "SELECT png_data, tiff_data FROM clipboard_entries WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let png = ClipboardHistorySQLite.readBlob(stmt, index: 0)
            let tiff = ClipboardHistorySQLite.readBlob(stmt, index: 1)
            guard png != nil || tiff != nil else { return nil }
            return ClipboardImagePayload(png: png, tiff: tiff)
        }
    }

    package func imagePayloadInfo(for id: String) -> ClipboardImagePayloadInfo? {
        stateLock.withLock { state in
            guard let db = state.db else { return nil }
            // IS NOT NULL is answered from the record header, so this asks
            // whether a payload exists without ever materializing the blob.
            let sql = """
            SELECT png_data IS NOT NULL, tiff_data IS NOT NULL
            FROM clipboard_entries WHERE id = ? LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let hasPNG = sqlite3_column_int64(stmt, 0) != 0
            let hasTIFF = sqlite3_column_int64(stmt, 1) != 0
            guard hasPNG || hasTIFF else { return nil }
            return ClipboardImagePayloadInfo(hasPNG: hasPNG, hasTIFF: hasTIFF)
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
            INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at)
            VALUES (?, ?, ?, ?, ?, NULL);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (entry.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (entry.text as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (entry.kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, entry.createdAt.timeIntervalSince1970)
            if let bundleID = entry.sourceAppBundleID {
                sqlite3_bind_text(stmt, 5, (bundleID as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
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
                    Self.matchesSearch($0, query: trimmed)
                }
                let recentMatches = state.recentEntries.filter {
                    Self.matchesSearch($0, query: trimmed)
                }
                return pinnedMatches + recentMatches
            }

            // FTS5 trigram search for queries of 3 or more characters
            let escaped = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let ftsSQL = """
            SELECT \(ClipboardHistorySQLite.entryColumns)
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
                    if let entry = ClipboardHistorySQLite.readEntry(from: stmt) {
                        results.append(entry)
                    }
                }
                return results
            }

            // Fallback to in-memory filter if FTS query preparation fails
            let pinnedMatches = state.pinnedEntries.filter {
                Self.matchesSearch($0, query: trimmed)
            }
            let recentMatches = state.recentEntries.filter {
                Self.matchesSearch($0, query: trimmed)
            }
            return pinnedMatches + recentMatches
        }
    }

    private static func cappedImageData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxImageByteCount else {
            return nil
        }
        return data
    }

    private static func matchesSearch(_ entry: ClipboardEntry, query: String) -> Bool {
        if entry.text.localizedCaseInsensitiveContains(query) { return true }
        guard let image = entry.image else { return false }
        return "\(image.width)×\(image.height)".localizedCaseInsensitiveContains(query)
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
                state.pinnedEntries.append(unpinned.withPinnedAt(date))
                state.pinnedEntries
                    .sort { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
            } else if let idx = state.pinnedEntries.firstIndex(where: { $0.id == id }) {
                let existing = state.pinnedEntries[idx]
                state.pinnedEntries[idx] = existing.withPinnedAt(date)
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
                state.recentEntries.append(pinned.withPinnedAt(nil))
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
            state.totalCount = ClipboardHistorySQLite.queryTotalCount(db: db)
        }
    }

    package func prune(retention: ClipboardRetention, now: Date = .now) {
        guard let cutoff = retention.cutoffDate(from: now) else { return }
        prune(olderThan: cutoff)
    }
}
