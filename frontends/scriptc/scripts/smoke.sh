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
"$bin" --root "$root" --index "$index" --data "$work" --bench 1 >"$work/bench.json"
grep -q '"files":' "$work/bench.json" || fail "bench printed no JSON" "$work/bench.json"

# Typing arrives as one burst on the pipe, so the frontend must run one query
# for the final text (latest wins) and draw it before EOF ends the session.
printf 'build.zig' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" --data "$work" >"$work/typed.out"
grep -q 'build.zig' "$work/typed.out" || fail "typed query did not find core/build.zig" "$work/typed.out"
grep -q '1 result\|[0-9] results' "$work/typed.out" || fail "no result count on the prompt row" "$work/typed.out"

# Down then Esc: the selection moves and Esc ends the session cleanly.
printf 'zig\033[B\033' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" --data "$work" >"$work/nav.out"
grep -q 'results' "$work/nav.out" || fail "navigation session drew no results" "$work/nav.out"

# The answers that need no index: arithmetic, a typed address, a keyword
# engine, and web mode on Tab.
printf '2*(3+4)' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" --data "$work" >"$work/calc.out"
grep -q '= 14' "$work/calc.out" || fail "calculator row missing" "$work/calc.out"
printf 'gh floodlight\t' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" --data "$work" >"$work/web.out"
grep -q 'Search GitHub' "$work/web.out" || fail "Tab did not enter GitHub web mode" "$work/web.out"

# Clipboard: the capture agent records into the store, skips a concealed
# copy, and the board lists what it recorded.
agent=$(dirname "$bin")/floodlight-clipd
"$agent" --data "$work" --record-text 'https://example.com/smoke' | grep -q recorded || fail "agent did not record a link"
"$agent" --data "$work" --record-text 'hunter2' --types org.nspasteboard.ConcealedType | grep -q skipped ||
    fail "agent recorded a concealed copy"
"$agent" --data "$work" --record-text 'https://example.com/smoke' | grep -q skipped || fail "agent recorded a repeat"
printf '' | "$bin" --headless --stay --board --size 14x100 --root "$root" --index "$index" --data "$work" >"$work/board.out"
grep -q 'example.com' "$work/board.out" || fail "board did not list the recorded link" "$work/board.out"
grep -q 'hunter2' "$work/board.out" && fail "board shows a concealed copy" "$work/board.out"

# Pin and delete on the board change the store a second run reads.
"$agent" --data "$work" --record-text 'second entry' >/dev/null
printf '\033d' | "$bin" --headless --stay --board --size 14x100 --root "$root" --index "$index" --data "$work" >/dev/null
printf '' | "$bin" --headless --stay --board --size 14x100 --root "$root" --index "$index" --data "$work" >"$work/board2.out"
grep -q 'second entry' "$work/board2.out" && fail "⌥D did not delete the selected entry" "$work/board2.out"
grep -q 'example.com' "$work/board2.out" || fail "⌥D deleted more than the selection" "$work/board2.out"

# Without Full Disk Access, search still works and the notice offers the grant.
printf 'build' | "$bin" --headless --stay --fda missing --size 14x100 --root "$root" --index "$index" --data "$work" >"$work/fda.out"
grep -q 'Full Disk Access is off' "$work/fda.out" || fail "no Full Disk Access notice" "$work/fda.out"
grep -q '\.zig' "$work/fda.out" || fail "search stopped without Full Disk Access" "$work/fda.out"

# Without a terminal and without --headless the binary must refuse, not hang.
if "$bin" --root "$root" --index "$index" --data "$work" </dev/null >"$work/notty.out" 2>&1; then
    fail "ran without a terminal" "$work/notty.out"
fi

# On macOS the system catalog always has Terminal.app.
if [ "$(uname -s)" = Darwin ]; then
    printf 'terminal' | "$bin" --headless --stay --size 12x80 --root "$root" --index "$index" --data "$work" >"$work/apps.out"
    grep -q 'Terminal' "$work/apps.out" || fail "app search did not find Terminal.app" "$work/apps.out"
fi

echo "smoke: passed"
