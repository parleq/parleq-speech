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
        let r = EditDiff.singleWordReplacements(before: "Claude likes the clawed one",
                                                after: "cloud likes the Claude one")
        XCTAssertEqual(r, [
            EditDiff.WordReplacement(before: "Claude", after: "cloud", wordIndex: 0),
            EditDiff.WordReplacement(before: "clawed", after: "Claude", wordIndex: 3),
        ])
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

    func test_reorder_reports_positionwise_mismatches() {
        // A pure reorder shows up as position-wise mismatches; over the cap ⇒ nil.
        // "b a c d e" vs "a b c d e": 2 mismatches — under the cap, but each pair
        // is a (before, after) replacement that downstream validation (voiceprint
        // presence + phonetic gate) will reject. The DIFF stays mechanical.
        let r = EditDiff.singleWordReplacements(before: "b a c d e",
                                                after: "a b c d e")
        XCTAssertEqual(r?.count, 2)
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
