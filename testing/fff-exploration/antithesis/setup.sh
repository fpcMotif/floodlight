#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=${ANTITHESIS_OUTPUT_DIR:-/tmp/antithesis-output}
mkdir -p "$OUTPUT_DIR"
printf '%s\n' '{"antithesis_setup":{"status":"complete","details":{"workload":"fff-terminal-harness"}}}' >> "$OUTPUT_DIR/sdk.jsonl"
exec tail -f /dev/null
