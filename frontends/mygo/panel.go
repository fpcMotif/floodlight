package main

import (
	"log"
	"os"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/apps"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/core"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/hotkey"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/platform"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

// panel is the launcher window. Its fields belong to the main thread: the
// view, the hot key and Window.Update closures all run there. Only engine
// and the measurement hooks are touched from other goroutines.
type panel struct {
	win     *mygo.Window
	engine  *search.Engine
	measure bool

	// The window seams publish, resize and the actions go through: the
	// window in the app, plain functions in the view test, which has none.
	update  func(func())
	visible func() bool
	hide    func()
	resize  func(height int)
	open    func(target string) error
	reveal  func(path string)

	query  string
	mode   query.Mode
	pub    search.Publication
	filter search.Filter
	rows   []search.Row // pub.Visible(filter)
	chosen int
	list   ui.ListState
	input  ui.Handle
	height int

	// icons are row icons decoded on first show and dropped on hide.
	icons map[string]*ui.Bitmap

	// Set by the app: where Tab on `clip` and the clipboard keyword go, and
	// what the lock button starts.
	openBoard  func(query string)
	startGrant func()
	granted    func() bool

	// warming is true until the off-screen first frame at launch is drawn.
	warming bool

	// Measurement hooks: set by runMeasurement before the first show, read
	// on the main thread. Nil outside -measure.
	onFrame atomic.Pointer[func()]
	onRows  atomic.Pointer[func(search.Result)]
}

func newPanel(measure bool) *panel {
	p := &panel{measure: measure, height: searchHeight, icons: map[string]*ui.Bitmap{}}
	p.engine = search.New(p.publish)
	p.granted = func() bool { return true }
	return p
}

// ready creates the hidden panel and binds ⌥Space. Main thread.
func (p *panel) ready() {
	glass := mygo.VibrancyGlassClear
	if platform.ReduceTransparency() {
		// A solid material keeps the rows readable when the user asked for
		// less transparency; the view paints the theme background.
		glass = mygo.VibrancyNone
	}
	p.win = mygo.NewWindow(mygo.WindowOptions{
		Title:         "Floodlight",
		Panel:         true,
		Hidden:        true,
		Frameless:     true,
		Transparent:   true,
		Vibrancy:      glass,
		CornerRadius:  panelCornerRadius,
		Width:         panelWidth,
		Height:        searchHeight,
		DisableResize: true,
		Content:       ui.View(p.view),
	})
	// The clear glass reads clear only in a window drawn as active, and a
	// non-activating panel never is.
	p.win.SetActiveAppearance(true)
	platform.ConfigurePanel(p.win.NativeHandle())
	p.update, p.visible, p.hide = p.win.Update, p.win.IsVisible, p.win.Hide
	p.open = func(target string) error {
		if strings.Contains(target, ":") && !strings.HasPrefix(target, "/") {
			return mygo.Shell.OpenExternal(target)
		}
		return mygo.Shell.OpenPath(target)
	}
	p.reveal = mygo.Shell.ShowItemInFolder
	p.resize = p.resizeWindow
	// Cmd-W and an Escape the view leaves would close the panel; hiding keeps
	// it warm for the next ⌥Space.
	p.win.OnClose(func(e *mygo.CloseEvent) {
		e.PreventDefault()
		p.win.Hide()
	})
	p.win.OnHide(p.drop)
	// The measurement run has no user to keep the panel focused.
	if !p.measure {
		p.win.OnBlur(func() {
			if !p.warming && !platform.QuickLookVisible() {
				p.win.Hide()
			}
		})
	}
	if _, err := hotkey.Register(hotkey.KeySpace, hotkey.Option, p.toggle); err != nil {
		log.Printf("⌥Space: %v", err)
	}
}

// warm draws one frame off screen at launch, so fonts, glyphs and the Metal
// pipeline exist before the first ⌥Space instead of being built by it.
func (p *panel) warm() {
	p.warming = true
	p.win.SetPosition(-4*panelWidth, -4*panelMaxHeight)
	p.win.ShowInactive()
}

// warmed runs on the main thread after the off-screen frame. Every frame
// drawn while warming queues one, and a summon may land between them; only
// the first, and only if no summon did, hides the window.
func (p *panel) warmed() {
	if !p.warming {
		return
	}
	p.warming = false
	p.win.Hide()
}

// resizeWindow keeps the top edge and the horizontal centre still, then
// asks for a frame at the new size at once, so no stale frame is scaled.
func (p *panel) resizeWindow(h int) {
	b := p.win.Bounds()
	if b.Height == h {
		return
	}
	p.win.SetBounds(mygo.Rectangle{X: b.X, Y: b.Y, Width: b.Width, Height: h})
	p.win.Invalidate()
}

// loadIndex opens the index left by the last run at once, then rebuilds it
// on a goroutine and swaps the new one in. The returned channel gets the
// entry count once the fresh index is open.
func (p *panel) loadIndex(root, path string) <-chan int {
	if _, err := os.Stat(path); err == nil {
		p.engine.UseIndex(path, root, nil)
	}
	return p.rebuild(root, path)
}

// rebuild scans root off the main thread and swaps the new index in on the
// engine goroutine, which owns every mapping. It runs after launch and again
// after a Full Disk Access grant, when folders the scan skipped open up.
func (p *panel) rebuild(root, path string) <-chan int {
	opened := make(chan int, 1)
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
	if p.win.IsVisible() && !p.warming {
		p.win.Hide()
		return
	}
	p.show()
}

// show puts the panel a third of the way down the display under the
// pointer, as Spotlight does, and lists the apps afresh, since they may have
// changed while it was hidden.
func (p *panel) show() {
	p.warming = false
	d := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint())
	p.height = searchHeight
	p.win.SetBounds(mygo.Rectangle{
		X:     d.WorkArea.X + (d.WorkArea.Width-panelWidth)/2,
		Y:     d.WorkArea.Y + (d.WorkArea.Height-panelMaxHeight)/3,
		Width: panelWidth, Height: searchHeight,
	})
	p.input.Focus()
	p.win.Show()
	go func() { p.engine.SetApps(apps.Scan(apps.Dirs())) }()
}

