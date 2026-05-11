#!/usr/bin/env bash
# make-app.sh — wrap the SwiftPM release binary into Parleq.app.
#
# Output: parleq-app/build/Parleq.app
#
# Why we need this: SwiftPM produces a Mach-O executable, not a macOS
# .app bundle. Without the .app wrapper, permission prompts (Microphone,
# Accessibility) attribute to the parent process (Terminal during
# `swift run`, login shell otherwise) and the mic dialog reads "Terminal
# wants to access the microphone" instead of "Parleq wants to access".
# A real bundle also gives us a stable identity for permission grants
# (so they survive rebuilds), Login Items support, and the ability to
# drag-to-/Applications.
#
# Usage:
#   parleq-app/scripts/make-app.sh           # release build, wrap, sign
#   parleq-app/scripts/make-app.sh --debug   # debug build (faster iteration)
#
# Stages:
#   1. swift build -c release (or debug)
#   2. assemble Parleq.app/Contents/{Info.plist, MacOS/ParleqApp}
#   3. ad-hoc codesign so macOS will run it without quarantine warnings
#
# Ad-hoc signing keeps a stable identity (same bundle ID) across
# rebuilds, which means TCC entries (Mic, Accessibility) carry over.
# Switching between debug and release does NOT change the bundle ID,
# so permissions persist either way.

set -euo pipefail

# Resolve script's parent (parleq-app/) regardless of where it's run from.
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_PATH/ParleqApp"
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: built binary not found at $BINARY" >&2
    exit 1
fi

OUT_DIR="$APP_DIR/build"
APP_BUNDLE="$OUT_DIR/Parleq.app"

# Clean prior bundle so stale files (e.g. an old binary still present
# under a renamed executable name) don't survive.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$APP_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/ParleqApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/ParleqApp"

# App icon — Info.plist's CFBundleIconFile points at "AppIcon" which
# macOS resolves to Contents/Resources/AppIcon.icns. The same .icns
# drives the Dock tile, the Finder Get Info pane, and the standard
# About panel. Regenerate via scripts/generate-app-icon.sh when the
# favicon design changes.
if [[ -f "$APP_DIR/Resources/AppIcon.icns" ]]; then
    cp "$APP_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "WARNING: AppIcon.icns not found at $APP_DIR/Resources/AppIcon.icns; bundle will use generic icon" >&2
fi

