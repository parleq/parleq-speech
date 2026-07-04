// HarvestRefinementNoticeTests — pure gating for the one-time 0.41.0 upgrade
// notice that tells EXISTING enrollees corrections now refine their voiceprints.

import XCTest
@testable import ParleqAppCore

#if Concord

final class HarvestRefinementNoticeTests: XCTestCase {
    private typealias N = HarvestRefinementNotice

    func test_fresh_install_is_silent_regardless() {
        // Wizard not completed ⇒ onboards with the feature + enrollment-card
        // disclosure; never notified, whatever else is true.
        XCTAssertEqual(N.decide(wizardCompleted: false, showingWizard: false,
                                perAppNoticeSeen: true, hasEnrolledVoiceprints: true),
                       .markSeenSilently)
        XCTAssertEqual(N.decide(wizardCompleted: false, showingWizard: true,
                                perAppNoticeSeen: false, hasEnrolledVoiceprints: false),
                       .markSeenSilently)
    }

    func test_existing_enrollee_clear_to_show() {
        XCTAssertEqual(N.decide(wizardCompleted: true, showingWizard: false,
                                perAppNoticeSeen: true, hasEnrolledVoiceprints: true),
                       .show)
    }

    func test_existing_user_without_voiceprints_is_silent() {
        // Nothing to disclose yet; they'll see the enrollment-card disclosure if
        // they enroll later.
        XCTAssertEqual(N.decide(wizardCompleted: true, showingWizard: false,
                                perAppNoticeSeen: true, hasEnrolledVoiceprints: false),
                       .markSeenSilently)
    }

    func test_defers_while_wizard_is_showing() {
        // Don't stack modals — retry next launch (flag stays unset).
        XCTAssertEqual(N.decide(wizardCompleted: true, showingWizard: true,
                                perAppNoticeSeen: true, hasEnrolledVoiceprints: true),
                       .wait)
    }

    func test_defers_until_perApp_notice_handled() {
        // The per-app-modes notice hasn't been seen yet (it may fire this launch),
        // so defer to avoid two modals in one launch.
        XCTAssertEqual(N.decide(wizardCompleted: true, showingWizard: false,
                                perAppNoticeSeen: false, hasEnrolledVoiceprints: true),
                       .wait)
    }
}
#endif
