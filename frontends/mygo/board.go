package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/clipboard"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/hotkey"
	"github.com/fpcMotif/floodlight/frontends/mygo/internal/platform"
)

// textPreviewBytes bounds the inspector's look into a copied text file.
const textPreviewBytes = 4096

// board is the clipboard board on ⌥⇧C. Its fields belong to the main thread.
type board struct {
	win   *mygo.Window
	store *clipboard.Store
	data  string // the data folder, where the Accessibility marker lives

	update  func(func())
	visible func() bool
	hide    func()
	now     func() float64

	query string
	b     clipboard.Board
	list  ui.ListState
	input ui.Handle
	menu  bool

	// target is the app in front when the board opened: where Return
	// pastes.
	target int

	// The inspector's decoded picture and text preview, for one entry at a
	// time, dropped on hide.
	shownID    string
	image      *ui.Bitmap
	thumbs     map[string]*ui.Bitmap
	filePeek   string
	sourceName map[string]string
}

func newBoard(store *clipboard.Store, data string) *board {
	return &board{
		store: store, data: data,
		now:    func() float64 { return float64(time.Now().UnixNano()) / 1e9 },
		thumbs: map[string]*ui.Bitmap{}, sourceName: map[string]string{},
	}
}

func (bd *board) ready() {
	bd.win = mygo.NewWindow(mygo.WindowOptions{
		Title:         "Floodlight Clipboard",
		Panel:         true,
		Hidden:        true,
		Frameless:     true,
		Transparent:   true,
		Vibrancy:      mygo.VibrancyGlass,
		CornerRadius:  panelCornerRadius,
		Width:         boardWidth,
		Height:        boardHeight,
		DisableResize: true,
		Content:       ui.View(bd.view),
	})
	platform.ConfigurePanel(bd.win.NativeHandle())
	bd.update, bd.visible, bd.hide = bd.win.Update, bd.win.IsVisible, bd.win.Hide
	bd.win.OnClose(func(e *mygo.CloseEvent) {
		e.PreventDefault()
		bd.win.Hide()
	})
	bd.win.OnHide(bd.drop)
	bd.win.OnBlur(func() {
		if !platform.QuickLookVisible() && !bd.menu {
			bd.win.Hide()
		}
	})
	if _, err := hotkey.Register(hotkey.KeyC, hotkey.Option|hotkey.Shift, bd.toggle); err != nil {
		log.Printf("⌥⇧C: %v", err)
	}
}

func (bd *board) toggle() {
	if bd.win.IsVisible() {
		bd.win.Hide()
		return
	}
	bd.open("")
}

// open shows the board with query in its field, remembering the app in
// front so Return can paste into it.
func (bd *board) open(query string) {
	bd.target = platform.FrontmostPID()
	bd.query = query
	bd.refresh()
	d := mygo.Screen.DisplayNearestPoint(mygo.Screen.CursorScreenPoint())
	bd.win.SetPosition(d.WorkArea.X+(d.WorkArea.Width-boardWidth)/2, d.WorkArea.Y+(d.WorkArea.Height-boardHeight)/3)
	bd.input.Focus()
	bd.win.Show()
}

// refresh lists the store for the field's text.
func (bd *board) refresh() {
	es, err := bd.store.List(bd.query)
	if err != nil {
		log.Print(err)
	}
	bd.b.SetEntries(es)
}

// recorded runs on the capture goroutine after a copy is stored.
func (bd *board) recorded([]clipboard.Entry) {
	if bd.update == nil {
		return
	}
	bd.update(func() {
		if bd.visible() {
			bd.refresh()
		}
	})
}

// drop lets go of the rows and every decoded image, then returns the
// memory: the board waits hidden far more than it is open.
func (bd *board) drop() {
	bd.query, bd.b, bd.list, bd.menu = "", clipboard.Board{}, ui.ListState{}, false
	bd.shownID, bd.image, bd.filePeek = "", nil, ""
	clear(bd.thumbs)
	platform.CloseQuickLook()
	debug.FreeOSMemory()
	platform.ReleaseMemory()
}

