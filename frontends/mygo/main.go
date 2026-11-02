// Command floodlight-mygo is a trial Floodlight frontend in Go and MyGo's
// native UI (ADR 0012): ⌥Space shows a panel that searches applications and
// the core/ file index.
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

	"github.com/egoist/mygo"
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

	p := newPanel(*measure)
	mygo.App.OnSecondInstance(func([]string, string) { p.show() })
	mygo.App.WhenReady(func() {
		p.ready()
		indexed := p.loadIndex(filesRoot(), indexPath())
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

func indexPath() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	dir = filepath.Join(dir, "Floodlight")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Print(err)
	}
	return filepath.Join(dir, "mygo-files.flix")
}
