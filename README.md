# Floodlight

Floodlight is a keyboard-first Spotlight alternative for macOS, written in
SwiftUI and powered by the [FFF](https://github.com/dmtrKovalenko/fff) Rust
indexing engine.

It searches files and folders with FFF's fuzzy ranking, live filesystem watcher,
query history, and frecency database. Native catalogs add applications and
System Settings. Floodlight also evaluates arithmetic, provides a web-search
fallback, supports Quick Look, and opens or reveals results without touching the
mouse.

## Features

- Global `⌘Space` invocation, with automatic `⌥Space` fallback while Apple's
  Spotlight still owns the shortcut
- FFF fuzzy search across files and folders
- Time-budgeted FFF content search when filename matches are sparse
- Live index updates
- Persistent FFF frecency and query history
- FFF-ranked application search via a package-marker index
- Native System Settings search
- Arithmetic with precedence, parentheses, powers, and percentages
- Web-search fallback in the default browser
- Open, Finder reveal, Quick Look, copy, and drag actions
- Configurable indexing scope and manual index rebuild
- Multi-display placement, full-screen space support, and menu-bar access
- Optional launch at login

## Requirements

- macOS 14 or newer
- Xcode command-line tools with Swift 5.10 or newer
- Rust and Cargo
- A local checkout of FFF (the default expected path is `../fff`)

## Build and run

```sh
make run
```

The first build compiles FFF as an optimized `libfff_c.dylib`; this can take a
few minutes because FFF enables release LTO. Override the location when needed:

```sh
make run FFF_DIR=/absolute/path/to/fff
```

Create a signed ad-hoc application bundle:

```sh
make bundle
open .build/Floodlight.app
```

For normal use, install Floodlight at a stable app path:

```sh
make install
```

This installs to `~/Applications/Floodlight.app` with a stable designated code
requirement. Grant macOS file access to that installed copy once; the grant
persists on later launches and development rebuilds. Set
`FLOODLIGHT_INSTALL_DIR` to choose another install directory.

Run the test suite:

```sh
make test
```

## Make `⌘Space` belong to Floodlight

macOS does not allow two applications to register the same global shortcut.
Floodlight tries `⌘Space` first and falls back to `⌥Space` if Spotlight owns it.
To use the Spotlight shortcut:

1. Open System Settings.
2. Open Keyboard → Keyboard Shortcuts → Spotlight.
3. Disable “Show Spotlight search.”
4. Restart Floodlight.

The menu-bar flashlight remains available if neither keyboard shortcut can be
registered.

## Keyboard controls

| Shortcut | Action |
| --- | --- |
| `↑` / `↓` | Move selection |
| `Return` | Open result or copy calculator answer |
| `⌘R` or `⌘Return` | Reveal file, folder, or app in Finder |
| `⌘Y` | Toggle Quick Look for a file |
| `⌘C` | Copy the selected path, URL, or answer |
| `⌘L` | Choose the indexed folder |
| `⇧⌘R` | Rebuild the FFF index |
| `Escape` | Hide Floodlight |

## Architecture

```text
SwiftUI search panel
  └─ SearchCoordinator
      ├─ FFFIndex → CFFF shim → libfff_c.dylib → fff-search
      ├─ ApplicationCatalog → private app markers → a second FFFIndex
      ├─ SystemCatalog
      ├─ Calculator
      └─ QuickLookController / NSWorkspace
```

All FFF calls run on one high-priority serial queue. Search input is debounced
for 35 ms and stale generations are discarded, keeping typing and selection on
the main actor responsive while the Rust engine searches in parallel.

macOS applications are directory packages, while FFF indexes regular files and
derives directories from their immediate parents. Floodlight discovers real
`.app` packages without descending into them, writes one empty marker per app
under its private Application Support directory, and gives that marker tree to
a dedicated FFF instance. The marker result maps back to the real bundle URL,
so app fuzzy scoring, frecency, and query history use FFF without indexing every
file inside every application.

## Search scope and privacy

Floodlight indexes the current user's home directory by default. Change the
scope with `⌘L` or the menu-bar menu. The index, frecency database, and query
history stay on the Mac under `~/Library/Application Support/Floodlight`.

macOS privacy rules still apply. To search protected locations, grant Floodlight
Full Disk Access in System Settings → Privacy & Security.

## Current compatibility boundary

Floodlight implements the core local-search workflow users rely on in Spotlight:
global access, apps, files, folders, settings, calculator answers, previews, and
web handoff. Apple's private Spotlight sources—such as Mail, Messages, Photos,
Contacts, Siri suggestions, and proprietary metadata importers—are not exposed
to third-party apps. Those sources require separate public-framework
integrations and user permissions rather than FFF filesystem indexing.

## License

Floodlight is available under the [MIT License](LICENSE).
