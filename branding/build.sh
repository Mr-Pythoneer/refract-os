#!/usr/bin/env bash
#
# Rasterizes the SVG sources in branding/src/ to the PNGs Calamares branding
# expects (see iso/calamares/branding/refractos/branding.desc) and to a
# square favicon for the website.
#
# Built/verified on macOS using `qlmanage -t` (QuickLook's own thumbnail
# generator, ships with every macOS install) as the SVG rasterizer, since no
# CLI SVG renderer (rsvg-convert/inkscape/cairosvg) is installed here. Per
# this project's disk-as-cache rule, this script runs on whatever box has it
# checked out -- on a real Linux box, swap RASTERIZE() below for
# `rsvg-convert -w W -h H in.svg -o out.png`, which is the more standard tool
# there and doesn't need the letterbox-crop step this macOS path requires.
#
# qlmanage's thumbnailer always pads non-square input to a square canvas
# (white-letterboxed) at the requested size -- this script crops that back
# out by detecting the non-white band, rather than hand-coding crop offsets
# that would silently break if the source SVG's aspect ratio ever changes.
#
# Usage: ./build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/src"
OUT="$SCRIPT_DIR/out"
CALAMARES_DIR="$SCRIPT_DIR/../iso/calamares/branding/refractos"

mkdir -p "$OUT"

if ! command -v qlmanage >/dev/null 2>&1; then
    echo "build.sh: qlmanage not found -- this rasterization path is macOS-specific." >&2
    echo "On Linux, use: rsvg-convert -w W -h H src/X.svg -o out/X.png" >&2
    exit 1
fi

# Renders one SVG to an exact W x H PNG. qlmanage renders into a SQUARE canvas
# (scaling to fit the SVG's own viewBox aspect, white-letterboxing the rest), so
# the real content band is determined by the SOURCE viewBox aspect, NOT the
# target — crop the band using the parsed viewBox, then resize to the target.
rasterize() {
    local svg="$1" width="$2" height="$3" out_name="$4"
    local square=$(( width > height ? width : height ))

    # Parse "viewBox='minx miny W H'" -> src_w/src_h (3rd/4th tokens).
    local vb src_w src_h
    vb="$(grep -o 'viewBox="[^"]*"' "$svg" | head -n1 | sed -E 's/viewBox="([^"]*)"/\1/')"
    src_w="$(printf '%s\n' "$vb" | awk '{print $3}')"
    src_h="$(printf '%s\n' "$vb" | awk '{print $4}')"
    if [ -z "$src_w" ] || [ -z "$src_h" ]; then
        echo "build.sh: could not parse viewBox from $svg" >&2
        return 1
    fi

    rm -f "$OUT/$(basename "$svg").png"
    qlmanage -t -s "$square" -o "$OUT" "$svg" >/dev/null

    PYTARGETW="$width" PYTARGETH="$height" PYSRCW="$src_w" PYSRCH="$src_h" \
    SRC_PNG="$OUT/$(basename "$svg").png" DEST_PNG="$OUT/$out_name" python3 -c '
import os
from PIL import Image

im = Image.open(os.environ["SRC_PNG"]).convert("RGBA")
square = im.size[0]
target_w = int(os.environ["PYTARGETW"])
target_h = int(os.environ["PYTARGETH"])
src_w = float(os.environ["PYSRCW"])
src_h = float(os.environ["PYSRCH"])

# The non-white content band inside the square is fixed by the SOURCE aspect:
# qlmanage scaled the viewBox to fit the square and centered it.
if src_w >= src_h:
    content_h = round(square * (src_h / src_w))
    top = (square - content_h) // 2
    box = (0, top, square, top + content_h)
else:
    content_w = round(square * (src_w / src_h))
    left = (square - content_w) // 2
    box = (left, 0, left + content_w, square)

cropped = im.crop(box).resize((target_w, target_h), Image.LANCZOS)
cropped.save(os.environ["DEST_PNG"])
'
    rm -f "$OUT/$(basename "$svg").png"
    echo "Wrote $OUT/$out_name (${width}x${height})"
}

rasterize "$SRC/logo.svg" 512 512 "logo.png"
rasterize "$SRC/welcome.svg" 1024 460 "welcome.png"
rasterize "$SRC/logo.svg" 256 256 "favicon.png"
# logo-clean.png + logo-small.png are consumed by iso/build.sh (Plymouth splash,
# /usr/share/refract, GDM greeter, fastfetch). They used to be hand-made 720px
# PNGs with the logo anchored in the TOP-LEFT of an oversized transparent canvas,
# which is why the boot splash + login logo rendered up-and-left of center.
# Generate them here from the SVG so the content is centered/tight like the rest.
rasterize "$SRC/logo.svg" 512 512 "logo-clean.png"
rasterize "$SRC/logo.svg" 200 200 "logo-small.png"

mkdir -p "$CALAMARES_DIR"
cp "$OUT/logo.png" "$CALAMARES_DIR/logo.png"
cp "$OUT/welcome.png" "$CALAMARES_DIR/welcome.png"
echo "Copied logo.png + welcome.png into $CALAMARES_DIR"

echo
echo "favicon.png is for docs/ (the website) -- copy it in manually if docs/index.html"
echo "gains a <link rel=\"icon\"> reference; not auto-wired since that's a website-content"
echo "decision, not a branding-asset one."
