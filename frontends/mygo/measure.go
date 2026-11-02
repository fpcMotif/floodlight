package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"slices"
	"time"

	"github.com/egoist/mygo"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/hotkey"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/memstat"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

// The -measure run, for CI. It drives the real panel: summons it, types
// queries through the same Submit the text field uses, hides it, waits, and
// reads its own memory. Numbers go to stdout as one FLOODLIGHT_MYGO line.

const (
	warmSummons = 10
	queryReps   = 5
	idleAfter   = 10 * time.Second
	watchdog    = 4 * time.Minute
)

// Queries a user might type, short and long, matching many entries and few.
var measureQueries = []string{"a", "re", "doc", "make", "swift", "readme", "package", "src main", "xyzzy", "flood"}

type report struct {
	MyGo                string       `json:"mygo"`
	Go                  string       `json:"go"`
	Root                string       `json:"root"`
	Entries             int          `json:"entries"`
	HotkeyPath          string       `json:"hotkey_path"`
	FirstFrameColdMs    float64      `json:"hotkey_first_frame_cold_ms"`
	FirstFrameWarmP50Ms float64      `json:"hotkey_first_frame_warm_p50_ms"`
	QueryP50Ms          float64      `json:"query_p50_ms"`
	QueryP95Ms          float64      `json:"query_p95_ms"`
	EngineP50Ms         float64      `json:"query_engine_p50_ms"`
	Idle                memstat.Stat `json:"idle_after_hide"`
	IdleGoHeapInuse     uint64       `json:"idle_go_heap_inuse"`
}

func runMeasurement(p *panel, indexed <-chan int) {
	time.AfterFunc(watchdog, func() { fail("watchdog: no result in %v", watchdog) })

	frames := make(chan time.Time, 1)
	frameHook := func() {
		select {
		case frames <- time.Now():
		default:
		}
	}
	p.onFrame.Store(&frameHook)
	rows := make(chan search.Result, 16)
	rowsHook := func(r search.Result) { rows <- r }
	p.onRows.Store(&rowsHook)

	rep := report{MyGo: moduleVersion("github.com/egoist/mygo"), Go: runtime.Version(), Root: filesRoot()}
	select {
	case rep.Entries = <-indexed:
	case <-time.After(2 * time.Minute):
		fail("index never opened")
	}
	time.Sleep(time.Second)

	// Cold summon: a real ⌥Space through the HID tap if the system lets this
	// process post one, else the hot key's own handler on the main thread.
	drain(frames)
	start := time.Now()
	hotkey.PostOptionSpace()
	if at, ok := waitFrame(frames, 1500*time.Millisecond); ok {
		rep.HotkeyPath = "carbon"
		rep.FirstFrameColdMs = ms(at.Sub(start))
	} else {
		rep.HotkeyPath = "handler"
		if p.win.IsVisible() {
			fail("panel shown but no frame drawn")
		}
		start = time.Now()
		p.win.Update(p.toggle)
		at, ok := waitFrame(frames, 5*time.Second)
		if !ok {
			fail("no frame after summon")
		}
		rep.FirstFrameColdMs = ms(at.Sub(start))
	}

	var warm []float64
	for range warmSummons {
		p.win.Update(p.win.Hide)
		time.Sleep(300 * time.Millisecond)
		drain(frames)
		start := time.Now()
		if rep.HotkeyPath == "carbon" {
			hotkey.PostOptionSpace()
		} else {
			p.win.Update(p.toggle)
		}
		at, ok := waitFrame(frames, 5*time.Second)
		if !ok {
			fail("no frame on warm summon")
		}
		warm = append(warm, ms(at.Sub(start)))
	}
	rep.FirstFrameWarmP50Ms = percentile(warm, 50)

	// Let the app list from the last show land, so it doesn't rerun a query
	// mid-measurement.
	time.Sleep(500 * time.Millisecond)
	var uiTimes, engine []float64
	for range queryReps {
		for _, q := range measureQueries {
			drainRows(rows)
			start := time.Now()
			p.win.Update(func() {
				p.query = q
				p.submit()
			})
			r := waitRows(rows, q)
			uiTimes = append(uiTimes, ms(time.Since(start)))
			engine = append(engine, ms(r.Took))
		}
	}
	rep.QueryP50Ms, rep.QueryP95Ms = percentile(uiTimes, 50), percentile(uiTimes, 95)
	rep.EngineP50Ms = percentile(engine, 50)

	p.onFrame.Store(nil)
	p.onRows.Store(nil)
	p.win.Update(p.win.Hide)
	time.Sleep(idleAfter)
	var err error
	if rep.Idle, err = memstat.Read(); err != nil {
		fail("%v", err)
	}
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	rep.IdleGoHeapInuse = mem.HeapInuse

	out, _ := json.Marshal(rep)
	fmt.Printf("FLOODLIGHT_MYGO %s\n", out)
	mygo.App.Exit(0)
}

func waitFrame(frames <-chan time.Time, d time.Duration) (time.Time, bool) {
	select {
	case at := <-frames:
		return at, true
	case <-time.After(d):
		return time.Time{}, false
	}
}

func waitRows(rows <-chan search.Result, q string) search.Result {
	deadline := time.After(10 * time.Second)
	for {
		select {
		case r := <-rows:
			if r.Query == q {
				return r
			}
		case <-deadline:
			fail("no rows for %q", q)
		}
	}
}

func drain(ch <-chan time.Time) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

func drainRows(ch <-chan search.Result) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

func percentile(v []float64, p int) float64 {
	s := slices.Clone(v)
	slices.Sort(s)
	return s[min(len(s)-1, len(s)*p/100)]
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func moduleVersion(path string) string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, m := range info.Deps {
			if m.Path == path {
				return m.Version
			}
		}
	}
	return "unknown"
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "measure: "+format+"\n", args...)
	os.Exit(1)
}
