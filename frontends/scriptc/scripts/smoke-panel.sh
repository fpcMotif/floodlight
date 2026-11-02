#!/bin/sh
# Smoke test of floodlight-panel (macOS): show the panel, search, draw, hide,
# idle, and report. Needs a window server, which the CI runner's logged-in
# session provides.
#
# usage: smoke-panel.sh path/to/floodlight-panel
set -eu

bin=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(dirname "$(dirname "$here")")/core
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

"$bin" --root "$root" --index "$work/panel.flix" --smoke build --idle 5 >"$work/out.json"
cat "$work/out.json"

smoke=$(grep '"panel_smoke"' "$work/out.json")
idle=$(grep '"panel_idle"' "$work/out.json")
rows=$(echo "$smoke" | jq -r '.rows')
if [ "$rows" -lt 1 ]; then
    echo "smoke-panel: FAIL: query 'build' drew no rows" >&2
    exit 1
fi

{
    echo "### floodlight-panel ($(uname -sm))"
    echo
    echo "| metric | value |"
    echo "|---|---|"
    echo "| binary size (stripped) | $(($(wc -c <"$bin") / 1024)) KB |"
    echo "| exec → panel on screen | $(echo "$smoke" | jq -r '.exec_to_visible_ms') ms |"
    echo "| show → frame flushed | $(echo "$smoke" | jq -r '.show_ms') ms |"
    echo "| query → rows drawn | $(echo "$smoke" | jq -r '.query_to_rows_ms') ms ($rows rows) |"
    echo "| RSS while visible | $(echo "$smoke" | jq -r '.visible_rss_mb') MB |"
    echo "| idle RSS / footprint after hide + 5 s | $(echo "$idle" | jq -r '"\(.rss_mb) / \(.footprint_mb)"') MB |"
} | tee "$work/table"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$work/table" >>"$GITHUB_STEP_SUMMARY"
fi
echo "smoke-panel: passed"
