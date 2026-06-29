// ManagedConfigAuditView — Compliance Audit dialog.
//
// Opened from Settings → Privacy & Features → "View managed
// configuration…" (PrivacyFeaturesView.swift, 0.13.0+). The
// dialog used to live as a top-level menu bar item; moved into
// Settings in 0.13.0 (#213) as part of a menu-bar declutter pass.
// Shows every managed-eligible key with its current effective
// value and source:
//   - "Managed"  (orange badge) — value came from /Library/Managed Preferences
//   - "User"     (gray badge)   — value was set by the user in Settings / config.json
//   - "Default"  (light gray)   — value is the built-in default (never changed)
//
// A "Copy snapshot" button puts a JSON dump of the whole snapshot on the
// clipboard for IT verification without screen-sharing or Terminal access.
//
// The list of eligible keys is `ManagedConfig.allKeys` — the single source
// of truth shared with Config.load() and ManagedConfigTests.
//
// Presentation: a plain NSPanel (non-activating) opened via the
// shared `ManagedConfigAuditWindowController` (singleton, see
// bottom of this file). PrivacyFeaturesView calls
// `.shared.show()` directly; no callback plumbing needed.

import AppKit
import SwiftUI

// MARK: - Data model

/// One row in the compliance audit table. Each row represents one
/// managed-eligible key with its current effective value and the source
/// that determined the value.
struct AuditRow: Identifiable {
    let id = UUID()
    let key: String
    let displayValue: String
    let source: AuditSource
}

enum AuditSource {
    case managed   // /Library/Managed Preferences — IT pushed this
    case user      // user stored this via Settings or config.json
    case `default` // built-in fallback — never changed

    var label: String {
        switch self {
        case .managed:  return "Managed"
        case .user:     return "User"
        case .default:  return "Default"
        }
    }

    var color: Color {
        switch self {
        case .managed:  return Color.orange
        case .user:     return Color.secondary
        case .default:  return Color(NSColor.tertiaryLabelColor)
        }
    }
}

// MARK: - Build snapshot

/// Build the audit rows from the current loaded config + managed overlay.
/// Called on every view appear so the dialog reflects live state.
func buildAuditRows() -> [AuditRow] {
    let (config, _) = Config.load()
    return buildAuditRows(config: config)
}

/// Injectable variant: tests pass a synthetic Config so assertions never
/// depend on the developer's live ~/.parleq/config.json.
func buildAuditRows(config: Config) -> [AuditRow] {
    let defaults = Config.default
    return ManagedConfig.allKeys.map { key in
        let (displayValue, source) = resolveAuditRow(key: key, config: config, defaults: defaults)
        return AuditRow(key: key, displayValue: displayValue, source: source)
    }
}

