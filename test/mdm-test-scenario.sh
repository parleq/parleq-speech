#!/usr/bin/env bash
# ============================================================================
# LOCAL DEVELOPER TESTING TOOL — NOT SHIPPED TO END USERS
# ============================================================================
#
# Orchestrator for the named MDM test scenarios covering issue #39 (Managed
# Configuration). This script is never run by the Parleq app, never invoked
# from `swift build` / `swift test` / CI, and not part of any release
# artifact. It lives in `test/` purely as a developer aid for manual
# end-to-end testing of the MDM read overlay.
#
# DESIGN: PRIVILEGE MINIMIZATION
#
# This orchestrator itself runs UNPRIVILEGED. The only privileged step
# (writing to /Library/Managed Preferences/, which requires root) is
# delegated to the companion script `mdm-managed-prefs.sh`, which is the
# only piece that needs passwordless sudo. See that script's header for
# its security design.
#
# Everything this orchestrator does directly:
#   - Killing user-owned Parleq processes (pkill on `Parleq.app` — no sudo)
#   - Launching the worktree-built Parleq.app (open — no sudo)
#   - Reading the user's own ~/.parleq/app.log
#   - Extracting a sample mobileconfig fragment via PlistBuddy
#
# None of those operations require elevated privileges.
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

    test18-no-static-keys)
        # Phase 4: push staticApiKeysAllowed=false (master switch).
        # Verify:
        #   1. Gemini card: "API key entry disabled by your organization." + lock icon.
        #   2. OpenAI card: same.
        #   3. Bedrock bearer card: same.
        #   4. Azure card (apiKey mode): API key row hidden.
        #   5. Bedrock IAM card (sso mode is default): no change to sso controls;
        #      if user switches to static/bedrockApiKey in picker, the entry row is hidden.
        #   6. Vertex card: "Service account JSON entry disabled"; ADC mode remains.
        #   7. Compliance Audit: staticApiKeysAllowed=false, source=Managed.
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        ;;

    test19-azure-pinned-to-azuread)
        # Phase 4: push azureAuthMode=azureAd.
        # Verify:
        #   1. Azure credentials card shows pinned "Microsoft Entra ID" fixed label.
        #   2. Auth-mode picker replaced by disabled label + lock icon.
        #   3. "Set API key…" button hidden (azureAd doesn't use one).
        #   4. az login caption visible.
        #   5. Compliance Audit: azureAuthMode=azureAd, source=Managed.
        write_scenario '    <key>azureAuthMode</key>
    <string>azureAd</string>'
        restart_parleq
        ;;

    test20-bedrock-pinned-to-sso)
        # Phase 4: push bedrockAuthMode=sso (the default, but now managed/locked).
        # Verify:
        #   1. Bedrock IAM card shows pinned "AWS CLI session (SSO)" fixed label + lock.
        #   2. Auth-mode picker replaced by disabled label.
        #   3. Static-credentials row and Bedrock API key row hidden.
        #   4. AWS profile text field visible (still used in sso mode).
        #   5. Compliance Audit: bedrockAuthMode=sso, source=Managed.
        write_scenario '    <key>bedrockAuthMode</key>
    <string>sso</string>'
        restart_parleq
        ;;

    test21-auth-mode-combined)
        # Phase 4: all three auth-mode restriction keys in one push.
        # Verify cumulative lockdown:
        #   - staticApiKeysAllowed=false: API key entry hidden everywhere.
        #   - azureAuthMode=azureAd: Azure card pinned to Entra ID.
        #   - bedrockAuthMode=sso: Bedrock IAM pinned to SSO.
        #   Compliance Audit shows all three keys as Managed.
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>
    <key>azureAuthMode</key>
    <string>azureAd</string>
    <key>bedrockAuthMode</key>
    <string>sso</string>'
        restart_parleq
        ;;

    test22-runtime-rejection-gemini)
        # Phase 5: push staticApiKeysAllowed=false and verify RUNTIME rejection.
        # Verify:
        #   1. Startup log shows "BLOCKED by staticApiKeysAllowed=false" for the
        #      Gemini provider (when cleanup is configured to use Gemini).
        #   2. Gemini card shows "Auth disabled by org" badge in header.
        #   3. Provider picker shows "(disabled by your organization)" next to Gemini.
        #   4. Dictating with Gemini as the cleanup provider surfaces the
        #      "auth path disabled" message in the overlay rather than the raw
        #      transcript appearing without any failure indication.
        #   5. Compliance Audit: staticApiKeysAllowed=false, source=Managed.
        #   (contrast with test18 which only verifies UI — this verifies runtime)
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        echo "--- verifying runtime block in startup log ---"
        sleep 1
        if [ -f ~/.parleq/app.log ]; then
            tail -30 ~/.parleq/app.log \
                | grep -E "BLOCKED by staticApiKeysAllowed|authPathBlocked" \
                || echo "(no block log line found — may need to dictate once to trigger the cleanup path)"
        fi
        ;;

    test23-runtime-rejection-azure-apikey)
        # Phase 5: push staticApiKeysAllowed=false with Azure in apiKey mode.
        # Verify:
        #   1. Azure card shows "Auth disabled by org" badge (apiKey mode blocked).
        #   2. The auth-mode picker REMAINS visible — user can switch to azureAd.
        #   3. After switching to azureAd in Settings, the badge disappears and
        #      Azure is available again (adc federated path is unblocked).
        #   4. A dictation attempt with Azure/apiKey surfaces the auth-path-blocked
        #      overlay message, not a raw API-key-missing error.
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        echo "Manual verification:"
        echo "  1. Open Settings → LLM → Azure OpenAI credentials card"
        echo "  2. Confirm 'Auth disabled by org' badge appears (apiKey mode)"
        echo "  3. Confirm auth-mode picker (apiKey / azureAd) is still visible"
        echo "  4. Switch to azureAd — badge should disappear"
        ;;

    test24-vertex-adc-still-works)
        # Phase 5: push staticApiKeysAllowed=false with Vertex in adc mode.
        # Verify that ADC (Application Default Credentials) is NOT blocked —
        # it is a federated auth path and must remain available even when
        # the master switch is off.
        # Verify:
        #   1. Vertex card does NOT show "Auth disabled by org" badge (adc mode).
        #   2. No "BLOCKED" log line for vertex in startup log.
        #   3. Provider picker does NOT show "(disabled by your organization)"
        #      next to Vertex.
        #   4. Dictation with Vertex/adc selected proceeds normally (assuming
        #      gcloud credentials are available).
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        echo "--- verifying Vertex ADC is NOT blocked ---"
        sleep 1
        if [ -f ~/.parleq/app.log ]; then
            tail -30 ~/.parleq/app.log \
                | grep -E "BLOCKED.*vertex|vertex.*BLOCKED" \
                && echo "FAIL: vertex appears in BLOCKED log line" \
                || echo "PASS: no vertex BLOCK log line (ADC path is unblocked)"
        fi
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
        echo "  test18-no-static-keys          Phase 4: staticApiKeysAllowed=false (master switch)"
        echo "  test19-azure-pinned-to-azuread Phase 4: azureAuthMode=azureAd"
        echo "  test20-bedrock-pinned-to-sso   Phase 4: bedrockAuthMode=sso"
        echo "  test21-auth-mode-combined      Phase 4: all three auth-mode keys combined"
        echo "  test22-runtime-rejection-gemini  Phase 5: Gemini blocked at runtime (no network call)"
        echo "  test23-runtime-rejection-azure-apikey  Phase 5: Azure apiKey blocked; azureAd remains"
        echo "  test24-vertex-adc-still-works  Phase 5: Vertex ADC unblocked under master switch off"
        exit 1
        ;;

    *)
        echo "Unknown scenario: $scenario" >&2
        echo "Run without args to see the list." >&2
        exit 1
        ;;
esac
