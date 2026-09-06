#!/bin/sh
# Dead-code gate: Periphery over the two source targets.
#
# There is no suppression baseline, so every finding is new. Act on it: delete
# the declaration, or annotate it `// periphery:ignore` at the declaration with
# the reason it has to stay.
#
# Periphery builds nothing here. It reads the index store that check-build's
# `swift build --build-tests` already wrote, which is why this gate runs after
# the build gate and why a fresh checkout has to build before scanning.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

periphery=$(resolve_tool periphery "$FLOODLIGHT_PERIPHERY_VERSION" version)

# find_index_store
#
# Echoes the index store `swift build` wrote, or returns 1. Where that is
# depends on the build system, and the layout changed when swift-build became
# the default in Swift 6.4:
#
#   .build/debug/index/store
#       The native build system. `.build/debug` is a symlink into the target
#       triple's directory, so this also covers the old
#       .build/arm64-apple-macosx/debug/index/store path — and it is where
#       some swift-build toolchains put the store too.
#   .build/out
#       swift-build on Xcode 27: the store's v5/ directory sits at the scratch
#       root itself, beside Products/.
#   .build/*-apple-macosx/debug/index/store
#       The native layout on a machine where the `.build/debug` symlink is
#       missing.
#
# A store is recognised by its v5/units directory rather than by the path
# existing: `.build/out` is present on every swift-build machine whether or
# not an index was written into it, and scanning an empty store would report
# everything as unused. Candidates are tried newest-first, so a stale store
# left behind by the other build system is never picked over the one the
# build that just ran wrote.
find_index_store() {
    newest=
    for candidate in \
        "$PROJECT_DIR/.build/debug/index/store" \
        "$PROJECT_DIR/.build/out" \
        "$PROJECT_DIR"/.build/*-apple-macosx/debug/index/store
    do
        [ -d "$candidate/v5/units" ] || continue
        if [ -z "$newest" ] || [ "$candidate/v5/units" -nt "$newest/v5/units" ]; then
            newest="$candidate"
        fi
    done
    [ -n "$newest" ] || return 1
    echo "$newest"
}

if ! index_store=$(find_index_store); then
    echo "check-dead-code: no index store under .build" >&2
    echo "Run 'swift build --build-tests' (or 'make check-build') first: Periphery" >&2
    echo "  reads the index that build writes rather than building on its own." >&2
    exit 1
fi

if "$periphery" scan --quiet \
    --project-root "$PROJECT_DIR" \
    --config "$PROJECT_DIR/.periphery.yml" \
    --index-store-path "$index_store"
then
    echo "check-dead-code: no unused declarations"
else
    echo "check-dead-code: delete the declarations above, or annotate an intentional" >&2
    echo "  retention with '// periphery:ignore - <reason>' at the declaration." >&2
    exit 1
fi
