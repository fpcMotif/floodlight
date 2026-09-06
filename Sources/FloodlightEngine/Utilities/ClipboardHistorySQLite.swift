import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardHistorySQLite {
    static let entryColumns = """
    id, text, created_at, source_app_bundle_id, pinned_at, kind, \
    image_hash, image_width, image_height, image_byte_count, thumbnail_png
    """

    static func initializeSchema(db: OpaquePointer) {
        let schemaSQL = """
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
        migrateImageColumns(db: db)
        recreateFTSTriggers(db: db)
    }

    static func loadInitialWindow(
        db: OpaquePointer,
        recentLimit: Int
    ) -> (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
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

        return (pinned, recent)
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

    private static func migrateImageColumns(db: OpaquePointer) {
        // Ignore duplicate-column failures on databases that already have these columns.
        sqlite3_exec(
            db,
            "ALTER TABLE clipboard_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';",
            nil,
            nil,
            nil
        )
        for columnSQL in [
            "ALTER TABLE clipboard_entries ADD COLUMN image_hash TEXT;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_width INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_height INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN image_byte_count INTEGER;",
            "ALTER TABLE clipboard_entries ADD COLUMN thumbnail_png BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN png_data BLOB;",
            "ALTER TABLE clipboard_entries ADD COLUMN tiff_data BLOB;",
        ] {
            sqlite3_exec(db, columnSQL, nil, nil, nil)
        }
    }

    private static func recreateFTSTriggers(db: OpaquePointer) {
        sqlite3_exec(db, "DROP TRIGGER IF EXISTS clipboard_entries_ai;", nil, nil, nil)
        sqlite3_exec(db, "DROP TRIGGER IF EXISTS clipboard_entries_ad;", nil, nil, nil)
        sqlite3_exec(db, "DROP TRIGGER IF EXISTS clipboard_entries_au;", nil, nil, nil)
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
        sqlite3_exec(db, triggerSQL, nil, nil, nil)
    }
}
