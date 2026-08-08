#!/bin/sh
# Formatting gate: SwiftFormat in lint mode, at the pinned version.
#
# Nothing here is worth hand-editing — `make format` fixes all of it — so the
# failure message says that rather than listing style opinions.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

swiftformat=$(resolve_tool swiftformat "$FLOODLIGHT_SWIFTFORMAT_VERSION" --version)

if "$swiftformat" --lint "$PROJECT_DIR"; then
    echo "check-format: formatting matches .swiftformat"
else
    echo "check-format: run 'make format' to fix the files listed above" >&2
    exit 1
fi
