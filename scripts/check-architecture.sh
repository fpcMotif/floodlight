#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

# Modularization is being carved in slices (see issue #12). Once every
# target's directory exists, this script also grows import-direction
# assertions (e.g. FloodlightEngine must never import the shell, and only
# the shell may import FFFKit). For now it only enforces the rule every
# slice already needs: nothing under Sources declares `public` or `open`.
# Cross-target sharing goes through `package`, which is invisible to
# anything outside this Swift package and keeps FloodlightEngine's surface
# no wider than the shell actually forces it to be.
#
# The pattern is anchored at declaration position, not just "the word
# public/open appears somewhere in the line" — a naive scan is red on a
# clean tree, since `open` shows up repeatedly in Sources without ever being
# an access modifier: `case open(URL)`, `private func open(_:asApplication:)`,
# `NSWorkspace.shared.open`, a doc comment, an `.accessibilityHint` string.

# Matches a `public`/`open` access modifier sitting directly on a
# declaration, in any order Swift allows relative to attributes and other
# modifiers (`public func`, `final public func`, `@MainActor public final
# class`, `public extension`, ...). It intentionally does not match `open`
# used as an identifier, case name, or method call (`case open(URL)`,
# `NSWorkspace.shared.open`, `private func open(...)`) because none of
# those are followed by whitespace then a declaration keyword.
ATTR='(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?\s+)*'
MODIFIER='(?:final|static|class|override|mutating|nonmutating|convenience|required|lazy|weak|unowned|indirect|dynamic|nonisolated|distributed|infix|prefix|postfix|actor)'
MODIFIERS="(?:${MODIFIER}\\s+)*"
KEYWORD='(?:func|var|let|class|struct|enum|protocol|typealias|init|subscript|extension|actor)'
PATTERN="^\\s*${ATTR}${MODIFIERS}\\b(public|open)\\b\\s+${MODIFIERS}\\b${KEYWORD}\\b"

set +e
rg --pcre2 --line-number --glob '*.swift' "$PATTERN" "$PROJECT_DIR/Sources"
status=$?
set -e

case "$status" in
    0)
        echo "check-architecture: found public/open declarations above — use 'package' instead" >&2
        exit 1
        ;;
    1)
        echo "check-architecture: no public/open declarations in Sources"
        ;;
    *)
        echo "check-architecture: ripgrep failed (exit $status)" >&2
        exit 1
        ;;
esac
