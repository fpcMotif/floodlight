#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
require_tools

RUN_ID=${BOMBADIL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_DIR=${BOMBADIL_OUTPUT_PATH:-$EXPLORATION_ROOT/artifacts/$RUN_ID}
TIME_LIMIT=${BOMBADIL_TIME_LIMIT:-5s}
COLUMNS=${BOMBADIL_COLUMNS:-300}
ROWS=${BOMBADIL_ROWS:-16}
SCROLLBACK=${BOMBADIL_SCROLLBACK_LINES_MAX:-5}
QUIESCENCE=${BOMBADIL_QUIESCENCE_TIMEOUT_MS:-20}
write_metadata "$RUN_DIR" "$COLUMNS" "$ROWS" "$SCROLLBACK" "$QUIESCENCE"

"$BOMBADIL_BIN" terminal test \
  --specification="$EXPLORATION_ROOT/specification.ts" \
  --time-limit="$TIME_LIMIT" \
  --columns="$COLUMNS" \
  --rows="$ROWS" \
  --scrollback-lines-max="$SCROLLBACK" \
  --quiescence-timeout-ms="$QUIESCENCE" \
  --output-path="$RUN_DIR" \
  --output-path-overwrite \
  "$HARNESS"

[[ -s "$RUN_DIR/trace.jsonl" ]] || { echo "error: Bombadil produced no trace at $RUN_DIR/trace.jsonl" >&2; exit 1; }
echo "Bombadil artifacts: $RUN_DIR"
