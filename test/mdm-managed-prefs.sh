#!/usr/bin/env bash
# ============================================================================
# LOCAL DEVELOPER TESTING TOOL — NOT SHIPPED TO END USERS
# ============================================================================
#
# This script exists to let a Parleq developer manually exercise the MDM
# (Managed Configuration, issue #39) read overlay without enrolling their
# Mac in a real MDM service like Jamf / Kandji / Mosyle. It is never run
# by the Parleq app itself, never run during `swift build` or `swift test`,
# never invoked from CI, and is not part of any release artifact. It lives
# in `test/` purely as a development aid documented in the testing protocol
# for issue #39.
#
# WHY IT NEEDS ROOT
#
# macOS MDM policies are read from `/Library/Managed Preferences/`, which
# is owned by `root:wheel` and only writable by privileged processes. A
# real MDM agent (mdmclient) writes there as part of profile installation.
# To test our app-side read overlay (`ManagedConfig.swift`) without
# installing real profiles, this script writes the same target plist
# directly.
#
# SECURITY DESIGN
#
# The script is the ONLY place that touches `/Library/Managed Preferences/`
# and:
#   - Hardcodes its target to `/Library/Managed Preferences/com.parleq.app.plist`
#     (`readonly MANAGED_PLIST`). Cannot be coerced into writing elsewhere.
#   - Hardcodes the plist envelope. Callers only supply the inner <dict>
#     body via stdin; the script wraps it. Cannot inject extra payloads.
#   - Validates the resulting file with `plutil -lint` before leaving it
#     in place. Malformed output is deleted; the user sees a loud error.
#   - Only two subcommands: `clear` and `write`. No shell metacharacter
#     handling, no eval, no exec of arbitrary commands.
#   - `set -euo pipefail`. Failures abort loudly.
#
# So passwordless sudo on THIS script grants the ability to manage exactly
# one specific plist file. Compromise of the script's contents (e.g. an
# attacker rewriting the worktree-local copy) is the main residual risk;
# see the "Paranoid setups" section below for the root-owned deployment
# pattern that mitigates that.
#
# Sudoers entry — TWO PATTERNS depending on your threat model:
#
# Solo-dev iteration (acceptable for personal machines):
#   <USER> ALL=(ALL) NOPASSWD: <ABSOLUTE-PATH-TO-THIS-SCRIPT>
#   Replace <USER> with your username and <ABSOLUTE-PATH-TO-THIS-SCRIPT>
#   with the worktree path, e.g.:
#   .../parleq-worktrees/issue-39-managed-config-phase-N/test/mdm-managed-prefs.sh
#
# Caveat: the worktree path is USER-WRITABLE. A compromised process
# running as your user could rewrite this script and gain a
# passwordless root execution path. The script's internal safeguards
# (hardcoded target path, plutil validation) only matter if the
# script contents stay trusted.
#
# Paranoid / shared-machine / multi-user setups (recommended):
#   1. Install a root-owned copy outside the worktree:
#        sudo install -o root -g wheel -m 0755 \
#            /path/to/this/script \
#            /usr/local/sbin/parleq-mdm-managed-prefs
#   2. Sudoers entry points at the root-owned copy:
#        <USER> ALL=(ALL) NOPASSWD: /usr/local/sbin/parleq-mdm-managed-prefs
#   3. Re-install whenever this script changes upstream.
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
