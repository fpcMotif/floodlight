package clipboard

import (
	"crypto/sha256"
	"encoding/hex"
	"slices"
)

// Limits a capture must fit, the Swift capture service's.
const (
	MaxTextBytes  = 32_000
	MaxImageBytes = 15 << 20
	RetentionDays = 30
	ThumbnailPx   = 128
)

// OwnWriteType marks Floodlight's own pasteboard writes, the Swift app's
// marker, so that pasting an old entry never records it again.
const OwnWriteType = "com.floodlight.own-write"

// skippedTypes are what history never records: our own writes, and what
// password managers and the system mark concealed, transient or sensitive.
var skippedTypes = []string{OwnWriteType, "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.apple.is-sensitive"}

// Pasteboard is what the pasteboard held at one change: its types, then
// what a reader found, files first, then an image, then text. The platform
// layer fills it; nothing here reads the system.
type Pasteboard struct {
	Types  []string
	Files  []string
	Image  *Image
	Text   string
	Source string // the frontmost app's bundle id when the copy was seen
}

// Image is a copied picture: PNG bytes, its size, and a thumbnail.
type Image struct {
	Name          string // "PNG Image", "TIFF Image", "Screenshot"
	PNG           []byte
	Width, Height int
	Thumbnail     []byte
}

// Skip says why a copy was not recorded.
type Skip string

const (
	Recorded  Skip = ""
	Concealed Skip = "concealed"
	OwnWrite  Skip = "own write"
	Repeat    Skip = "repeat"
	TooLarge  Skip = "too large"
	Empty     Skip = "empty"
)

// Capture is what a copy would add to history.
type Capture struct {
	Kind  Kind
	Text  string // text, a file path, or an image's name
	Image *Image
}

// Decide turns one pasteboard change into the captures history should
// store, or the reason it stores none. newest is the most recent entry, so a
// copy that repeats it is skipped.
func Decide(pb Pasteboard, newest *Entry) ([]Capture, Skip) {
	for _, t := range skippedTypes {
		if slices.Contains(pb.Types, t) {
			if t == OwnWriteType {
				return nil, OwnWrite
			}
			return nil, Concealed
		}
	}
	var caps []Capture
	switch {
	case len(pb.Files) > 0:
		for _, f := range slices.Compact(slices.Clone(pb.Files)) {
			caps = append(caps, Capture{Kind: KindFile, Text: f})
		}
	case pb.Image != nil:
		if len(pb.Image.PNG) > MaxImageBytes {
			return nil, TooLarge
		}
		caps = []Capture{{Kind: KindImage, Text: pb.Image.Name, Image: pb.Image}}
	case pb.Text != "":
		if len(pb.Text) > MaxTextBytes {
			return nil, TooLarge
		}
		caps = []Capture{{Kind: KindText, Text: pb.Text}}
	default:
		return nil, Empty
	}
	if newest != nil && len(caps) == 1 && caps[0].repeats(*newest) {
		return nil, Repeat
	}
	return caps, Recorded
}

func (c Capture) repeats(e Entry) bool {
	if c.Kind != e.Kind {
		return false
	}
	if c.Kind == KindImage {
		return e.ImageHash != "" && e.ImageHash == ImageHash(c.Image.PNG)
	}
	return c.Text == e.Text
}

// ImageHash identifies an image by its bytes, as the Swift store's
// image_hash column does.
func ImageHash(png []byte) string {
	sum := sha256.Sum256(png)
	return hex.EncodeToString(sum[:])
}