// do carries out a board command.
func (bd *board) do(cmd clipboard.Command) {
	e := cmd.Entry
	switch cmd.Action {
	case clipboard.ActClose:
		bd.hide()
	case clipboard.ActPaste:
		bd.write(e)
		bd.hide()
		go bd.paste(bd.target)
	case clipboard.ActCopy:
		bd.write(e)
		bd.hide()
	case clipboard.ActReveal:
		if p, ok := e.FilePath(); ok {
			bd.hide()
			mygo.Shell.ShowItemInFolder(p)
		}
	case clipboard.ActPreview:
		if p := bd.previewPath(e); p != "" {
			platform.ToggleQuickLook(p)
		}
	case clipboard.ActActions:
		bd.menu = !bd.menu
	case clipboard.ActPin:
		if err := bd.store.TogglePin(e.ID, bd.now()); err != nil {
			log.Print(err)
		}
		bd.refresh()
	case clipboard.ActDelete:
		if err := bd.store.Delete(e.ID); err != nil {
			log.Print(err)
		}
		bd.refresh()
	}
}

func (bd *board) write(e clipboard.Entry) {
	var png []byte
	if e.Kind == clipboard.KindImage {
		png = bd.store.ImagePNG(e.ID)
	}
	platform.WriteEntry(e, png)
}

// paste posts ⌘V to pid, which takes Accessibility trust. The system's
// prompt is shown once, ever: asking on every paste would nag, and the
// entry is on the pasteboard for a manual ⌘V either way.
func (bd *board) paste(pid int) {
	if platform.AccessibilityTrusted(false) {
		if !platform.PasteInto(pid) {
			log.Print("paste: target app did not come forward")
		}
		return
	}
	marker := filepath.Join(bd.data, "accessibility-prompted")
	if _, err := os.Stat(marker); err == nil {
		return
	}
	platform.AccessibilityTrusted(true)
	if err := os.WriteFile(marker, nil, 0o644); err != nil {
		log.Print(err)
	}
}

// previewPath is the file Quick Look shows for e: the file it names, or
// the image written out to a temporary file.
func (bd *board) previewPath(e clipboard.Entry) string {
	if p, ok := e.FilePath(); ok {
		return p
	}
	if e.Kind != clipboard.KindImage {
		return ""
	}
	png := bd.store.ImagePNG(e.ID)
	if png == nil {
		return ""
	}
	dir := filepath.Join(os.TempDir(), "FloodlightMyGoPreviews")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return ""
	}
	p := filepath.Join(dir, e.ID+".png")
	if err := os.WriteFile(p, png, 0o600); err != nil {
		return ""
	}
	return p
}

func (bd *board) appName(id string) string {
	if n, ok := bd.sourceName[id]; ok {
		return n
	}
	n := clipboard.SourceName(id, platform.AppName)
	bd.sourceName[id] = n
	return n
}

// chordKeys maps the board's chords to MyGo keys, so the bindings stay in
// one table in the clipboard package.
var chordKeys = map[string]ui.Key{
	"return": ui.KeyEnter, "space": ui.KeySpace, "up": ui.KeyUp, "down": ui.KeyDown, "escape": ui.KeyEscape,
	"c": ui.KeyC, "r": ui.KeyR, "y": ui.KeyY, "k": ui.KeyK, "d": ui.KeyD, ".": ui.KeyPeriod,
	"1": ui.Key1, "2": ui.Key2, "3": ui.Key3, "4": ui.Key4,
}

