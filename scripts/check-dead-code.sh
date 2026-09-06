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

# Periphery exits 1 both for "found unused declarations" and for "could not
# scan at all" — a missing index store, an unreadable config. Reporting the
# second as the first sends whoever is reading the log looking for declarations
# that were never printed, so the two verdicts are told apart by what the scan
# actually reported rather than by its exit status.
report=$(mktemp)
trap 'rm -f "$report"' EXIT INT TERM

status=0
"$periphery" scan --quiet --project-root "$PROJECT_DIR" \
    --config "$PROJECT_DIR/.periphery.yml" >"$report" || status=$?

cat "$report"

if [ "$status" -eq 0 ]; then
    echo "check-dead-code: no unused declarations"
    exit 0
fi

# A finding is a source location: `path/File.swift:12:5: warning: ...`. A
# tooling failure has none, whichever stream Periphery chose to print it on.
if grep -Eq '^.+:[0-9]+:[0-9]+: (warning|error):' "$report"; then
    echo "check-dead-code: delete the declarations above, or annotate an intentional" >&2
    echo "  retention with '// periphery:ignore - <reason>' at the declaration." >&2
else
    echo "check-dead-code: the scan failed (exit $status) — nothing was analysed, so" >&2
    echo "  this is not a dead-code finding. Fix the tooling or configuration error" >&2
    echo "  reported above." >&2
fi
exit 1
