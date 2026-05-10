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
# Note: the FluidAudio sidecar (Nemotron streaming ASR HTTP server) is
# still started manually. M5.2 will bundle it inside Parleq.app and
# supervise it as a child process.

APP_DIR           := parleq-app
APP_BUNDLE        := $(APP_DIR)/build/Parleq.app
INSTALL_DEST      := /Applications/Parleq.app
CODESIGN_IDENTITY :=
# Keychain profile name for `xcrun notarytool`. Created once via
# `xcrun notarytool store-credentials` (see `make help` output for
# the full command). Override to use a different profile.
NOTARY_PROFILE    := parleq-notarize

.DEFAULT_GOAL := help
.PHONY: help build build-debug install run clean notarize dmg dmg-preview release set-version show-version

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
	@echo "  release       dmg + named/hashed copy + RELEASE_NOTES.txt stub"
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
# call `gh release create` ourselves: tagging + release notes are
# human decisions and the artifact is the same either way.
release: dmg
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
		"$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || echo "0.0.0"); \
	SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo "nogit"); \
	OUT="$(APP_DIR)/build/release"; \
	NAME="Parleq-$$VERSION-$$SHA.dmg"; \
	mkdir -p "$$OUT"; \
	rm -f "$$OUT"/Parleq-*.dmg "$$OUT"/Parleq-*.dmg.sha256 "$$OUT"/RELEASE_NOTES.txt; \
	cp "$(APP_DIR)/build/Parleq.dmg" "$$OUT/$$NAME"; \
	(cd "$$OUT" && shasum -a 256 "$$NAME" > "$$NAME.sha256"); \
	{ \
		echo "Parleq $$VERSION ($$SHA) — $$(date -u +%Y-%m-%d)"; \
		echo ""; \
		echo "## What's new"; \
		echo "- TODO"; \
		echo ""; \
		echo "## Install"; \
		echo "1. Download $$NAME"; \
		echo "2. (Optional) Verify the SHA-256:"; \
		echo "   shasum -a 256 -c $$NAME.sha256"; \
		echo "3. Open the DMG and drag Parleq.app onto the Applications folder."; \
		echo "4. Eject the DMG, then launch Parleq from Applications."; \
		echo "5. On first launch, grant Microphone + Accessibility permissions."; \
		echo ""; \
		echo "First launch downloads the speech model (~150 MB) — give it"; \
		echo "30–60 seconds before pressing the hotkey. The menu-bar icon"; \
		echo "switches from a download glyph to a microphone when ready."; \
		echo ""; \
		echo "See README.md for hotkey, LLM provider setup (Gemini / Bedrock),"; \
		echo "and custom-dictionary configuration."; \
	} > "$$OUT/RELEASE_NOTES.txt"; \
	echo ""; \
	echo "Release artifacts ready in $$OUT/:"; \
	ls -lh "$$OUT/$$NAME" "$$OUT/$$NAME.sha256" "$$OUT/RELEASE_NOTES.txt" | awk '{print "  " $$NF " (" $$5 ")"}'; \
	echo ""; \
	echo "Edit RELEASE_NOTES.txt, then upload with:"; \
	echo "  gh release create v$$VERSION \\"; \
	echo "    --title \"Parleq $$VERSION\" \\"; \
	echo "    --notes-file $$OUT/RELEASE_NOTES.txt \\"; \
	echo "    $$OUT/$$NAME $$OUT/$$NAME.sha256"

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