func chord(s string) (ui.Modifiers, ui.Key) {
	var mods ui.Modifiers
	parts := strings.Split(s, "+")
	for _, m := range parts[:len(parts)-1] {
		switch m {
		case "cmd":
			mods |= ui.Cmd
		case "alt":
			mods |= ui.Alt
		case "shift":
			mods |= ui.Shift
		case "ctrl":
			mods |= ui.Ctrl
		}
	}
	return mods, chordKeys[parts[len(parts)-1]]
}

func (bd *board) keys(c *ui.Context) {
	for _, b := range clipboard.Bindings {
		// Space is the field's while it has text; asking for the shortcut
		// would take the key from it.
		if b.Chord == "space" && strings.TrimSpace(bd.query) != "" {
			continue
		}
		mods, key := chord(b.Chord)
		if c.Shortcut(mods, key) {
			if cmd, ok := bd.b.Press(b.Chord, strings.TrimSpace(bd.query) == ""); ok {
				bd.do(cmd)
				if cmd.Action == clipboard.ActUp || cmd.Action == clipboard.ActDown {
					bd.list.ScrollIntoView(bd.b.Selected)
				}
			}
		}
	}
}

func (bd *board) view(c *ui.Context) {
	t := c.Theme()
	root := c.Root()
	if c.Vibrancy() {
		root.Background(ui.Transparent)
	} else {
		root.Background(t.Background)
	}
	bd.keys(c)
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).Height(boardSearchHeight).PaddingX(18).Gap(12).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, searchIcon).FontSize(searchIconSize).TextColor(t.TextMuted)
			if ui.TextInputBase(c, &bd.query).Bind(&bd.input).Grow(1).FontSize(20).
				Placeholder("Search clipboard history").Label("Search clipboard").Changed() {
				bd.refresh()
			}
			for i, f := range clipboard.Filters {
				bg, fg := t.TextMuted.Alpha(0.1), t.Text
				if f == bd.b.Filter {
					bg, fg = t.Accent, t.AccentText
				}
				chip := ui.ButtonBase(c).Label(f.Title()).Tooltip(fmt.Sprintf("⌘%d", i+1)).Padding(4, 10).Radius(12).Background(bg)
				chip.Children(func() { ui.Text(c, f.Title()).FontSize(chipSize).Bold().TextColor(fg) })
				if chip.Clicked() {
					bd.b.Filter, bd.b.Selected = f, 0
				}
			}
		})
		ui.Divider(c)
		ui.Row(c).Grow(1).Children(func() {
			bd.listView(c)
			bd.inspector(c)
		})
		bd.footer(c)
	})
}

func (bd *board) listView(c *ui.Context) {
	t := c.Theme()
	visible := bd.b.Visible()
	ui.Column(c).Width(boardListWidth).FillHeight().Padding(resultPadding).Children(func() {
		if len(visible) == 0 {
			ui.Text(c, "Nothing copied yet").TextColor(t.TextMuted).Margin(24)
			return
		}
		bd.list.Selected = &bd.b.Selected
		bd.list.Key = func(i int) any { return visible[i].ID }
		bd.list.Label = func(i int) string { return visible[i].Title() }
		now := bd.now()
		l := ui.List(c, &bd.list, len(visible), func(i int) {
			e := visible[i]
			bg, text, muted := ui.Transparent, t.Text, t.TextMuted
			if i == bd.b.Selected {
				bg, text, muted = t.Accent.Alpha(0.85), t.AccentText, t.AccentText.Alpha(0.75)
			}
			ui.Row(c).Height(48).PaddingX(8).Gap(10).AlignItems(ui.Center).Radius(rowCornerRadius).Background(bg).Children(func() {
				if th := bd.thumb(e); th != nil {
					ui.Image(c, th).Size(30, 30).Radius(5)
				} else {
					ui.Box(c).Size(30, 30).Radius(6).Background(t.TextMuted.Alpha(0.14)).Center().Children(func() {
						ui.Icon(c, entryIcon(e)).FontSize(15).TextColor(muted)
					})
				}
				ui.Column(c).Grow(1).Gap(1).Children(func() {
					ui.Text(c, e.Title()).FontSize(13).FontWeight(500).TextColor(text).SingleLine()
					ui.Text(c, e.Subtitle(now, bd.appName)).FontSize(11).TextColor(muted).SingleLine()
				})
				if e.Pinned() {
					ui.Text(c, "Pinned").FontSize(badgeSize).Bold().TextColor(muted)
				}
			})
		}).Grow(1)
		if l.Submitted() {
			if e, ok := bd.b.Selection(); ok {
				bd.do(clipboard.Command{Action: clipboard.ActPaste, Entry: e})
			}
		}
	})
}

