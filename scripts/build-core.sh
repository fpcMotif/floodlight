#!/bin/sh
# Builds core/ into the static archive FloodlightEngine links.
#
# SwiftPM cannot run Zig itself, so every Make target that builds Swift runs
# this first. It fetches the pinned Zig on first use, which is what lets a
# clean checkout go straight to `make debug` or `make test`.
#
# The macOS target names the package's deployment floor (macOS 14). A native
# build would stamp the host's SDK version on every object, and ld then warns
# on each one when it links them into a macOS 14 binary.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

"$SCRIPT_DIR/install-zig.sh" >/dev/null
zig=$(resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target=aarch64-macos.14.0 ;;
    Darwin-x86_64) target=x86_64-macos.14.0 ;;
    *) target=native ;;
esac

cd "$PROJECT_DIR/core"
"$zig" build --release -Dtarget="$target" --prefix "$PROJECT_DIR/core/zig-out"
