## Problem Statement

Floodlight has exactly one way to hand a query off to the outside world: a single hard-coded
Google row, promoted or not by `WebSearchIntent`. The user who lives in this launcher wants
more destinations reachable without leaving the search bar — Twitter/X and YouTube searches
they run constantly, and quick answers from the AI CLIs already installed on their Mac
(`codex`, `claude -p`) — addressed the same terse way every other launcher lets you address a
site search: type a short keyword, then the query. They also want the same set of destinations
usable from outside Floodlight entirely, through PopClip's select-text-and-act popup, without
maintaining two separate lists of "things I can search for."

## Solution

Add a small, fixed table of keyword-addressed search engines that sits next to today's
Google fallback: `x`/`twitter` for Twitter/X, `yt`/`youtube` for YouTube, `codex` for the
Codex CLI, and `claude` for `claude -p`. Typing a keyword as the first word of a query
produces one explicit, highly-ranked result row — a URL-opening row for Twitter/YouTube
(the same shape as today's web fallback), and a new "run this CLI and show me the answer
right here" row for Codex/Claude that streams its answer inline in the panel instead of
handing off to a browser or terminal.

The same `{title, keyword, destination}` table is the one and only source of truth for what
these engines are. Floodlight doesn't build any PopClip-specific code or protocol — the table
is documented/exported in the shape PopClip already understands natively (an "Open URL %s"
action for the two site searches, a "Shell Script %s" action for the two CLI asks), so a user
can point PopClip at the exact same destinations Floodlight uses, and the two never have to
talk to each other at runtime.

## User Stories

1. As a Floodlight user, I want to type `yt lofi hip hop` and get a "Search YouTube" result, so that I can jump straight to YouTube's results page without opening a browser first and typing there.
2. As a Floodlight user, I want to type `x floodlight app` and get a "Search Twitter/X" result, so that I can search X the same fast way I search my files.
3. As a Floodlight user, I want `twitter` and `youtube` to work as full-word aliases for `x` and `yt`, so that I don't have to remember an abbreviation if the short form doesn't come to mind.
4. As a power user who remembers DuckDuckGo-style bangs, I want `!x` and `!yt` to work as alternate spellings of the same keywords, so that muscle memory from other tools carries over.
5. As a Floodlight user, I want the keyword to only trigger when it's the first word of my query, so that a file named `yttestfile.md` or a sentence that happens to contain "x" doesn't get hijacked into a Twitter search.
6. As a Floodlight user, I want the matched keyword row to rank above my fuzzy app/file matches, so that a deliberate `yt` keyword always wins over an accidental fuzzy hit.
7. As a Floodlight user, I want the keyword-search rows to still lose to Floodlight's own commands (like "Floodlight settings"), so that Floodlight's own configuration is never shadowed by a search engine.
8. As a Floodlight user, I want typing just `yt` with nothing after it to not immediately fire off a search for an empty string, so that I have a moment to keep typing my actual query.
9. As a Floodlight user, I want to type `codex fix the flaky test in CatalogTests` and see an "Ask Codex" row, so that I can get a quick answer from the Codex CLI without switching to a terminal.
10. As a Floodlight user, I want to type `claude what does WebSearchIntent do` and see an "Ask Claude" row, so that I can get a quick answer from `claude -p` without switching to a terminal.
11. As a Floodlight user, I want the AI row to only run the CLI when I explicitly select it (Return), not on every keystroke, so that I'm not spawning an LLM call for every partial word I type.
12. As a Floodlight user, I want to see a loading state on the row after I select it, so that I know Floodlight registered my request and is waiting on a real subprocess.
13. As a Floodlight user, I want the panel to stay open while the AI answer is in flight and once it lands, so that I can read the answer right there instead of getting bounced out to a browser or terminal.
14. As a Floodlight user, I want the answer text rendered in the panel once the CLI exits, so that I get my answer without any other app opening.
15. As a Floodlight user, I want a clear error state if the CLI exits with an error or times out, so that I know the ask failed instead of staring at a stuck spinner.
16. As a Floodlight user, if I keep editing my query after triggering an ask, I want the in-flight process cancelled and the stale answer cleared, so that I never see an answer attached to the wrong query.
17. As a Floodlight user without `codex` or `claude` installed, I want the corresponding keyword row to simply not appear, so that I'm never shown an action that's guaranteed to fail.
18. As a security-conscious user, I want my typed query passed to the CLI as a plain argument, never interpolated into a shell string, so that a query containing quotes or shell metacharacters can't do anything unexpected.
19. As a Floodlight user, I want my query text passed to the AI CLIs to never be logged or persisted beyond the run itself, so that ad hoc questions containing anything sensitive don't linger on disk.
20. As a PopClip user, I want a "Search Twitter/X" and "Search YouTube" action available from the PopClip bar when I select text anywhere on my Mac, so that I can search from any app, not just from inside Floodlight.
21. As a PopClip user, I want an "Ask Codex" and "Ask Claude" action available from the PopClip bar, so that I can get a quick AI answer about selected text without switching to Floodlight or a terminal.
22. As a Floodlight maintainer, I want the PopClip-facing destinations defined from the exact same keyword-engine table Floodlight's search bar uses, so that adding or renaming an engine in one place keeps both surfaces in sync without hand-editing two lists.
23. As a Floodlight maintainer, I want Floodlight to own zero PopClip-specific runtime code (no shared IPC, no custom URL scheme, no daemon), so that this feature doesn't add an ongoing compatibility surface between two independently-updated apps.
24. As a documentation reader, I want a guide showing exactly how to wire the same engines into PopClip, so that setting it up is copy-paste rather than reverse-engineering Floodlight's internals.
25. As a Floodlight user, I want the four new keyword rows to use the same icon/kind conventions as existing result kinds (web search vs. a distinct AI-assistant look), so that I can tell at a glance which kind of action a row performs.
26. As a Floodlight user, I want the existing Google web-fallback behavior (promoted-when-weak, pinned-last-when-strong) to keep working exactly as it does today, so that this feature is additive and doesn't regress the in-flight web-intent work.
27. As a Floodlight developer, I want the new keyword-engine parsing to live as a small, pure, independently testable function (no I/O, no catalog lifecycle), so that it follows the same shape as `WebSearchIntent` and `FloodlightCommandCatalog` rather than inventing a new pattern.
28. As a Floodlight developer, I want the CLI-invoking piece isolated behind a small seam so tests never spawn a real `codex`/`claude` process, so that the test suite stays fast, deterministic, and doesn't depend on what's installed on the CI machine.

## Implementation Decisions

- **New module: a keyword-engine table.** A small, fixed (not user-editable in this spec) table of engines, each with a title, one or more keyword spellings (a primary word plus any full-word alias and `!`-bang alias), and a destination: either a URL template (Twitter/X, YouTube — same shape as today's Google URL construction) or a CLI invocation (Codex, Claude — a binary name plus an argument list, never a shell string). This table is the single source of truth referenced by both the in-app parser and the PopClip documentation/export.
- **New module: a keyword-engine parser**, shaped like `WebSearchIntent`/`FloodlightCommandCatalog` — pure, synchronous, no I/O. Given the raw query, it checks whether the first whitespace-delimited token is an exact (case-insensitive) match for a known keyword or bang-alias; if so it returns the matched engine and the remainder of the query. No match (or an empty remainder) produces no result. This is a whole-word match, not fuzzy or prefix — `yt` matches, `yts` does not.
- **`buildResults` integration.** This parser's output slots into `SearchCoordinator.buildResults` the same way `FloodlightCommandCatalog.search(query)` does today: appended to the result array as its own contribution, not counted toward the `localMatchCount` that `WebSearchIntent` uses to decide whether to promote the default web row. Explicit keyword matches and the existing auto-detect promotion are independent mechanisms; this spec only adds the former.
- **New ranking tier.** Matched keyword-engine rows need a score band above application/calculator matches (a fuzzy match should never outrank a deliberately typed keyword) and below Floodlight's own command tier (Floodlight's own settings/config should never be shadowed by a search engine). This is a new constant alongside the existing tiers in `SearchItemRanking`.
- **Twitter/X and YouTube rows** reuse the existing `.web` `SearchItemKind` and the existing `.open(URL)` `SearchItemAction` — they are, mechanically, exactly what today's Google fallback row is, just addressed explicitly instead of auto-promoted.
- **A new `SearchItemKind` case for AI-assistant rows** (distinct label and symbol from `.web`), wired into the same exhaustive switches `.calculator`/`.web` already appear in (filter counts, filter inclusion) as excluded from the filter chips, matching how those two kinds are treated today.
- **A new `SearchItemAction` case for AI-assistant rows**, carrying the CLI binary name and its argument list as discrete values (not a single shell string) — the query text always travels as one argument, never interpolated into anything a shell would re-parse.
- **A new small subprocess-running seam** (something like an `AssistantProcessRunning` protocol with one concrete implementation over `Process`) that the coordinator calls only when a user selects an AI-assistant row — never on keystroke. It reports back running/succeeded-with-text/failed/timed-out. Tests substitute a fake conforming to this protocol; nothing in the test suite spawns a real `codex` or `claude` process.
- **Availability check.** At startup (or lazily, cached), Floodlight checks whether `codex` and `claude` are resolvable on the user's `$PATH` (GUI apps on macOS do not inherit a login shell's PATH by default, so this check needs to account for common install locations or resolve the binary the way a login shell would). An engine whose binary can't be found is dropped from the table for that session rather than shown as a row that's guaranteed to fail.
- **`performAction` restructuring.** Today, `SearchCoordinator.performAction` calls `onDismiss?()` unconditionally before its switch, then performs the action. The AI-assistant action must not dismiss the panel on selection — it needs to keep the panel open, run the process asynchronously, and publish a run state (idle → running → answered(text) / failed(message)) that the row's detail view observes. Editing the query, dismissing the panel, or triggering a different action while a run is in flight cancels it.
- **One-shot, not conversational.** Each ask is independent — no follow-up turns, no retained conversation history between asks. A fresh selection is a fresh process invocation.
- **PopClip parity via shared schema, not shared runtime.** No custom URL scheme, no `onOpenURL` handling, no IPC between the two apps. The deliverable is documentation (and optionally a generated PopClip extension package) that mirrors the keyword-engine table: Twitter/X and YouTube become PopClip "Open URL" actions with the same URL template Floodlight uses; Codex and Claude become PopClip "Shell Script" actions running the same binary/argument shape against PopClip's selected-text variable. If a PopClip extension artifact is generated rather than hand-documented, it must be generated from the same table Floodlight's parser reads, so the two can't drift silently out of sync.
- **Existing Google/`WebSearchIntent` behavior is untouched by this spec.** Whether to eventually fold the default web fallback into the same keyword-engine table (giving it an explicit `g`/`google` keyword alongside its existing auto-promotion behavior) is left to the implementing agent's judgment as a nice-to-have, not a requirement — the schema should be able to describe it, but migrating the existing, currently in-flight `WebSearchIntent` code path is not required to close this spec.

