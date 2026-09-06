#!/bin/sh
# Finds out-of-bounds access, use-after-free, double-free, and heap corruption.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"
# The skipped suites assert wall-clock and CPU budgets calibrated against an
# uninstrumented build. Instrumented, they measure the sanitizer rather than the
# code, so they fail on a slowdown that is the point of the run.
swift test \
    --sanitize=address \
    --scratch-path .build/address-sanitizer \
    --skip 'SearchPerformanceTests|SearchItemRankingPerformanceTests|ClipboardHistoryPerformanceTests'
