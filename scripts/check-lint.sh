#!/bin/sh
# Swift quality gate: SwiftLint in strict mode, at the pinned version, plus the
# check that keeps its thresholds honest.
#
# `--strict` promotes every warning to a failure. There is no warning tier on
# purpose: a warning nobody has to fix is a warning that accumulates, and the
# thresholds in .swiftlint.yml are already set at the tree's current ceiling.
#
# That ceiling used to be a promise nothing kept. A threshold is only a gate
# while it sits on the worst offender; when a refactor shrinks that offender and
# nobody lowers the number, the difference is a licence for the next one. By #95
# every threshold had drifted — `cyclomatic_complexity` allowed 13 against a
# worst of 11 — so the second half of this script measures what the tree
# actually reaches and fails when a number sits above it. Between the two halves
# the configured value can only ever equal the measured worst: above it and the
# slack check fails, below it and --strict fails.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

. "$SCRIPT_DIR/tools.sh"

swiftlint=$(resolve_tool swiftlint "$FLOODLIGHT_SWIFTLINT_VERSION" version)

lint_config="$PROJECT_DIR/.swiftlint.yml"
measure_config="$SCRIPT_DIR/swiftlint-measure.yml"

# The rules whose thresholds are a ratchet. Adding one here means adding it to
# swiftlint-measure.yml too — a rule listed here that the measuring run never
# reports is a hard failure below, so the two cannot fall out of step quietly.
ratcheted_rules="file_length type_body_length function_body_length cyclomatic_complexity closure_body_length"

# The self-test's scratch config lives outside the repository. A fixed name
# inside it would outlive a SIGKILL as an untracked file somebody then commits.
selftest_dir=$(mktemp -d)
trap 'rm -rf "$selftest_dir"' EXIT
trap 'rm -rf "$selftest_dir"; exit 130' INT
trap 'rm -rf "$selftest_dir"; exit 143' TERM

if "$swiftlint" lint --strict --quiet --config "$lint_config" "$PROJECT_DIR"; then
    echo "check-lint: no SwiftLint violations"
else
    echo "check-lint: SwiftLint violations above — see .swiftlint.yml for the rule's rationale" >&2
    exit 1
fi

# configured_threshold <rule> <config>
#
# SwiftLint's own view of the number rather than a grep of the YAML: the
# configuration it prints is the one it lints with, parent configs and all.
configured_threshold() {
    "$swiftlint" rules "$1" --config "$2" 2>/dev/null |
        awk '/^ *warning: /{ print $2; exit }'
}

# rule_options <rule> <config>
#
# A rule's configuration with the two thresholds removed. SwiftLint replaces a
# rule's configuration wholesale rather than merging it into the parent's, so
# swiftlint-measure.yml has to repeat options like `ignore_comment_only_lines`;
# this is what proves it still repeats them correctly. A silent revert there
# would measure a different tree than the gate lints, and the number demanded
# below would be wrong rather than merely stale.
rule_options() {
    "$swiftlint" rules "$1" --config "$2" 2>/dev/null | awk '
        /^Configuration \(YAML\):/ { inside = 1; next }
        /^Triggering Examples/ { exit }
        inside && $1 != "warning:" && $1 != "error:" { print }
    '
}

# measure_tree
#
# One line per ratcheted rule: `<rule> <the highest value anything reaches>`.
# swiftlint-measure.yml forces every threshold to its floor, so each declaration
# reports the size it actually is instead of only the ones over the limit. The
# number wanted is the last one in the message — "currently contains 658",
# "currently spans 100 lines", "currently complexity is 11" — and these five
# rules are the only ones whose messages say "currently" at all.
measure_tree() {
    "$swiftlint" lint --quiet --reporter xcode --config "$measure_config" "$PROJECT_DIR" 2>/dev/null |
        sed -n 's/.*currently [a-z ]*\([0-9][0-9]*\).*(\([a-z_]*\))$/\2 \1/p' |
        awk '{ if ($2 + 0 > worst[$1]) worst[$1] = $2 + 0 }
             END { for (rule in worst) print rule, worst[rule] }'
}

# worst_measured <rule>
#
# What the tree reaches for one rule, out of the single measuring run.
worst_measured() {
    printf '%s\n' "$measured" | awk -v rule="$1" '$1 == rule { print $2 }'
}

# slack_check <config>
#
# Reports every ratcheted threshold in <config> that sits above what the tree
# reaches, and returns non-zero when there was one. The config is a parameter so
# the self-test at the bottom can run this exact comparison against a
# deliberately loosened copy rather than asserting something adjacent to it.
slack_check() {
    slack_config=$1
    slack_result=0
    for slack_rule in $ratcheted_rules; do
        slack_worst=$(worst_measured "$slack_rule")
        slack_configured=$(configured_threshold "$slack_rule" "$slack_config")
        if [ "$slack_configured" -gt "$slack_worst" ]; then
            echo "check-lint: $slack_rule allows $slack_configured but nothing in the"
            echo "  tree exceeds $slack_worst. Set it to $slack_worst in .swiftlint.yml."
            slack_result=1
        fi
    done
    return "$slack_result"
}

measured=$(measure_tree)

for rule in $ratcheted_rules; do
    if [ "$(rule_options "$rule" "$lint_config")" != "$(rule_options "$rule" "$measure_config")" ]; then
        echo "check-lint: $rule is configured differently in .swiftlint.yml and in" >&2
        echo "  scripts/swiftlint-measure.yml, so the measurement would be taken against" >&2
        echo "  a different rule than the gate lints with. Make the options match." >&2
        exit 1
    fi
    if [ -z "$(worst_measured "$rule")" ]; then
        echo "check-lint: $rule is ratcheted but the measuring run reported nothing for" >&2
        echo "  it. Either it is missing from scripts/swiftlint-measure.yml or it is" >&2
        echo "  disabled — either way its threshold is unguarded." >&2
        exit 1
    fi
done

if slack_output=$(slack_check "$lint_config" 2>&1); then
    echo "check-lint: every ratcheted threshold sits on the tree's worst offender"
else
    printf '%s\n' "$slack_output" >&2
    echo "check-lint: a threshold with slack in it is a licence for the next offender." >&2
    echo "  The number moves down in the commit that shrank the offender, not later." >&2
    exit 1
fi

# The slack check has to be able to fail, and a check that has never failed is a
# claim rather than a gate. Raise one threshold by one in a config that inherits
# everything else, and require the same comparison to reject it and to name the
# rule it rejected.
selftest_config="$selftest_dir/loosened.yml"
selftest_rule=cyclomatic_complexity
cat > "$selftest_config" <<EOF
parent_config: $lint_config
$selftest_rule:
  warning: $(($(worst_measured "$selftest_rule") + 1))
  error: 18
  ignores_case_statements: true
EOF

if selftest_output=$(slack_check "$selftest_config" 2>&1); then
    echo "check-lint: SELF-TEST FAILED — a config allowing one more than the tree's" >&2
    echo "  worst $selftest_rule passed the slack check. The check is not comparing the" >&2
    echo "  configured number against the measurement." >&2
    exit 1
fi
case "$selftest_output" in
    *"$selftest_rule"*) ;;
    *)
        echo "check-lint: SELF-TEST FAILED — the slack check rejected a loosened" >&2
        echo "  $selftest_rule without naming it. A failure nobody can act on is not a" >&2
        echo "  gate; the message has to say which rule and which number." >&2
        exit 1
        ;;
esac
echo "check-lint: self-test passed (a threshold one above the tree's worst is caught)"
