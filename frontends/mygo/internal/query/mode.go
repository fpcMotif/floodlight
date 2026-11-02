package query

import "strings"

// ModeKind is which posture the panel's one field is in.
type ModeKind uint8

const (
	Local ModeKind = iota
	Web
	Clipboard
)

// Mode is the Swift SearchMode: local search, one web engine addressed
// directly, or clipboard history. It remembers how it was entered so that
// leaving puts the field back as the user typed it: Tab and Esc are inverses.
type Mode struct {
	Kind         ModeKind
	EngineID     string // Web only
	TypedKeyword string // the keyword as typed, "" when a plain Tab entered
	QueryAtEntry string
}

// Event is a key that may move the mode, as an intent.
type Event uint8

const (
	Tab Event = iota
	ShiftTab
	Escape
	BackspaceOnEmpty
	Reset
	ClipboardShortcut
)

// clipKeyword enters clipboard mode from the field, as in the Swift app.
const clipKeyword = "clip"

// Transition is the one place the mode changes: it takes the mode, the
// field's text and an event, and returns the next mode and text.
func Transition(m Mode, q string, ev Event) (Mode, string) {
	switch ev {
	case Reset:
		return Mode{}, ""
	case Tab:
		if m.Kind != Local {
			return m, q
		}
		return entered(q)
	case ClipboardShortcut:
		if m.Kind == Clipboard {
			return m, q
		}
		return Mode{Kind: Clipboard}, ""
	case ShiftTab, Escape, BackspaceOnEmpty:
		switch m.Kind {
		case Web:
			canonical := ""
			if e, ok := EngineByID(m.EngineID); ok {
				canonical = e.Keywords[0]
			}
			return Mode{}, exitText(m, q, canonical)
		case Clipboard:
			return Mode{}, exitText(m, q, clipKeyword)
		}
	}
	return m, q
}

// entered is Tab's keyword completion: a first word naming an engine is
// absorbed into the mode, even with nothing after it; anything else
// addresses the default engine with the query unchanged.
func entered(q string) (Mode, string) {
	k, rest, ok := ParseAddress(q)
	if ok && strings.EqualFold(k, clipKeyword) {
		return Mode{Kind: Clipboard, TypedKeyword: k, QueryAtEntry: rest}, rest
	}
	if ok {
		if e, found := EngineFor(k); found {
			return Mode{Kind: Web, EngineID: e.ID, TypedKeyword: k, QueryAtEntry: rest}, rest
		}
	}
	return Mode{Kind: Web, EngineID: DefaultEngine.ID, QueryAtEntry: q}, q
}

// exitText rebuilds "keyword query" for a keyword-entered mode. The typed
// spelling survives while the query is unedited; an edit falls back to the
// canonical one.
func exitText(m Mode, q, canonical string) string {
	if m.TypedKeyword == "" {
		return q
	}
	spelling := m.TypedKeyword
	if q != m.QueryAtEntry && canonical != "" {
		spelling = canonical
	}
	if q == "" {
		return spelling
	}
	return spelling + " " + q
}
