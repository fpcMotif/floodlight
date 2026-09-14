#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=${ANTITHESIS_OUTPUT_DIR:-/tmp/antithesis-output}
mkdir -p "$OUTPUT_DIR"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
ARTIFACTS="$OUTPUT_DIR/bombadil-$RUN_ID"
SDK_OUTPUT="$OUTPUT_DIR/sdk-$RUN_ID.jsonl"
TIME_LIMIT=${BOMBADIL_TIME_LIMIT:-5s}
COLUMNS=${BOMBADIL_COLUMNS:-300}
ROWS=${BOMBADIL_ROWS:-16}
SCROLLBACK=${BOMBADIL_SCROLLBACK_LINES_MAX:-5}
QUIESCENCE=${BOMBADIL_QUIESCENCE_TIMEOUT_MS:-20}

ANTITHESIS_SDK_LOCAL_OUTPUT="$SDK_OUTPUT" bombadil terminal test \
    --specification=/opt/floodlight/specification.ts \
    --time-limit="$TIME_LIMIT" \
    --exit-on-violation \
    --columns="$COLUMNS" \
    --rows="$ROWS" \
    --scrollback-lines-max="$SCROLLBACK" \
    --quiescence-timeout-ms="$QUIESCENCE" \
    --output-path="$ARTIFACTS" \
    --output-path-overwrite \
    /usr/local/bin/fff-terminal-harness

[[ -s "$ARTIFACTS/trace.jsonl" ]] || { echo "error: Bombadil emitted no trace" >&2; exit 1; }
[[ -s "$SDK_OUTPUT" ]] || { echo "error: Antithesis SDK emitted no local output" >&2; exit 1; }
grep -Fq '"antithesis_sdk"' "$SDK_OUTPUT" || { echo "error: Antithesis SDK info event missing" >&2; exit 1; }
if ! grep -F '"message":"fff-terminal-harness-started"' "$SDK_OUTPUT" | grep -Fq '"hit":true'; then
    echo "error: fff-terminal-harness Antithesis reachable property did not emit a hit" >&2
    exit 1
fi
if ! grep -F '"message":"fff-terminal-response-well-formed"' "$SDK_OUTPUT" | grep -Fq '"hit":true'; then
    echo "error: terminal response safety property did not emit a hit" >&2
    exit 1
fi
