package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

// harness is a panel with no window: results land on a channel and the
// test applies them on its own goroutine, which stands in for the main
// thread. The window seams record what the panel asked for.
type harness struct {
	p       *panel
	tt      *ui.Tester
	updates chan func()
	hidden  int
	heights []int
	opened  []string
	boards  []string
}

func testPanel(t *testing.T) *harness {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"Calculator.app/x", "Calendar.app/x", "notes/calendar-plan.md", "notes/report.pdf"} {
		full := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	index := filepath.Join(t.TempDir(), "t.flix")
	if _, err := core.Build(root, index); err != nil {
		t.Fatal(err)
	}
	h := &harness{p: newPanel(false), updates: make(chan func(), 64)}
	p := h.p
	t.Cleanup(p.engine.Close)
	p.update = func(fn func()) { h.updates <- fn }
	p.visible = func() bool { return true }
	p.hide = func() { h.hidden++ }
	p.resize = func(height int) { h.heights = append(h.heights, height) }
	p.open = func(target string) error { h.opened = append(h.opened, target); return nil }
	p.reveal = func(path string) { h.opened = append(h.opened, "reveal:"+path) }
	p.openBoard = func(q string) { h.boards = append(h.boards, q) }
	opened := make(chan struct{})
	p.engine.UseIndex(index, root, func(int, error) { close(opened) })
	<-opened
	p.engine.SetApps(apps.Scan([]string{root}))
	h.tt = ui.NewTester(p.view, panelWidth, panelMaxHeight)
	p.input.Focus()
	h.tt.Frame()
	return h
}

// settle applies published results until one answers query.
func (h *harness) settle(t *testing.T, query string) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case fn := <-h.updates:
			fn()
			h.tt.Frame()
			if h.p.query == query && len(h.p.rows) > 0 {
				return
			}
		case <-deadline:
			t.Fatalf("no rows for %q (rows %+v)", query, h.p.rows)
		}
	}
}

func TestTypingShowsAppsBeforeFilesAndTheWebRowLast(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("cal")
	h.settle(t, "cal")
	p := h.p
	if p.rows[0].Title != "Calendar" || p.rows[1].Title != "Calculator" {
		t.Fatalf("rows %+v, want Calendar then Calculator first", p.rows)
	}
	if !h.tt.HasText("Calendar") || !h.tt.HasText("Top Hit · Application") {
		t.Fatalf("view shows %q", h.tt.Texts())
	}
	if last := p.rows[len(p.rows)-1]; last.ID != search.WebRowID {
		t.Fatalf("last row %+v, want the Google row", last)
	}
	if !h.tt.HasText("All 5") || !h.tt.HasText("Apps 2") {
		t.Fatalf("chips missing in %q", h.tt.Texts())
	}
	if len(h.heights) == 0 || h.heights[len(h.heights)-1] != panelHeight(len(p.rows)) {
		t.Fatalf("panel resized to %v for %d rows", h.heights, len(p.rows))
	}
}

func TestFilterChipNarrowsAndKeepsTheWebRow(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("cal")
	h.settle(t, "cal")
	h.tt.Key(ui.Cmd, ui.Key2)
	p := h.p
	if p.filter != search.FilterApps || len(p.rows) != 3 || p.rows[2].ID != search.WebRowID {
		t.Fatalf("Apps chip shows %+v", p.rows)
	}
}

func TestArrowsMoveTheChoiceWithinBounds(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("cal")
	h.settle(t, "cal")
	h.tt.Key(0, ui.KeyUp)
	if h.p.chosen != 0 {
		t.Fatalf("Up from the top chose %d", h.p.chosen)
	}
	for range 10 {
		h.tt.Key(0, ui.KeyDown)
	}
	if h.p.chosen != len(h.p.rows)-1 {
		t.Fatalf("Down past the end chose %d of %d", h.p.chosen, len(h.p.rows))
	}
}

func TestReturnOpensAndHides(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("cal")
	h.settle(t, "cal")
	h.tt.Key(0, ui.KeyEnter)
	if h.hidden != 1 || len(h.opened) != 1 || filepath.Base(h.opened[0]) != "Calendar.app" {
		t.Fatalf("hidden %d, opened %v", h.hidden, h.opened)
	}
	h.tt.Key(ui.Cmd, ui.KeyEnter)
	if len(h.opened) != 2 || h.opened[1][:7] != "reveal:" {
		t.Fatalf("⌘Return did %v", h.opened)
	}
}

