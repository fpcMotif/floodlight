# floodlight-tui

Floodlight's launcher as a terminal program. It is written in TypeScript and
compiled by [scriptc](https://github.com/vercel-labs/scriptc) to a native
binary with no Node.js or V8 inside. File search goes through the Zig index in
`core/`. Design and numbers: [ADR 0013](../../docs/adr/0013-scriptc-frontend.md).

## Build

```sh
make install-zig        # at the repository root, once
cd frontends/scriptc
make                    # → build/floodlight-tui, build/floodlight-clipd
make test               # self-test + parity fixtures, no-V8 gate, smoke run
make measure            # size, cold start, idle memory, query latency
```

Needs bun (it fetches the pinned scriptc), clang and SQLite (part of macOS;
`libsqlite3-dev` on Linux).

## Use

```sh
build/floodlight-tui                 # indexes $HOME on first run, in the background
build/floodlight-tui --root ~/code   # index a different folder
build/floodlight-tui --board         # the clipboard board
```

The index and the clipboard history live in the frontend's own data
folder, `~/Library/Application Support/com.floodlight.tui` (bundle id
`com.floodlight.tui`), apart from the Swift app's. The history uses the Swift
app's `clipboard_entries` schema (ADR 0008), so either can read the other's.

### Search

Apps, files and folders, System Settings panes, arithmetic and unit
conversions (`2*(3+4)`, `10 km to mi`), typed web addresses (`x.com/abc`)
and keyword engines (`yt lofi`, `gh floodlight`). Every term must match. The
best row is the Top Hit (★); the last row searches Google.

A terminal sees no ⌘, so ⌥ stands in for it and Ctrl covers the rest.

| key | action |
|---|---|
| type | search |
| ↑ ↓, Ctrl-P/N, PgUp/PgDn | move the selection |
| Enter | open (a calculator answer is copied), then exit |
| ⌥Enter | reveal in Finder, then exit |
| Ctrl-Y | Quick Look the selected file |
| ← →, ⌥1–⌥6 | filter: All, Apps, Files, Folders, PDFs, Images |
| Tab | web mode with the keyword's engine (`clip` opens the board) |
| Shift-Tab, Esc, Backspace on empty | leave web mode |
| Ctrl-B | the clipboard board |
| Ctrl-G | grant Full Disk Access (when the notice shows) |
| Esc, Ctrl-C | quit |
| Ctrl-U / Ctrl-W | clear the query / delete a word |

`--stay` keeps it running after opening a result.

### Clipboard board

A split view: the history on the left (pinned first, then the newest; type to
filter), the inspector on the right with the full text and its character,
word and line counts, a link's domain, a colour's swatch, a file's path and
size, or an image's dimensions and size.

| key | Swift board | action |
|---|---|---|
| Enter | Return | paste into the app you came from |
| ⌥Enter, ⌥C | ⌥Return, ⌘C | copy only |
| ⌥R, Ctrl-O | ⌘Return, ⌘R | reveal in Finder |
| Space (empty query), ⌥Y, Ctrl-Y | Space, ⌘Y | Quick Look |
| ⌥K, Ctrl-K | ⌘K | actions menu |
| ⌥. | ⌘. | pin or unpin |
| ⌥D, Ctrl-D | ⌘D | delete |
| ⌥1–⌥4 | ⌘1–⌘4 | All, Text, Files, Images |
| Esc | Esc | close |

Paste needs the target's process id: `floodlight-popup` records the frontmost
app and passes `--paste-pid`. macOS asks for Accessibility once, the first
time ⌘V is posted (#66).

### Clipboard capture

The TUI exits when dismissed, so a small agent, `build/floodlight-clipd`,
polls the pasteboard every 0.5 s and writes the store the board reads. It
skips concealed, transient and Floodlight's own writes and a repeat of the
newest entry, keeps text up to 32,000 bytes and images up to 15 MiB with a
128 px thumbnail, and prunes entries older than 30 days at launch. Run it at
login:

```sh
install -m 755 build/floodlight-clipd ~/.local/bin/
sed "s|@BIN@|$HOME/.local/bin|" launch/com.floodlight.tui.clipd.plist \
  > ~/Library/LaunchAgents/com.floodlight.tui.clipd.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.floodlight.tui.clipd.plist
```

### Full Disk Access

Without it, search still works and skips protected folders. A notice row
says so; Ctrl-G opens System Settings at the Full Disk Access list and shows
your terminal app in Finder, ready to drag in. The TUI polls for the grant,
then rebuilds the index. The grant belongs to the terminal app, not the TUI:
macOS gives a program the access of the app that runs it.

Colours are truecolor when `COLORTERM` says the terminal has it, and the 16
ANSI colours otherwise.

## Native panel (macOS)

`make` also builds `build/floodlight-panel`. It is the same search in a
Spotlight-style floating panel drawn by AppKit, with no Dock icon. ⌥Space shows
and hides it. Enter opens the result, ⌘Enter reveals it in Finder, and Esc or a
click elsewhere dismisses it.

```sh
build/floodlight-panel &        # runs in the background; press ⌥Space
build/floodlight-panel --show   # show it right away
```

## Global hotkey for the TUI

A terminal program cannot register a system hotkey. Instead,
`launch/floodlight-popup` opens a small borderless terminal window running the
TUI. It uses the first of Ghostty, kitty, Alacritty or WezTerm it finds, and
falls back to Terminal.app. Copy both files onto your `PATH`:

```sh
install -m 755 build/floodlight-tui launch/floodlight-popup ~/.local/bin/
```

Then bind `floodlight-popup` to ⌥Space and `floodlight-popup --board` to ⌥⇧C:

- **Shortcuts.app:** a new shortcut with a "Run Shell Script" action that runs
  `~/.local/bin/floodlight-popup`. Then Shortcut Details → Add Keyboard
  Shortcut.
- **skhd:** `alt - space : ~/.local/bin/floodlight-popup`
- **Hammerspoon:** `hs.hotkey.bind({"alt"}, "space", function() hs.task.new(os.getenv("HOME") .. "/.local/bin/floodlight-popup", nil):start() end)`
