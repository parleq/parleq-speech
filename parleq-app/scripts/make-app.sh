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
# Phase 2 (Reference Windows): the SwiftPM executable was renamed
# from "ParleqApp" to "parleq-app" when the package was split into
# ParleqAppCore (library) + parleq-app (thin executable). We still
# copy/rename to "ParleqApp" inside the .app bundle because
# Info.plist's CFBundleExecutable hasn't changed.
BINARY="$BIN_PATH/parleq-app"
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

# Stage the prebuilt MLX Metal shader library next to the executable.
# `swift build` cannot compile MLX's Metal shaders (Xcode-only build
# phase); the MLX runtime looks for mlx.metallib next to the executable
# first (mlx/backend/metal/device.cpp, load_default_library). Must run
# BEFORE codesign so the metallib is inside the signed bundle.
# Note: APP_DIR is already resolved above; scripts/ is always a peer of
# the directory make-app.sh lives in.
"$APP_DIR/scripts/fetch-metallib.sh" "$APP_BUNDLE/Contents/MacOS"

# Inject the standard macOS-bundle framework search path into the
# executable's LC_RPATH. SwiftPM doesn't add this for binary-target
# frameworks (it injects @executable_path/ only, treating the
# binary as a CLI tool), so without this step the runtime looks
# for Sparkle.framework at Contents/MacOS/ rather than the
# Contents/Frameworks/ where make-app.sh embeds it — dyld fails
# with "Library not loaded: @rpath/Sparkle.framework/..." on
# launch. Xcode-built apps get this rpath automatically; SwiftPM-
# built apps have to set it themselves.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/ParleqApp"

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

# Open-source attribution files. Apache-2.0 §4 (the license covering
# most of our deps) and the MIT/BSD attribution clauses (Sparkle and
# its vendored components) want us to propagate notices alongside any
# binary redistribution. Copying these into Contents/Resources/
# physically satisfies that for the notarized .app — downstream
# redistributors don't need to ship a separate notice file alongside
# the .dmg, and end users with curiosity can find the credits by
# Show Package Contents on Parleq.app. See THIRD_PARTY_LICENSES.md
# for the policy this implements.
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
for f in LICENSE NOTICE THIRD_PARTY_LICENSES.md; do
    if [[ -f "$REPO_ROOT/$f" ]]; then
        cp "$REPO_ROOT/$f" "$APP_BUNDLE/Contents/Resources/$f"
    else
        echo "WARNING: $f not found at $REPO_ROOT/$f; .app will ship without it" >&2
    fi
done

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
# in-process consolidation drops the second SwiftPM build and the
# Resources/sidecar directory.

# Embed Sparkle.framework. SwiftPM's binary-target integration leaves
# Sparkle.framework in .build/<triple>/<config>/, NOT inside the
# .app's Contents/Frameworks/ where the runtime expects it — that
# step is on the integrator. A missing framework is a hard error,
# not a warning: the main binary links Sparkle, so a build without
# the framework produces a guaranteed-crash-on-launch bundle.
# Failing here is much friendlier than getting a launch-time
# `dlopen Sparkle` crash from a user.
SPARKLE_BUILD_DIR=$(swift build -c "$CONFIG" --show-bin-path)
SPARKLE_SRC="$SPARKLE_BUILD_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_SRC." >&2
    echo "       The main executable links Sparkle, so the .app would crash" >&2
    echo "       on launch without the embedded framework. Try:" >&2
    echo "         cd $APP_DIR && swift package resolve && swift build -c $CONFIG" >&2
    echo "       If that doesn't repopulate the framework, clear the artifact" >&2
    echo "       cache and rebuild:" >&2
    echo "         rm -rf $APP_DIR/.build/artifacts && swift build -c $CONFIG" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
