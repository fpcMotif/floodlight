#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR=${ANTITHESIS_OUTPUT_DIR:-/tmp/antithesis-output}
OUTPUT_PATH=${ANTITHESIS_SDK_LOCAL_OUTPUT:-$OUTPUT_DIR/sdk.jsonl}
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
ANTITHESIS_SDK_LOCAL_OUTPUT="$OUTPUT_PATH" /usr/local/bin/fff-terminal-harness --antithesis-setup
exec tail -f /dev/null