private func resolveAuditRow(key: String, config: Config, defaults: Config) -> (String, AuditSource) {
    let isManaged = config.managedKeys.contains(key)

    switch key {
    // MARK: Bool keys
    case "referenceWindowsEnabled":
        return formatBool(config.referenceWindowsEnabled, managed: isManaged, defaultVal: defaults.referenceWindowsEnabled)
    case "clipboardReferenceEnabled":
        return formatBool(config.clipboardReferenceEnabled, managed: isManaged, defaultVal: defaults.clipboardReferenceEnabled)
    case "imageReferenceEnabled":
        return formatBool(config.imageReferenceEnabled, managed: isManaged, defaultVal: defaults.imageReferenceEnabled)
    case "fileReferenceEnabled":
        return formatBool(config.fileReferenceEnabled, managed: isManaged, defaultVal: defaults.fileReferenceEnabled)
    case "customDictionaryEnabled":
        return formatBool(config.customDictionaryEnabled, managed: isManaged, defaultVal: defaults.customDictionaryEnabled)
    case "customModelEntryEnabled":
        return formatBool(config.customModelEntryEnabled, managed: isManaged, defaultVal: defaults.customModelEntryEnabled)
    // Phase 8 — transcript-history retention (0.14.0 PR 6 / #221).
    // Optional Int values; nil renders as "Unlimited", 0 as
    // "Disabled (no history)" so the audit dialog is honest about
    // what the deployed policy actually means at the user UI.
    case "transcriptHistoryMaxEntries":
        return formatOptionalRetentionInt(
            config.transcriptHistoryMaxEntries,
            managed: isManaged,
            defaultVal: defaults.transcriptHistoryMaxEntries
        )
    case "transcriptHistoryRetentionHours":
        return formatOptionalRetentionInt(
            config.transcriptHistoryRetentionHours,
            managed: isManaged,
            defaultVal: defaults.transcriptHistoryRetentionHours
        )
    // Phase 9 — learn-from-corrections (opt-in feature + journal retention).
    case "learnFromCorrectionsEnabled":
        return formatBool(config.learnFromCorrectionsEnabled, managed: isManaged, defaultVal: defaults.learnFromCorrectionsEnabled)
    // Transform presets feature toggle.
    case "transformPresetsEnabled":
        return formatBool(config.transformPresetsEnabled, managed: isManaged, defaultVal: defaults.transformPresetsEnabled)
    case "learnedCorrectionsMaxEntries":
        return formatOptionalRetentionInt(
            config.learnedCorrectionsMaxEntries,
            managed: isManaged,
            defaultVal: defaults.learnedCorrectionsMaxEntries,
            disabledLabel: "Disabled (no corrections)"
        )
    case "learnedCorrectionsRetentionHours":
        return formatOptionalRetentionInt(
            config.learnedCorrectionsRetentionHours,
            managed: isManaged,
            defaultVal: defaults.learnedCorrectionsRetentionHours,
            disabledLabel: "Disabled (no corrections)"
        )
    case "voiceEnrollmentEnabled":
        // Phase 10 — voiceprint master switch. Default on (true). When MDM
        // forces false, enrollment UI is hidden and voiceprint matching is
        // disabled fleet-wide. Normal fail-open Bool key (managed bool or nil).
        return formatBool(config.voiceEnrollmentEnabled, managed: isManaged, defaultVal: defaults.voiceEnrollmentEnabled)
    case "voiceprintClipStorageEnabled":
        // Phase 10 — on-device clip-storage kill-switch. Default on (true).
        // SI-2: fails CLOSED — a present-but-malformed forced value disables
        // clip storage. Annotate the audit row when the key is managed-and-off
        // so an IT admin sees the fail-closed policy in effect.
        let display: String
        if isManaged && !config.voiceprintClipStorageEnabled {
            display = "false (fail-closed: clip storage disabled by MDM)"
        } else {
            display = config.voiceprintClipStorageEnabled ? "true" : "false"
        }
        let source: AuditSource = isManaged ? .managed : (config.voiceprintClipStorageEnabled != defaults.voiceprintClipStorageEnabled ? .user : .default)
        return (display, source)
    case "autoUpdateEnabled":
        // autoUpdateEnabled is Sparkle-side only — read managed value directly since
        // it isn't mirrored into Config fields.
        if let managedVal = ManagedConfig.managedBool(forKey: "autoUpdateEnabled") {
            return ("\(managedVal)", .managed)
        }
        return ("(Sparkle-controlled)", .user)

    // MARK: String keys (provider/model pins)
    case "cleanupProvider":
        return formatString(config.llmProvider, managed: isManaged, defaultVal: defaults.llmProvider)
    case "cleanupModel":
        return formatString(config.llmModel, managed: isManaged, defaultVal: defaults.llmModel)
    case "contextProvider":
        // When MDM doesn't manage this key, classify as User when the user
        // explicitly set a distinct context-tier provider (contextModel
        // non-nil) and Default when the context tier inherits cleanup
        // (contextModel == nil, so the effective value is the cleanup
        // provider passing through). Without this branch the formatString
        // helper with defaultVal:nil would always classify these as
        // Default, hiding user-set context-tier choices.
        let val = config.contextModel?.provider ?? config.llmProvider
        let display = val.isEmpty ? "(not set)" : val
        if isManaged { return (display, .managed) }
        return (display, config.contextModel != nil ? .user : .default)
    case "contextModel":
        let val = config.contextModel?.model ?? config.llmModel
        let display = val.isEmpty ? "(not set)" : val
        if isManaged { return (display, .managed) }
        return (display, config.contextModel != nil ? .user : .default)

    // MARK: [String] keys (allowlists)
    case "cleanupAllowedProviders":
        if let arr = ManagedConfig.managedStringArray(forKey: key) {
            return ("[\(arr.joined(separator: ", "))]", .managed)
        }
        return ("(any)", .default)
    case "cleanupAllowedModels":
        if let arr = ManagedConfig.managedStringArray(forKey: key) {
            return ("[\(arr.joined(separator: ", "))]", .managed)
        }
        return ("(any)", .default)
    case "contextAllowedProviders":
        if let arr = ManagedConfig.managedStringArray(forKey: key) {
            return ("[\(arr.joined(separator: ", "))]", .managed)
        }
        return ("(any)", .default)
    case "contextAllowedModels":
        if let arr = ManagedConfig.managedStringArray(forKey: key) {
            return ("[\(arr.joined(separator: ", "))]", .managed)
        }
        return ("(any)", .default)

    // MARK: Phase 3 — operational policy keys
    case "sparkleUpdateFeedURL":
        // Centralized validation (see ManagedConfig.validateFeedURL): strict
        // scheme=https, non-empty host, no userinfo, no query. Display only
        // scheme://host to avoid leaking any path/query/userinfo through the
        // audit dialog — the snapshot can be copied to a clipboard, and a
        // tokenized URL on a clipboard is the same threat model as logging.
        if let raw = ManagedConfig.managedString(forKey: key) {
            if let url = ManagedConfig.validateFeedURL(raw) {
                let safe = "\(url.scheme ?? "https")://\(url.host ?? "?")"
                return (safe, .managed)
            }
            return ("(invalid — using Info.plist SUFeedURL)", .default)
        }
        return ("(Info.plist SUFeedURL)", .default)

    case "loggingMode":
        // Forward-compatibility hook. Only "lengthOnly" and "verbose" are
        // recognized; anything else is rejected and treated as unmanaged.
        if let raw = ManagedConfig.managedString(forKey: key) {
            let recognized = ["lengthOnly", "verbose"]
            if recognized.contains(raw) {
                return (raw, .managed)
            }
            // Unrecognized value — rejected by Config.applyManagedOverlay;
            // not added to managedKeys so the effective policy is Default.
            return ("(unrecognized: \(raw))", .default)
        }
        return ("lengthOnly", .default)

    // MARK: Phase 4 — auth-mode restriction keys

    case "staticApiKeysAllowed":
        // Bool master switch. Default is true (API key entry is allowed).
        // Phase 5: when false, also enforces runtime auth-path blocking.
        // Append a compact summary of which provider/authMode combinations
        // are currently blocked given the user's stored config — useful for
        // an IT admin confirming the policy has taken effect as expected.
        if let managedVal = ManagedConfig.managedBool(forKey: "staticApiKeysAllowed") {
            let valStr = managedVal ? "true" : "false"
            if !managedVal {
                // Build a per-provider blocked summary based on the user's
                // stored config. Only include providers whose current auth
                // mode is blocked (fully-blocked ones appear regardless of mode).
                let providerAuthModes: [(String, String?)] = [
                    ("gemini",         nil),
                    ("openai",         nil),
                    ("bedrock-bearer", nil),
                    ("vertex",         config.vertexAuthMode),
                    ("azure",          config.azureAuthMode),
                    ("bedrock",        config.awsAuthMode),
                ]
                let blocked = providerAuthModes
                    .filter { ManagedConfig.isProviderAuthPathBlocked(provider: $0.0, authMode: $0.1) }
                    .map { $0.0 }
                if blocked.isEmpty {
                    return ("\(valStr) (no providers blocked — all using federated auth)", .managed)
                } else {
                    return ("\(valStr) — blocked: \(blocked.joined(separator: ", "))", .managed)
                }
            }
            return (valStr, .managed)
        }
        return ("true", .default)

    case "azureAuthMode":
        // String pin. Default is "apiKey". When managed, overrides the
        // stored config value and locks the Azure auth-mode picker.
        // If MDM pushed an unrecognized value, Config.applyManagedOverlay
        // rejects it and doesn't add it to managedKeys — but we surface
        // the rejected raw value here so an admin pushing an invalid
        // policy can see it in the audit dialog (mirrors loggingMode).
        if !isManaged, let raw = ManagedConfig.managedString(forKey: "azureAuthMode") {
            let recognized = ["apiKey", "azureAd"]
            if !recognized.contains(raw) {
                return ("(unrecognized: \(raw))", .default)
            }
        }
        return formatString(config.azureAuthMode, managed: isManaged, defaultVal: defaults.azureAuthMode)

    case "bedrockAuthMode":
        // String pin. Default is "sso". When managed, overrides the
        // stored config value (stored as awsAuthMode) and locks the
        // Bedrock IAM auth-mode picker. Unrecognized values are
        // surfaced as "(unrecognized: ...)" — same UX as loggingMode.
        if !isManaged, let raw = ManagedConfig.managedString(forKey: "bedrockAuthMode") {
            let recognized = ["sso", "static", "bedrockApiKey"]
            if !recognized.contains(raw) {
                return ("(unrecognized: \(raw))", .default)
            }
        }
        return formatString(config.awsAuthMode, managed: isManaged, defaultVal: defaults.awsAuthMode)

    // MARK: Phase 7 — destination pins
    case "vertexAuthMode":
        // String pin. Default is "adc". Surface unrecognized values
        // the same way azureAuthMode + bedrockAuthMode do.
        if !isManaged, let raw = ManagedConfig.managedString(forKey: "vertexAuthMode") {
            let recognized = ["adc", "serviceAccount"]
            if !recognized.contains(raw) {
                return ("(unrecognized: \(raw))", .default)
            }
        }
        // Distinguish admin-pinned from Parleq-auto-coerced. When
        // vertexAuthMode is in managedKeys but the MDM plist does NOT
        // carry the key, Parleq's #196 option-2 coercion is the
        // source. Annotate the value so an admin auditing the
        // snapshot understands the cause (otherwise they'd see
        // "vertexAuthMode: adc / Managed" and wonder if their policy
        // accidentally pinned it).
        if isManaged && ManagedConfig.managedString(forKey: "vertexAuthMode") == nil {
            return ("\(config.vertexAuthMode) (auto: staticApiKeysAllowed=false)", .managed)
        }
        return formatString(config.vertexAuthMode, managed: isManaged, defaultVal: defaults.vertexAuthMode)
    case "asrEndpoint":
        // For the bundled sentinel show a friendly "(bundled FluidAudio)"
        // marker; for an HTTPS URL show scheme://host[:port] (path stripped
        // so a tokenized URL doesn't leak via the clipboard snapshot — but
        // port preserved so an admin auditing a non-default port can
        // confirm it's pinned).
        if config.asrEndpoint == Config.bundledASREndpoint {
            return ("(bundled FluidAudio)", isManaged ? .managed : .default)
        }
        if let url = URL(string: config.asrEndpoint), let host = url.host, !host.isEmpty {
            let portSuffix = url.port.map { ":\($0)" } ?? ""
            let safe = "\(url.scheme ?? "https")://\(host)\(portSuffix)"
            return (safe, isManaged ? .managed : .user)
        }
        return formatString(config.asrEndpoint, managed: isManaged, defaultVal: defaults.asrEndpoint)
    case "vertexProject":
        return formatString(config.vertexProject, managed: isManaged, defaultVal: defaults.vertexProject)
    case "vertexRegion":
        return formatString(config.vertexRegion, managed: isManaged, defaultVal: defaults.vertexRegion)
    case "vertexAnthropicRegion":
        return formatString(config.vertexAnthropicRegion, managed: isManaged, defaultVal: defaults.vertexAnthropicRegion)
    case "awsRegion":
        return formatString(config.awsRegion, managed: isManaged, defaultVal: defaults.awsRegion)
    case "awsProfile":
        // awsProfile is String? — display the unwrapped value with a
        // "(default profile)" placeholder when nil/empty.
        let display = (config.awsProfile?.isEmpty == false) ? config.awsProfile! : "(default profile)"
        if isManaged { return (display, .managed) }
        // User-set when stored profile differs from the default-value
        // (defaults.awsProfile is nil), otherwise Default.
        if config.awsProfile != defaults.awsProfile { return (display, .user) }
        return (display, .default)
    case "azureResource":
        return formatString(config.azureResource, managed: isManaged, defaultVal: defaults.azureResource)
    case "azureDeployment":
        return formatString(config.azureDeployment, managed: isManaged, defaultVal: defaults.azureDeployment)

    // MARK: Enterprise OIDC federation
    case "oidcIssuer":
        return formatString(config.oidcIssuer, managed: isManaged, defaultVal: defaults.oidcIssuer)
    case "oidcClientID":
        return formatString(config.oidcClientID, managed: isManaged, defaultVal: defaults.oidcClientID)
    case "oidcScopes":
        // Array of scope strings. "(not set)" can't happen (a non-empty
        // default list always applies); compare against the default list
        // to classify User vs Default.
        let display = "[\(config.oidcScopes.joined(separator: ", "))]"
        if isManaged { return (display, .managed) }
        return (display, config.oidcScopes != defaults.oidcScopes ? .user : .default)
    case "oidcEphemeralBrowserSession":
        return formatBool(config.oidcEphemeralBrowser, managed: isManaged, defaultVal: defaults.oidcEphemeralBrowser)
    case "oidcRedirectURI":
        return formatString(config.oidcRedirectURI, managed: isManaged, defaultVal: defaults.oidcRedirectURI)
    case "oidcExtraAuthParams":
        // Dictionary of extra authorization-request params. Render the param
        // NAMES only (not values) — same redaction discipline as the startup
        // log. "(none)" when empty (the default).
        let names = config.oidcExtraAuthParams.keys.sorted()
        let display = names.isEmpty ? "(none)" : "{\(names.joined(separator: ", "))}"
        if isManaged { return (display, .managed) }
        return (display, config.oidcExtraAuthParams != defaults.oidcExtraAuthParams ? .user : .default)
    case "awsRoleArn":
        return formatString(config.awsRoleArn, managed: isManaged, defaultVal: defaults.awsRoleArn)
    case "awsSessionDurationSeconds":
        let display = "\(config.awsSessionDurationSeconds)"
        if isManaged { return (display, .managed) }
        return (display, config.awsSessionDurationSeconds != defaults.awsSessionDurationSeconds ? .user : .default)
    case "vertexWorkforceProvider":
        return formatString(config.vertexWorkforceProvider, managed: isManaged, defaultVal: defaults.vertexWorkforceProvider)

    default:
        return ("(unknown key)", .default)
    }
}

