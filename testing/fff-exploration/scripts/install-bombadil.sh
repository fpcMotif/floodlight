#!/usr/bin/env bash
set -euo pipefail

EXPLORATION_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$EXPLORATION_ROOT/bombadil.env"

case "$(uname -sm)" in
  "Darwin arm64")
    path=$BOMBADIL_DARWIN_ARM64_PATH
    expected=$BOMBADIL_DARWIN_ARM64_SHA256
    asset=bombadil-aarch64-darwin
    ;;
  "Linux x86_64")
    path=$BOMBADIL_LINUX_AMD64_PATH
    expected=$BOMBADIL_LINUX_AMD64_SHA256
    asset=bombadil-x86_64-linux
    ;;
  *) echo "error: no pinned Bombadil binary for $(uname -sm)" >&2; exit 1 ;;
esac

destination="$EXPLORATION_ROOT/$path"
temporary="$destination.download"
mkdir -p "$(dirname -- "$destination")"
trap 'rm -f "$temporary"' EXIT
curl --fail --location --silent --show-error \
  "https://github.com/antithesishq/bombadil/releases/download/v$BOMBADIL_VERSION/$asset" \
  --output "$temporary"
actual=$(shasum -a 256 "$temporary" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  echo "error: Bombadil checksum mismatch: expected $expected, got $actual" >&2
  exit 1
}
chmod 0555 "$temporary"
mv "$temporary" "$destination"
echo "Installed Bombadil $BOMBADIL_VERSION at $destination"
