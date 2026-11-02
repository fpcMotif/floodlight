// Package clipboard is the clipboard history: what a copy records, how an
// entry is classified and named (ADR 0009), the SQLite store, and the board's
// list and keys. It calls no OS API; the platform package reads and writes
// the pasteboard and hands this package plain values.
package clipboard

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Kind is what an entry holds.
type Kind string

const (
	KindText  Kind = "text"
	KindFile  Kind = "file"
	KindImage Kind = "image"
)

// Content is what a text entry holds, decided from its characters alone.
type Content string

const (
	Plain Content = "plain"
	Link  Content = "link"
	Color Content = "color"
	Code  Content = "code"
	Path  Content = "path"
)

// Classification is a text entry's content and the one fact it carries: a
// link's domain, a colour as #RRGGBB[AA], a code language, or a path as a
// file:// URL. It is the Swift store's content_kind and content_detail pair.
type Classification struct {
	Content Content
	Detail  string
}

// Entry is one row of the Swift app's clipboard_entries table.
type Entry struct {
	ID        string
	Kind      Kind
	Text      string // the text; a file's path; an image's name
	CreatedAt float64
	SourceID  string   // the bundle id of the app the copy came from
	PinnedAt  *float64 // nil when not pinned
	Class     Classification
	ImageHash string
	Width     int
	Height    int
	ByteCount int
	Thumbnail []byte // PNG, 128 px on its long side
}

// Pinned reports whether the entry is pinned.
func (e Entry) Pinned() bool { return e.PinnedAt != nil }

// Classify is the one classifier, the Swift ClipboardTextContent.classify:
// a single-line local path, then an http(s) link, then a hex colour, then
// code, else plain.
func Classify(text string) Classification {
	t := strings.TrimSpace(text)
	if p, ok := localPath(t); ok {
		return Classification{Path, (&url.URL{Scheme: "file", Path: p}).String()}
	}
	if d, ok := linkDomain(t); ok {
		return Classification{Link, d}
	}
	if c, ok := ParseColor(t); ok {
		return Classification{Color, c.Hex()}
	}
	if lang, ok := codeLanguage(t); ok {
		return Classification{Code, lang}
	}
	return Classification{Content: Plain}
}

// Home is the folder ~ expands to. A variable so tests and fixtures can
// pin it.
var Home = func() string { h, _ := os.UserHomeDir(); return h }

func localPath(t string) (string, bool) {
	if t == "" || strings.ContainsAny(t, "\r\n\u0085  ") {
		return "", false
	}
	switch {
	case strings.HasPrefix(t, "file://"):
		u, err := url.Parse(t)
		if err != nil || u.Scheme != "file" || u.Path == "" {
			return "", false
		}
		return u.Path, true
	case strings.HasPrefix(t, "~/"):
		return filepath.Join(Home(), t[2:]), true
	case strings.HasPrefix(t, "/"):
		return t, true
	}
	return "", false
}

func linkDomain(t string) (string, bool) {
	if !strings.HasPrefix(t, "http://") && !strings.HasPrefix(t, "https://") {
		return "", false
	}
	u, err := url.Parse(t)
	if err != nil || u.Hostname() == "" {
		return "", false
	}
	return strings.TrimPrefix(u.Hostname(), "www."), true
}

// RGBA is a decoded hex colour; A is -1 when the hex had no alpha.
type RGBA struct{ R, G, B, A int }

// ParseColor reads #RGB, #RRGGBB or #RRGGBBAA, ASCII hex only.
func ParseColor(t string) (RGBA, bool) {
	t = strings.TrimSpace(t)
	if !strings.HasPrefix(t, "#") {
		return RGBA{}, false
	}
	h := t[1:]
	if len(h) != 3 && len(h) != 6 && len(h) != 8 {
		return RGBA{}, false
	}
	var v uint64
	for i := 0; i < len(h); i++ {
		d, ok := hexDigit(h[i])
		if !ok {
			return RGBA{}, false
		}
		v = v<<4 | uint64(d)
	}
	switch len(h) {
	case 3:
		return RGBA{int(v>>8&15) * 17, int(v>>4&15) * 17, int(v&15) * 17, -1}, true
	case 6:
		return RGBA{int(v >> 16 & 255), int(v >> 8 & 255), int(v & 255), -1}, true
	}
	return RGBA{int(v >> 24 & 255), int(v >> 16 & 255), int(v >> 8 & 255), int(v & 255)}, true
}

func hexDigit(c byte) (byte, bool) {
	switch {
	case '0' <= c && c <= '9':
		return c - '0', true
	case 'a' <= c && c <= 'f':
		return c - 'a' + 10, true
	case 'A' <= c && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// Hex is the stored form, #RRGGBB or #RRGGBBAA.
func (c RGBA) Hex() string {
	if c.A < 0 {
		return fmt.Sprintf("#%02X%02X%02X", c.R, c.G, c.B)
	}
	return fmt.Sprintf("#%02X%02X%02X%02X", c.R, c.G, c.B, c.A)
}

// RGB is the inspector's rgb() or rgba() line.
func (c RGBA) RGB() string {
	if c.A < 0 {
		return fmt.Sprintf("rgb(%d, %d, %d)", c.R, c.G, c.B)
	}
	return fmt.Sprintf("rgba(%d, %d, %d, %.2f)", c.R, c.G, c.B, float64(c.A)/255)
}

// codeMarkers each carry their trailing space, which keeps "funcs" and
// "classy" from matching.
var codeMarkers = []string{"func ", "struct ", "import ", "class ", "const ", "function ", "export "}

func codeLanguage(t string) (string, bool) {
	if (strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}")) || (strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]")) {
		if json.Valid([]byte(t)) {
			return "JSON", true
		}
	}
	for _, m := range codeMarkers {
		if strings.Contains(t, m) {
			return "Code", true
		}
	}
	if strings.HasPrefix(t, "<!DOCTYPE") || strings.HasPrefix(t, "<html") ||
		(strings.HasPrefix(t, "<") && strings.HasSuffix(t, ">") && strings.Contains(t, "</")) {
		return "HTML", true
	}
	return "", false
}

