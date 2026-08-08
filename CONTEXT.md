# Floodlight

Floodlight turns a person’s current search intent into progressively refined local and addressed results while preserving a keyboard-first interaction.

## Language

**Search Session**:
The user’s active interaction with Floodlight, including the current query, mode, filter, and selection.
_Avoid_: Search lifecycle, coordinator state

**Search Execution**:
The live attempt to answer the current query, progressively incorporating available matches and later source changes. It remains idle while settled and ends when superseded or explicitly cancelled.
_Avoid_: Search task, search pipeline

**Search Source**:
An origin of searchable candidates with its own readiness and refresh behavior. Files, applications, and System Settings are Search Sources.
_Avoid_: Provider, backend

**Source Search**:
The part of a Search Execution that queries Search Sources and normalizes their candidates. It excludes calculator answers, Floodlight commands, addressed-search rows, and the web fallback.
_Avoid_: Local search, catalog search

**Search Snapshot**:
The complete normalized Search Source candidates and progress currently known for a Search Execution. Cross-source collisions are already resolved; a settled snapshot has no pending work, and each newer snapshot replaces the previous snapshot rather than requiring it to be merged.
_Avoid_: Search delta, partial update

**Result Projection**:
The presentation policy that turns the current search context into the rows, filters, selection, and progress shown for a Search Session.
_Avoid_: Result builder, result pipeline

**Result Publication**:
One coherent, atomically visible statement of all projected rows, visible rows, filter state, semantic selection, and search progress for a Search Session.
_Avoid_: Published fields, result state

**Degraded Search**:
A search execution whose available sources still produce usable candidates while one or more expected sources are unavailable. Degradation never discards candidates from healthy sources.
_Avoid_: Failed search, partial failure