private func formatBool(_ value: Bool, managed: Bool, defaultVal: Bool) -> (String, AuditSource) {
    let str = value ? "true" : "false"
    if managed { return (str, .managed) }
    if value != defaultVal { return (str, .user) }
    return (str, .default)
}

/// Format an optional retention-Int (transcriptHistoryMaxEntries /
/// transcriptHistoryRetentionHours, 0.14.0 PR 6 / #221) for the
/// Compliance Audit dialog. nil → "Unlimited"; 0 → "Disabled (no
/// history)"; positive → the number. Source classification matches
/// the standard formatBool/formatString helpers.
private func formatOptionalRetentionInt(_ value: Int?, managed: Bool, defaultVal: Int?, disabledLabel: String = "Disabled (no history)") -> (String, AuditSource) {
    let display: String
    switch value {
    case nil: display = "Unlimited"
    case 0: display = disabledLabel
    case let .some(n): display = "\(n)"
    }
    if managed { return (display, .managed) }
    if value != defaultVal { return (display, .user) }
    return (display, .default)
}

private func formatString(_ value: String, managed: Bool, defaultVal: String?) -> (String, AuditSource) {
    let display = value.isEmpty ? "(not set)" : value
    if managed { return (display, .managed) }
    if let d = defaultVal, value != d { return (display, .user) }
    return (display, .default)
}

