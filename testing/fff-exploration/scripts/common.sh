#!/usr/bin/env bash
set -euo pipefail

EXPLORATION_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPOSITORY_ROOT=$(CDPATH='' cd -- "$EXPLORATION_ROOT/../.." && pwd)
# shellcheck disable=SC1091
source "$EXPLORATION_ROOT/bombadil.env"

HARNESS=${FFF_TERMINAL_HARNESS:-$REPOSITORY_ROOT/.build/fff-contracts/source/Vendor/fff/target/release/fff-terminal-harness}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_tools() {
  command -v bun >/dev/null || { echo "error: bun is required" >&2; exit 1; }
  [[ -x "$HARNESS" ]] || {
    echo "error: FFF terminal harness is absent: $HARNESS" >&2
    echo "run make test-fff-contracts, then build the harness in .build/fff-contracts/source" >&2
    exit 1
  }
  local expected platform actual version default_path
  platform=$(uname -sm)
  case "$platform" in
    "Darwin arm64") expected=$BOMBADIL_DARWIN_ARM64_SHA256; default_path=$BOMBADIL_DARWIN_ARM64_PATH ;;
    "Linux x86_64") expected=$BOMBADIL_LINUX_AMD64_SHA256; default_path=$BOMBADIL_LINUX_AMD64_PATH ;;
    *) echo "error: no pinned Bombadil binary for $platform" >&2; exit 1 ;;
  esac
  BOMBADIL_BIN=${BOMBADIL_BIN:-$EXPLORATION_ROOT/$default_path}
  [[ -x "$BOMBADIL_BIN" ]] || {
    echo "error: Bombadil $BOMBADIL_VERSION is absent: $BOMBADIL_BIN" >&2
    echo "run bun run install:bombadil in $EXPLORATION_ROOT" >&2
    exit 1
  }

  actual=$(sha256 "$BOMBADIL_BIN")
  [[ "$actual" == "$expected" ]] || {
    echo "error: Bombadil checksum mismatch: expected $expected, got $actual" >&2
    exit 1
  }
  version=$($BOMBADIL_BIN --version)
  [[ "$version" == *"$BOMBADIL_VERSION"* ]] || {
    echo "error: expected Bombadil $BOMBADIL_VERSION, got: $version" >&2
    exit 1
  }
}

write_metadata() {
  local destination=$1 columns=$2 rows=$3 scrollback=$4 quiescence=$5
  mkdir -p "$destination"
  bun -e '
    import { writeFileSync } from "node:fs";
    const [path, columns, rows, scrollback, quiescence, bombadil, bombadilSha, harness, harnessSha] = process.argv.slice(1);
    writeFileSync(path, JSON.stringify({
      bombadil: { version: "0.7.4", path: bombadil, sha256: bombadilSha },
      harness: { path: harness, sha256: harnessSha },
      options: { columns: Number(columns), rows: Number(rows), scrollbackLinesMax: Number(scrollback), quiescenceTimeoutMs: Number(quiescence) },
    }, null, 2) + "\n");
  ' "$destination/metadata.json" "$columns" "$rows" "$scrollback" "$quiescence" "$BOMBADIL_BIN" "$(sha256 "$BOMBADIL_BIN")" "$HARNESS" "$(sha256 "$HARNESS")"
}
