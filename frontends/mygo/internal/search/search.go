// Package search runs every query on one goroutine, away from the UI.
//
// The UI calls Submit on each keystroke and gets a Publication back through
// the publish callback. Only the newest query counts: a query still waiting
// is replaced, and a result that finishes after a newer Submit is dropped. A
// core search cannot be interrupted once in C, so the engine checks between
// the steps of a query instead.
package search

import (
	"os"
	"sync/atomic"
	"time"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
)

// Result answers one Submit.
type Result struct {
	Gen   uint64
	Query string
	Mode  query.Mode
	Publication
	Took time.Duration // on the engine goroutine, queue wait excluded
}

type request struct {
	gen   uint64
	query string
	mode  query.Mode
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
	cat  Catalog
	last request
}

// New starts the engine. publish runs on the engine goroutine, once per
// query that is still the newest when it finishes.
func New(publish func(Result)) *Engine {
	home, _ := os.UserHomeDir()
	return NewAt(home, publish)
}

// NewAt is New with home, the folder subtitles show as ~, given; the
// parity fixtures set it so their rows read the same on every machine.
func NewAt(home string, publish func(Result)) *Engine {
	e := &Engine{
		publish: publish,
		req:     make(chan request, 1),
		ctl:     make(chan func(), 4),
		done:    make(chan struct{}),
		cat:     Catalog{Home: home},
	}
	go e.loop()
	return e
}

// Submit queues a local query and returns its generation.
func (e *Engine) Submit(q string) uint64 { return e.SubmitMode(q, query.Mode{}) }

// SubmitMode queues q in mode. A query still waiting is replaced, so a fast
// typist never builds a backlog.
func (e *Engine) SubmitMode(q string, mode query.Mode) uint64 {
	r := request{gen: e.latest.Add(1), query: q, mode: mode}
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
		e.cat.Apps, e.last = nil, request{}
		if then != nil {
			then()
		}
	})
}

// SetApps replaces the app list and reruns the newest query against it,
// since the apps usually arrive after the first keystroke.
func (e *Engine) SetApps(list []apps.App) {
	e.do(func() {
		e.cat.Apps = list
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
			e.cat.Index.Close()
			e.cat.Index, e.cat.Root = ix, root
			e.run(e.last)
		}
		if done != nil {
			n := 0
			if e.cat.Index != nil {
				n = e.cat.Index.Count()
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
			e.cat.Index.Close()
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
	p, ok := e.cat.Publish(r.query, r.mode, func() bool { return e.stale(r) })
	if !ok || e.stale(r) {
		return
	}
	e.publish(Result{Gen: r.gen, Query: r.query, Mode: r.mode, Publication: p, Took: time.Since(start)})
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
