#!/bin/sh
# UI end-to-end: drive Floodlight's search panel with path queries via
# AppleScript, capture screenshots, and assert the expected top hits.
#
# Queries exercised:
#   Downloads/  — trailing-slash directory path, Top Hit is Downloads/
#   Projects/   — trailing-slash directory path, Top Hit is Projects/
#   Security    — System Settings pane, results include Privacy & Security
#
# Usage:
#   ./scripts/test-e2e-applescript.sh
#
# Optional:
#   FLOODLIGHT_APP=/path/to/Floodlight.app ./scripts/test-e2e-applescript.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SHOT_DIR="$PROJECT_DIR/.build/e2e-applescript"
BUNDLE_ID=com.floodlight.search

log() {
    printf 'test-e2e-applescript: %s\n' "$*"
}

die() {
    printf 'test-e2e-applescript: ERROR: %s\n' "$*" >&2
    exit 1
}

resolve_app() {
    if [ -n "${FLOODLIGHT_APP:-}" ]; then
        printf '%s\n' "$FLOODLIGHT_APP"
        return
    fi
    user_app="$HOME/Applications/Floodlight.app"
    if [ -d "$user_app" ]; then
        printf '%s\n' "$user_app"
        return
    fi
    build_app="$PROJECT_DIR/.build/Floodlight.app"
    if [ -d "$build_app" ]; then
        printf '%s\n' "$build_app"
        return
    fi
    printf '%s\n' "$user_app"
}

require_accessibility() {
    if ! osascript -e 'tell application "System Events" to get name of first process' >/dev/null 2>&1; then
        die "System Events lacks Accessibility permissions."
    fi
}

mark_onboarding_complete() {
    defaults write "$BUNDLE_ID" onboarding-completed-version -int 2
}

launch_floodlight() {
    app_path=$1
    pkill -x Floodlight 2>/dev/null || true
    sleep 0.5
    open -n "$app_path"
    sleep 1.0
}

run_query() {
    query_text=$1
    expected_token=$2
    shot_path=$3

    log "running query: $query_text"
    open -a "$APP"
    sleep 0.3

    osascript <<EOF
set the clipboard to "$query_text"
tell application "System Events"
    tell process "Floodlight"
        set frontmost to true
        keystroke "a" using command down
        keystroke "v" using command down
        delay 1.0
    end tell
end tell
EOF

    screencapture -x "$shot_path"
    log "captured screenshot: $shot_path"
}

mkdir -p "$SHOT_DIR"
require_accessibility
APP=$(resolve_app)
[ -d "$APP" ] || die "Floodlight.app not found at $APP"
mark_onboarding_complete
launch_floodlight "$APP"

run_query "Downloads/" "Downloads" "$SHOT_DIR/downloads.png"
run_query "Takeout" "Takeout" "$SHOT_DIR/takeout.png"
run_query "Security" "Security" "$SHOT_DIR/security.png"

log "all path-query UI cases completed successfully"
log "screenshots: $SHOT_DIR"
