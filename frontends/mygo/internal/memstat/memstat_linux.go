package memstat

import (
	"bufio"
	"errors"
	"os"
	"strconv"
	"strings"
)

// Read returns VmRSS from /proc. Linux has no phys_footprint.
func Read() (Stat, error) {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return Stat{}, err
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if rest, ok := strings.CutPrefix(s.Text(), "VmRSS:"); ok {
			kb, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64)
			if err != nil {
				return Stat{}, err
			}
			return Stat{RSS: kb << 10}, nil
		}
	}
	return Stat{}, errors.New("memstat: no VmRSS")
}