func entryIcon(e clipboard.Entry) *ui.SVG {
	switch {
	case e.Kind == clipboard.KindImage:
		return kindIcons[0]
	case e.Kind == clipboard.KindFile || e.Class.Content == clipboard.Path:
		return kindIcons[1]
	case e.Class.Content == clipboard.Link:
		return kindIcons[3]
	}
	return kindIcons[1]
}

func (bd *board) thumb(e clipboard.Entry) *ui.Bitmap {
	if len(e.Thumbnail) == 0 {
		return nil
	}
	if b, ok := bd.thumbs[e.ID]; ok {
		return b
	}
	b, _ := ui.DecodeBitmap(e.Thumbnail)
	bd.thumbs[e.ID] = b
	return b
}

// inspect loads what the inspector shows for e once per selection: the
// full image, or the head of a text file.
func (bd *board) inspect(e clipboard.Entry) {
	if bd.shownID == e.ID {
		return
	}
	bd.shownID, bd.image, bd.filePeek = e.ID, nil, ""
	if e.Kind == clipboard.KindImage {
		if png := bd.store.ImagePNG(e.ID); png != nil {
			bd.image, _ = ui.DecodeBitmap(png)
		}
		return
	}
	if p, ok := e.FilePath(); ok && clipboard.FileType(p, false) != "Image" {
		if f, err := os.Open(p); err == nil {
			buf := make([]byte, textPreviewBytes)
			n, _ := f.Read(buf)
			f.Close()
			if utf8.Valid(buf[:n]) {
				bd.filePeek = string(buf[:n])
			}
		}
	}
}

func (bd *board) inspector(c *ui.Context) {
	t := c.Theme()
	e, ok := bd.b.Selection()
	ui.Column(c).Width(boardInspectorW).FillHeight().Padding(14).Gap(10).Background(t.TextMuted.Alpha(0.06)).Radius(rowCornerRadius).Children(func() {
		if !ok {
			return
		}
		bd.inspect(e)
		ui.Text(c, e.Title()).FontSize(inspectorTitleSize).Bold().TextColor(t.Text).SingleLine()
		ui.Scroll(c).Grow(1).Children(func() {
			switch {
			case bd.image != nil:
				ui.Image(c, bd.image).MaxWidth(boardInspectorW - 28).MaxHeight(300).Fit(ui.Contain)
			case bd.filePeek != "":
				ui.Text(c, bd.filePeek).FontSize(inspectorRowSize).Font("monospace").TextColor(t.Text).Wrap()
			case e.Kind == clipboard.KindText:
				ui.Text(c, e.Text).FontSize(inspectorRowSize).TextColor(t.Text).Wrap().Selectable()
			}
		})
		for _, kv := range details(e, bd.appName) {
			ui.Row(c).Gap(8).Children(func() {
				ui.Text(c, kv[0]).FontSize(inspectorLabelSize).Bold().TextColor(t.TextMuted).Width(110)
				ui.Text(c, kv[1]).FontSize(inspectorRowSize).TextColor(t.Text).SingleLine()
			})
		}
	})
}

