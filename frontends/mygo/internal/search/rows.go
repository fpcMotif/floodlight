package search

import (
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
)

// MaxRows caps one publication, the web row included, as #112 and the
// nanoui port do. A launcher shows about ten; more only costs stat calls.
const MaxRows = 80

// The recognizer rows name their own answer, so they sit above anything a
// fuzzy match can score. The order among them is the Swift app's.
const (
	scoreDirectLink = 160_000
	scoreKeyword    = 150_000
	scoreCalculator = 100_000
)

// settingBonus puts a System Settings pane between an app and a file that
// match equally: a setting is a destination, like an app, but the user asked
// for the app by name more often than for the pane.
const settingBonus = 30

// Kind tells what a row is and so which badge and chip it gets.
type Kind uint8

const (
	KindApp Kind = iota
	KindFile
	KindFolder
	KindWeb
	KindCalculator
	KindSetting
)

// Label is the row's kind badge, the Swift SearchItemKind label.
func (k Kind) Label() string {
	return [...]string{"Application", "File", "Folder", "Web", "Calculator", "System Setting"}[k]
}

// Row is one result as the panel shows it.
type Row struct {
	ID       string
	Kind     Kind
	Title    string
	Subtitle string
	// Path is what Return opens: an absolute file path, or a URL.
	Path string
	// Copy, when set, is what Return copies instead of opening anything:
	// a calculator or conversion answer.
	Copy     string
	Size     int64 // bytes; -1 when not a file or unknown
	Modified time.Time
	Score    int
}

// IsFile reports whether the row is on disk, so ⌘Return and Quick Look
// apply to it.
func (r Row) IsFile() bool { return r.Kind == KindApp || r.Kind == KindFile || r.Kind == KindFolder }

// Filter is a chip over the result list.
type Filter uint8

const (
	FilterAll Filter = iota
	FilterApps
	FilterFiles
	FilterFolders
	FilterPDFs
	FilterImages
	numFilters
)

// Filters lists the chips in the order the bar shows them.
var Filters = [numFilters]Filter{FilterAll, FilterApps, FilterFiles, FilterFolders, FilterPDFs, FilterImages}

// Title is the chip's label.
func (f Filter) Title() string {
	return [...]string{"All", "Apps", "Files", "Folders", "PDFs", "Images"}[f]
}

var imageExts = map[string]bool{"png": true, "jpg": true, "jpeg": true, "heic": true, "webp": true, "gif": true, "tiff": true, "tif": true, "bmp": true, "avif": true, "svg": true}

// Includes reports whether r belongs under the chip. The web row belongs
// to none of them: it is appended after whatever the chip keeps.
func (f Filter) Includes(r Row) bool {
	if r.ID == WebRowID {
		return false
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(r.Title), "."))
	switch f {
	case FilterApps:
		return r.Kind == KindApp
	case FilterFiles:
		return r.Kind == KindFile
	case FilterFolders:
		return r.Kind == KindFolder
	case FilterPDFs:
		return r.Kind == KindFile && ext == "pdf"
	case FilterImages:
		return r.Kind == KindFile && imageExts[ext]
	}
	return true
}

// Counts holds each chip's row count.
type Counts [numFilters]int

// WebRowID marks the fallback row, which is always last.
const WebRowID = "web-search"

// Publication is the immutable answer to one query (ADR 0002): the rows,
// best first, with the web row last, and the chip counts from the same rows.
type Publication struct {
	Rows   []Row
	Counts Counts
}

// TopHit is the best row, or false when only the web row is left.
func (p Publication) TopHit() (Row, bool) {
	if len(p.Rows) == 0 || p.Rows[0].ID == WebRowID {
		return Row{}, false
	}
	return p.Rows[0], true
}

// Visible is what the list shows under f: the chip's rows, then the web row.
func (p Publication) Visible(f Filter) []Row {
	if f == FilterAll {
		return p.Rows
	}
	var out []Row
	for _, r := range p.Rows {
		if f.Includes(r) || r.ID == WebRowID {
			out = append(out, r)
		}
	}
	return out
}

// Catalog is what a query runs against. It is not safe for concurrent use:
// the engine goroutine owns one.
type Catalog struct {
	Index *core.Index
	Root  string
	Home  string // shown as ~ in subtitles
	Apps  []apps.App

	hits [MaxRows]core.Hit
}

// Publish answers q in mode. stale, if not nil, is asked between the slow
// steps; a true answer abandons the query and Publish reports false.
func (c *Catalog) Publish(q string, mode query.Mode, stale func() bool) (Publication, bool) {
	if stale == nil {
		stale = func() bool { return false }
	}
	text := strings.TrimSpace(q)
	var rows []Row
	switch {
	case text == "" || mode.Kind == query.Clipboard:
	case mode.Kind == query.Web:
		rows = webModeRows(text, mode.EngineID)
	default:
		var ok bool
		if rows, ok = c.localRows(text, stale); !ok {
			return Publication{}, false
		}
	}
	p := Publication{Rows: rows}
	for _, r := range rows {
		for _, f := range Filters {
			if f.Includes(r) {
				p.Counts[f]++
			}
		}
	}
	return p, true
}

