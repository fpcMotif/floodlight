# Web-search routing spec

Type: grilling
Status: partially resolved — smart auto-detect shipped; keyword triggers, hotkey chord, and Web filter tab still open
Blocked by: 02

## Question

Pin down exactly how the four chosen web-intent mechanisms compose in Floodlight, informed by the conventions research:

- **Keyword triggers**: what syntax (`g query`, `!yt query`, `? query`)? Which engines ship by default, and how are custom engines configured? Do triggers appear as completions while typing?
- **Hotkey on any query**: which chord (⌘Return is the obvious candidate — check conflicts with existing actions in `docs/src/content/docs/guides/keyboard-shortcuts.mdx`)? Does it use the default engine or the last-used one?
- **Web filter tab**: what does the tab contain — just engine actions for the current query, or live suggestions too (suggestions have a privacy/network cost — currently fogged)? Where does it sit in the tab order?
- **Smart auto-detect**: which non-AI heuristics promote the web row (question-shaped queries, URLs, zero/weak file matches)? What score does a promoted web row get, replacing today's hard-coded `Int.min` in `SearchCoordinator.buildResults`? How does this hand off to the AI intent router (ticket 04) later without the two fighting?

Resolve via /grilling with the user; the answer is the routing section of the final spec.

## Smart auto-detect — resolved 2026-08-08

Decision (quick-confirmed with the user, not a full grilling pass): promote on
**both** triggers — weak/zero local matches, OR a question/URL-shaped query —
whichever fires first.

Shipped:
- `WebSearchIntent` (`Sources/FloodlightEngine/Search/WebSearchIntent.swift`) —
  `shouldPromote(query:localMatchCount:)`. Weak-match threshold is
  `localMatchCount <= 2` (apps + settings + files + content, combined,
  excluding calculator/command rows). Question detection is a leading-word
  list (how/what/why/who/when/where/is/are/can/does/do/should/will/which) or
  a trailing `?`. URL detection is `NSDataDetector(.link)` requiring the
  whole trimmed query to match.
- New rank band `SearchItemRanking.webPromoted = 1_500`
  (`Sources/FloodlightEngine/Search/Catalog.swift`) — above plain content
  grep hits (1,000), below settings/apps/calculator/commands. Unpromoted rows
  keep the old `Int.min` (always last).
- `SearchCoordinator.buildResults` computes `localMatchCount` from
  `apps.count + system.count + indexed.count` and re-ranks after inserting
  the web row, since a promoted row is no longer guaranteed to sort last.
- Tests: `Tests/FloodlightEngineTests/WebSearchIntentTests.swift` (heuristic
  unit tests) and the `testWebFallback*`/`testWebFallbackIsPromoted*` cases in
  `Tests/FloodlightTests/SearchCoordinatorTests.swift` (ranking integration).

Still open — keyword triggers, the any-query hotkey chord, and the Web filter
tab — none of those are implemented; this only closes the auto-detect
sub-question. How auto-detect hands off to the AI intent router (ticket 04)
is also still open.
