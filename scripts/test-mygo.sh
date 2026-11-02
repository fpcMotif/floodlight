#!/bin/sh
# The MyGo frontend's gate (ADR 0012): build the Zig core it links, then
# gofmt, go vet, the race-enabled tests, and a stripped release build of the
# app and the empty-window baseline into .build/mygo.
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
ls -l "$out"
