#!/bin/sh
# Finds data races hidden by ordinary deterministic test runs.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"
swift test \
    --sanitize=thread \
    --scratch-path .build/thread-sanitizer \
    --skip 'SearchPerformanceTests|SearchItemRankingPerformanceTests'
