# Parleq build & install targets.
#
# Common usage:
#   make build         Build release Parleq.app at parleq-app/build/Parleq.app
#   make build-debug   Debug build (faster compile, slower runtime, larger binary)
#   make install       Copy Parleq.app to $(INSTALL_DEST)
#   make run           Build and open the .app
#   make clean         Remove build artifacts
#
# Override the install destination per-invocation:
#   make install INSTALL_DEST=$$HOME/Applications/Parleq.app
#
# Override the signing identity (default: auto-detect Apple Development
# cert, fall back to ad-hoc):
#   make build CODESIGN_IDENTITY="Developer ID Application: My Name (XXXX)"
#   make build CODESIGN_IDENTITY=-      # force ad-hoc
#
# FluidAudio (Parakeet TDT v3 on the Apple Neural Engine) runs
# in-process — no sidecar binary to build, supervise, or sign
# separately. See LocalASR.swift for the in-process consolidation.

APP_DIR           := parleq-app
APP_BUNDLE        := $(APP_DIR)/build/Parleq.app
# Canonical source for CFBundleShortVersionString. The built bundle's
# Info.plist is a copy of this, so reading from the source rather than
# the bundle guarantees release-precheck and release see the same value
# even if a stale bundle from a prior version lingers in build/.
SOURCE_INFO_PLIST := $(APP_DIR)/Resources/Info.plist
# Source of truth for the GitHub release body. The version-bump PR
# updates this alongside CHANGELOG.md; `make release` validates its
# first line against SOURCE_INFO_PLIST's CFBundleShortVersionString
# before doing anything destructive.
RELEASE_NOTES     := RELEASE_NOTES.txt
APPCAST           := web/public/appcast.xml
INSTALL_DEST      := /Applications/Parleq.app
CODESIGN_IDENTITY :=
# Keychain profile name for `xcrun notarytool`. Created once via
# `xcrun notarytool store-credentials` (see `make help` output for
# the full command). Override to use a different profile.
NOTARY_PROFILE    := parleq-notarize
# Sparkle's sign_update tool. Generates the Ed25519 signature each
# released .dmg gets recorded against in the appcast. Loads the
# private key from the maintainer's macOS Keychain (where
# generate_keys placed it). Override SPARKLE_SIGN_UPDATE for a
# different install path (e.g. a colleague's machine that extracted
# the Sparkle tarball somewhere else):
#   make release SPARKLE_SIGN_UPDATE=/opt/sparkle/bin/sign_update
SPARKLE_SIGN_UPDATE := $(HOME)/Tools/sparkle/bin/sign_update

.DEFAULT_GOAL := help
.PHONY: help build build-debug install run clean notarize dmg dmg-preview release release-precheck set-version show-version

help:
	@echo "Parleq build & install"
	@echo ""
	@echo "Targets:"
	@echo "  build         Build release Parleq.app (output: $(APP_BUNDLE))"
	@echo "  build-debug   Build debug Parleq.app (faster iteration)"
	@echo "  install       Copy Parleq.app to $(INSTALL_DEST)"
	@echo "  run           Build and open the .app"
	@echo "  notarize      Build + submit to Apple for notarization + staple"
	@echo "  dmg-preview   Build a DMG without signing or notarizing — fast"
	@echo "                feedback loop for verifying the create-dmg layout"
	@echo "  dmg           notarize + bundle the stapled .app in a signed,"
	@echo "                notarized, stapled DMG (drag-to-Applications layout)"
	@echo "  release       dmg + create GitHub release with assets + dispatch site redeploy."
	@echo "                Requires RELEASE_NOTES.txt at repo root with first line"
	@echo "                referencing 'Parleq <version>'. Branch must be pushed."
	@echo "  show-version  Print the current marketing version + build number"
	@echo "  set-version   Set marketing version. Usage: make set-version VERSION=0.5.0"
	@echo "  clean         Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  INSTALL_DEST       Install destination (default: $(INSTALL_DEST))"
	@echo "  CODESIGN_IDENTITY  Override the auto-detected signing identity"
	@echo "  NOTARY_PROFILE     notarytool keychain profile (default: $(NOTARY_PROFILE))"

build:
	PARLEQ_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" $(APP_DIR)/scripts/make-app.sh

