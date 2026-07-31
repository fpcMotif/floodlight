#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
FFF_SOURCE=${FFF_DIR:-"$PROJECT_DIR/../fff"}

if [ ! -f "$FFF_SOURCE/crates/fff-c/Cargo.toml" ]; then
    echo "FFF was not found at: $FFF_SOURCE" >&2
    echo "Set FFF_DIR to the fff repository path." >&2
    exit 1
fi

cargo build \
    --manifest-path "$FFF_SOURCE/Cargo.toml" \
    --package fff-c \
    --release

mkdir -p "$PROJECT_DIR/Native/lib"
cp "$FFF_SOURCE/target/release/libfff_c.dylib" "$PROJECT_DIR/Native/lib/libfff_c.dylib"
install_name_tool \
    -id "@rpath/libfff_c.dylib" \
    "$PROJECT_DIR/Native/lib/libfff_c.dylib"

# SwiftPM also searches its configuration directory while linking. Refresh any
# existing copies so an incremental build cannot bind against an older FFF ABI.
for BIN_DIR in "$PROJECT_DIR"/.build/*/debug "$PROJECT_DIR"/.build/*/release; do
    [ -d "$BIN_DIR" ] || continue
    cp "$PROJECT_DIR/Native/lib/libfff_c.dylib" "$BIN_DIR/libfff_c.dylib"
done
