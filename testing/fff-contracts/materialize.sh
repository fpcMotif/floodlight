#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DESTINATION=${1:-$ROOT/.build/fff-contracts/source}
REVISION=dbc38f5c81f44d0c7bac434f1f247ca01f1dfc9c
SOURCE_URL=https://github.com/vmg-dev/fff-swift.git
PATCH=$ROOT/testing/fff-contracts/patches/fff-contracts.patch

rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
git clone --quiet "$SOURCE_URL" "$DESTINATION"
git -C "$DESTINATION" checkout --quiet "$REVISION"
git -C "$DESTINATION" apply --check "$PATCH"
git -C "$DESTINATION" apply "$PATCH"

mkdir -p "$ROOT/.build/fff-contracts"
cat > "$ROOT/.build/fff-contracts/provenance.txt" <<EOF
source_url=$SOURCE_URL
source_revision=$REVISION
patch_sha256=$(shasum -a 256 "$PATCH" | awk '{print $1}')
cargo_lock_sha256=$(shasum -a 256 "$DESTINATION/Vendor/fff/Cargo.lock" | awk '{print $1}')
rustc=$(rustc --version)
cargo=$(cargo --version)
host=$(rustc -vV | awk '/^host:/ {print $2}')
profile=test
features=ripgrep
EOF

printf '%s\n' "$DESTINATION"
