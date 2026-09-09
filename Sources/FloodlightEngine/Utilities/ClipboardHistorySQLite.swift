import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardHistorySQLite {
    /// A SQLite call that reported failure, carrying the message SQLite gave for it.
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String

        var description: String {
            "SQLite error \(code): \(message)"
        }

        /// A migration re-adding a column an older launch already added.
        var isDuplicateColumn: Bool {
            message.contains("duplicate column name")
        }
    }

    static let entryColumns = """
    id, text, created_at, source_app_bundle_id, pinned_at, kind, \
    image_hash, image_width, image_height, image_byte_count, thumbnail_png, \
    content_kind, content_detail
    """

    private static let schemaSQL = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS clipboard_entries (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        created_at REAL NOT NULL,
        source_app_bundle_id TEXT,
        pinned_at REAL,
        kind TEXT NOT NULL DEFAULT 'text'
    );

    CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_entries(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_clipboard_pinned_at ON clipboard_entries(pinned_at ASC);

    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
        text,
        content='clipboard_entries',
        content_rowid='rowid',
        tokenize='trigram'
    );
    """

    static func initializeSchema(db: OpaquePointer) throws {
        try exec(db, schemaSQL)
        try migrateAddedColumns(db: db)
        try recreateFTSTriggers(db: db)
    }

    /// Runs `sql`, throwing the message SQLite reported instead of discarding it.
    ///
    /// Schema work only — every row mutation goes through
    /// `ClipboardHistoryStore.write`, which reports failure as a Bool the
    /// caller must consume before it touches the in-memory mirror.
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            throw Failure(code: result, message: message)
        }
    }

    // MARK: - Reads

    /// A row's classification computed while reading it, waiting to be
    /// stored once the statement that read it is finalized.
    typealias Backfill = (id: String, content: ClipboardTextContent)

    static func loadInitialWindow(
        db: OpaquePointer,
        recentLimit: Int
    ) -> (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
        var backfill: [Backfill] = []

        let pinnedSQL = """
        SELECT \(entryColumns)
        FROM clipboard_entries
        WHERE pinned_at IS NOT NULL
        ORDER BY pinned_at ASC;
        """
        let pinned = fetch(db: db, sql: pinnedSQL, backfill: &backfill) { _ in } ?? []

        let recentSQL = """
        SELECT \(entryColumns)
        FROM clipboard_entries
        WHERE pinned_at IS NULL
        ORDER BY created_at DESC
        LIMIT ?;
        """
        let recent = fetch(db: db, sql: recentSQL, backfill: &backfill) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(recentLimit))
        } ?? []

        storeClassifications(db: db, of: backfill)
        return (pinned, recent)
    }

    static func fetchEntry(db: OpaquePointer, id: String) -> ClipboardEntry? {
        var backfill: [Backfill] = []
        let sql = """
        SELECT \(entryColumns)
        FROM clipboard_entries
        WHERE id = ?
        LIMIT 1;
        """
        let entries = fetch(db: db, sql: sql, backfill: &backfill) { stmt in
            bindText(stmt, index: 1, value: id)
        }
        storeClassifications(db: db, of: backfill)
        return entries?.first
    }

    /// The trigram index's answer for `ftsQuery`, pinned entries first. `nil`
    /// when the statement cannot be prepared, so the store can fall back to
    /// scanning its window instead of reporting nothing.
    static func fetchMatches(
        db: OpaquePointer,
        ftsQuery: String,
        limit: Int
    ) -> [ClipboardEntry]? {
        var backfill: [Backfill] = []
        let sql = """
        SELECT \(entryColumns)
        FROM clipboard_entries
        WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?)
        ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC
        LIMIT ?;
        """
        let entries = fetch(db: db, sql: sql, backfill: &backfill) { stmt in
            bindText(stmt, index: 1, value: ftsQuery)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
        storeClassifications(db: db, of: backfill)
        return entries
    }

    /// Runs one SELECT over `entryColumns` and reads every row it returns, or
    /// `nil` if the statement cannot be prepared. Rows classified on the way
    /// in land in `backfill`; the statement is finalized before this returns,
    /// so the caller can write them back without an open read on the table.
    private static func fetch(
        db: OpaquePointer,
        sql: String,
        backfill: inout [Backfill],
        bind: (OpaquePointer?) -> Void
    ) -> [ClipboardEntry]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var entries: [ClipboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readEntry(from: stmt, backfill: &backfill) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// One row as a Clipboard Entry. A text row recorded before its
    /// classification was stored comes back classified now and is added to
    /// `backfill`, for the caller to persist once its statement is done
    /// (#73) — so the one-time work happens on load, never on a keystroke.
    static func readEntry(
        from stmt: OpaquePointer?,
        backfill: inout [Backfill]
    ) -> ClipboardEntry? {
        guard let stmt else { return nil }

        guard let id = readText(stmt, index: 0), let text = readText(stmt, index: 1) else {
            return nil
        }

        let createdAtTimestamp = sqlite3_column_double(stmt, 2)
        let createdAt = Date(timeIntervalSince1970: createdAtTimestamp)

        let sourceAppBundleID: String? = if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            readText(stmt, index: 3)
        } else {
            nil
        }

        let pinnedAt: Date? = if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        } else {
            nil
        }

        let kind: ClipboardEntryKind = if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
                                          let raw = readText(stmt, index: 5),
                                          let parsed = ClipboardEntryKind(rawValue: raw)
        {
            parsed
        } else {
            .text
        }

        let image: ClipboardImageMetadata? = if kind == .image,
                                                sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                                                let hash = readText(stmt, index: 6)
        {
            ClipboardImageMetadata(
                hash: hash,
                width: Int(sqlite3_column_int64(stmt, 7)),
                height: Int(sqlite3_column_int64(stmt, 8)),
                byteCount: Int(sqlite3_column_int64(stmt, 9)),
                thumbnailPNGData: readBlob(stmt, index: 10) ?? Data()
            )
        } else {
            nil
        }

        var content = ClipboardTextContent(
            storedKind: readText(stmt, index: 11),
            storedDetail: readText(stmt, index: 12)
        )
        if kind == .text, content == nil {
            let classified = ClipboardTextContent.classify(text)
            backfill.append((id: id, content: classified))
            content = classified
        }

        return ClipboardEntry(
            id: id,
            text: text,
            kind: kind,
            createdAt: createdAt,
            sourceAppBundleID: sourceAppBundleID,
            pinnedAt: pinnedAt,
            image: image,
            textContent: content
        )
    }

    /// Persists the classification `readEntry` computed for rows recorded
    /// before the columns existed, so every later read finds it stored. One
    /// transaction, once per row, ever; a failure costs nothing but a repeat
    /// the next time the row is read.
    private static func storeClassifications(db: OpaquePointer, of backfill: [Backfill]) {
        guard !backfill.isEmpty else { return }
        let sql = "UPDATE clipboard_entries SET content_kind = ?, content_detail = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else { return }

        for (id, content) in backfill {
            let stored = content.storedForm
            sqlite3_reset(stmt)
            bindText(stmt, index: 1, value: stored.kind)
            bindText(stmt, index: 2, value: stored.detail)
            bindText(stmt, index: 3, value: id)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Binds `value` with the transient destructor so SQLite copies the bytes at
    /// bind time — the Swift string's buffer only lives for the duration of this call.
    ///
    /// The length is the explicit UTF-8 byte count, not `-1`. A negative length
    /// tells SQLite to measure to the first NUL, so a string carrying an
    /// interior one — clipboard text is whatever another application put on the
    /// pasteboard — would be stored truncated while the in-memory mirror kept
    /// the whole thing. That divergence is the one this store exists to avoid.
    static func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        // `withCString` hands over the whole UTF-8 encoding plus a terminator,
        // and the explicit length is what stops SQLite measuring to the first
        // NUL instead. It also gives the empty string a real address to bind
        // to — `clipboard_entries.text` is TEXT NOT NULL, and SQLite reads a
        // null value pointer as `sqlite3_bind_null` whatever the length says.
        _ = value.withCString { chars in
            sqlite3_bind_text(stmt, index, chars, Int32(value.utf8.count), sqliteTransient)
        }
    }

    /// Reads a text column by its byte count rather than to its first NUL.
    ///
    /// The mirror of `bindText`: `sqlite3_column_text` must be called before
    /// `sqlite3_column_bytes` for the length to describe the UTF-8 encoding,
    /// and `String(cString:)` would stop at an interior NUL that the column
    /// legitimately contains.
    static func readText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        // Not `String(bytes:encoding: .utf8)`, which the lint rule would
        // otherwise prefer: it treats a leading U+FEFF as a byte-order mark and
        // strips it, so a clipboard entry that is exactly a zero-width no-break
        // space comes back empty. `decoding:` copies the bytes as they are.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    static func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data?) {
        guard let data, !data.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                stmt,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                sqliteTransient
            )
        }
    }

    static func readBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard let stmt, sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    /// Adds the columns later releases introduced — the image columns, then
    /// the stored text classification (#73). A column an earlier launch
    /// already added is success; anything else is a database we cannot prepare.
    private static func migrateAddedColumns(db: OpaquePointer) throws {
        for columnSQL in [
            "ALTER TABLE clipboard_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';",
            "ALTER TABLE clipboard_entries ADD COLUMN image_hash TEXT;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_width INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_height INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_byte_count INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN thumbnail_png BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN png_data BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN tiff_data BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN content_kind TEXT;",
            "ALTER TABLE clipboard_entries ADD COLUMN content_detail TEXT;",
        ] {
            do {
                try exec(db, columnSQL)
            } catch let failure as Failure where failure.isDuplicateColumn {
                continue
            }
        }
    }

    /// The update trigger names the columns the indexed text is built from,
    /// so a pin, an unpin, or a stored classification leaves the trigram
    /// index alone: re-tokenizing an entry whose text did not change was a
    /// cost per write that nothing read back.
    private static func recreateFTSTriggers(db: OpaquePointer) throws {
        try exec(db, """
        DROP TRIGGER IF EXISTS clipboard_entries_ai;
        DROP TRIGGER IF EXISTS clipboard_entries_ad;
        DROP TRIGGER IF EXISTS clipboard_entries_au;
        """)
        let triggerSQL = """
        CREATE TRIGGER IF NOT EXISTS clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(rowid, text) VALUES (
                new.rowid,
                CASE WHEN new.kind = 'image' AND new.image_width IS NOT NULL
                    THEN new.text || ' ' || new.image_width || '×' || new.image_height
                    ELSE new.text
                END
            );
        END;

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES(
                'delete',
                old.rowid,
                CASE WHEN old.kind = 'image' AND old.image_width IS NOT NULL
                    THEN old.text || ' ' || old.image_width || '×' || old.image_height
                    ELSE old.text
                END
            );
        END;

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_au
        AFTER UPDATE OF text, kind, image_width, image_height ON clipboard_entries BEGIN
            INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES(
                'delete',
                old.rowid,
                CASE WHEN old.kind = 'image' AND old.image_width IS NOT NULL
                    THEN old.text || ' ' || old.image_width || '×' || old.image_height
                    ELSE old.text
                END
            );
            INSERT INTO clipboard_fts(rowid, text) VALUES (
                new.rowid,
                CASE WHEN new.kind = 'image' AND new.image_width IS NOT NULL
                    THEN new.text || ' ' || new.image_width || '×' || new.image_height
                    ELSE new.text
                END
            );
        END;
        """
        try exec(db, triggerSQL)
    }
}
