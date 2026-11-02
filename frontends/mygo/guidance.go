package main

import (
	"log"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/permission"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/platform"
)

var (
	checkIcon = svg(`<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>`)
	arrowUp   = svg(`<path d="M12 19V5M5 12l7-7 7 7"/>`)
	closeIcon = svg(`<path d="M18 6 6 18M6 6l12 12"/>`)
)

// guidance is the panel that floats under System Settings with the app to
// drag into the Full Disk Access list.
type guidance struct {
	win    *mygo.Window
	flow   *permission.Flow
	bundle string
	icon   *ui.Bitmap
	phase  permission.Phase
	at     permission.Rect
	parent func() *permission.Rect
	stop   chan struct{}
}

// newGuidance wires the grant flow to the platform. granted runs on the
// main thread once access is first seen.
func newGuidance(parent func() *permission.Rect, granted func()) *guidance {
	g := &guidance{bundle: platform.BundlePath(), parent: parent}
	g.flow = permission.New(permission.Effects{
		IsGranted:    platform.FullDiskAccess,
		OpenSettings: platform.OpenFullDiskAccessSettings,
		Present:      g.present,
		Close:        g.close,
		OnGranted:    granted,
	})
	return g
}

func (g *guidance) ready() {
	g.win = mygo.NewWindow(mygo.WindowOptions{
		Title:         "Full Disk Access",
		Panel:         true,
		Hidden:        true,
		Frameless:     true,
		Transparent:   true,
		Vibrancy:      mygo.VibrancyGlass,
		CornerRadius:  16,
		Width:         guidanceWidth,
		Height:        guidanceHeight,
		DisableResize: true,
		Content:       ui.View(g.view),
	})
	g.win.SetAlwaysOnTop(true)
	g.win.SetVisibleOnAllWorkspaces(true)
	g.win.OnClose(func(e *mygo.CloseEvent) {
		e.PreventDefault()
		g.flow.Dismiss()
	})
}

// begin starts the flow and polls it every half second on the main thread
// until it stops asking.
func (g *guidance) begin() {
	if g.bundle == "" {
		log.Print("Full Disk Access: not running from an app bundle; nothing to drag into the list")
	}
	g.flow.Begin()
	if g.stop != nil || g.flow.Phase == permission.Dismissed {
		return
	}
	g.stop = make(chan struct{})
	go func(stop chan struct{}) {
		t := time.NewTicker(permission.PollInterval)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case now := <-t.C:
				g.win.Update(func() {
					if !g.flow.Tick(now) && g.stop != nil {
						close(g.stop)
						g.stop = nil
					}
				})
			}
		}
	}(g.stop)
}

// present places the panel under System Settings, moving it only when the
// window moved, and shows it.
func (g *guidance) present(phase permission.Phase) {
	g.phase = phase
	d := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint())
	screen := permission.Rect{X: float64(d.WorkArea.X), Y: float64(d.WorkArea.Y), W: float64(d.WorkArea.Width), H: float64(d.WorkArea.Height)}
	var target *permission.Rect
	if r, ok := platform.SettingsWindow(); ok {
		target = &r
	}
	to := permission.Anchor(target, g.parent(), screen)
	if !g.win.IsVisible() || permission.ShouldMove(g.at, to) {
		g.at = to
		g.win.SetPosition(int(to.X), int(to.Y))
	}
	if !g.win.IsVisible() {
		g.win.ShowInactive()
	}
	g.win.Invalidate()
}

func (g *guidance) close() {
	g.win.Hide()
	g.icon = nil
}

func (g *guidance) appName() string {
	if g.bundle == "" {
		return "Floodlight"
	}
	return strings.TrimSuffix(filepath.Base(g.bundle), ".app")
}

func (g *guidance) view(c *ui.Context) {
	t := c.Theme()
	root := c.Root()
	if c.Vibrancy() {
		root.Background(ui.Transparent)
	} else {
		root.Background(t.Background)
	}
	ui.Column(c).Fill().PaddingX(14).PaddingY(12).Gap(8).Radius(16).Border(1, t.Text.Alpha(0.1)).Children(func() {
		if g.phase == permission.Granted {
			ui.Row(c).Fill().Gap(10).AlignItems(ui.Center).PaddingX(8).Children(func() {
				ui.Icon(c, checkIcon).FontSize(24).TextColor(t.Success)
				ui.Column(c).Gap(2).Children(func() {
					ui.Text(c, "Full Disk Access Granted").FontSize(13.5).Bold().TextColor(t.Text)
					ui.Text(c, "You're ready to search everywhere.").FontSize(11).TextColor(t.TextMuted)
				})
			})
			return
		}
		name := g.appName()
		ui.Row(c).FillWidth().Gap(6).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, arrowUp).FontSize(11.5).TextColor(t.Accent)
			ui.Text(c, "Drag "+name+" into the Full Disk Access list").FontSize(12.5).FontWeight(500).TextColor(t.Text).SingleLine().Grow(1)
			x := ui.ButtonBase(c).Label("Close").Size(16, 16).Center()
			x.Children(func() { ui.Icon(c, closeIcon).FontSize(10).TextColor(t.TextMuted) })
			if x.Clicked() {
				g.flow.Dismiss()
			}
		})
		card := ui.Row(c).FillWidth().Height(34).PaddingX(10).Gap(8).AlignItems(ui.Center).Radius(8).Background(t.TextMuted.Alpha(0.12)).Label(name)
		if g.bundle != "" {
			if data, err := transfer.FileData(g.bundle); err == nil {
				card.DragData(data, transfer.DragOptions{Operations: transfer.Copy})
			}
		}
		card.Children(func() {
			if g.icon == nil && g.bundle != "" {
				if png := platform.IconPNG(g.bundle, 44); png != nil {
					g.icon, _ = ui.DecodeBitmap(png)
				}
			}
			if g.icon != nil {
				ui.Image(c, g.icon).Size(22, 22)
			}
			ui.Text(c, name).FontSize(12).FontWeight(500).TextColor(t.Text).Grow(1)
		})
		ui.Text(c, "Or click + in System Settings and choose "+name).FontSize(10.5).TextColor(t.TextMuted)
	})
}
