// HelpOverlayWindow — a transient "?" help panel that lists every
// gesture/command available in the dictation overlay.
//
// Shown by pressing "?" (or "/") while the dictation overlay has key
// focus — during capture, review, or refine. It floats ABOVE the main
// overlay (a separate NSPanel at .floating level) without disturbing
// it: the underlying dictation session is paused (audio preserved) while
// the panel is up and resumes when it's dismissed. Esc or "?" closes it.
//
// Mirrors the OverlayPanel pattern: borderless, non-activating,
// canBecomeKey so keyDown delivers Esc without activating the app.

import AppKit
import SwiftUI

@MainActor
final class HelpOverlayWindow {
    private let panel: HelpPanel
    private let hostingController: NSHostingController<HelpContent>
    private let model = HelpModel()

    /// Fired when the user dismisses the help panel (Esc, "?", or a
    /// click outside). AppState resumes the paused dictation here.
    var onDismiss: (() -> Void)?

    init() {
        let content = HelpContent(model: model)
        hostingController = NSHostingController(rootView: content)

        panel = HelpPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Strictly above the main dictation overlay, which sits at
        // .popUpMenu (level 101). .floating (3) would render BEHIND it
        // when a tall overlay overlaps the centered help panel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.onDismiss = { [weak self] in self?.onDismiss?() }
    }

    /// Show the help panel, populated for the user's actual hotkey name
    /// (e.g. "⌥-Right") so the instructions read correctly.
    /// `referenceWindowsEnabled` drops the Space/C attach gestures from
    /// the list when reference windows are disabled (MDM / Settings), so
    /// the panel only advertises gestures that are actually live.
    func show(hotkeyName: String, referenceWindowsEnabled: Bool) {
        model.hotkeyName = hotkeyName.isEmpty ? "your hotkey" : hotkeyName
        model.referenceWindowsEnabled = referenceWindowsEnabled
        // Size to content, then center, then show. Sizing before
        // centering avoids the "grows from the wrong origin" class of
        // bug documented in CLAUDE.md.
        let fitting = hostingController.view.fittingSize
        let size = NSSize(width: 480, height: max(260, fitting.height))
        panel.setContentSize(size)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Panel subclass (Esc / "?" to dismiss without activating the app)

private final class HelpPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {        // Escape
            onDismiss?()
            return
        }
        // Match the produced glyph (layout-independent), mirroring the
        // overlay's trigger — check both characters and the
        // modifiers-ignored form so it works regardless of held
        // modifiers. Ignore key-repeat: the same "?" press that opened
        // the panel auto-repeats into this now-key panel and would
        // immediately close it (a flicker). Only a fresh tap dismisses.
        let glyph = event.characters
        let baseGlyph = event.charactersIgnoringModifiers
        if glyph == "?" || glyph == "/" || baseGlyph == "?" || baseGlyph == "/" {
            if !event.isARepeat { onDismiss?() }
            return
        }
        super.keyDown(with: event)
    }

    // Clicking outside (resigning key) dismisses, matching the
    // lightweight-popover feel.
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }
}

// MARK: - Content

@MainActor
private final class HelpModel: ObservableObject {
    @Published var hotkeyName: String = "your hotkey"
    @Published var referenceWindowsEnabled: Bool = true
}

private struct HelpRow {
    let keys: String
    let desc: String
}

private struct HelpSection {
    let title: String
    let rows: [HelpRow]
}

/// A term + plain-language definition for the glossary at the top of
/// the panel. Separate from HelpRow because it renders as prose
/// (bold term — definition) rather than the keys/description grid.
private struct GlossaryEntry {
    let term: String
    let def: String
}

private struct HelpContent: View {
    @ObservedObject var model: HelpModel

