#!/usr/bin/env bash
# mdm-test-scenario.sh — orchestrate Phase 2 MDM test scenarios.
#
# Runs unprivileged. Calls mdm-managed-prefs.sh via sudo for the ONLY
# step that genuinely needs root (writing /Library/Managed Preferences/).
# Everything else (killing user-owned Parleq processes, launching the
# worktree-built Parleq.app, reading log lines) runs as the user.
#
# Usage:
#   ./mdm-test-scenario.sh                       # list available scenarios
#   ./mdm-test-scenario.sh clear                 # remove managed config + relaunch
#   ./mdm-test-scenario.sh <scenario-name>       # set up + relaunch

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKTREE="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly INNER_SCRIPT="$SCRIPT_DIR/mdm-managed-prefs.sh"
readonly PARLEQ_APP="$WORKTREE/parleq-app/build/Parleq.app"

write_scenario() {
    # $1 = scenario body (inner dict content)
    printf '%s\n' "$1" | sudo "$INNER_SCRIPT" write
}

clear_scenario() {
    sudo "$INNER_SCRIPT" clear
}

restart_parleq() {
    # Kill the user's own Parleq instance — no sudo needed; the process
    # is owned by the current user.
    pkill -f "Parleq.app/Contents/MacOS/" 2>/dev/null || true
    sleep 0.5
    if [ ! -d "$PARLEQ_APP" ]; then
        echo "ERROR: $PARLEQ_APP not found. Build it first:" >&2
        echo "    cd $WORKTREE/parleq-app && ./scripts/make-app.sh" >&2
        exit 1
    fi
    open "$PARLEQ_APP"
    echo "Parleq launched from $PARLEQ_APP"
    # Give it a moment to write the startup log line.
    sleep 1.5
    if [ -f ~/.parleq/app.log ]; then
        echo "--- recent managed-config log lines ---"
        tail -30 ~/.parleq/app.log \
            | grep -E "managed config|cleanupAllowed|contextAllowed|cleanupProvider|cleanupModel|customModelEntry|customModel|provider pin|allowlist" \
            | tail -8 \
            || echo "(no managed-config log lines in last 30 — check tail -50 ~/.parleq/app.log)"
        echo "--------------------------------------"
    fi
}

scenario="${1:-}"

