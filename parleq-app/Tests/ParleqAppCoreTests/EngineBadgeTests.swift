import XCTest
@testable import ParleqAppCore

/// Task 4: the header engine badge semantics. `AppState.engineBadge` maps a
/// resolved target mode → the badge shown for a fresh cleanup. The load-bearing
/// case is the no-Concord-build fallback: an Instant target with no standing
/// Concord provider pastes RAW, so the badge must read Raw (not a false Instant
/// claim), matching the provider routing.
final class EngineBadgeTests: XCTestCase {

    func test_instant_with_provider_is_instant() {
        XCTAssertEqual(AppState.engineBadge(for: .instant, hasInstantProvider: true), .instant)
    }

    /// No-Concord (public source) build: Instant falls back to raw paste, so the
    /// badge tells the truth. Guards against a false "on-device" claim.
    func test_instant_without_provider_falls_back_to_raw() {
        XCTAssertEqual(AppState.engineBadge(for: .instant, hasInstantProvider: false), .raw)
    }

    func test_raw_is_raw() {
        XCTAssertEqual(AppState.engineBadge(for: .raw, hasInstantProvider: true), .raw)
        XCTAssertEqual(AppState.engineBadge(for: .raw, hasInstantProvider: false), .raw)
    }

    /// Polished (and refine turns, which resolve to `.polished`) → no notable
    /// badge; the header keeps the interactive model picker.
    func test_polished_is_polished() {
        XCTAssertEqual(AppState.engineBadge(for: .polished, hasInstantProvider: true), .polished)
    }
}