// details are the inspector's label and value rows.
func details(e clipboard.Entry, appName func(string) string) [][2]string {
	rows := [][2]string{{"Source", appName(e.SourceID)}, {"Copied", time.Unix(int64(e.CreatedAt), 0).Format("Jan 2, 2006 at 3:04 PM")}}
	switch {
	case e.Kind == clipboard.KindImage:
		rows = append(rows, [2]string{"Dimensions", fmt.Sprintf("%d×%d", e.Width, e.Height)}, [2]string{"Size", clipboard.FormatBytes(int64(e.ByteCount))})
	case e.Kind == clipboard.KindFile || e.Class.Content == clipboard.Path:
		p, _ := e.FilePath()
		st, err := os.Stat(p)
		rows = append(rows, [2]string{"Type", clipboard.FileType(p, err == nil && st.IsDir())}, [2]string{"Path", p})
		if err == nil && !st.IsDir() {
			rows = append(rows, [2]string{"Size", clipboard.FormatBytes(st.Size())})
		}
	default:
		n := clipboard.CountText(e.Text)
		rows = append(rows, [2]string{"Content", contentLabel(e.Class)},
			[2]string{"Characters", fmt.Sprint(n.Characters)}, [2]string{"Words", fmt.Sprint(n.Words)}, [2]string{"Lines", fmt.Sprint(n.Lines)})
		if c, ok := clipboard.ParseColor(e.Class.Detail); ok && e.Class.Content == clipboard.Color {
			rows = append(rows, [2]string{"RGB", c.RGB()})
		}
	}
	return rows
}

func contentLabel(c clipboard.Classification) string {
	switch c.Content {
	case clipboard.Link:
		return "Link · " + c.Detail
	case clipboard.Color:
		return "Color · " + c.Detail
	case clipboard.Code:
		return c.Detail
	}
	return "Text"
}

// footer is Paste, Preview and Actions; the actions menu opens over it.
func (bd *board) footer(c *ui.Context) {
	t := c.Theme()
	e, ok := bd.b.Selection()
	ui.Row(c).Height(boardFooterHeight).PaddingX(12).Gap(8).AlignItems(ui.Center).Justify(ui.End).Children(func() {
		key := func(label, hint string) ui.Element {
			b := ui.ButtonBase(c).Label(label).Padding(2, 8).Radius(6).Disabled(!ok)
			b.Children(func() {
				ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
					ui.Text(c, label).FontSize(keyChipSize).TextColor(t.Text)
					ui.Text(c, hint).FontSize(keyChipSize).Bold().TextColor(t.TextMuted).Padding(1, 5).Radius(4).Background(t.TextMuted.Alpha(0.14))
				})
			})
			return b
		}
		if key("Paste", "↵").Clicked() && ok {
			bd.do(clipboard.Command{Action: clipboard.ActPaste, Entry: e})
		}
		if key("Preview", "⌘Y").Clicked() && ok {
			bd.do(clipboard.Command{Action: clipboard.ActPreview, Entry: e})
		}
		actions := key("Actions", "⌘K")
		if actions.Clicked() {
			bd.menu = !bd.menu
		}
		ui.Popover(c, actions, &bd.menu, func() {
			if !ok {
				return
			}
			for _, it := range clipboard.Menu(e) {
				item := ui.ButtonBase(c).Label(it.Title).PaddingX(10).Height(26).FillWidth()
				item.Children(func() {
					ui.Row(c).Gap(16).FillWidth().Children(func() {
						ui.Text(c, it.Title).FontSize(13).TextColor(t.Text).Grow(1)
						ui.Text(c, keyHint(it.Chord)).FontSize(keyChipSize).TextColor(t.TextMuted)
					})
				})
				if item.Clicked() {
					bd.menu = false
					bd.do(clipboard.Command{Action: it.Action, Entry: e})
				}
			}
		})
	})
}

func keyHint(chord string) string {
	return strings.NewReplacer("cmd+", "⌘", "alt+", "⌥", "shift+", "⇧", "return", "↵").Replace(chord)
}
