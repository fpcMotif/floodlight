---
status: accepted
date: 2026-11-07
---

# Clipboard History owns capture rules and classifies once

`app/src/clipboard.zig` (`clipboard/model.zig` and `clipboard/store.zig`) is Clipboard History in Nanospot. Clipboard History decides what a pasteboard copy becomes, classifies each Clipboard Entry once when recorded, and stores full pictures on disk. `app/src/mac/pasteboard.zig` reads the pasteboard, and `app/src/board.zig` draws the board. Neither re-parses an entry.

## Why

Splitting capture and classification across modules caused four problems:

- Pasteboard skip rules, type precedence, size caps, and screenshot naming lived inside Objective-C calls where unit tests could not reach them.
- Re-classifying text on every draw parsed links, colors, and code repeatedly per frame.
- Calling `stat` on copied paths during draw coupled frame rendering to filesystem latency.
- Keeping `:memory:` test images inline in SQLite left the production on-disk image path untested in unit suites.

Clipboard History now keeps the capture rules, content parsers, and file-backed image storage in one module.

## Interface

- `Store.capture(arena, pasteboard, app, now) !bool` records a copy through the five-function `Pasteboard` reader (`has_type`, `file_paths`, `image_byte_count`, `image`, `text`). Pictures decode only when no file URLs win and the byte count fits within the cap. `mac.PasteboardReader` adapts `NSPasteboard`, and unit tests pass a scripted reader.
- `Entry.content` is a `Content` union: `plain`, `link` with domain, `color` with `Rgba`, `code` with language, or `path`. `Store.add` classifies the text once on insert and stores `content_kind` and `content_detail` in SQLite.
- `clipboard.facts(entry)` runs at most one `stat`, and `Board` caches the result for the selected entry id. `Store.load(arena, entry, facts)` reads the full picture or file head after the held-arrow delay, so drawing never touches the disk.
- `Store.open(path, images)` requires an image directory even when `path` is `:memory:`. Headless runs use `$TMPDIR/nanospot-<pid>-images`, production uses `~/Library/Application Support/Nanospot/clipboard-images`, and unit tests exercise the same on-disk image path.

## Considered options

- **Classify in `list()` without storing columns.** Every keystroke on the board then re-parses up to 1,000 rows.
- **Keep an inline SQLite blob path for `:memory:`.** Unit tests then skip the on-disk image storage and AVIF compaction paths.
- **Enforce size caps inside `PasteboardReader`.** Every fake test reader then duplicates capture policy.
