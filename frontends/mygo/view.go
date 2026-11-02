package main

import (
	"fmt"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/query"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

func svg(body string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` + body + `</svg>`))
}

var (
	searchIcon = svg(`<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>`)
	lockIcon   = svg(`<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>`)
	kindIcons  = map[search.Kind]*ui.SVG{
		search.KindApp:        svg(`<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>`),
		search.KindFile:       svg(`<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>`),
		search.KindFolder:     svg(`<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`),
		search.KindWeb:        svg(`<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>`),
		search.KindCalculator: svg(`<path d="M5 12h14M12 5v14"/>`),
		search.KindSetting:    svg(`<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 3 15H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 4.6 9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.7 1.7 0 0 0 9 3.1V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0 1.2 2.9H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>`),
	}
)

// filterKeys are ⌘1–⌘6, one per chip in bar order.
var filterKeys = [...]ui.Key{ui.Key1, ui.Key2, ui.Key3, ui.Key4, ui.Key5, ui.Key6}

func (p *panel) view(c *ui.Context) {
	t := c.Theme()
	root := c.Root()
	if c.Vibrancy() {
		root.Background(ui.Transparent)
	} else {
		root.Background(t.Background)
	}
	if hook := p.onFrame.Load(); hook != nil {
		root.Draw(func(*ui.Painter, ui.Rect) { (*hook)() })
	}
	if p.warming {
		root.Draw(func(*ui.Painter, ui.Rect) {
			if p.update != nil {
				p.update(p.warmed)
			}
		})
	}
	p.keys(c)

	ui.Column(c).Fill().Children(func() {
		p.searchBar(c)
		if len(p.rows) == 0 {
			return
		}
		p.chips(c)
		p.list.Selected = &p.chosen
		p.list.Key = func(i int) any { return p.rows[i].ID }
		p.list.Label = func(i int) string { return p.rows[i].Title }
		list := ui.List(c, &p.list, len(p.rows), func(i int) { p.row(c, i) }).Grow(1).Padding(resultPadding)
		if list.Submitted() {
			p.activate(false)
		}
	})
}

// keys asks each shortcut every frame, not in a switch: a shortcut the view
// stops asking about stops being one.
func (p *panel) keys(c *ui.Context) {
	if c.Shortcut(0, ui.KeyEscape) {
		if p.mode.Kind == query.Local {
			p.hide()
		} else {
			p.key(query.Escape)
		}
	}
	if c.Shortcut(ui.Shift, ui.KeyTab) {
		p.key(query.ShiftTab)
	}
	if c.Shortcut(0, ui.KeyTab) {
		p.key(query.Tab)
	}
	if p.query == "" && p.mode.Kind != query.Local && c.Shortcut(0, ui.KeyBackspace) {
		p.key(query.BackspaceOnEmpty)
	}
	if c.Shortcut(0, ui.KeyDown) {
		p.choose(p.chosen + 1)
	}
	if c.Shortcut(0, ui.KeyUp) {
		p.choose(p.chosen - 1)
	}
	if c.Shortcut(ui.Cmd, ui.KeyEnter) || c.Shortcut(ui.Cmd, ui.KeyR) {
		p.activate(true)
	}
	if c.Shortcut(0, ui.KeyEnter) {
		p.activate(false)
	}
	if c.Shortcut(ui.Cmd, ui.KeyY) {
		p.preview()
	}
	for i, k := range filterKeys {
		if c.Shortcut(ui.Cmd, k) && len(p.rows) > 0 {
			p.setFilter(search.Filters[i])
		}
	}
}

func (p *panel) placeholder() string {
	if p.mode.Kind == query.Web {
		if e, ok := query.EngineByID(p.mode.EngineID); ok {
			return e.Title
		}
	}
	return "Search apps, files and the web"
}

func (p *panel) searchBar(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Height(searchHeight).PaddingX(18).Gap(12).AlignItems(ui.Center).Children(func() {
		ui.Icon(c, searchIcon).FontSize(searchIconSize).TextColor(t.TextMuted)
		if p.mode.Kind == query.Web {
			if e, ok := query.EngineByID(p.mode.EngineID); ok {
				ui.Text(c, e.Name).FontSize(chipSize).Bold().TextColor(t.AccentText).
					Background(t.Accent).Padding(3, 8).Radius(6)
			}
		}
		field := ui.TextInputBase(c, &p.query).Bind(&p.input).Grow(1).FontSize(inputFontSize).
			Placeholder(p.placeholder()).Label("Search")
		if field.Changed() {
			p.submit()
		}
		// The focused field takes Return before any shortcut sees it.
		if field.Submitted() {
			p.activate(false)
		}
		if p.startGrant != nil && !p.granted() {
			lock := ui.ButtonBase(c).Label("Grant Full Disk Access").Tooltip("Grant Full Disk Access to search protected folders")
			lock.Children(func() { ui.Icon(c, lockIcon).FontSize(16).TextColor(t.TextMuted) })
			if lock.Clicked() {
				p.startGrant()
			}
		}
	})
}

// chips are All, Apps, Files and Folders always, then PDFs and Images when
// the query found any, each with its count, as the Swift filter bar shows.
func (p *panel) chips(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).Height(filterBarHeight).PaddingX(14).Gap(6).AlignItems(ui.Center).Children(func() {
		for _, f := range search.Filters {
			n := p.pub.Counts[f]
			if f > search.FilterFolders && n == 0 {
				continue
			}
			bg, fg := t.TextMuted.Alpha(0.1), t.Text
			if f == p.filter {
				bg, fg = t.Accent, t.AccentText
			}
			chip := ui.ButtonBase(c).Label(f.Title()).Padding(4, 10).Radius(12).Background(bg)
			chip.Children(func() {
				ui.Text(c, fmt.Sprintf("%s %d", f.Title(), n)).FontSize(chipSize).Bold().TextColor(fg)
			})
			if chip.Clicked() {
				p.setFilter(f)
			}
		}
	})
}

func (p *panel) row(c *ui.Context, i int) {
	r := p.rows[i]
	t := c.Theme()
	top := i == 0 && p.filter == search.FilterAll && r.ID != search.WebRowID
	bg, text, muted := ui.Transparent, t.Text, t.TextMuted
	if i == p.chosen {
		bg, text, muted = t.Accent.Alpha(0.85), t.AccentText, t.AccentText.Alpha(0.75)
	}
	iconSize, titleSize := float32(standardIconSize), float32(rowTitleSize)
	if top {
		iconSize, titleSize = topHitIconSize, topHitTitleSize
	}
	ui.Row(c).Height(resultRowHeight).PaddingX(10).Gap(12).AlignItems(ui.Center).Radius(rowCornerRadius).Background(bg).Children(func() {
		if b := p.rowIcon(r); b != nil {
			ui.Image(c, b).Size(iconSize, iconSize)
		} else {
			ui.Box(c).Size(iconSize, iconSize).Radius(8).Background(t.TextMuted.Alpha(0.14)).Center().Children(func() {
				ui.Icon(c, kindIcons[r.Kind]).FontSize(iconSize * 0.5).TextColor(muted)
			})
		}
		ui.Column(c).Grow(1).Gap(2).Children(func() {
			ui.Text(c, r.Title).FontSize(titleSize).FontWeight(500).TextColor(text).SingleLine()
			ui.Text(c, rowDetail(r, time.Now())).FontSize(rowSubtitleSize).TextColor(muted).SingleLine()
		})
		label := r.Kind.Label()
		if top {
			label = "Top Hit · " + label
		}
		ui.Text(c, label).FontSize(badgeSize).Bold().TextColor(muted).Padding(2, 6).Radius(4).Background(muted.Alpha(0.12))
	})
}

func (p *panel) rowIcon(r search.Row) *ui.Bitmap {
	if !r.IsFile() {
		return nil
	}
	return p.icon(r.Path)
}

// rowDetail is the subtitle line: where the row lives, then a file's size
// and modified date, so two files with one name read apart.
func rowDetail(r search.Row, now time.Time) string {
	s := r.Subtitle
	if r.Size >= 0 {
		s += " · " + clipboard.FormatBytes(r.Size)
	}
	if !r.Modified.IsZero() {
		s += " · " + relativeDate(r.Modified, now)
	}
	return s
}

// relativeDate is "Today at 3:04 PM", "Yesterday at …", a weekday within the
// week, else the date, as Finder lists files.
func relativeDate(t, now time.Time) string {
	day := func(x time.Time) time.Time { y, m, d := x.Date(); return time.Date(y, m, d, 0, 0, 0, 0, x.Location()) }
	days := int(day(now).Sub(day(t)).Hours() / 24)
	clock := t.Format("3:04 PM")
	switch {
	case days == 0:
		return "Today at " + clock
	case days == 1:
		return "Yesterday at " + clock
	case days > 1 && days < 7:
		return t.Format("Monday") + " at " + clock
	}
	return t.Format("Jan 2, 2006")
}
