#!/bin/sh
# End-to-end smoke test of the compiled binary: real index, real app catalog,
# keys arriving on a pipe, frames read back off stdout.
#
# usage: smoke.sh path/to/floodlight-tui
set -eu

bin=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(dirname "$(dirname "$here")")/core
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
index="$work/smoke.flix"

fail() {
    echo "smoke: FAIL: $1" >&2
    shift
    for f in "$@"; do sed 's/\x1b\[[0-9;?]*[A-Za-z]/ /g' "$f" | head -c 2000 >&2; echo >&2; done
    exit 1
}

# Builds the index of core/ and waits for it, through the bench path.
"$bin" --root "$root" --index "$index" --bench 1 >"$work/bench.json"
grep -q '"files":' "$work/bench.json" || fail "bench printed no JSON" "$work/bench.json"

# Typing arrives as one burst on the pipe, so the frontend must run one query
# for the final text (latest wins) and draw it before EOF ends the session.
printf 'build.zig' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" >"$work/typed.out"
grep -q 'build.zig' "$work/typed.out" || fail "typed query did not find core/build.zig" "$work/typed.out"
grep -q '1 result\|[0-9] results' "$work/typed.out" || fail "no result count on the prompt row" "$work/typed.out"

# Down then Esc: the selection moves and Esc ends the session cleanly.
printf 'zig\033[B\033' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" >"$work/nav.out"
grep -q 'results' "$work/nav.out" || fail "navigation session drew no results" "$work/nav.out"

# Without a terminal and without --headless the binary must refuse, not hang.
if "$bin" --root "$root" --index "$index" </dev/null >"$work/notty.out" 2>&1; then
    fail "ran without a terminal" "$work/notty.out"
fi

# On macOS the system catalog always has Terminal.app.
if [ "$(uname -s)" = Darwin ]; then
    printf 'terminal' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" >"$work/apps.out"
    grep -q 'Terminal' "$work/apps.out" || fail "app search did not find Terminal.app" "$work/apps.out"
fi

echo "smoke: passed"
