// Package apps finds application bundles on disk and scores them by name.
package apps

import (
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/match"
)

// Bonus lifts an app over a file hit with the same core score: launching an
// app is a launcher's first job. #112 and the nanoui port both fix it at 60.
const Bonus = 60

// App is an application bundle.
type App struct {
	Name string // the bundle's file name without .app
	Path string
}

// Hit is a matched app and its score, Bonus included.
type Hit struct {
	App
	Score int
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
	slices.SortFunc(found, func(a, b App) int {
		return cmp.Or(cmp.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)), cmp.Compare(a.Path, b.Path))
	})
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
			found = append(found, App{Name: base, Path: path})
			continue
		}
		if depth > 0 && e.IsDir() {
			found = scanDir(path, depth-1, found)
		}
	}
	return found
}

// Match scores every app against each space-separated term of query and
// returns the ones every term matches, best first. Equal scores go to the
// shorter name, then the name, so the order never depends on scan order.
func Match(all []App, query string, limit int) []Hit {
	terms := strings.Fields(match.Lower(query))
	if len(terms) == 0 || limit <= 0 {
		return nil
	}
	var hits []Hit
	for _, a := range all {
		if s, ok := scoreTerms(a.Name, terms); ok {
			hits = append(hits, Hit{a, s + Bonus})
		}
	}
	slices.SortStableFunc(hits, func(a, b Hit) int {
		return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(len(a.Name), len(b.Name)), cmp.Compare(a.Name, b.Name))
	})
	return hits[:min(limit, len(hits))]
}

func scoreTerms(name string, terms []string) (int, bool) {
	total := 0
	for _, t := range terms {
		s, ok := match.Score(name, t, 0)
		if !ok {
			return 0, false
		}
		total += s
	}
	return total, true
}
