package match

import "testing"

// The cases are core/src/match.zig's, so a drift between the two matchers
// fails here before it reorders a result list.
func TestScoreAgreesWithCore(t *testing.T) {
	must := func(hay, needle string, nameStart int) int {
		t.Helper()
		s, ok := Score(hay, needle, nameStart)
		if !ok {
			t.Fatalf("%q should match %q", needle, hay)
		}
		return s
	}
	if _, ok := Score("readme.md", "xyz", 0); ok {
		t.Error("xyz matched readme.md")
	}
	if _, ok := Score("ab", "abc", 0); ok {
		t.Error("a longer needle matched")
	}
	if _, ok := Score("ReadMe.MD", "readme", 0); !ok {
		t.Error("matching is not case-insensitive")
	}
	if !(must("notes.txt", "notes", 0) > must("notesbook.txt", "notes", 0)) {
		t.Error("an exact name should beat a prefix")
	}
	if !(must("notesbook.txt", "notes", 0) > must("n_o_t_e_s.txt", "notes", 0)) {
		t.Error("a prefix should beat a scatter")
	}
	if !(must("src/budget.xlsx", "budget", 4) > must("budget/q3.xlsx", "budget", 7)) {
		t.Error("a match in the name should beat one in a folder")
	}
	if !(must("xxabcxx", "abc", 0) > must("xaxbxcx", "abc", 0)) {
		t.Error("consecutive should beat scattered")
	}
	if must("axxxxabc", "abc", 0) != must("xxxxxabc", "abc", 0) {
		t.Error("the backward pass should tighten the window")
	}
	if !(must("my-app", "app", 0) > must("mapping", "app", 0)) {
		t.Error("a word boundary should beat mid-word")
	}
}
