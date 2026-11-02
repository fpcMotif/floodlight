# floodlight-tui: the TypeScript frontend compiled to a native binary by
# scriptc (ADR 0013). Self-contained: run from here, or through the
# `scriptc-*` targets in the root Makefile.
#
#   make            build build/floodlight-tui
#   make test       self-test, static-coverage gate, end-to-end smoke
#   make measure    size, cold start, idle memory, query latency
#
# Needs bun (to fetch the pinned scriptc), clang, and the pinned Zig from
# `make install-zig` at the repository root.

.PHONY: all build check-coverage clean deps measure smoke test

ROOT := $(abspath ../..)
SCRIPTC := node_modules/.bin/scriptc
ZIG ?= $(firstword $(wildcard $(ROOT)/.tools/bin/zig) zig)
BUILD := build
# Its own prefix: test-core builds the same archive without -fPIC, which a
# Linux PIE executable cannot link.
CORE_PREFIX := $(ROOT)/.build/core-scriptc
CORE_LIB := $(CORE_PREFIX)/lib/libfloodlight_core.a
CORE_PIC := $(if $(filter Linux,$(shell uname -s)),-Dpic=true,)

SOURCES := $(wildcard src/*.ts)
CFLAGS := -O2 -fPIC -Wall -Wextra -Werror -std=c11 -I$(ROOT)/core/include

all: build
build: $(BUILD)/floodlight-tui

deps: $(SCRIPTC)

$(SCRIPTC): package.json bun.lock
	bun install --frozen-lockfile
	@touch $@

$(CORE_LIB): $(wildcard $(ROOT)/core/src/*.zig) $(ROOT)/core/build.zig $(ROOT)/core/include/floodlight_core.h
	cd $(ROOT)/core && $(ZIG) build --release $(CORE_PIC) --prefix $(CORE_PREFIX)

$(BUILD)/libflshim.a: native/flshim.c native/flshim.h $(ROOT)/core/include/floodlight_core.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c native/flshim.c -o $(BUILD)/flshim.o
	rm -f $@ && ar rcs $@ $(BUILD)/flshim.o

$(BUILD)/floodlight-tui: $(SOURCES) ffi.json $(BUILD)/libflshim.a $(CORE_LIB) $(SCRIPTC)
	$(SCRIPTC) build src/main.ts --ffi ffi.json --strip --no-keep-llvm -o $@ >/dev/null

$(BUILD)/selftest: $(SOURCES) test/selftest.ts $(SCRIPTC)
	@mkdir -p $(BUILD)
	$(SCRIPTC) build test/selftest.ts --no-keep-llvm -o $@ >/dev/null

# Every statement must compile to native code: no Node.js island (which
# would load libnode, i.e. V8) and no dynamic-tier fallback on any path.
check-coverage: $(SCRIPTC) $(BUILD)/libflshim.a $(CORE_LIB)
	$(SCRIPTC) coverage src/main.ts --ffi ffi.json --fail-on node-islands
	$(SCRIPTC) coverage src/main.ts --ffi ffi.json --fail-on dynamic

test: $(BUILD)/selftest check-coverage smoke
	./$(BUILD)/selftest

smoke: $(BUILD)/floodlight-tui
	./scripts/smoke.sh ./$(BUILD)/floodlight-tui

measure: $(BUILD)/floodlight-tui
	./scripts/measure.sh ./$(BUILD)/floodlight-tui

clean:
	rm -rf $(BUILD) $(CORE_PREFIX) .scriptc
