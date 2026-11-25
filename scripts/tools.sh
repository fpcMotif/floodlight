#!/bin/sh
# Resolves each gate tool to a binary at the pinned version.
#
# Sourced by the check scripts; not run directly. Every tool is looked for in
# `.tools/bin` first (what scripts/install-zig.sh downloads) and then on
# PATH, so a machine that already has the right version — via nix, via a
# manual install — is used as-is and nothing gets downloaded.
set -eu

SCRIPT_DIR=${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
TOOLS_BIN="$PROJECT_DIR/.tools/bin"

. "$SCRIPT_DIR/tool-versions.env"

tool_candidates() {
    echo "$TOOLS_BIN/$1"
    command -v "$1" 2>/dev/null || true
}

tool_version() {
    "$1" "$2" 2>/dev/null | tr -d '\r' | grep -o '[0-9][0-9.]*' | head -1
}

tool_at_version() {
    tool_at_version_found=1
    for candidate in $(tool_candidates "$1"); do
        [ -x "$candidate" ] || continue
        if [ "$(tool_version "$candidate" "$3")" = "$2" ]; then
            tool_at_version_found=0
            break
        fi
    done
    return "$tool_at_version_found"
}

resolve_tool() {
    mismatch=

    for candidate in $(tool_candidates "$1"); do
        [ -x "$candidate" ] || continue
        found=$(tool_version "$candidate" "$3")
        if [ "$found" = "$2" ]; then
            echo "$candidate"
            return 0
        fi
        mismatch="${mismatch}${mismatch:+, }$candidate ($found)"
    done

    if [ -n "$mismatch" ]; then
        echo "$1: need $2, found $mismatch" >&2
    else
        echo "$1: not installed (need $2)" >&2
    fi
    echo "Run 'make install-zig' to fetch the pinned toolchain into .tools/bin." >&2
    exit 1
}
