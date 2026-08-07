#!/bin/sh
set -eu

# Floodlight's cross-target visibility is `package`-only — `public`/`open`
# is a deliberate, written-justification act, never a side effect of the
# carve. This asserts the count stays at zero.
#
# Anchored at declaration position: leading attributes, then modifiers,
# then the `public`/`open` keyword itself, then more modifiers, then an
# actual declaration keyword. That keeps it quiet on things that merely
# contain the word — `case open(URL)`, `private func open(_:asApplication:)`,
# `NSWorkspace.shared.open(...)`, a doc comment mentioning "open", an
# `.accessibilityHint` string — while still catching `final public func` and
# `@MainActor public final class`, where a bare `^\s*(public|open)\s` would
# miss the keyword sitting after other modifiers. Scoped to `*.swift` so it
# never sees the `PUBLIC` doctype keyword in Resources/Info.plist.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

MODIFIERS='(final|override|static|class|required|convenience|lazy|weak|unowned|indirect|dynamic|nonisolated|distributed|mutating|nonmutating|async|isolated|borrowing|consuming)'
ATTRIBUTE='@\w+(\([^)]*\))?'
DECL_KEYWORD='(class|struct|enum|protocol|func|var|let|init|subscript|typealias|extension|actor)'
PATTERN="^\s*(${ATTRIBUTE}\s+)*(${MODIFIERS}\s+)*(public|open)\b\s+(${MODIFIERS}\s+)*${DECL_KEYWORD}\b"

cd "$PROJECT_DIR"

set +e
matches=$(rg -n --glob '*.swift' "$PATTERN" Sources 2>&1)
status=$?
set -e

case "$status" in
    0)
        echo "check-architecture: found public/open declarations — Floodlight's cross-target surface is package-only:" >&2
        echo "$matches" >&2
        exit 1
        ;;
    1)
        echo "check-architecture: zero public/open declarations in Sources/."
        ;;
    *)
        echo "check-architecture: ripgrep failed unexpectedly (exit $status):" >&2
        echo "$matches" >&2
        exit 1
        ;;
esac
