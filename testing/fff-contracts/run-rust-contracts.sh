#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE=$ROOT/.build/fff-contracts/source
"$ROOT/testing/fff-contracts/materialize.sh" "$SOURCE"

for seed in 17361641481138401537 17361641481138401538 17361641481138401539; do
    PROPTEST_RNG_SEED=$seed cargo test \
        --manifest-path "$SOURCE/Vendor/fff/Cargo.toml" \
        --package fff-test-harness \
        --locked
done
cargo build \
    --manifest-path "$SOURCE/Vendor/fff/Cargo.toml" \
    --package fff-c \
    --locked
cc -O0 -g -Wall -Wextra -std=c99 \
    -I "$SOURCE/Vendor/fff/crates/fff-c/include" \
    -L "$SOURCE/Vendor/fff/target/debug" \
    -Wl,-rpath,"$SOURCE/Vendor/fff/target/debug" \
    "$SOURCE/Vendor/fff/crates/fff-c/tests/smoke.c" \
    -lfff_c \
    -o "$SOURCE/Vendor/fff/target/debug/fff_c_contract_smoke"
"$SOURCE/Vendor/fff/target/debug/fff_c_contract_smoke" "$SOURCE/Vendor/fff"
