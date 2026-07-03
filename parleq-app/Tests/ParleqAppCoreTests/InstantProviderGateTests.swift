import XCTest
@testable import ParleqAppCore

#if Concord

/// Task 3 regression guard (the sharpest catch of the adversarial design review):
/// the enrolled-voiceprint over-fire veto must be installed on the STANDING
/// Instant Concord instance, not just the cleanup-tier provider. A cloud-global
/// user dictating into an Instant target routes through `instantLLM`; if that
/// instance lacked the gate, the durable-voiceprints guarantee would silently
/// break on exactly that path.
///
/// `AppState.installEnrollmentGate` is the pure casting+install helper the
/// (NSPanel-requiring, un-unit-testable) `installVoiceprintEnforcement` funnels
/// through, so it can be exercised directly here.
@MainActor
final class InstantProviderGateTests: XCTestCase {

    /// The real production gate factory — installation is what's under test,
    /// not the gate's veto logic (covered by the voiceprint/enrollment suites).
    /// Sourced from the coordinator so the closure type is inferred (no need to
    /// name `AcousticGate`, which lives in the private Concord module).
    private let factory = VoiceprintCoordinator().enforcementGateFactory()

    /// The instant instance gets the gate even when the cleanup slot is a
    /// non-Concord provider (the exact cloud-global-plus-Instant case). Before
    /// the fix, `installVoiceprintEnforcement` early-returned on `llm as? Concord`
    /// failing and never touched the instant instance.
    func test_instant_instance_gated_when_cleanup_is_non_concord() {
        let instant = ConcordCleanupProvider()
        // Simulate a non-Concord cleanup tier with `nil` in the cleanup slot
        // (a cloud provider casts to `nil as? ConcordCleanupProvider` all the same).
        AppState.installEnrollmentGate(factory, on: [nil, instant])
        XCTAssertTrue(instant.hasEnrollmentGate,
                      "Instant Concord instance must receive the voiceprint gate")
    }

    /// Both standing Concord instances (cleanup + instant) get gated when the
    /// global cleanup provider is itself Concord.
    func test_both_concord_instances_gated() {
        let cleanup = ConcordCleanupProvider()
        let instant = ConcordCleanupProvider()
        AppState.installEnrollmentGate(factory, on: [cleanup, instant])
        XCTAssertTrue(cleanup.hasEnrollmentGate)
        XCTAssertTrue(instant.hasEnrollmentGate)
    }

    /// A no-Concord (public) build passes `instantLLM == nil`; the helper must
    /// no-op safely (no crash, nothing to gate).
    func test_nil_providers_are_safe_noop() {
        AppState.installEnrollmentGate(factory, on: [nil, nil])
    }
}

#endif
