// Package apps finds application bundles on disk and ranks them by name.
package apps

import (
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// App is an application bundle.
type App struct {
	Name string // the bundle's file name without .app
	Path string
	key  string // Name, lowercased once at scan time
}

// Dirs returns the folders macOS installs applications into, the user's own
// included.
func Dirs() []string {
	dirs := []string{"/Applications", "/System/Applications"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}
	return dirs
}

// Scan lists the .app bundles in dirs and one folder below them, where
// /Applications/Utilities and vendor folders keep theirs. A missing folder is
// skipped, not an error: ~/Applications usually does not exist.
func Scan(dirs []string) []App {
	var found []App
	for _, dir := range dirs {
		found = scanDir(dir, 1, found)
	}
	slices.SortFunc(found, func(a, b App) int { return cmp.Compare(a.key, b.key) })
	return slices.CompactFunc(found, func(a, b App) bool { return a.Path == b.Path })
}

func scanDir(dir string, depth int, found []App) []App {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return found
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		path := filepath.Join(dir, name)
		if base, ok := strings.CutSuffix(name, ".app"); ok {
			found = append(found, App{Name: base, Path: path, key: strings.ToLower(base)})
			continue
		}
		if depth > 0 && e.IsDir() {
			found = scanDir(path, depth-1, found)
		}
	}
	return found
}

// Match returns up to limit apps whose names match query, best first: a
// prefix, then a word start, then a substring, then the query's letters in
// order, so "vsc" finds Visual Studio Code. Shorter names win ties, since a
// short name the query covers more of is the likelier target.
func Match(all []App, query string, limit int) []App {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" || limit <= 0 {
		return nil
	}
	type ranked struct {
		app  App
		rank int
	}
	var hits []ranked
	for _, a := range all {
		if r := rank(a.key, q); r >= 0 {
			hits = append(hits, ranked{a, r})
		}
	}
	slices.SortStableFunc(hits, func(a, b ranked) int {
		return cmp.Or(cmp.Compare(a.rank, b.rank), cmp.Compare(len(a.app.key), len(b.app.key)))
	})
	out := make([]App, 0, min(limit, len(hits)))
	for _, h := range hits[:min(limit, len(hits))] {
		out = append(out, h.app)
	}
	return out
}

func rank(name, q string) int {
	switch {
	case strings.HasPrefix(name, q):
		return 0
	case strings.Contains(name, " "+q) || strings.Contains(name, "-"+q):
		return 1
	case strings.Contains(name, q):
		return 2
	}
	rest := name
	for _, r := range q {
		i := strings.IndexRune(rest, r)
		if i < 0 {
			return -1
		}
		rest = rest[i+len(string(r)):]
	}
	return 3
}
