// Package platform holds every AppKit, Carbon, CoreGraphics, ImageIO and
// Quick Look call the MyGo frontend makes that MyGo does not, behind plain Go
// functions. Domain packages never import it, so the parity fixtures run
// them headless; off macOS every call is a stub.
package platform

import (
	"os"
	"path/filepath"
)

// tccDatabase is readable only by a process with Full Disk Access, which
// makes opening it the probe. The Swift app and the nanoui port use it too.
const tccDatabase = "/Library/Application Support/com.apple.TCC/TCC.db"

// FullDiskAccess reports whether the grant is in place.
func FullDiskAccess() bool {
	f, err := os.Open(tccDatabase)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// BundlePath is the .app the running binary is inside, or "" for a bare
// development binary, which has nothing to drag into the Full Disk Access
// list.
func BundlePath() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	for dir := filepath.Dir(exe); dir != "/" && dir != "."; dir = filepath.Dir(dir) {
		if filepath.Ext(dir) == ".app" {
			return dir
		}
	}
	return ""
}