build-debug:
	PARLEQ_CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" $(APP_DIR)/scripts/make-app.sh --debug

install: build
	@# Replace any prior install. macOS lets us unlink a running .app's
	@# files; a running Parleq keeps its mmap'd inode alive until quit.
	rm -rf "$(INSTALL_DEST)"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DEST)"
	@echo ""
	@echo "Installed to $(INSTALL_DEST)"
	@echo "If Parleq was already running, quit and re-launch to pick up the new build."

run: build
	open "$(APP_BUNDLE)"

clean:
	rm -rf $(APP_DIR)/.build $(APP_DIR)/build

# Submit Parleq.app to Apple for notarization, wait for the result,
# and staple the ticket on success. Requires a one-time setup:
#
#   xcrun notarytool store-credentials parleq-notarize \
#     --apple-id <your-apple-id-email> \
#     --team-id N7S8GXC725 \
#     --password <app-specific-password>
#
# (Generate an app-specific password at https://appleid.apple.com →
# Sign-In and Security → App-Specific Passwords.)
#
# Notarization is required for SMAppService.mainApp to accept Parleq
# as a Login Item. Once notarized + stapled, spctl will say
# "accepted source=Notarized Developer ID" and the menu's
# "Open at Login" toggle works without going through System Settings.
notarize: build
	@# notarytool requires a zip (or .pkg / .dmg). Make a fresh one
	@# in build/ alongside the .app.
	@rm -f $(APP_DIR)/build/Parleq.zip
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(APP_DIR)/build/Parleq.zip"
	@# `notarytool submit` itself reports a clear error if the
	@# credentials profile is missing, so we don't pre-check.
	xcrun notarytool submit "$(APP_DIR)/build/Parleq.zip" \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	xcrun stapler staple "$(APP_BUNDLE)"
	@echo ""
	@echo "Notarized + stapled. Verify:"
	@echo "  spctl -a -t exec --verbose $(APP_BUNDLE)"
	@echo "  (should print: accepted source=Notarized Developer ID)"

# `make dmg-preview` is the layout-iteration dry-run for `make dmg`.
# It exercises create-dmg against the locally-built (signed but
# unstapled) .app and skips both `notarize` and the post-DMG
# codesign/notarytool/stapler steps. The output DMG mounts and
# displays correctly on the dev machine but is NOT Gatekeeper-
# clean — non-developer Macs would refuse to open it. Useful for
# tweaking icon positions, window size, or eventually a custom
# background PNG without paying the 5-minute notary round-trip
# every time.
dmg-preview: build
	@command -v create-dmg >/dev/null 2>&1 || { \
		echo ""; \
		echo "create-dmg not found. Install with:"; \
		echo "  brew install create-dmg"; \
		exit 1; \
	}
	@rm -f $(APP_DIR)/build/Parleq-preview.dmg
	create-dmg \
		--volname "Parleq (preview)" \
		--volicon "$(APP_DIR)/Resources/AppIcon.icns" \
		--window-pos 200 120 \
		--window-size 640 400 \
		--icon-size 100 \
		--icon "Parleq.app" 160 200 \
		--hide-extension "Parleq.app" \
		--app-drop-link 480 200 \
		"$(APP_DIR)/build/Parleq-preview.dmg" \
		"$(APP_BUNDLE)"
	@echo ""
	@echo "Preview DMG ready (unsigned, not notarized — dev-machine only):"
	@echo "  $(APP_DIR)/build/Parleq-preview.dmg"
	@echo ""
	@echo "Mount and inspect the layout:"
	@echo "  open $(APP_DIR)/build/Parleq-preview.dmg"

