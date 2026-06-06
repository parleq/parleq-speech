#!/bin/bash
# Renders og-image-src/og-image.html → public/og-image.png (1200×630)
# using headless Chrome. Run from anywhere; needs network for fonts.
set -euo pipefail
cd "$(dirname "$0")/.."
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars \
  --window-size=1200,630 \
  --virtual-time-budget=5000 \
  --screenshot="public/og-image.png" \
  "file://$PWD/og-image-src/og-image.html"
echo "Wrote public/og-image.png ($(sips -g pixelWidth -g pixelHeight public/og-image.png | tail -2 | awk '{print $2}' | paste -sd x -))"