# Auto-bump CFBundleVersion (the build number) from the git commit
# count. CFBundleShortVersionString (the marketing version) stays
# whatever's in the source Info.plist — bump that intentionally via
# `make set-version VERSION=x.y.z`.
#
# Apple's notarytool effectively requires CFBundleVersion to
# increment between submissions of the same marketing version, and
# macOS uses (CFBundleShortVersionString, CFBundleVersion) to decide
# whether a downloaded copy is "newer" than what's installed. The
# git rev-list count gives a monotonic-per-commit number that's
# stable across machines and builds.
#
# Falls back to the value already in Info.plist if we're not in a
# git checkout (e.g. someone untarred a source archive).
if BUILD_NUMBER=$(git -C "$APP_DIR" rev-list --count HEAD 2>/dev/null) && [[ -n "$BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
        "$APP_BUNDLE/Contents/Info.plist"
    SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$APP_BUNDLE/Contents/Info.plist")
    echo "    version: $SHORT_VERSION (build $BUILD_NUMBER)"
fi

# Build and embed the FluidAudio sidecar binary so the .app is
# self-contained — no separate process to start manually. The
# supervisor inside Parleq.app launches it at startup, watches for
# crashes, and terminates it on quit.
SIDECAR_DIR="$APP_DIR/../third_party/fluidaudio-sidecar"
if [[ -d "$SIDECAR_DIR" ]]; then
    echo "==> swift build -c release (sidecar)"
    (cd "$SIDECAR_DIR" && swift build -c release)
    SIDECAR_BIN_DIR=$(cd "$SIDECAR_DIR" && swift build -c release --show-bin-path)
    SIDECAR_BIN="$SIDECAR_BIN_DIR/fluidaudio-sidecar"
    if [[ -x "$SIDECAR_BIN" ]]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/sidecar"
        cp "$SIDECAR_BIN" "$APP_BUNDLE/Contents/Resources/sidecar/fluidaudio-sidecar"
        chmod +x "$APP_BUNDLE/Contents/Resources/sidecar/fluidaudio-sidecar"
        echo "    embedded sidecar: $(du -sh "$APP_BUNDLE/Contents/Resources/sidecar/fluidaudio-sidecar" | awk '{print $1}')"
    else
        echo "WARNING: sidecar binary not found at $SIDECAR_BIN; bundle will rely on an external sidecar at runtime" >&2
    fi
else
    echo "WARNING: sidecar source not found at $SIDECAR_DIR; bundle will rely on an external sidecar at runtime" >&2
fi

# Pick a signing identity:
#   1. Honor PARLEQ_CODESIGN_IDENTITY env var if set (lets the user
#      override or force ad-hoc with "-").
#   2. Otherwise prefer the first "Developer ID Application:" cert.
#      This is what Gatekeeper accepts for executable trust, and what
#      SMAppService.mainApp needs to register Parleq as a Login Item
#      from inside the app. With Developer ID, spctl -a -t exec on the
#      built bundle returns "accepted source=Developer ID".
#   3. Otherwise fall back to "Apple Development:" — the free Xcode
#      cert that's still useful day-to-day (stable identity, TCC
#      grants persist) but doesn't satisfy Gatekeeper exec, so the
#      Login Items toggle will fall back to opening System Settings.
#   4. Last resort: ad-hoc.
IDENTITY="${PARLEQ_CODESIGN_IDENTITY:-}"
# Use the SHA-1 hash rather than the cert's display name, because
# multiple certs (e.g. an old + a regenerated one from the same team)
# can share the same display name and codesign refuses an ambiguous
# match. Hashes are unique. The output of `security find-identity -v`
# is "  N) <SHA-1> "<display name>"" — column 2 is the hash we want.
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application:/{print $2; exit}')
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development:/{print $2; exit}')
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "==> codesign --sign - (ad-hoc; no signing identity found in keychain)"
else
    echo "==> codesign --sign \"$IDENTITY\""
fi
# Sign nested binaries first, then the outer bundle. Apple's
# notarization rejects --deep'd nested binaries because --deep
# doesn't reliably propagate --options runtime + --timestamp to
# them — the embedded sidecar shows up as "not Hardened Runtime,
# no secure timestamp, not Developer ID" in the notary log even
# when the bundle's own signature looks fine.
#
# Sign innermost-first: the sidecar binary, then the .app bundle.
# No --deep on the bundle call — the prior nested signatures stay
# intact. --timestamp is required for notarization on every signing
# call. The sidecar gets the same entitlements as the app; it
# doesn't actually use audio-input or network.client, but
# Hardened Runtime treats entitlements as upper bounds, not
# requirements, so the extras are harmless.
ENTITLEMENTS_FILE="$APP_DIR/Resources/Parleq.entitlements"
NESTED_BINS=(
    "$APP_BUNDLE/Contents/Resources/sidecar/fluidaudio-sidecar"
)
if [[ "$IDENTITY" == "-" ]]; then
    # Ad-hoc: keep --deep, no Hardened Runtime — there's no path to
    # notarization from ad-hoc anyway and the simpler form keeps
    # local dev easy.
    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
    for bin in "${NESTED_BINS[@]}"; do
        if [[ -f "$bin" ]]; then
            codesign --force --sign "$IDENTITY" \
                --options runtime \
                --entitlements "$ENTITLEMENTS_FILE" \
                --timestamp \
                "$bin"
        fi
    done
    codesign --force --sign "$IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        --timestamp \
        "$APP_BUNDLE"
fi

echo ""
echo "Built: $APP_BUNDLE"
echo "Run:   open $APP_BUNDLE"
echo "Or drag to /Applications."
