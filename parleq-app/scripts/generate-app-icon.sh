#!/usr/bin/env bash
# generate-app-icon.sh — rebuild parleq-app/Resources/AppIcon.icns from
# web/public/favicon.svg.
#
# One-shot: run by hand whenever the favicon design changes. The
# resulting AppIcon.icns is checked in so day-to-day `make install`
# doesn't depend on qlmanage (which is fast but produces non-bit-
# reproducible output across macOS versions).
#
# Pipeline:
#   1. qlmanage -t -s 1024 favicon.svg → 1024×1024 PNG master
#   2. sips downsizes the master into the iconset sizes Apple expects
#      (16, 32, 64, 128, 256, 512, 1024 — with @2x variants)
#   3. iconutil packs the .iconset folder into AppIcon.icns
#
# Tools used (all preinstalled on macOS, no Homebrew dependency):
#   qlmanage, sips, iconutil.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
SOURCE_SVG="$REPO_ROOT/web/public/favicon.svg"
OUT_ICNS="$APP_DIR/Resources/AppIcon.icns"

if [[ ! -f "$SOURCE_SVG" ]]; then
    echo "ERROR: source SVG not found at $SOURCE_SVG" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering 1024×1024 master via qlmanage"
qlmanage -t -s 1024 -o "$TMP" "$SOURCE_SVG" >/dev/null 2>&1
MASTER="$TMP/favicon.svg.png"
if [[ ! -f "$MASTER" ]]; then
    echo "ERROR: qlmanage failed to produce $MASTER" >&2
    exit 1
fi

# iconutil expects this exact filename convention. Anything else fails
# with "Failed to generate ICNS" and no useful error.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

echo "==> downsizing to iconset (10 variants)"
for pair in "${SIZES[@]}"; do
    size="${pair%%:*}"
    name="${pair##*:}"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

echo "==> packing AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo ""
echo "Wrote: $OUT_ICNS"
echo "Size:  $(du -sh "$OUT_ICNS" | awk '{print $1}')"
