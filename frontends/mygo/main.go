// Command floodlight-mygo is Floodlight's frontend in Go and MyGo's native
// UI (ADR 0012): ⌥Space shows the search panel over the Zig core's file
// index, ⌥⇧C the clipboard board, and the lock in the search bar walks the
// user through granting Full Disk Access.
//
//	floodlight-mygo           run as a menu-bar-less accessory app
//	floodlight-mygo -measure  run the CI measurement and print one JSON line
package main

import (
	"flag"
	"log"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"

	"github.com/egoist/mygo"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/permission"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/platform"
)

// memoryLimit is the soft heap cap #112 proposes. The GC works harder near
// it instead of letting the heap grow; it is not a hard ceiling.
const memoryLimit = 25 << 20

func main() {
	measure := flag.Bool("measure", false, "measure hotkey, query and idle memory, print JSON, exit")
	flag.Parse()
	debug.SetMemoryLimit(memoryLimit)

	// The measurement run must not hand off to a launcher the user left open.
	if !*measure && !mygo.App.RequestSingleInstanceLock() {
		return
	}
	mygo.App.SetName("Floodlight")
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	mygo.App.OnWindowAllClosed(func() {})

	data := dataDir(*measure)
	p := newPanel(*measure)
	mygo.App.OnSecondInstance(func([]string, string) { p.show() })
	mygo.App.WhenReady(func() {
		p.ready()
		p.warm()
		root, index := filesRoot(), filepath.Join(data, "files.flix")
		indexed := p.loadIndex(root, index)

		// The measurement run builds every window and starts the capture
		// loop too: the footprint it reports is the whole app's, hidden.
		store, err := clipboard.Open(filepath.Join(data, "clipboard.sqlite3"))
		if err != nil {
			log.Printf("clipboard history kept in memory only: %v", err)
		}
		now := func() float64 { return float64(time.Now().UnixNano()) / 1e9 }
		if err := store.Prune(now(), clipboard.RetentionDays); err != nil {
			log.Print(err)
		}
		bd := newBoard(store, data)
		bd.ready()
		clipboard.Watch(platform.Pasteboard{}, store, now, make(chan struct{}), bd.recorded)
		p.openBoard = bd.open

		g := newGuidance(func() *permission.Rect {
			if !p.win.IsVisible() {
				return nil
			}
			b := p.win.Bounds()
			return &permission.Rect{X: float64(b.X), Y: float64(b.Y), W: float64(b.Width), H: float64(b.Height)}
		}, func() { p.rebuild(root, index) })
		g.ready()
		p.granted = platform.FullDiskAccess
		p.startGrant = g.begin
		if *measure {
			go runMeasurement(p, indexed)
		}
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

// filesRoot is the folder file search covers: FLOODLIGHT_MYGO_ROOT, so CI can
// point it at a known tree, or the home folder.
func filesRoot() string {
	if root := os.Getenv("FLOODLIGHT_MYGO_ROOT"); root != "" {
		return root
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	return home
}

// dataDir is this frontend's own folder, beside the Swift app's and the
// nanoui port's, so the three can run side by side. The measurement run gets
// a fresh temporary one, so it never reads or prunes a user's history.
func dataDir(measure bool) string {
	if measure {
		dir, err := os.MkdirTemp("", "floodlight-mygo-measure-")
		if err != nil {
			log.Fatal(err)
		}
		return dir
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	dir = filepath.Join(dir, "Floodlight MyGo")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Print(err)
	}
	return dir
}
