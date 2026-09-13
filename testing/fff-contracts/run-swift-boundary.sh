#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$ROOT/.build/fff-boundary
SOURCE=$WORK/fff-swift
APP=$WORK/floodlight
FAULT=$ROOT/testing/fff-contracts/patches/known-mixed-search-fault.patch
BUILT_ARTIFACT=$SOURCE/Artifacts/CFFF.xcframework
CACHED_ARTIFACT=$APP/.build/artifacts/fff-swift/CFFF/CFFF.xcframework

bind_artifact() {
    rm -rf "$CACHED_ARTIFACT"
    mkdir -p "$(dirname "$CACHED_ARTIFACT")"
    cp -R "$BUILT_ARTIFACT" "$CACHED_ARTIFACT"
}

rm -rf "$WORK"
mkdir -p "$APP"
"$ROOT/testing/fff-contracts/materialize.sh" "$SOURCE"
make -C "$SOURCE" build

git -C "$ROOT" archive HEAD | tar -x -C "$APP"
swift package --package-path "$APP" resolve
swift package --package-path "$APP" edit fff-swift --path "$SOURCE"
bind_artifact
swift test --package-path "$APP" --filter FFFIndexTests \
    2>&1 | tee "$WORK/swift-boundary-baseline.log"

cat >> "$ROOT/.build/fff-contracts/provenance.txt" <<EOF
artifact_sha256=$(shasum -a 256 "$SOURCE/Artifacts/CFFF.xcframework/macos-arm64/libfff_c.a" | awk '{print $1}')
swift=$(swift --version | head -n 1)
swift_boundary=FFFIndexTests
EOF

git -C "$SOURCE" apply --check "$FAULT"
git -C "$SOURCE" apply "$FAULT"
make -C "$SOURCE" build
swift package --package-path "$APP" clean
bind_artifact

set +e
swift test --package-path "$APP" --filter FFFIndexTests.indexesAndSearchesFilesAndFolders \
    > "$WORK/swift-boundary-known-fault.log" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -eq 0 ]; then
    echo "error: the known mixed-search fault survived Swift boundary tests" >&2
    exit 1
fi

printf '%s\n' "known mixed-search fault caught by Swift FFFIndex integration"
