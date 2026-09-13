#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=${ANTITHESIS_OUTPUT_DIR:-/tmp/antithesis-output}
mkdir -p "$OUTPUT_DIR"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
ARTIFACTS="$OUTPUT_DIR/bombadil-$RUN_ID"
SDK_OUTPUT="$OUTPUT_DIR/sdk-$RUN_ID.jsonl"

ANTITHESIS_SDK_LOCAL_OUTPUT="$SDK_OUTPUT" bombadil terminal test \
    --specification=/opt/floodlight/specification.ts \
    --time-limit=30s \
    --exit-on-violation \
    --columns=500 \
    --rows=40 \
    --quiescence-timeout-ms=20 \
    --output-path="$ARTIFACTS" \
    --output-path-overwrite \
    /usr/local/bin/fff-terminal-harness

[[ -s "$ARTIFACTS/trace.jsonl" ]] || { echo "error: Bombadil emitted no trace" >&2; exit 1; }
[[ -s "$SDK_OUTPUT" ]] || { echo "error: Antithesis SDK emitted no local output" >&2; exit 1; }
