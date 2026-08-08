#!/bin/sh
# Latency gate: the engine's budgeted performance suite, in release.
#
# Separate from `make test` because configuration is the whole point. A debug
# build's search path is several times slower and its numbers say nothing about
# what a user feels, so a budget measured in debug is either uselessly loose or
# permanently red. CI runs this as its own step for the same reason.
#
# The budgets are hard `XCTAssertLessThan` bounds inside the suites, with margin
# for shared-runner variance — they catch an order-of-magnitude regression, not
# a 10% one. Tightening them below runner noise makes the gate flaky, which
# costs more than the regression it would catch.
#
# The FLOODLIGHT_BENCH lines are the record of what the numbers actually were
# on this run; read them when a budget starts creeping.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"
log="$PROJECT_DIR/.build/performance.log"

# Not `swift test | tee`: in a pipeline the exit status is tee's, so a failed
# budget would be reported as a pass. A gate that cannot fail is not a gate.
status=0
swift test -c release --filter 'PerformanceTests' >"$log" 2>&1 || status=$?
cat "$log"

echo
if [ "$status" -eq 0 ]; then
    echo "test-performance: budgets held. Measured:"
    grep FLOODLIGHT_BENCH "$log" || echo "  (no FLOODLIGHT_BENCH lines — did the filter match anything?)"
else
    echo "test-performance: a latency budget was exceeded. Measured:" >&2
    grep FLOODLIGHT_BENCH "$log" >&2 || true
    exit "$status"
fi
