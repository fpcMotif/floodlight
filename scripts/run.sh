#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR=$(cd "$PROJECT_DIR" && swift build --show-bin-path)

cp "$PROJECT_DIR/Native/lib/libfff_c.dylib" "$BIN_DIR/libfff_c.dylib"
exec "$BIN_DIR/Floodlight"
