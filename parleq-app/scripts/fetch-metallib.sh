#!/usr/bin/env bash
# fetch-metallib.sh — stage the prebuilt MLX Metal shader library.
#
# `swift build` cannot compile MLX's Metal shaders (mlx-swift README;
# Xcode-only build phase). MLX's runtime looks for `mlx.metallib` next
# to the executable FIRST (mlx/backend/metal/device.cpp,
# load_default_library), so we ship the prebuilt metallib from the
# matching mlx-swift release asset, into Contents/MacOS/, BEFORE codesign.
#
# VERSION RULE: the metallib must come from the SAME mlx-swift release
# that Package.resolved pins — mismatched kernels fail subtly.
# Bump procedure: change MLX_SWIFT_VERSION + METALLIB_SHA256 together
# with the Package.swift pin.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: fetch-metallib.sh <DEST-DIR>" >&2
  exit 1
fi

MLX_SWIFT_VERSION="0.31.4"           # must match Package.swift pin
METALLIB_SHA256="4306c203e313df5cf796680ee800984172028634922be436802b33d93bf3af1b"
CACHE_DIR="$(dirname "$0")/../.build-cache"
DEST="$1"                            # path to copy mlx.metallib into

mkdir -p "$CACHE_DIR"
LIB="$CACHE_DIR/mlx-$MLX_SWIFT_VERSION.metallib"

# Cross-check the pin against Package.resolved so the two can't drift.
if ! command -v python3 >/dev/null 2>&1; then
  echo "fetch-metallib: python3 is required (install Xcode Command Line Tools)." >&2
  exit 1
fi
RESOLVED=$(python3 -c '
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
match = next((p["state"]["version"] for p in pins if p["identity"] == "mlx-swift"), None)
if match is None:
  sys.exit("fetch-metallib: mlx-swift not found in Package.resolved — identity may have changed")
print(match)' "$(dirname "$0")/../Package.resolved")
if [ "$RESOLVED" != "$MLX_SWIFT_VERSION" ]; then
  echo "fetch-metallib: Package.resolved has mlx-swift $RESOLVED but script pins $MLX_SWIFT_VERSION — update both together." >&2
  exit 1
fi

if [ ! -f "$LIB" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  # NOTE: release tags have NO "v" prefix.
  curl -fL --retry 3 -o "$TMP/cmlx.zip" \
    "https://github.com/ml-explore/mlx-swift/releases/download/$MLX_SWIFT_VERSION/Cmlx.xcframework.zip"
  unzip -q "$TMP/cmlx.zip" -d "$TMP"
  SRC="$TMP/Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib"
  [ -f "$SRC" ] || SRC=$(find "$TMP" -name "default.metallib" 2>/dev/null | head -1 || true)
  if [[ -z "$SRC" ]]; then
    echo "fetch-metallib: default.metallib not found in Cmlx.xcframework.zip — upstream layout may have changed." >&2
    exit 1
  fi
  echo "$METALLIB_SHA256  $SRC" | shasum -a 256 -c - >/dev/null || {
    echo "fetch-metallib: SHA-256 mismatch on downloaded metallib — aborting." >&2
    exit 1
  }
  cp "$SRC" "$LIB"
fi

echo "$METALLIB_SHA256  $LIB" | shasum -a 256 -c - >/dev/null || {
  echo "fetch-metallib: cached metallib at $LIB failed SHA check — removing for re-download." >&2
  rm -f "$LIB"
  exit 1
}
cp "$LIB" "$DEST/mlx.metallib"
echo "fetch-metallib: staged $(du -h "$DEST/mlx.metallib" | cut -f1) mlx.metallib ($MLX_SWIFT_VERSION)"