// MARK: - Build clipboard snapshot

func buildJSONSnapshot() -> String {
    let rows = buildAuditRows()
    var dict: [String: Any] = [:]
    for row in rows {
        dict[row.key] = ["value": row.displayValue, "source": row.source.label]
    }
    let json = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) }
        ?? "{}"
    return json
}

// MARK: - SwiftUI View

/// The Compliance Audit dialog content view.
@MainActor
struct ManagedConfigAuditView: View {
    @State private var rows: [AuditRow] = []
    @State private var copyConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Managed Configuration")
                    .font(.title2.weight(.semibold))
                Text("Active managed keys, their current values, and sources.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Table
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        Divider()
                            .opacity(0.4)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Footer buttons
            HStack {
                Button(copyConfirmed ? "Copied!" : "Copy snapshot") {
                    let json = buildJSONSnapshot()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                    copyConfirmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copyConfirmed = false
                    }
                }
                .help("Copy all keys, values, and sources as JSON to the clipboard for IT verification.")

                Spacer()

                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        // Explicit width AND height so the SwiftUI hosting view's
        // intrinsic content size is well-defined. Without a height
        // dimension, the NSHostingController + NSPanel layout-constraint
        // negotiation throws during the first display cycle (the panel
        // has an explicit contentRect, the SwiftUI view doesn't know
        // how tall it wants to be, and the resulting ambiguity aborts
        // the window's setNeedsUpdateConstraints pass).
        .frame(width: 560, height: 520)
        .onAppear { rows = buildAuditRows() }
    }