    /// Plain-language definitions for the vocabulary the command list
    /// assumes ("refine" especially is used but never explained). Shown
    /// near the top so the shortcuts below make sense. Uses the generic
    /// "the hotkey" term (the actual binding is stated once in the
    /// Hotkey section). The "reference window" entry is dropped when
    /// that feature is disabled, matching the Space/C rows.
    private var glossary: [GlossaryEntry] {
        var entries: [GlossaryEntry] = [
            GlossaryEntry(
                term: "Dictate",
                def: "Speak, and Parleq transcribes and cleans up your words."
            ),
            GlossaryEntry(
                term: "Review",
                def: "Check the cleaned text before it\u{2019}s pasted — then accept, "
                    + "refine, or cancel it."
            ),
            GlossaryEntry(
                term: "Refine",
                def: "Revise the result — hold the hotkey again and say what to "
                    + "change (e.g. \u{201C}make it shorter\u{201D})."
            ),
        ]
        if model.referenceWindowsEnabled {
            entries.append(GlossaryEntry(
                term: "Reference window",
                def: "Another window attached as context, so cleanup and refine "
                    + "can use what\u{2019}s on your screen."
            ))
        }
        return entries
    }

    /// The user's actual hotkey, stated once at the top so every other
    /// section can say the generic "the hotkey". This is the single
    /// place the binding appears — the help fully adapts to a rebind
    /// (the name is passed live from the binding's displayName).
    private var hotkeySection: HelpSection {
        HelpSection(title: "Hotkey", rows: [
            HelpRow(
                keys: model.hotkeyName,
                desc: "Your dictation hotkey — \u{201C}the hotkey\u{201D} below means this"
            ),
        ])
    }

    /// The keystroke sections, in reading order. Space/C/P/? all work
    /// both while the hotkey is held (dictating or refining) AND while
    /// reviewing, so they live in one combined section rather than being
    /// duplicated. Reviewing keeps only the keys unique to it.
    private var commandSections: [HelpSection] {
        // Combined section — works while dictating/refining AND while
        // reviewing. Space/C only when reference windows are enabled.
        // Esc and P abort from any state; ? shows help from any state.
        var both: [HelpRow] = []
        if model.referenceWindowsEnabled {
            both.append(HelpRow(keys: "Space", desc: "Attach another window as context"))
            both.append(HelpRow(keys: "C", desc: "Attach the current window as context"))
        }
        both.append(HelpRow(keys: "Esc", desc: "Cancel"))
        both.append(HelpRow(keys: "P", desc: "Cancel and show the Parleq window"))
        both.append(HelpRow(keys: "? or /", desc: "Show this help"))

        return [
            HelpSection(title: "Dictate", rows: [
                HelpRow(keys: "Hold the hotkey", desc: "Dictate — review, then accept"),
                HelpRow(keys: "Double-tap + hold the hotkey", desc: "Quick dictate — pastes straight away"),
            ]),
            HelpSection(title: "Refine", rows: [
                HelpRow(keys: "Hold the hotkey again", desc: "Revise your reviewed text — say what to change"),
            ]),
            HelpSection(title: "While dictating, refining, or reviewing", rows: both),
            HelpSection(title: "Reviewing your text", rows: [
                HelpRow(keys: "Enter", desc: "Accept & paste to the current app"),
                HelpRow(keys: "V", desc: "Send to a different window"),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Parleq commands")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Esc to close")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 18) {
                // Hotkey first — states the actual binding once, so
                // everything below can use the generic "the hotkey".
                sectionView(hotkeySection)
                // Concepts glossary — definition prose (bold term —
                // definition) instead of the keys/description grid.
                glossaryView
                // Command sections (keys/description grid).
                ForEach(commandSections, id: \.title) { section in
                    sectionView(section)
                }
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// A keys/description section: amber uppercase header with the rows
    /// indented beneath it. Shared by the Hotkey section and every
    /// command section.
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(SettingsView.brandAccent)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.rows, id: \.keys) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.keys)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(width: 200, alignment: .leading)
                        Text(row.desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 16)
        }
    }

    /// The Concepts glossary: same amber header + indentation as a
    /// section, but each row is definition prose (bold term — text)
    /// rather than the keys/description grid.
    private var glossaryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONCEPTS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(SettingsView.brandAccent)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(glossary, id: \.term) { entry in
                    (
                        Text(entry.term)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        + Text("  —  \(entry.def)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 16)
        }
    }
}
