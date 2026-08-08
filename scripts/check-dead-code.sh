#!/bin/sh
# Dead-code gate: Periphery over the two source targets.
#
# There is no suppression baseline, so every finding is new. Act on it: delete
# the declaration, or annotate it `// periphery:ignore` at the declaration with
# the reason it has to stay.
#
# Periphery builds the package to produce an index, so this is the slowest step
# in the gate and runs last.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

periphery=$(resolve_tool periphery "$FLOODLIGHT_PERIPHERY_VERSION" version)

if "$periphery" scan --quiet --project-root "$PROJECT_DIR" --config "$PROJECT_DIR/.periphery.yml"; then
    echo "check-dead-code: no unused declarations"
else
    echo "check-dead-code: delete the declarations above, or annotate an intentional" >&2
    echo "  retention with '// periphery:ignore - <reason>' at the declaration." >&2
    exit 1
fi