func TestTabEntersWebModeAndEscapeLeavesIt(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("yt lofi")
	h.settle(t, "yt lofi")
	h.tt.Key(0, ui.KeyTab)
	p := h.p
	if p.mode.Kind != query.Web || p.mode.EngineID != "youtube" || p.query != "lofi" {
		t.Fatalf("after Tab: mode %+v, query %q", p.mode, p.query)
	}
	h.settle(t, "lofi")
	if p.rows[0].Title != "YouTube" {
		t.Fatalf("web mode rows %+v", p.rows)
	}
	h.tt.Key(0, ui.KeyEscape)
	if p.mode.Kind != query.Local || p.query != "yt lofi" || h.hidden != 0 {
		t.Fatalf("after Esc: mode %+v, query %q, hidden %d", p.mode, p.query, h.hidden)
	}
	h.tt.Key(0, ui.KeyEscape)
	if h.hidden != 1 {
		t.Fatal("Esc in local mode did not hide")
	}
}

func TestTabOnClipHandsTheQueryToTheBoard(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("clip foo")
	h.tt.Key(0, ui.KeyTab)
	if len(h.boards) != 1 || h.boards[0] != "foo" || h.hidden != 1 {
		t.Fatalf("boards %v, hidden %d", h.boards, h.hidden)
	}
}

func TestCalculatorRowCopies(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("6*7")
	h.settle(t, "6*7")
	if r := h.p.rows[0]; r.Kind != search.KindCalculator || r.Copy != "42" {
		t.Fatalf("first row %+v", r)
	}
}

func TestDropForgetsRowsAndQuery(t *testing.T) {
	h := testPanel(t)
	h.tt.Type("cal")
	h.settle(t, "cal")
	p := h.p
	freed := make(chan struct{})
	p.drop()
	p.engine.Clear(func() { close(freed) })
	<-freed
	if p.query != "" || p.rows != nil || p.chosen != 0 || len(p.icons) != 0 {
		t.Fatalf("after drop: query %q, %d rows, chosen %d", p.query, len(p.rows), p.chosen)
	}
}

func testBoard(t *testing.T) (*board, *ui.Tester) {
	t.Helper()
	store, err := clipboard.Open(filepath.Join(t.TempDir(), "c.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	for i, text := range []string{"first copy", "https://example.com/x", "second copy"} {
		if _, err := store.Record([]clipboard.Capture{{Kind: clipboard.KindText, Text: text}}, "com.apple.Safari", float64(1000+i)); err != nil {
			t.Fatal(err)
		}
	}
	bd := newBoard(store, t.TempDir())
	bd.now = func() float64 { return 1010 }
	bd.update = func(fn func()) { fn() }
	bd.visible = func() bool { return true }
	bd.hide = func() {}
	bd.refresh()
	tt := ui.NewTester(bd.view, boardWidth, boardHeight)
	bd.input.Focus()
	tt.Frame()
	return bd, tt
}

func TestBoardListsNewestFirstAndFilters(t *testing.T) {
	bd, tt := testBoard(t)
	if sel, _ := bd.b.Selection(); sel.Text != "second copy" {
		t.Fatalf("selected %q, want the newest", sel.Text)
	}
	if !tt.HasText("Safari · just now") || !tt.HasText("Characters") {
		t.Fatalf("board shows %q", tt.Texts())
	}
	tt.Type("example")
	tt.Frame()
	if v := bd.b.Visible(); len(v) != 1 || v[0].Class.Content != clipboard.Link {
		t.Fatalf("search shows %+v", v)
	}
}

func TestBoardPinMovesTheEntryToTheTop(t *testing.T) {
	bd, tt := testBoard(t)
	tt.Key(0, ui.KeyDown)
	tt.Key(0, ui.KeyDown)
	tt.Key(ui.Cmd, ui.KeyPeriod)
	tt.Frame()
	if first := bd.b.Visible()[0]; first.Text != "first copy" || !first.Pinned() {
		t.Fatalf("first entry %+v", first)
	}
	if sel, _ := bd.b.Selection(); sel.Text != "first copy" {
		t.Fatalf("selection moved to %q", sel.Text)
	}
	tt.Key(ui.Cmd, ui.KeyD)
	if n := len(bd.b.Visible()); n != 2 {
		t.Fatalf("%d entries after delete", n)
	}
}

func TestBoardActionsMenuOpensOnCmdK(t *testing.T) {
	bd, tt := testBoard(t)
	tt.Key(ui.Cmd, ui.KeyK)
	tt.Frame()
	if !bd.menu || !tt.HasText("Pin") || !tt.HasText("Delete") {
		t.Fatalf("menu %v, texts %q", bd.menu, tt.Texts())
	}
}
