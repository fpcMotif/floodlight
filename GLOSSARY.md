# Nanospot

Nanospot is a keyboard-first macOS launcher. It finds apps, files, web destinations, and clipboard history from one panel.

## Language

### Session and presentation

**Panel Presence**:
Whether the Nanospot panel is `hidden`, `entering`, or `shown`. It governs window reveal, focus loss, and post-action dismissal.
_Avoid_: Window state, visibility flag

**Search Session**:
The active interaction in the panel. It holds the query, mode, filter, completion, and selection.
_Avoid_: Search lifecycle, coordinator state

**Session Retention**:
The bounded in-memory window that keeps hidden Search Session and clipboard board state. Expiry frees that state and idle memory.
_Avoid_: Session cache, state persistence, draft recovery

**Result Publication**:
The coherent list of rows, filtered rows, counts, and selection that a query answers in the panel.
_Avoid_: Result builder, result state

**Selected-Result Action**:
An open, paste, copy, or Finder-reveal request on the selected row. It records query history, app opens, and dismissal effects.
_Avoid_: Panel command, item command

**Global Hot-Key Registration**:
The main-thread lifetime of Nanospot's system-wide shortcuts for search and the clipboard board.
_Avoid_: Hot-key manager, shortcut framework

**Full Disk Access Grant**:
The onboarding flow that tracks permission across `idle`, `guiding`, `granted`, and `dismissed` phases. It floats the drag card beside System Settings and rebuilds the File Index once access arrives.
_Avoid_: FDA coordinator, grant coordinator, guidance panel

### Sources and indexing

**Search Execution**:
The live work that answers the current query across apps, the File Index, and web suggestions. Newer queries supersede older replies.
_Avoid_: Search task, search pipeline

**Search Source**:
An origin of local candidates with its own scan and refresh lifecycle. Installed applications and the File Index are Search Sources.
_Avoid_: Provider, backend

**Source Search**:
The part of a Search Execution that scores applications, queries the File Index, and swaps fresh index mappings between searches. It excludes web rows.
_Avoid_: Local search, catalog search

**Search Scope**:
The home folder tree that the File Index scans and maps for file search.
_Avoid_: Search root, index path

**File Index**:
The memory-mapped record of file and folder names under the Search Scope. Each fresh scan atomically replaces the whole record.
_Avoid_: Flix, names file, index file

### Clipboard

**Clipboard History**:
The local SQLite and image-folder record of copied items. It owns capture skip rules and classifies each entry once on record.
_Avoid_: Clipboard cache, pasteboard manager

**Clipboard Entry**:
One immutable recorded or pinned copy in Clipboard History. Its content (`plain`, `link`, `color`, `code`, or `path`) never changes.
_Avoid_: Clip, item, history item, clipboard row

**Clipboard Capture**:
The periodic poll that records pasteboard changes into Clipboard History. It skips sensitive, transient, oversized, and self-written copies.
_Avoid_: Pasteboard watcher, clipboard listener

**Clipboard Inspector**:
The detail pane on the clipboard board. It previews the selected Clipboard Entry's text, picture, file head, or metadata.
_Avoid_: Preview sidebar, detail view
