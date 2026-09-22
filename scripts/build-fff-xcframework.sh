#!/bin/sh
# Builds FFFKit's Rust core small and hands it to the submodule's Artifacts/,
# which its Package.swift prefers over the released download.
#
# `opt-level` is a --config override rather than an edit to the submodule so
# there is nothing to rebase when FFFKit moves.
#
# No --target, unlike the submodule's own build script: cargo withholds target
# rustflags from host units in cross mode, and the vendored .cargo/config.toml
# is where the `-undefined dynamic_lookup` that makes proc-macro dylibs
# loadable lives. Without it the build dies at phf_macros. That config is also
# found from the working directory, hence the cd.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
PACKAGE_DIR="$PROJECT_DIR/Vendor/fff-swift"
VENDOR_DIR="$PACKAGE_DIR/Vendor/fff"
XCFRAMEWORK="$PACKAGE_DIR/Artifacts/CFFF.xcframework"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/floodlight-fff.XXXXXX")
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM
if [ ! -f "$VENDOR_DIR/Cargo.toml" ]; then
    echo "build-fff-xcframework: run 'git submodule update --init' first" >&2
    exit 1
fi
cd "$VENDOR_DIR"
MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0} \
    cargo build --package fff-c --release --locked \
        --config 'profile.release.opt-level="s"'
mkdir -p "$TEMP_DIR/Headers" "$PACKAGE_DIR/Artifacts"
cp "$VENDOR_DIR/crates/fff-c/include/fff.h" "$TEMP_DIR/Headers/"
cp "$PACKAGE_DIR/Support/CFFF/module.modulemap" "$TEMP_DIR/Headers/"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$VENDOR_DIR/target/release/libfff_c.a" \
    -headers "$TEMP_DIR/Headers" \
    -output "$XCFRAMEWORK" >"$TEMP_DIR/xcodebuild.log" 2>&1 \
    || { cat "$TEMP_DIR/xcodebuild.log" >&2; exit 1; }
echo "$XCFRAMEWORK"
