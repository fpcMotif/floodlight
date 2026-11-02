package platform

/*
#cgo CFLAGS: -fobjc-arc
#cgo LDFLAGS: -framework AppKit -framework ApplicationServices -framework Carbon -framework ImageIO -framework Quartz -framework QuartzCore
#include <stdlib.h>
#include "platform_darwin.h"
*/
import "C"

import (
	"strings"
	"unsafe"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/permission"
)

func lines(p *C.char) []string {
	if p == nil {
		return nil
	}
	s := C.GoString(p)
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func goString(p *C.char) string {
	if p == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(p))
	return C.GoString(p)
}

// Pasteboard is the general pasteboard as clipboard.Watch reads it.
type Pasteboard struct{}

// ChangeCount is NSPasteboard's change count.
func (Pasteboard) ChangeCount() int { return int(C.fl_pb_change_count()) }

// Read takes what the pasteboard holds now, files first, then an image
// with its thumbnail, then text, and names the app in front as its source.
func (Pasteboard) Read() clipboard.Pasteboard {
	var raw C.fl_pasteboard
	C.fl_pb_read(&raw, C.long(clipboard.MaxTextBytes), C.long(clipboard.MaxImageBytes), C.int(clipboard.ThumbnailPx))
	defer C.fl_pb_free(&raw)
	pb := clipboard.Pasteboard{Types: lines(raw.types), Files: lines(raw.files), Source: FrontmostBundle()}
	if raw.text != nil {
		pb.Text = C.GoString(raw.text)
	}
	if raw.png != nil && raw.png_len > 0 {
		name := "PNG Image"
		if raw.is_tiff != 0 {
			name = "TIFF Image"
		}
		if pb.Source == "com.apple.screencapture" || pb.Source == "com.apple.screencaptureui" {
			name = "Screenshot"
		}
		pb.Image = &clipboard.Image{
			Name: name, PNG: C.GoBytes(raw.png, C.int(raw.png_len)),
			Width: int(raw.width), Height: int(raw.height),
		}
		if raw.thumb != nil {
			pb.Image.Thumbnail = C.GoBytes(raw.thumb, C.int(raw.thumb_len))
		}
	}
	return pb
}

// WriteEntry puts an entry back on the pasteboard, marked as our own write
// so capture skips it.
func WriteEntry(e clipboard.Entry, png []byte) {
	switch {
	case e.Kind == clipboard.KindFile:
		cs := C.CString(e.Text)
		C.fl_pb_write_files(cs)
		C.free(unsafe.Pointer(cs))
	case e.Kind == clipboard.KindImage && len(png) > 0:
		C.fl_pb_write_png(unsafe.Pointer(&png[0]), C.long(len(png)))
	default:
		WriteText(e.Text)
	}
}

// WriteText copies text, marked as our own write.
func WriteText(s string) {
	cs := C.CString(s)
	C.fl_pb_write_text(cs)
	C.free(unsafe.Pointer(cs))
}

// FrontmostPID is the process of the app in front: the paste target.
func FrontmostPID() int { return int(C.fl_frontmost_pid()) }

// FrontmostBundle is the bundle id of the app in front.
func FrontmostBundle() string { return goString(C.fl_frontmost_bundle()) }

// AppName is what Launch Services calls the app with bundleID.
func AppName(bundleID string) string {
	cs := C.CString(bundleID)
	defer C.free(unsafe.Pointer(cs))
	return goString(C.fl_app_name(cs))
}

// AccessibilityTrusted reports whether posting ⌘V to another app is
// allowed; with prompt, the system shows its Accessibility prompt.
func AccessibilityTrusted(prompt bool) bool { return bool(C.fl_ax_trusted(C.bool(prompt))) }

// PasteInto activates pid and types ⌘V into it. It blocks while the app
// comes forward, so call it off the main thread.
func PasteInto(pid int) bool { return bool(C.fl_paste_into(C.int(pid))) }

// ToggleQuickLook shows path in Quick Look, or closes Quick Look when it is
// up. Main thread.
func ToggleQuickLook(path string) {
	cs := C.CString(path)
	C.fl_quicklook_toggle(cs)
	C.free(unsafe.Pointer(cs))
}

// QuickLookVisible reports whether the Quick Look panel is up.
func QuickLookVisible() bool { return bool(C.fl_quicklook_visible()) }

// CloseQuickLook hides Quick Look and lets go of its item.
func CloseQuickLook() { C.fl_quicklook_close() }

// ReduceTransparency is the Accessibility setting.
func ReduceTransparency() bool { return bool(C.fl_reduce_transparency()) }

// ReleaseMemory returns freed malloc pages to the system.
func ReleaseMemory() { C.fl_release_memory() }

// SettingsWindow is System Settings' window, when it is on screen.
func SettingsWindow() (permission.Rect, bool) {
	var x, y, w, h C.double
	if !C.fl_settings_window(&x, &y, &w, &h) {
		return permission.Rect{}, false
	}
	return permission.Rect{X: float64(x), Y: float64(y), W: float64(w), H: float64(h)}, true
}

// OpenFullDiskAccessSettings opens System Settings at the Full Disk Access
// list.
func OpenFullDiskAccessSettings() { C.fl_open_fda_settings() }

// IconPNG is the Finder icon of path, px pixels square.
func IconPNG(path string, px int) []byte {
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	var n C.long
	p := C.fl_icon_png(cs, C.int(px), &n)
	if p == nil {
		return nil
	}
	defer C.free(p)
	return C.GoBytes(p, C.int(n))
}

// ConfigurePanel puts a launcher window at status level on every Space and
// keeps its drawn frame at its visual top while it resizes. handle
// is MyGo's Window.NativeHandle, an NSWindow.
func ConfigurePanel(handle uintptr) { C.fl_configure_panel(C.uintptr_t(handle)) }
