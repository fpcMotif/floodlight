#!/bin/sh
# Builds libfloodlight_core.a for the GPUI frontend to link. Release mode: the
# frontend's latency numbers are only meaningful against an optimized core.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)
cd "$PROJECT_DIR/core"
"$zig" build --release --prefix "$PROJECT_DIR/.build/core"
