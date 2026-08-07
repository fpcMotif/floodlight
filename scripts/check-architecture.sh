#!/usr/bin/env bash
#
# Enforces the package's zero-`public` invariant: every cross-module seam is
# stated in `package` access, never `public` or `open`. A public/open
# declaration would leak past the package boundary this repo is built
# around, so any occurrence here is a violation.
#
# The pattern is anchored at declaration position, not just "the word
# public/open appears somewhere in the line" — a naive scan is red on a
# clean tree, since `open` shows up 17 times in Sources without ever being
# an access modifier: `case open(URL)`, `private func open(_:asApplication:)`,
# `NSWorkspace.shared.open`, a doc comment, an `.accessibilityHint` string.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ATTR='(?:@\w+(?:\([^)]*\))?\s+)*'
MOD='(?:final|static|class|override|mutating|nonisolated|convenience|required|indirect|distributed|lazy|dynamic)'
ACCESS='(?:public|open)'
DECL='(?:func|var|let|class|struct|enum|protocol|extension|init|subscript|typealias|actor)'
PATTERN="^\\s*${ATTR}(?:${MOD}\\s+)*${ACCESS}\\b(?:\\s+${MOD})*\\s+${DECL}\\b"

status=0

check_dir() {
    local dir="$1"

    matches="$(rg -n "$PATTERN" --glob '*.swift' "$dir" 2>&1)"
    rg_status=$?

    if [ "$rg_status" -eq 0 ]; then
        echo "check-architecture: public/open declaration(s) found under $dir:" >&2
        echo "$matches" >&2
        status=1
    elif [ "$rg_status" -eq 2 ]; then
        echo "check-architecture: ripgrep failed scanning $dir:" >&2
        echo "$matches" >&2
        status=1
    fi
    # rg_status == 1 means no matches — the clean, passing case.
}

check_dir Sources

if [ "$status" -eq 0 ]; then
    echo "check-architecture: no public/open declarations found."
fi

exit "$status"
