#!/bin/sh
# Compiler gate: build every target with warnings promoted to errors.
#
# Warnings-as-errors is a flag here rather than a package setting so that an
# exploratory local `swift build` stays lenient — you can leave an unused
# variable in place while you are still thinking. Strict concurrency checking
# is the opposite: it lives in Package.swift, because a data race is not
# something to be lenient about while thinking.
#
# `--build-tests` is deliberate: test code is where `@MainActor` boundaries get
# crossed most casually, and a warning there is a warning on main.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

cd "$PROJECT_DIR"

if swift build --build-tests -Xswiftc -warnings-as-errors; then
    echo "check-build: builds clean with warnings-as-errors and strict concurrency"
else
    echo "check-build: fix the diagnostics above — warnings are errors in the gate" >&2
    exit 1
fi
