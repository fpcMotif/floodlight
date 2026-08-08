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

# tool_candidates <name>
#
# Where a tool may live, best first: the pinned copy in .tools/bin, then
# whatever is on PATH. Also used by scripts/install-tools.sh, so the two agree
# on what "already installed" means.
tool_candidates() {
    echo "$TOOLS_BIN/$1"
    command -v "$1" 2>/dev/null || true
}

# tool_version <path> <version-argument>
#
# The first dotted number the binary prints. Every tool here reports its version
# differently (`swiftlint version`, `swiftformat --version`, a bare `3.8.0`),
# and none of them prints an unrelated number first.
tool_version() {
    "$1" "$2" 2>/dev/null | tr -d '\r' | grep -o '[0-9][0-9.]*' | head -1
}

# tool_at_version <name> <expected-version> <version-argument>
#
# True when some candidate is already at the pinned version.
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

# find_ripgrep
#
# Echoes the path to an rg built with PCRE2 and returns 0, or returns 1 quietly.
# The quiet form matters: install-tools.sh needs to ask "is one present?" and
# carry on either way, which it could not do if this exited.
#
# Deliberately not version-pinned. The tools above are pinned exactly because
# their rule sets change between releases and so change the verdict; ripgrep
# contributes no rules, only the engine for a pattern check-architecture.sh
# supplies. What actually matters is the one capability that pattern needs — so
# that is what gets checked, by running it rather than by parsing a version.
find_ripgrep() {
    for candidate in $(tool_candidates rg); do
        [ -x "$candidate" ] || continue
        if echo 'public func' | "$candidate" --pcre2 -q '(?:public)\s+func' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# resolve_ripgrep
#
# find_ripgrep, or explain what to install and exit 1.
resolve_ripgrep() {
    if found_rg=$(find_ripgrep); then
        echo "$found_rg"
        return 0
    fi

    echo "rg: no ripgrep with PCRE2 support found" >&2
    echo "scripts/check-architecture.sh needs '--pcre2' for its declaration pattern." >&2
    echo "Run 'make install-tools' to fetch the pinned binary into .tools/bin." >&2
    exit 1
}

# resolve_tool <name> <expected-version> <version-argument>
#
# Echoes the path to a usable binary, or explains what to install and exits 1.
resolve_tool() {
    # Reset per call: POSIX sh has no `local`, so without this a second call
    # reports the previous tool's paths in its error message.
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
    echo "Run 'make install-tools' to fetch the pinned binaries into .tools/bin." >&2
    exit 1
}
