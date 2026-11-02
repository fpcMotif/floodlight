#!/bin/sh
# Measures the compiled frontend and prints a Markdown table (also appended
# to $GITHUB_STEP_SUMMARY in CI).
#
#   binary size        the stripped executable on disk
#   cold start         exec → first frame written, from the kernel's process
#                      start time (macOS), median of RUNS launches
#   idle memory        resident and phys_footprint after IDLE seconds parked
#                      in the event wait, plus `ps` RSS as a cross-check
#   query latency      per keystroke over typed prefixes of ten words:
#                      search alone, and search + layout + diff
#
# usage: measure.sh path/to/floodlight-tui
# env:   MEASURE_ROOT (default $HOME), RUNS (20), IDLE (5)
set -eu

bin=$1
root=${MEASURE_ROOT:-$HOME}
runs=${RUNS:-20}
idle=${IDLE:-5}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
index="$work/measure.flix"

median() {
    sort -n | awk '{a[NR]=$1} END {if (NR==0) print "n/a"; else print a[int((NR+1)/2)]}'
}

# Index the root first; the bench waits for the build, so later runs open a
# finished file the way a launch after the first one does.
build_start=$(date +%s)
bench=$("$bin" --root "$root" --index "$index" --bench 5)
build_end=$(date +%s)

size=$(wc -c <"$bin" | tr -d ' ')

: >"$work/paint"
i=0
while [ "$i" -lt "$runs" ]; do
    "$bin" --headless --size 16x80 --root "$root" --index "$index" --query notes \
        --exit-after-paint 2>>"$work/paint" >/dev/null </dev/null
    i=$((i + 1))
done
exec_paint=$(jq -r '.exec_to_paint_ms' "$work/paint" | grep -v '^-1$' | median)
main_paint=$(jq -r '.main_to_paint_ms' "$work/paint" | median)
first_exec=$(head -1 "$work/paint" | jq -r 'if .exec_to_paint_ms < 0 then "n/a" else .exec_to_paint_ms end')

"$bin" --headless --size 16x80 --root "$root" --index "$index" --idle-report "$idle" \
    2>"$work/idle" >/dev/null </dev/null &
pid=$!
sleep $((idle - 1))
ps_rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ')
wait "$pid"

row() { printf '| %s | %s |\n' "$1" "$2"; }
{
    echo "### floodlight-tui ($(uname -sm))"
    echo
    echo "| metric | value |"
    echo "|---|---|"
    row "binary size (stripped)" "$((size / 1024)) KB"
    row "files indexed (\`$root\`)" "$(echo "$bench" | jq -r '.files') in $((build_end - build_start)) s incl. bench"
    row "cold start, exec → first paint (median of $runs)" "${exec_paint} ms"
    row "cold start, first launch" "${first_exec} ms"
    row "main() → first paint (median)" "${main_paint} ms"
    row "idle RSS after ${idle} s (task_info)" "$(jq -r '.rss_mb' "$work/idle") MB"
    row "idle phys_footprint after ${idle} s" "$(jq -r '.footprint_mb' "$work/idle") MB"
    row "idle RSS (\`ps\`)" "$((ps_rss_kb / 1024)).$(((ps_rss_kb % 1024) * 100 / 1024)) MB"
    row "query p50 / p95, search only" "$(echo "$bench" | jq -r '"\(.search_p50_ms) / \(.search_p95_ms)"') ms"
    row "query p50 / p95, keystroke → frame" "$(echo "$bench" | jq -r '"\(.keystroke_to_frame_p50_ms) / \(.keystroke_to_frame_p95_ms)"') ms"
    row "queries timed" "$(echo "$bench" | jq -r '.queries')"
    row "RSS after bench (index paged in)" "$(echo "$bench" | jq -r '.rss_mb') MB"
} | tee "$work/table"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$work/table" >>"$GITHUB_STEP_SUMMARY"
fi
