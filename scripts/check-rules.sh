#!/bin/sh
# Architecture gate: ast-grep's domain rules, their unit tests, and a scoping
# self-test.
#
# Three things have to be true for a rule to be worth having, and each gets its
# own step:
#   1. scan     — the tree satisfies every rule right now
#   2. test     — each rule fires on its invalid snippets and stays quiet on its
#                 valid ones (tools/ast-grep/rule-tests)
#   3. selftest — the `files:` globs point at the directories they claim to
#                 A rule test runs on an in-memory snippet with no path, so it
#                 cannot catch a glob that matches nothing. That failure mode is
#                 silent and total: the rule passes its own tests forever while
#                 guarding nothing.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

# `ast-grep scan` defaults its search path to `.`, so without this the script
# scans whatever directory it was invoked from — exits 0 having examined
# nothing, then fails the self-test blaming the globs. Run it from anywhere.
cd "$PROJECT_DIR"

astgrep=$(resolve_tool ast-grep "$FLOODLIGHT_ASTGREP_VERSION" --version)

engine_probe="$PROJECT_DIR/Sources/FloodlightEngine/GateSelfTest.swift"
shell_probe="$PROJECT_DIR/Sources/Floodlight/GateSelfTest.swift"
tests_probe="$PROJECT_DIR/Tests/FloodlightTests/GateSelfTest.swift"
trap 'rm -f "$engine_probe" "$shell_probe" "$tests_probe"' EXIT INT TERM

if "$astgrep" scan --config "$PROJECT_DIR/sgconfig.yml"; then
    echo "check-rules: no architecture violations"
else
    echo "check-rules: violations above — each message names the alternative to use" >&2
    exit 1
fi

rule_test_output=$("$astgrep" test --config "$PROJECT_DIR/sgconfig.yml" 2>&1) || {
    printf '%s\n' "$rule_test_output" >&2
    echo "check-rules: rule tests failed. If a rule changed on purpose, regenerate" >&2
    echo "  its snapshots with: ast-grep test --update-all" >&2
    exit 1
}
echo "check-rules: rule tests pass"

# The probe imports a UI framework and detaches a task — two engine-scoped
# rules. In the engine it must be caught; in the shell, where both are
# legitimate, it must not be.
#
# `--no-ignore vcs` because the probe path is in .gitignore (so an interrupted
# run cannot leave something that looks like source) and ast-grep honours
# .gitignore — without this the probe is invisible and the self-test passes by
# scanning nothing, which is the exact failure it exists to detect.
probe_source='import SwiftUI

func gateSelfTest() {
    Task.detached { await refresh() }
}
'

printf '%s' "$probe_source" > "$engine_probe"
if "$astgrep" scan --no-ignore vcs --config "$PROJECT_DIR/sgconfig.yml" >/dev/null 2>&1; then
    echo "check-rules: SELF-TEST FAILED — engine rules did not fire on a planted" >&2
    echo "  violation in Sources/FloodlightEngine. The 'files:' globs in" >&2
    echo "  tools/ast-grep/rules are not matching, so the rules guard nothing." >&2
    exit 1
fi
rm -f "$engine_probe"

printf '%s' "$probe_source" > "$shell_probe"
if "$astgrep" scan --no-ignore vcs --config "$PROJECT_DIR/sgconfig.yml" >/dev/null 2>&1; then
    echo "check-rules: self-test passed (rules armed on the engine, quiet on the shell)"
else
    echo "check-rules: SELF-TEST FAILED — engine-scoped rules fired on Sources/Floodlight." >&2
    echo "  SwiftUI and Task.detached are legitimate in the shell; a rule is over-scoped." >&2
    exit 1
fi
rm -f "$shell_probe"

# The readability rules are scoped to both source targets *and* Tests, which is
# a wider claim than any rule above makes and so a wider glob to get wrong.
# `readability-nesting-depth` stands in for all of them: it is the only one
# whose match needs no particular code around it, so a deep enough nest is a
# violation wherever it is planted. `--filter` runs that rule alone, so the
# probe does not have to satisfy the other twelve.
#
# The filter is checked against the clean tree first. Every test below reads a
# non-zero exit as "the rule fired", and `--filter` on an id that does not exist
# also exits non-zero — so a renamed rule would turn this whole section into
# three tests that pass without running anything.
if ! "$astgrep" scan --no-ignore vcs --filter '^readability-nesting-depth$' \
    --config "$PROJECT_DIR/sgconfig.yml" >/dev/null 2>&1; then
    echo "check-rules: SELF-TEST FAILED — scanning the clean tree for" >&2
    echo "  readability-nesting-depth alone did not exit 0. Either the rule id in this" >&2
    echo "  script no longer matches one in tools/ast-grep/rules, or the tree is not" >&2
    echo "  clean; either way the three probes below would pass without testing." >&2
    exit 1
fi

nesting_probe_source='func gateSelfTest() {
    if isReady {
        for row in rows {
            while row.hasMore {
                if row.isStale {
                    for child in row.children {
                        child.refresh()
                    }
                }
            }
        }
    }
}
'

for probe in "$engine_probe" "$shell_probe" "$tests_probe"; do
    printf '%s' "$nesting_probe_source" > "$probe"
    if "$astgrep" scan --no-ignore vcs --filter '^readability-nesting-depth$' \
        --config "$PROJECT_DIR/sgconfig.yml" >/dev/null 2>&1; then
        echo "check-rules: SELF-TEST FAILED — readability-nesting-depth did not fire on a" >&2
        echo "  five-deep nest planted at ${probe#"$PROJECT_DIR"/}. The 'files:' globs in" >&2
        echo "  the readability rules are not matching that directory." >&2
        exit 1
    fi
    rm -f "$probe"
done
echo "check-rules: self-test passed (readability rules armed on Sources and Tests)"
