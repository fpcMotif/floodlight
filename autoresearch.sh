#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

# 1. Verification: ensure all gates and tests pass without breakage
./scripts/check-format.sh >/dev/null 2>&1 || { echo "check-format failed" >&2; exit 1; }
./scripts/check-lint.sh >/dev/null 2>&1 || { echo "check-lint failed" >&2; exit 1; }
./scripts/check-rules.sh >/dev/null 2>&1 || { echo "check-rules failed" >&2; exit 1; }
./scripts/check-architecture.sh >/dev/null 2>&1 || { echo "check-architecture failed" >&2; exit 1; }
./scripts/check-build.sh >/dev/null 2>&1 || { echo "check-build failed" >&2; exit 1; }
./scripts/check-dead-code.sh >/dev/null 2>&1 || { echo "check-dead-code failed" >&2; exit 1; }

# 2. Build the deliverable bundle and DMG
make bundle dmg >/dev/null 2>&1 || { echo "make bundle dmg failed" >&2; exit 1; }

APP_PATH=".build/Floodlight.app"
BIN_PATH="$APP_PATH/Contents/MacOS/Floodlight"
DMG_PATH=".build/Floodlight.dmg"

if [ ! -d "$APP_PATH" ] || [ ! -f "$BIN_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    echo "Build artifacts missing" >&2
    exit 1
fi

# Measure deliverable sizes in bytes
APP_BYTES=$(du -sk "$APP_PATH" | awk '{print $1 * 1024}')
BIN_BYTES=$(stat -f %z "$BIN_PATH")
DMG_BYTES=$(stat -f %z "$DMG_PATH")

# 3. Measure latency and startup performance via performance test suite
PERF_LOG=".build/autoresearch-perf.log"
swift test -c release --filter 'PerformanceTests' >"$PERF_LOG" 2>&1 || { echo "Performance tests failed" >&2; exit 1; }

APP_SEARCH_US=$(grep "fast_application_search_us=" "$PERF_LOG" | sed -E 's/.*fast_application_search_us=([0-9.]+).*/\1/' | head -n 1)
STARTUP_MS=$(grep "source_immediate_snapshot_ms=" "$PERF_LOG" | sed -E 's/.*source_immediate_snapshot_ms=([0-9.]+).*/\1/' | head -n 1)
TOP_RANKED_US=$(grep "top_ranked_selection_us=" "$PERF_LOG" | sed -E 's/.*top_ranked_selection_us=([0-9.]+).*/\1/' | head -n 1)
FUZZY_US=$(grep "fuzzy_matcher_scoring_us=" "$PERF_LOG" | sed -E 's/.*fuzzy_matcher_scoring_us=([0-9.]+).*/\1/' | head -n 1)

STARTUP_US=$(python3 -c "print(f'{(float(\"${STARTUP_MS}\") * 1000):.3f}')")

# Primary Metric (Deliverable Size in Bytes)
echo "METRIC deliverable_size_bytes=${APP_BYTES}"

# Secondary Metrics
echo "METRIC dmg_size_bytes=${DMG_BYTES}"
echo "METRIC binary_size_bytes=${BIN_BYTES}"
echo "METRIC search_latency_us=${APP_SEARCH_US}"
echo "METRIC startup_latency_us=${STARTUP_US}"
echo "METRIC selection_latency_us=${TOP_RANKED_US}"
echo "METRIC fuzzy_scoring_us=${FUZZY_US}"
