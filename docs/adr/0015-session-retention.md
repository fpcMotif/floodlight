---
status: accepted
date: 2026-11-07
---

# Retain hidden search and clipboard board sessions for five minutes

Hidden panels in the Zig `nanoui` frontend keep their Search Session and clipboard board state for 5 minutes. When the Session Retention window expires, the panel forgets everything and releases freed pages. This replaces PR #130's standing rule that hidden panels keep nothing per session. The idle memory budget in #116 applies once the retention window expires.

## Why

Forgetting the session on every hide loses the user's query, filter chip, and selection after Escape or Return. Keeping the state in memory for 5 minutes lets the user reopen the panel and continue. Typing replaces the selected query, and pressing `→` keeps it. A timer runs the forget path at expiry so the app returns to its idle memory footprint.

## Rules

1. When the panel hides (including after a Selected-Result Action), it records the active surface's hide timestamp.
2. Search retention keeps the query, the filter chip, and the selected row's `path`. Reopening within the window restores the query fully selected. It highlights the row with that `path`, or the top row when that path is gone.
3. Clipboard board retention keeps the query, the kind filter, and the selected entry's `id`. If a newer copy matches the filter and query, the board selects the newest match on show. Otherwise the board restores the remembered `id`, or selects the top entry when that `id` is gone.
4. The search surface and the clipboard board expire independently.
5. Clearing the search field forgets that surface at once.
6. The retention length comes from the `sessionRetentionSeconds` user default (`300` seconds when unset). A value of `0` turns retention off and forgets on hide.
7. At expiry, a shell timer runs `Panel.expire()`, clears the icon cache, and returns freed pages to macOS. Retained state stays in memory only and never touches the disk.
