#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR=$(cd "$PROJECT_DIR" && swift build --show-bin-path)

exec "$BIN_DIR/Floodlight"
