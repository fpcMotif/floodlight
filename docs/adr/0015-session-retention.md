---
status: accepted
date: 2026-11-07
---

# Retain hidden search and clipboard board sessions for five minutes

Hidden panels in Nanospot (`app/src/panel.zig`) keep their Search Session and clipboard board state in memory for 5 minutes. When the Session Retention window expires, Nanospot forgets the expired surface and releases freed memory pages to macOS.

## Why

Forgetting session state immediately on Escape or Return discards the user's query, active filter chip, and selection between quick summons. Retaining hidden state for 5 minutes lets reopening continue immediately while still returning to the idle memory floor once the timer expires.

## Rules

1. Hiding the panel (including after a Selected-Result Action) records the active surface's hide timestamp.
2. Search retention preserves the query, filter chip, and selected row path. Reopening within the window restores the selected query and reselects the matching path or the top row. Typing replaces the restored query, and `→` keeps it.
3. Clipboard board retention preserves the query, kind filter, and selected entry `id`. If a newer copy arrived since hide and matches the active filter and query, the board selects that new entry. Otherwise the board selects the remembered `id` or the top entry.
4. Search and clipboard board retention windows expire independently.
5. Clearing the search field forgets the active surface immediately.
6. Retention duration reads the `sessionRetentionSeconds` user default. It defaults to `300` seconds, and `0` forgets state on hide.
7. At expiry, one shell timer calls `Panel.expire()`, clears cached icons, drops hidden GPU surfaces, and releases pages to macOS. Retained session state never writes to disk.
