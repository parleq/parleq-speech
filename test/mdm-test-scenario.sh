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

    # ════════════════════════════════════════════════════════════════════════
    # Phase 7 — destination pins + Sparkle skip-version + Vertex card fix
    # ════════════════════════════════════════════════════════════════════════

    test25-asr-endpoint-bundled-pin)
        # Pin asrEndpoint to the bundled-FluidAudio sentinel.
        # Verify:
        #   1. Settings → Advanced → Speech-recognition endpoint TextField is
        #      disabled with the lock icon and "Managed by your organization"
        #      caption underneath.
        #   2. The "Reset to default" button is also disabled.
        #   3. Compliance Audit dialog shows asrEndpoint as "(bundled FluidAudio)"
        #      with the orange Managed badge.
        write_scenario '    <key>asrEndpoint</key>
    <string>http://127.0.0.1:8767/inference</string>'
        restart_parleq
        echo "--- check Settings → Advanced and the Compliance Audit dialog ---"
        ;;

    test26-asr-endpoint-https-pin)
        # Pin asrEndpoint to an https:// URL with a non-default port.
        # Verify:
        #   1. Same UI gating as test25 (TextField disabled, lock icon).
        #   2. Compliance Audit displays "https://asr.example.com:8443" — port
        #      preserved, path stripped (RoboRev fix).
        #   3. Startup log contains a confirmation line (since asrEndpoint is
        #      non-default the app logs the custom endpoint).
        write_scenario '    <key>asrEndpoint</key>
    <string>https://asr.example.com:8443/inference</string>'
        restart_parleq
        echo "--- verify port shows in audit dialog and path is stripped ---"
        if [ -f ~/.parleq/app.log ]; then
            tail -30 ~/.parleq/app.log \
                | grep -E "ASR:.*custom endpoint" \
                || echo "(no custom-endpoint log line — check tail -50 ~/.parleq/app.log)"
        fi
        ;;

    test27-asr-endpoint-rejects-http)
        # Push asrEndpoint=http://attacker.example/inference. The plain-HTTP
        # validation in ManagedConfig.validateASREndpoint must reject this.
        # Verify:
        #   1. Startup log contains a "[parleq] asrEndpoint: rejected managed value"
        #      line.
        #   2. Settings TextField is NOT disabled — the key is not added to
        #      managedKeys after rejection.
        #   3. Compliance Audit shows asrEndpoint with the User or Default
        #      badge (not Managed).
        write_scenario '    <key>asrEndpoint</key>
    <string>http://attacker.example/inference</string>'
        restart_parleq
        echo "--- verifying http:// asrEndpoint is rejected ---"
        if [ -f ~/.parleq/app.log ]; then
            tail -30 ~/.parleq/app.log \
                | grep -E "asrEndpoint: rejected" \
                && echo "PASS: rejection log line present" \
                || echo "FAIL: no rejection log line"
        fi
        ;;

    test28-asr-endpoint-rejects-userinfo)
        # Push asrEndpoint with embedded user:pass@host. Validator rejects.
        write_scenario '    <key>asrEndpoint</key>
    <string>https://user:pass@asr.example.com/inference</string>'
        restart_parleq
        if [ -f ~/.parleq/app.log ]; then
            tail -30 ~/.parleq/app.log \
                | grep -E "asrEndpoint: rejected" \
                && echo "PASS: rejection log line present (userinfo)" \
                || echo "FAIL: no rejection log line"
        fi
        ;;

    test29-vertex-destination-pins)
        # Pin all three Vertex destination fields. Settings → Vertex card
        # should show three disabled TextFields each with a lock icon.
        # Verify:
        #   1. Project / Region / Anthropic-region TextFields are all
        #      disabled with the lock icon.
        #   2. ManagedCaption "Managed by your organization." sits directly
        #      under each field (mirrors the Bedrock/Azure layout).
        #   3. Compliance Audit shows three new rows: vertexProject,
        #      vertexRegion, vertexAnthropicRegion — all Managed.
        write_scenario '    <key>vertexProject</key>
    <string>corp-vertex-prod</string>
    <key>vertexRegion</key>
    <string>us-central1</string>
    <key>vertexAnthropicRegion</key>
    <string>us-east5</string>'
        restart_parleq
        echo "--- check Settings → Vertex card and Compliance Audit ---"
        ;;

    test30-aws-region-and-profile-pins)
        # Pin awsRegion + awsProfile.
        # Verify:
        #   1. Settings → Bedrock card: Region TextField disabled + lock icon.
        #   2. Under SSO auth mode: AWS profile TextField disabled + lock icon.
        #   3. Compliance Audit: awsRegion + awsProfile both Managed.
        write_scenario '    <key>awsRegion</key>
    <string>us-east-2</string>
    <key>awsProfile</key>
    <string>corp-bedrock</string>'
        restart_parleq
        echo "--- check Settings → Bedrock card and Compliance Audit ---"
        ;;

    test31-azure-destination-pins)
        # Pin azureResource + azureDeployment.
        # Verify:
        #   1. Settings → Azure card: Resource + Deployment TextFields both
        #      disabled with lock icons.
        #   2. API version TextField is NOT disabled (not pinned).
        #   3. Compliance Audit: both new rows Managed.
        write_scenario '    <key>azureResource</key>
    <string>corp-openai</string>
    <key>azureDeployment</key>
    <string>gpt-4o-mini</string>'
        restart_parleq
        echo "--- check Settings → Azure card and Compliance Audit ---"
        ;;

    test32-vertex-auth-mode-pin)
        # Pin vertexAuthMode=adc. The Vertex auth-mode segmented picker
        # should be replaced with a fixed "gcloud (ADC)" label + lock icon.
        # Verify:
        #   1. Auth-mode row shows the fixed disabled label, NOT the picker.
        #   2. Service account JSON entry is hidden (we're in ADC mode).
        #   3. ADC instructions still appear in the body.
        #   4. Compliance Audit shows vertexAuthMode=adc / Managed.
        write_scenario '    <key>vertexAuthMode</key>
    <string>adc</string>'
        restart_parleq
        echo "--- check Settings → Vertex card auth-mode row ---"
        ;;

    test33-vertex-card-clarity-196)
        # #196 fix verification: store vertexAuthMode=serviceAccount on disk,
        # then push staticApiKeysAllowed=false. The Vertex card USED to show
        # BOTH a fixed "gcloud (ADC)" label AND a "Service account JSON entry
        # disabled by your organization" caption — read as contradictory.
        # Now: only the fixed label + ADC instructions; no JSON-disabled caption.
        # Prep: switch to Vertex/serviceAccount before running this scenario
        #       via Settings → LLM → Vertex auth-mode picker. (Restart Parleq
        #       afterwards if needed so the change persists.)
        # Then this scenario writes the master switch:
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        echo "--- check Settings → Vertex card body should NOT show ---"
        echo "    'Service account JSON entry disabled by your organization' ---"
        echo "    Only the ADC instructions caption should appear."
        ;;

    test34-suskipped-clear)
        # SUSkippedVersion bypass closure. Set SUSkippedVersion in the user
        # domain, push autoUpdateEnabled=true, verify all three Sparkle 2.x
        # skip keys are cleared on launch.
        # Verify:
        #   1. Before relaunch: all three keys present in user defaults.
        #   2. After relaunch: all three keys cleared.
        echo "--- setting SUSkippedVersion + variants in user defaults ---"
        defaults write com.parleq.app SUSkippedVersion -string "99.99.99"
        defaults write com.parleq.app SUSkippedMajorVersion -string "99"
        defaults write com.parleq.app SUSkippedMajorSubreleaseVersion -string "99.99"
        echo "Before relaunch:"
        defaults read com.parleq.app SUSkippedVersion 2>/dev/null || echo "  SUSkippedVersion: (unset)"
        defaults read com.parleq.app SUSkippedMajorVersion 2>/dev/null || echo "  SUSkippedMajorVersion: (unset)"
        defaults read com.parleq.app SUSkippedMajorSubreleaseVersion 2>/dev/null || echo "  SUSkippedMajorSubreleaseVersion: (unset)"
        write_scenario '    <key>autoUpdateEnabled</key>
    <true/>'
        restart_parleq
        sleep 2
        echo "After relaunch:"
        defaults read com.parleq.app SUSkippedVersion 2>/dev/null \
            && echo "  FAIL: SUSkippedVersion still present" \
            || echo "  PASS: SUSkippedVersion cleared"
        defaults read com.parleq.app SUSkippedMajorVersion 2>/dev/null \
            && echo "  FAIL: SUSkippedMajorVersion still present" \
            || echo "  PASS: SUSkippedMajorVersion cleared"
        defaults read com.parleq.app SUSkippedMajorSubreleaseVersion 2>/dev/null \
            && echo "  FAIL: SUSkippedMajorSubreleaseVersion still present" \
            || echo "  PASS: SUSkippedMajorSubreleaseVersion cleared"
        ;;

    test35-setup-wizard-gemini-blocked)
        # SetupWizard credential gating (#198). Push staticApiKeysAllowed=false,
        # reset wizard so it relaunches on next start.
        # Verify in the SetupWizard's "Configure provider" step:
        #   1. Pick "Google Gemini" — the API key SecureField is HIDDEN.
        #   2. A "Choose a federated-auth provider" note appears instead.
        #   3. Pick "Vertex" + "Service account JSON" — the SA JSON TextEditor
        #      is HIDDEN; switching to "gcloud (ADC)" shows ADC instructions.
        #   4. Pick "Azure" + "API key" — the API key SecureField is HIDDEN;
        #      switching to "Microsoft Entra ID" shows the Entra instructions.
        echo "--- resetting wizard so it auto-launches ---"
        # Edit user config to set wizard.completed=false. Use plutil for
        # idempotence; create the file with defaults if missing.
        if [ ! -f ~/.parleq/config.json ]; then
            mkdir -p ~/.parleq
            echo '{"wizard": {"completed": false}}' > ~/.parleq/config.json
        else
            # JQ-style edit via python (always present on macOS).
            python3 -c "
