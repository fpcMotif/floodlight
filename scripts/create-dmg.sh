#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
APP_PATH=${1:-"$PROJECT_DIR/.build/Floodlight.app"}
OUTPUT_PATH=${2:-"$PROJECT_DIR/.build/Floodlight.dmg"}

case "$APP_PATH" in
    /*) ;;
    *) APP_PATH="$PROJECT_DIR/$APP_PATH" ;;
esac

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$PROJECT_DIR/$OUTPUT_PATH" ;;
esac

if [ ! -d "$APP_PATH" ]; then
    echo "Floodlight app bundle was not found at: $APP_PATH" >&2
    echo "Build it first with: make bundle" >&2
    exit 1
fi

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/floodlight-dmg.XXXXXX")
cleanup() {
    rm -R "$STAGING_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$(dirname "$OUTPUT_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/Floodlight.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Floodlight" \
    -srcfolder "$STAGING_DIR" \
    -format ULMO \
    -ov \
    "$OUTPUT_PATH"

DMG_BYTES=$(stat -f%z "$OUTPUT_PATH")
BINARY_PATH="$APP_PATH/Contents/MacOS/Floodlight"
BINARY_BYTES=$(stat -f%z "$BINARY_PATH" 2>/dev/null || echo 0)

echo "FLOODLIGHT_BENCH dmg_size_bytes=$DMG_BYTES binary_size_bytes=$BINARY_BYTES"
echo "$OUTPUT_PATH"
