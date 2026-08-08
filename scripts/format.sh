#!/bin/sh
# Applies the one deterministic style. The fix side of scripts/check-format.sh.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

swiftformat=$(resolve_tool swiftformat "$FLOODLIGHT_SWIFTFORMAT_VERSION" --version)

"$swiftformat" "$PROJECT_DIR"
