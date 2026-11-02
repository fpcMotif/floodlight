package apps

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestScanFindsBundlesOneLevelDown(t *testing.T) {
	root := t.TempDir()
	for _, p := range []string{"Safari.app", "Utilities/Terminal.app", "Deep/Nested/Hidden.app", ".Secret.app"} {
		if err := os.MkdirAll(filepath.Join(root, p), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	got := Scan([]string{root, filepath.Join(root, "missing")})
	var names []string
	for _, a := range got {
		names = append(names, a.Name)
	}
	if !slices.Equal(names, []string{"Safari", "Terminal"}) {
		t.Fatalf("Scan found %q, want [Safari Terminal]", names)
	}
}

func names(hits []Hit) []string {
	var out []string
	for _, h := range hits {
		out = append(out, h.Name)
	}
	return out
}

func TestMatchRanks(t *testing.T) {
	all := []App{{Name: "Visual Studio Code"}, {Name: "Calendar"}, {Name: "System Settings"}, {Name: "Calculator"}, {Name: "Music"}}
	cases := []struct {
		query string
		want  []string
	}{
		{"cal", []string{"Calendar", "Calculator"}},
		{"vsc", []string{"Visual Studio Code"}},
		{"system set", []string{"System Settings"}},
		{"  ", nil},
		{"zzz", nil},
	}
	for _, c := range cases {
		if got := names(Match(all, c.query, 5)); !slices.Equal(got, c.want) {
			t.Errorf("Match(%q) = %q, want %q", c.query, got, c.want)
		}
	}
	if got := Match(all, "c", 1); len(got) != 1 {
		t.Errorf("limit 1 gave %d", len(got))
	}
}

func TestMatchAddsTheAppBonus(t *testing.T) {
	h := Match([]App{{Name: "Notes"}}, "notes", 1)
	if len(h) != 1 || h[0].Score <= Bonus {
		t.Fatalf("hits %+v, want one scored above the bonus", h)
	}
}
