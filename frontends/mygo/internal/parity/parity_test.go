// Package parity runs the repository's shared parity fixtures
// (fixtures/parity) against the MyGo frontend's domain modules. The same
// files are what every other frontend's runner reads, so "full port" is a
// test result, not an opinion.
package parity

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

func load(t *testing.T, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "fixtures", "parity", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

var kindNames = map[search.Kind]string{
	search.KindApp: "app", search.KindFile: "file", search.KindFolder: "folder",
	search.KindWeb: "web", search.KindCalculator: "calculator", search.KindSetting: "setting",
}

var filterNames = map[string]search.Filter{
	"all": search.FilterAll, "apps": search.FilterApps, "files": search.FilterFiles,
	"folders": search.FilterFolders, "pdfs": search.FilterPDFs, "images": search.FilterImages,
}

type wantRow struct {
	Kind, Title, Subtitle, URL, Copy string
}

func parseMode(s, typed, entry string) query.Mode {
	switch {
	case s == "clipboard":
		return query.Mode{Kind: query.Clipboard, TypedKeyword: typed, QueryAtEntry: entry}
	case strings.HasPrefix(s, "web:"):
		return query.Mode{Kind: query.Web, EngineID: strings.TrimPrefix(s, "web:"), TypedKeyword: typed, QueryAtEntry: entry}
	}
	return query.Mode{}
}

func modeName(m query.Mode) string {
	switch m.Kind {
	case query.Web:
		return "web:" + m.EngineID
	case query.Clipboard:
		return "clipboard"
	}
	return "local"
}

func TestSearchParity(t *testing.T) {
	var fx struct {
		Files   []string
		Apps    []string
		Queries []struct {
			Query    string
			Mode     string
			Rows     []wantRow
			TopHit   *string `json:"top_hit"`
			Absent   []string
			Counts   map[string]int
			WebRow   *wantRow `json:"web_row"`
			NoWebRow bool     `json:"no_web_row"`
		}
		Modes []struct {
			From, Typed, Entry, Query, Event, To, Text string
		}
	}
	load(t, "search.json", &fx)

	root := t.TempDir()
	for _, f := range fx.Files {
		full := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	index := filepath.Join(t.TempDir(), "parity.flix")
	if _, err := core.Build(root, index); err != nil {
		t.Fatal(err)
	}
	ix, err := core.Open(index)
	if err != nil {
		t.Fatal(err)
	}
	defer ix.Close()
	var dirs []string
	for _, d := range fx.Apps {
		dirs = append(dirs, filepath.Join(root, d))
	}
	cat := &search.Catalog{Index: ix, Root: root, Home: root, Apps: apps.Scan(dirs)}

	for _, q := range fx.Queries {
		t.Run(q.Query, func(t *testing.T) {
			p, ok := cat.Publish(q.Query, parseMode(q.Mode, "", ""), nil)
			if !ok {
				t.Fatal("not published")
			}
			got := p.Rows
			var web *search.Row
			if n := len(got); n > 0 && got[n-1].ID == search.WebRowID {
				web, got = &got[n-1], got[:n-1]
			}
			dump := describe(p.Rows)
			if len(q.Rows) > len(got) || (len(q.Rows) == 0 && len(got) != 0) {
				t.Fatalf("rows:\n%s\nwant head %+v", dump, q.Rows)
			}
			for i, w := range q.Rows {
				g := got[i]
				if w.Kind != kindNames[g.Kind] || w.Title != g.Title ||
					w.Subtitle != "" && w.Subtitle != g.Subtitle || w.URL != "" && w.URL != g.Path || w.Copy != "" && w.Copy != g.Copy {
					t.Fatalf("row %d: want %+v\nrows:\n%s", i, w, dump)
				}
			}
			for _, a := range q.Absent {
				if slices.ContainsFunc(got, func(r search.Row) bool { return r.Title == a }) {
					t.Errorf("%q should be absent\nrows:\n%s", a, dump)
				}
			}
			if q.TopHit != nil {
				top, ok := p.TopHit()
				if !ok || top.Title != *q.TopHit {
					t.Errorf("top hit %q, want %q", top.Title, *q.TopHit)
				}
			}
			for name, n := range q.Counts {
				if p.Counts[filterNames[name]] != n {
					t.Errorf("%s count %d, want %d\nrows:\n%s", name, p.Counts[filterNames[name]], n, dump)
				}
			}
			switch {
			case q.NoWebRow && web != nil:
				t.Error("web mode published a fallback row")
			case !q.NoWebRow && q.Mode == "" && web == nil:
				t.Error("no web row last")
			case q.WebRow != nil && (web.Title != q.WebRow.Title || q.WebRow.URL != web.Path || q.WebRow.Subtitle != "" && q.WebRow.Subtitle != web.Subtitle):
				t.Errorf("web row %+v, want %+v", *web, *q.WebRow)
			}
		})
	}

	events := map[string]query.Event{
		"tab": query.Tab, "shift_tab": query.ShiftTab, "escape": query.Escape,
		"backspace_on_empty": query.BackspaceOnEmpty, "reset": query.Reset, "clipboard_shortcut": query.ClipboardShortcut,
	}
	for _, m := range fx.Modes {
		next, text := query.Transition(parseMode(m.From, m.Typed, m.Entry), m.Query, events[m.Event])
		if modeName(next) != m.To || text != m.Text {
			t.Errorf("%s %q %s → %s %q, want %s %q", m.From, m.Query, m.Event, modeName(next), text, m.To, m.Text)
		}
	}
}

func describe(rows []search.Row) string {
	var b strings.Builder
	for _, r := range rows {
		fmt.Fprintf(&b, "  %-10s %-24q %-40q %d\n", kindNames[r.Kind], r.Title, r.Subtitle, r.Score)
	}
	return b.String()
}

func TestClipboardParity(t *testing.T) {
	var fx struct {
		Home     string
		Now      float64
		Captures []struct {
			Name, Source, Text string
			Types              []string
			Files              []string
			TextRepeat         *struct {
				Text  string
				Count int
			} `json:"text_repeat"`
			Image *struct {
				Name                 string
				Width, Height, Bytes int
			}
			Expect struct {
				Skipped, Kind, Content, Detail, Title, Subtitle string
			}
		}
		Ages []struct {
			Seconds float64
			Age     string
		}
		Counts []struct {
			Text                     string
			Characters, Words, Lines int
		}
		List struct {
			First, Pin, Query   string
			Matches             []string
			PruneAfterDays      int      `json:"prune_after_days"`
			RemainingAfterPrune []string `json:"remaining_after_prune"`
		}
	}
	load(t, "clipboard.json", &fx)
	home := clipboard.Home
	clipboard.Home = func() string { return fx.Home }
	defer func() { clipboard.Home = home }()

	store, err := clipboard.Open(filepath.Join(t.TempDir(), "clipboard.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	name := func(id string) string { return clipboard.SourceName(id, nil) }
	ids := map[string]string{}
	for i, c := range fx.Captures {
		pb := clipboard.Pasteboard{Types: c.Types, Files: c.Files, Text: c.Text, Source: c.Source}
		if c.TextRepeat != nil {
			pb.Text = strings.Repeat(c.TextRepeat.Text, c.TextRepeat.Count)
		}
		if c.Image != nil {
			png := make([]byte, c.Image.Bytes)
			pb.Image = &clipboard.Image{Name: c.Image.Name, PNG: png, Width: c.Image.Width, Height: c.Image.Height}
		}
		// Each capture lands a second after the last, so list order is
		// capture order.
		now := fx.Now + float64(i)
		caps, skip := clipboard.Decide(pb, store.Newest())
		if c.Expect.Skipped != "" {
			if string(skip) != c.Expect.Skipped {
				t.Errorf("%s: skip %q, want %q", c.Name, skip, c.Expect.Skipped)
			}
			continue
		}
		if skip != clipboard.Recorded {
			t.Errorf("%s: skipped as %q", c.Name, skip)
			continue
		}
		es, err := store.Record(caps, pb.Source, now)
		if err != nil || len(es) != 1 {
			t.Fatalf("%s: recorded %d, %v", c.Name, len(es), err)
		}
		e, x := es[0], c.Expect
		ids[c.Name] = e.ID
		check := func(field, got, want string) {
			if want != "" && got != want {
				t.Errorf("%s: %s %q, want %q", c.Name, field, got, want)
			}
		}
		check("kind", string(e.Kind), x.Kind)
		check("content", string(e.Class.Content), x.Content)
		check("detail", e.Class.Detail, x.Detail)
		check("title", e.Title(), x.Title)
		check("subtitle", e.Subtitle(now, name), x.Subtitle)
	}
	for _, a := range fx.Ages {
		if got := clipboard.Age(a.Seconds); got != a.Age {
			t.Errorf("Age(%v) = %q, want %q", a.Seconds, got, a.Age)
		}
	}
	for _, c := range fx.Counts {
		if got := clipboard.CountText(c.Text); got != (clipboard.Counts{Characters: c.Characters, Words: c.Words, Lines: c.Lines}) {
			t.Errorf("CountText(%q) = %+v", c.Text, got)
		}
	}

	all, err := store.List("")
	if err != nil || len(all) == 0 || all[0].Title() != fx.List.First {
		t.Fatalf("list head %v, want %q (%v)", titles(all), fx.List.First, err)
	}
	if err := store.TogglePin(ids[fx.List.Pin], fx.Now+1000); err != nil {
		t.Fatal(err)
	}
	all, _ = store.List("")
	if !all[0].Pinned() || all[0].ID != ids[fx.List.Pin] {
		t.Fatalf("pinned entry not first: %v", titles(all))
	}
	found, err := store.List(fx.List.Query)
	if err != nil || !slices.Equal(titles(found), fx.List.Matches) {
		t.Fatalf("List(%q) = %v, want %v (%v)", fx.List.Query, titles(found), fx.List.Matches, err)
	}
	if err := store.Prune(fx.Now+float64(fx.List.PruneAfterDays)*86400, clipboard.RetentionDays); err != nil {
		t.Fatal(err)
	}
	left, _ := store.List("")
	if !slices.Equal(titles(left), fx.List.RemainingAfterPrune) {
		t.Fatalf("after prune %v, want %v", titles(left), fx.List.RemainingAfterPrune)
	}
}

func titles(es []clipboard.Entry) []string {
	var out []string
	for _, e := range es {
		out = append(out, e.Title())
	}
	return out
}

func TestBoardParity(t *testing.T) {
	var fx struct {
		Entries []struct{ Title, Kind, Text string }
		Cases   []struct {
			Keys     []string
			Query    string
			Actions  []*string
			Selected string
		}
		Menus []struct {
			Entry string
			Items []string
		}
	}
	load(t, "board.json", &fx)
	var entries []clipboard.Entry
	for i, e := range fx.Entries {
		en := clipboard.Entry{ID: fmt.Sprint(i), Kind: clipboard.Kind(e.Kind), Text: e.Text}
		if en.Kind == clipboard.KindText {
			en.Class = clipboard.Classify(e.Text)
		}
		if en.Title() != e.Title {
			t.Fatalf("entry %d titled %q, want %q", i, en.Title(), e.Title)
		}
		entries = append(entries, en)
	}
	for _, c := range fx.Cases {
		b := &clipboard.Board{}
		b.SetEntries(entries)
		for i, k := range c.Keys {
			cmd, ok := b.Press(k, c.Query == "")
			var got *string
			if ok {
				s := string(cmd.Action)
				got = &s
			}
			want := c.Actions[i]
			if (got == nil) != (want == nil) || got != nil && *got != *want {
				t.Errorf("%v: key %q gave %v, want %v", c.Keys, k, deref(got), deref(want))
			}
		}
		if c.Selected != "" {
			if sel, _ := b.Selection(); sel.Title() != c.Selected {
				t.Errorf("%v: selected %q, want %q", c.Keys, sel.Title(), c.Selected)
			}
		}
	}
	for _, m := range fx.Menus {
		i := slices.IndexFunc(entries, func(e clipboard.Entry) bool { return e.Title() == m.Entry })
		var got []string
		for _, it := range clipboard.Menu(entries[i]) {
			got = append(got, it.Title)
		}
		if !slices.Equal(got, m.Items) {
			t.Errorf("menu for %q = %v, want %v", m.Entry, got, m.Items)
		}
	}
}

func deref(s *string) string {
	if s == nil {
		return "null"
	}
	return *s
}
