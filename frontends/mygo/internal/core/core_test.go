package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildOpenSearch(t *testing.T) {
	root := t.TempDir()
	for _, p := range []string{"docs/readme.md", "src/main.go", "src/search.go"} {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	out := filepath.Join(t.TempDir(), "test.flix")
	n, err := Build(root, out)
	if err != nil {
		t.Fatal(err)
	}
	if n < 5 {
		t.Fatalf("Build counted %d entries, want at least 5", n)
	}
	ix, err := Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer ix.Close()
	if ix.Count() != n {
		t.Fatalf("Count = %d, Build said %d", ix.Count(), n)
	}

	var buf [8]Hit
	hits := ix.Search("search", buf[:])
	if len(hits) == 0 {
		t.Fatal("no hits for \"search\"")
	}
	path, err := ix.RelativePath(hits[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, "search.go") || ix.IsDir(hits[0].ID) {
		t.Fatalf("best hit %q (dir %v), want src/search.go", path, ix.IsDir(hits[0].ID))
	}
	if got := ix.Search("", buf[:]); len(got) != 0 {
		t.Fatalf("empty query gave %d hits", len(got))
	}
}