## Testing Decisions

Tests should exercise externally observable behavior — what row appears, in what order, with what action — not internal call sequencing.

- **Keyword-engine parser**: pure input/output unit tests, following `Tests/FloodlightEngineTests/WebSearchIntentTests.swift`'s style exactly — no mocking, a table of representative queries (`"yt lofi"`, `"YT lofi"`, `"!yt lofi"`, `"youtube lofi"`, `"ytlofi"` (should not match), `"yt"` alone (no remainder, should not match), `"lofi yt"` (keyword not in first position, should not match)) asserted against the expected matched engine and remainder.
- **`SearchCoordinator.buildResults` integration**: pipeline-level tests following `Tests/FloodlightTests/SearchCoordinatorTests.swift`'s existing pattern (e.g. `testWebFallbackIsPromotedWhenLocalMatchesAreWeak`, `testEverySourceContributesToTheMergedResults`) — assert a keyword-matched row appears, ranks above application/calculator results and below Floodlight commands, and that an unmatched query produces no such row and leaves the existing Google-fallback behavior unchanged.
- **AI-assistant run lifecycle**: tests inject a fake conforming to the new process-running protocol and assert the coordinator's published state transitions (idle → running → answered / failed) and that cancellation on query change actually cancels the fake run. No test spawns a real CLI process or depends on `codex`/`claude` being installed on the test machine.
- **Availability filtering**: a test that an engine backed by a binary the fake resolver reports as "not found" is absent from the built table.
- **Not a testing target**: the exact bytes/formatting of any generated PopClip extension file — if such a file is produced, verifying it exists and is derived from the same table is enough; pixel/format-level assertions belong to whatever thin generation step produces it, not to this feature's core test suite.

