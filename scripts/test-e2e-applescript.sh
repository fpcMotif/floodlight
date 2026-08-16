#!/bin/sh
# UI end-to-end: drive Floodlight's search panel with path queries via
# AppleScript, capture screenshots, and assert the expected top hits.
#
# Queries exercised:
#   Downloads/  — trailing-slash directory path, Top Hit is Downloads/
#   Projects/   — trailing-slash directory path, Top Hit is Projects/
#   Security    — System Settings pane, results include Privacy & Security
#
# Floodlight is an LSUIElement agent whose panel hides when the app resigns
# active, so each query's type / wait / dump / screenshot happens inside one
# osascript invocation while the panel is still key.
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
LAUNCHED_PID=""

log() {
    printf 'test-e2e-applescript: %s\n' "$*"
}

die() {
    printf 'test-e2e-applescript: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$LAUNCHED_PID" ]; then
        kill "$LAUNCHED_PID" 2>/dev/null || true
        wait "$LAUNCHED_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

resolve_app() {
    if [ -n "${FLOODLIGHT_APP:-}" ]; then
        printf '%s\n' "$FLOODLIGHT_APP"
        return
    fi
    if [ -d "$HOME/Applications/Floodlight.app" ]; then
        printf '%s\n' "$HOME/Applications/Floodlight.app"
        return
    fi
    if [ -d "$PROJECT_DIR/.build/Floodlight.app" ]; then
        printf '%s\n' "$PROJECT_DIR/.build/Floodlight.app"
        return
    fi
    log "building Floodlight.app so the UI can be driven"
    make -C "$PROJECT_DIR" bundle >/dev/null
    printf '%s\n' "$PROJECT_DIR/.build/Floodlight.app"
}

process_running() {
    pgrep -x Floodlight >/dev/null 2>&1
}

wait_for_process() {
    tries=0
    while [ "$tries" -lt 40 ]; do
        if process_running; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 0.25
    done
    die "Floodlight did not start"
}

# Accessibility is required for System Events to inspect the panel. Fail
# with the grant path rather than a raw Apple Event error.
require_accessibility() {
    if osascript -e 'tell application "System Events" to get name of first process' >/dev/null 2>&1
    then
        return 0
    fi
    die "System Events is not allowed to control this Mac. Grant Accessibility to Terminal (or the hosting app) in System Settings → Privacy & Security → Accessibility, then re-run."
}

# Floodlight's first launch presents onboarding instead of search. Pin the
# completed version so a fresh bundle still opens the panel.
mark_onboarding_complete() {
    defaults write "$BUNDLE_ID" onboarding-completed-version -int 2
}

ensure_path_fixtures() {
    # PathNavigator resolves trailing-slash queries against the search root
    # and the home directory. These folders are the ones the UI cases type.
    mkdir -p "$HOME/Downloads" "$HOME/Projects"
}

launch_floodlight() {
    APP_PATH=$1
    if process_running; then
        log "using already-running Floodlight"
        open -a "$APP_PATH" || true
        return
    fi
    log "launching $APP_PATH"
    open -na "$APP_PATH"
    wait_for_process
    LAUNCHED_PID=$(pgrep -n -x Floodlight || true)
    # Indexing and the first panel presentation both take a beat.
    sleep 2
}

# Drive one query: focus Floodlight, replace the field, wait for results,
# dump accessible names, and screenshot the panel window.
run_query() {
    query=$1
    expected=$2
    shot=$3

    result=$(osascript - "$query" "$shot" <<'APPLESCRIPT'
on collectNames()
    tell application "System Events"
        tell process "Floodlight"
            if (count of windows) is 0 then error "Floodlight has no visible window"
            set names to {}
            set elems to entire contents of window 1
            repeat with e in elems
                try
                    set n to name of e
                    if n is not missing value and n is not "" then
                        set end of names to n
                    end if
                end try
                try
                    set v to value of e as text
                    if v is not missing value and v is not "" then
                        set end of names to v
                    end if
                end try
            end repeat
            set AppleScript's text item delimiters to linefeed
            return names as text
        end tell
    end tell
end collectNames

on capturePanel(shotPath)
    tell application "System Events"
        tell process "Floodlight"
            set win to window 1
            set {x, y} to position of win
            set {w, h} to size of win
        end tell
    end tell
    set rect to (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
    do shell script "screencapture -x -R " & quoted form of rect & " " & quoted form of shotPath
end capturePanel

on run argv
    set queryText to item 1 of argv
    set shotPath to item 2 of argv

    tell application "System Events"
        tell process "Floodlight"
            set frontmost to true
            delay 0.4
            if (count of windows) is 0 then error "Floodlight panel is not visible"
            keystroke "a" using command down
            delay 0.08
            key code 51
            delay 0.08
            keystroke queryText
            delay 1.4
        end tell
    end tell

    capturePanel(shotPath)
    return collectNames()
end run
APPLESCRIPT
) || die "osascript failed for query '$query'"

    printf '%s\n' "$result" > "$shot.ui.txt"
    log "query '$query' → screenshot $shot"

    case "$result" in
        *"$expected"*) ;;
        *)
            printf '%s\n' "$result" >&2
            die "query '$query' did not surface '$expected'"
            ;;
    esac
    log "query '$query' asserted '$expected'"
}

mkdir -p "$SHOT_DIR"
require_accessibility
ensure_path_fixtures
APP=$(resolve_app)
[ -d "$APP" ] || die "Floodlight.app not found at $APP"
mark_onboarding_complete
launch_floodlight "$APP"

run_query "Downloads/" "Downloads/" "$SHOT_DIR/downloads.png"
run_query "Projects/" "Projects/" "$SHOT_DIR/projects.png"
run_query "Security" "Security" "$SHOT_DIR/security.png"

log "all path-query UI cases passed"
log "screenshots: $SHOT_DIR"