echo "    embedded Sparkle.framework: $(du -sh "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" | awk '{print $1}')"

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
# Sign innermost-first: Sparkle.framework's nested helpers, then
# Sparkle.framework, then the outer .app bundle. Apple's notarization
# rejects --deep'd nested binaries because --deep doesn't reliably
# propagate --options runtime + --timestamp into them — every nested
# binary gets its own codesign call, each with --options runtime and
# --timestamp.
#
# The nested helpers (Updater.app, the two .xpc services, Autoupdate)
# come pre-signed by the Sparkle project, but Apple's notary requires
# every binary in the eventual .app tree to be signed by the SAME
# Developer ID. `--force` replaces Sparkle's signature; we keep their
# original entitlements via `--preserve-metadata=entitlements`
# because those helpers need specific XPC client/service rights that
# our app's entitlements file doesn't grant.
ENTITLEMENTS_FILE="$APP_DIR/Resources/Parleq.entitlements"
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ "$IDENTITY" == "-" ]]; then
    # Ad-hoc: keep --deep, no Hardened Runtime — there's no path to
    # notarization from ad-hoc anyway and the simpler form keeps
    # local dev easy.
    codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
    if [[ -d "$SPARKLE_FW" ]]; then
        # Sparkle's nested helpers in dependency order. Use the
        # `Versions/Current` symlink rather than hard-coding
        # `Versions/B`: a future Sparkle release that bumps to
        # `Versions/C` (Apple convention when ABI breaks) would
        # otherwise silently skip every signing step and ship an
        # unsigned-nested-binary bundle that notarization rejects.
        SPARKLE_CURRENT="$SPARKLE_FW/Versions/Current"
        if [[ ! -L "$SPARKLE_FW/Versions/Current" ]]; then
            echo "ERROR: $SPARKLE_FW/Versions/Current is not a symlink." >&2
            echo "       Sparkle's framework layout is unexpected — the signing" >&2
            echo "       loop below relies on Versions/Current pointing at the" >&2
            echo "       active version directory. Has Sparkle changed its layout?" >&2
            exit 1
        fi
        for nested in \
            "$SPARKLE_CURRENT/XPCServices/Downloader.xpc" \
            "$SPARKLE_CURRENT/XPCServices/Installer.xpc" \
            "$SPARKLE_CURRENT/Updater.app" \
            "$SPARKLE_CURRENT/Autoupdate"; do
            if [[ ! -e "$nested" ]]; then
                echo "ERROR: missing nested Sparkle helper at $nested." >&2
                echo "       The framework layout is unexpected — all four nested" >&2
                echo "       binaries (Downloader.xpc, Installer.xpc, Updater.app," >&2
                echo "       Autoupdate) need to be signed with the Developer ID" >&2
                echo "       identity or notarization will reject the bundle. Has" >&2
                echo "       Sparkle dropped or renamed one of them?" >&2
                exit 1
            fi
            codesign --force --sign "$IDENTITY" \
                --options runtime \
                --timestamp \
                --preserve-metadata=entitlements \
                "$nested"
        done
        # Outer framework. No --preserve-metadata here; the framework
        # bundle itself doesn't carry entitlements.
        codesign --force --sign "$IDENTITY" \
            --options runtime \
            --timestamp \
            "$SPARKLE_FW"
    fi
    # Sign the MLX Metal shader library. `mlx.metallib` is a MetalLib
    # code object (not a data file), so codesign treats it as a nested
    # binary and requires it to be signed before the outer .app seal.
    # Ad-hoc path above uses --deep which covers it automatically.
    METALLIB_PATH="$APP_BUNDLE/Contents/MacOS/mlx.metallib"
    if [[ -f "$METALLIB_PATH" ]]; then
        # No --preserve-metadata=entitlements: MetalLib code objects carry no
        # entitlements; the flag is only meaningful for XPC service bundles (Sparkle).
        codesign --force --sign "$IDENTITY" \
            --options runtime \
            --timestamp \
            "$METALLIB_PATH"
    fi
    # Outer .app bundle. No --deep; the nested signatures above
    # remain intact.
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
