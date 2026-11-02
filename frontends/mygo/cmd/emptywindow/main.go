// Command emptywindow is the feasibility baseline for ADR 0012: the smallest
// MyGo app shaped like the launcher. It shows an empty panel, waits for its
// first frame, hides it, frees the heap, idles 10 s, and prints its memory as
// one FLOODLIGHT_MYGO_EMPTY JSON line.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime/debug"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/memstat"
)

func main() {
	debug.SetMemoryLimit(25 << 20)
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
	mygo.App.OnWindowAllClosed(func() {})
	frame := make(chan struct{}, 1)
	mygo.App.WhenReady(func() {
		w := mygo.NewWindow(mygo.WindowOptions{
			Title: "Empty", Panel: true, Hidden: true, Frameless: true,
			Width: 680, Height: 420, DisableResize: true,
			Content: ui.View(func(c *ui.Context) {
				c.Root().Draw(func(*ui.Painter, ui.Rect) {
					select {
					case frame <- struct{}{}:
					default:
					}
				})
			}),
		})
		w.Show()
		go func() {
			drew := true
			select {
			case <-frame:
			case <-time.After(10 * time.Second):
				drew = false
			}
			w.Hide()
			debug.FreeOSMemory()
			time.Sleep(10 * time.Second)
			s, err := memstat.Read()
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			out, _ := json.Marshal(struct {
				DrewFrame bool `json:"drew_frame"`
				memstat.Stat
			}{drew, s})
			fmt.Printf("FLOODLIGHT_MYGO_EMPTY %s\n", out)
			mygo.App.Exit(0)
		}()
	})
	if err := mygo.App.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
