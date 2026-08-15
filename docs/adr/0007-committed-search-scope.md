---
status: accepted
date: 2026-08-09
---

# Publish only a committed Search Scope

Floodlight will continue displaying its current Search Scope while a requested folder change is pending. The selected folder becomes the new Search Scope only after Source Search confirms that its index is ready. The shell then publishes and persists the new scope as consequences of that same successful operation.

A folder picker returns a candidate URL, not an already-applied scope. A failed change preserves the previous displayed, active, and persisted scope. This keeps one truthful value across configuration UI, shell state, preferences, and Source Search instead of requiring callers to reconcile optimistic and committed representations.

This decision does not require the interface to remain visually silent while work is pending. A later design may publish progress or a non-modal failure message, but pending presentation must not replace the committed scope with an unconfirmed candidate.

## Considered options

- **Display the candidate immediately and model rollback:** rejected because it introduces requested-versus-committed state, allows configuration to finish against an unready source, and requires explicit rollback behavior.
- **Keep displaying the committed scope until success:** accepted because one value remains truthful and failure naturally preserves the previous working configuration.
- **Keep the existing optimistic display without pending or rollback state:** rejected because the application can claim to search a folder that Source Search rejected.

## Consequences

The Search Scope owner must await the existing throwing Source Search change operation before publishing or persisting. Shell-level tests must cover successful commit, failed-change preservation, preference preservation, and overlapping requests. `RootPicker` remains a mechanical AppKit chooser and Source Search retains index preparation and rollback ownership.
