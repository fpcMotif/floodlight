/*
 * Clipboard History on SQLite, in the Swift app's `clipboard_entries` schema
 * and its trigram full-text table (ADR 0008), so this frontend can later
 * read the Swift app's history and the other way round.
 *
 * Shaped for scriptc's FFI like flshim.c: spans in, scalars out, results
 * serialized into caller-owned buffers. A listed entry is one record ended
 * by RS (0x1e), its fields split by US (0x1f), in the order clip-sqlite.ts
 * reads them. One connection per process, used from the script thread only.
 */
#include "flclip.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sqlite3.h>

#include "flnative.h"

#define RS 0x1e
#define US 0x1f
/* A listed entry carries at most this much text; flc_text has the rest. */
#define PREVIEW_BYTES 1024

static sqlite3 *db;

static const char *schema_sql =
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = NORMAL;"
    "CREATE TABLE IF NOT EXISTS clipboard_entries ("
    "  id TEXT PRIMARY KEY, text TEXT NOT NULL, created_at REAL NOT NULL,"
    "  source_app_bundle_id TEXT, pinned_at REAL, kind TEXT NOT NULL DEFAULT 'text');"
    "CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_entries(created_at DESC);"
    "CREATE INDEX IF NOT EXISTS idx_clipboard_pinned_at ON clipboard_entries(pinned_at ASC);"
    "CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5("
    "  text, content='clipboard_entries', content_rowid='rowid', tokenize='trigram');";

/* The Swift app's additive migrations; a duplicate column is not an error. */
static const char *added_columns[] = {
    "ALTER TABLE clipboard_entries ADD COLUMN image_hash TEXT;",
    "ALTER TABLE clipboard_entries ADD COLUMN image_width INTEGER;",
    "ALTER TABLE clipboard_entries ADD COLUMN image_height INTEGER;",
    "ALTER TABLE clipboard_entries ADD COLUMN image_byte_count INTEGER;",
    "ALTER TABLE clipboard_entries ADD COLUMN thumbnail_png BLOB;",
    "ALTER TABLE clipboard_entries ADD COLUMN png_data BLOB;",
    "ALTER TABLE clipboard_entries ADD COLUMN tiff_data BLOB;",
    "ALTER TABLE clipboard_entries ADD COLUMN content_kind TEXT;",
    "ALTER TABLE clipboard_entries ADD COLUMN content_detail TEXT;",
};

#define FTS_TEXT(row)                                                                 \
    "CASE WHEN " row ".kind = 'image' AND " row ".image_width IS NOT NULL THEN " row  \
    ".text || ' ' || " row ".image_width || '×' || " row ".image_height ELSE " row ".text END"

static const char *trigger_sql =
    "DROP TRIGGER IF EXISTS clipboard_entries_ai;"
    "DROP TRIGGER IF EXISTS clipboard_entries_ad;"
    "DROP TRIGGER IF EXISTS clipboard_entries_au;"
    "CREATE TRIGGER clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN"
    "  INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, " FTS_TEXT("new") ");"
    "END;"
    "CREATE TRIGGER clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN"
    "  INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES('delete', old.rowid, " FTS_TEXT("old") ");"
    "END;"
    "CREATE TRIGGER clipboard_entries_au AFTER UPDATE OF text, kind, image_width, image_height"
    "  ON clipboard_entries BEGIN"
    "  INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES('delete', old.rowid, " FTS_TEXT("old") ");"
    "  INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, " FTS_TEXT("new") ");"
    "END;";

#define COLUMNS                                                                             \
    "id, text, kind, created_at, source_app_bundle_id, pinned_at, image_width, image_height, " \
    "image_byte_count, content_kind, content_detail, image_hash"

static int init_schema(sqlite3 *conn) {
    if (sqlite3_exec(conn, schema_sql, NULL, NULL, NULL) != SQLITE_OK) return -1;
    for (size_t i = 0; i < sizeof added_columns / sizeof added_columns[0]; i++) {
        sqlite3_exec(conn, added_columns[i], NULL, NULL, NULL);
    }
    return sqlite3_exec(conn, trigger_sql, NULL, NULL, NULL) == SQLITE_OK ? 0 : -1;
}

static int span_cstr(const uint8_t *bytes, size_t len, char *out, size_t cap) {
    if (len + 1 > cap || (len > 0 && memchr(bytes, 0, len) != NULL)) return -1;
    if (len > 0) memcpy(out, bytes, len);
    out[len] = 0;
    return 0;
}

/* 1: the file opened. 2: it could not, and history lives in memory for this
 * run. Negative: not even that. */
