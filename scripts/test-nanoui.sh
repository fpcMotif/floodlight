#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)
cd "$PROJECT_DIR/frontends/nanoui"

"$zig" fmt --check build.zig build.zig.zon src
"$zig" build test --summary all
"$zig" build bundle --release

bin="zig-out/Floodlight Nano.app/Contents/MacOS/floodlight-nanoui"
ls -l "$bin"
mkdir -p "$PROJECT_DIR/.build"
"$bin" --nanoui-snapshot="$PROJECT_DIR/.build/nanoui-panel.png" --nanoui-script="type:cal"
