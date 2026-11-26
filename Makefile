.PHONY: bench-nanoui-latency bench-nanoui-memory build bundle check clean docs format install-zig run test test-core test-nanoui

ZIG = $(shell SCRIPT_DIR="$$PWD/scripts" . ./scripts/tools.sh && resolve_tool zig "$$NANOSPOT_ZIG_VERSION" version)

check:
	@status=0; \
	./scripts/test-core.sh || status=1; \
	./scripts/test-nanoui.sh || status=1; \
	./scripts/bench-nanoui-latency.sh || status=1; \
	if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	echo "check: all gates passed"

test: test-core test-nanoui

format:
	"$(ZIG)" fmt core/build.zig core/src
	"$(ZIG)" fmt app/build.zig app/build.zig.zon app/src

build:
	cd app && "$(ZIG)" build --release

bundle:
	cd app && "$(ZIG)" build bundle --release

run:
	cd app && "$(ZIG)" build run

install-zig:
	./scripts/install-zig.sh

test-core:
	./scripts/test-core.sh

test-nanoui:
	./scripts/test-nanoui.sh

bench-nanoui-latency:
	./scripts/bench-nanoui-latency.sh

bench-nanoui-memory:
	./scripts/bench-nanoui-memory.sh

docs:
	bun --cwd=docs run build

clean:
	rm -rf .build core/.zig-cache core/zig-out app/.zig-cache app/zig-out
