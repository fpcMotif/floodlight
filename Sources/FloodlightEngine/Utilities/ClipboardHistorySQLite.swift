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
    image_hash, image_width, image_height, image_byte_count, thumbnail_png
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
        try migrateImageColumns(db: db)
        try recreateFTSTriggers(db: db)
    }

    /// Runs `sql`, throwing the message SQLite reported instead of discarding it.
    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            throw Failure(code: result, message: message)
        }
    }

    static func loadInitialWindow(
        db: OpaquePointer,
        recentLimit: Int
    ) -> (pinned: [ClipboardEntry], recent: [ClipboardEntry], total: Int) {
        var pinned: [ClipboardEntry] = []
        var recent: [ClipboardEntry] = []

        let pinnedSQL = """
        SELECT \(entryColumns)
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

        let recentSQL = """
        SELECT \(entryColumns)
        FROM clipboard_entries
        WHERE pinned_at IS NULL
        ORDER BY created_at DESC
        LIMIT ?;
        """
        if sqlite3_prepare_v2(db, recentSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(recentLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = readEntry(from: stmt) {
                    recent.append(entry)
                }
            }
        }

        return (pinned, recent, queryTotalCount(db: db))
    }

    static func queryTotalCount(db: OpaquePointer) -> Int {
        let countSQL = "SELECT COUNT(*) FROM clipboard_entries;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func readEntry(from stmt: OpaquePointer?) -> ClipboardEntry? {
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

        let kind: ClipboardEntryKind = if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
                                          let kindCString = sqlite3_column_text(stmt, 5),
                                          let parsed =
                                          ClipboardEntryKind(rawValue: String(cString: kindCString))
        {
            parsed
        } else {
            .text
        }

        let image: ClipboardImageMetadata? = if kind == .image,
                                                sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                                                let hashCString = sqlite3_column_text(stmt, 6)
        {
            ClipboardImageMetadata(
                hash: String(cString: hashCString),
                width: Int(sqlite3_column_int64(stmt, 7)),
                height: Int(sqlite3_column_int64(stmt, 8)),
                byteCount: Int(sqlite3_column_int64(stmt, 9)),
                thumbnailPNGData: readBlob(stmt, index: 10) ?? Data()
            )
        } else {
            nil
        }

        return ClipboardEntry(
            id: id,
            text: text,
            kind: kind,
            createdAt: createdAt,
            sourceAppBundleID: sourceAppBundleID,
            pinnedAt: pinnedAt,
            image: image
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Binds `value` with the transient destructor so SQLite copies the bytes at
    /// bind time — the Swift string's buffer only lives for the duration of this call.
    static func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
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

    /// Adds the columns later releases introduced. A column an earlier launch
    /// already added is success; anything else is a database we cannot prepare.
    private static func migrateImageColumns(db: OpaquePointer) throws {
        for columnSQL in [
            "ALTER TABLE clipboard_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';",
            "ALTER TABLE clipboard_entries ADD COLUMN image_hash TEXT;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_width INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_height INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_byte_count INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN thumbnail_png BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN png_data BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN tiff_data BLOB;",
        ] {
            do {
                try exec(db, columnSQL)
            } catch let failure as Failure where failure.isDuplicateColumn {
                continue
            }
        }
    }

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

        CREATE TRIGGER IF NOT EXISTS clipboard_entries_au AFTER UPDATE ON clipboard_entries BEGIN
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
