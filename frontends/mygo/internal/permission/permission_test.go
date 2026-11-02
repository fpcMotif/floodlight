package permission

import (
	"testing"
	"time"
)

type recorder struct {
	granted                   bool
	opened, presented, closed int
	grants                    int
	lastPhase                 Phase
}

func (r *recorder) effects() Effects {
	return Effects{
		IsGranted:    func() bool { return r.granted },
		OpenSettings: func() { r.opened++ },
		Present:      func(p Phase) { r.presented++; r.lastPhase = p },
		Close:        func() { r.closed++ },
		OnGranted:    func() { r.grants++ },
	}
}

func TestGrantIsDetectedThenDismissed(t *testing.T) {
	r := &recorder{}
	f := New(r.effects())
	f.Begin()
	f.Begin() // a second click re-presents, it does not reopen Settings
	if f.Phase != Guiding || r.opened != 1 {
		t.Fatalf("phase %d, opened %d", f.Phase, r.opened)
	}
	t0 := time.Now()
	if !f.Tick(t0) || f.Phase != Guiding {
		t.Fatal("polling stopped before the grant")
	}
	r.granted = true
	f.Tick(t0.Add(PollInterval))
	if f.Phase != Granted || r.grants != 1 || r.lastPhase != Granted {
		t.Fatalf("phase %d, grants %d", f.Phase, r.grants)
	}
	if !f.Tick(t0.Add(PollInterval + GrantedLinger/2)) {
		t.Fatal("dismissed before the granted state lingered")
	}
	if f.Tick(t0.Add(PollInterval+GrantedLinger)) || f.Phase != Dismissed || r.closed != 1 {
		t.Fatalf("phase %d, closed %d", f.Phase, r.closed)
	}
	if r.grants != 1 {
		t.Fatalf("OnGranted ran %d times", r.grants)
	}
}

func TestBeginWithAccessSkipsSettings(t *testing.T) {
	r := &recorder{granted: true}
	New(r.effects()).Begin()
	if r.opened != 0 || r.grants != 1 {
		t.Fatalf("opened %d, grants %d", r.opened, r.grants)
	}
}

func TestAnchorStaysOnScreen(t *testing.T) {
	screen := Rect{0, 0, 1440, 900}
	settings := Rect{1300, 500, 700, 500}
	got := Anchor(&settings, nil, screen)
	if got.X+got.W > screen.W-12 || got.Y+got.H > screen.H-8 {
		t.Fatalf("panel %+v leaves the screen", got)
	}
	if mid := Anchor(nil, nil, screen); mid.X != 720-PanelW/2 || mid.Y != 900-80-PanelH {
		t.Fatalf("fallback %+v", mid)
	}
	if ShouldMove(Rect{0, 0, 1, 1}, Rect{3, 3, 1, 1}) {
		t.Error("moved for 3 points")
	}
}
