#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
BIN_DIR=$(cd "$PROJECT_DIR" && swift build -c release --show-bin-path)
APP_DIR="$PROJECT_DIR/.build/Floodlight.app"
CONTENTS="$APP_DIR/Contents"
SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}
RESOURCE_SOURCE="$PROJECT_DIR/Sources/Floodlight/Resources"

if [ -e "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/Floodlight" "$CONTENTS/MacOS/Floodlight"
cp "$RESOURCE_SOURCE/Info.plist" "$CONTENTS/Info.plist"
cp "$RESOURCE_SOURCE/FloodlightMenuBar.svg" "$CONTENTS/Resources/"
"$SCRIPT_DIR/build-app-icon.sh" \
    "$RESOURCE_SOURCE/AppIcon.png" \
    "$CONTENTS/Resources/Floodlight.icns"

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign \
        --force \
        --sign - \
        --identifier "com.floodlight.search" \
        --requirements '=designated => identifier "com.floodlight.search"' \
        "$APP_DIR"
else
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --identifier "com.floodlight.search" \
        --options runtime \
        --timestamp \
        "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