func (c *Catalog) localRows(q string, stale func() bool) ([]Row, bool) {
	var rows []Row
	if l, ok := query.Link(q); ok {
		rows = append(rows, Row{ID: "direct-link", Kind: KindWeb, Title: l.Host, Subtitle: l.URL, Path: l.URL, Size: -1, Score: scoreDirectLink})
	}
	if v, ok := query.Evaluate(q); ok {
		answer := query.FormatNumber(v)
		rows = append(rows, Row{ID: "calculator", Kind: KindCalculator, Title: answer, Subtitle: q + " = " + answer + " · Press Return to copy", Copy: answer, Size: -1, Score: scoreCalculator})
	} else if answer, ok := query.Convert(q); ok {
		rows = append(rows, Row{ID: "conversion", Kind: KindCalculator, Title: answer, Subtitle: q + " = " + answer + " · Press Return to copy", Copy: answer, Size: -1, Score: scoreCalculator})
	}
	if e, rest, ok := query.Addressed(q); ok {
		rows = append(rows, Row{ID: "keyword-engine:" + e.ID, Kind: KindWeb, Title: e.Name, Subtitle: e.Host(), Path: e.URL(rest), Size: -1, Score: scoreKeyword})
	}
	matched := apps.Match(c.Apps, q, MaxRows)
	appPaths := make(map[string]bool, len(matched))
	for _, a := range matched {
		appPaths[a.Path] = true
		rows = append(rows, Row{ID: "app:" + a.Path, Kind: KindApp, Title: a.Name, Subtitle: c.abbrev(filepath.Dir(a.Path)), Path: a.Path, Size: -1, Score: a.Score})
	}
	for _, s := range query.MatchSettings(q, 6) {
		rows = append(rows, Row{ID: "setting:" + s.Pane, Kind: KindSetting, Title: s.Name, Subtitle: s.Subtitle, Path: s.URL(), Size: -1, Score: s.Score + settingBonus})
	}
	if stale() {
		return nil, false
	}
	hits := c.Index.Search(q, c.hits[:])
	// The C search is the slow step and cannot be interrupted; skip the path
	// rebuilds if the user typed again while it ran.
	if stale() {
		return nil, false
	}
	for _, h := range hits {
		rel, err := c.Index.RelativePath(h.ID)
		if err != nil {
			continue
		}
		// A bundle's insides match by path but are never what a launcher
		// user wants; Spotlight hides them too.
		if strings.Contains(rel, ".app/") {
			continue
		}
		abs := filepath.Join(c.Root, rel)
		// An app under the indexed root, ~/Applications say, is also a
		// folder hit; the app row already stands for it.
		if appPaths[abs] || strings.HasSuffix(rel, ".app") && slices.ContainsFunc(c.Apps, func(a apps.App) bool { return a.Path == abs }) {
			continue
		}
		kind := KindFile
		if c.Index.IsDir(h.ID) {
			kind = KindFolder
		}
		rows = append(rows, Row{ID: "file:" + abs, Kind: kind, Title: filepath.Base(rel), Subtitle: c.abbrev(filepath.Dir(abs)), Path: abs, Size: -1, Score: int(h.Score)})
	}
	slices.SortStableFunc(rows, func(a, b Row) int {
		return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(len(a.Title), len(b.Title)), cmp.Compare(a.Title, b.Title), cmp.Compare(a.ID, b.ID))
	})
	rows = rows[:min(len(rows), MaxRows-1)]
	for i := range rows {
		if rows[i].Kind == KindFile || rows[i].Kind == KindFolder {
			stamp(&rows[i])
		}
	}
	e := query.DefaultEngine
	return append(rows, Row{ID: WebRowID, Kind: KindWeb, Title: e.Name, Subtitle: e.Host(), Path: e.URL(q), Size: -1}), true
}

// webModeRows lists every engine for q, the active one first, as the Swift
// webModeResults does.
func webModeRows(q, active string) []Row {
	var rows []Row
	add := func(e query.Engine) {
		rows = append(rows, Row{ID: "web-mode:" + e.ID, Kind: KindWeb, Title: e.Name, Subtitle: e.Host(), Path: e.URL(q), Size: -1})
	}
	for _, e := range query.Engines {
		if e.ID == active {
			add(e)
		}
	}
	for _, e := range query.Engines {
		if e.ID != active {
			add(e)
		}
	}
	return rows
}

// stamp fills a file row's size and modified date. A folder has no size
// worth showing; Finder computes one by walking it.
func stamp(r *Row) {
	st, err := os.Stat(r.Path)
	if err != nil {
		return
	}
	r.Modified = st.ModTime()
	if r.Kind == KindFile {
		r.Size = st.Size()
	}
}

func (c *Catalog) abbrev(path string) string {
	if c.Home != "" && (path == c.Home || strings.HasPrefix(path, c.Home+"/")) {
		return "~" + path[len(c.Home):]
	}
	return path
}
