#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SOURCE_ICON=${1:-"$PROJECT_DIR/Sources/Floodlight/Resources/AppIcon.png"}
OUTPUT_ICON=${2:-"$PROJECT_DIR/.build/Floodlight.icns"}

case "$SOURCE_ICON" in
    /*) ;;
    *) SOURCE_ICON="$PROJECT_DIR/$SOURCE_ICON" ;;
esac

case "$OUTPUT_ICON" in
    /*) ;;
    *) OUTPUT_ICON="$PROJECT_DIR/$OUTPUT_ICON" ;;
esac

if [ ! -f "$SOURCE_ICON" ]; then
    echo "App icon master was not found at: $SOURCE_ICON" >&2
    exit 1
fi

ICON_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/floodlight-icon.XXXXXX")
ICONSET="$ICON_WORK_DIR/Floodlight.iconset"
cleanup() {
    rm -R "$ICON_WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$ICONSET" "$(dirname "$OUTPUT_ICON")"

render_size() {
    pixels=$1
    filename=$2
    sips \
        --resampleHeightWidth "$pixels" "$pixels" \
        "$SOURCE_ICON" \
        --out "$ICONSET/$filename" \
        >/dev/null
}

render_size 16 icon_16x16.png
render_size 32 icon_16x16@2x.png
render_size 32 icon_32x32.png
render_size 64 icon_32x32@2x.png
render_size 128 icon_128x128.png
render_size 256 icon_128x128@2x.png
render_size 256 icon_256x256.png
render_size 512 icon_256x256@2x.png
render_size 512 icon_512x512.png
render_size 1024 icon_512x512@2x.png

python3 - "$ICONSET" "$OUTPUT_ICON" "$PROJECT_DIR" <<'EOF'
import os, sys, struct, zlib, subprocess

iconset = sys.argv[1]
output_icns = sys.argv[2]
project_dir = sys.argv[3]

tag_map = [
    ('icon_16x16.png', b'ic04'),
    ('icon_16x16@2x.png', b'ic11'),
    ('icon_32x32.png', b'ic05'),
    ('icon_32x32@2x.png', b'ic12'),
    ('icon_128x128.png', b'ic07'),
    ('icon_128x128@2x.png', b'ic13'),
    ('icon_256x256.png', b'ic08'),
    ('icon_256x256@2x.png', b'ic14'),
    ('icon_512x512.png', b'ic09'),
    ('icon_512x512@2x.png', b'ic10'),
]

pngquant_bin = None
for cand in [os.path.join(project_dir, '.tools/bin/pngquant'), 'pngquant']:
    try:
        subprocess.check_call([cand, '--version'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pngquant_bin = cand
        break
    except Exception:
        pass

oxipng_bin = None
for cand in [os.path.join(project_dir, '.tools/bin/oxipng'), 'oxipng']:
    try:
        subprocess.check_call([cand, '--version'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        oxipng_bin = cand
        break
    except Exception:
        pass

def filter_and_compress(data):
    pos = 8
    ihdr = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos+4])[0]
        ctype = data[pos+4:pos+8]
        cdata = data[pos+8:pos+8+length]
        pos += 12 + length
        if ctype == b'IHDR':
            ihdr = cdata
        elif ctype == b'IDAT':
            idat.extend(cdata)
    if not ihdr or not idat:
        return data
    try:
        decomp = zlib.decompress(idat)
    except Exception:
        return data
    w, h, bit_depth, color_type = struct.unpack('>IIBB', ihdr[:10])
    bpp = 4 if color_type == 6 else (3 if color_type == 2 else 1)
    stride = w * bpp
    if bit_depth != 8 or color_type not in (2, 6) or len(decomp) < (stride + 1) * h:
        recomp = zlib.compress(decomp, 9)
        out = bytearray(b'\x89PNG\r\n\x1a\n')
        out.extend(struct.pack('>I', len(ihdr)) + b'IHDR' + ihdr + struct.pack('>I', zlib.crc32(b'IHDR' + ihdr)))
        out.extend(struct.pack('>I', len(recomp)) + b'IDAT' + recomp + struct.pack('>I', zlib.crc32(b'IDAT' + recomp)))
        out.extend(struct.pack('>I', 0) + b'IEND' + struct.pack('>I', zlib.crc32(b'IEND')))
        return bytes(out)
    raw_rgba = bytearray(stride * h)
    prev_row = bytearray(stride)
    src_pos = 0
    for y in range(h):
        f_type = decomp[src_pos]
        src_pos += 1
        row = bytearray(decomp[src_pos:src_pos+stride])
        src_pos += stride
        if f_type == 1:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + left) & 0xff
        elif f_type == 2:
            for x in range(stride):
                up = prev_row[x]
                row[x] = (row[x] + up) & 0xff
        elif f_type == 3:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                up = prev_row[x]
                row[x] = (row[x] + ((left + up) // 2)) & 0xff
        elif f_type == 4:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                up = prev_row[x]
                up_left = prev_row[x - bpp] if x >= bpp else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                pr = left if (pa <= pb and pa <= pc) else (b if pb <= pc else up_left)
                row[x] = (row[x] + pr) & 0xff
        raw_rgba[y*stride:(y+1)*stride] = row
        prev_row = row
    filtered = bytearray()
    prev_row = bytearray(stride)
    for y in range(h):
        row = raw_rgba[y*stride:(y+1)*stride]
        best_filtered = bytearray([0]) + row
        best_sum = sum(row)
        sub_row = bytearray(stride)
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            sub_row[x] = (row[x] - left) & 0xff
        if sum(sub_row) < best_sum:
            best_sum = sum(sub_row)
            best_filtered = bytearray([1]) + sub_row
        up_row = bytearray(stride)
        for x in range(stride):
            up = prev_row[x]
            up_row[x] = (row[x] - up) & 0xff
        if sum(up_row) < best_sum:
            best_sum = sum(up_row)
            best_filtered = bytearray([2]) + up_row
        paeth_row = bytearray(stride)
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b_val = prev_row[x]
            c = prev_row[x - bpp] if x >= bpp else 0
            p = a + b_val - c
            pa, pb, pc = abs(p - a), abs(p - b_val), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b_val if pb <= pc else c)
            paeth_row[x] = (row[x] - pr) & 0xff
        if sum(paeth_row) < best_sum:
            best_filtered = bytearray([4]) + paeth_row
        filtered.extend(best_filtered)
        prev_row = row
    recomp = zlib.compress(filtered, 9)
    out = bytearray(b'\x89PNG\r\n\x1a\n')
    out.extend(struct.pack('>I', len(ihdr)) + b'IHDR' + ihdr + struct.pack('>I', zlib.crc32(b'IHDR' + ihdr)))
    out.extend(struct.pack('>I', len(recomp)) + b'IDAT' + recomp + struct.pack('>I', zlib.crc32(b'IDAT' + recomp)))
    out.extend(struct.pack('>I', 0) + b'IEND' + struct.pack('>I', zlib.crc32(b'IEND')))
    return bytes(out)

if pngquant_bin:
    for fn, _ in tag_map:
        path = os.path.join(iconset, fn)
        subprocess.call([pngquant_bin, '--quality', '95-100', '--force', '--output', path, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if oxipng_bin:
    files = [os.path.join(iconset, fn) for fn, _ in tag_map]
    subprocess.call([oxipng_bin, '-o', 'max', '--strip', 'all'] + files, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
elif not pngquant_bin:
    for fn, _ in tag_map:
        path = os.path.join(iconset, fn)
        with open(path, 'wb') as f:
            f.write(filter_and_compress(open(path, 'rb').read()))

chunks = []
for fn, tag in tag_map:
    path = os.path.join(iconset, fn)
    data = open(path, 'rb').read()
    chunks.append(tag + struct.pack('>I', len(data) + 8) + data)

body = b''.join(chunks)
icns_data = b'icns' + struct.pack('>I', len(body) + 8) + body
with open(output_icns, 'wb') as f:
    f.write(icns_data)
EOF

if [ ! -s "$OUTPUT_ICON" ]; then
    iconutil --convert icns --output "$OUTPUT_ICON" "$ICONSET"
fi
echo "$OUTPUT_ICON"
