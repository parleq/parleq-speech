import XCTest
@testable import ParleqAppCore

/// Phase B of the cleanup provider/level reframe: the two pure routing helpers
/// that back the live dictation path.
///   - `effectiveCleanupMode`: degrades a FRESH Polished turn to Instant when
///     no Polished provider is configured (concord/none global) — Polished
///     cleanup never silently falls to a cloud call it can't make; it cleans
///     on-device instead.
///   - `appendSpokenText`: the append-only refine join used when a refine turn
///     has no Polished (refine-capable) provider — the spoken words are
///     appended to the prior text instead of interpreted, so speech is never
///     lost.
final class CleanupReframeRoutingTests: XCTestCase {

    // MARK: - effectiveCleanupMode (fresh-turn Polished → Instant degradation)

    func test_polished_degrades_to_instant_without_provider() {
        XCTAssertEqual(
            AppState.effectiveCleanupMode(behaviorMode: .polished, hasPolishedProvider: false),
            .instant)
    }

    func test_polished_stays_polished_with_provider() {
        XCTAssertEqual(
            AppState.effectiveCleanupMode(behaviorMode: .polished, hasPolishedProvider: true),
            .polished)
    }

    func test_instant_and_raw_pass_through_unchanged() {
        for hasProvider in [true, false] {
            XCTAssertEqual(
                AppState.effectiveCleanupMode(behaviorMode: .instant, hasPolishedProvider: hasProvider),
                .instant)
            XCTAssertEqual(
                AppState.effectiveCleanupMode(behaviorMode: .raw, hasPolishedProvider: hasProvider),
                .raw)
        }
    }

    // MARK: - appendSpokenText (append-only refine join)

    func test_append_joins_with_single_space() {
        XCTAssertEqual(AppState.appendSpokenText("world", to: "hello"), "hello world")
    }

    func test_append_does_not_double_space() {
        XCTAssertEqual(AppState.appendSpokenText("world", to: "hello "), "hello world")
    }

    func test_append_after_newline_adds_no_space() {
        XCTAssertEqual(AppState.appendSpokenText("world", to: "hello\n"), "hello\nworld")
    }

    func test_append_trims_spoken_and_ignores_empty() {
        XCTAssertEqual(AppState.appendSpokenText("  more words  ", to: "prior"), "prior more words")
        XCTAssertEqual(AppState.appendSpokenText("   ", to: "prior"), "prior")
    }

    func test_append_onto_empty_prior_is_just_spoken() {
        XCTAssertEqual(AppState.appendSpokenText("hello", to: ""), "hello")
    }
}
