#!/bin/sh
# Builds the release bundle, quits any running Nanospot, moves the old bundle
# to the Trash, copies the new bundle into place, verifies its code signature,
# and checks LaunchServices for stale records pointing at deleted builds.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/tools.sh"

dest=${NANOSPOT_INSTALL_DEST:-/Applications/Nanospot.app}
prune_stale=0
require_index=${NANOSPOT_REQUIRE_FILE_INDEX:-0}

usage() {
    cat <<'EOF'
usage: install-app.sh [--dest PATH] [--prune-stale] [--require-index]

  --dest PATH      Install destination (default: /Applications/Nanospot.app)
  --prune-stale    Unregister stale LaunchServices records for deleted builds
  --require-index  Exit non-zero if ~/Library/Application Support/Nanospot/names.flix is missing
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)
            [ $# -ge 2 ] || { echo "install-app: --dest requires an argument" >&2; exit 2; }
            dest=$2
            shift 2
            ;;
        --dest=*)
            dest=${1#--dest=}
            shift
            ;;
        --prune-stale)
            prune_stale=1
            shift
            ;;
        --require-index)
            require_index=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "install-app: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$dest" in
    ""|"/")
        echo "install-app: refusing unsafe destination: '$dest'" >&2
        exit 2
        ;;
esac

zig=$(resolve_tool zig "$NANOSPOT_ZIG_VERSION" version)
src_bundle="$PROJECT_DIR/app/zig-out/Nanospot.app"
rm -rf "$src_bundle"
(cd "$PROJECT_DIR/app" && "$zig" build bundle --release)

if [ ! -d "$src_bundle" ]; then
    echo "install-app: built bundle missing at $src_bundle" >&2
    exit 1
fi

quit_running() {
    if [ "$dest" = "/Applications/Nanospot.app" ]; then
        osascript -e 'tell application id "com.nanospot.app" to quit' >/dev/null 2>&1 || true
        tries=0
        while [ "$tries" -lt 30 ]; do
            pgrep -x nanospot >/dev/null 2>&1 || return 0
            sleep 0.1
            tries=$((tries + 1))
        done
        pkill -x nanospot >/dev/null 2>&1 || true
        tries=0
        while [ "$tries" -lt 20 ]; do
            pgrep -x nanospot >/dev/null 2>&1 || return 0
            sleep 0.1
            tries=$((tries + 1))
        done
        echo "install-app: running nanospot process did not quit" >&2
        exit 1
    fi

    pkill -f "$dest/Contents/MacOS/" >/dev/null 2>&1 || true
    tries=0
    while [ "$tries" -lt 20 ]; do
        pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1 || return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    echo "install-app: process at $dest did not quit" >&2
    exit 1
}

quit_running

if [ -e "$dest" ] || [ -L "$dest" ]; then
    /usr/bin/trash "$dest"
fi

if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "install-app: refused to copy over existing bundle at $dest" >&2
    exit 1
fi

mkdir -p "$(dirname -- "$dest")"
ditto "$src_bundle" "$dest"

macos_dir="$dest/Contents/MacOS"
exec_count=$(ls -A "$macos_dir" | wc -l | tr -d ' ')
if [ "$exec_count" -ne 1 ] || [ ! -x "$macos_dir/nanospot" ]; then
    echo "install-app: expected exactly one executable (nanospot) in $macos_dir, found $exec_count" >&2
    ls -la "$macos_dir" >&2
    exit 1
fi

codesign --verify --deep --strict -vv "$dest"

cs_info=$(codesign -dv "$dest" 2>&1)
bundle_id=$(printf '%s\n' "$cs_info" | awk -F= '/^Identifier=/{print $2; exit}')
req_info=$(codesign -d -r- "$dest" 2>&1)
designated_req=$(printf '%s\n' "$req_info" | awk '/^designated => /{print; exit}')

printf 'Installed: %s\n' "$dest"
printf 'Bundle identifier: %s\n' "${bundle_id:-<missing>}"
printf 'Designated requirement: %s\n' "${designated_req:-<missing>}"

if [ "$bundle_id" != "com.nanospot.app" ]; then
    echo "install-app: unexpected bundle identifier: ${bundle_id:-<missing>}" >&2
    exit 1
fi

case "$req_info" in
    *'designated => identifier "com.nanospot.app"'*) ;;
    *)
        echo "install-app: designated requirement must name com.nanospot.app:" >&2
        echo "$req_info" >&2
        exit 1
        ;;
esac

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$lsregister" ]; then
    stale_lines=$(
        "$lsregister" -dump 2>/dev/null | awk '
        BEGIN { RS="--------------------------------------------------------------------------------\n" }
        {
            path=""; name=""; display=""; ident="";
            n = split($0, lines, "\n");
            for (i = 1; i <= n; i++) {
                line = lines[i];
                if (match(line, /^path:[ \t]+/)) {
                    val = substr(line, RSTART + RLENGTH);
                    sub(/[ \t]+\(0x[0-9a-fA-F]+\)$/, "", val);
                    path = val;
                } else if (match(line, /^name:[ \t]+/)) {
                    name = substr(line, RSTART + RLENGTH);
                } else if (match(line, /^displayName:[ \t]+/)) {
                    display = substr(line, RSTART + RLENGTH);
                } else if (match(line, /^identifier:[ \t]+/)) {
                    ident = substr(line, RSTART + RLENGTH);
                }
            }
            if (path != "" && (path ~ /\/Nanospot\.app$/ || name == "Nanospot" || display == "Nanospot" || ident == "com.nanospot.app")) {
                if (!seen[path]++) {
                    print path "\t" ident;
                }
            }
        }'
    )
    stale_found=0
    if [ -n "$stale_lines" ]; then
        OLDIFS=$IFS
        IFS='
'
        for rec in $stale_lines; do
            p=${rec%%	*}
            id=${rec#*	}
            if [ ! -e "$p" ]; then
                if [ "$stale_found" -eq 0 ]; then
                    echo "Stale LaunchServices records:"
                fi
                stale_found=1
                printf '  %s (identifier=%s)\n' "$p" "${id:-unknown}"
                if [ "$prune_stale" -eq 1 ]; then
                    "$lsregister" -u "$p"
                    printf '    removed with: %s -u "%s"\n' "$lsregister" "$p"
                else
                    printf '    remove: %s -u "%s"\n' "$lsregister" "$p"
                fi
            fi
        done
        IFS=$OLDIFS
    fi
    if [ "$stale_found" -eq 0 ]; then
        echo "LaunchServices: no stale Nanospot records found."
    elif [ "$prune_stale" -eq 0 ]; then
        echo "Run with --prune-stale to unregister stale LaunchServices records."
    fi
fi

index_file="$HOME/Library/Application Support/Nanospot/names.flix"
if [ -s "$index_file" ]; then
    index_bytes=$(stat -f '%z' "$index_file")
    echo "File Index: present ($index_file, $index_bytes bytes)"
else
    echo "Warning: File Index missing or empty at $index_file (file search will have no rows until Full Disk Access is granted)." >&2
    if [ "$require_index" -eq 1 ]; then
        exit 1
    fi
fi
