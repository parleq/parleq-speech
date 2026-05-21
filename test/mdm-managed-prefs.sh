#!/usr/bin/env bash
# mdm-managed-prefs.sh — the ONLY script that needs root.
#
# Hardcodes its target to /Library/Managed Preferences/com.parleq.app.plist
# so that passwordless sudo on this script grants the minimum surface area
# (write/clear that single file + invalidate cfprefsd). Anyone — script,
# attacker, or bug — invoking this with sudo can only touch that one file.
# It cannot be coerced into writing anywhere else, executing other
# binaries, or stealing broader privilege.
#
# Sudoers entry (one line; replace <USER> with your username and
# <ABSOLUTE-PATH-TO-SCRIPT> with the absolute path of this file in
# your checkout — the script lives at <repo-root>/test/mdm-managed-prefs.sh):
#   <USER> ALL=(ALL) NOPASSWD: <ABSOLUTE-PATH-TO-SCRIPT>
#
# Usage:
#   sudo mdm-managed-prefs.sh clear
#       Remove the managed plist, invalidate cfprefsd. No stdin needed.
#
#   sudo mdm-managed-prefs.sh write < body.xml
#       Read XML dict body from stdin, wrap in a plist envelope, write
#       to /Library/Managed Preferences/com.parleq.app.plist, then
#       invalidate cfprefsd. The body should be only the <dict>...</dict>
#       inner content — the envelope is added here so callers can't inject
#       extra elements (PayloadType, extra root-level keys, etc.).

set -euo pipefail

readonly MANAGED_DIR="/Library/Managed Preferences"
readonly MANAGED_PLIST="${MANAGED_DIR}/com.parleq.app.plist"

subcommand="${1:-}"
case "$subcommand" in
    clear)
        rm -f "$MANAGED_PLIST"
        killall cfprefsd 2>/dev/null || true
        echo "managed-prefs: cleared"
        ;;

    write)
        # Read body from stdin into a variable so we can wrap it.
        body="$(cat)"
        if [ -z "$body" ]; then
            echo "ERROR: write subcommand requires <dict>...</dict> body on stdin" >&2
            exit 1
        fi
        mkdir -p "$MANAGED_DIR"
        # Envelope is hardcoded here — caller controls only the inner
        # dict body, not the structure.
        cat > "$MANAGED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
</dict>
</plist>
EOF
        # Validate the resulting file is valid XML / plist. plutil's exit
        # code is non-zero on malformed plists; the `set -e` above means
        # we fail loudly rather than leaving a bad file in place.
        if ! plutil -lint "$MANAGED_PLIST" >/dev/null; then
            echo "ERROR: wrote malformed plist; aborting" >&2
            rm -f "$MANAGED_PLIST"
            exit 1
        fi
        killall cfprefsd 2>/dev/null || true
        echo "managed-prefs: wrote $MANAGED_PLIST and invalidated cfprefsd"
        ;;

    *)
        echo "Usage: $0 {clear|write}" >&2
        exit 1
        ;;
esac
