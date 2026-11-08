#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

idle_budget_mb=${FLOODLIGHT_NANO_IDLE_BUDGET_MB:-60}
cycles=3

zig=$(resolve_tool zig "$FLOODLIGHT_ZIG_VERSION" version)
cd "$PROJECT_DIR/frontends/nanoui"
"$zig" build bundle --release

bin="$PWD/zig-out/Nanospot.app/Contents/MacOS/floodlight-nanoui"
scratch_home=$(mktemp -d "${TMPDIR:-/tmp}/floodlight-nano-memory.XXXXXX")
mkdir -p "$scratch_home/Applications"
log="$scratch_home/session.log"
report="$scratch_home/footprint.json"
pid=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$scratch_home"
}
trap cleanup EXIT INT TERM

HOME="$scratch_home" "$bin" --floodlight-memory-seed >"$log" 2>&1
HOME="$scratch_home" "$bin" --floodlight-memory-session -sessionRetentionSeconds 0 >"$log" 2>&1 &
pid=$!

sample_footprint() {
    footprint -f bytes -j "$report" "$pid" >/dev/null 2>&1
    jq -r '.processes[0] | "\(.footprint / 1048576 * 10 | round / 10) \(.auxiliary.phys_footprint_peak / 1048576 * 10 | round / 10)"' "$report"
}

largest_categories() {
    jq -r '.processes[0].categories | to_entries | map({k: .key, mb: ((.value.dirty + .value.swapped) / 1048576)}) | sort_by(-.mb) | .[0:6][] | "    \(.k): \(.mb * 10 | round / 10) MB"' "$report"
}

seen=0
idle_mb=
deadline=$(($(date +%s) + 90))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "bench-nanoui-memory: the app exited early:" >&2
        cat "$log" >&2
        exit 1
    fi
    markers=$(rg -c '^FLOODLIGHT_MEMORY ' "$log" || true)
    while [ "$seen" -lt "${markers:-0}" ]; do
        seen=$((seen + 1))
        marker=$(rg '^FLOODLIGHT_MEMORY ' "$log" | awk -v n="$seen" 'NR == n { print $2, $3 }')
        set -- $(sample_footprint)
        echo "FLOODLIGHT_MEMORY $marker footprint_mb=$1 peak_mb=$2"
        largest_categories
        if [ "$marker" = "phase=idle cycle=$cycles" ]; then
            idle_mb=$1
            break 2
        fi
    done
    sleep 0.2
done

if [ -z "$idle_mb" ]; then
    echo "bench-nanoui-memory: no final idle marker within 90 s:" >&2
    cat "$log" >&2
    exit 1
fi
if awk -v m="$idle_mb" -v b="$idle_budget_mb" 'BEGIN { exit !(m > b) }'; then
    echo "bench-nanoui-memory: idle footprint ${idle_mb} MB exceeds the ${idle_budget_mb} MB budget" >&2
    exit 1
fi
echo "bench-nanoui-memory: idle footprint ${idle_mb} MB within the ${idle_budget_mb} MB budget"