case "$scenario" in
    clear)
        clear_scenario
        restart_parleq
        ;;

    test1-lock-icon)
        write_scenario '    <key>referenceWindowsEnabled</key>
    <false/>'
        restart_parleq
        ;;

    test2-provider-pin)
        write_scenario '    <key>cleanupProvider</key>
    <string>azure</string>'
        restart_parleq
        ;;

    test3-provider-allowlist)
        write_scenario '    <key>cleanupAllowedProviders</key>
    <array>
        <string>azure</string>
        <string>openai</string>
    </array>'
        restart_parleq
        ;;

    test4-model-pin)
        write_scenario '    <key>cleanupProvider</key>
    <string>openai</string>
    <key>cleanupModel</key>
    <string>gpt-4o-mini</string>'
        restart_parleq
        ;;

    test5-model-allowlist)
        write_scenario '    <key>cleanupProvider</key>
    <string>openai</string>
    <key>cleanupAllowedModels</key>
    <array>
        <string>gpt-4o</string>
        <string>gpt-4o-mini</string>
    </array>'
        restart_parleq
        ;;

    test6-cross-provider-snap)
        # Use a Gemini-only model so the auto-snap path actually fires.
        # gpt-4o would NOT trigger it because Azure hosts gpt-4o too.
        write_scenario '    <key>cleanupAllowedModels</key>
    <array>
        <string>gemini-2.5-flash</string>
    </array>'
        restart_parleq
        ;;

    test7-auto-update)
        write_scenario '    <key>autoUpdateEnabled</key>
    <false/>'
        restart_parleq
        ;;

    test8-audit-mixed)
        write_scenario '    <key>cleanupAllowedProviders</key>
    <array>
        <string>azure</string>
        <string>openai</string>
    </array>
    <key>imageReferenceEnabled</key>
    <false/>'
        restart_parleq
        ;;

    test9-save-preservation)
        write_scenario '    <key>cleanupProvider</key>
    <string>azure</string>'
        restart_parleq
        ;;

    test12-cleanup-provider-only)
        # Provider allowlist active, model unmanaged. Exercises the
        # asymmetric case where only the Provider column has a managed
        # caption; the Model column should still baseline-align.
        write_scenario '    <key>cleanupAllowedProviders</key>
    <array>
        <string>gemini</string>
        <string>vertex</string>
    </array>'
        restart_parleq
        ;;

    test13-cleanup-model-only)
        # Model allowlist active, provider unmanaged. Exercises the
        # mirror case where only the Model column has a managed caption.
        # Note: the #176 fix means the Provider picker will be silently
        # filtered to providers that own at least one allowed model
        # (gemini-2.5-flash + gemini-2.5-pro are gemini/vertex only) —
        # but with no provider-level managed key, no lock/caption
        # appears on the provider column.
        write_scenario '    <key>cleanupAllowedModels</key>
    <array>
        <string>gemini-2.5-flash</string>
        <string>gemini-2.5-pro</string>
    </array>'
        restart_parleq
        ;;

    test14-context-managed)
        # Manage the CONTEXT tier (which we have not yet tested):
        # context provider pinned to vertex, context model pinned to a
        # Claude Sonnet model on Vertex. Cleanup tier left fully
        # user-controlled.
        write_scenario '    <key>contextProvider</key>
    <string>vertex</string>
    <key>contextModel</key>
    <string>claude-sonnet-4-5@20250929</string>'
        restart_parleq
        ;;

    test11-followups-combined)
        # Exercises all three Phase 2 UI followups in one configuration:
        #   #174 (caption visibility on toggle rows): imageReferenceEnabled
        #        is forced false → Privacy & Features pane should show
        #        an always-visible "Managed by your organization." caption
        #        beneath that toggle, not just on hover.
        #   #175 (Cleanup tier baseline alignment): cleanupAllowedProviders
        #        gives the Provider picker a managed caption while the
        #        Model picker (no managed key) doesn't — the dropdowns
        #        should stay top-aligned with consistent label position.
        #   #176 (provider picker hides incompatible providers):
        #        cleanupAllowedModels is set to a Gemini-only model, so
        #        the Provider picker should show only Gemini + Vertex
        #        (the two providers that own gemini-2.5-flash), NOT all
        #        six providers.
        write_scenario '    <key>cleanupAllowedProviders</key>
    <array>
        <string>gemini</string>
        <string>vertex</string>
        <string>azure</string>
    </array>
    <key>cleanupAllowedModels</key>
    <array>
        <string>gemini-2.5-flash</string>
    </array>
    <key>imageReferenceEnabled</key>
    <false/>'
        restart_parleq
        ;;

    test10-sample-mobileconfig)
        # Extract the inner mcx_preference_settings from the shipped
        # sample mobileconfig and pipe it through the inner script.
        # PlistBuddy reads the sample (user-owned file, no sudo) and
        # emits the inner dict in XML; the inner script writes it.
        body="$(/usr/libexec/PlistBuddy -x -c \
            'Print :PayloadContent:0:PayloadContent:com.parleq.app:Forced:0:mcx_preference_settings' \
            "$WORKTREE/config/parleq-managed-example.mobileconfig" 2>/dev/null \
            | sed -n '/<dict>/,/<\/dict>/p' \
            | sed '1d;$d')"
        if [ -z "$body" ]; then
            echo "ERROR: failed to extract mcx_preference_settings from sample mobileconfig" >&2
            exit 1
        fi
        write_scenario "$body"
        restart_parleq
        ;;

    test15-sparkle-feed-url)
        # Phase 3: push sparkleUpdateFeedURL.
        # Verify:
        #   1. Startup log shows: "[parleq] sparkleUpdateFeedURL: accepted managed URL ..."
        #   2. Settings -> Updates pane shows:
        #      "Update feed: https://example.com/appcast.xml (managed by your organization)"
        # Compliance Audit dialog should show sparkleUpdateFeedURL with
        # source=Managed and value=https://example.com/appcast.xml.
        write_scenario '    <key>sparkleUpdateFeedURL</key>
    <string>https://example.com/appcast.xml</string>'
        restart_parleq
        ;;

    test16-logging-mode)
        # Phase 3: push loggingMode=lengthOnly.
        # Verify:
        #   1. Startup log shows: "[parleq] managed config: 1 keys managed (loggingMode=lengthOnly)"
        #   2. Compliance Audit dialog shows loggingMode row with source=Managed.
        write_scenario '    <key>loggingMode</key>
    <string>lengthOnly</string>'
        restart_parleq
        ;;

    test17-tier3-combined)
        # Phase 3: both new keys + an invalid loggingMode value to confirm
        # rejection. Expected:
        #   - sparkleUpdateFeedURL accepted (valid https:// URL)
        #   - loggingMode rejected (unrecognized value "verboseUltra") with log warning
        #   - Compliance Audit: sparkleUpdateFeedURL=Managed, loggingMode=Default
        #   - Startup log: "[parleq] loggingMode: rejected unrecognized managed value 'verboseUltra'"
        write_scenario '    <key>sparkleUpdateFeedURL</key>
    <string>https://example.com/appcast.xml</string>
    <key>loggingMode</key>
    <string>verboseUltra</string>'
        restart_parleq
        ;;

    "")
        echo "Available scenarios:"
        echo "  clear                          remove managed config + relaunch"
        echo "  test1-lock-icon                referenceWindowsEnabled=false"
        echo "  test2-provider-pin             cleanupProvider=azure"
        echo "  test3-provider-allowlist       cleanupAllowedProviders=[azure,openai]"
        echo "  test4-model-pin                pin openai + gpt-4o-mini"
        echo "  test5-model-allowlist          openai + allowed [gpt-4o, gpt-4o-mini]"
        echo "  test6-cross-provider-snap      allowed=[gpt-4o] no provider pin"
        echo "  test7-auto-update              autoUpdateEnabled=false"
        echo "  test8-audit-mixed              allowlist + one toggle for audit dialog"
        echo "  test9-save-preservation        provider pin to different provider"
        echo "  test10-sample-mobileconfig     install the shipped sample"
        echo "  test11-followups-combined      exercises Phase 2 UI followups #174 + #175 + #176"
        echo "  test12-cleanup-provider-only   provider allowlist + unmanaged model (alignment)"
        echo "  test13-cleanup-model-only      model allowlist + unmanaged provider (alignment)"
        echo "  test14-context-managed         context tier pinned (provider + model)"
        echo "  test15-sparkle-feed-url        Phase 3: sparkleUpdateFeedURL=https://example.com/appcast.xml"
        echo "  test16-logging-mode            Phase 3: loggingMode=lengthOnly"
        echo "  test17-tier3-combined          Phase 3: both + invalid loggingMode to verify rejection"
        exit 1
        ;;

    *)
        echo "Unknown scenario: $scenario" >&2
        echo "Run without args to see the list." >&2
        exit 1
        ;;
esac
