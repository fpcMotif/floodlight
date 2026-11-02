//go:build !darwin

package platform

import (
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/permission"
)

// Off macOS there is no pasteboard to watch and no app to paste into. The
// stubs keep the frontend building, so its domain tests and headless view
// tests run on a Linux CI runner.

type Pasteboard struct{}

func (Pasteboard) ChangeCount() int           { return 0 }
func (Pasteboard) Read() clipboard.Pasteboard { return clipboard.Pasteboard{} }
func WriteEntry(clipboard.Entry, []byte)      {}
func WriteText(string)                        {}
func FrontmostPID() int                       { return 0 }
func FrontmostBundle() string                 { return "" }
func AppName(string) string                   { return "" }
func AccessibilityTrusted(bool) bool          { return false }
func PasteInto(int) bool                      { return false }
func ToggleQuickLook(string)                  {}
func QuickLookVisible() bool                  { return false }
func CloseQuickLook()                         {}
func ReduceTransparency() bool                { return false }
func ReleaseMemory()                          {}
func SettingsWindow() (permission.Rect, bool) { return permission.Rect{}, false }
func OpenFullDiskAccessSettings()             {}
func IconPNG(string, int) []byte              { return nil }
func ConfigurePanel(uintptr)                  {}
