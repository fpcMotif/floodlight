.PHONY: build bundle check check-architecture check-build check-dead-code check-format \
	check-lint check-rules clean debug dmg docs format icons install install-tools run \
	test test-address-sanitizer test-performance test-sanitizers test-thread-sanitizer \
	install-zig test-core core

debug: core
	swift build

# The gate. One command, every mechanical check, same verdict as CI.
#
# Ordered cheapest-first so a formatting slip fails in a second rather than
# after a full index build. Each step is its own script, so you can run just
# the one you are iterating on.
check: check-format check-lint check-rules check-architecture check-build check-dead-code
	@echo "check: all gates passed"

check-format:
	./scripts/check-format.sh

check-lint:
	./scripts/check-lint.sh

check-rules:
	./scripts/check-rules.sh

check-architecture:
	./scripts/check-architecture.sh

check-build: core
	./scripts/check-build.sh

check-dead-code: core
	./scripts/check-dead-code.sh

# Fixes everything `check-format` would complain about. Formatting feedback is
# never something to hand-edit.
format:
	./scripts/format.sh

# Downloads the pinned tool versions into .tools/bin. Anything already on PATH
# at the right version is left alone.
install-tools:
	./scripts/install-tools.sh

build: core
	swift build -c release

run: debug
	./scripts/run.sh

test: core
	swift test

test-address-sanitizer: core
	./scripts/test-address-sanitizer.sh

test-thread-sanitizer: core
	./scripts/test-thread-sanitizer.sh

test-sanitizers: test-address-sanitizer test-thread-sanitizer

# The latency budgets, in release configuration — debug numbers are meaningless
# for a search path. This is what CI runs as its own step.
test-performance: core
	./scripts/test-performance.sh

bundle: build
	./scripts/bundle.sh

icons:
	./scripts/build-app-icon.sh

dmg: bundle
	./scripts/create-dmg.sh

docs:
	npm --prefix docs run build

install: bundle
	./scripts/install.sh

# Build products only. `.tools` is deliberately left alone: it holds pinned
# binaries verified by checksum, and re-downloading them is not what anyone
# means by "clean". Remove it by hand to force a re-fetch.
clean:
	swift package clean
	rm -rf core/zig-out core/.zig-cache

# The Zig file index in core/: its unit tests, a cross-build for the other OS,
# and the CLI bench. Separate from `make test` because only a change to core/
# can move its verdict; CI runs it as its own job.
install-zig:
	./scripts/install-zig.sh

test-core:
	./scripts/test-core.sh

# The static archive FloodlightEngine links. Every target that builds Swift
# depends on it, because SwiftPM has no way to run Zig itself. Fetches the
# pinned Zig on first use; Zig's own cache makes a repeat run a no-op.
core:
	./scripts/build-core.sh
