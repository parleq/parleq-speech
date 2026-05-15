// MenuBar — the NSStatusItem in the macOS menu bar (top-right, near
// the clock). For an LSUIElement app like Parleq, this is the only
// always-visible UI handle the user has to confirm the app is running
// and to quit it cleanly.
//
// What it shows:
//   - An icon: outlined mic when idle, filled mic when an utterance
//     is in flight (capturing / cleaning / refining / pasting).
//   - On click, a menu with:
//       * "Status: <human-readable phase>" (informational, disabled)
//       * "Hotkey: <binding>"             (informational, disabled)
//       * Separator
//       * "Quit Parleq" (⌘Q) — terminates the app.
//
// Wiring: AppState calls onPhaseChanged on every phase transition;
// ParleqApp.main hooks this into MenuBar.setPhase so the icon and
// status string update without the menu bar ever poking at AppState.
//
// Inherits NSObject so we can use #selector for the Quit menu action.

import AppKit

@MainActor
final class MenuBar: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    /// "⚠ Cleanup failed — <message>" item that appears between
    /// Status and Hotkey when LLM cleanup fails (#28). Click
    /// dismisses the badge. Hidden by default; every `applyResult`
    /// in AppState — both quick-mode and the overlay path — toggles
    /// visibility via `setCleanupFailure(_:)`. Quick mode is the
    /// motivating case (no overlay to surface the failure inline),
    /// but firing in normal mode too means a successful subsequent
    /// dictation automatically clears the badge even when the user
    /// never dismissed an earlier one manually.
    private let cleanupFailureMenuItem: NSMenuItem
    /// Submenu listing recent dictations. Items are rebuilt
    /// on every menu open via `NSMenuDelegate.menuNeedsUpdate(_:)`
    /// so the user always sees the current state of
    /// `TranscriptHistory.shared.entries` (newest first).
    private let recentSubmenu = NSMenu()
    private let recentMenuItem: NSMenuItem

    /// Microphone submenu (#25). Rebuilt on every menu open via
    /// `menuNeedsUpdate(_:)` so newly-plugged devices appear without
    /// an app restart and unplugged ones disappear. Item structure:
    /// "System Default" (always first), separator, every available
    /// input device sorted by name. Checkmark on the active item;
    /// when the saved UID doesn't match any present device, an
    /// extra disabled "Selected mic disconnected" placeholder
    /// renders so the user notices their selection isn't taking.
    private let microphoneSubmenu = NSMenu()
    private let microphoneMenuItem: NSMenuItem
    /// `RelativeDateTimeFormatter` formats timestamps like "2 min
    /// ago". One instance reused for all rebuild passes.
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    /// Closure invoked when the user picks "Settings…". ParleqApp.main
    /// wires this to a SettingsWindowController.show() call so the
    /// menu bar doesn't need to know about the window class directly.
    var onOpenSettings: (() -> Void)?
    /// Closure invoked when the user picks "Reset ASR". Wired to
    /// `LocalASR.reset()` in ParleqApp.main — unloads and reloads
    /// the FluidAudio Parakeet TDT v3 model in-process. Useful when
    /// long sessions get the speech engine into a degraded state
    /// (the FluidAudio Nemotron-era issue tracked as #5 in the
    /// retired sidecar; the in-process consolidation kept the same
    /// recovery affordance).
    var onResetASR: (() -> Void)?
    /// Closure invoked when the user picks "Run Setup…". Opens the
    /// SetupWizardController; works regardless of whether the
    /// wizard already ran on first launch (#21 step 6).
    var onOpenWizard: (() -> Void)?
    /// Closure invoked when the user picks "Check for Updates…".
    /// Wired to `SPUStandardUpdaterController.checkForUpdates(nil)`
    /// in ParleqApp.main. Sparkle handles the UI from there — the
    /// "you're up to date" dialog, the "update available" prompt,
    /// the download progress, the relaunch.
    var onCheckForUpdates: (() -> Void)?

    /// Invoked when the user picks an entry from the Microphone
    /// submenu (#25). Empty string = "System Default"; otherwise a
    /// Core Audio device UID. ParleqApp wires this to update both
    /// the AudioRecorder's runtime selection and the persisted
    /// Config.audioInputDeviceUID.
    var onMicrophoneSelected: ((String) -> Void)?

    /// Currently-active microphone UID. Empty = System Default.
    /// Drives the checkmark in the Microphone submenu. ParleqApp
    /// updates this on launch from Config and after each user
    /// selection so the submenu's next-open render is correct.
    /// didSet refreshes the menu-bar tooltip so a hover after any
    /// selection change (from the submenu, from Settings → Audio,
    /// from anywhere else that touches this property) immediately
    /// shows the new mic name — without this, the tooltip stays
    /// pinned to whatever value was set at the last phase
    /// transition.
    var currentMicrophoneUID: String = "" {
        didSet {
            if oldValue != currentMicrophoneUID { refresh() }
        }
    }

    init(hotkeyDisplayName: String) {
        // .variableLength sizes the item to the icon's intrinsic
        // width — what most well-behaved menu-bar apps use.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        cleanupFailureMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recentMenuItem = NSMenuItem(
            title: "Recent Dictations",
            action: nil,
            keyEquivalent: ""
        )
        microphoneMenuItem = NSMenuItem(
            title: "Microphone",
            action: nil,
            keyEquivalent: ""
        )
        super.init()
        recentSubmenu.delegate = self
        recentMenuItem.submenu = recentSubmenu
        microphoneSubmenu.delegate = self
        microphoneMenuItem.submenu = microphoneSubmenu

        statusMenuItem.isEnabled = false

        let hotkeyItem = NSMenuItem(
            title: "Hotkey: \(hotkeyDisplayName)",
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false

        let settingsItem = NSMenuItem(
            title: "Settings…",
            // Deliberately not `openSettings`: that selector name is
            // the canonical macOS Ventura+ "Open Settings" responder
            // action, which AppKit auto-decorates with a gearshape
            // SF Symbol next to the menu item title. We want a
            // text-only menu (consistent with the rest of the menu's
            // styling) so we route through a uniquely-named selector
            // that AppKit doesn't recognize.
            action: #selector(presentSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self

        let runSetupItem = NSMenuItem(
            title: "Run Setup…",
            action: #selector(runSetup),
            keyEquivalent: ""
        )
        runSetupItem.target = self

        let resetASRItem = NSMenuItem(
            title: "Reset ASR",
            action: #selector(resetASR),
            keyEquivalent: ""
        )
        resetASRItem.target = self

        // Cleanup-failure indicator. Hidden by default; every
        // `applyResult` in AppState toggles it via
        // `setCleanupFailure(_:)` with a provider-specific recovery
        // hint on failure or nil on success. Click clears the badge
        // (and the amber-bar icon) manually.
        cleanupFailureMenuItem.target = self
        cleanupFailureMenuItem.action = #selector(dismissCleanupFailure)
        cleanupFailureMenuItem.isHidden = true

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self

        let aboutItem = NSMenuItem(
            title: "About Parleq",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit Parleq",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(cleanupFailureMenuItem)
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())
        menu.addItem(microphoneMenuItem)
        menu.addItem(settingsItem)
        menu.addItem(runSetupItem)
        menu.addItem(.separator())
        menu.addItem(resetASRItem)
        menu.addItem(checkForUpdatesItem)
        menu.addItem(recentMenuItem)
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        applyIcon(active: false)
    }

    @objc private func presentSettings() {
        onOpenSettings?()
    }

    @objc private func runSetup() {
        onOpenWizard?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func resetASR() {
        onResetASR?()
    }

    @objc private func dismissCleanupFailure() {
        // Clearing the badge from the menu doesn't retry the cleanup —
        // the next successful dictation does that on its own. This is
        // just "yes I saw the warning, get it off my menu bar."
        setCleanupFailure(nil)
    }

    @objc private func showAbout() {
        // NSApp's standard About panel reads from Info.plist so we
        // get a native window with version + copyright with no
        // custom UI work. Suitable for a personal-use app; can grow
        // into a richer About later if useful.
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// AppState calls this on every phase transition. We update the
    /// icon (filled when an utterance is in flight) and the status
    /// string in the dropdown menu. When `LocalASR` reports the
    /// speech engine is not yet ready, `setASRReady(false)`
    /// overrides the phase-based label until readiness comes back.
    func setPhase(_ phase: AppState.Phase) {
        currentPhase = phase
        refresh()
    }

    /// `LocalASR` calls this when its TDT model finishes loading
    /// (true) or when `reset()` drops it (false). While not ready
    /// the menu bar shows "Initializing…" regardless of the
    /// underlying phase, since hotkey presses during this window
    /// deliberately don't start a capture.
    func setASRReady(_ ready: Bool) {
        asrReady = ready
        refresh()
    }

    /// `LocalASR` calls this when its model load fails after the
    /// internal one-shot retry. The menu bar then surfaces an at-
    /// a-glance signal that the user should pick "Reset ASR" once
    /// they've fixed the underlying problem (typically network).
    /// Cleared again on the next `setASRReady(true)`.
    func setASRLoadFailed(_ failed: Bool) {
        asrLoadFailed = failed
        refresh()
    }

    /// AppState calls this from every `applyResult` to surface or
    /// clear a cleanup-failure indicator. Non-nil message →
    /// amber-bar icon + "⚠ Cleanup failed — <message>" menu item
    /// visible; nil → cleared. Quick mode is the primary
    /// motivating case (no overlay to surface the failure inline),
    /// but firing in normal mode too means a successful subsequent
    /// dictation automatically clears any leftover badge. The
    /// message text matches what the overlay's `awaitingAccept`
    /// decoration shows in normal mode, so users get consistent
    /// recovery hints regardless of which surface delivers them
    /// (#28).
    func setCleanupFailure(_ message: String?) {
        let oldHadFailure = cleanupFailureMessage != nil
        cleanupFailureMessage = message
        cleanupFailureMenuItem.title = message.map { "⚠ Cleanup failed — \($0)" } ?? ""
        cleanupFailureMenuItem.isHidden = (message == nil)
        // Only re-render the icon when the failure-state boolean
        // actually changed — flipping isHidden on the menu item is
        // cheap, but redrawing the icon is wasteful otherwise.
        if oldHadFailure != (message != nil) {
            refresh()
        }
    }

    private var currentPhase: AppState.Phase = .idle
    private var asrReady: Bool = true
    private var asrLoadFailed: Bool = false
    /// Latest cleanup-failure message from the most recent
    /// `applyResult` in AppState (any mode — quick or overlay).
    /// Drives the amber-bar status icon + the dismissable
    /// "⚠ Cleanup failed — …" menu item. Cleared on the next
    /// successful cleanup or when the user clicks the row. nil = no
    /// badge shown.
    private var cleanupFailureMessage: String?

    private func refresh() {
        if asrLoadFailed {
            applyInitializingIcon()
            statusMenuItem.title = "Status: Speech model failed to load"
            statusItem.button?.toolTip =
                "Parleq couldn't load the speech model (network, disk, " +
                "or sandbox issue). Pick “Reset ASR” to retry once " +
                "the underlying issue is resolved."
            return
        }
        if !asrReady {
            applyInitializingIcon()
            statusMenuItem.title = "Status: Initializing speech model…"
            // First-launch tooltip is the only at-a-glance signal a
            // tester gets that the app is busy rather than broken —
            // they wouldn't click the menu bar icon to see the
            // dropdown text. Cleared once ready.
            statusItem.button?.toolTip =
                "Parleq is initializing the speech model. " +
                "First launch downloads ~150 MB and typically takes 30–60 s; " +
                "subsequent launches are <5 s."
            return
        }
        let isActive: Bool
        let label: String
        switch currentPhase {
        case .idle:
            isActive = false
            label = "Idle"
        case .capturing:
            isActive = true
            label = "Listening…"
        case .cleaning:
            isActive = true
            label = "Processing…"
        case .awaitingAccept:
            isActive = true
            label = "Ready — tap ⌥ to accept"
        case .refining:
            isActive = true
            label = "Refining…"
        case .pasting:
            isActive = true
            label = "Pasting…"
        }
        applyIcon(active: isActive)
        statusMenuItem.title = "Status: \(label)"
        // Surface the active microphone in the tooltip so a hover
        // over the menu-bar icon answers "what mic is Parleq
        // listening on?" without opening the dropdown. The overlay
        // carries the same info during dictation; the tooltip
        // backstops at-rest. We deliberately don't fall back to
        // a generic "Parleq" label when no mic is resolvable —
        // a nil tooltip just means no hover-text, which is fine.
        let micName = effectiveMicrophoneName(forExplicitUID: currentMicrophoneUID)
        statusItem.button?.toolTip = micName.map { "Microphone: \($0)" }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func applyIcon(active: Bool) {
        statusItem.button?.image = Self.barIcon(
            active: active,
            cleanupFailed: cleanupFailureMessage != nil
        )
    }

    /// Render the 5-bar brand mark as an `NSImage`. The mark is the
    /// same shape the favicon and the wordmark lockup carry — drawn
    /// here in monochrome on transparent (or amber when cleanup has
    /// failed) so it sits cleanly against any menu bar background.
    ///
    /// Three states:
    ///   - Idle: bars at the favicon's rhythm (20/36/48/30/42
    ///     normalized), template-tinted by AppKit.
    ///   - Active: bars in a peak shape with the tallest bar in the
    ///     center, signalling "listening / capturing audio."
    ///     Template-tinted.
    ///   - Cleanup failed: bars rendered in NSColor.systemOrange and
    ///     non-template so the color sticks regardless of menu bar
    ///     appearance. Distinct-at-a-glance signal that LLM cleanup
    ///     stopped working — the user typically discovers the cause
    ///     by clicking the menu, where a "⚠ Cleanup failed — <hint>"
    ///     row carries the full recovery message.
    ///
    /// Drawn via NSImage(size:flipped:drawingHandler:) so AppKit
    /// re-rasterizes on demand at the target backing scale — crisp
    /// on Retina without shipping @2x assets.
    private static func barIcon(active: Bool, cleanupFailed: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let barCount: CGFloat = 5
            let totalWidth = barCount * barWidth + (barCount - 1) * gap // 14
            let xStart = (rect.width - totalWidth) / 2
            let yMidline = rect.height / 2

            // Heights chosen so each pair shares the favicon's
            // asymmetric rhythm (idle) or telescopes to a centered
            // peak (active). All values fit in the 14pt usable
            // vertical band (1pt padding top/bottom from the 18pt
            // canvas), so the icon optically lines up with adjacent
            // menu-bar items.
            let heights: [CGFloat] = active
                ? [8, 10, 14, 10, 8]
                : [5, 9, 14, 7, 11]

            // Cleanup-failed state breaks out of template-image
            // rendering so the amber tint reads as a deliberate
            // warning rather than the system tinting the bars to
            // black/white. Picked systemOrange (not systemRed) to
            // signal "needs attention" without implying the app is
            // broken — dictation still works, just cleanup is off.
            let fillColor: NSColor = cleanupFailed
                ? .systemOrange
                : .black  // template — AppKit retints in idle/active
            fillColor.setFill()

            for (i, h) in heights.enumerated() {
                let x = xStart + CGFloat(i) * (barWidth + gap)
                let y = yMidline - h / 2
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                )
                bar.fill()
            }
            return true
        }
        // Template only when the bars are the regular monochrome
        // version — the cleanup-failed amber should bypass AppKit's
        // auto-tint to preserve the warning color.
        image.isTemplate = !cleanupFailed
        image.accessibilityDescription = cleanupFailed
            ? "Parleq — cleanup failed"
            : "Parleq"
        return image
    }

    /// Distinct glyph while `LocalASR` is still loading the model —
    /// visually different enough from the idle bars that a tester
    /// glancing at the menu bar can tell the app isn't ready yet
    /// without having to click the icon to read the status.
    /// `arrow.down.circle.dotted` reads as "downloading" while
    /// matching the toolbar's monochrome aesthetic.
    private func applyInitializingIcon() {
        let image = NSImage(
            systemSymbolName: "arrow.down.circle.dotted",
            accessibilityDescription: "Parleq — initializing speech model"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}

// MARK: - Recent Dictations submenu

extension MenuBar: NSMenuDelegate {
    /// Rebuild the Recent Dictations submenu before AppKit shows
    /// it. Newest entry on top; each item carries the entry as
    /// its representedObject so the click handler can pull the
    /// full text without indexing back into the history. A
    /// "Clear" item appears at the bottom when the buffer is
    /// non-empty; an "(empty)" placeholder appears otherwise so
    /// the submenu still hints what it would contain.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === microphoneSubmenu {
            rebuildMicrophoneSubmenu(menu)
            return
        }
        guard menu === recentSubmenu else { return }
        menu.removeAllItems()
        let entries = TranscriptHistory.shared.entries
        if entries.isEmpty {
            let placeholder = NSMenuItem(
                title: "(no dictations yet)",
                action: nil,
                keyEquivalent: ""
            )
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }
        let now = Date()
        for entry in entries {
            let when = relativeFormatter.localizedString(
                for: entry.timestamp, relativeTo: now
            )
            // Entries where LLM cleanup failed get a trailing "· raw"
            // marker (#27) so users can tell at a glance which
            // dictations are the raw-ASR fallback rather than the
            // cleaned-up version. Tooltip spells it out for users
            // who don't recognise the marker yet.
            let title: String
            if entry.wasCleanupSuccessful {
                title = "\(entry.preview)  ·  \(when)"
            } else {
                title = "\(entry.preview)  ·  \(when)  ·  raw"
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(copyRecentEntry(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.text
            // Tooltip shows the full text + target app, since long
            // dictations get truncated in the title.
            var tooltip = entry.text
            if let app = entry.targetAppName {
                tooltip += "\n\n(originally pasted into \(app))"
            }
            if !entry.wasCleanupSuccessful {
                tooltip += "\n\n(raw transcript — LLM cleanup failed " +
                    "for this dictation)"
            }
            item.toolTip = tooltip
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "Clear Recent",
            action: #selector(clearRecent),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)
    }

    /// Click handler for a recent-dictation menu item. Copies
    /// the full text to the system pasteboard; user can then
    /// ⌘V wherever they want. Doesn't auto-paste (we have no
    /// captured target at this point — the user navigated via
    /// the menu, focus is wherever they want it next).
    @objc private func copyRecentEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func clearRecent() {
        TranscriptHistory.shared.clear()
    }

    /// Build the Microphone submenu fresh on every open. Includes
    /// "System Default" at the top, separator, and one item per
    /// connected input device (sorted by name). Active selection
    /// gets a checkmark; if the saved UID doesn't match any present
    /// device we add a disabled "Selected mic disconnected"
    /// placeholder so the user notices their saved selection isn't
    /// being applied.
    private func rebuildMicrophoneSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Resolve the system default's current name so the user can
        // see what "System Default" actually points at right now —
        // their fallback isn't anonymous. Falls through to a bare
        // "System Default" title when no default input device is
        // currently available (rare; Core Audio essentially always
        // has one unless every input device has been physically
        // removed).
        let defaultTitle: String
        if let resolved = effectiveMicrophoneName(forExplicitUID: "") {
            defaultTitle = "System Default  ·  \(resolved)"
        } else {
            defaultTitle = "System Default"
        }
        let systemDefault = NSMenuItem(
            title: defaultTitle,
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        systemDefault.target = self
        systemDefault.representedObject = ""
        systemDefault.state = currentMicrophoneUID.isEmpty ? .on : .off
        menu.addItem(systemDefault)
        menu.addItem(.separator())

        let devices = availableInputDevices()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if devices.isEmpty {
            let placeholder = NSMenuItem(
                title: "(no input devices found)",
                action: nil,
                keyEquivalent: ""
            )
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for device in devices {
                let title: String
                if let label = device.transportLabel {
                    title = "\(device.name)  ·  \(label)"
                } else {
                    title = device.name
                }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.uid
                item.state = (device.uid == currentMicrophoneUID) ? .on : .off
                menu.addItem(item)
            }
        }

        // If the user previously picked a device that's now gone,
        // surface that so they understand why their selection isn't
        // taking effect today.
        let selectedIsConnected = currentMicrophoneUID.isEmpty
            || devices.contains(where: { $0.uid == currentMicrophoneUID })
        if !selectedIsConnected {
            menu.addItem(.separator())
            let warning = NSMenuItem(
                title: "Selected microphone disconnected",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            warning.toolTip = "Saved UID: \(currentMicrophoneUID)\n" +
                "Reconnect the device to use it again, or pick another option above."
            menu.addItem(warning)
        }
    }

    /// Click handler for an entry in the Microphone submenu. Reads
    /// the device UID from `representedObject` (empty string for
    /// System Default), updates the local checkmark state, fires
    /// the legacy `onMicrophoneSelected` callback for ParleqApp's
    /// recorder/config wiring, and posts
    /// `parleqMicrophoneSelectionChanged` so Settings → Audio's
    /// picker reflects the change without a separate observer.
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        // Setting currentMicrophoneUID triggers its didSet, which
        // calls refresh() to re-render the menu-bar tooltip with
        // the new mic name. Same path covers Settings → Audio
        // selection changes (they post the cross-surface notification
        // that ParleqApp.main routes back through this property).
        // Note: macOS-level default-input-device changes (e.g. user
        // unplugs AirPods while Parleq has "System Default"
        // selected) aren't observed here — that would need a
        // Core Audio property listener on
        // kAudioHardwarePropertyDefaultInputDevice. Deferred.
        currentMicrophoneUID = uid
        onMicrophoneSelected?(uid)
        NotificationCenter.default.post(
            name: .parleqMicrophoneSelectionChanged,
            object: nil,
            userInfo: ["uid": uid]
        )
    }
}
