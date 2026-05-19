// PasteTargetTracker — observes NSWorkspace's frontmost-app
// notifications and tracks the currently-frontmost non-Parleq app
// as the paste destination.
//
// Parleq's own activations (e.g., when the user clicks the overlay
// or the + button) are filtered out so the chip doesn't flicker.
//
// The current target is exposed as @Published so the overlay
// chip view re-renders automatically.

import AppKit
import Combine

@MainActor
final class PasteTargetTracker: ObservableObject {
    @Published private(set) var current: PasteDestination?

    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let selfBundleID: String

    init() {
        // Real bundle ID per Info.plist; the fallback only matters if
        // Bundle.main.bundleIdentifier somehow returns nil (won't
        // happen in a real .app bundle, but keep the real value here
        // so the self-filter remains correct in test/preview contexts).
        self.selfBundleID = Bundle.main.bundleIdentifier ?? "com.parleq.app"
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            // Notification is already on the main queue (queue: .main),
            // so handle synchronously — wrapping in Task { @MainActor }
            // re-queues onto the main run loop and can reorder rapid
            // app-switch events. Use assumeIsolated to satisfy the
            // @MainActor isolation requirement without a hop.
            MainActor.assumeIsolated {
                self.handleActivation(app)
            }
        }

        // Seed with the currently-frontmost app, if not us.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != selfBundleID {
            current = makeTarget(from: app)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != selfBundleID else {
            return
        }
        current = makeTarget(from: app)
    }

    private func makeTarget(from app: NSRunningApplication) -> PasteDestination {
        PasteDestination(
            bundleID: app.bundleIdentifier ?? "unknown",
            appName: app.localizedName ?? "App",
            windowTitle: nil,  // Phase 2: AX query for focused window title
            appIcon: app.icon
        )
    }
}
