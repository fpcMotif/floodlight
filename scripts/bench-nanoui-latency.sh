#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
cd "$PROJECT_DIR/app"
"$zig" build bundle --release

bin="$PWD/zig-out/Nanospot.app/Contents/MacOS/nanospot"
scratch_home=$(mktemp -d "${TMPDIR:-/tmp}/nanospot-latency.XXXXXX")
trap 'rm -rf "$scratch_home"' EXIT INT TERM
mkdir -p "$scratch_home/Applications"

HOME="$scratch_home" "$bin" --nanospot-memory-seed >/dev/null 2>&1
HOME="$scratch_home" "$bin" --nanospot-latency-session "$@" -sessionRetentionSeconds "${NANOSPOT_RETENTION_SECONDS:-0}" 2>&1 | rg '^NANOSPOT_LATENCY '
