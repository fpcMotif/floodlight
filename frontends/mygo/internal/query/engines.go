package query

import (
	"net/url"
	"strings"
)

// Engine is a web destination addressed by a first-word keyword (ADR 0006):
// `yt lofi` searches YouTube. The table matches the Swift
// KeywordEngineCatalog's web engines; the assistant engines are left out, as
// the Swift registry drops them when their CLI is missing.
type Engine struct {
	ID       string
	Title    string   // the verb phrase: "Search YouTube"
	Name     string   // the row title: "YouTube"
	Keywords []string // case-insensitive; the first is the canonical spelling
	Template string   // contains {query}
}

// Engines lists every engine; Google, the first, is the default.
var Engines = []Engine{
	{"google", "Search Google", "Google", []string{"g", "google", "!g"}, "https://www.google.com/search?q={query}"},
	// No single-letter "w": it starts too many natural queries.
	{"wikipedia", "Search Wikipedia", "Wikipedia", []string{"wiki", "wikipedia", "!wiki"}, "https://en.wikipedia.org/wiki/Special:Search?search={query}"},
	{"github", "Search GitHub", "GitHub", []string{"gh", "github", "!gh"}, "https://github.com/search?q={query}"},
	{"stackoverflow", "Search Stack Overflow", "Stack Overflow", []string{"so", "stackoverflow", "!so"}, "https://stackoverflow.com/search?q={query}"},
	{"twitter", "Search Twitter/X", "Twitter/X", []string{"x", "twitter", "!x"}, "https://x.com/search?q={query}"},
	{"youtube", "Search YouTube", "YouTube", []string{"yt", "youtube", "!yt"}, "https://www.youtube.com/results?search_query={query}"},
}

// DefaultEngine is the engine nothing else addresses.
var DefaultEngine = Engines[0]

// EngineByID returns the engine with id.
func EngineByID(id string) (Engine, bool) {
	for _, e := range Engines {
		if e.ID == id {
			return e, true
		}
	}
	return Engine{}, false
}

// EngineFor returns the engine keyword names, case-insensitively.
func EngineFor(keyword string) (Engine, bool) {
	k := strings.ToLower(keyword)
	for _, e := range Engines {
		for _, w := range e.Keywords {
			if w == k {
				return e, true
			}
		}
	}
	return Engine{}, false
}

// URL is the engine's results page for q. Every web row derives its URL
// here, so the keyword row, the fallback row and web mode cannot disagree.
func (e Engine) URL(q string) string {
	return strings.ReplaceAll(e.Template, "{query}", escape(q))
}

// Host is where the engine goes, read from its template: the row subtitle.
func (e Engine) Host() string {
	u, err := url.Parse(strings.ReplaceAll(e.Template, "{query}", ""))
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(u.Hostname(), "www.")
}

// escape percent-encodes everything but ALPHA, DIGIT and -._~, the set the
// Swift engine allows in a query value.
func escape(q string) string {
	var b strings.Builder
	const hex = "0123456789ABCDEF"
	for i := 0; i < len(q); i++ {
		c := q[i]
		if isLetter(c) || '0' <= c && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~' {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&15])
	}
	return b.String()
}

// ParseAddress splits q into its first whitespace-delimited token and the
// trimmed remainder; false when q is blank.
func ParseAddress(q string) (keyword, rest string, ok bool) {
	t := strings.TrimLeft(q, " \t\n")
	if t == "" {
		return "", "", false
	}
	i := strings.IndexAny(t, " \t\n")
	if i < 0 {
		return t, "", true
	}
	return t[:i], strings.TrimSpace(t[i:]), true
}

// Addressed is the engine a keyword query names and the text to search it
// for: `yt lofi` → YouTube, "lofi". An empty remainder is not an address,
// since there is nothing to search for yet.
func Addressed(q string) (Engine, string, bool) {
	k, rest, ok := ParseAddress(q)
	if !ok || rest == "" {
		return Engine{}, "", false
	}
	e, ok := EngineFor(k)
	return e, rest, ok
}
