package apps

import (
	"os"
	"path/filepath"
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
	if len(names) != 2 || names[0] != "Safari" || names[1] != "Terminal" {
		t.Fatalf("Scan found %q, want [Safari Terminal]", names)
	}
}

func TestMatchRanks(t *testing.T) {
	all := []App{
		{Name: "Visual Studio Code", key: "visual studio code"},
		{Name: "Calendar", key: "calendar"},
		{Name: "System Settings", key: "system settings"},
		{Name: "Calculator", key: "calculator"},
		{Name: "Music", key: "music"},
	}
	cases := []struct {
		query string
		want  []string
	}{
		{"cal", []string{"Calendar", "Calculator"}},
		{"set", []string{"System Settings"}},
		{"vsc", []string{"Visual Studio Code"}},
		{"usi", []string{"Music", "Visual Studio Code"}},
		{"  ", nil},
		{"zzz", nil},
	}
	for _, c := range cases {
		got := Match(all, c.query, 5)
		var names []string
		for _, a := range got {
			names = append(names, a.Name)
		}
		if len(names) != len(c.want) {
			t.Errorf("Match(%q) = %q, want %q", c.query, names, c.want)
			continue
		}
		for i := range names {
			if names[i] != c.want[i] {
				t.Errorf("Match(%q) = %q, want %q", c.query, names, c.want)
				break
			}
		}
	}
	if got := Match(all, "c", 1); len(got) != 1 {
		t.Errorf("limit 1 gave %d", len(got))
	}
}
