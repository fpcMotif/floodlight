#!/bin/sh
# Runs the MyGo frontend's measurements on this Mac and prints them, as JSON
# lines and as a Markdown table for the CI step summary. Needs a desktop
# session and the binaries from scripts/test-mygo.sh.
#
# FLOODLIGHT_MYGO_ROOT picks the folder the file index covers; the default is
# the home folder, which is what a user would index.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
out="$PROJECT_DIR/.build/mygo"

size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

empty=$("$out/emptywindow" | grep '^FLOODLIGHT_MYGO_EMPTY ' | cut -d' ' -f2-)
echo "empty window: $empty"
app=$("$out/floodlight-mygo" -measure | grep '^FLOODLIGHT_MYGO ' | cut -d' ' -f2-)
echo "floodlight-mygo: $app"

mb() { jq -r "$1 / 1048576 * 10 | round / 10" ; }
summary=$(cat <<MD
### MyGo frontend ($(echo "$app" | jq -r .mygo), $(echo "$app" | jq -r .go))

| measure | value |
|---|---|
| empty window idle 10 s after hide: RSS / phys_footprint | $(echo "$empty" | mb .rss) MB / $(echo "$empty" | mb .phys_footprint) MB (drew frame: $(echo "$empty" | jq -r .drew_frame)) |
| launcher idle 10 s after hide: RSS / phys_footprint | $(echo "$app" | mb .idle_after_hide.rss) MB / $(echo "$app" | mb .idle_after_hide.phys_footprint) MB |
| launcher Go heap in use, idle | $(echo "$app" | mb .idle_go_heap_inuse) MB |
| launcher footprint after launch (warm frame drawn, index open), before any summon | $(echo "$app" | mb .after_launch.phys_footprint) MB |
| idle breakdown: Go resident (heap in use / heap idle, unreleased / stacks / runtime) | $(echo "$app" | mb .idle_go_resident) MB ($(echo "$app" | mb .idle_go_heap_inuse) / $(echo "$app" | mb .idle_go_heap_idle_unreleased) / $(echo "$app" | mb .idle_go_stacks) / $(echo "$app" | mb .idle_go_runtime_metadata)) |
| idle breakdown: native (AppKit, Metal, MyGo glyphs and textures, SQLite) | $(echo "$app" | mb .idle_native) MB |
| hotkey → first frame, cold / warm p50 ($(echo "$app" | jq -r .hotkey_path)) | $(echo "$app" | jq -r .hotkey_first_frame_cold_ms) ms / $(echo "$app" | jq -r .hotkey_first_frame_warm_p50_ms) ms |
| query p50 / p95, keystroke → rows on main thread | $(echo "$app" | jq -r .query_p50_ms) ms / $(echo "$app" | jq -r .query_p95_ms) ms |
| query p50, engine only | $(echo "$app" | jq -r .query_engine_p50_ms) ms |
| index | $(echo "$app" | jq -r .entries) entries under $(echo "$app" | jq -r .root) |
| binary size, stripped: app / empty window | $(size "$out/floodlight-mygo" | mb .) MB / $(size "$out/emptywindow" | mb .) MB |
MD
)
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$summary" >> "$GITHUB_STEP_SUMMARY"
fi
