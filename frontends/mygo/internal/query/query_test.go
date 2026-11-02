package query

import "testing"

func TestEvaluate(t *testing.T) {
	cases := map[string]string{
		"1+2":          "3",
		"2^3^2":        "512",
		"10 / 4":       "2.5",
		"7 % 3":        "1",
		"-(2+3)*2":     "-10",
		"1,000 * 3":    "3,000",
		"3 × 4 − 2":    "10",
		"1234567.5+0":  "1,234,567.5",
		"0.1+0.2":      "0.3",
		"(1+2":         "",
		"1/0":          "",
		"42":           "",
		"hello + 1":    "",
		"":             "",
		"2 * (3 + 4))": "",
	}
	for in, want := range cases {
		v, ok := Evaluate(in)
		got := ""
		if ok {
			got = FormatNumber(v)
		}
		if got != want {
			t.Errorf("Evaluate(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestConvert(t *testing.T) {
	cases := map[string]string{
		"1 in to cm":      "2.54 cm",
		"5 kg in lb":      "11.0231 lb",
		"0 c to f":        "32 °F",
		"1.5 gb as mb":    "1,500 MB",
		"90 min to h":     "1.5 h",
		"100km/h to mph":  "62.1371 mph",
		"100 km/h to mph": "62.1371 mph",
		"3 kg to km":      "",
		"ten km to mi":    "",
	}
	for in, want := range cases {
		got, _ := Convert(in)
		if got != want {
			t.Errorf("Convert(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLink(t *testing.T) {
	cases := map[string]string{
		"https://abd.com/x":           "https://abd.com/x",
		"x.com/abc":                   "https://x.com/abc",
		"apple.com":                   "https://apple.com",
		"http://localhost:3000":       "http://localhost:3000",
		"https://apple.com@evil.tld":  "",
		"javascript:alert(1)":         "",
		"file:///etc/passwd":          "",
		"~/notes":                     "",
		"/usr/bin":                    "",
		"not a link":                  "",
		"readme":                      "",
		"example.com:8080":            "",
		"build.sh":                    "https://build.sh",
		"mail@example.com":            "",
		"www.github.com/fpcMotif/abc": "https://www.github.com/fpcMotif/abc",
	}
	for in, want := range cases {
		l, ok := Link(in)
		if (ok && l.URL != want) || (!ok && want != "") {
			t.Errorf("Link(%q) = %q %v, want %q", in, l.URL, ok, want)
		}
	}
	if l, _ := Link("www.github.com"); l.Host != "github.com" {
		t.Errorf("host %q keeps www.", l.Host)
	}
}

func TestEngines(t *testing.T) {
	e, rest, ok := Addressed("  YT   lofi hip hop ")
	if !ok || e.ID != "youtube" || rest != "lofi hip hop" {
		t.Fatalf("Addressed = %v %q %v", e.ID, rest, ok)
	}
	if got := e.URL(rest); got != "https://www.youtube.com/results?search_query=lofi%20hip%20hop" {
		t.Errorf("URL %q", got)
	}
	if _, _, ok := Addressed("yt"); ok {
		t.Error("a bare keyword addressed an engine")
	}
	if _, _, ok := Addressed("w hello"); ok {
		t.Error("w is deliberately not a Wikipedia keyword")
	}
	if h := DefaultEngine.Host(); h != "google.com" {
		t.Errorf("default host %q", h)
	}
	if got := DefaultEngine.URL("a&b=c d"); got != "https://www.google.com/search?q=a%26b%3Dc%20d" {
		t.Errorf("escaping %q", got)
	}
}

func TestSettings(t *testing.T) {
	hits := MatchSettings("displ", 3)
	if len(hits) == 0 || hits[0].Name != "Displays" || hits[0].Subtitle != "System Settings" {
		t.Fatalf("displ → %+v", hits)
	}
	hits = MatchSettings("night", 3)
	if len(hits) == 0 || hits[0].Name != "Displays" || hits[0].Subtitle != "Matches: night" {
		t.Fatalf("night → %+v", hits)
	}
	if hits := MatchSettings("d", 3); hits != nil {
		t.Fatalf("one letter matched %+v", hits)
	}
}