# `make dmg` wraps the stapled .app in a drag-to-Applications DMG,
# signs the DMG with the same Developer ID Application certificate
# that signed the .app, and runs notarytool a second time on the
# DMG envelope so Gatekeeper doesn't warn the tester when they
# mount it. The .app inside has already been notarized + stapled
# by the prior `notarize` target, so this round-trip is fast —
# Apple has seen the bytes and just OKs the new envelope.
#
# Requires `create-dmg` from Homebrew:
#   brew install create-dmg
#
# Layout: 640×400 window, Parleq.app on the left, /Applications
# symlink on the right, both at y=200 with 100px icons. No custom
# background image yet — default white. We can swap in a branded
# PNG later via --background.
#
# `--volicon` points create-dmg at the same AppIcon.icns the .app
# bundle ships, so the mounted volume's Finder icon (the one shown
# on the desktop) renders as the five-bar Parleq mark instead of
# the generic disk-image glyph. Reusing AppIcon.icns is the
# conventional shape for single-app DMGs and keeps us from
# maintaining a second .icns asset.
dmg: notarize
	@command -v create-dmg >/dev/null 2>&1 || { \
		echo ""; \
		echo "create-dmg not found. Install with:"; \
		echo "  brew install create-dmg"; \
		exit 1; \
	}
	@rm -f $(APP_DIR)/build/Parleq.dmg
	create-dmg \
		--volname "Parleq" \
		--volicon "$(APP_DIR)/Resources/AppIcon.icns" \
		--window-pos 200 120 \
		--window-size 640 400 \
		--icon-size 100 \
		--icon "Parleq.app" 160 200 \
		--hide-extension "Parleq.app" \
		--app-drop-link 480 200 \
		"$(APP_DIR)/build/Parleq.dmg" \
		"$(APP_BUNDLE)"
	@# Sign the DMG envelope. Use the same identity-resolution rules
	@# as scripts/make-app.sh so behavior is consistent: explicit
	@# CODESIGN_IDENTITY wins; otherwise prefer the first
	@# "Developer ID Application:" cert from the keychain.
	@IDENTITY="$(CODESIGN_IDENTITY)"; \
	if [ -z "$$IDENTITY" ]; then \
		IDENTITY=$$(security find-identity -v -p codesigning 2>/dev/null \
			| awk '/Developer ID Application:/{print $$2; exit}'); \
	fi; \
	if [ -z "$$IDENTITY" ] || [ "$$IDENTITY" = "-" ]; then \
		echo ""; \
		echo "No Developer ID Application certificate found in keychain."; \
		echo "Install one before running this target — the DMG must be"; \
		echo "Developer-ID-signed for notarytool to accept it."; \
		exit 1; \
	fi; \
	echo "==> codesign --sign $$IDENTITY (DMG)"; \
	codesign --sign "$$IDENTITY" --timestamp "$(APP_DIR)/build/Parleq.dmg"
	xcrun notarytool submit "$(APP_DIR)/build/Parleq.dmg" \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	xcrun stapler staple "$(APP_DIR)/build/Parleq.dmg"
	@echo ""
	@echo "Notarized DMG ready: $(APP_DIR)/build/Parleq.dmg"
	@echo "Verify the envelope:"
	@echo "  spctl -a -t open --context context:primary-signature -v $(APP_DIR)/build/Parleq.dmg"
	@echo "  (should print: accepted source=Notarized Developer ID)"

