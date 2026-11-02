package main

import (
	"log"
	"os"
	"runtime/debug"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/hotkey"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

const width, height = 680, 420

// panel is the launcher window. Its fields belong to the main thread: the
// view, the hot key and Window.Update closures all run there. Only engine
// and the measurement hooks are touched from other goroutines.
type panel struct {
	win     *mygo.Window
	engine  *search.Engine
	measure bool

	// The window seam publish goes through: Window.Update and IsVisible in
	// the app, a direct call in the view test, which has no window.
	update  func(func())
	visible func() bool

	query  string
	rows   []search.Row
	chosen int
	list   ui.ListState
	input  ui.Handle

	// Measurement hooks: set by runMeasurement before the first show, read
	// on the main thread. Nil outside -measure.
	onFrame atomic.Pointer[func()]
	onRows  atomic.Pointer[func(search.Result)]
}

func newPanel(measure bool) *panel {
	p := &panel{measure: measure}
	p.engine = search.New(p.publish)
	return p
}

// ready creates the hidden panel and binds ⌥Space. Main thread.
func (p *panel) ready() {
	p.win = mygo.NewWindow(mygo.WindowOptions{
		Title:         "Floodlight",
		Panel:         true,
		Hidden:        true,
		Frameless:     true,
		Transparent:   true,
		Vibrancy:      mygo.VibrancyGlass,
		CornerRadius:  16,
		Width:         width,
		Height:        height,
		DisableResize: true,
		Content:       ui.View(p.view),
	})
	p.update, p.visible = p.win.Update, p.win.IsVisible
	// Cmd-W and an Escape the view leaves would close the panel; hiding keeps
	// it warm for the next ⌥Space.
	p.win.OnClose(func(e *mygo.CloseEvent) {
		e.PreventDefault()
		p.win.Hide()
	})
	p.win.OnHide(p.drop)
	// The measurement run has no user to keep the panel focused.
	if !p.measure {
		p.win.OnBlur(p.win.Hide)
	}
	if _, err := hotkey.Register(hotkey.KeySpace, hotkey.Option, p.toggle); err != nil {
		log.Printf("⌥Space: %v", err)
	}
}

// loadIndex opens the index left by the last run at once, then rebuilds it
// on a goroutine and swaps the new one in. The returned channel gets the
// entry count once the fresh index is open.
func (p *panel) loadIndex(root, path string) <-chan int {
	opened := make(chan int, 1)
	if _, err := os.Stat(path); err == nil {
		p.engine.UseIndex(path, root, nil)
	}
	go func() {
		start := time.Now()
		if _, err := core.Build(root, path); err != nil {
			log.Print(err)
		}
		p.engine.UseIndex(path, root, func(n int, err error) {
			if err != nil {
				log.Print(err)
			}
			log.Printf("index: %d entries under %s in %v", n, root, time.Since(start).Round(time.Millisecond))
			opened <- n
		})
	}()
	return opened
}

func (p *panel) toggle() {
	if p.win.IsVisible() {
		p.win.Hide()
		return
	}
	p.show()
}

// show puts the panel a third of the way down the display under the
// pointer, as Spotlight does, and lists the apps afresh, since they may have
// changed while it was hidden.
func (p *panel) show() {
	d := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint())
	w, h := p.win.Size()
	p.win.SetPosition(d.WorkArea.X+(d.WorkArea.Width-w)/2, d.WorkArea.Y+(d.WorkArea.Height-h)/3)
	p.input.Focus()
	p.win.Show()
	go func() { p.engine.SetApps(apps.Scan(apps.Dirs())) }()
}

// drop runs on every hide: it lets go of everything the next show rebuilds,
// then hands the freed pages back to macOS. Without FreeOSMemory the Go
// runtime keeps them as idle heap and RSS never falls.
func (p *panel) drop() {
	p.query, p.rows, p.chosen = "", nil, 0
	p.list = ui.ListState{}
	p.engine.Clear(debug.FreeOSMemory)
}

func (p *panel) submit() { p.engine.Submit(p.query) }

// publish runs on the engine goroutine.
func (p *panel) publish(r search.Result) {
	p.update(func() {
		if r.Gen != p.engine.Latest() || !p.visible() {
			return
		}
		p.rows = r.Rows
		p.choose(0)
		if hook := p.onRows.Load(); hook != nil {
			(*hook)(r)
		}
	})
}

func (p *panel) choose(i int) {
	p.chosen = max(0, min(i, len(p.rows)-1))
	if len(p.rows) > 0 {
		p.list.ScrollIntoView(p.chosen)
	}
}

// activate opens the chosen row, or reveals it in Finder. The panel hides
// first so the app the user came from has the keyboard until the opened one
// takes it.
func (p *panel) activate(reveal bool) {
	if p.chosen >= len(p.rows) {
		return
	}
	row := p.rows[p.chosen]
	p.win.Hide()
	if reveal {
		mygo.Shell.ShowItemInFolder(row.Path)
		return
	}
	if err := mygo.Shell.OpenPath(row.Path); err != nil {
		log.Printf("open %s: %v", row.Path, err)
	}
}
