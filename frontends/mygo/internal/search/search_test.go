package search

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
)

func fixture(t *testing.T) (index, root string) {
	t.Helper()
	root = t.TempDir()
	for _, p := range []string{"notes/plan.md", "src/planner.go", "Calendar.app/Contents/Info.plist"} {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	index = filepath.Join(t.TempDir(), "x.flix")
	if _, err := core.Build(root, index); err != nil {
		t.Fatal(err)
	}
	return index, root
}

func waitFor(t *testing.T, ch <-chan Result) Result {
	t.Helper()
	select {
	case r := <-ch:
		return r
	case <-time.After(5 * time.Second):
		t.Fatal("no result")
		return Result{}
	}
}

func TestEngineAppsThenFiles(t *testing.T) {
	index, root := fixture(t)
	results := make(chan Result, 16)
	e := New(func(r Result) { results <- r })
	defer e.Close()

	opened := make(chan error, 1)
	e.UseIndex(index, root, func(_ int, err error) { opened <- err })
	if err := <-opened; err != nil {
		t.Fatal(err)
	}
	e.SetApps(apps.Scan([]string{root}))

	gen := e.Submit("plan")
	r := waitFor(t, results)
	if r.Gen != gen || len(r.Rows) < 2 {
		t.Fatalf("result %+v, want gen %d with plan.md and planner.go", r, gen)
	}
	for _, row := range r.Rows {
		if row.Kind == KindApp {
			t.Fatalf("app row %q for \"plan\"", row.Title)
		}
		if !filepath.IsAbs(row.Path) {
			t.Fatalf("row path %q is not absolute", row.Path)
		}
	}

	e.Submit("calen")
	r = waitFor(t, results)
	if len(r.Rows) == 0 || r.Rows[0].Kind != KindApp || r.Rows[0].Title != "Calendar" {
		t.Fatalf("first row for \"calen\" is %+v, want the Calendar app", r.Rows)
	}
	seen := map[string]bool{}
	for _, row := range r.Rows {
		if seen[row.Path] {
			t.Fatalf("%s listed twice", row.Path)
		}
		seen[row.Path] = true
	}
}

func TestEngineDropsStaleQueries(t *testing.T) {
	index, root := fixture(t)
	results := make(chan Result, 64)
	e := New(func(r Result) { results <- r })
	defer e.Close()
	e.UseIndex(index, root, nil)

	var last uint64
	for _, q := range []string{"p", "pl", "pla", "plan", "plann"} {
		last = e.Submit(q)
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case r := <-results:
			if r.Gen > last {
				t.Fatalf("gen %d past the last submit %d", r.Gen, last)
			}
			if r.Gen == last {
				if r.Query != "plann" {
					t.Fatalf("newest result answers %q", r.Query)
				}
				return
			}
		case <-deadline:
			t.Fatal("newest query never answered")
		}
	}
}

func TestClearDropsInFlightAndApps(t *testing.T) {
	index, root := fixture(t)
	results := make(chan Result, 16)
	e := New(func(r Result) { results <- r })
	defer e.Close()
	e.UseIndex(index, root, nil)
	e.SetApps(apps.Scan([]string{root}))

	e.Submit("calen")
	waitFor(t, results)
	e.Clear(nil)
	gen := e.Submit("calen")
	r := waitFor(t, results)
	if r.Gen != gen {
		t.Fatalf("gen %d, want %d", r.Gen, gen)
	}
	for _, row := range r.Rows {
		if row.Kind == KindApp {
			t.Fatal("app list survived Clear")
		}
	}
}

func TestEmptyQueryHasNoRows(t *testing.T) {
	results := make(chan Result, 1)
	e := New(func(r Result) { results <- r })
	defer e.Close()
	e.Submit("   ")
	if r := waitFor(t, results); len(r.Rows) != 0 {
		t.Fatalf("rows for a blank query: %+v", r.Rows)
	}
}
