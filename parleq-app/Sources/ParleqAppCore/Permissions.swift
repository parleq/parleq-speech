// Permissions — synchronous state probes and click handlers for the
// four permissions Parleq surfaces in Settings → Permissions and in
// the Setup wizard's Permissions step: Microphone, Accessibility,
// Screen Recording (optional — only needed for Reference Windows),
// and Open at Login (optional).
//
// Each probe is a single API call that returns immediately — no async,
// no blocking, safe to call from any UI refresh cycle. The probes are
// the *read* path; the click handlers in this file are the *write*
// path (firing the OS prompt or opening System Settings to the right
// pane). PermissionsModel observes app-activation and view-appearance
// to know when to re-poll.

import AVFoundation
import AppKit
import ApplicationServices
import Combine

/// Visible state of one permission. Open at Login is the only row that
/// can report `.notSupported` — that's the SMAppService `.notFound`
/// fallback we see on unnotarized builds and during `swift run`.
enum PermissionState: Equatable {
    case granted
    case missing
    case notSupported
}

/// Snapshot of all four permissions captured at a single instant.
/// Equatable so PermissionsModel only republishes when something
/// actually changed.
struct PermissionsSnapshot: Equatable {
    let microphone: PermissionState
    let accessibility: PermissionState
    let screenRecording: PermissionState
    let openAtLogin: PermissionState
}

@MainActor
enum Permissions {

    // MARK: - State probes

    /// Wraps `AVCaptureDevice.authorizationStatus(for: .audio)`. The
    /// `.notDetermined` case is rolled into `.missing` because from
    /// the user's perspective both look the same in the row — they
    /// have to do something. The click handler differentiates them
    /// (notDetermined → fire the OS prompt; denied → open Settings).
    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        default:          return .missing
        }
    }

    /// Wraps the *non-prompting* `AXIsProcessTrusted()`. We use the
    /// prompting variant `AXIsProcessTrustedWithOptions` only from
    /// the click handler — calling it on every refresh would spam
    /// the system dialog.
    static var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .missing
    }

    /// Builds on the existing `LoginItem` helper.
    /// `.notSupported` is the SMAppService `.notFound` fallback —
    /// signed-but-unnotarized builds and `swift run` hit this. The
    /// row degrades to a "Open Login Items Settings…" button in
    /// that case so the user can register Parleq manually.
    static var openAtLogin: PermissionState {
        guard LoginItem.isSupported else { return .notSupported }
        return LoginItem.isEnabled ? .granted : .missing
    }

    /// Wraps `CGPreflightScreenCaptureAccess()`. Screen Recording is
    /// surfaced in Settings → Permissions as an *optional* row (only
    /// required for Reference Windows). Like microphone, the OS state
    /// is a binary "granted vs not" — TCC doesn't distinguish
    /// notDetermined from denied here, and the click handler treats
    /// both as "fire request + open Settings" since
    /// `CGRequestScreenCaptureAccess()` is a one-shot.
    static var screenRecordingState: PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .missing
    }

    /// Convenience snapshot. Four synchronous calls — cheap to call
    /// on every UI refresh.
    static var snapshot: PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: microphone,
            accessibility: accessibility,
            screenRecording: screenRecordingState,
            openAtLogin: openAtLogin
        )
    }

    // MARK: - Click handlers

    /// Click handler for the Microphone row's primary action. Routes
    /// based on the *current* authorization status — must be read
    /// fresh, because the snapshot in the row's view may be slightly
    /// stale on the moment of click.
    ///
    /// - `.notDetermined` → `AVCaptureDevice.requestAccess` fires the
    ///   system "Parleq would like to access the microphone" prompt.
    ///   Result is ignored; PermissionsModel picks up the new state
    ///   on the next `didBecomeActive`.
    /// - `.denied` / `.restricted` → the OS does not re-prompt after a
    ///   prior denial, so we route the user directly to the relevant
    ///   System Settings pane.
    /// - `.authorized` → no-op (the row's button should already be
    ///   disabled, but defending against a stale click).
    static func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // The TCC microphone prompt is an in-process alert
                // that doesn't reliably round-trip the app through
                // resignActive/becomeActive on every macOS version,
                // so we can't depend on PermissionsModel's
                // didBecomeActive observer to refresh after this.
                // Refresh explicitly from the completion so the row
                // flips to green the moment the user clicks "Allow".
                Task { @MainActor in
                    PermissionsModel.shared.refresh()
                }
            }
        case .denied, .restricted:
            openSystemSettings(privacyPane: "Privacy_Microphone")
        case .authorized:
            return
        @unknown default:
            openSystemSettings(privacyPane: "Privacy_Microphone")
        }
    }

    /// Click handler for the Accessibility row's primary action. Two
    /// stacked behaviors:
    ///
    /// 1. `AXIsProcessTrustedWithOptions` with prompt = true. macOS
    ///    shows its standard "Parleq would like to control this
    ///    computer using accessibility features" dialog, which itself
    ///    has an "Open System Settings" button. We let the user
    ///    choose to dismiss or open from that dialog.
    /// 2. Belt-and-suspenders: also open the Accessibility pane
    ///    directly so the user lands on the right place even if
    ///    they dismissed the dialog or are on a macOS revision where
    ///    the dialog doesn't appear (e.g. when the process is already
    ///    listed as untrusted from a prior session).
    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSystemSettings(privacyPane: "Privacy_Accessibility")
    }

    /// Click handler for the Open at Login row's primary action. The
    /// row's button label changes per state — this function applies
    /// the inverse of the current state when supported, and falls
    /// back to the manual System Settings flow otherwise.
    ///
    /// Special case: when SMAppService is `.requiresApproval` (user
    /// previously called `.register()` but hasn't approved in System
    /// Settings yet), `isEnabled` returns false. Re-registering here
    /// would be a no-op — what the user actually needs is the System
    /// Settings → Login Items pane open so they can flip the toggle.
    static func toggleOpenAtLogin() {
        guard LoginItem.isSupported else {
            LoginItem.openLoginItemsSettings()
            return
        }
        if LoginItem.requiresApproval {
            LoginItem.openLoginItemsSettings()
            return
        }
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            // SMAppService rejected the call — log and fall back to
            // the manual settings page so the user has a recovery
            // path. Common cause: user previously revoked approval.
            logStderr("[parleq] permissions: setEnabled failed: \(error)")
            LoginItem.openLoginItemsSettings()
        }
    }

    // MARK: - System Settings deep-links

    /// Open System Settings directly to the Microphone Privacy pane.
    /// Used by the `.notSupported` row branch and by power users who
    /// want to revoke without going through Parleq's TCC request
    /// pathway.
    static func openMicrophoneSettings() {
        openSystemSettings(privacyPane: "Privacy_Microphone")
    }

    /// Open System Settings directly to the Accessibility Privacy
    /// pane. Same role as `openMicrophoneSettings` for Accessibility.
    static func openAccessibilitySettings() {
        openSystemSettings(privacyPane: "Privacy_Accessibility")
    }

    // MARK: - Screen Recording (Reference Windows)
    //
    // Screen Recording is required by Reference Windows. It's surfaced
    // in Settings → Permissions and the Setup wizard as an *optional*
    // row (the pill reads "Optional", not "Required") since users who
    // don't use Reference Windows don't need it. The runtime path
    // (`AppState.captureReferenceWindow`) also fires the OS prompt
    // lazily on first capture attempt, so users who skip the row in
    // Settings still get the just-in-time grant flow.

    /// True if Screen Recording is currently granted. False covers both
    /// "not yet determined" and "denied" — the request handler
    /// distinguishes them.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Fire the system Screen Recording prompt (the first time) or
    /// surface a no-op (subsequent calls after prior denial — macOS
    /// won't re-prompt for this permission, the user must go to
    /// System Settings). Returns `true` if access is granted by the
    /// time the call returns; in practice the first-time flow always
    /// returns `false` and the user's grant lands asynchronously
    /// after they click Allow.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings directly to the Screen Recording Privacy
    /// pane. Use after a prior denial, when CGRequestScreenCaptureAccess
    /// won't re-prompt.
    static func openScreenRecordingSettings() {
        openSystemSettings(privacyPane: "Privacy_ScreenCapture")
    }

    /// Open System Settings directly to a specific Privacy & Security
    /// sub-pane. `pane` is the suffix that comes after
    /// `com.apple.preference.security?` — e.g. `Privacy_Microphone`,
    /// `Privacy_Accessibility`. Falls back to opening the top-level
    /// Privacy page if the deep link is unreachable.
    private static func openSystemSettings(privacyPane pane: String) {
        let deepLink = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: deepLink), NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(fallback)
        }
    }
}

