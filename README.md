# Floodlight

Floodlight is a keyboard-first Spotlight alternative for macOS, written in
SwiftUI and powered by the [FFF Swift](https://github.com/vmg-dev/fff-swift)
package.

It searches files and folders with FFF's fuzzy ranking, live filesystem watcher,
query history, and frecency database. Native catalogs add applications and
System Settings. Floodlight also evaluates arithmetic, provides a web-search
fallback, supports Quick Look, and opens or reveals results without touching the
mouse.

## Features

- Global `⌘Space` invocation, with automatic `⌥Space` fallback while Apple's
  Spotlight still owns the shortcut
- FFF fuzzy search across files and folders
- Relative, absolute, and `~/` path queries with directory-only trailing-slash
  search
- Time-budgeted FFF content search when filename matches are sparse
- Live file and folder index updates
- Persistent FFF frecency and query history
- FFF-ranked application search via a package-marker index
- Native System Settings search
- Searchable Floodlight settings for shortcuts, permissions, and scope
- Arithmetic with precedence, parentheses, powers, and percentages
- Web-search fallback in the default browser
- Open, Finder reveal, Quick Look, copy, and drag actions
- Configurable indexing scope and manual index rebuild
- Multi-display placement, full-screen space support, and menu-bar access
- Optional launch at login

## Requirements

- macOS 14 or newer
- Xcode command-line tools with Swift 5.10 or newer

## Build and run

```sh
make run
```

Swift Package Manager downloads the versioned FFFKit XCFramework automatically.
Building Floodlight does not require Rust or a separate FFF checkout.

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

## Quality gates

`make check` is the single entry point for every mechanical gate, and CI runs
exactly the same command — so a green run locally is a green run on the pull
request.

```sh
make install-tools   # pinned binaries into .tools/, once
make check           # format, lint, architecture rules, build, dead code
make format          # fix everything the format gate would complain about
```

The gate is deliberately made of small pieces you can run one at a time while
iterating: `make check-format`, `check-lint`, `check-rules`,
`check-architecture`, `check-build`, `check-dead-code`.

| Gate | Tool | What it owns |
| --- | --- | --- |
| `check-format` | SwiftFormat | One deterministic style. Never hand-edit its feedback — run `make format`. |
| `check-lint` | SwiftLint `--strict` | Performance antipatterns (`first_where`, `contains_over_filter_count`, …) and complexity proxies. |
| `check-rules` | ast-grep | Floodlight's own invariants — see below. |
| `check-architecture` | `rg` | Nothing under `Sources` declares `public` or `open`. |
| `check-build` | `swift build` | Warnings as errors, with strict concurrency checking on. |
| `check-dead-code` | Periphery | Unused declarations, with no suppression baseline. |

The architecture rules live one-per-file in
[`tools/ast-grep/rules`](tools/ast-grep/rules) and encode this codebase rather
than Swift style: the engine may not import a UI framework, the query path may
not touch the filesystem, the search path may not fully sort a candidate set,
and `try!`/`as!`/force unwrap may not ship. Every message names the alternative
to use. Adding a rule is one YAML file plus one test file in
[`tools/ast-grep/rule-tests`](tools/ast-grep/rule-tests).

Latency budgets run separately, in release configuration, because a debug
build's search path is several times slower than what a user feels:

```sh
make test-performance
```

**A new hot path is not done until it has a budgeted test.** Anything that runs
per keystroke — scoring, filtering, selection, a new catalog's
`immediatePage` — gets a test in the engine's performance suite: warm up, take
many samples, take the median, then assert against a hard bound with enough
margin to survive a shared CI runner. Print a `FLOODLIGHT_BENCH` line so the
measured number is in the log even on a green run. `SearchItemRankingPerformanceTests`
is the shape to copy. Elegance is not a substitute for a measurement, and none
of the rules above can tell you something is slow — only that it is shaped
wrong.

Some rules are worth breaking at a specific site. Suppress one with a
`// ast-grep-ignore: <rule-id>` comment on the line directly above, with the
reason beside it — ast-grep reports suppressions that have stopped matching, so
a stale one cannot quietly outlive its justification.

Tool versions are pinned in
[`scripts/tool-versions.env`](scripts/tool-versions.env); the check scripts
refuse to run against a different version rather than give you a verdict CI
will not reproduce.

Build the Astro documentation site:

```sh
npm --prefix docs install
make docs
```

Create a local development DMG:

```sh
make dmg
```

Local bundles and DMGs use ad-hoc signing. Tagged GitHub releases use the
Developer ID signing and notarization workflow in
[`.github/workflows/release.yml`](.github/workflows/release.yml).

The Finder/DMG icon is generated from
`Sources/Floodlight/Resources/AppIcon.png` with `make icons`. The menu bar uses
the separate monochrome `FloodlightMenuBar.svg` vector as a template image so
macOS supplies the correct foreground color for every appearance and state.

## Make `⌘Space` belong to Floodlight

Floodlight tries `⌘Space` first and falls back to `⌥Space` when another macOS
feature owns the shortcut. Follow the
[Replace Spotlight guide](docs/src/content/docs/getting-started/replace-spotlight.mdx)
to use `⌘Space` and restore Spotlight later if needed.

## Keyboard controls

See the complete [keyboard shortcut
reference](docs/src/content/docs/guides/keyboard-shortcuts.mdx).

## Architecture

```text
FloodlightPanelController
  ├─ SwiftUI search panel
  │   └─ SearchCoordinator (Search Session and selection)
  │       ├─ SourceSearchEngine actor
  │       │   ├─ FFFFileSource → FFFKit → vendored fff-search
  │       │   ├─ ApplicationCatalog → private app markers → a second FFFIndex
  │       │   └─ SystemCatalog
  │       ├─ Calculator
  │       └─ SelectedResultActionPerformer (selected-result action policy)
  │           └─ SelectedResultActionEffects → NSPasteboard / NSWorkspace
  └─ QuickLookController
```

The actor owns source startup, cancellation, scope changes, and rebuilds. Each
FFF instance serializes its own calls on a high-priority queue. Application and
System Settings matches publish immediately. File and application-marker search
then run concurrently after a 15–20 ms debounce. Content search waits another
30 ms. New queries cancel stale work before it can publish.

macOS applications are directory packages, while FFF indexes regular files and
derives directories from indexed file paths. Floodlight discovers apps in
standard system, user, and CoreServices locations without descending into their
packages. It writes one empty marker per app under its private Application
Support directory and gives that marker tree to a dedicated FFF instance. The
marker result maps back to the real bundle URL, so app fuzzy scoring, frecency,
and query history use FFF without indexing every package file. `.app` bundles
elsewhere inside the selected scope are also recognized by the main FFF index.

## Search scope and privacy

Floodlight indexes the current user's home directory by default. Change the
scope with `⌘L`, or from the menu-bar flashlight. The main file
index is rebuilt in memory at launch. Persistent FFF history, frecency data, and
private app markers stay on the Mac under
`~/Library/Application Support/Floodlight`.

macOS privacy rules still apply. To search protected locations, grant Floodlight
Full Disk Access in System Settings → Privacy & Security.

## Current compatibility boundary

Floodlight currently covers local apps, files, folders, settings, calculations,
previews, and web handoff. See [sources not yet
integrated](docs/src/content/docs/guides/search.mdx#sources-not-yet-integrated)
for the current Contacts, Photos, Mail, Messages, and Spotlight metadata
boundaries.

## License

Floodlight is available under the [MIT License](LICENSE).
