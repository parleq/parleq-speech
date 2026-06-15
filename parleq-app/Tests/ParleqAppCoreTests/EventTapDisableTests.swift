import XCTest
@testable import ParleqAppCore

/// The keyboard-lockout fix: deciding what to do when macOS disables our
/// keyboard event tap. The old code re-enabled unconditionally, which on an
/// Accessibility *revoke* fought macOS back and left a keyboard-intercepting tap
/// alive that could no longer pass events → the user's keyboard locked up. The
/// rule: only re-enable on a genuine timeout while still trusted; otherwise tear
/// the tap down so the keyboard is freed.
final class EventTapDisableTests: XCTestCase {

    func testTimeoutWhileTrustedReEnables() {
        // Genuine "callback was too slow" and we still hold Accessibility →
        // re-enable so the hotkey keeps working.
        XCTAssertEqual(
            HotkeyListener.actionForTapDisabled(reason: .timeout, accessibilityTrusted: true),
            .reEnable)
    }

    func testTimeoutWhileUntrustedTearsDown() {
        // Lost Accessibility → never re-arm a tap the system revoked.
        XCTAssertEqual(
            HotkeyListener.actionForTapDisabled(reason: .timeout, accessibilityTrusted: false),
            .tearDown)
    }

    func testUserInputAlwaysTearsDown() {
        // .tapDisabledByUserInput is the system/user-disabled signal (the
        // Accessibility-revoke case). NEVER fight it back on — even if
        // AXIsProcessTrusted() momentarily still reads true (it can lag a
        // revoke). Tear down; the reconciler re-arms if we're legitimately
        // still trusted.
        XCTAssertEqual(
            HotkeyListener.actionForTapDisabled(reason: .userInput, accessibilityTrusted: true),
            .tearDown)
        XCTAssertEqual(
            HotkeyListener.actionForTapDisabled(reason: .userInput, accessibilityTrusted: false),
            .tearDown)
    }
}
