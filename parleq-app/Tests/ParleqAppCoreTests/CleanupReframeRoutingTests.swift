import XCTest
@testable import ParleqAppCore

/// The `appendSpokenText` helper backing the append-only refinement types
/// (Refinement = Instant/Raw): the new dictation is appended to the prior text
/// rather than interpreted, so speech is never lost.
final class CleanupReframeRoutingTests: XCTestCase {

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
