---
status: accepted
date: 2026-09-07
---

# Classify a Clipboard Entry once, when it is recorded

A text Clipboard Entry carries a stored classification — `ClipboardTextContent` — decided once by the engine when the entry is recorded and persisted beside it in Clipboard History. It says whether the text is plain prose, a link (with its domain), a hex colour (with its components), code (with a language hint), or a single-line local path (resolved to a file URL). Result Projection reads it to pick a row's icon and title, the Clipboard Inspector reads it for the detail it shows, and neither parses the text again. Clipboard Search memoizes the rows it builds, keyed by the store's mutation version and the query, so a chip switch over unchanged history reuses them (#73).

## Why

Before this, "what kind of thing is this entry" was decided independently at eight sites across five modules, from the same text, on every keystroke: the row builder parsed a JSON serializer over any brace-wrapped text, stat'ed any path-like text, and re-derived link, colour, and code for every entry the query returned — up to a thousand for the empty query — while the inspector ran its own copy of the same parsers for the selection. None of that depends on the query, and an entry never changes after capture.

Deletion test: delete the parsers from the row builder, the inspector, and the coordinator's preview check, and the decision does not scatter — it concentrates into one classifier with three readers. That is the signal for a deep module, and it is why the classifier lives in the engine (`FloodlightEngine`), which imports no UI framework and is where Clipboard History already lives.

#73's body places classification in the capture service; its follow-up comment and #58 place it in the engine, at record time. The latter wins: the store is the one writer of Clipboard History, so an entry classified by its record can never be stored without its classification, and a fixture built in a test reads exactly as a captured entry does.

## What is stored

Two additive columns on `clipboard_entries`, `content_kind` and `content_detail`, added by the same duplicate-column-tolerant migration the image columns use. The detail is the one fact the kind carries: the link's domain, the colour as `#RRGGBB[AA]`, the code language, or the path as a `file://` URL string so a folder stays a folder without a stat on load. A row recorded before the columns existed is classified the first time it is read — the in-memory window on launch, an index hit later — and the result is written back in one transaction. For the window that is launch work; for a row beyond it, it is once, on the first query that returns it, and never again. The FTS update trigger now names the columns the indexed text is built from, so that write-back — and a pin or unpin — no longer re-tokenizes an entry whose text did not change.

## What moved

- The path-existence check leaves projection. A copied path is a path row whether or not the file is still there — it carries the URL and shows the file's icon; history records what was copied. Clipboard Search stats it once per selection move to decide whether Quick Look and "Show in Finder" have anything to open, and the session's reveal command honours that answer. A copied *file's* row is taken as it comes, as it always was.
- The budget below found the next two query-independent costs once parsing was gone, and they moved with it: a row's title collapses the text to one line over its UTF-8 bytes instead of walking graphemes (the same string, checked against the Character definition on the adversarial corpus), and a source application's display name is memoized alongside its URL.
- Short queries — under three UTF-8 bytes, which the trigram index cannot answer — scan a case-folded copy of each windowed entry's text (and an image's dimensions) that the store keeps in memory, instead of running a locale-aware comparison per entry per keystroke.
- The store counts every write it accepts in `mutationVersion` — record, pin, unpin, delete, clear, prune — and nothing else. Clipboard Search's one-query-deep row memo is invalidated by that number, by a new query, and by the clock ticking over a minute (rows carry their age), and by nothing else.

## What is unchanged

Rows and inspector snapshots are what they were; Result Projection's clipboard tests are the guarantee. Classification rules — what counts as a link, a colour, code, a path — are the ones the inspector already applied, with two degenerate inputs now read the same way by the list and the inspector where before they disagreed: a bare `file://` is plain text rather than a path to nothing, and a hex string in fullwidth digits, which the list gave a colour icon the inspector could not decode, is plain text. The trigram index and the search result limit are untouched. Clipboard Capture gates what is recorded exactly as before.

## Budgets

`clipboard_board_keystroke_us` bounds a search plus a thousand-row projection over a board of every kind, including a hundred 20 KB JSON entries; `clipboard_chip_switch_us` bounds the memo hit. A future row decoration that parses text again fails the first.
