# Clipboard Power — Mac test plan and experiments

Written on Windows, where Swift cannot build. Everything below runs on the Mac.
Tick items as you go. Sections are ordered so the cheapest de-risking comes first.

## 0. Baseline (before any new code)

- [ ] `make install-tools` then `make check` is green on `main` at `936926b`.
- [ ] `make test` passes; note the count in the summary line (expect 550+).
- [ ] `make test-performance` passes; copy the `FLOODLIGHT_BENCH clipboard_search_us=…` line here: `______`
- [ ] `make install` and grant Full Disk Access to `~/Applications/Floodlight.app` once.
- [ ] Open Clipboard mode (`clip` + Tab). Confirm the footer reads `Paste to <source app>` and that Return only copies and dismisses. This is the behaviour the spec replaces.

## 1. Spikes (throwaway, in `.scratch/clipboard-power/spikes/`, never merged)

### 1a. Paste Delivery via CGEvent

- [ ] Write a 40-line Swift script (`swift spike-paste.swift`) that: writes "hello" to the pasteboard, sleeps 300 ms, posts ⌘V key-down/up on `kCGHIDEventTap`.
- [ ] Run with TextEdit frontmost. Record: pasted? `__` delay needed? `__`
- [ ] Repeat with Safari URL bar, Terminal (`cat > /dev/null`), Xcode editor, an Electron app (VS Code), a Java app if you have one.
- [ ] Focus a password field in Safari, run the script. Confirm nothing is typed and `IsSecureEventInputEnabled()` returns true.
- [ ] Revoke Accessibility for the script host and rerun. Confirm `AXIsProcessTrustedWithOptions` returns false and no paste happens.
- [ ] Try the same from a **non-activating** `NSPanel` that calls `orderOut` then posts the event. Measure the minimum reliable delay between `orderOut` and the event: `__ ms`.

### 1b. Accessibility deep link on your macOS version

- [ ] `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"` lands on the Accessibility pane? macOS version: `__`
- [ ] Rebuild with `make install` twice. Does the Accessibility grant survive? (It should, thanks to the stable designated requirement.)

### 1c. Pasteboard markers

- [ ] Copy a password from 1Password / Bitwarden / Keychain autofill. Run `osascript -e 'the clipboard as record'` or a tiny Swift script printing `NSPasteboard.general.types`. Record which of `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `com.apple.is-sensitive` appear.
- [ ] Copy text on your iPhone, wait for Universal Clipboard, print the types. Record the remote marker: `__`
- [ ] Press ⌃⇧⌘4 (screenshot to clipboard), print the types. Record the screenshot markers: `__`

### 1d. OCR and QR timing

- [ ] Run a `VNRecognizeTextRequest` (accurate, automatic language) on a 2× Retina full-screen screenshot with mixed Chinese and English. Record wall time: `__ ms`, and whether paragraphs come back in reading order.
- [ ] Generate a QR for a 200-character URL with `CIQRCodeGenerator`, scale to 512 px, write PNG to the pasteboard. Confirm Preview shows it crisp.

### 1e. Two Carbon hot keys

- [ ] Register ⌘Space and ⇧⌘V in one process with two `EventHotKeyID`s and confirm each routes to its own handler. Check ⇧⌘V does not collide in Safari, Xcode, Slack, Terminal (Paste and Match Style is ⌥⇧⌘V; confirm).

## 2. Slice 1 — Paste Target, Paste Delivery, hotkey

- [ ] `swift test --filter SelectedResultActionPerformerTests` covers: paste with trust and target, without trust, delivery failure, plain-text form.
- [ ] `swift test --filter SearchCoordinatorClipboardModeTests` covers hotkey entry and Paste Target in the publication.
- [ ] Manual: press ⇧⌘V from Safari. Panel opens in Clipboard mode, footer reads `Paste to Safari ↵`. Return pastes into the page's focused field.
- [ ] Manual: press ⇧⌘V with Floodlight's Settings window frontmost. Footer reads `Copy ↵`.
- [ ] Manual: revoke Accessibility. Footer reads `Copy ↵`, hint row appears once, its button opens the right pane, dismissing the hint persists across relaunch.
- [ ] Manual: ⇧Return on an entry copied from a rich web page pastes plain text into Pages.
- [ ] Manual: set Return behaviour to "Copy to clipboard" in Settings. Return copies and dismisses.
- [ ] Manual: paste, then press ⌘V in the target app again. Same content pastes (pasteboard kept).
- [ ] Manual: after pasting, open Clipboard mode again. No duplicate entry was recorded.

## 3. Slice 2 — Clipboard Actions, transforms, edit

- [ ] `swift test --filter ClipboardActionComposerTests` (new): per-type action tables.
- [ ] `swift test --filter PasteTransformTests` (new): transform table, failures, Unicode.
- [ ] Manual: ⌘K on a link. Type `mark`, Return. Pasted `[title](url)` form. Escape closes the overlay with selection intact.
- [ ] Manual: link with `?utm_source=…&id=5`. "Copy without tracking parameters" keeps `id=5`.
- [ ] Manual: colour `#3498DB`. Copy as `rgb()` gives `rgb(52, 152, 219)`; SwiftUI literal compiles.
- [ ] Manual: invalid JSON, "Pretty print". Inspector shows the failure, entry unchanged.
- [ ] Manual: ⌘E, edit, Return. Edited text pastes; history has no new entry. ⌥Return on the edit records it.
- [ ] Manual: ⌘⌫ then ⌘Z within eight seconds restores the entry with its pin.
- [ ] Manual: email, phone, and address in one text. All three actions appear; Compose mail opens Mail; Open in Maps opens Maps.

