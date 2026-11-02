package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
)

// testPanel is a panel with no window: results land on a channel and the
// test applies them on its own goroutine, which stands in for the main
// thread.
func testPanel(t *testing.T) (*panel, *ui.Tester, chan func()) {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"Calculator.app/x", "Calendar.app/x", "notes/calendar-plan.md"} {
		full := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	index := filepath.Join(t.TempDir(), "t.flix")
	if _, err := core.Build(root, index); err != nil {
		t.Fatal(err)
	}
	p := newPanel(false)
	t.Cleanup(p.engine.Close)
	updates := make(chan func(), 16)
	p.update = func(fn func()) { updates <- fn }
	p.visible = func() bool { return true }
	opened := make(chan struct{})
	p.engine.UseIndex(index, root, func(int, error) { close(opened) })
	<-opened
	p.engine.SetApps(apps.Scan([]string{root}))
	tt := ui.NewTester(p.view, width, height)
	p.input.Focus()
	tt.Frame()
	return p, tt, updates
}

// settle applies published results until one carries rows for query.
func settle(t *testing.T, p *panel, tt *ui.Tester, updates chan func(), query string) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case fn := <-updates:
			fn()
			tt.Frame()
			if p.query == query && len(p.rows) > 0 {
				return
			}
		case <-deadline:
			t.Fatalf("no rows for %q (rows %+v)", query, p.rows)
		}
	}
}

func TestTypingShowsAppsBeforeFiles(t *testing.T) {
	p, tt, updates := testPanel(t)
	tt.Type("cal")
	settle(t, p, tt, updates, "cal")
	if p.rows[0].Title != "Calendar" || p.rows[1].Title != "Calculator" {
		t.Fatalf("rows %+v, want Calendar then Calculator first", p.rows)
	}
	if !tt.HasText("Calendar") || !tt.HasText("Application") {
		t.Fatalf("view shows %q", tt.Texts())
	}
	last := p.rows[len(p.rows)-1]
	if last.Title != "calendar-plan.md" {
		t.Fatalf("last row %+v, want the file", last)
	}
}

func TestArrowsMoveTheChoiceWithinBounds(t *testing.T) {
	p, tt, updates := testPanel(t)
	tt.Type("cal")
	settle(t, p, tt, updates, "cal")
	tt.Key(0, ui.KeyUp)
	if p.chosen != 0 {
		t.Fatalf("Up from the top chose %d", p.chosen)
	}
	for range 10 {
		tt.Key(0, ui.KeyDown)
	}
	if p.chosen != len(p.rows)-1 {
		t.Fatalf("Down past the end chose %d of %d", p.chosen, len(p.rows))
	}
}

func TestDropForgetsRowsAndQuery(t *testing.T) {
	p, tt, updates := testPanel(t)
	tt.Type("cal")
	settle(t, p, tt, updates, "cal")
	freed := make(chan struct{})
	p.drop()
	p.engine.Clear(func() { close(freed) })
	<-freed
	if p.query != "" || p.rows != nil || p.chosen != 0 {
		t.Fatalf("after drop: query %q, %d rows, chosen %d", p.query, len(p.rows), p.chosen)
	}
}