# `make release` is the one-shot for cutting a tester-ready build.
# It runs the full DMG flow above, then names the artifact with the
# project version + git SHA, computes a SHA-256 for verification,
# and writes a RELEASE_NOTES.txt stub the operator can fill in
# before uploading to GitHub Releases.
#
# The output lives in $(APP_DIR)/build/release/ — a single directory
# you can `gh release create vYYYY.MM.DD <files>` against. We don't
# Atomic release: build the DMG, create the GitHub release with the
# DMG + SHA256 attached, and dispatch the website-redeploy workflow.
# Single command, single round-trip.
#
# The flow is split into two recipes:
#
#   release-precheck — Four guard conditions, runs FIRST (no prereqs)
#     so a bad release notes file or unpushed branch fails before the
#     ~20-second DMG build instead of after.
#   release         — Depends on release-precheck + dmg. Composes the
#     release-output RELEASE_NOTES.txt, runs gh release create with
#     assets attached, dispatches the site-redeploy workflow.
#
# Pre-checks (all fail fast with an instructive message):
#   1. RELEASE_NOTES.txt at the repo root exists and its first line
#      starts with "Parleq $VERSION" (anchored — "Parleq 0.8.1" alone
#      does not satisfy a 0.8.10 release) so the release notes can't
#      drift out of sync with the version being shipped.
#   2. Sparkle's `sign_update` tool exists at $(SPARKLE_SIGN_UPDATE).
#      Without it the release recipe couldn't emit an EdDSA-signed
#      appcast entry; better to bail before paying the DMG build cost.
#   3. $(APPCAST) exists and contains the PARLEQ_APPCAST_INSERT
#      sentinel marker. The release recipe inserts new <item> blocks
#      immediately above that marker, so removing it would leave the
#      flow with nowhere deterministic to inject the entry.
#   4. Current branch has an upstream and its local HEAD is an
#      ancestor of (or equal to) origin/<branch>. gh release create's
#      --target uses the local SHA, which must exist server-side;
#      failing here is much friendlier than getting a 404 from gh
#      halfway through.
#   5. Working tree is clean. A surprise dirty file in the release
#      build is almost always a mistake; bail rather than ship it.
#
# After pre-checks succeed:
#   - Build DMG (dmg prereq).
#   - Compose the release-output RELEASE_NOTES.txt by replacing the
#     repo-root file's first line with `Parleq $VERSION ($SHA) — $DATE`
#     and keeping the rest verbatim. The augmented first line carries
#     the build-time provenance (sha + UTC date) that the source file
#     doesn't carry on its own.
#   - Run Sparkle's `sign_update` against the DMG to produce the
#     Ed25519 signature + byte-length the appcast <enclosure> needs.
#     The private key lives in the maintainer's Keychain; macOS may
#     pop a one-time access prompt on first invocation (click
#     "Always Allow" to skip it on subsequent runs).
#   - Insert a new <item> at the top of $(APPCAST), commit + push to
#     main, and refresh FULL_SHA. The release tag then points at the
#     just-pushed commit containing the matching appcast entry — so
#     installed Parleq builds checking the appcast will always find
#     the .dmg the appcast describes.
#   - Run `gh release create` directly with the DMG + .sha256 attached
#     and --target=$SHA so the release tag points at the exact local
#     commit (handy when you cut a release pre-merge from a branch).
#   - Dispatch deploy-pages.yml from main so the website rebuilds and
#     picks up both the new release listing and the freshly-prepended
#     appcast entry. Bypasses the github-pages environment protection
#     rule that rejects release-event-triggered runs from tag refs.
#
# Both recipes run under `set -e` so any single failing command
# aborts the chain and propagates a non-zero exit to make. This
# matters most in `release` — without set -e, a failed
# `gh release create` would silently fall through to the workflow
# dispatch and make would report success on a release that didn't
# actually ship.
#
# `gh` must be authenticated (run `gh auth login` once on a new
# machine). `gh release create` requires `repo` scope, which the
# default gh login provides.
release-precheck:
	@set -e; \
	VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(SOURCE_INFO_PLIST)" 2>/dev/null || echo "0.0.0"); \
	if [ ! -f "$(RELEASE_NOTES)" ]; then \
		echo "ERROR: $(RELEASE_NOTES) not found at repo root."; \
		echo "       Create it (first line: 'Parleq $$VERSION ...') before running make release."; \
		exit 1; \
	fi; \
	NOTES_FIRST=$$(head -n 1 "$(RELEASE_NOTES)"); \
	if ! echo "$$NOTES_FIRST" | grep -qE "^Parleq $$VERSION([^0-9]|$$)"; then \
		echo "ERROR: $(RELEASE_NOTES) first line doesn't start with 'Parleq $$VERSION'."; \
		echo "       Got: $$NOTES_FIRST"; \
		echo "       Update $(RELEASE_NOTES) for the new version before running make release."; \
		exit 1; \
	fi; \
	if [ ! -x "$(SPARKLE_SIGN_UPDATE)" ]; then \
		echo "ERROR: Sparkle's sign_update tool not found at $(SPARKLE_SIGN_UPDATE)."; \
		echo "       Download the Sparkle release tarball from"; \
		echo "       https://github.com/sparkle-project/Sparkle/releases, extract to"; \
		echo "       ~/Tools/sparkle/, and strip the quarantine xattr:"; \
		echo "         xattr -dr com.apple.quarantine ~/Tools/sparkle/"; \
		echo "       Override SPARKLE_SIGN_UPDATE if you've extracted it elsewhere."; \
		exit 1; \
	fi; \
	if [ ! -f "$(APPCAST)" ]; then \
		echo "ERROR: $(APPCAST) not found. The release flow needs the appcast skeleton"; \
		echo "       to exist before it can insert a new <item>."; \
		exit 1; \
	fi; \
	if ! grep -q "PARLEQ_APPCAST_INSERT" "$(APPCAST)"; then \
		echo "ERROR: $(APPCAST) is missing the PARLEQ_APPCAST_INSERT sentinel marker."; \
		echo "       The release recipe inserts new <item> blocks above that marker;"; \
		echo "       without it, the recipe doesn't know where to put the entry."; \
		exit 1; \
	fi; \
	UPSTREAM=$$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true); \
	if [ -z "$$UPSTREAM" ]; then \
		echo "ERROR: current branch has no upstream — can't verify it's pushed."; \
		echo "       Push your branch (git push -u origin <branch>) before running make release."; \
		exit 1; \
	fi; \
	if ! git merge-base --is-ancestor HEAD "$$UPSTREAM"; then \
		echo "ERROR: local HEAD is ahead of $$UPSTREAM."; \
		echo "       Push your latest commits before running make release."; \
		exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "ERROR: working tree is dirty. Commit, stash, or revert before running make release."; \
		git status --short; \
		exit 1; \
	fi; \
	echo "release-precheck OK (version $$VERSION, upstream $$UPSTREAM)"

