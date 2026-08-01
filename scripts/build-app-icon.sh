#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SOURCE_ICON=${1:-"$PROJECT_DIR/Sources/Floodlight/Resources/AppIcon.png"}
OUTPUT_ICON=${2:-"$PROJECT_DIR/.build/Floodlight.icns"}

case "$SOURCE_ICON" in
    /*) ;;
    *) SOURCE_ICON="$PROJECT_DIR/$SOURCE_ICON" ;;
esac

case "$OUTPUT_ICON" in
    /*) ;;
    *) OUTPUT_ICON="$PROJECT_DIR/$OUTPUT_ICON" ;;
esac

if [ ! -f "$SOURCE_ICON" ]; then
    echo "App icon master was not found at: $SOURCE_ICON" >&2
    exit 1
fi

ICON_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/floodlight-icon.XXXXXX")
ICONSET="$ICON_WORK_DIR/Floodlight.iconset"
cleanup() {
    rm -R "$ICON_WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$ICONSET" "$(dirname "$OUTPUT_ICON")"

render_size() {
    pixels=$1
    filename=$2
    sips \
        --resampleHeightWidth "$pixels" "$pixels" \
        "$SOURCE_ICON" \
        --out "$ICONSET/$filename" \
        >/dev/null
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
render_size 1024 icon_512x512@2x.png

iconutil --convert icns --output "$OUTPUT_ICON" "$ICONSET"
echo "$OUTPUT_ICON"
