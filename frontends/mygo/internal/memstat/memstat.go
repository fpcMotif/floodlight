// Package memstat reads this process's memory as the OS accounts for it.
package memstat

// Stat is a snapshot of the process's memory, in bytes.
type Stat struct {
	RSS uint64 `json:"rss"`
	// Footprint is phys_footprint on macOS: what Activity Monitor shows and
	// what memory pressure acts on. Zero elsewhere.
	Footprint uint64 `json:"phys_footprint"`
}
