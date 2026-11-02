package main

import (
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/search"
)

var searchIcon = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>`))

var kindLabel = [...]string{search.KindApp: "Application", search.KindFile: "File", search.KindFolder: "Folder"}

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

	// Each Shortcut is asked every frame, not in a switch: a shortcut the
	// view stops asking about stops being one.
	if c.Shortcut(0, ui.KeyEscape) {
		p.win.Hide()
	}
	if c.Shortcut(0, ui.KeyDown) {
		p.choose(p.chosen + 1)
	}
	if c.Shortcut(0, ui.KeyUp) {
		p.choose(p.chosen - 1)
	}
	if c.Shortcut(ui.Cmd, ui.KeyEnter) {
		p.activate(true)
	}
	if c.Shortcut(0, ui.KeyEnter) {
		p.activate(false)
	}

	ui.Column(c).Fill().Children(func() {
		ui.Row(c).Padding(16, 18).Gap(12).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, searchIcon).FontSize(20).TextColor(t.TextMuted)
			if ui.TextInputBase(c, &p.query).Bind(&p.input).Grow(1).FontSize(22).
				Placeholder("Search apps and files").Label("Search").Changed() {
				p.submit()
			}
		})
		ui.Divider(c)
		p.list.Selected = &p.chosen
		p.list.Key = func(i int) any { return p.rows[i].Path }
		p.list.Label = func(i int) string { return p.rows[i].Title }
		list := ui.List(c, &p.list, len(p.rows), func(i int) { p.row(c, i) }).Grow(1).Padding(6)
		if list.Submitted() {
			p.activate(false)
		}
	})
}

func (p *panel) row(c *ui.Context, i int) {
	r := p.rows[i]
	t := c.Theme()
	bg, text, muted := ui.Transparent, t.Text, t.TextMuted
	if i == p.chosen {
		bg, text, muted = t.Accent.Alpha(0.85), t.AccentText, t.AccentText.Alpha(0.75)
	}
	ui.Row(c).Padding(6, 10).Gap(12).AlignItems(ui.Center).Radius(8).Background(bg).Children(func() {
		ui.Column(c).Grow(1).Gap(1).Children(func() {
			ui.Text(c, r.Title).TextColor(text).SingleLine()
			ui.Text(c, r.Subtitle).FontSize(11).TextColor(muted).SingleLine()
		})
		ui.Text(c, kindLabel[r.Kind]).FontSize(11).TextColor(muted)
	})
}
