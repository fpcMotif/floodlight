#!/bin/sh
# Finds data races hidden by ordinary deterministic test runs.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"
# The skipped suites assert wall-clock and CPU budgets calibrated against an
# uninstrumented build. Instrumented, they measure the sanitizer rather than the
# code, so they fail on a slowdown that is the point of the run.
swift test \
    --sanitize=thread \
    --scratch-path .build/thread-sanitizer \
    --skip 'SearchPerformanceTests|SearchItemRankingPerformanceTests|ClipboardHistoryPerformanceTests'