int32_t flc_open(const uint8_t *path, size_t len) {
    char p[4096];
    if (db != NULL) {
        sqlite3_close(db);
        db = NULL;
    }
    if (span_cstr(path, len, p, sizeof p) == 0 && sqlite3_open(p, &db) == SQLITE_OK && init_schema(db) == 0) {
        sqlite3_busy_timeout(db, 500);
        return 1;
    }
    if (db != NULL) sqlite3_close(db);
    db = NULL;
    if (sqlite3_open(":memory:", &db) == SQLITE_OK && init_schema(db) == 0) return 2;
    return -1;
}

static void bind_span(sqlite3_stmt *st, int i, const uint8_t *bytes, size_t len) {
    if (len == 0) sqlite3_bind_null(st, i);
    else sqlite3_bind_text(st, i, (const char *)bytes, (int)len, SQLITE_TRANSIENT);
}

/* ---- serializing rows ------------------------------------------------- */

struct out_buf {
    uint8_t *p;
    size_t cap, len;
    int full;
};

static void put(struct out_buf *o, const void *bytes, size_t n) {
    if (o->full || o->len + n > o->cap) {
        o->full = 1;
        return;
    }
    memcpy(o->p + o->len, bytes, n);
    o->len += n;
}

static void put_byte(struct out_buf *o, uint8_t b) { put(o, &b, 1); }

/* Text with the separators blanked, cut at `limit` bytes on a UTF-8 boundary. */
static int put_text(struct out_buf *o, const unsigned char *s, size_t n, size_t limit) {
    int cut = 0;
    if (n > limit) {
        n = limit;
        while (n > 0 && (s[n] & 0xc0) == 0x80) n--;
        cut = 1;
    }
    for (size_t i = 0; i < n; i++) put_byte(o, (s[i] == RS || s[i] == US) ? ' ' : s[i]);
    return cut;
}

static void put_col_text(struct out_buf *o, sqlite3_stmt *st, int col) {
    const unsigned char *s = sqlite3_column_text(st, col);
    if (s != NULL) put_text(o, s, (size_t)sqlite3_column_bytes(st, col), (size_t)-1);
    put_byte(o, US);
}

static void put_col_num(struct out_buf *o, sqlite3_stmt *st, int col) {
    char num[48];
    int n = 0;
    if (sqlite3_column_type(st, col) != SQLITE_NULL) n = snprintf(num, sizeof num, "%.6f", sqlite3_column_double(st, col));
    put(o, num, (size_t)(n > 0 ? n : 0));
    put_byte(o, US);
}

/* id US text US kind US created US source US pinned US w US h US bytes US
 * content_kind US content_detail US image_hash US truncated RS */
static void put_row(struct out_buf *o, sqlite3_stmt *st) {
    put_col_text(o, st, 0);
    const unsigned char *text = sqlite3_column_text(st, 1);
    int cut = text != NULL ? put_text(o, text, (size_t)sqlite3_column_bytes(st, 1), PREVIEW_BYTES) : 0;
    put_byte(o, US);
    put_col_text(o, st, 2);
    for (int c = 3; c <= 3; c++) put_col_num(o, st, c);
    put_col_text(o, st, 4);
    for (int c = 5; c <= 8; c++) put_col_num(o, st, c);
    for (int c = 9; c <= 11; c++) put_col_text(o, st, c);
    put_byte(o, cut ? '1' : '0');
    put_byte(o, RS);
}

static int32_t run_list(sqlite3_stmt *st, uint8_t *out, size_t cap) {
    struct out_buf o = {out, cap, 0, 0};
    while (sqlite3_step(st) == SQLITE_ROW) put_row(&o, st);
    sqlite3_finalize(st);
    return o.full ? -1 : (int32_t)o.len;
}

/* Pinned entries first, then the newest: every pinned entry plus `limit`
 * recent ones for the empty query, or `limit` matches for a filter. -1
 * when `out` is too small; the caller grows it and asks again. */
