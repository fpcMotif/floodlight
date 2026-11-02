#!/bin/sh
# The MyGo frontend's gate (ADR 0012): build the Zig core it links, then
# gofmt, go vet, the race-enabled tests (the shared parity fixtures among
# them), and a stripped release build of the app and the empty-window
# baseline into .build/mygo. On macOS it also wraps the app in
# "Floodlight MyGo.app" (com.floodlight.mygo), the bundle a user drags into
# the Full Disk Access list.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)
go=$(resolve_tool go "$FLOODLIGHT_GO_VERSION" version)

# The prefix internal/core's cgo flags point at.
(cd "$PROJECT_DIR/core" && "$zig" build --release --prefix "$PROJECT_DIR/.build/core")

cd "$PROJECT_DIR/frontends/mygo"
unformatted=$("$(dirname "$go")/gofmt" -l .)
if [ -n "$unformatted" ]; then
    echo "test-mygo: gofmt wants changes in:" >&2
    echo "$unformatted" >&2
    exit 1
fi
"$go" vet ./...
"$go" test -race ./...

out="$PROJECT_DIR/.build/mygo"
mkdir -p "$out"
"$go" build -trimpath -ldflags='-s -w' -o "$out/floodlight-mygo" .
"$go" build -trimpath -ldflags='-s -w' -o "$out/emptywindow" ./cmd/emptywindow

if [ "$(uname -s)" = Darwin ]; then
    app="$out/Floodlight MyGo.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp Info.plist "$app/Contents/Info.plist"
    cp "$out/floodlight-mygo" "$app/Contents/MacOS/floodlight-mygo"
    # Ad hoc: macOS ties a Full Disk Access grant to this signature, so each
    # rebuild needs `tccutil reset SystemPolicyAllFiles com.floodlight.mygo`
    # and a fresh drag.
    codesign --force --sign - --identifier com.floodlight.mygo "$app"
fi
ls -l "$out"