import json, os
p = os.path.expanduser('~/.parleq/config.json')
with open(p) as f: c = json.load(f)
c.setdefault('wizard', {})['completed'] = False
with open(p, 'w') as f: json.dump(c, f, indent=2)
"
        fi
        write_scenario '    <key>staticApiKeysAllowed</key>
    <false/>'
        restart_parleq
        echo "--- SetupWizard should launch; check each provider's credential step ---"
        ;;

    "")
        echo "Available scenarios:"
        echo "  clear                          remove managed config + relaunch"
        echo "  test1-lock-icon                referenceWindowsEnabled=false"
        echo "  test2-provider-pin             cleanupProvider=azure"
        echo "  test3-provider-allowlist       cleanupAllowedProviders=[azure,openai]"
        echo "  test4-model-pin                pin openai + gpt-4o-mini"
        echo "  test5-model-allowlist          openai + allowed [gpt-4o, gpt-4o-mini]"
        echo "  test6-cross-provider-snap      allowed=[gemini-2.5-flash] no provider pin"
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
        echo ""
        echo "  --- Phase 7 (MDM hardening) ---"
        echo "  test25-asr-endpoint-bundled-pin  asrEndpoint pinned to bundled-FluidAudio sentinel"
        echo "  test26-asr-endpoint-https-pin  asrEndpoint pinned to https://asr.example.com:8443/inference"
        echo "  test27-asr-endpoint-rejects-http  http://attacker.example/inference rejected by validator"
        echo "  test28-asr-endpoint-rejects-userinfo  embedded user:pass@host rejected by validator"
        echo "  test29-vertex-destination-pins  vertexProject + vertexRegion + vertexAnthropicRegion"
        echo "  test30-aws-region-and-profile-pins  awsRegion + awsProfile"
        echo "  test31-azure-destination-pins  azureResource + azureDeployment"
        echo "  test32-vertex-auth-mode-pin  vertexAuthMode=adc (symmetric with azureAuthMode/bedrockAuthMode)"
        echo "  test33-vertex-card-clarity-196  no redundant 'JSON disabled' caption when apiKeysBlocked"
        echo "  test34-suskipped-clear  SUSkippedVersion+major+subrelease cleared on autoUpdateEnabled=true"
        echo "  test35-setup-wizard-gemini-blocked  SetupWizard hides credential fields under staticApiKeysAllowed=false"
        exit 1
        ;;

    *)
        echo "Unknown scenario: $scenario" >&2
        echo "Run without args to see the list." >&2
        exit 1
        ;;
esac
