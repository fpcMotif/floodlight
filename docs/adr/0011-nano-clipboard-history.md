---
status: accepted
date: 2026-11-07
---

# Nano's Clipboard History owns capture rules and classifies once

In the Zig frontend, `frontends/nanoui/src/clipboard.zig` is Clipboard History. Clipboard History decides what a copy becomes, classifies each Clipboard Entry when it is recorded, and keeps every picture as a file. `mac.zig` reads the pasteboard, and the board draws. Neither one decides anything about an entry. ADR 0009 made the same choice for the Swift app. This ADR records it for the Zig port on its own terms, because the Zig port is the line that continues.

## Why

Before this, four modules shared the decision:

- `mac.readPasteboard` held the capture rules: the skipped pasteboard types, the order files, then a picture, then text, the size caps, and the "Screenshot" name. Those rules sat between Objective-C calls, so no test reached them.
- `Entry.content()` ran the classifier on every call. The board called it several times per row on every frame. Then the board parsed the text again for the domain, the colour or the code language, because `content()` returned only the kind.
- The board called `stat` on a copied path on every frame, to decide whether Preview was live.
- A `:memory:` store without an images folder kept pictures inline in SQLite. Tests and the hidden fallback used that path, so they never ran the file path that production uses.

Deletion test: delete the rules from the adapter, the parsers from the board, and the inline branch from the store. The decisions collect in Clipboard History, and nothing else is lost.

## Interface

- `Store.capture(arena, pasteboard, app, now) !bool` records a copy. `Pasteboard` is a reader with five functions: `has_type`, `file_paths`, `image_byte_count`, `image` and `text`. Each one reads a single representation. A picture is decoded only after the files lose and its byte count fits under the cap. `mac.PasteboardReader` is the Cocoa adapter. Tests use a fake reader, so two adapters sit at this seam.
- `Entry.content` is a `Content` union. It holds `plain`, `link` with a domain, `color` with an `Rgba`, `code` with a language, or `path`. It is decided once, in `Store.add`, and stored in the `content_kind` and `content_detail` columns. The board only reads it.
- `facts(entry)` makes one `stat`, and the board keeps the answer for the entry the selection rests on. `Store.load(arena, entry, facts)` reads the full picture or a file's head. The board calls it once, after the held-arrow delay. No `stat` and no read runs while the board draws.
- `Store.open(path, images)` always takes a folder for pictures. `:memory:` means the rows live in memory. Pictures still go to the folder, so tests and the fallback store run the production path. The hidden, snapshot and open-failure modes use `$TMPDIR/floodlight-nano-<pid>-images`, and that folder is removed on exit.

## Migration

Two columns, `content_kind TEXT` and `content_detail TEXT`, are added through the duplicate-tolerant `ALTER TABLE` list. On `open`, every row with a NULL `content_kind` is classified in one transaction. History holds at most 5 000 entries, so the backfill runs once and stays bounded. The old `png` column stays only so that `moveInlineImagesOut` can move pictures out of older stores.

## Considered options

- **Classify in `list()` with no schema change:** rejected. It classifies up to 1 000 rows for each query, and each keystroke runs a query.
- **Keep the inline-image path for `:memory:`:** rejected. One store type held two behaviours, and the store that tests used did not stand in for production.
- **Pass the size cap to the adapter's `image` call:** rejected. That would put a capture rule back in the adapter, and a fake would need its own copy of the rule.
