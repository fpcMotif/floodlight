package hotkey

/*
#cgo LDFLAGS: -framework Carbon -framework ApplicationServices
#include "hotkey_darwin.h"
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

// kCGEventFlagMaskAlternate: the Option key in a synthesized CGEvent.
const cgOptionFlag = 0x00080000

var (
	mu       sync.Mutex
	handlers = map[uint32]func(){}
	refs     = map[uint32]unsafe.Pointer{}
	nextID   uint32
)

// Register binds keyCode with Carbon modifiers to fn and returns an id for
// Unregister. Call it on the main thread, which is where Carbon delivers the
// event and so where fn runs.
func Register(keyCode, modifiers uint32, fn func()) (uint32, error) {
	mu.Lock()
	nextID++
	id := nextID
	handlers[id] = fn
	mu.Unlock()
	var ref unsafe.Pointer
	if st := C.fl_hotkey_register(C.uint32_t(keyCode), C.uint32_t(modifiers), C.uint32_t(id), &ref); st != 0 {
		mu.Lock()
		delete(handlers, id)
		mu.Unlock()
		return 0, fmt.Errorf("hotkey: Carbon status %d (taken by another app?)", int(st))
	}
	mu.Lock()
	refs[id] = ref
	mu.Unlock()
	return id, nil
}

// Unregister releases a hot key from Register.
func Unregister(id uint32) {
	mu.Lock()
	ref := refs[id]
	delete(refs, id)
	delete(handlers, id)
	mu.Unlock()
	C.fl_hotkey_unregister(ref)
}

// PostOptionSpace synthesizes ⌥Space through the HID event tap, which is how
// the measurement mode presses the hot key. Without Accessibility trust the
// system drops it silently; the caller times out and falls back.
func PostOptionSpace() {
	C.fl_hotkey_post(C.uint32_t(KeySpace), cgOptionFlag)
}

//export flHotKeyPressed
func flHotKeyPressed(id C.uint32_t) {
	mu.Lock()
	fn := handlers[uint32(id)]
	mu.Unlock()
	if fn != nil {
		fn()
	}
}