## Out of Scope

- A user-facing settings UI for adding, editing, or removing arbitrary keyword engines. This spec ships a fixed table (Twitter/X, YouTube, Codex, Claude); a general engine editor is a separate, larger feature.
- Conversational/multi-turn AI interaction, retained chat history, or follow-up questions within a single ask.
- Any on-device/local-model AI (Apple Foundation Models, llama.cpp, etc.) — that is the separate, already-tracked "local AI search" effort (`.scratch/smarter-search` tickets 01/04/05), which is about natural-language *file* search and an explore/answer mode over Floodlight's own index, not about shelling out to already-installed developer CLIs. This spec does not touch that effort or its local-first decision.
- A Floodlight-owned URL scheme, deep-link handling, or any other mechanism for external tools to reach into a running Floodlight instance. Rejected in favor of the shared-schema approach.
- Live search suggestions/autocomplete for Twitter/YouTube while typing — selecting the row only opens a static search-results URL, no network calls happen before selection.
- Rate limiting, cost tracking, or usage controls on the AI CLI calls — this relies entirely on the user's own already-configured `codex`/`claude` authentication and billing.
- Changes to the existing Google web-fallback promotion logic (`WebSearchIntent`, `SearchItemRanking.webPromoted`/`.webFallback`) beyond what's needed to keep it unaffected by this addition.
- Actually building or maintaining an installable `.popclipext` package as a shipped artifact is optional for closing this spec — a documentation page that lets a user hand-configure PopClip from the same table satisfies the PopClip user stories; a generated package is a nice-to-have.

