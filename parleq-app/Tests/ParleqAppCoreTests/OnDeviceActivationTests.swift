import XCTest
@testable import ParleqAppCore

/// Unit tests for `onDeviceActivationPending` (#88) — the entry-point-agnostic
/// condition behind the "Restart to start using on-device" affordance shown on
/// both the Settings card and the menu bar (wizard path).
final class OnDeviceActivationTests: XCTestCase {

    func test_pending_whenConfigLocalAndReadyButLaunchedDifferent() {
        // Wizard or Settings just enabled local; model finished downloading;
        // the live process launched on a cloud provider. → needs restart.
        XCTAssertTrue(onDeviceActivationPending(
            launchProvider: "gemini", configProvider: "local", modelReady: true))
        XCTAssertTrue(onDeviceActivationPending(
            launchProvider: "none", configProvider: "local", modelReady: true))
    }

    func test_notPending_whenAlreadyLaunchedLocal() {
        // Process already runs on-device — nothing to restart for.
        XCTAssertFalse(onDeviceActivationPending(
            launchProvider: "local", configProvider: "local", modelReady: true))
    }

    func test_notPending_whenModelNotReady() {
        // The call-to-action is gated on the model being usable — restarting
        // before the download finishes would launch local-with-no-model.
        XCTAssertFalse(onDeviceActivationPending(
            launchProvider: "gemini", configProvider: "local", modelReady: false))
    }

    func test_notPending_whenConfigNotLocal() {
        XCTAssertFalse(onDeviceActivationPending(
            launchProvider: "gemini", configProvider: "gemini", modelReady: true))
        XCTAssertFalse(onDeviceActivationPending(
            launchProvider: "local", configProvider: "gemini", modelReady: true))
    }
}
