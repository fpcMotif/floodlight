FFF_DIR ?= ../fff

.PHONY: build build-fff bundle clean debug install run test

build-fff:
	FFF_DIR="$(FFF_DIR)" ./scripts/build-fff.sh

debug: build-fff
	swift build

build: build-fff
	swift build -c release

run: debug
	./scripts/run.sh

test: build-fff
	swift test

bundle: build
	./scripts/bundle.sh

install: bundle
	./scripts/install.sh

clean:
	swift package clean
