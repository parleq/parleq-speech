import XCTest
@testable import ParleqAppCore

/// Pure launch-time permission decisions for #82 — deferring the Accessibility
/// prompt to the wizard and never exiting the app when it's missing. The CGEventTap
/// install + PermissionsModel observation are wired in main.swift and verified in
/// the manual walkthrough; the branching logic is pure and tested here.
final class LaunchPermissionsTests: XCTestCase {

    // MARK: show the wizard at launch?

    func testWizardShownOnFreshInstall() {
        // Never completed the wizard → show it (existing behavior).
        XCTAssertTrue(LaunchPermissions.shouldShowWizardAtLaunch(
            wizardCompleted: false, accessibilityGranted: true))
    }

    func testWizardShownWhenAccessibilityMissingEvenIfCompleted() {
        // #82: a returning user whose Accessibility was revoked needs the
        // explained re-grant step, not a silent dead hotkey.
        XCTAssertTrue(LaunchPermissions.shouldShowWizardAtLaunch(
            wizardCompleted: true, accessibilityGranted: false))
    }

    func testWizardNotShownWhenCompletedAndGranted() {
        XCTAssertFalse(LaunchPermissions.shouldShowWizardAtLaunch(
            wizardCompleted: true, accessibilityGranted: true))
    }

    // MARK: arm the hotkey listener now, or wait?

    func testArmWhenGrantedAndNotYetArmed() {
        XCTAssertEqual(
            LaunchPermissions.armingDecision(armed: false, accessibilityGranted: true), .arm)
    }

    func testWaitWhenMissing() {
        // #82: do NOT exit(1) — wait for the grant instead.
        XCTAssertEqual(
            LaunchPermissions.armingDecision(armed: false, accessibilityGranted: false),
            .waitForAccessibility)
    }

    func testNoReArmWhenAlreadyArmed() {
        // Re-grant events must not install a second event tap.
        XCTAssertEqual(
            LaunchPermissions.armingDecision(armed: true, accessibilityGranted: true), .alreadyArmed)
        XCTAssertEqual(
            LaunchPermissions.armingDecision(armed: true, accessibilityGranted: false), .alreadyArmed)
    }
}
