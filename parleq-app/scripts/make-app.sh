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

# LaunchAgent plist for "Open at Login" via SMAppService.mainApp.
# macOS looks for this file at Contents/Library/LaunchAgents/<bundle-id>.plist
# and reports `SMAppService.mainApp.status == .notFound` (with no path
# to recover) if it's absent. The file has to be in place *before*
# codesign runs — adding it later would invalidate the signature.
LAUNCH_AGENT_SOURCE="$APP_DIR/Resources/LaunchAgents/com.parleq.app.plist"
if [[ -f "$LAUNCH_AGENT_SOURCE" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"
    cp "$LAUNCH_AGENT_SOURCE" "$APP_BUNDLE/Contents/Library/LaunchAgents/com.parleq.app.plist"
else
    echo "WARNING: LaunchAgent plist not found at $LAUNCH_AGENT_SOURCE; Open at Login will not work" >&2
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

# FluidAudio runs in-process now (see LocalASR.swift). Previously
# this stage built a separate `fluidaudio-sidecar` binary, copied it
# to Contents/Resources/sidecar/, and signed it independently. The
# in-process consolidation drops the second SwiftPM build, the
# Resources/sidecar directory, and the nested codesigning pass — the
# bundle is now a single signed executable.

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
# Single signing pass on the bundle. Previously this stage signed a
# nested sidecar binary first (Apple's notarization rejects --deep'd
# nested binaries), then the outer bundle. With FluidAudio folded
# into the main executable there's nothing nested to sign — one call
# covers everything.
ENTITLEMENTS_FILE="$APP_DIR/Resources/Parleq.entitlements"
if [[ "$IDENTITY" == "-" ]]; then
    # Ad-hoc: keep --deep, no Hardened Runtime — there's no path to
    # notarization from ad-hoc anyway and the simpler form keeps
    # local dev easy.
    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
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