int32_t flc_list(const uint8_t *query, size_t qlen, int32_t limit, uint8_t *out, size_t cap) {
    if (db == NULL) return 0;
    sqlite3_stmt *st = NULL;
    const char *sql;
    if (qlen == 0) {
        sql = "SELECT " COLUMNS " FROM clipboard_entries WHERE pinned_at IS NOT NULL ORDER BY pinned_at ASC;";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
        struct out_buf o = {out, cap, 0, 0};
        while (sqlite3_step(st) == SQLITE_ROW) put_row(&o, st);
        sqlite3_finalize(st);
        sql = "SELECT " COLUMNS " FROM clipboard_entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT ?;";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return o.full ? -1 : (int32_t)o.len;
        sqlite3_bind_int(st, 1, limit);
        while (sqlite3_step(st) == SQLITE_ROW) put_row(&o, st);
        sqlite3_finalize(st);
        return o.full ? -1 : (int32_t)o.len;
    }
    /* The trigram index needs three bytes; a shorter query scans. */
    if (qlen >= 3) {
        sql = "SELECT " COLUMNS " FROM clipboard_entries WHERE rowid IN"
              " (SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?)"
              " ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC LIMIT ?;";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
        /* One quoted phrase, so the query's own punctuation is not syntax. */
        size_t cap_q = qlen * 2 + 3;
        char *phrase = malloc(cap_q);
        if (phrase == NULL) {
            sqlite3_finalize(st);
            return 0;
        }
        size_t n = 0;
        phrase[n++] = '"';
        for (size_t i = 0; i < qlen; i++) {
            if (query[i] == '"') phrase[n++] = '"';
            phrase[n++] = (char)query[i];
        }
        phrase[n++] = '"';
        sqlite3_bind_text(st, 1, phrase, (int)n, SQLITE_TRANSIENT);
        free(phrase);
    } else {
        sql = "SELECT " COLUMNS " FROM clipboard_entries WHERE instr(lower(" FTS_TEXT("clipboard_entries")
              "), lower(?)) > 0 ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC LIMIT ?;";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
        bind_span(st, 1, query, qlen);
    }
    sqlite3_bind_int(st, 2, limit);
    return run_list(st, out, cap);
}

/* The newest entry, pinned or not, in the list's record form. */
int32_t flc_newest(uint8_t *out, size_t cap) {
    if (db == NULL) return 0;
    sqlite3_stmt *st = NULL;
    const char *sql = "SELECT " COLUMNS " FROM clipboard_entries ORDER BY created_at DESC LIMIT 1;";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    return run_list(st, out, cap);
}

/* One entry by id, in the list's record form; 0 bytes when it is gone. */
int32_t flc_entry(const uint8_t *id, size_t id_len, uint8_t *out, size_t cap) {
    if (db == NULL) return 0;
    sqlite3_stmt *st = NULL;
    const char *sql = "SELECT " COLUMNS " FROM clipboard_entries WHERE id = ?;";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    bind_span(st, 1, id, id_len);
    return run_list(st, out, cap);
}

static int32_t step_done(sqlite3_stmt *st) {
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? sqlite3_changes(db) : -1;
}

int32_t flc_record(const uint8_t *id, size_t id_len, const uint8_t *text, size_t text_len, const uint8_t *kind,
                   size_t kind_len, double created, const uint8_t *source, size_t source_len,
                   const uint8_t *content_kind, size_t ck_len, const uint8_t *content_detail, size_t cd_len) {
    if (db == NULL) return -1;
    sqlite3_stmt *st = NULL;
    const char *sql =
        "INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at,"
        " content_kind, content_detail) VALUES (?, ?, ?, ?, ?, NULL, ?, ?);";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    bind_span(st, 1, id, id_len);
    sqlite3_bind_text(st, 2, (const char *)text, (int)text_len, SQLITE_TRANSIENT);
    bind_span(st, 3, kind, kind_len);
    sqlite3_bind_double(st, 4, created);
    bind_span(st, 5, source, source_len);
    bind_span(st, 6, content_kind, ck_len);
    bind_span(st, 7, content_detail, cd_len);
    return step_done(st);
}

/* The two calls that touch the pasteboard, built only into the capture
 * agent's copy of this file (FLCLIP_PASTEBOARD): the TUI links no AppKit. */
#if defined(FLCLIP_PASTEBOARD)
static void bind_blob(sqlite3_stmt *st, int i, const uint8_t *bytes, size_t len) {
    if (bytes == NULL || len == 0) sqlite3_bind_null(st, i);
    else sqlite3_bind_blob(st, i, bytes, (int)len, SQLITE_TRANSIENT);
}

/* Records the image the native layer is holding from its last capture. */
int32_t flc_record_image(const uint8_t *id, size_t id_len, double created, const uint8_t *source, size_t source_len,
                         const uint8_t *hash, size_t hash_len, int32_t width, int32_t height, int32_t bytes) {
    if (db == NULL) return -1;
    const uint8_t *png = NULL, *tiff = NULL, *thumb = NULL;
    size_t png_len = flm_pending_png(&png);
    size_t tiff_len = flm_pending_tiff(&tiff);
    size_t thumb_len = flm_pending_thumbnail(&thumb);
    if (png_len == 0 && tiff_len == 0) return -1;
    sqlite3_stmt *st = NULL;
    const char *sql =
        "INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at,"
        " image_hash, image_width, image_height, image_byte_count, thumbnail_png, png_data, tiff_data)"
        " VALUES (?, '', 'image', ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?);";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    bind_span(st, 1, id, id_len);
    sqlite3_bind_double(st, 2, created);
    bind_span(st, 3, source, source_len);
    bind_span(st, 4, hash, hash_len);
    sqlite3_bind_int(st, 5, width);
    sqlite3_bind_int(st, 6, height);
    sqlite3_bind_int(st, 7, bytes);
    bind_blob(st, 8, thumb, thumb_len);
    bind_blob(st, 9, png, png_len);
    bind_blob(st, 10, tiff, tiff_len);
    return step_done(st);
}
#endif

