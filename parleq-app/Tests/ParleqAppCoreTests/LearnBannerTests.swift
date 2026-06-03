import XCTest
@testable import ParleqAppCore

final class LearnBannerTests: XCTestCase {

    // MARK: - App banner

    func test_app_shows_when_off_and_not_dismissed() {
        XCTAssertTrue(LearnBanner.shouldShowInApp(dismissed: false, featureEnabled: false))
    }

    func test_app_hidden_when_dismissed() {
        XCTAssertFalse(LearnBanner.shouldShowInApp(dismissed: true, featureEnabled: false))
    }

    func test_app_hidden_when_feature_enabled() {
        XCTAssertFalse(LearnBanner.shouldShowInApp(dismissed: false, featureEnabled: true),
                       "Discovery is done once the feature is on — hide it")
    }

    func test_app_hidden_when_mdm_managed() {
        XCTAssertFalse(LearnBanner.shouldShowInApp(dismissed: false, featureEnabled: false, managed: true),
                       "When MDM pins the flag the user can't change it — don't nag")
    }

    func test_overlay_hidden_when_mdm_managed() {
        XCTAssertFalse(LearnBanner.shouldShowInOverlay(
            dismissed: false, featureEnabled: false, firstShownAt: nil, now: 1000, managed: true))
    }

    // MARK: - Overlay line

    func test_overlay_shows_before_first_shown() {
        XCTAssertTrue(LearnBanner.shouldShowInOverlay(
            dismissed: false, featureEnabled: false, firstShownAt: nil, now: 1000))
    }

    func test_overlay_shows_within_window() {
        XCTAssertTrue(LearnBanner.shouldShowInOverlay(
            dismissed: false, featureEnabled: false,
            firstShownAt: 1000, now: 1000 + 86_399, windowSeconds: 86_400))
    }

    func test_overlay_hidden_after_window() {
        XCTAssertFalse(LearnBanner.shouldShowInOverlay(
            dismissed: false, featureEnabled: false,
            firstShownAt: 1000, now: 1000 + 86_400, windowSeconds: 86_400),
            "After the 24h window the overlay line stops on its own")
    }

    func test_overlay_hidden_when_dismissed() {
        XCTAssertFalse(LearnBanner.shouldShowInOverlay(
            dismissed: true, featureEnabled: false, firstShownAt: nil, now: 1000))
    }

    func test_overlay_hidden_when_feature_enabled() {
        XCTAssertFalse(LearnBanner.shouldShowInOverlay(
            dismissed: false, featureEnabled: true, firstShownAt: nil, now: 1000))
    }
}
