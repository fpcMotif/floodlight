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
    /^@@ / { emit = / sort_and_paginate(_dirs)?<.a>/ }
    emit { print }
' > "$OUTPUT/target.diff"
[[ -s "$OUTPUT/target.diff" ]] || { echo "error: mutation target diff was empty" >&2; exit 1; }
cd "$SOURCE/Vendor/fff"

cargo mutants \
    --list \
    --package fff-search \
    --file "$MUTATION_FILE" \
    --in-diff "$OUTPUT/target.diff" \
    > "$OUTPUT/discovered.txt"
[[ -s "$OUTPUT/discovered.txt" ]] || { echo "error: mutation discovery was empty" >&2; exit 1; }

cargo mutants \
    --package fff-search \
    --test-package fff-test-harness \
    --file "$MUTATION_FILE" \
    --in-diff "$OUTPUT/target.diff" \
    --jobs 2 \
    --timeout 60 \
    --output "$OUTPUT" \
    -- r01_
