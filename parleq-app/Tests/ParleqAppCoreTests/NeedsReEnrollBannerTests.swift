import XCTest
@testable import ParleqAppCore

/// Unit tests for `NeedsReEnrollBanner` — the dismissible warning shown in
/// Dictionary Settings when migration discarded voiceprints that need a fresh
/// enrollment.
final class NeedsReEnrollBannerTests: XCTestCase {

    // Clear the UserDefaults key before and after each test so runs are
    // independent of app state or prior test order.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: NeedsReEnrollBanner.dismissedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NeedsReEnrollBanner.dismissedKey)
        super.tearDown()
    }

    // MARK: - UserDefaults-backed state

    func test_isDismissed_false_initially() {
        XCTAssertFalse(NeedsReEnrollBanner.isDismissed,
                       "Banner should not be dismissed on a clean key")
    }

    func test_dismiss_sets_dismissed_true() {
        NeedsReEnrollBanner.dismiss()
        XCTAssertTrue(NeedsReEnrollBanner.isDismissed,
                      "dismiss() must persist the dismissed flag")
    }

    // MARK: - Pure visibility rule

    func test_shouldShow_true_when_count_positive_and_not_dismissed() {
        XCTAssertTrue(NeedsReEnrollBanner.shouldShow(dismissed: false, needsReEnrollCount: 1))
    }

    func test_shouldShow_false_when_dismissed() {
        XCTAssertFalse(NeedsReEnrollBanner.shouldShow(dismissed: true, needsReEnrollCount: 1),
                       "Dismissed banner must stay hidden even with pending re-enrollments")
    }

    func test_shouldShow_false_when_count_zero() {
        XCTAssertFalse(NeedsReEnrollBanner.shouldShow(dismissed: false, needsReEnrollCount: 0),
                       "Banner must not show when no terms need re-enrollment")
    }

    func test_shouldShow_false_when_dismissed_and_count_zero() {
        XCTAssertFalse(NeedsReEnrollBanner.shouldShow(dismissed: true, needsReEnrollCount: 0))
    }

    // MARK: - Copy constants are non-empty

    func test_title_and_message_are_non_empty() {
        XCTAssertFalse(NeedsReEnrollBanner.title.isEmpty)
        XCTAssertFalse(NeedsReEnrollBanner.message.isEmpty)
    }
}
