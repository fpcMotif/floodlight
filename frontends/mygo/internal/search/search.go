// Package search runs every query on one goroutine, away from the UI.
//
// The UI calls Submit on each keystroke and gets results back through the
// publish callback. Only the newest query counts: a query still waiting is
// replaced, and a result that finishes after a newer Submit is dropped. A
// core search cannot be interrupted once in C, so the engine checks between
// the steps of a query instead.
package search

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
)

// Row limits per section. A launcher shows about ten rows, so more files
// than this only cost path rebuilds nobody sees.
const (
	maxApps  = 6
	maxFiles = 40
)

// Kind tells what a row opens.
type Kind uint8

const (
	KindApp Kind = iota
	KindFile
	KindFolder
)

// Row is one result as the panel shows it.
type Row struct {
	Kind     Kind
	Title    string
	Subtitle string
	Path     string // absolute
}

// Result answers one Submit.
type Result struct {
	Gen   uint64
	Query string
	Rows  []Row
	Took  time.Duration // on the engine goroutine, queue wait excluded
}

type request struct {
	gen   uint64
	query string
}

// Engine owns the file index and the app list. All its state lives on its
// goroutine; other goroutines reach it only through channels.
type Engine struct {
	publish func(Result)
	latest  atomic.Uint64
	req     chan request
	ctl     chan func()
	done    chan struct{}

	// Engine goroutine only.
	index   *core.Index
	root    string
	apps    []apps.App
	last    request
	hitsBuf [maxFiles]core.Hit
}

// New starts the engine. publish runs on the engine goroutine, once per
// query that is still the newest when it finishes.
func New(publish func(Result)) *Engine {
	e := &Engine{
		publish: publish,
		req:     make(chan request, 1),
		ctl:     make(chan func(), 4),
		done:    make(chan struct{}),
	}
	go e.loop()
	return e
}

// Submit queues query and returns its generation. A query still waiting is
// replaced, so a fast typist never builds a backlog.
func (e *Engine) Submit(query string) uint64 {
	r := request{gen: e.latest.Add(1), query: query}
	for {
		select {
		case e.req <- r:
			return r.gen
		default:
		}
		select {
		case <-e.req:
		default:
		}
	}
}

// Latest returns the generation of the newest Submit or Clear.
func (e *Engine) Latest() uint64 { return e.latest.Load() }

// Clear makes every query in flight stale and drops the app list, so the
// hidden panel holds nothing it can rebuild on the next show. then, if not
// nil, runs on the engine goroutine once the list is unreachable.
func (e *Engine) Clear(then func()) {
	e.latest.Add(1)
	e.do(func() {
		e.apps, e.last = nil, request{}
		if then != nil {
			then()
		}
	})
}

// SetApps replaces the app list and reruns the newest query against it,
// since the apps usually arrive after the first keystroke.
func (e *Engine) SetApps(list []apps.App) {
	e.do(func() {
		e.apps = list
		e.run(e.last)
	})
}

// UseIndex opens the index at path for files under root and closes the one
// before it. It runs on the engine goroutine, so no search is ever using the
// mapping it unmaps. done, if not nil, gets the open error.
func (e *Engine) UseIndex(path, root string, done func(entries int, err error)) {
	e.do(func() {
		ix, err := core.Open(path)
		if err == nil {
			e.index.Close()
			e.index, e.root = ix, root
		}
		if done != nil {
			n := 0
			if e.index != nil {
				n = e.index.Count()
			}
			done(n, err)
		}
	})
}

// Close stops the engine and unmaps the index.
func (e *Engine) Close() {
	close(e.done)
}

func (e *Engine) do(fn func()) {
	select {
	case e.ctl <- fn:
	case <-e.done:
	}
}

func (e *Engine) loop() {
	for {
		select {
		case fn := <-e.ctl:
			fn()
		case r := <-e.req:
			// A Clear or SetApps sent before this Submit must land first;
			// select alone picks among ready channels at random.
			e.drainCtl()
			e.last = r
			e.run(r)
		case <-e.done:
			e.index.Close()
			return
		}
	}
}

func (e *Engine) stale(r request) bool { return r.gen != e.latest.Load() }

func (e *Engine) run(r request) {
	if r.gen == 0 || e.stale(r) {
		return
	}
	start := time.Now()
	q := strings.TrimSpace(r.query)
	var rows []Row
	if q != "" {
		matched := apps.Match(e.apps, q, maxApps)
		for _, a := range matched {
			rows = append(rows, Row{Kind: KindApp, Title: a.Name, Subtitle: Abbrev(filepath.Dir(a.Path)), Path: a.Path})
		}
		hits := e.index.Search(q, e.hitsBuf[:])
		// The C search is the slow step and cannot be interrupted; skip the
		// path rebuilds if the user typed again while it ran.
		if e.stale(r) {
			return
		}
		for _, h := range hits {
			rel, err := e.index.RelativePath(h.ID)
			if err != nil {
				continue
			}
			// A bundle's insides match by path but are never what a launcher
			// user wants; Spotlight hides them too.
			if strings.Contains(rel, ".app/") {
				continue
			}
			abs := filepath.Join(e.root, rel)
			// An app under the indexed root, ~/Applications say, is also a
			// folder hit; the app row already stands for it.
			if slices.ContainsFunc(matched, func(a apps.App) bool { return a.Path == abs }) {
				continue
			}
			kind := KindFile
			if e.index.IsDir(h.ID) {
				kind = KindFolder
			}
			rows = append(rows, Row{Kind: kind, Title: filepath.Base(rel), Subtitle: Abbrev(filepath.Dir(abs)), Path: abs})
		}
	}
	if e.stale(r) {
		return
	}
	e.publish(Result{Gen: r.gen, Query: r.query, Rows: rows, Took: time.Since(start)})
}

var home, _ = os.UserHomeDir()

// Abbrev shortens a path under the home folder to ~/….
func Abbrev(path string) string {
	if home != "" && (path == home || strings.HasPrefix(path, home+"/")) {
		return "~" + path[len(home):]
	}
	return path
}

func (e *Engine) drainCtl() {
	for {
		select {
		case fn := <-e.ctl:
			fn()
		default:
			return
		}
	}
}
