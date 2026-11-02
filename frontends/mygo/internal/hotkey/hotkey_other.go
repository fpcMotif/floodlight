//go:build !darwin

package hotkey

import "errors"

// Register is macOS-only; elsewhere it always fails.
func Register(keyCode, modifiers uint32, fn func()) (uint32, error) {
	return 0, errors.New("hotkey: Carbon hot keys are macOS-only")
}

// Unregister does nothing off macOS.
func Unregister(id uint32) {}

// PostOptionSpace does nothing off macOS.
func PostOptionSpace() {}
