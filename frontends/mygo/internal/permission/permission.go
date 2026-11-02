// Package permission is the Full Disk Access grant flow: open System
// Settings at the list, float a guidance panel under its window that holds
// the app to drag in, poll for the grant, show it granted, then go. A port
// of the Swift FullDiskAccessGrantCoordinator and GuidancePanelAnchorPolicy.
//
// The flow calls the system only through Effects, so tests drive it with
// counters and a fake clock.
package permission

import (
	"math"
	"time"
)

// Phase is where the flow is.
type Phase uint8

const (
	Idle Phase = iota
	Guiding
	Granted
	Dismissed
)

// Timing, the Swift coordinator's.
const (
	PollInterval  = 500 * time.Millisecond
	GrantedLinger = 1500 * time.Millisecond
)

// Effects is what the flow asks of the system. The shell wires these to the
// platform layer.
type Effects struct {
	IsGranted    func() bool
	OpenSettings func()
	// Present shows the guidance panel, or moves it to follow System
	// Settings' window.
	Present func(Phase)
	Close   func()
	// OnGranted runs once, when the grant is first seen: the shell rebuilds
	// the index, since folders the scan skipped are open now.
	OnGranted func()
}

// Flow is one grant attempt. Its methods run on the main thread.
type Flow struct {
	Phase     Phase
	fx        Effects
	grantedAt time.Time
}

// New makes an idle flow.
func New(fx Effects) *Flow { return &Flow{fx: fx} }

// Begin starts guiding, unless access is already there.
func (f *Flow) Begin() {
	if f.fx.IsGranted() {
		f.grant(time.Now())
		return
	}
	if f.Phase != Guiding {
		f.Phase = Guiding
		f.fx.OpenSettings()
	}
	f.fx.Present(Guiding)
}

// Tick is the poll: it detects the grant, keeps the panel under System
// Settings, and dismisses it once the granted state has lingered. It
// reports whether the flow wants another tick.
func (f *Flow) Tick(now time.Time) bool {
	switch f.Phase {
	case Guiding:
		if f.fx.IsGranted() {
			f.grant(now)
			return true
		}
		f.fx.Present(Guiding)
		return true
	case Granted:
		if now.Sub(f.grantedAt) >= GrantedLinger {
			f.Dismiss()
			return false
		}
		return true
	}
	return false
}

func (f *Flow) grant(now time.Time) {
	f.Phase, f.grantedAt = Granted, now
	f.fx.Present(Granted)
	f.fx.OnGranted()
}

// Dismiss closes the panel, granted or not.
func (f *Flow) Dismiss() {
	f.fx.Close()
	f.Phase = Dismissed
}

// Rect is in screen points with the origin at the top left of the primary
// display and y growing down: MyGo's window coordinates, and the bounds
// CGWindowList reports, so no flip is needed between them.
type Rect struct{ X, Y, W, H float64 }

func (r Rect) midX() float64   { return r.X + r.W/2 }
func (r Rect) bottom() float64 { return r.Y + r.H }

// PanelW and PanelH are the guidance panel's size.
const PanelW, PanelH = 380.0, 110.0

// Anchor places the guidance panel just under System Settings' window,
// overlapping its bottom edge, when it is on screen; else under the panel
// that started the flow; else low on the screen; always inside the screen.
func Anchor(target, parent *Rect, screen Rect) Rect {
	var r Rect
	switch {
	case target != nil:
		r = Rect{target.midX() - PanelW/2, target.bottom() - 20, PanelW, PanelH}
	case parent != nil:
		r = Rect{parent.midX() - PanelW/2, parent.bottom() - 16, PanelW, PanelH}
	default:
		r = Rect{screen.midX() - PanelW/2, screen.bottom() - 80 - PanelH, PanelW, PanelH}
	}
	r.X = clamp(r.X, screen.X+12, screen.X+screen.W-r.W-12)
	r.Y = clamp(r.Y, screen.Y+8, screen.bottom()-r.H-8)
	return r
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(v, hi)) }

// ShouldMove is true past a few points, so polling never jitters the panel.
func ShouldMove(from, to Rect) bool {
	return math.Abs(to.X-from.X) > 4 || math.Abs(to.Y-from.Y) > 4
}
