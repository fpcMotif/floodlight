---
status: accepted
date: 2026-09-07
---

# Put Clipboard mode behind Clipboard Search

Floodlight moves Clipboard mode's behavior out of `SearchCoordinator` into one main-actor, observable `ClipboardSearch` module in the macOS shell. It composes Clipboard History (`ClipboardHistoryStore`), Result Projection's clipboard context ([ADR 0002](0002-result-publication.md)), and the Clipboard Inspector. Clipboard Search is the part of a Search Session in Clipboard mode that turns the query, filter, and selection into Clipboard Entry rows, the Clipboard Inspector snapshot, pin and preview facts, and restore payloads, and applies pin, unpin, and delete to Clipboard History. It decides no Search Mode transitions and is not a Search Source.

## What Clipboard Search owns

Its interface is asked for things, not handed the store. `publication(query:selectedFilter:selection:)` returns the Result Publication for Clipboard mode and, as a side effect, reconciles the selection against the returned rows; `selectionDidMove(to:)` reports a selection move that leaves the rows unchanged, such as an arrow key or a click. Four published values follow the selection: `inspector`, `isSelectionPinned`, `isSelectionPreviewable`, and `selectionFileURL`. All four are recomputed together when the selection or the store changes — never inside a getter, so a view body asking never triggers a store read or an image decode.

```swift
func publication(
    query: String,
    selectedFilter: SearchResultFilter,
    selection: SearchResultSelection?
) -> SearchResultPublication
func selectionDidMove(to item: SearchItem?)

private(set) var inspector: ClipboardInspector?
private(set) var isSelectionPinned: Bool
private(set) var isSelectionPreviewable: Bool
private(set) var selectionFileURL: URL?

@discardableResult func pinSelection() -> Bool
@discardableResult func unpinSelection() -> Bool
@discardableResult func togglePinSelection() -> Bool
@discardableResult func deleteSelection() -> Bool

func restorePayload(for entryID: String) -> ClipboardRestorePayload?
nonisolated func fullImageData(for entryID: String) -> Data?
func materializePreviewURL() -> URL?
```

`pinSelection`, `unpinSelection`, `togglePinSelection`, and `deleteSelection` each apply to the selected entry and return whether the store accepted the write. `restorePayload(for:)` returns a `ClipboardRestorePayload` — exact text, native file references, or the captured image's PNG and TIFF bytes. Activation asks for it when a row names its entry rather than carrying the value, which today is a captured image; text and file rows carry theirs in the action, so this is the one payload read that path performs. `fullImageData(for:)` is `nonisolated`: it is the pane's one off-main-actor payload read, for drawing a full-size image once its thumbnail is already on screen. `materializePreviewURL()` is the one writer of Quick Look's temporary file; it is an action, not a question, so `isSelectionPreviewable` decides whether the affordance is live before it ever runs.

The row identifier is a private implementation detail of Clipboard Search. `rowID(forEntryID:)` and `entryID(forRowID:)` are the only mapping between Clipboard Entry identity and row identity: Result Projection calls the former when it builds a row, and the board's image cache calls the latter, so the spelling lives in one place rather than at every site that could drift from it. Nothing else parses a row identifier. The preview's temporary directory and the clock the rows' relative ages are read against are both injected, so tests can pin them.

## What the coordinator retains

`SearchCoordinator` keeps Search Mode transitions — Tab, Shift-Tab, Escape, Backspace-on-empty — the query, the `selectFilter` and `select` intents, and the Result Publication Clipboard Search returns. It asks Clipboard Search for a publication on entering Clipboard mode and again on every query or filter change; on leaving Clipboard mode it publishes the idle local publication instead. Selection moves that don't change the rows are reported through `selectionDidMove(to:)`.

Commands notify the session through one hook Clipboard Search exposes, `historyDidChange`, installed once by the coordinator. A pin, unpin, or delete runs the hook, and the session responds by re-asking for a publication; the session never learns which command ran, and a new clipboard command never adds a branch to the coordinator. The coordinator keeps two thin delegations the panel reads for Space and Quick Look, `isSelectionPreviewable` and `previewableSelectionURL`, which in Clipboard mode forward to Clipboard Search.

## Composition

The application shell creates Clipboard History once and hands it to both Clipboard Capture and Clipboard Search; the coordinator receives Clipboard Search, not the store. Clipboard Capture no longer reaches into the coordinator to get at the store. `SearchView` branches on Clipboard mode once: the well holds the coordinator for the session's rows and intents, and hands the inspector pane and the footer only Clipboard Search's published values, the board context, and the three Selected-Result commands the footer's chips and Actions menu dispatch. The Selected-Result Action performer receives one narrow restore-payload operation supplied by Clipboard Search, in the pattern [ADR 0005](0005-selected-result-action-execution.md) uses for Source Selection Learning; the performer's action policy — dismiss only after the clipboard accepts the value — is unchanged.

## Why the store needs no protocol

`ClipboardHistoryStore` already has two adapters behind one type: an on-disk SQLite database and an in-memory SQLite database (`inMemory()`). Tests drive Clipboard Search through its own interface using the in-memory store, so a protocol over the store would add a seam with one production conformance and no second implementation that differs in behavior. Clipboard Search's interface is expressed as operations and published values rather than store access, so a future storage adapter can be substituted behind Clipboard Search without the coordinator, or anything above it, changing.

## Why the module is shell-side

The Clipboard Inspector already needs the filesystem and AppKit for file facts, thumbnails, and app names. Result Projection is shell-local presentation policy, as established by ADR 0002. The preview action writes into the temporary directory. None of that belongs in `FloodlightEngine`, which stays free of UI frameworks.

## Considered options

- **Keep the branches in `SearchCoordinator`:** rejected because seven places already knew the store and the row prefix, and every clipboard feature since #50 added another branch.
- **A store protocol:** rejected because the store has one production conformance and no second implementation that differs in behavior; see above.
- **Put Clipboard Search in `FloodlightEngine`:** rejected because the inspector and the preview action need AppKit and the filesystem.
- **Have Clipboard Search own the Result Publication itself:** rejected because two owners for one publication contradicts ADR 0002; it would make Clipboard Search a second coordinator.
- **Make the coordinator wrap each command:** rejected because every new command would be one more coordinator branch, which is what this seam exists to end.

## Consequences

A test suite drives Clipboard Search through its interface with an in-memory store — rows, inspector snapshot, pin state, previewability, restore payloads, and the preview action — without rendering a view or asserting on how row identifiers are formed. The coordinator's clipboard-mode suite shrinks to mode transitions and delegation. Result Projection's clipboard tests are unchanged and remain the guarantee that visible rows are identical. The performance budget for producing the clipboard publication with an image entry selected, measured without a payload read, is attached to Clipboard Search. #72's inspector snapshot and preview action already live inside Clipboard Search; #73's memoization keyed by store mutation version and #58's clipboard slices target it directly rather than the coordinator.
