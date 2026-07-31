#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SOURCE_APP="$PROJECT_DIR/.build/Floodlight.app"
INSTALL_DIR=${FLOODLIGHT_INSTALL_DIR:-"$HOME/Applications"}
TARGET_APP="$INSTALL_DIR/Floodlight.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo "Build the app first with: make bundle" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
pkill -x Floodlight 2>/dev/null || true
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"

echo "Installed Floodlight at: $TARGET_APP"
echo "Privacy grants will persist for this stable app identity and path."
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$TARGET_APP"
open -n "$TARGET_APP"
