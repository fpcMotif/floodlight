#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
cd "$PROJECT_DIR/core"
"$zig" build --release --prefix "$PROJECT_DIR/.build/core"
cd "$PROJECT_DIR/app"
"$zig" build bundle --release

nscore="$PROJECT_DIR/.build/core/bin/nscore"
bin="$PWD/zig-out/Nanospot.app/Contents/MacOS/nanospot"
scratch_home=$(mktemp -d "${TMPDIR:-/tmp}/nanospot-latency.XXXXXX")
trap 'rm -rf "$scratch_home"' EXIT INT TERM
mkdir -p "$scratch_home/Applications" "$scratch_home/Library/Application Support/Nanospot"

"$nscore" synth "$scratch_home/Library/Application Support/Nanospot/names.flix" "${NANOSPOT_LATENCY_ENTRIES:-750000}" >/dev/null
HOME="$scratch_home" "$bin" --nanospot-memory-seed >/dev/null 2>&1

log="$scratch_home/latency.log"
HOME="$scratch_home" "$bin" --nanospot-latency-session "$@" -sessionRetentionSeconds "${NANOSPOT_RETENTION_SECONDS:-0}" >"$log" 2>&1 || true
rg -N '^NANOSPOT_LATENCY ' "$log" || true

if ! rg -q '^NANOSPOT_LATENCY done ' "$log"; then
    echo "bench-nanoui-latency: session did not finish:" >&2
    cat "$log" >&2
    exit 1
fi

awk '
BEGIN {
    budgets["summon"] = 8300
    budgets["keystroke_new_rows"] = 16000
    budgets["keystroke_same_rows"] = 16000
    budgets["switch_to_board"] = 8300
    budgets["return_to_hidden"] = 8300
    budgets["reveal_to_hidden"] = 8300
    failed = 0
    timeouts = -1
}
/^NANOSPOT_LATENCY / {
    delete kv
    for (i = 2; i <= NF; i++) {
        split($i, p, "=")
        kv[p[1]] = p[2]
    }
    if ("metric" in kv) {
        m = kv["metric"]
        runs[m] = kv["runs"] + 0
        p99[m] = ("p99_us" in kv) ? kv["p99_us"] + 0 : 0
    }
    if ($2 == "done" && "timeouts" in kv) {
        timeouts = kv["timeouts"] + 0
    }
}
END {
    order[1] = "summon"
    order[2] = "keystroke_new_rows"
    order[3] = "keystroke_same_rows"
    order[4] = "switch_to_board"
    order[5] = "return_to_hidden"
    order[6] = "reveal_to_hidden"
    for (k = 1; k <= 6; k++) {
        m = order[k]
        b = budgets[m]
        if (!(m in runs)) {
            printf "bench-nanoui-latency: missing metric %s\n", m > "/dev/stderr"
            failed = 1
        } else if (runs[m] == 0) {
            printf "bench-nanoui-latency: %s has 0 runs (budget %d us)\n", m, b > "/dev/stderr"
            failed = 1
        } else if (p99[m] > b) {
            printf "bench-nanoui-latency: %s p99 %d us exceeds the %d us budget\n", m, p99[m], b > "/dev/stderr"
            failed = 1
        } else {
            printf "bench-nanoui-latency: %s p99 %d us within the %d us budget\n", m, p99[m], b
        }
    }
    if (timeouts < 0 || timeouts > 0) {
        printf "bench-nanoui-latency: timeouts=%d exceeds 0\n", timeouts > "/dev/stderr"
        failed = 1
    }
    exit failed
}
' "$log"
