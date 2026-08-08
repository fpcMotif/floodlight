#!/bin/sh
# Swift quality gate: SwiftLint in strict mode, at the pinned version.
#
# `--strict` promotes every warning to a failure. There is no warning tier on
# purpose: a warning nobody has to fix is a warning that accumulates, and the
# thresholds in .swiftlint.yml are already set at the tree's current ceiling.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

swiftlint=$(resolve_tool swiftlint "$FLOODLIGHT_SWIFTLINT_VERSION" version)

if "$swiftlint" lint --strict --quiet --config "$PROJECT_DIR/.swiftlint.yml" "$PROJECT_DIR"; then
    echo "check-lint: no SwiftLint violations"
else
    echo "check-lint: SwiftLint violations above — see .swiftlint.yml for the rule's rationale" >&2
    exit 1
fi
