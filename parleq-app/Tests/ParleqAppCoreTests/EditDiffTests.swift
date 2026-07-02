// EditDiffTests — Task 5: conservative 1:1 word-replacement diff for E-edits.

import XCTest
@testable import ParleqAppCore

#if Concord

final class EditDiffTests: XCTestCase {

    func test_single_replacement_found() {
        let r = EditDiff.singleWordReplacements(before: "use Claude here",
                                                after: "use cloud here")
        XCTAssertEqual(r, [EditDiff.WordReplacement(before: "Claude", after: "cloud", wordIndex: 1)])
    }

    func test_two_replacements_ok() {
        let r = EditDiff.singleWordReplacements(before: "use Claude and Parlek here",
                                                after: "use cloud and Parleq here")
        XCTAssertEqual(r, [
            EditDiff.WordReplacement(before: "Claude", after: "cloud", wordIndex: 1),
            EditDiff.WordReplacement(before: "Parlek", after: "Parleq", wordIndex: 3),
        ])
    }

    func test_confusable_swap_returns_nil() {
        // A swap of two confusable words is a REORDER, not a mishear correction —
        // its (Claude → cloud) pair carries TRUE term audio and would poison the
        // voiceprint (RoboRev-7508).
        XCTAssertNil(EditDiff.singleWordReplacements(before: "Claude cloud",
                                                     after: "cloud Claude"))
    }

    func test_changed_after_matching_changed_before_elsewhere_returns_nil() {
        // One legit-looking pair + one pair whose after re-uses a changed before
        // word — smells like a move; the whole edit is rejected (zero-junk).
        XCTAssertNil(EditDiff.singleWordReplacements(before: "Claude likes the clawed one",
                                                     after: "cloud likes the Claude one"))
    }

    func test_case_only_change_returns_nil() {
        // Core-identical before/after (case fix) is a self-edit, never a harvest.
        XCTAssertNil(EditDiff.singleWordReplacements(before: "use Claude here",
                                                     after: "use claude here"))
    }

    func test_three_replacements_at_cap_ok() {
        let r = EditDiff.singleWordReplacements(before: "a b c d",
                                                after: "x y z d")
        XCTAssertEqual(r?.count, 3)
    }

    func test_four_replacements_over_cap_nil() {
        XCTAssertNil(EditDiff.singleWordReplacements(before: "a b c d",
                                                     after: "w x y z"),
                     "4 mismatches is a rewrite, not a hand-fix")
    }

    func test_insert_changes_word_count_nil() {
        XCTAssertNil(EditDiff.singleWordReplacements(before: "use Claude here",
                                                     after: "use the Claude here"))
    }

    func test_delete_changes_word_count_nil() {
        XCTAssertNil(EditDiff.singleWordReplacements(before: "use Claude here",
                                                     after: "use here"))
    }

    func test_adjacent_reorder_returns_nil() {
        // A pure reorder swaps changed words position-wise — the reorder guard
        // rejects the whole edit (RoboRev-7508).
        XCTAssertNil(EditDiff.singleWordReplacements(before: "b a c d e",
                                                     after: "a b c d e"))
    }

    func test_identical_strings_empty() {
        XCTAssertEqual(EditDiff.singleWordReplacements(before: "same text",
                                                       after: "same text"), [])
    }

    func test_whitespace_only_change_empty() {
        XCTAssertEqual(EditDiff.singleWordReplacements(before: "same  text",
                                                       after: "same text"), [])
    }

    func test_replacement_preserves_verbatim_words_with_affixes() {
        let r = EditDiff.singleWordReplacements(before: "ask Claude, please",
                                                after: "ask cloud, please")
        XCTAssertEqual(r, [EditDiff.WordReplacement(before: "Claude,", after: "cloud,", wordIndex: 1)])
    }
}
#endif
