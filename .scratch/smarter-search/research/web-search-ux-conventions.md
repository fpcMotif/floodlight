# Web-search UX conventions in established launchers

Research for ticket `02-web-search-ux-conventions`. Surveyed primary sources (official manuals/docs, plus vendor changelogs and shipping source code where the manual is thin) for how launchers route "I meant the web, not local results". Frame: (a) explicit invocation, (b) implicit fallback, (c) multi-engine config/addressing, (d) hotkey conventions.

---

## Raycast

- **(a) Explicit**: Quicklinks — user-defined URL templates with `{argument name="query"}` placeholders (e.g. `https://google.com/search?q={argument name="query"}`) that appear in Root Search by name and accept a typed argument. Any Quicklink can be given an **alias** (typed keyword) or a global **hotkey**. There is no reserved prefix character; addressing is by name/alias.
- **(b) Implicit fallback**: **Fallback Commands** — when the root-search query matches nothing, a "Use with…" fallback section appears containing commands that receive the raw query text (Google Search, DuckDuckGo Search, File Search, Quick AI, etc.). The user just presses Enter (top fallback is selected) or arrows into the list.
- **(c) Multi-engine**: multiple Quicklinks, one per engine; the fallback list itself is user-curated — add any command/Quicklink/Script Command that takes a single argument, drag-and-drop to reorder (Settings → Launcher → Fallback Commands, or the settings icon next to the fallback section header).
- **(d) Hotkeys**: no dedicated "web-search this query" chord; the convention is Enter-on-fallback. Every result row has an **Action Panel on ⌘K** with context actions (and per-item alias/hotkey assignment directly from root search).

Sources:
- https://manual.raycast.com/quicklinks
- https://www.raycast.com/changelog/macos/1-23-0 (customizable fallback commands)
- https://www.raycast.com/changelog/windows/0-40 (fallback commands: appear when no results; pre-defined Google/DuckDuckGo; customize via settings icon on the list section)
- https://manual.raycast.com/action-panel, https://manual.raycast.com/command-aliases-and-hotkeys

## Alfred

- **(a) Explicit**: **Web Search** keywords — ~30 built-ins (`google X`, `maps X`, `wiki X`, `amazon X`, `youtube X` …), each keyword customizable (Preferences → Features → Web Search). **Custom Searches** add any engine via a URL with `{query}` (e.g. `https://example.com/search?q={query}`), plus a title and a keyword; OpenSearch auto-detection ("Lookup") can fill the URL.
- **(b) Implicit fallback**: **Fallback Searches** — shown "when you search for a keyword that doesn't match a result on your local Mac". Defaults: Google, Wikipedia, Amazon. Configurable to appear *only* when zero local results, or "intelligently at the end of relevant results" (i.e. appended below weak matches). User selects a fallback row and hits Enter.
- **(c) Multi-engine**: the fallback list is user-curated (Powerpack): add web searches, custom searches, or workflow triggers; drag-and-drop to reorder. Keyword-addressed engines are unlimited via Custom Searches.
- **(d) Hotkeys**: no dedicated web-search chord; convention is arrow-to-row + Enter. Keywords are the primary explicit path.

Sources:
- https://www.alfredapp.com/help/features/web-search/ (keywords, `{query}` custom searches)
- https://www.alfredapp.com/help/features/default-results/fallback-searches/ (defaults, "no local match" trigger, reorderable list)

## LaunchBar

- **(a) Explicit**: **Search Templates** — indexed items selected by abbreviation like any other item (e.g. type `GOO` for Google), then **Space** opens a text field, type the query, **Return** submits; result opens in the default browser. Template URLs use `*` or `%s` wildcards (e.g. `http://en.wikipedia.org/w/wiki.phtml?search=*`), with POST support via a `post-` URL prefix.
- **(b) Implicit fallback**: none — LaunchBar's model is strictly select-target-then-type-query (target-first, query-second — the inverse of Alfred/Raycast).
- **(c) Multi-engine**: many factory templates (Google, Amazon, IMDb, iTunes Store…); custom ones added in the Index pane (Search Templates indexing rule → Add), with per-rule text-encoding options.
- **(d) Hotkeys**: per-template search history — Space reopens last query for refinement; **Shift+Space** carries the search string from another template; **Shift+Return** re-runs immediately. **Instant Send** (hold ⌘Space, or a modifier-key tap) sends the current text selection *into* LaunchBar, then typing an engine's abbreviation + Return web-searches the selection ("select text → ⌘Space, G, Return").

Sources:
- https://www.obdev.at/resources/launchbar/help/PerformingWebSearches.html
- https://www.obdev.at/resources/launchbar/help/SearchTemplates.html
- https://www.obdev.at/resources/launchbar/help/InstantSend.html

## PowerToys Run

