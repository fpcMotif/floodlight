package memstat

import "testing"

func TestReadReportsResidentMemory(t *testing.T) {
	s, err := Read()
	if err != nil {
		t.Fatal(err)
	}
	if s.RSS < 1<<20 {
		t.Fatalf("RSS %d bytes is implausibly small", s.RSS)
	}
}
