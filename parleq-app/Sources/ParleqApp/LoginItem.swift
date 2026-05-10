// LoginItem — toggle Parleq's "Open at login" registration via the
// modern macOS API.
//
// macOS 13+ exposes SMAppService.mainApp for this. Calling
// .register() adds Parleq to the user's Login Items list (visible
// in System Settings → General → Login Items), and macOS may show
// an approval prompt the first time. The .status property reflects
// current registration so we can render a checkmark in the menu.
//
// Notes:
//   - Only works when Parleq is launched from a .app bundle. In dev
//     mode (`swift run`), SMAppService.mainApp is a no-op (status
//     stays .notFound). The menu item is hidden in that case so we
//     don't surface a non-functional toggle.
//   - Registration persists in user state, not in our code. macOS
//     remembers it across restarts even if we don't call register
//     again.
//   - Unregistering returns the user to a clean state — System
//     Settings won't list Parleq anymore.

import AppKit
import ServiceManagement

@MainActor
enum LoginItem {
    /// True when Parleq is registered as a Login Item AND macOS has
    /// approved the registration (i.e., it'll actually launch at
    /// login). False when not registered, when approval is pending,
    /// or when we're not running from a .app bundle.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when SMAppService can manage the current process. False
    /// in two important cases:
    ///   - dev mode (swift run): no .app bundle for the service to
    ///     attach to.
    ///   - signed with Apple Development (free) instead of Developer
    ///     ID Application: Gatekeeper rejects the app for execution
    ///     trust, and SMAppService follows the same trust model and
    ///     returns .notFound.
    /// In the second case the menu falls back to "Open Login Items
    /// in System Settings…" so the user can add Parleq manually.
    static var isSupported: Bool {
        SMAppService.mainApp.status != .notFound
    }

    /// Toggle registration. Throws if SMAppService rejects the call.
    /// macOS may show an approval dialog on first registration; the
    /// status property goes through .requiresApproval first if that
    /// happens.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    /// Open System Settings → General → Login Items so the user can
    /// add Parleq via the + button. Used as a fallback when the
    /// auto-registration path is blocked (Apple Development cert vs
    /// the Developer ID required for full SMAppService trust).
    static func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    /// Diagnostic — current status as a human-readable string.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown(\(SMAppService.mainApp.status.rawValue))"
        }
    }
}
