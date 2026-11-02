package clipboard

import "strings"

// Filter is a board chip, reached with ⌘1–⌘4.
type Filter uint8

const (
	FilterAll Filter = iota
	FilterText
	FilterFiles
	FilterImages
)

// Filters lists the chips in bar order.
var Filters = []Filter{FilterAll, FilterText, FilterFiles, FilterImages}

// Title is the chip's label.
func (f Filter) Title() string { return [...]string{"All", "Text", "Files", "Images"}[f] }

// Includes reports whether e shows under the chip.
func (f Filter) Includes(e Entry) bool {
	switch f {
	case FilterText:
		return e.Kind == KindText
	case FilterFiles:
		return e.Kind == KindFile
	case FilterImages:
		return e.Kind == KindImage
	}
	return true
}

// Action is what a board key asks for.
type Action string

const (
	ActPaste   Action = "paste"
	ActCopy    Action = "copy"
	ActReveal  Action = "reveal"
	ActPreview Action = "preview"
	ActActions Action = "actions"
	ActPin     Action = "pin"
	ActDelete  Action = "delete"
	ActFilter  Action = "filter"
	ActUp      Action = "up"
	ActDown    Action = "down"
	ActClose   Action = "close"
)

// Binding maps a chord to an action. Chords are written "cmd+k",
// "alt+return", "space": modifiers in the order ctrl, alt, shift, cmd.
type Binding struct {
	Chord  string
	Action Action
	Filter Filter // ActFilter only
}

// Bindings are the board's keys, the Swift board's and #112's.
var Bindings = []Binding{
	{Chord: "return", Action: ActPaste},
	{Chord: "alt+return", Action: ActCopy},
	{Chord: "cmd+c", Action: ActCopy},
	{Chord: "cmd+return", Action: ActReveal},
	{Chord: "cmd+r", Action: ActReveal},
	{Chord: "space", Action: ActPreview},
	{Chord: "cmd+y", Action: ActPreview},
	{Chord: "cmd+k", Action: ActActions},
	{Chord: "cmd+.", Action: ActPin},
	{Chord: "cmd+d", Action: ActDelete},
	{Chord: "cmd+1", Action: ActFilter, Filter: FilterAll},
	{Chord: "cmd+2", Action: ActFilter, Filter: FilterText},
	{Chord: "cmd+3", Action: ActFilter, Filter: FilterFiles},
	{Chord: "cmd+4", Action: ActFilter, Filter: FilterImages},
	{Chord: "up", Action: ActUp},
	{Chord: "down", Action: ActDown},
	{Chord: "escape", Action: ActClose},
}

// Lookup finds the binding for chord.
func Lookup(chord string) (Binding, bool) {
	c := strings.ToLower(chord)
	for _, b := range Bindings {
		if b.Chord == c {
			return b, true
		}
	}
	return Binding{}, false
}

// Board is the board's list state: the entries the store listed for the
// query, the chip, and the selection within what the chip shows.
type Board struct {
	Entries  []Entry
	Filter   Filter
	Selected int
}

// Visible is what the list shows under the chip.
func (b *Board) Visible() []Entry {
	if b.Filter == FilterAll {
		return b.Entries
	}
	var out []Entry
	for _, e := range b.Entries {
		if b.Filter.Includes(e) {
			out = append(out, e)
		}
	}
	return out
}

// Selection is the selected entry, or false on an empty list.
func (b *Board) Selection() (Entry, bool) {
	v := b.Visible()
	if len(v) == 0 {
		return Entry{}, false
	}
	return v[max(0, min(b.Selected, len(v)-1))], true
}

// SetEntries replaces the list and keeps the selection on the same entry
// when it is still there, else at the top: a new copy landing while the
// board is open must not move what the user is about to paste.
func (b *Board) SetEntries(es []Entry) {
	cur, had := b.Selection()
	b.Entries = es
	b.Selected = 0
	if had {
		for i, e := range b.Visible() {
			if e.ID == cur.ID {
				b.Selected = i
				return
			}
		}
	}
}

// Command is the outcome of one key: what the shell must do, on which
// entry. Moves and filters are applied to the board itself.
type Command struct {
	Action Action
	Entry  Entry
}

// Press applies chord and returns the command it asks of the shell, or
// false when the key is not the board's or there is nothing to act on.
// searchEmpty gates Space: with text in the field, Space types a space.
func (b *Board) Press(chord string, searchEmpty bool) (Command, bool) {
	bind, ok := Lookup(chord)
	if !ok || (bind.Chord == "space" && !searchEmpty) {
		return Command{}, false
	}
	switch bind.Action {
	case ActUp:
		b.Selected = max(0, b.Selected-1)
		return Command{Action: ActUp}, true
	case ActDown:
		b.Selected = min(max(0, len(b.Visible())-1), b.Selected+1)
		return Command{Action: ActDown}, true
	case ActFilter:
		b.Filter, b.Selected = bind.Filter, 0
		return Command{Action: ActFilter}, true
	case ActClose:
		return Command{Action: ActClose}, true
	}
	e, ok := b.Selection()
	if !ok {
		return Command{}, false
	}
	if bind.Action == ActReveal {
		if _, file := e.FilePath(); !file {
			return Command{}, false
		}
	}
	return Command{Action: bind.Action, Entry: e}, true
}

// MenuItem is one row of the ⌘K actions menu.
type MenuItem struct {
	Title  string
	Chord  string
	Action Action
}

// Menu is the actions menu for e: what applies to it, with its keys.
func Menu(e Entry) []MenuItem {
	items := []MenuItem{{"Paste", "return", ActPaste}, {"Copy", "cmd+c", ActCopy}}
	if _, ok := e.FilePath(); ok {
		items = append(items, MenuItem{"Show in Finder", "cmd+return", ActReveal})
	}
	if _, ok := e.FilePath(); ok || e.Kind == KindImage {
		items = append(items, MenuItem{"Quick Look", "cmd+y", ActPreview})
	}
	pin := "Pin"
	if e.Pinned() {
		pin = "Unpin"
	}
	return append(items, MenuItem{pin, "cmd+.", ActPin}, MenuItem{"Delete", "cmd+d", ActDelete})
}
