# floodlight-tui: the TypeScript frontend compiled to a native binary by
# scriptc (ADR 0013). Self-contained: run from here, or through the
# `scriptc-*` targets in the root Makefile.
#
#   make            build build/floodlight-tui and build/floodlight-clipd
#   make test       self-test with the parity fixtures, coverage gate, smoke
#   make measure    size, cold start, idle memory, query latency
#
# Needs bun (to fetch the pinned scriptc), clang, SQLite, and the pinned Zig
# from `make install-zig` at the repository root.

.PHONY: all build check-coverage clean deps measure smoke smoke-panel test

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
# The Cocoa panel (#111) and the AppKit platform layer are macOS-only;
# elsewhere the platform layer is a stub that reports "not available".
DARWIN := $(filter Darwin,$(shell uname -s))
PANEL := $(if $(DARWIN),$(BUILD)/floodlight-panel,)
SMOKE_PANEL := $(if $(DARWIN),smoke-panel,)
NATIVE_SRC := $(if $(DARWIN),native/flmac.m,native/flnative_stub.c)
# Deprecations stay warnings: an SDK bump must not break the build.
NATIVE_CC := $(if $(DARWIN),clang -O2 -fobjc-arc -Wall -Wextra -Werror -Wno-error=deprecated-declarations,clang $(CFLAGS))
COMMA := ,
FRAMEWORKS := $(if $(DARWIN),["AppKit"$(COMMA)"ApplicationServices"$(COMMA)"ImageIO"],[])
LIBS := $(BUILD)/libflshim.a $(BUILD)/libflclip.a $(BUILD)/libflnative.a $(CORE_LIB)

all: build
build: $(BUILD)/floodlight-tui $(BUILD)/floodlight-clipd $(PANEL)

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

$(BUILD)/libflclip.a: native/flclip.c native/flclip.h native/flnative.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c native/flclip.c -o $(BUILD)/flclip.o
	rm -f $@ && ar rcs $@ $(BUILD)/flclip.o

$(BUILD)/libflnative.a: $(NATIVE_SRC) native/flnative.h
	@mkdir -p $(BUILD)
	$(NATIVE_CC) -c $(NATIVE_SRC) -o $(BUILD)/flnative.o
	rm -f $@ && ar rcs $@ $(BUILD)/flnative.o

# ffi.json plus this platform's frameworks, beside it so library paths hold.
ffi-tui.json: ffi.json
	jq '. + {frameworks: $(FRAMEWORKS)}' ffi.json >$@

$(BUILD)/floodlight-tui: $(SOURCES) ffi-tui.json $(LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/main.ts --ffi ffi-tui.json --strip --no-keep-llvm -o $@ >/dev/null

# The capture agent: the TUI exits when dismissed, so this polls instead.
$(BUILD)/floodlight-clipd: $(SOURCES) ffi-tui.json $(LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/agent.ts --ffi ffi-tui.json --strip --no-keep-llvm -o $@ >/dev/null

$(BUILD)/libflpanel.a: native/flpanel.m native/flpanel.h
	@mkdir -p $(BUILD)
	clang -O2 -fobjc-arc -Wall -Wextra -Werror -c native/flpanel.m -o $(BUILD)/flpanel.o
	rm -f $@ && ar rcs $@ $(BUILD)/flpanel.o

# One source of truth for the shared functions: the panel manifest is
# ffi.json's bindings plus the panel's own, with both sets of libraries.
ffi-panel.json: ffi.json native/flpanel.ffi.json
	jq -s '.[0] + {functions: (.[0].functions + .[1].functions), libraries: (.[1].libraries[:1] + .[0].libraries), frameworks: ((.[1].frameworks + $(FRAMEWORKS)) | unique)}' ffi.json native/flpanel.ffi.json >$@

$(BUILD)/floodlight-panel: $(SOURCES) ffi-panel.json $(BUILD)/libflpanel.a $(LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/panel.ts --ffi ffi-panel.json --strip --no-keep-llvm -o $@ >/dev/null

$(BUILD)/selftest: $(SOURCES) $(wildcard test/*.ts) ffi-tui.json $(LIBS) $(SCRIPTC)
	@mkdir -p $(BUILD)
	$(SCRIPTC) build test/selftest.ts --ffi ffi-tui.json --no-keep-llvm -o $@ >/dev/null

# Every statement must compile to native code: no Node.js island (which
# would load libnode, i.e. V8) and no dynamic-tier fallback on any path.
check-coverage: $(SCRIPTC) ffi-tui.json $(LIBS)
	$(SCRIPTC) coverage src/main.ts --ffi ffi-tui.json --fail-on node-islands
	$(SCRIPTC) coverage src/main.ts --ffi ffi-tui.json --fail-on dynamic
	$(SCRIPTC) coverage src/agent.ts --ffi ffi-tui.json --fail-on node-islands
	$(SCRIPTC) coverage src/agent.ts --ffi ffi-tui.json --fail-on dynamic

test: $(BUILD)/selftest check-coverage smoke $(SMOKE_PANEL)
	./$(BUILD)/selftest $(ROOT)/fixtures/parity

smoke: $(BUILD)/floodlight-tui $(BUILD)/floodlight-clipd
	./scripts/smoke.sh ./$(BUILD)/floodlight-tui

measure: $(BUILD)/floodlight-tui
	./scripts/measure.sh ./$(BUILD)/floodlight-tui

smoke-panel: $(BUILD)/floodlight-panel ffi-panel.json
	$(SCRIPTC) coverage src/panel.ts --ffi ffi-panel.json --fail-on node-islands
	$(SCRIPTC) coverage src/panel.ts --ffi ffi-panel.json --fail-on dynamic
	./scripts/smoke-panel.sh ./$(BUILD)/floodlight-panel

clean:
	rm -rf $(BUILD) $(CORE_PREFIX) .scriptc ffi-panel.json ffi-tui.json