// FilePath is the file an entry names: a copied file, or text classified
// as a path.
func (e Entry) FilePath() (string, bool) {
	switch {
	case e.Kind == KindFile:
		return e.Text, true
	case e.Kind == KindText && e.Class.Content == Path:
		u, err := url.Parse(e.Class.Detail)
		if err == nil && u.Path != "" {
			return u.Path, true
		}
	}
	return "", false
}

// Title is the row's title: a file's name, an image's name, or the text on
// one line.
func (e Entry) Title() string {
	if p, ok := e.FilePath(); ok {
		if name := filepath.Base(p); name != "" && name != "." {
			return name
		}
		return e.Text
	}
	if e.Kind == KindImage {
		if e.Text == "" {
			return "Image"
		}
		return e.Text
	}
	return OneLine(e.Text)
}

// Subtitle is "{App} · {age}", then the parent folder or the image's size,
// as every Swift clipboard row reads.
func (e Entry) Subtitle(now float64, appName func(bundleID string) string) string {
	head := appName(e.SourceID) + " · " + Age(now-e.CreatedAt)
	var detail string
	if p, ok := e.FilePath(); ok {
		if parent := filepath.Base(filepath.Dir(p)); parent != "/" && parent != "." {
			detail = parent
		}
	} else if e.Kind == KindImage && e.Width > 0 {
		detail = fmt.Sprintf("%d×%d", e.Width, e.Height)
	}
	if detail == "" {
		return head
	}
	return head + " · " + detail
}

// knownSources are the bundle ids Launch Services names badly.
var knownSources = map[string]string{"com.apple.screencaptureui": "Screenshot", "com.apple.finder": "Finder"}

// SourceName names a source app as the Swift board does when Launch
// Services cannot: the known table, else the bundle id's last component.
// lookup, if not nil, is asked between the two.
func SourceName(bundleID string, lookup func(string) string) string {
	if bundleID == "" {
		return "Clipboard"
	}
	if n, ok := knownSources[bundleID]; ok {
		return n
	}
	if lookup != nil {
		if n := lookup(bundleID); n != "" {
			return n
		}
	}
	if i := strings.LastIndexByte(bundleID, '.'); i >= 0 && i < len(bundleID)-1 {
		return bundleID[i+1:]
	}
	return bundleID
}

// OneLine joins the text's lines with single spaces, drops empty ones and
// trims the ends; "(Empty text)" when nothing is left.
func OneLine(text string) string {
	var b strings.Builder
	pending := false
	for _, r := range text {
		switch r {
		case '\n', '\r', '\u000B', '\u000C', '\u0085', ' ', ' ':
			pending = b.Len() > 0
			continue
		}
		if pending {
			b.WriteByte(' ')
			pending = false
		}
		b.WriteRune(r)
	}
	s := strings.Trim(b.String(), " \t")
	if s == "" {
		return "(Empty text)"
	}
	return s
}

// Age is the row's relative time: "just now", "5m", "3h", "2d", "4mo", "1y".
func Age(seconds float64) string {
	s := int(max(0, seconds))
	switch {
	case s < 60:
		return "just now"
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	case s < 86400:
		return fmt.Sprintf("%dh", s/3600)
	}
	days := s / 86400
	switch {
	case days < 30:
		return fmt.Sprintf("%dd", days)
	case days/30 < 12:
		return fmt.Sprintf("%dmo", days/30)
	}
	return fmt.Sprintf("%dy", days/365)
}

// Counts are the inspector's character, word and line counts.
type Counts struct{ Characters, Words, Lines int }

// CountText counts runes, whitespace-separated words and lines.
func CountText(text string) Counts {
	return Counts{utf8.RuneCountInString(text), len(strings.Fields(text)), strings.Count(text, "\n") + 1}
}

// FileType is the inspector's Type for a file, from its extension.
func FileType(path string, isDir bool) string {
	if isDir {
		return "Folder"
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	for _, t := range fileTypes {
		for _, e := range t.exts {
			if e == ext {
				return t.name
			}
		}
	}
	if ext == "" {
		return "File"
	}
	return strings.ToUpper(ext)
}

var fileTypes = []struct {
	name string
	exts []string
}{
	{"Video", []string{"mp4", "mov", "m4v", "webm", "mkv", "avi"}},
	{"Image", []string{"png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "svg"}},
	{"JSON", []string{"json"}},
	{"Markdown", []string{"md", "markdown", "mdown", "mkdn"}},
	{"Plain Text", []string{"txt", "text"}},
	{"Source Code", []string{"swift", "rs", "ts", "js", "py", "go", "c", "cpp", "h", "sh"}},
	{"Archive", []string{"zip", "tar", "gz", "dmg"}},
}

// FormatBytes is a size as Finder shows it: decimal units, one decimal
// place past bytes.
func FormatBytes(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d bytes", n)
	}
	v, units := float64(n), []string{"KB", "MB", "GB", "TB"}
	for _, u := range units {
		v /= 1000
		if v < 1000 || u == "TB" {
			return fmt.Sprintf("%.1f %s", v, u)
		}
	}
	return ""
}
