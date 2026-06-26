// VoiceEnrollDiscovery — discoverability surfaces for the marquee voice-
// enrollment feature (Concord builds). Two pieces:
//
//   • VoiceEnrollBanner — one-time, dismissible "new feature" callouts,
//     backed by UserDefaults flags. Mirrors LearnBanner's pattern (a
//     first-run-until-dismissed nudge, not version-gated). Two independent
//     surfaces share nothing but the pattern:
//       – the Recent landing "what's new" banner (CTA → Settings → Dictionary)
//       – the Dictionary settings section intro banner
//
//   • VoiceEnrollNudge — an in-memory, process-lifetime store for the
//     contextual "this dictionary term over-fired — enroll your voice to
//     fix it" suggestion. Set by AppState when the user UNDOES a
//     dictionary-stage correction for a term that has no voiceprint yet;
//     read by the Dictionary settings section. Concord-only (voiceprints
//     don't exist in the public build).
//
// The banner enum is always compiled (its key constants are referenced by
// the always-compiled RecentDictationsView via @AppStorage), so it lives
// outside the #if Concord guard; the nudge store is Concord-only.

import Foundation

/// One-time, dismissible discovery banners for voice enrollment. Pure
/// visibility rules are unit-test friendly; persisted state lives in
/// UserDefaults under stable keys also referenced via @AppStorage so the
/// SwiftUI surfaces re-render on dismiss.
enum VoiceEnrollBanner {
    /// Recent-landing "what's new" banner dismissed flag.
    static let appBannerDismissedKey = "parleq.voiceEnrollBanner.appDismissed"
    /// Dictionary-section intro banner dismissed flag.
    static let sectionBannerDismissedKey = "parleq.voiceEnrollBanner.sectionDismissed"

    static var appBannerDismissed: Bool {
        UserDefaults.standard.bool(forKey: appBannerDismissedKey)
    }

    static func dismissAppBanner() {
        UserDefaults.standard.set(true, forKey: appBannerDismissedKey)
    }

    static var sectionBannerDismissed: Bool {
        UserDefaults.standard.bool(forKey: sectionBannerDismissedKey)
    }

    static func dismissSectionBanner() {
        UserDefaults.standard.set(true, forKey: sectionBannerDismissedKey)
    }

    /// Show the Recent-landing "what's new" banner while not dismissed.
    static func shouldShowInApp(dismissed: Bool) -> Bool { !dismissed }
}

#if Concord
import Combine

/// In-memory, process-lifetime store for the contextual "this dictionary
/// term over-fired — enroll your voice to fix it" nudge.
///
/// Privacy: the term + confused word are dictation-derived; they live in
/// process memory only (never logged, never written to disk), matching the
/// in-memory-only correction-signal invariants. Cleared on quit and when the
/// term gets a voiceprint (or the user dismisses the nudge).
@MainActor
public final class VoiceEnrollNudge: ObservableObject {
    public static let shared = VoiceEnrollNudge()
    private init() {}

    public struct Suggestion: Equatable {
        public let term: String
        public let confusedWith: String
    }

    @Published public private(set) var pending: Suggestion?

    /// Record (or replace) the one-shot suggestion for `term`. No-op for a
    /// blank term.
    public func suggest(term: String, confusedWith: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        pending = Suggestion(
            term: t,
            confusedWith: confusedWith.trimmingCharacters(in: .whitespaces)
        )
    }

    public func clear() { pending = nil }

    /// Clear the pending suggestion if it targets `term` (case-insensitive) —
    /// e.g. once the term gets a voiceprint, the nudge is moot.
    public func clearIfMatches(term: String) {
        let t = term.trimmingCharacters(in: .whitespaces).lowercased()
        if pending?.term.lowercased() == t { pending = nil }
    }
}
#endif