## Further Notes

- This spec builds directly on uncommitted, in-progress work in the working tree: `Sources/FloodlightEngine/Search/WebSearchIntent.swift` and the `buildResults`/`SearchItemRanking` changes in `Sources/Floodlight/Search/SearchCoordinator.swift` and `Sources/FloodlightEngine/Search/Catalog.swift`, which implement the "smart auto-detect" promotion of the default web row. That work should land (or already be landed) independently of this spec; this spec's keyword-engine rows are additive and orthogonal to it.
- There is also an uncommitted local research effort at `.scratch/smarter-search/` (map + tickets, not yet in the GitHub tracker) that scoped the broader "web-search intent routing" problem, including this exact "keyword-prefix engines" mechanism (its research ticket explicitly names `yt query` and Twitter as examples) and explicitly flagged selection-capture-into-search (the PopClip shape) as a separate feature. Whoever picks this spec up should skim `.scratch/smarter-search/research/web-search-ux-conventions.md` for the full survey of how Alfred/Raycast/LaunchBar/Flow Launcher/DuckDuckGo bangs handle keyword engines — the conventions section directly informed the decisions above.
- The exact non-interactive invocation flags for the `codex` CLI (its "print an answer and exit" mode, analogous to `claude -p`) were not verified against the installed CLI's own `--help`/docs as part of writing this spec — confirm against the currently installed version before wiring the argument list.
- GUI macOS apps do not inherit a login shell's `PATH`, `nvm`/`rbenv`/Homebrew shims, etc. Resolving `codex`/`claude` reliably (and running them with the environment they'd have in a real terminal) is a real implementation risk worth budgeting time for, not a one-line lookup.
