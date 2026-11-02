#!/bin/sh
# Runs the GPUI frontend's two benches on this Mac and prints their
# FLOODLIGHT_GPUI lines: the blank-window floor, then the full panel over the
# real home folder. Needs a logged-in GUI session; it opens windows.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

bin="$PROJECT_DIR/frontends/gpui/target/release/floodlight-gpui"
log="$PROJECT_DIR/.build/gpui-bench.log"
mkdir -p "$PROJECT_DIR/.build"
: >"$log"

# A bench that never gets a frame would otherwise hang the job until the
# runner's own timeout; five minutes is many times a healthy run.
run() {
    "$bin" "$@" >>"$log" 2>&1 &
    pid=$!
    (sleep 300 && kill "$pid" 2>/dev/null) &
    watchdog=$!
    status=0
    wait "$pid" || status=$?
    kill "$watchdog" 2>/dev/null || true
    return "$status"
}

FLOODLIGHT_GPUI_INDEX="$PROJECT_DIR/.build/gpui-bench.flix" run --bench-empty
FLOODLIGHT_GPUI_INDEX="$PROJECT_DIR/.build/gpui-bench.flix" run --bench
cat "$log"

# A run that printed no idle sample did not finish; say so with the exit code.
grep -q '^FLOODLIGHT_GPUI empty_idle_rss_mb=' "$log"
grep -q '^FLOODLIGHT_GPUI idle_rss_mb=' "$log"
