#!/bin/sh
# The GPUI frontend's gate: rustfmt, clippy with warnings denied, the unit
# tests, and a release build. The core archive must exist first
# (`make gpui-core`); cargo links it rather than building it.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR/frontends/gpui"
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --release --locked