## 4. Slice 3 — merging, scopes, collections

- [ ] `swift test --filter ClipboardHistoryStoreTests` includes merge-on-record, `copyCount`, preserved pin and collections, scope queries, migration of a duplicate-laden database.
- [ ] `swift test --filter ClipboardQueryParserTests` (new): adversarial corpus never throws.
- [ ] `make test-performance`: record the new `FLOODLIGHT_BENCH` lines for scoped search and record-with-merge: `______`
- [ ] Manual: copy the same text five times over a minute. One entry, subtitle `Copied 5×`, at the top.
- [ ] Manual: `from:safari is:link on:today` narrows correctly; `in:receipts` after adding entries to a collection works; `from:` with an unknown app yields empty, not an error.
- [ ] Manual: a database from before the migration (copy `~/Library/Application Support/Floodlight/clipboard.sqlite3` first) opens, duplicates are merged, pins survive.
- [ ] Manual: ⌘5 selects Pinned; collection chips appear after it.

## 5. Slice 4 — Secret Guard and ephemeral entries

- [ ] `swift test --filter SecretGuardTests` (new): rule positives, adversarial negatives, Luhn.
- [ ] `swift test --filter ClipboardCaptureServiceTests` includes policies, sensitive-app lifetime, expiry pass.
- [ ] Manual: copy a fake `ghp_` token from Terminal. Entry appears redacted with a shield and a countdown. Reveal shows it. After five minutes it is gone. Quit and relaunch before expiry: gone.
- [ ] Manual: confirm the entry never hit disk: `sqlite3 ~/Library/Application\ Support/Floodlight/clipboard.sqlite3 "select count(*) from clipboard_entries where text like 'ghp_%'"` returns 0.
- [ ] Manual: mark Terminal as sensitive with a 2-minute lifetime. Copy plain text from Terminal. It is ephemeral.
- [ ] Manual: copy a 64-character SHA-256 hex digest. It is **not** flagged. Copy a 40-character random Base64 string. Record whether it is flagged and whether "Keep" persists it.
- [ ] Manual: a 1Password copy is still skipped entirely.

## 6. Slice 5 — multi-select and Paste Stack

- [ ] `swift test --filter SearchCoordinatorClipboardModeTests` includes extension, collapse, and multi-paste.
- [ ] Manual: ⇧↓ three times, Return in TextEdit. Three lines pasted in selection order. Change separator to comma via ⌘K and repeat.
- [ ] Manual: select three entries, ⌘K "Arm paste stack". Menu bar shows `3`. In a web form, press ⇧⌘V in three fields. Each field gets the next entry; the badge counts down; after the third, ⇧⌘V opens the panel again.
- [ ] Manual: arm a stack, press ⌘Space. The panel opens normally; the stack stays armed. Cancel from the menu bar.
- [ ] Manual: arm a stack, delete one of its entries from the panel, press ⇧⌘V. The stack disarms cleanly.

## 7. Slice 6 — Clipboard Board and image actions

- [ ] `swift test --filter ClipboardBoardModelTests` (new): overview totals, retention round-trip, collections, clear by age, export then import.
- [ ] `swift test --filter SearchViewRenderingTests` includes the Board pane and the overlay in both appearances.
- [ ] Manual: Settings → Clipboard. Overview counts match `sqlite3 … "select kind, count(*), sum(length(png_data)+length(tiff_data)) from clipboard_entries group by kind"`.
- [ ] Manual: Pause for 15 minutes. Menu bar shows the paused symbol; copies are not recorded; resume from the menu bar.
- [ ] Manual: sleep the Mac for 20 minutes during a 15-minute pause. On wake, capture has resumed.
- [ ] Manual: set images retention to 1 day, add an old image by editing `last_copied_at` in SQLite, relaunch. It is pruned; a pinned old image is not.
- [ ] Manual: pick an excluded app with the picker. Its icon and name show; copies from it are skipped.
- [ ] Manual: Export to a folder; inspect `history.json` and `images/`. Clear all. Import. Counts match, pins and collections restored, no duplicates.
- [ ] Manual: Clear images, then Compact. `ls -la` the database before and after; the file shrinks.
- [ ] Manual: image entry → ⌘K "Recognize text". Text appears in the inspector; searching a word from it finds the image.
- [ ] Manual: link → "Show QR code". The inspector shows a scannable code (test with the iPhone camera).

## 8. Gate before each PR

- [ ] `make check` (format, lint, ast-grep rules, architecture, build with warnings as errors, dead code).
- [ ] `make test`, `make test-performance`, `make test-sanitizers`.
- [ ] Docs updated: keyboard-shortcuts.mdx, search.mdx (Clipboard mode), filters.mdx (Pinned and collection chips), and CONTEXT.md glossary additions from the spec.
