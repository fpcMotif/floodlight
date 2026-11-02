#!/bin/sh
# Downloads the pinned Zig toolchain into .tools and links .tools/bin/zig.
#
# Same rule as install-tools.sh: pinned by version and SHA-256, verified
# before anything is unpacked. A Zig already on PATH at the pinned version is
# used as-is.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

if tool_at_version zig "$FLOODLIGHT_ZIG_VERSION" version; then
    echo "install-zig: zig $FLOODLIGHT_ZIG_VERSION already present"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=aarch64-macos sha=$FLOODLIGHT_ZIG_SHA256_MACOS_ARM64 ;;
    Darwin-x86_64) platform=x86_64-macos sha=$FLOODLIGHT_ZIG_SHA256_MACOS_X86_64 ;;
    Linux-x86_64) platform=x86_64-linux sha=$FLOODLIGHT_ZIG_SHA256_LINUX_X86_64 ;;
    *)
        echo "install-zig: no pinned Zig for $(uname -s)-$(uname -m)" >&2
        exit 1
        ;;
esac

name=zig-$platform-$FLOODLIGHT_ZIG_VERSION
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT INT TERM
archive="$work_dir/$name.tar.xz"

echo "install-zig: fetching $name"
curl --fail --location --silent --show-error \
    "https://ziglang.org/download/$FLOODLIGHT_ZIG_VERSION/$name.tar.xz" --output "$archive"

# macOS ships shasum, most Linux images ship sha256sum; either answers.
if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
else
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
fi
if [ "$actual" != "$sha" ]; then
    echo "install-zig: checksum mismatch for $name" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

mkdir -p "$TOOLS_BIN"
rm -rf "$PROJECT_DIR/.tools/$name"
tar -xJf "$archive" -C "$PROJECT_DIR/.tools"
ln -sf "../$name/zig" "$TOOLS_BIN/zig"
echo "install-zig: installed $("$TOOLS_BIN/zig" version)"
