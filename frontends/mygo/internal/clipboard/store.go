package clipboard

/*
#cgo LDFLAGS: -lsqlite3
#include <sqlite3.h>
#include <stdlib.h>

// SQLITE_TRANSIENT is a cast of -1 to a function pointer, which cgo cannot
// spell; these wrappers make SQLite copy what it is handed.
static int fl_bind_text(sqlite3_stmt *s, int i, const char *p, int n) {
	return sqlite3_bind_text(s, i, p, n, SQLITE_TRANSIENT);
}
static int fl_bind_blob(sqlite3_stmt *s, int i, const void *p, int n) {
	return sqlite3_bind_blob(s, i, p, n, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unsafe"
)

// List limits: the board shows the newest window, or this many matches.
const (
	ListWindow  = 1000
	SearchLimit = 200
)

// schema is the Swift app's (ClipboardHistorySQLite), columns, trigram
// full-text table and triggers alike, so this store can read the Swift
// app's history and the Swift app can read this one's.
const schema = `
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
);`

var addedColumns = []string{
	"image_hash TEXT", "image_width INTEGER", "image_height INTEGER", "image_byte_count INTEGER",
	"thumbnail_png BLOB", "png_data BLOB", "tiff_data BLOB", "content_kind TEXT", "content_detail TEXT",
}

// ftsText is what the trigram index holds for a row: an image is also
// found by its size.
const ftsText = `CASE WHEN %[1]s.kind = 'image' AND %[1]s.image_width IS NOT NULL
	THEN %[1]s.text || ' ' || %[1]s.image_width || '×' || %[1]s.image_height ELSE %[1]s.text END`

var triggers = fmt.Sprintf(`
DROP TRIGGER IF EXISTS clipboard_entries_ai;
DROP TRIGGER IF EXISTS clipboard_entries_ad;
DROP TRIGGER IF EXISTS clipboard_entries_au;
CREATE TRIGGER clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
    INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, %[1]s);
END;
CREATE TRIGGER clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
    INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES ('delete', old.rowid, %[2]s);
END;
CREATE TRIGGER clipboard_entries_au AFTER UPDATE OF text, kind, image_width, image_height ON clipboard_entries BEGIN
    INSERT INTO clipboard_fts(clipboard_fts, rowid, text) VALUES ('delete', old.rowid, %[2]s);
    INSERT INTO clipboard_fts(rowid, text) VALUES (new.rowid, %[1]s);
END;`, fmt.Sprintf(ftsText, "new"), fmt.Sprintf(ftsText, "old"))

const columns = `id, text, created_at, source_app_bundle_id, pinned_at, kind,
	image_hash, image_width, image_height, image_byte_count, thumbnail_png, content_kind, content_detail`

// boardOrder is pinned first, by when they were pinned, then the newest.
const boardOrder = ` ORDER BY pinned_at IS NOT NULL DESC, pinned_at ASC, created_at DESC`

// Store is the clipboard history in SQLite. Its methods are safe for
// concurrent use: the capture goroutine writes while the board reads.
type Store struct {
	mu sync.Mutex
	db *C.sqlite3
	// InMemory is true when the file could not open and history lives only
	// until the app quits.
	InMemory bool
}

// Open opens or creates the store at path. On failure it falls back to an
// in-memory database, so a damaged file never costs the user the board.
func Open(path string) (*Store, error) {
	s, err := open(path)
	if err == nil {
		return s, nil
	}
	m, merr := open(":memory:")
	if merr != nil {
		return nil, errors.Join(err, merr)
	}
	m.InMemory = true
	return m, err
}

func open(path string) (*Store, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var db *C.sqlite3
	flags := C.SQLITE_OPEN_READWRITE | C.SQLITE_OPEN_CREATE | C.SQLITE_OPEN_FULLMUTEX
	if rc := C.sqlite3_open_v2(cpath, &db, C.int(flags), nil); rc != C.SQLITE_OK {
		C.sqlite3_close_v2(db)
		return nil, fmt.Errorf("clipboard: open %s: sqlite %d", path, int(rc))
	}
	C.sqlite3_busy_timeout(db, 2000)
	s := &Store{db: db}
	if err := s.exec(schema); err != nil {
		s.Close()
		return nil, err
	}
	for _, col := range addedColumns {
		err := s.exec("ALTER TABLE clipboard_entries ADD COLUMN " + col)
		if err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			s.Close()
			return nil, err
		}
	}
	if err := s.exec(triggers); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the database.
func (s *Store) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		C.sqlite3_close_v2(s.db)
		s.db = nil
	}
}

func (s *Store) exec(sql string) error {
	csql := C.CString(sql)
	defer C.free(unsafe.Pointer(csql))
	var msg *C.char
	if rc := C.sqlite3_exec(s.db, csql, nil, nil, &msg); rc != C.SQLITE_OK {
		err := fmt.Errorf("clipboard: sqlite %d: %s", int(rc), C.GoString(msg))
		C.sqlite3_free(unsafe.Pointer(msg))
		return err
	}
	return nil
}

type stmt struct {
	s  *C.sqlite3_stmt
	db *C.sqlite3
}

func (s *Store) prepare(sql string, args ...any) (*stmt, error) {
	csql := C.CString(sql)
	defer C.free(unsafe.Pointer(csql))
	var st *C.sqlite3_stmt
	if rc := C.sqlite3_prepare_v2(s.db, csql, -1, &st, nil); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("clipboard: prepare: %s", C.GoString(C.sqlite3_errmsg(s.db)))
	}
	for i, a := range args {
		n := C.int(i + 1)
		switch v := a.(type) {
		case nil:
			C.sqlite3_bind_null(st, n)
		case string:
			cs := C.CString(v)
			C.fl_bind_text(st, n, cs, C.int(len(v)))
			C.free(unsafe.Pointer(cs))
		case []byte:
			if v == nil {
				C.sqlite3_bind_null(st, n)
			} else if len(v) == 0 {
				C.sqlite3_bind_zeroblob(st, n, 0)
			} else {
				C.fl_bind_blob(st, n, unsafe.Pointer(&v[0]), C.int(len(v)))
			}
		case float64:
			C.sqlite3_bind_double(st, n, C.double(v))
		case int:
			C.sqlite3_bind_int64(st, n, C.sqlite3_int64(v))
		default:
			C.sqlite3_finalize(st)
			return nil, fmt.Errorf("clipboard: cannot bind %T", a)
		}
	}
	return &stmt{st, s.db}, nil
}

func (st *stmt) step() (bool, error) {
	switch rc := C.sqlite3_step(st.s); rc {
	case C.SQLITE_ROW:
		return true, nil
	case C.SQLITE_DONE:
		return false, nil
	default:
		return false, fmt.Errorf("clipboard: step: %s", C.GoString(C.sqlite3_errmsg(st.db)))
	}
}

func (st *stmt) close() { C.sqlite3_finalize(st.s) }

func (st *stmt) null(i int) bool { return C.sqlite3_column_type(st.s, C.int(i)) == C.SQLITE_NULL }

func (st *stmt) text(i int) string {
	p := C.sqlite3_column_text(st.s, C.int(i))
	if p == nil {
		return ""
	}
	return C.GoStringN((*C.char)(unsafe.Pointer(p)), C.sqlite3_column_bytes(st.s, C.int(i)))
}

func (st *stmt) blob(i int) []byte {
	p := C.sqlite3_column_blob(st.s, C.int(i))
	if p == nil {
		return nil
	}
	return C.GoBytes(p, C.sqlite3_column_bytes(st.s, C.int(i)))
}

func (st *stmt) float(i int) float64 { return float64(C.sqlite3_column_double(st.s, C.int(i))) }
func (st *stmt) int(i int) int       { return int(C.sqlite3_column_int64(st.s, C.int(i))) }

func (s *Store) run(sql string, args ...any) error {
	st, err := s.prepare(sql, args...)
	if err != nil {
		return err
	}
	defer st.close()
	_, err = st.step()
	return err
}

func (s *Store) query(sql string, args ...any) ([]Entry, error) {
	st, err := s.prepare(sql, args...)
	if err != nil {
		return nil, err
	}
	defer st.close()
	var out []Entry
	for {
		ok, err := st.step()
		if err != nil || !ok {
			return out, err
		}
		e := Entry{
			ID: st.text(0), Text: st.text(1), CreatedAt: st.float(2), SourceID: st.text(3), Kind: Kind(st.text(5)),
			ImageHash: st.text(6), Width: st.int(7), Height: st.int(8), ByteCount: st.int(9), Thumbnail: st.blob(10),
		}
		if !st.null(4) {
			p := st.float(4)
			e.PinnedAt = &p
		}
		if e.Kind == KindText {
			// A row the Swift app wrote before it stored a classification
			// is classified on read, as the Swift store does.
			if st.null(11) {
				e.Class = Classify(e.Text)
			} else {
				e.Class = Classification{Content(st.text(11)), st.text(12)}
			}
		}
		out = append(out, e)
	}
}

// Newest is the most recent entry, pinned or not, or nil.
func (s *Store) Newest() *Entry {
	s.mu.Lock()
	defer s.mu.Unlock()
	got, err := s.query("SELECT " + columns + " FROM clipboard_entries ORDER BY created_at DESC LIMIT 1")
	if err != nil || len(got) == 0 {
		return nil
	}
	return &got[0]
}

// Record stores caps, copied from source at now, and returns the entries.
func (s *Store) Record(caps []Capture, source string, now float64) ([]Entry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Entry
	for _, c := range caps {
		e := Entry{ID: newID(), Kind: c.Kind, Text: c.Text, CreatedAt: now, SourceID: source}
		var err error
		switch c.Kind {
		case KindImage:
			img := c.Image
			e.ImageHash, e.Width, e.Height, e.ByteCount, e.Thumbnail = ImageHash(img.PNG), img.Width, img.Height, len(img.PNG), img.Thumbnail
			err = s.run(`INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at,
				image_hash, image_width, image_height, image_byte_count, thumbnail_png, png_data)
				VALUES (?, ?, 'image', ?, ?, NULL, ?, ?, ?, ?, ?, ?)`,
				e.ID, e.Text, now, nullable(source), e.ImageHash, e.Width, e.Height, e.ByteCount, img.Thumbnail, img.PNG)
		case KindText:
			e.Class = Classify(c.Text)
			err = s.run(`INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at, content_kind, content_detail)
				VALUES (?, ?, 'text', ?, ?, NULL, ?, ?)`, e.ID, e.Text, now, nullable(source), string(e.Class.Content), nullable(e.Class.Detail))
		default:
			err = s.run(`INSERT INTO clipboard_entries (id, text, kind, created_at, source_app_bundle_id, pinned_at)
				VALUES (?, ?, ?, ?, ?, NULL)`, e.ID, e.Text, string(c.Kind), now, nullable(source))
		}
		if err != nil {
			return out, err
		}
		out = append(out, e)
	}
	return out, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// List is what the board shows for q: with no query, every pinned entry
// and the ListWindow newest; with one, up to SearchLimit entries matching
// every term, pinned first either way.
func (s *Store) List(q string) ([]Entry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	terms := strings.Fields(q)
	if len(terms) == 0 {
		return s.query(fmt.Sprintf(`SELECT %s FROM clipboard_entries WHERE pinned_at IS NOT NULL
			OR rowid IN (SELECT rowid FROM clipboard_entries WHERE pinned_at IS NULL ORDER BY created_at DESC LIMIT %d)%s`,
			columns, ListWindow, boardOrder))
	}
	// The trigram index cannot answer a term under three bytes; those
	// queries scan instead, case-folded, as the Swift store does.
	short := false
	for _, t := range terms {
		short = short || len(t) < 3
	}
	if !short {
		var quoted []string
		for _, t := range terms {
			quoted = append(quoted, `"`+strings.ReplaceAll(t, `"`, `""`)+`"`)
		}
		got, err := s.query(fmt.Sprintf(`SELECT %s FROM clipboard_entries WHERE rowid IN
			(SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?)%s LIMIT %d`, columns, boardOrder, SearchLimit),
			strings.Join(quoted, " "))
		if err == nil {
			return got, nil
		}
	}
	var where []string
	var args []any
	for _, t := range terms {
		where = append(where, "instr(lower("+fmt.Sprintf(ftsText, "clipboard_entries")+"), lower(?)) > 0")
		args = append(args, t)
	}
	return s.query(fmt.Sprintf("SELECT %s FROM clipboard_entries WHERE %s%s LIMIT %d", columns, strings.Join(where, " AND "), boardOrder, SearchLimit), args...)
}

// ImagePNG is an image entry's full picture, read only when shown.
func (s *Store) ImagePNG(id string) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := s.prepare("SELECT png_data FROM clipboard_entries WHERE id = ?", id)
	if err != nil {
		return nil
	}
	defer st.close()
	if ok, _ := st.step(); !ok {
		return nil
	}
	return st.blob(0)
}

// TogglePin pins an unpinned entry at now, or unpins a pinned one.
func (s *Store) TogglePin(id string, now float64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.run("UPDATE clipboard_entries SET pinned_at = CASE WHEN pinned_at IS NULL THEN ? ELSE NULL END WHERE id = ?", now, id)
}

// Delete removes an entry.
func (s *Store) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.run("DELETE FROM clipboard_entries WHERE id = ?", id)
}

// Prune drops unpinned entries older than days; pinned ones stay.
func (s *Store) Prune(now float64, days int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.run("DELETE FROM clipboard_entries WHERE pinned_at IS NULL AND created_at < ?", now-float64(days)*86400)
}

// newID is an uppercase UUID v4, the form Swift's UUID().uuidString takes.
func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
