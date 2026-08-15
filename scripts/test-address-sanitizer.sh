#!/bin/sh
# Finds out-of-bounds access, use-after-free, double-free, and heap corruption.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"
swift test \
    --sanitize=address \
    --scratch-path .build/address-sanitizer \
    --skip 'SearchPerformanceTests|SearchItemRankingPerformanceTests'