release: release-precheck dmg
	@set -e; \
	VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(SOURCE_INFO_PLIST)" 2>/dev/null || echo "0.0.0"); \
	BUILD=$$(git rev-list --count HEAD); \
	SHA=$$(git rev-parse --short HEAD); \
	OUT="$(APP_DIR)/build/release"; \
	NAME="Parleq-$$VERSION-$$SHA.dmg"; \
	DMG_URL="https://github.com/parleq/parleq-speech/releases/download/v$$VERSION/$$NAME"; \
	RELEASE_NOTES_URL="https://github.com/parleq/parleq-speech/releases/tag/v$$VERSION"; \
	mkdir -p "$$OUT"; \
	rm -f "$$OUT"/Parleq-*.dmg "$$OUT"/Parleq-*.dmg.sha256 "$$OUT"/RELEASE_NOTES.txt; \
	cp "$(APP_DIR)/build/Parleq.dmg" "$$OUT/$$NAME"; \
	(cd "$$OUT" && shasum -a 256 "$$NAME" > "$$NAME.sha256"); \
	{ \
		echo "Parleq $$VERSION ($$SHA) — $$(date -u +%Y-%m-%d)"; \
		tail -n +2 "$(RELEASE_NOTES)"; \
	} > "$$OUT/RELEASE_NOTES.txt"; \
	echo ""; \
	echo "==> Signing DMG with Sparkle Ed25519 key ($(SPARKLE_SIGN_UPDATE))..."; \
	SIGN_OUTPUT=$$("$(SPARKLE_SIGN_UPDATE)" "$$OUT/$$NAME"); \
	echo "    $$SIGN_OUTPUT"; \
	ED_SIGNATURE=$$(echo "$$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'); \
	DMG_LENGTH=$$(echo "$$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p'); \
	if [ -z "$$ED_SIGNATURE" ] || [ -z "$$DMG_LENGTH" ]; then \
		echo "ERROR: failed to parse sign_update output; got: $$SIGN_OUTPUT"; \
		exit 1; \
	fi; \
	echo ""; \
	echo "==> Prepending v$$VERSION <item> to $(APPCAST)..."; \
	PUBDATE=$$(date -u +"%a, %d %b %Y %H:%M:%S +0000"); \
	APPCAST_ITEM="        <item>\n            <title>Version $$VERSION</title>\n            <pubDate>$$PUBDATE</pubDate>\n            <sparkle:version>$$BUILD</sparkle:version>\n            <sparkle:shortVersionString>$$VERSION</sparkle:shortVersionString>\n            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n            <sparkle:releaseNotesLink>$$RELEASE_NOTES_URL</sparkle:releaseNotesLink>\n            <enclosure\n                url=\"$$DMG_URL\"\n                sparkle:edSignature=\"$$ED_SIGNATURE\"\n                length=\"$$DMG_LENGTH\"\n                type=\"application/octet-stream\" />\n        </item>"; \
	awk -v item="$$APPCAST_ITEM" '/PARLEQ_APPCAST_INSERT/ { gsub(/\\n/, "\n", item); print item } { print }' "$(APPCAST)" > "$(APPCAST).tmp" && mv "$(APPCAST).tmp" "$(APPCAST)"; \
	echo ""; \
	echo "==> Committing + pushing appcast update to main..."; \
	git add "$(APPCAST)"; \
	git commit -m "release: appcast entry for v$$VERSION"; \
	git push; \
	FULL_SHA=$$(git rev-parse HEAD); \
	SHA=$$(git rev-parse --short HEAD); \
	echo ""; \
	echo "Release artifacts ready in $$OUT/:"; \
	ls -lh "$$OUT/$$NAME" "$$OUT/$$NAME.sha256" "$$OUT/RELEASE_NOTES.txt" | awk '{print "  " $$NF " (" $$5 ")"}'; \
	echo ""; \
	echo "==> Creating GitHub release v$$VERSION (target $$SHA)..."; \
	gh release create "v$$VERSION" \
		--target "$$FULL_SHA" \
		--title "Parleq $$VERSION" \
		--notes-file "$$OUT/RELEASE_NOTES.txt" \
		"$$OUT/$$NAME" "$$OUT/$$NAME.sha256"; \
	echo ""; \
	echo "==> Dispatching website redeploy (workflow_dispatch on main)..."; \
	gh workflow run deploy-pages.yml --ref main; \
	echo ""; \
	echo "Done."; \
	echo "  Release:  https://github.com/parleq/parleq-speech/releases/tag/v$$VERSION"; \
	echo "  Appcast:  https://parleq.app/appcast.xml (live after deploy-pages runs)"; \
	echo "  Workflow: https://github.com/parleq/parleq-speech/actions/workflows/deploy-pages.yml"

# Show the current marketing version + projected build number.
# Build number comes from `git rev-list --count HEAD` exactly the
# way scripts/make-app.sh stamps it during `make build`, so this
# matches what the next built artifact will carry.
show-version:
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(APP_DIR)/Resources/Info.plist"); \
	BUILD=$$(git rev-list --count HEAD 2>/dev/null || echo "?"); \
	echo "Marketing version: $$VERSION"; \
	echo "Build number:      $$BUILD (auto-stamped at build time)"

# Set the marketing version (CFBundleShortVersionString) in the
# source Info.plist. Build number stays auto-stamped from git.
#
# Usage:
#   make set-version VERSION=0.5.0
#
# Validates the format as MAJOR.MINOR.PATCH (digits only). Uses a
# surgical sed edit instead of PlistBuddy because PlistBuddy
# rewrites the plist in canonical form and strips the XML comments
# that document LSUIElement, the termination opt-outs, etc. Leaves
# the modified Info.plist staged in your worktree — review and
# commit deliberately rather than auto-committing, since version
# bumps usually want a hand-written commit message ("Release 0.5.0:
# notarized DMG, custom dictionary aliases, …").
set-version:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make set-version VERSION=x.y.z"; \
		exit 1; \
	fi
	@echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || { \
		echo "VERSION must be MAJOR.MINOR.PATCH (digits only). Got: $(VERSION)"; \
		exit 1; \
	}
	@OLD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(APP_DIR)/Resources/Info.plist"); \
	sed -i '' -E '/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>$(VERSION)</string>|;}' \
		"$(APP_DIR)/Resources/Info.plist"; \
	NEW=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(APP_DIR)/Resources/Info.plist"); \
	if [ "$$NEW" != "$(VERSION)" ]; then \
		echo "ERROR: edit didn't take. Info.plist still reads $$NEW."; \
		exit 1; \
	fi; \
	echo "CFBundleShortVersionString: $$OLD → $(VERSION)"; \
	echo ""; \
	echo "Review and commit:"; \
	echo "  git diff $(APP_DIR)/Resources/Info.plist"; \
	echo "  git add $(APP_DIR)/Resources/Info.plist"; \
	echo "  git commit -m \"chore: bump version to $(VERSION)\""