// drop runs on every hide: it lets go of everything the next show rebuilds,
// then hands the freed pages back to macOS. Without FreeOSMemory the Go
// runtime keeps them as idle heap and the footprint never falls.
func (p *panel) drop() {
	if p.warming {
		return
	}
	p.query, p.mode, p.pub, p.rows, p.chosen, p.filter = "", query.Mode{}, search.Publication{}, nil, 0, search.FilterAll
	p.list = ui.ListState{}
	clear(p.icons)
	platform.CloseQuickLook()
	p.engine.Clear(func() {
		debug.FreeOSMemory()
		platform.ReleaseMemory()
	})
}

func (p *panel) submit() { p.engine.SubmitMode(p.query, p.mode) }

// publish runs on the engine goroutine.
func (p *panel) publish(r search.Result) {
	p.update(func() {
		if r.Gen != p.engine.Latest() || !p.visible() {
			return
		}
		p.pub = r.Publication
		p.setFilter(p.filter)
		if hook := p.onRows.Load(); hook != nil {
			(*hook)(r)
		}
	})
}

// setFilter applies a chip and resizes the panel to what it shows.
func (p *panel) setFilter(f search.Filter) {
	p.filter = f
	p.rows = p.pub.Visible(f)
	p.choose(0)
	if h := panelHeight(len(p.rows)); h != p.height {
		p.height = h
		if p.resize != nil {
			p.resize(h)
		}
	}
}

func (p *panel) choose(i int) {
	p.chosen = max(0, min(i, len(p.rows)-1))
	if len(p.rows) > 0 {
		p.list.ScrollIntoView(p.chosen)
	}
}

// key moves the search mode. Tab into clipboard mode hands the field to the
// board, which is where clipboard history lives in this frontend.
func (p *panel) key(ev query.Event) {
	mode, text := query.Transition(p.mode, p.query, ev)
	if mode == p.mode && text == p.query {
		return
	}
	if mode.Kind == query.Clipboard {
		p.hide()
		if p.openBoard != nil {
			p.openBoard(text)
		}
		return
	}
	p.mode, p.query = mode, text
	p.submit()
}

func (p *panel) selected() (search.Row, bool) {
	if p.chosen >= len(p.rows) {
		return search.Row{}, false
	}
	return p.rows[p.chosen], true
}

// activate opens the chosen row, copies its answer, or reveals it in
// Finder. The panel hides first so the app the user came from keeps the
// keyboard until the opened one takes it.
func (p *panel) activate(reveal bool) {
	row, ok := p.selected()
	if !ok {
		return
	}
	if reveal && !row.IsFile() {
		return
	}
	p.hide()
	switch {
	case reveal:
		p.reveal(row.Path)
	case row.Copy != "":
		platform.WriteText(row.Copy)
	default:
		if err := p.open(row.Path); err != nil {
			log.Printf("open %s: %v", row.Path, err)
		}
	}
}

// preview toggles Quick Look on the chosen file.
func (p *panel) preview() {
	if row, ok := p.selected(); ok && row.IsFile() {
		platform.ToggleQuickLook(row.Path)
	}
}

// icon is the Finder icon for a file row, decoded once per show.
func (p *panel) icon(path string) *ui.Bitmap {
	if b, ok := p.icons[path]; ok {
		return b
	}
	var b *ui.Bitmap
	if png := platform.IconPNG(path, iconPixels); png != nil {
		b, _ = ui.DecodeBitmap(png)
	}
	p.icons[path] = b
	return b
}
