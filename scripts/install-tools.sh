#!/bin/sh
# Downloads the pinned gate tools into .tools/bin.
#
# Deliberately not a package manager: each tool is one release artifact from its
# own repository, pinned by version *and* SHA-256, so CI and a laptop install
# byte-identical binaries and neither depends on a third party's formula being
# up to date. The digest is not ceremony — these binaries then run over the
# whole source tree, and a version number only pins which release was asked
# for, not what arrived.
#
# Anything already on PATH at the pinned version is left alone; this only fills
# gaps.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

mkdir -p "$TOOLS_BIN"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT INT TERM

case $(uname -m) in
    arm64)
        astgrep_asset=app-aarch64-apple-darwin.zip
        astgrep_sha=$FLOODLIGHT_ASTGREP_SHA256_ARM64
        ;;
    *)
        astgrep_asset=app-x86_64-apple-darwin.zip
        astgrep_sha=$FLOODLIGHT_ASTGREP_SHA256_X86_64
        ;;
esac

# fetch_zip <url> <sha256> <binary-name-inside-zip> <destination-name>
fetch_zip() {
    echo "install-tools: fetching $4"
    curl --fail --location --silent --show-error "$1" --output "$work_dir/download.zip"

    actual=$(shasum -a 256 "$work_dir/download.zip" | cut -d' ' -f1)
    if [ "$actual" != "$2" ]; then
        echo "install-tools: checksum mismatch for $1" >&2
        echo "  expected $2" >&2
        echo "  actual   $actual" >&2
        echo "Refusing to install. If the upstream release was legitimately" >&2
        echo "re-published, update the digest in scripts/tool-versions.env." >&2
        exit 1
    fi

    rm -rf "$work_dir/unpacked"
    mkdir -p "$work_dir/unpacked"
    unzip -q -o "$work_dir/download.zip" -d "$work_dir/unpacked"
    extracted=$(find "$work_dir/unpacked" -type f -name "$3" -perm -u+x | head -1)
    if [ -z "$extracted" ]; then
        echo "install-tools: $3 not found inside $1" >&2
        exit 1
    fi
    mv "$extracted" "$TOOLS_BIN/$4"
    chmod +x "$TOOLS_BIN/$4"
}

if tool_at_version swiftlint "$FLOODLIGHT_SWIFTLINT_VERSION" version; then
    echo "install-tools: swiftlint $FLOODLIGHT_SWIFTLINT_VERSION already present"
else
    fetch_zip \
        "https://github.com/realm/SwiftLint/releases/download/$FLOODLIGHT_SWIFTLINT_VERSION/portable_swiftlint.zip" \
        "$FLOODLIGHT_SWIFTLINT_SHA256" swiftlint swiftlint
fi

if tool_at_version swiftformat "$FLOODLIGHT_SWIFTFORMAT_VERSION" --version; then
    echo "install-tools: swiftformat $FLOODLIGHT_SWIFTFORMAT_VERSION already present"
else
    fetch_zip \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/$FLOODLIGHT_SWIFTFORMAT_VERSION/swiftformat.zip" \
        "$FLOODLIGHT_SWIFTFORMAT_SHA256" swiftformat swiftformat
fi

if tool_at_version ast-grep "$FLOODLIGHT_ASTGREP_VERSION" --version; then
    echo "install-tools: ast-grep $FLOODLIGHT_ASTGREP_VERSION already present"
else
    fetch_zip \
        "https://github.com/ast-grep/ast-grep/releases/download/$FLOODLIGHT_ASTGREP_VERSION/$astgrep_asset" \
        "$astgrep_sha" ast-grep ast-grep
fi

if tool_at_version periphery "$FLOODLIGHT_PERIPHERY_VERSION" version; then
    echo "install-tools: periphery $FLOODLIGHT_PERIPHERY_VERSION already present"
else
    fetch_zip \
        "https://github.com/peripheryapp/periphery/releases/download/$FLOODLIGHT_PERIPHERY_VERSION/periphery-$FLOODLIGHT_PERIPHERY_VERSION.zip" \
        "$FLOODLIGHT_PERIPHERY_SHA256" periphery periphery
    # The release binary links libIndexStore.dylib through an @rpath that
    # includes @executable_path, and the dylib only ships inside Xcode's
    # toolchain. Putting a link beside the binary is what the package managers
    # do for you, and it means nothing has to export DYLD_* at call time.
    index_store="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
    if [ ! -f "$index_store" ]; then
        echo "install-tools: libIndexStore.dylib not found under $(xcode-select -p)" >&2
        echo "Periphery needs a full Xcode toolchain, not just Command Line Tools." >&2
        exit 1
    fi
    ln -sf "$index_store" "$TOOLS_BIN/libIndexStore.dylib"
fi

echo "install-tools: pinned tools available in $TOOLS_BIN"
