package clipboard

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fakeSource struct {
	mu    sync.Mutex
	count int
	pb    Pasteboard
}

func (f *fakeSource) ChangeCount() int { f.mu.Lock(); defer f.mu.Unlock(); return f.count }
func (f *fakeSource) Read() Pasteboard { f.mu.Lock(); defer f.mu.Unlock(); return f.pb }
func (f *fakeSource) copy(pb Pasteboard) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.count++
	f.pb = pb
}

func TestWatchRecordsEachChangeOnce(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "c.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	src := &fakeSource{}
	got := make(chan []Entry, 4)
	stop := make(chan struct{})
	defer close(stop)
	Watch(src, store, func() float64 { return 1 }, stop, func(es []Entry) { got <- es })

	src.copy(Pasteboard{Text: "hello", Source: "com.apple.Notes"})
	select {
	case es := <-got:
		if len(es) != 1 || es[0].Text != "hello" || es[0].SourceID != "com.apple.Notes" {
			t.Fatalf("recorded %+v", es)
		}
	case <-time.After(3 * PollInterval):
		t.Fatal("change never recorded")
	}
	time.Sleep(2 * PollInterval)
	if es, _ := store.List(""); len(es) != 1 {
		t.Fatalf("%d entries; an unchanged count was recorded again", len(es))
	}
}

func TestOpenFallsBackToMemory(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "missing", "dir", "c.sqlite3"))
	if err == nil || s == nil || !s.InMemory {
		t.Fatalf("store %v, err %v; want an in-memory store and the error", s, err)
	}
	defer s.Close()
	if _, err := s.Record([]Capture{{Kind: KindText, Text: "x"}}, "", 1); err != nil {
		t.Fatal(err)
	}
}

func TestShortQueriesScan(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "c.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for i, text := range []string{"Go is fun", "nothing", "GOPATH"} {
		if _, err := s.Record([]Capture{{Kind: KindText, Text: text}}, "", float64(i)); err != nil {
			t.Fatal(err)
		}
	}
	es, err := s.List("go")
	if err != nil || len(es) != 2 || es[0].Text != "GOPATH" {
		t.Fatalf("List(go) = %+v, %v", es, err)
	}
}

func TestSubtitleNamesTheSource(t *testing.T) {
	e := Entry{Kind: KindText, Text: "x", SourceID: "com.mitchellh.ghostty", CreatedAt: 0}
	if got := e.Subtitle(7200, func(id string) string { return SourceName(id, nil) }); got != "ghostty · 2h" {
		t.Fatalf("subtitle %q", got)
	}
	if got := SourceName("com.mitchellh.ghostty", func(string) string { return "Ghostty" }); got != "Ghostty" {
		t.Fatalf("lookup ignored: %q", got)
	}
}
