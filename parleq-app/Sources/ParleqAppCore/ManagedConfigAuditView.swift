// ManagedConfigAuditView — Compliance Audit dialog.
//
// Opened via Menu Bar → "View Managed Configuration…". Shows every
// managed-eligible key with its current effective value and source:
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
// Presentation: a plain NSPanel (non-activating) opened via
// ManagedConfigAuditWindowController. The controller is held by MenuBar
// (or by ParleqApp.main, analogous to how SettingsWindowController works).

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
