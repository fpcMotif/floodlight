#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
require_tools

SOURCE=${1:?usage: replay.sh ARTIFACT_DIRECTORY [OUTPUT_DIRECTORY]}
METADATA="$SOURCE/metadata.json"
TRACE="$SOURCE/trace.jsonl"
[[ -s "$METADATA" && -s "$TRACE" ]] || { echo "error: replay requires metadata.json and trace.jsonl in $SOURCE" >&2; exit 1; }

read_option() {
  bun -e 'const value = await Bun.file(process.argv[1]).json(); console.log(process.argv[2].split(".").reduce((part, key) => part[key], value));' "$METADATA" "$1"
}

[[ "$(read_option bombadil.sha256)" == "$(sha256 "$BOMBADIL_BIN")" ]] || { echo "error: replay Bombadil differs from the recorded binary" >&2; exit 1; }
[[ "$(read_option harness.sha256)" == "$(sha256 "$HARNESS")" ]] || { echo "error: replay harness differs from the recorded binary" >&2; exit 1; }

OUTPUT=${2:-$SOURCE/replay-$(date -u +%Y%m%dT%H%M%SZ)}
COLUMNS=$(read_option options.columns)
ROWS=$(read_option options.rows)
SCROLLBACK=$(read_option options.scrollbackLinesMax)
QUIESCENCE=$(read_option options.quiescenceTimeoutMs)

"$BOMBADIL_BIN" terminal test \
  --specification="$EXPLORATION_ROOT/specification.ts" \
  --columns="$COLUMNS" \
  --rows="$ROWS" \
  --scrollback-lines-max="$SCROLLBACK" \
  --quiescence-timeout-ms="$QUIESCENCE" \
  --reproduce="$TRACE" \
  --output-path="$OUTPUT" \
  --output-path-overwrite \
  "$HARNESS"

[[ -s "$OUTPUT/trace.jsonl" ]] || { echo "error: replay produced no trace" >&2; exit 1; }
echo "Replay artifacts: $OUTPUT"