int32_t flc_set_pinned(const uint8_t *id, size_t id_len, int32_t pinned, double now) {
    if (db == NULL) return -1;
    sqlite3_stmt *st = NULL;
    const char *sql = pinned ? "UPDATE clipboard_entries SET pinned_at = ? WHERE id = ?;"
                             : "UPDATE clipboard_entries SET pinned_at = NULL WHERE id = ?;";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    if (pinned) {
        sqlite3_bind_double(st, 1, now);
        bind_span(st, 2, id, id_len);
    } else {
        bind_span(st, 1, id, id_len);
    }
    return step_done(st);
}

int32_t flc_delete(const uint8_t *id, size_t id_len) {
    if (db == NULL) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM clipboard_entries WHERE id = ?;", -1, &st, NULL) != SQLITE_OK) return -1;
    bind_span(st, 1, id, id_len);
    return step_done(st);
}

int32_t flc_prune(double cutoff) {
    if (db == NULL) return -1;
    sqlite3_stmt *st = NULL;
    const char *sql = "DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?;";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_double(st, 1, cutoff);
    return step_done(st);
}

/* The entry's whole text; -(bytes needed) when `out` is too small. */
int32_t flc_text(const uint8_t *id, size_t id_len, uint8_t *out, size_t cap) {
    if (db == NULL) return 0;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT text FROM clipboard_entries WHERE id = ?;", -1, &st, NULL) != SQLITE_OK) return 0;
    bind_span(st, 1, id, id_len);
    int32_t result = 0;
    if (sqlite3_step(st) == SQLITE_ROW) {
        int n = sqlite3_column_bytes(st, 0);
        if ((size_t)n > cap) {
            result = -n;
        } else {
            memcpy(out, sqlite3_column_text(st, 0), (size_t)n);
            result = n;
        }
    }
    sqlite3_finalize(st);
    return result;
}

/* Hands an image entry's original data to `use`, which runs before the
 * statement that owns the blobs is finalized. */
static int32_t with_image(const uint8_t *id, size_t id_len, int32_t (*use)(const uint8_t *, size_t, const uint8_t *, size_t, void *),
                          void *ctx) {
    if (db == NULL) return -1;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT png_data, tiff_data FROM clipboard_entries WHERE id = ?;", -1, &st, NULL) !=
        SQLITE_OK)
        return -1;
    bind_span(st, 1, id, id_len);
    int32_t rc = -1;
    if (sqlite3_step(st) == SQLITE_ROW) {
        rc = use(sqlite3_column_blob(st, 0), (size_t)sqlite3_column_bytes(st, 0), sqlite3_column_blob(st, 1),
                 (size_t)sqlite3_column_bytes(st, 1), ctx);
    }
    sqlite3_finalize(st);
    return rc;
}


static int32_t write_file(const uint8_t *png, size_t png_len, const uint8_t *tiff, size_t tiff_len, void *ctx) {
    const uint8_t *bytes = png_len > 0 ? png : tiff;
    size_t len = png_len > 0 ? png_len : tiff_len;
    if (len == 0) return -1;
    FILE *f = fopen((const char *)ctx, "wb");
    if (f == NULL) return -1;
    size_t wrote = fwrite(bytes, 1, len, f);
    fclose(f);
    return wrote == len ? 1 : -1;
}

#if defined(FLCLIP_PASTEBOARD)
static int32_t write_pasteboard(const uint8_t *png, size_t png_len, const uint8_t *tiff, size_t tiff_len, void *ctx) {
    (void)ctx;
    return flm_write_image(png, png_len, tiff, tiff_len);
}

int32_t flc_copy_image(const uint8_t *id, size_t id_len) { return with_image(id, id_len, write_pasteboard, NULL); }
#endif

/* Writes an image entry to `path` (PNG when there is one) for Quick Look. */
int32_t flc_export_image(const uint8_t *id, size_t id_len, const uint8_t *path, size_t path_len) {
    char p[4096];
    if (span_cstr(path, path_len, p, sizeof p) != 0) return -1;
    return with_image(id, id_len, write_file, p);
}
