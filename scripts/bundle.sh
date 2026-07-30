#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR=$(cd "$PROJECT_DIR" && swift build -c release --show-bin-path)
APP_DIR="$PROJECT_DIR/.build/Floodlight.app"
CONTENTS="$APP_DIR/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$BIN_DIR/Floodlight" "$CONTENTS/MacOS/Floodlight"
cp "$PROJECT_DIR/Native/lib/libfff_c.dylib" "$CONTENTS/Frameworks/libfff_c.dylib"
cp "$PROJECT_DIR/Sources/Floodlight/Resources/Info.plist" "$CONTENTS/Info.plist"

codesign \
    --force \
    --deep \
    --sign "${CODE_SIGN_IDENTITY:--}" \
    --identifier "com.floodlight.search" \
    --requirements '=designated => identifier "com.floodlight.search"' \
    "$APP_DIR"
echo "$APP_DIR"
