package clipboard

import (
	"log"
	"time"
)

// PollInterval is how often the capture loop asks the pasteboard whether
// it changed. macOS has no change notification; the Swift app polls too.
const PollInterval = 500 * time.Millisecond

// Source is the pasteboard as the capture loop sees it. The platform layer
// implements it on NSPasteboard; tests feed it by hand.
type Source interface {
	ChangeCount() int
	Read() Pasteboard
}

// Watch polls src on its own goroutine until stop closes, recording each
// change into store. recorded, if not nil, runs on that goroutine after a
// change is stored, so an open board can refresh.
func Watch(src Source, store *Store, now func() float64, stop <-chan struct{}, recorded func([]Entry)) {
	// The baseline is read before Watch returns: a copy made after the call
	// must count as a change, and what was on the pasteboard before it is
	// not a new copy.
	last := src.ChangeCount()
	go func() {
		t := time.NewTicker(PollInterval)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
			}
			if n := src.ChangeCount(); n != last {
				last = n
				if es := Ingest(src.Read(), store, now()); len(es) > 0 && recorded != nil {
					recorded(es)
				}
			}
		}
	}()
}

// Ingest decides one pasteboard reading against the newest entry and
// stores what it keeps.
func Ingest(pb Pasteboard, store *Store, now float64) []Entry {
	caps, skip := Decide(pb, store.Newest())
	if skip != Recorded {
		return nil
	}
	es, err := store.Record(caps, pb.Source, now)
	if err != nil {
		log.Print(err)
	}
	return es
}
