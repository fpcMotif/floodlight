#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

idle_budget_mb=${NANOSPOT_IDLE_BUDGET_MB:-44}
peak_budget_mb=${NANOSPOT_PEAK_BUDGET_MB:-67}
cycles=3
expiry_wait_s=4

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
cd "$PROJECT_DIR/app"
"$zig" build bundle --release

bin="$PWD/zig-out/Nanospot.app/Contents/MacOS/nanospot"
scratch_home=
pid=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    if [ -n "$scratch_home" ]; then rm -rf "$scratch_home"; fi
}
trap cleanup EXIT INT TERM

sample_footprint() {
    footprint -f bytes -j "$report" "$pid" >/dev/null 2>&1
    jq -r '.processes[0] | "\(.footprint / 1048576 * 10 | round / 10) \(.auxiliary.phys_footprint_peak / 1048576 * 10 | round / 10)"' "$report"
}

note_peak() {
    max_peak_mb=$(awk -v a="$max_peak_mb" -v b="$1" 'BEGIN { print (b > a) ? b : a }')
}

largest_categories() {
    jq -r '.processes[0].categories | to_entries | map({k: .key, mb: ((.value.dirty + .value.swapped) / 1048576)}) | sort_by(-.mb) | .[0:6][] | "    \(.k): \(.mb * 10 | round / 10) MB"' "$report"
}

# start_session <retention-seconds>: a fresh seeded home and a running session.
start_session() {
    scratch_home=$(mktemp -d "${TMPDIR:-/tmp}/nanospot-memory.XXXXXX")
    mkdir -p "$scratch_home/Applications"
    log="$scratch_home/session.log"
    report="$scratch_home/footprint.json"
    HOME="$scratch_home" "$bin" --nanospot-memory-seed >"$log" 2>&1
    HOME="$scratch_home" "$bin" --nanospot-memory-session -sessionRetentionSeconds "$1" >"$log" 2>&1 &
    pid=$!
}

stop_session() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
    rm -rf "$scratch_home"
    scratch_home=
}

# run_session: samples every marker until the final idle one; sets idle_mb.
run_session() {
    seen=0
    idle_mb=
    deadline=$(($(date +%s) + 180))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "bench-nanoui-memory: the app exited early:" >&2
            cat "$log" >&2
            exit 1
        fi
        markers=$(rg -c '^NANOSPOT_MEMORY ' "$log" || true)
        while [ "$seen" -lt "${markers:-0}" ]; do
            seen=$((seen + 1))
            if [ "$seen" -eq 1 ]; then
                rg '^NANOSPOT_CATALOG ' "$log" | head -n 1 || true
            fi
            marker=$(rg '^NANOSPOT_MEMORY ' "$log" | awk -v n="$seen" 'NR == n { print $2, $3 }')
            set -- $(sample_footprint)
            note_peak "$2"
            echo "NANOSPOT_MEMORY $marker footprint_mb=$1 peak_mb=$2"
            largest_categories
            if [ "$marker" = "phase=idle cycle=$cycles" ]; then
                rg '^NANOSPOT_MEMORY_THUMBS ' "$log" | tail -n 1 || true
                idle_mb=$1
                return 0
            fi
        done
        sleep 0.2
    done
    echo "bench-nanoui-memory: no final idle marker within 180 s:" >&2
    cat "$log" >&2
    exit 1
}

check_budget() {
    if awk -v m="$2" -v b="$3" 'BEGIN { exit !(m > b) }'; then
        echo "bench-nanoui-memory: $1 footprint ${2} MB exceeds the ${3} MB budget" >&2
        return 1
    fi
    echo "bench-nanoui-memory: $1 footprint ${2} MB within the ${3} MB budget"
}

max_peak_mb=0
start_session 0
run_session
stop_session
status=0
check_budget idle "$idle_mb" "$idle_budget_mb" || status=1

# With retention on, the hidden session keeps its rows until the timer ends it.
start_session 2
run_session
sleep "$expiry_wait_s"
set -- $(sample_footprint)
note_peak "$2"
expired_mb=$1
echo "NANOSPOT_MEMORY phase=expired footprint_mb=$1 peak_mb=$2"
largest_categories
stop_session
check_budget expired "$expired_mb" "$idle_budget_mb" || status=1
echo "NANOSPOT_MEMORY phase=peak footprint_mb=$max_peak_mb budget_mb=$peak_budget_mb"
check_budget peak "$max_peak_mb" "$peak_budget_mb" || status=1
exit "$status"