/// Observes app-activation and snapshot changes so SwiftUI views can
/// rebind whenever the underlying permission state shifts. One shared
/// instance is enough — the snapshot is global, not per-view.
///
/// Refresh triggers:
///   1. `NSApplication.didBecomeActiveNotification` — covers the
///      dominant path where the user clicks "Allow…", switches to
///      System Settings, toggles a switch, ⌘-tabs back.
///   2. Explicit `refresh()` calls from `.onAppear` in the consumer
///      view, so a user who flips a permission while Parleq is
///      already frontmost (e.g. via the menu-bar app icon → Settings
///      shortcut, without a deactivate roundtrip) still sees fresh
///      state on the next view appearance.
@MainActor
final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var snapshot: PermissionsSnapshot = Permissions.snapshot

    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor — Notification Center delivers on the
            // main queue but the closure isn't statically isolated.
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    // No deinit: this is a `static let shared` singleton with a
    // process-lifetime retain, so `activationObserver` is held for the
    // life of the app. Adding a deinit would force the cleanup off
    // MainActor (where the observer was registered) and run into
    // Swift 6 isolation rules for non-Sendable NSObjectProtocol.

    /// Re-poll all three probes and republish only if something
    /// actually changed. `@Published` itself fires on every set —
    /// it does NOT Equatable-dedup — so the explicit guard here
    /// matters: a screen sitting idle with no permission changes
    /// won't get spurious objectWillChange traffic when the user
    /// ⌘-tabs in and out repeatedly.
    func refresh() {
        let next = Permissions.snapshot
        if next != snapshot {
            snapshot = next
        }
    }
}

// File-scoped logger so this file doesn't have to depend on the
// file-private `logStderr` in AudioRecorder/ParleqApp. Same shape and
// `[parleq]` prefix for grep parity in the combined log.
private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
