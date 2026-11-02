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
# The Cocoa panel (#111) and the AppKit half of the platform layer are
# macOS-only; elsewhere that half is a stub that reports "not available".
# The TUI links neither: AppKit at launch would cost it its cold start, so
# its pasteboard work runs in floodlight-clipd.
DARWIN := $(filter Darwin,$(shell uname -s))
PANEL := $(if $(DARWIN),$(BUILD)/floodlight-panel,)
SMOKE_PANEL := $(if $(DARWIN),smoke-panel,)
MAC_SRC := $(if $(DARWIN),native/flmac.m,native/flnative_stub.c)
# Deprecations stay warnings: an SDK bump must not break the build.
MAC_CC := $(if $(DARWIN),clang -O2 -fobjc-arc -Wall -Wextra -Werror -Wno-error=deprecated-declarations,clang $(CFLAGS))
COMMA := ,
FRAMEWORKS := $(if $(DARWIN),["AppKit"$(COMMA)"ApplicationServices"$(COMMA)"ImageIO"],[])
LIBS := $(BUILD)/libflshim.a $(BUILD)/libflclip.a $(BUILD)/libflplatform.a $(CORE_LIB)
AGENT_LIBS := $(LIBS) $(BUILD)/libflclip-agent.a $(BUILD)/libflmac.a

all: build
build: $(BUILD)/floodlight-tui $(BUILD)/floodlight-clipd $(PANEL)

deps: $(SCRIPTC)

$(SCRIPTC): package.json bun.lock
	bun install --frozen-lockfile
	@touch $@

$(CORE_LIB): $(wildcard $(ROOT)/core/src/*.zig) $(ROOT)/core/build.zig $(ROOT)/core/include/floodlight_core.h
	cd $(ROOT)/core && $(ZIG) build --release $(CORE_PIC) --prefix $(CORE_PREFIX)

$(BUILD)/lib%.a: native/%.c native/*.h $(ROOT)/core/include/floodlight_core.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c $< -o $(BUILD)/$*.o
	rm -f $@ && ar rcs $@ $(BUILD)/$*.o

# The store with its two pasteboard calls, for the agent only.
$(BUILD)/libflclip-agent.a: native/flclip.c native/flclip.h native/flnative.h
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -DFLCLIP_PASTEBOARD -c native/flclip.c -o $(BUILD)/flclip-agent.o
	rm -f $@ && ar rcs $@ $(BUILD)/flclip-agent.o

$(BUILD)/libflmac.a: $(MAC_SRC) native/flnative.h
	@mkdir -p $(BUILD)
	$(MAC_CC) -c $(MAC_SRC) -o $(BUILD)/flmac.o
	rm -f $@ && ar rcs $@ $(BUILD)/flmac.o

# ffi.json's bindings plus the agent's AppKit ones; its store archive
# replaces the TUI's. Generated beside ffi.json, so library paths hold.
ffi-agent.json: ffi.json native/flagent.ffi.json
	jq -s '.[0] + {functions: (.[0].functions + .[1].functions), libraries: ([.[0].libraries[] | select(test("libflclip.a$$") | not)] + .[1].libraries), frameworks: $(FRAMEWORKS)}' ffi.json native/flagent.ffi.json >$@

$(BUILD)/floodlight-tui: $(SOURCES) ffi.json $(LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/main.ts --ffi ffi.json --strip --no-keep-llvm -o $@ >/dev/null

# The capture agent: the TUI exits when dismissed, so this polls instead.
# It also does the TUI's copy and paste, which need AppKit.
$(BUILD)/floodlight-clipd: $(SOURCES) ffi-agent.json $(AGENT_LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/agent.ts --ffi ffi-agent.json --strip --no-keep-llvm -o $@ >/dev/null

$(BUILD)/libflpanel.a: native/flpanel.m native/flpanel.h
	@mkdir -p $(BUILD)
	clang -O2 -fobjc-arc -Wall -Wextra -Werror -c native/flpanel.m -o $(BUILD)/flpanel.o
	rm -f $@ && ar rcs $@ $(BUILD)/flpanel.o

# One source of truth for the shared functions: the panel manifest is the
# agent's bindings plus the panel's own, with both sets of libraries.
ffi-panel.json: ffi-agent.json native/flpanel.ffi.json
	jq -s '.[0] + {functions: (.[0].functions + .[1].functions), libraries: (.[1].libraries[:1] + .[0].libraries), frameworks: ((.[1].frameworks + .[0].frameworks) | unique)}' ffi-agent.json native/flpanel.ffi.json >$@

$(BUILD)/floodlight-panel: $(SOURCES) ffi-panel.json $(BUILD)/libflpanel.a $(AGENT_LIBS) $(SCRIPTC)
	$(SCRIPTC) build src/panel.ts --ffi ffi-panel.json --strip --no-keep-llvm -o $@ >/dev/null

$(BUILD)/selftest: $(SOURCES) $(wildcard test/*.ts) ffi.json $(LIBS) $(SCRIPTC)
	@mkdir -p $(BUILD)
	$(SCRIPTC) build test/selftest.ts --ffi ffi.json --no-keep-llvm -o $@ >/dev/null

# Every statement must compile to native code: no Node.js island (which
# would load libnode, i.e. V8) and no dynamic-tier fallback on any path.
check-coverage: $(SCRIPTC) ffi-agent.json $(AGENT_LIBS)
	$(SCRIPTC) coverage src/main.ts --ffi ffi.json --fail-on node-islands
	$(SCRIPTC) coverage src/main.ts --ffi ffi.json --fail-on dynamic
	$(SCRIPTC) coverage src/agent.ts --ffi ffi-agent.json --fail-on node-islands
	$(SCRIPTC) coverage src/agent.ts --ffi ffi-agent.json --fail-on dynamic

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
	rm -rf $(BUILD) $(CORE_PREFIX) .scriptc ffi-panel.json ffi-agent.json
