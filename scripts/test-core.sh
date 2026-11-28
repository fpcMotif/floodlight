#!/bin/sh
# The Zig engine's gate: unit tests on this host, a release build for both
# operating systems the scanner targets, and a smoke run of the CLI.
#
# Cross-building the other OS is the point of the second step: a Mac runner
# only executes the getattrlistbulk path, so without it the getdents64 path
# could stop compiling unnoticed, and the reverse on Linux.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
cd "$PROJECT_DIR/core"

"$zig" fmt --check build.zig src
"$zig" build test --summary all

case "$(uname -s)" in
    Darwin) other=x86_64-linux ;;
    *) other=aarch64-macos ;;
esac
"$zig" build --release -Dtarget="$other" --prefix "$PROJECT_DIR/.build/core-$other"
"$zig" build --release --prefix "$PROJECT_DIR/.build/core"

nscore="$PROJECT_DIR/.build/core/bin/nscore"
index="$PROJECT_DIR/.build/core/smoke.flix"
"$nscore" index "$PROJECT_DIR" "$index"
"$nscore" search "$index" build zig
"$nscore" bench "$index"
