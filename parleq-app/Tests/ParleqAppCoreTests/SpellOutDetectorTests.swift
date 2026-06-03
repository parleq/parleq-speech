import XCTest
@testable import ParleqAppCore

final class SpellOutDetectorTests: XCTestCase {

    func test_spaced_letters_assemble_to_proper_noun() {
        XCTAssertEqual(SpellOutDetector.candidates(in: "her name is M I R A"), ["Mira"])
    }

    func test_hyphenated_letters_assemble() {
        XCTAssertEqual(SpellOutDetector.candidates(in: "spelled M-I-R-A"), ["Mira"])
    }

    func test_period_separated_letters_assemble() {
        XCTAssertEqual(SpellOutDetector.candidates(in: "it's M. I. R. A. okay"), ["Mira"])
    }

    func test_compact_dot_separated_letters_assemble() {
        // "M.I.R.A" with no spaces is a single token; folding periods to
        // spaces lets it tokenize like "M I R A".
        XCTAssertEqual(SpellOutDetector.candidates(in: "spelled M.I.R.A here"), ["Mira"])
    }

    func test_run_shorter_than_three_is_ignored() {
        // "I a" is only 2 single letters; "I am ok" must not trip it.
        XCTAssertEqual(SpellOutDetector.candidates(in: "I a m fine"), [],
                       "A run of fewer than 3 single-letter tokens is not a spell-out")
    }

    func test_no_letters_returns_empty() {
        XCTAssertEqual(SpellOutDetector.candidates(in: "the quick brown fox"), [])
    }

    func test_multiple_runs_each_captured() {
        let result = SpellOutDetector.candidates(in: "first A B C then X Y Z")
        XCTAssertEqual(result, ["Abc", "Xyz"])
    }

    func test_empty_string_returns_empty() {
        XCTAssertEqual(SpellOutDetector.candidates(in: ""), [])
    }

    func test_digits_and_words_break_a_run() {
        // A single letter followed by a multi-char token ends the run.
        XCTAssertEqual(SpellOutDetector.candidates(in: "U R the best"), [],
                       "'U R the' — only 2 single letters before 'the' breaks it")
    }
}
