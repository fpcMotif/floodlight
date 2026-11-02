#!/bin/sh
# The feasibility gate's numbers on this Mac (ADR 0014), in the same shape as
# the other frontends' measure scripts:
#
#   1. the floor: the GPUIX window made into the panel, empty, idle 10 s
#   2. the app: summon and query latency through the hotkey handler, then
#      idle physical footprint and the JS heap 10 s after hiding
#   3. sizes: executable, platform library, whole bundle
#
# Physical footprint, not RSS: RSS counts shared framework pages and the
# clean pages of the mapped index. Lines go to stdout and, on CI, the job
# summary.
#
#   scripts/measure.sh "build/Floodlight GPUIX.app"
set -eu

app=$1
exe="$app/Contents/MacOS/floodlight-gpuix"
out=$(mktemp)
trap 'rm -f "$out"' EXIT INT TERM

# A real but small index root, so the numbers do not depend on the runner's
# home folder.
root=$(mktemp -d)
mkdir -p "$root/Documents/Reports" "$root/Projects/floodlight"
for i in $(seq 1 2000); do : >"$root/Documents/note-$i.md"; done
: >"$root/Documents/Reports/q3-report.pdf"
: >"$root/Projects/floodlight/README.md"

kb() { du -sk "$1" | cut -f1; }

# Each run must exit 0: a crash fails the job instead of leaving a gap.
"$exe" --bench-empty >"$out.log"
"$exe" --bench --root "$root" >>"$out.log"
{
  grep "^FLOODLIGHT_GPUIX" "$out.log"
  echo "FLOODLIGHT_GPUIX exe_kb=$(kb "$exe")"
  echo "FLOODLIGHT_GPUIX lib_kb=$(kb "$app/Contents/MacOS/libfloodlight_gpuix.dylib")"
  echo "FLOODLIGHT_GPUIX app_kb=$(kb "$app")"
} | tee "$out"
rm -f "$out.log"
rm -rf "$root"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '### GPUIX frontend'
    echo '```'
    cat "$out"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
