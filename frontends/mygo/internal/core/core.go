// Package core binds the Zig file index in core/ through its C ABI.
//
// Every call here is a cgo call. Callers keep them off the UI goroutine: the
// search package owns one goroutine that makes all of them.
package core

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../.build/core/include
#cgo LDFLAGS: ${SRCDIR}/../../../../.build/core/lib/libfloodlight_core.a
#include <stdlib.h>
#include "floodlight_core.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// MaxHits is the most hits one search returns; the C ABI caps it at 256.
const MaxHits = 256

// pathCap bounds a relative path. PATH_MAX on macOS is 1024.
const pathCap = 1024

// Hit is one search result: an entry id and its score.
type Hit struct {
	ID    uint32
	Score int32
}

// Index is an open, memory-mapped index. It is immutable, so concurrent
// searches are safe; Close must not race them.
type Index struct {
	h    *C.fl_index
	hits [MaxHits]C.fl_hit
	path [pathCap]C.char
}

// Build scans root and writes the index to out. It returns the entry count.
func Build(root, out string) (int, error) {
	croot, cout := C.CString(root), C.CString(out)
	defer C.free(unsafe.Pointer(croot))
	defer C.free(unsafe.Pointer(cout))
	n := int(C.fl_index_build(croot, cout))
	if n < 0 {
		return 0, fmt.Errorf("core: build %s: error %d", root, n)
	}
	return n, nil
}

// Open maps the index at path.
func Open(path string) (*Index, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	ix := &Index{}
	if rc := C.fl_index_open(cpath, &ix.h); rc != 0 {
		return nil, fmt.Errorf("core: open %s: error %d", path, rc)
	}
	return ix, nil
}

// Close unmaps the index. It is safe to call on nil.
func (ix *Index) Close() {
	if ix == nil || ix.h == nil {
		return
	}
	C.fl_index_close(ix.h)
	ix.h = nil
}

// Count returns how many entries the index holds.
func (ix *Index) Count() int { return int(C.fl_index_count(ix.h)) }

// Search writes up to len(dst) hits, best first, into dst and returns them.
// It reuses the index's own buffer, so one Index serves one goroutine.
func (ix *Index) Search(query string, dst []Hit) []Hit {
	if ix == nil || ix.h == nil || query == "" {
		return dst[:0]
	}
	limit := min(len(dst), MaxHits)
	cq := C.CString(query)
	n := int(C.fl_search(ix.h, cq, &ix.hits[0], C.uint32_t(limit)))
	C.free(unsafe.Pointer(cq))
	dst = dst[:n]
	for i := range n {
		dst[i] = Hit{ID: uint32(ix.hits[i].id), Score: int32(ix.hits[i].score)}
	}
	return dst
}

// ErrPath reports an id out of range or a path too long for the buffer.
var ErrPath = errors.New("core: no path for id")

// RelativePath returns the root-relative path of id.
func (ix *Index) RelativePath(id uint32) (string, error) {
	n := C.fl_relative_path(ix.h, C.uint32_t(id), &ix.path[0], pathCap)
	if n == 0 {
		return "", ErrPath
	}
	return C.GoStringN(&ix.path[0], C.int(n)), nil
}

// IsDir reports whether id is a directory.
func (ix *Index) IsDir(id uint32) bool { return bool(C.fl_is_dir(ix.h, C.uint32_t(id))) }
