#!/bin/sh
# Downloads the pinned Go toolchain into .tools and links .tools/bin/go.
#
# Same rule as install-zig.sh: pinned by version and SHA-256, verified before
# anything is unpacked. A Go already on PATH at the pinned version is used
# as-is.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

if tool_at_version go "$FLOODLIGHT_GO_VERSION" version; then
    echo "install-go: go $FLOODLIGHT_GO_VERSION already present"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin-arm64 sha=$FLOODLIGHT_GO_SHA256_MACOS_ARM64 ;;
    Darwin-x86_64) platform=darwin-amd64 sha=$FLOODLIGHT_GO_SHA256_MACOS_X86_64 ;;
    Linux-x86_64) platform=linux-amd64 sha=$FLOODLIGHT_GO_SHA256_LINUX_X86_64 ;;
    *)
        echo "install-go: no pinned Go for $(uname -s)-$(uname -m)" >&2
        exit 1
        ;;
esac

name=go$FLOODLIGHT_GO_VERSION.$platform
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT INT TERM
archive="$work_dir/$name.tar.gz"

echo "install-go: fetching $name"
curl --fail --location --silent --show-error \
    "https://go.dev/dl/$name.tar.gz" --output "$archive"

if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
else
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
fi
if [ "$actual" != "$sha" ]; then
    echo "install-go: checksum mismatch for $name" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

# The archive's top directory is always `go`; unpack it under a versioned name
# so a bump never overwrites the toolchain an open shell still points at.
mkdir -p "$TOOLS_BIN" "$work_dir/unpack"
tar -xzf "$archive" -C "$work_dir/unpack"
rm -rf "$PROJECT_DIR/.tools/$name"
mv "$work_dir/unpack/go" "$PROJECT_DIR/.tools/$name"
ln -sf "../$name/bin/go" "$TOOLS_BIN/go"
ln -sf "../$name/bin/gofmt" "$TOOLS_BIN/gofmt"
echo "install-go: installed $("$TOOLS_BIN/go" version)"
