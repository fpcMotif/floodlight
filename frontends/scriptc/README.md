# floodlight-tui

Floodlight's launcher as a terminal program. It is written in TypeScript and
compiled by [scriptc](https://github.com/vercel-labs/scriptc) to a native
binary with no Node.js or V8 inside. File search goes through the Zig index in
`core/`. Design and numbers: [ADR 0013](../../docs/adr/0013-scriptc-frontend.md).

## Build

```sh
make install-zig        # at the repository root, once
cd frontends/scriptc
make                    # → build/floodlight-tui
make test               # self-test, no-V8 coverage gate, smoke run
make measure            # size, cold start, idle memory, query latency
```

Needs bun (it fetches the pinned scriptc) and clang.

## Use

```sh
build/floodlight-tui                 # indexes $HOME on first run, in the background
build/floodlight-tui --root ~/code   # index a different folder
```

| key | action |
|---|---|
| type | search apps and files |
| ↑ ↓, Ctrl-P/N, PgUp/PgDn | move the selection |
| Enter | open, then exit |
| ⌥Enter | reveal in Finder, then exit |
| Esc, Ctrl-C | quit |
| Ctrl-U / Ctrl-W | clear the query / delete a word |

`--stay` keeps it running after opening a result.

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

Then bind `floodlight-popup` to a key:

- **Shortcuts.app:** a new shortcut with a "Run Shell Script" action that runs
  `~/.local/bin/floodlight-popup`. Then Shortcut Details → Add Keyboard
  Shortcut.
- **skhd:** `alt - space : ~/.local/bin/floodlight-popup`
- **Hammerspoon:** `hs.hotkey.bind({"alt"}, "space", function() hs.task.new(os.getenv("HOME") .. "/.local/bin/floodlight-popup", nil):start() end)`