- **(a) Explicit**: per-plugin **direct activation commands** — a short prefix scopes the query to one plugin. Web search is `??` (`?? what is the answer to life` → default browser's default engine); URI handler is `//` (`// learn.microsoft.com` opens the URL). All prefixes are remappable in the Plugin Manager, which warns that chosen characters can conflict with global queries of other plugins (e.g. `(` breaks calculator input) — a real hazard of prefix-sigil design.
- **(b) Implicit fallback**: plugins have an "include in global results" toggle rather than an empty-state fallback; the docs describe no dedicated "no results → web" mechanism. Engine choice is delegated to the default browser's default search engine (not configured in the launcher).
- **(c) Multi-engine**: none built in — one `??` command, one browser-default engine.
- **(d) Hotkeys**: Alt+Space to open (configurable); no web-search-this-query chord.

Source: https://learn.microsoft.com/en-us/windows/powertoys/run

## Flow Launcher

- **(a) Explicit**: Web Search plugin ships search sources each bound to an **action keyword**: `wiki {q}`, `sc` (Google Scholar), `maps`, `translate`, `facebook`, `twitter`, `findicon`, etc. URL templates use `{q}` (e.g. `https://www.google.com/search?q={q}`).
- **(b) Implicit**: the default **Google** source has action keyword `*` — Flow's "global" wildcard — so a plain "Search Google for <query>" result participates in *every* global query (ranked among/below local results), not only when results are empty. This is fallback-by-ranking rather than fallback-by-empty-state.
- **(c) Multi-engine**: search sources are user-editable in the plugin's settings (add/edit title, keyword, URL, per-source private/incognito mode, enable toggle; reorderable via drag-and-drop per release notes). Explorer uses `*` … actually file search uses its own keyword; each plugin's keywords are remappable.
- **(d) Hotkeys**: Alt+Space to open; no dedicated web-search chord — keyword or the ever-present global row.

Sources:
- https://raw.githubusercontent.com/Flow-Launcher/Flow.Launcher/dev/Plugins/Flow.Launcher.Plugin.WebSearch/Settings.cs (shipping defaults: Google `*`, `{q}` templates, per-source Enabled/IsPrivateMode)
- https://github.com/Flow-Launcher/docs/blob/main/usage-tips.md, https://deepwiki.com/Flow-Launcher/Flow.Launcher/4.4-web-search-and-other-plugins

## DuckDuckGo bangs (syntax convention)

- `!` + site abbreviation routes the query to that site's own search: `!w filter bubble` → Wikipedia, `!yt`, `!gh`. Thousands of bangs exist; users can submit new ones. The search executes on the destination site (with that site's data practices — DDG surfaces this caveat). Introduced 2008. The convention that matters for launchers: a **terse, memorable sigil+mnemonic that can ride along inside the query itself**, widely cloned by launcher plugins (Flow/Wox ecosystems, browser omniboxes).
- Source: https://duckduckgo.com/bang

## macOS Spotlight (baseline Floodlight replaces)

- Spotlight's own convention for "web-search the current query" is a **chord, not a row**: ⌘B opens the typed term in the default browser/engine. (Community documentation; Apple's shortcut table doesn't list it prominently.)
- Sources: https://macmost.com/10-mac-spotlight-keyboard-shortcuts.html, https://support.apple.com/guide/mac-help/spotlight-keyboard-shortcuts-mh26783/mac

---

## Distilled: what Floodlight should copy / adapt / skip

### Copy

1. **Keyword-prefix engines with a `{query}` URL template** (Alfred `{query}`, Flow `{q}`, LaunchBar `*`): `g rust lifetimes` → Google, `yt lofi` → YouTube. Universal across every surveyed launcher; keywords must be user-remappable and the engine list user-extensible (title + keyword + URL template + enabled toggle is the entire schema everyone ships).
2. **Empty-state fallback list that receives the raw query** (Raycast Fallback Commands, Alfred Fallback Searches): when local results are zero, replace the empty list with an ordered, user-curated set of web actions so plain **Enter** just works. This is the industry answer to "typed a web query, got nothing".
3. **A dedicated chord for "web-search exactly what I typed", available at all times** (Spotlight ⌘B): one keystroke that bypasses local results entirely, works even when local matches are hogging selection. ⌘Return or ⌘B are the two native-feeling candidates on macOS.
4. **Alfred's "intelligent" placement option**: fallbacks appended at the *end* of weak result lists, not only on zero results — covers the "3 junk matches beat the web row" failure mode Floodlight currently has.

### Adapt

5. **Flow's always-present global web row — but ranked, not pinned.** Floodlight already has the hard-pinned bottom row; the adaptation is to let smart auto-detect promote it (URL-shaped, question-shaped, zero/weak local score) rather than leaving it eternally last. Flow demonstrates the row can coexist with local results in one list; Alfred/Raycast demonstrate it should be adaptive.
6. **Bang syntax as an alias layer, not the primary UX**: accept `!yt query` / `!g query` as alternate spellings of the same engine keywords for muscle-memory users (bangs are a convention people arrive with), but keep the discoverable path the plain keyword + a Web filter tab. Support prefix position first; anywhere-in-query is a DDG nicety, not required.
7. **LaunchBar's engine-first flow** as the Web-tab interaction: selecting an engine (or the Web filter tab) then typing scopes everything to that engine — the target-first inverse of keyword-first, useful once a Web tab exists.
8. **Raycast's per-result action panel (⌘K)** in miniature: "Search web for '<query>'" (plus "with engine…") belongs in the actions of *any* selected result, so mid-list users can pivot to the web without retyping.

### Skip

9. **PowerToys-style cryptic sigil prefixes** (`??`, `%%`, `//`): the docs' own conflict warnings (sigils colliding with math/paths) show why word keywords beat punctuation soup; keep at most `!` (bangs) and `?` if desired, as aliases.
10. **Delegating engine choice to the browser default** (PowerToys): Floodlight should own its engine list; browser-default is opaque and unconfigurable in-app.
11. **LaunchBar's Space-to-enter-text-field modality** as the default path: a separate query-entry mode is extra state; modern launchers parse keyword+query from one input line. (The engine-first *scoping* idea survives via the Web tab, per #7.)
12. **Instant Send / selection capture** (LaunchBar ⌘Space-hold): valuable but a separate feature (OS-selection → search), out of scope for query routing.

### Open questions for the spec ticket

- Exact chord choice: ⌘Return (common launcher "secondary action") vs ⌘B (Spotlight muscle memory) — check for conflicts with Floodlight's existing action map.
- Whether the fallback list on zero results should auto-select its first row (Raycast: yes) — affects "Enter always does something" guarantees.