    @ViewBuilder
    private func rowView(_ row: AuditRow) -> some View {
        HStack(spacing: 0) {
            // Key name
            Text(row.key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 220, alignment: .leading)
                .padding(.leading, 16)
                .padding(.vertical, 8)

            // Effective value
            Text(row.displayValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            // Source badge
            sourceBadge(row.source)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(row.source == .managed ? Color.orange.opacity(0.06) : Color.clear)
    }

    @ViewBuilder
    private func sourceBadge(_ source: AuditSource) -> some View {
        Text(source.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(source.color.opacity(0.15))
            )
            .foregroundStyle(source.color)
    }
}

// MARK: - Window controller

/// Hosts `ManagedConfigAuditView` in a floating panel. Call `show()`
/// to open or bring to front. Follows the same pattern as other Parleq
/// detail windows (non-activating panel so the app stays LSUIElement).
@MainActor
public final class ManagedConfigAuditWindowController: NSObject {
    private var panel: NSPanel?

    public static let shared = ManagedConfigAuditWindowController()
    private override init() {}

    public func show() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ManagedConfigAuditView()
        let hosting = NSHostingController(rootView: view)
        // Do NOT use sizingOptions = .preferredContentSize here — when
        // combined with an explicit panel contentRect it confuses the
        // constraint system during the first layout pass and trips a
        // window-update assertion. The SwiftUI .frame(width:height:)
        // on the root view supplies a well-defined intrinsic size and
        // the panel's contentRect matches.

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Managed Configuration"
        p.isReleasedWhenClosed = false
        p.contentViewController = hosting
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
}
