#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE=$ROOT/.build/fff-mutations/source
OUTPUT=$ROOT/.build/fff-mutations/results
# shellcheck disable=SC1091
source "$ROOT/testing/fff-contracts/mutation.env"

command -v cargo-mutants >/dev/null || {
    echo "error: install cargo-mutants $CARGO_MUTANTS_VERSION with cargo install --locked cargo-mutants --version $CARGO_MUTANTS_VERSION" >&2
    exit 1
}
[[ "$(cargo mutants --version)" == "cargo-mutants $CARGO_MUTANTS_VERSION" ]] || {
    echo "error: cargo-mutants $CARGO_MUTANTS_VERSION is required" >&2
    exit 1
}

"$ROOT/testing/fff-contracts/materialize.sh" "$SOURCE"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

git -C "$SOURCE" diff -U0 -- "Vendor/fff/$MUTATION_FILE" \
    | sed 's#Vendor/fff/##g' \
    | awk '
    /^diff --git|^index |^--- |^\+\+\+ / { print; next }
    /^@@ / { emit = /sort_and_paginate/ }
    emit { print }
' > "$OUTPUT/pagination-target.diff"
[[ -s "$OUTPUT/pagination-target.diff" ]] || {
    echo "error: pagination mutation target diff was empty" >&2
    exit 1
}

cd "$SOURCE/Vendor/fff"

status=0

run_campaign() {
    local name=$1
    shift
    local out="$OUTPUT/$name"
    mkdir -p "$out"

    cargo mutants --list "$@" > "$out/discovered.txt"
    [[ -s "$out/discovered.txt" ]] || {
        echo "error: mutation discovery was empty for $name" >&2
        status=1
        return
    }

    set +e
    cargo mutants \
        "$@" \
        --jobs 2 \
        --timeout 300 \
        --output "$out"
    local campaign_status=$?
    set -e
    printf 'exit_status=%s\n' "$campaign_status" > "$out/status"
    (( campaign_status == 0 )) || status=1
}

run_campaign pagination \
    --package fff-search \
    --test-package fff-test-harness \
    --file "$MUTATION_FILE" \
    --in-diff "$OUTPUT/pagination-target.diff" \
    --re 'sort_and_paginate'

run_campaign eligibility \
    --package fff-search \
    --test-package fff-search \
    --file crates/fff-core/src/index/constraints.rs \
    --re 'apply_constraints|ConstraintPlan.*matches'

run_campaign query-parser \
    --package fff-query-parser \
    --test-package fff-query-parser \
    --file crates/fff-query-parser/src/parser.rs \
    --re 'QueryParser<C>::parse$' \

run_campaign persistence \
    --package fff-search \
    --test-package fff-search \
    --file crates/fff-core/src/dbs/frecency.rs \
    --re 'FrecencyTracker::(track_access|access_count|prune_stale_and_capped_accesses)'

run_campaign c-error \
    --package fff-c \
    --test-package fff-c \
    --file crates/fff-c/src/ffi_types.rs \
    --re 'FffResult::err'

mkdir -p "$OUTPUT/c-smoke"
cat > "$OUTPUT/c-smoke/excluded.txt" <<'EOF'
Direct C smoke execution is not a cargo-mutants test command. Its null-pointer, ownership, and error propagation checks run in run-rust-contracts.sh.
EOF

cat > "$OUTPUT/scope.txt" <<'EOF'
pagination: fff-core/src/score.rs sort_and_paginate(_dirs), fff-test-harness properties
eligibility: fff-core/src/index/constraints.rs apply_constraints and ConstraintPlan::matches, fff-search tests
query-parser: fff-query-parser/src/parser.rs QueryParser::parse, parser tests
persistence: fff-core/src/dbs/frecency.rs track_access/access_count/prune_stale_and_capped_accesses, fff-search tests
c-error: fff-c/src/ffi_types.rs FffResult::err, fff-c unit tests; C smoke covers FFI entrypoints
equivalent: none; all discovered production mutation scopes are executed or unviable
EOF


if (( status != 0 )); then
    echo "error: one or more Rust mutation scopes had missed, timed-out, or infrastructure failures" >&2
    exit "$status"
fi
