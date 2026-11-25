#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
cd "$PROJECT_DIR/app"

"$zig" fmt --check build.zig build.zig.zon src
"$zig" build test --summary all
"$zig" build bench --release
"$zig" build bundle --release

bin="zig-out/Nanospot.app/Contents/MacOS/nanospot"
ls -l "$bin"
requirement=$(codesign -d -r- "zig-out/Nanospot.app" 2>&1)
case "$requirement" in
*'designated => identifier "com.nanospot.app"'*) ;;
*)
    echo "test-nanoui: the bundle's designated requirement must name com.nanospot.app, not a cdhash, or every build loses its Accessibility grant:" >&2
    echo "$requirement" >&2
    exit 1
    ;;
esac
mkdir -p "$PROJECT_DIR/.build"
"$bin" --nanoui-snapshot="$PROJECT_DIR/.build/nanoui-panel.png" --nanoui-script="type:cal"
