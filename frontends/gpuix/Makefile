# Floodlight on GPUIX: React components painted by GPUI, on Bun (ADR 0014).
# Self-contained: run from here, or through the `gpuix-*` targets in the root
# Makefile.
#
#   make            build/libfloodlight_gpuix.{dylib,so} and, on macOS, the app
#   make test       typecheck, then the parity fixtures and unit tests (bun test)
#   make measure    idle footprint, JS heap, summon and query latency (macOS)
#
# Needs the pinned Bun (scripts/bun-version), clang, SQLite (part of macOS;
# libsqlite3-dev on Linux) and the pinned Zig from `make install-zig` at the
# repository root.

.PHONY: all app clean deps lib measure run test typecheck

ROOT := $(abspath ../..)
ZIG ?= $(firstword $(wildcard $(ROOT)/.tools/bin/zig) zig)
BUN ?= bun
BUILD := build
# Its own prefix and -Dpic: a shared library needs position-independent code
# on Linux, and test-core builds the same archive without it.
CORE_PREFIX := $(ROOT)/.build/core-gpuix
CORE_LIB := $(CORE_PREFIX)/lib/libfloodlight_core.a

DARWIN := $(filter Darwin,$(shell uname -s))
LIB := $(BUILD)/libfloodlight_gpuix.$(if $(DARWIN),dylib,so)
CFLAGS := -O2 -fPIC -Wall -Wextra -Werror -std=c11 -I$(ROOT)/core/include -Inative
# Deprecations stay warnings: an SDK bump must not break the build.
OBJCFLAGS := -O2 -fPIC -fobjc-arc -Wall -Wextra -Werror -Wno-error=deprecated-declarations -Inative
C_SRC := native/flshim.c native/flclip.c $(if $(DARWIN),,native/flnative_stub.c native/flgx_stub.c)
OBJC_SRC := $(if $(DARWIN),native/flmac.m native/flgx_mac.m,)
OBJS := $(patsubst native/%,$(BUILD)/%.o,$(C_SRC) $(OBJC_SRC))
LDLIBS := -lsqlite3 $(if $(DARWIN),-framework AppKit -framework ApplicationServices -framework Carbon \
	-framework ImageIO -framework QuartzCore,-lpthread)
SOURCES := $(shell find src -name '*.ts' -o -name '*.tsx')

all: lib $(if $(DARWIN),app,)
lib: $(LIB)

deps: node_modules/.installed

node_modules/.installed: package.json bun.lock
	$(BUN) install --frozen-lockfile
	@touch $@

$(CORE_LIB): $(wildcard $(ROOT)/core/src/*.zig) $(ROOT)/core/build.zig $(ROOT)/core/include/floodlight_core.h
	cd $(ROOT)/core && $(ZIG) build --release -Dpic=true --prefix $(CORE_PREFIX)

$(BUILD)/%.c.o: native/%.c $(wildcard native/*.h)
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c $< -o $@

$(BUILD)/%.m.o: native/%.m $(wildcard native/*.h)
	@mkdir -p $(BUILD)
	clang $(OBJCFLAGS) -c $< -o $@

$(LIB): $(OBJS) $(CORE_LIB)
	clang -shared -o $@ $(OBJS) $(CORE_LIB) $(LDLIBS)

typecheck: deps
	$(BUN) x tsc --noEmit -p .

test: $(LIB) typecheck
	FLOODLIGHT_GPUIX_LIB=$(abspath $(LIB)) $(BUN) test

# One executable with Bun inside; the library sits beside it. --smol trades a
# little GC time for a smaller heap, which is the trade an idle launcher wants;
# --bytecode skips parsing React at every cold start.
$(BUILD)/floodlight-gpuix: $(SOURCES) $(LIB) deps
	$(BUN) build --compile --bytecode --minify --sourcemap=none --compile-exec-argv=--smol \
		src/main.tsx --outfile $@

app: $(BUILD)/floodlight-gpuix
	./scripts/bundle.sh $(BUILD)

run: $(LIB) deps
	FLOODLIGHT_GPUIX_LIB=$(abspath $(LIB)) $(BUN) --smol src/main.tsx

measure: app
	./scripts/measure.sh "$(BUILD)/Floodlight GPUIX.app"

clean:
	rm -rf $(BUILD) $(CORE_PREFIX)
