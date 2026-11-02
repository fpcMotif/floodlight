// Package hotkey registers system-wide shortcuts with Carbon.
//
// Carbon's RegisterEventHotKey needs no Accessibility permission, unlike an
// event tap. The handler is installed on the application event target and
// passes on any hot key it did not register, so it coexists with MyGo's own
// GlobalShortcut handler.
package hotkey

// Carbon virtual key codes and modifier masks used by Floodlight. While the
// Swift app is installed it owns ⌘Space and ⇧⌘C, so this frontend takes
// ⌥Space and ⌥⇧C.
const (
	KeySpace uint32 = 0x31
	KeyC     uint32 = 0x08
	Shift    uint32 = 1 << 9
	Option   uint32 = 1 << 11
)
