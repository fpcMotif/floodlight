#!/bin/sh
# Resolves each gate tool to a binary at the pinned version.
#
# Sourced by the check scripts; not run directly. Every tool is looked for in
# `.tools/bin` first (what scripts/install-tools.sh downloads) and then on
# PATH, so a machine that already has the right version — via nix, via a
# manual install — is used as-is and nothing gets downloaded.
#
# A tool at the wrong version is a hard failure rather than a silent
# best-effort, because "it passes on my machine" is the exact thing pinning
# exists to prevent.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
TOOLS_BIN="$PROJECT_DIR/.tools/bin"

. "$SCRIPT_DIR/tool-versions.env"

# resolve_tool <name> <expected-version> <version-argument>
#
# Echoes the path to a usable binary, or explains what to install and exits 1.
resolve_tool() {
    tool_name=$1
    expected=$2
    version_flag=$3

    for candidate in "$TOOLS_BIN/$tool_name" "$(command -v "$tool_name" 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        found=$("$candidate" "$version_flag" 2>/dev/null | tr -d '\r' | grep -o '[0-9][0-9.]*' | head -1)
        if [ "$found" = "$expected" ]; then
            echo "$candidate"
            return 0
        fi
        mismatch="${mismatch:-}${mismatch:+, }$candidate ($found)"
    done

    if [ -n "${mismatch:-}" ]; then
        echo "$tool_name: need $expected, found $mismatch" >&2
    else
        echo "$tool_name: not installed (need $expected)" >&2
    fi
    echo "Run 'make install-tools' to fetch the pinned binaries into .tools/bin." >&2
    exit 1
}
