// HarvestSpanLocatorTests — Task 4: pure ordinal math + consistency guard.
//
// The locator maps a corrected word (undo span / E-edit word) to its raw-ASR
// word-group ordinal. Zero-junk: ANY count mismatch returns nil (skip harvest).

import XCTest
@testable import ParleqAppCore

#if Concord

final class HarvestSpanLocatorTests: XCTestCase {

    // MARK: - core()

    func test_core_strips_affixes_and_lowercases() {
        XCTAssertEqual(HarvestSpanLocator.core("Cloud,"), "cloud")
        XCTAssertEqual(HarvestSpanLocator.core("(cloud)"), "cloud")
        XCTAssertEqual(HarvestSpanLocator.core("cloud"), "cloud")
        XCTAssertEqual(HarvestSpanLocator.core("\"Claude's\""), "claude's",
                       "interior punctuation is kept; only edge affixes strip")
        XCTAssertEqual(HarvestSpanLocator.core("..."), "")
    }

    // MARK: - Trigger (a): rawOrdinalForUndo

    private func range(of needle: String, in text: String, occurrence: Int = 0) -> Range<String.Index> {
        var search = text.startIndex..<text.endIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: needle, range: search)
            guard let f = found else { break }
            search = f.upperBound..<text.endIndex
        }
        return found!
    }

    func test_undo_single_occurrence_ordinal_zero() {
        // Shown: "the Claude provider" — one span (cloud → Claude). One raw group
        // says "cloud"; no literal "cloud" remains in the shown text.
        let shown = "the Claude provider"
        let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
            shownText: shown,
            spanRange: range(of: "Claude", in: shown),
            original: "cloud",
            allSpans: [(number: 1, original: "cloud")],
            spanNumber: 1,
            groupMatchCount: 1)
        XCTAssertEqual(ordinal, 0)
    }

    func test_undo_mixed_literals_and_span_ordinal() {
        // Shown: "cloud one Claude two cloud" — the middle was substituted
        // (cloud → Claude); the outer two are literal. Raw ASR heard "cloud" 3×.
        // The span's heard word is the SECOND raw occurrence (ordinal 1).
        let shown = "cloud one Claude two cloud"
        let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
            shownText: shown,
            spanRange: range(of: "Claude", in: shown),
            original: "cloud",
            allSpans: [(number: 1, original: "cloud")],
            spanNumber: 1,
            groupMatchCount: 3)
        XCTAssertEqual(ordinal, 1)
    }

    func test_undo_guard_mismatch_returns_nil() {
        // Same as above but the raw groups only contain 2 matches (a number/compound
        // stage consumed one occurrence) — consistency guard must skip.
        let shown = "cloud one Claude two cloud"
        let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
            shownText: shown,
            spanRange: range(of: "Claude", in: shown),
            original: "cloud",
            allSpans: [(number: 1, original: "cloud")],
            spanNumber: 1,
            groupMatchCount: 2)
        XCTAssertNil(ordinal, "count mismatch ⇒ skip harvest (zero-junk)")
    }

    func test_undo_multiple_spans_same_original_uses_number_order() {
        // Shown: "Claude one Claude" — BOTH were substituted from "cloud"
        // (spans 1 and 2, in number order). Undoing span 2 → raw ordinal 1.
        let shown = "Claude one Claude"
        let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
            shownText: shown,
            spanRange: range(of: "Claude", in: shown, occurrence: 1),
            original: "cloud",
            allSpans: [(number: 1, original: "cloud"), (number: 2, original: "cloud")],
            spanNumber: 2,
            groupMatchCount: 2)
        XCTAssertEqual(ordinal, 1)
    }

    func test_undo_affix_stripped_matching() {
        // Literal occurrence carries punctuation: "cloud," still counts.
        let shown = "cloud, one Claude"
        let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
            shownText: shown,
            spanRange: range(of: "Claude", in: shown),
            original: "cloud",
            allSpans: [(number: 1, original: "cloud")],
            spanNumber: 1,
            groupMatchCount: 2)
        XCTAssertEqual(ordinal, 1)
    }

    // MARK: - Trigger (b): rawOrdinalForEdit

    func test_edit_no_substitution_spans_ordinal_zero() {
        // Before: "ask Claude about the cloud" — "Claude" (word 1) was ASR-emitted
        // verbatim (no substitution spans). Its raw-emitted ordinal is 0.
        let before = "ask Claude about the cloud"
        let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 1, term: "Claude",
            substitutionSpanStarts: [], substitutionSpanTotal: 0,
            groupMatchCount: 1)
        XCTAssertEqual(ordinal, 0)
    }

    func test_edit_substitution_span_before_decrements_ordinal() {
        // Before: "Claude says ask Claude now" — word 0 is a substitution span
        // (cloud → Claude, NOT ASR-emitted); word 3 is the emitted term the user
        // edits. Raw groups contain "Claude" once ⇒ ordinal 0.
        let before = "Claude says ask Claude now"
        let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 3, term: "Claude",
            substitutionSpanStarts: [before.startIndex], substitutionSpanTotal: 1,
            groupMatchCount: 1)
        XCTAssertEqual(ordinal, 0)
    }

    func test_edit_wordIndex_inside_substitution_span_returns_nil() {
        // The edited occurrence IS a substitution span — its audio is the heard
        // confusable, not the emitted term. Trigger (a) covers it via undo.
        let before = "Claude says hello"
        let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 0, term: "Claude",
            substitutionSpanStarts: [before.startIndex], substitutionSpanTotal: 1,
            groupMatchCount: 0)
        XCTAssertNil(ordinal)
    }

    func test_edit_guard_mismatch_returns_nil() {
        let before = "ask Claude about the cloud"
        let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 1, term: "Claude",
            substitutionSpanStarts: [], substitutionSpanTotal: 0,
            groupMatchCount: 2)   // raw groups disagree (expected 1)
        XCTAssertNil(ordinal, "count mismatch ⇒ skip harvest (zero-junk)")
    }

    func test_edit_word_not_matching_term_returns_nil() {
        let before = "ask Claude about the cloud"
        let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 0, term: "Claude",   // word 0 is "ask"
            substitutionSpanStarts: [], substitutionSpanTotal: 0,
            groupMatchCount: 1)
        XCTAssertNil(ordinal)
    }

    func test_edit_out_of_range_wordIndex_returns_nil() {
        let before = "ask Claude"
        XCTAssertNil(HarvestSpanLocator.rawOrdinalForEdit(
            beforeText: before, wordIndex: 9, term: "Claude",
            substitutionSpanStarts: [], substitutionSpanTotal: 0, groupMatchCount: 1))
    }

    // MARK: - locate()

    private func group(_ text: String, _ start: Double, _ end: Double) -> HarvestSpanLocator.GroupSpan {
        HarvestSpanLocator.GroupSpan(text: text, startSeconds: start, endSeconds: end)
    }

    func test_locate_returns_kth_matching_group() {
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5),
                      group("and", 0.5, 0.6), group("cloud", 0.6, 1.0)]
        XCTAssertEqual(HarvestSpanLocator.locate(groups: groups, word: "cloud", rawOrdinal: 0),
                       groups[1])
        XCTAssertEqual(HarvestSpanLocator.locate(groups: groups, word: "cloud", rawOrdinal: 1),
                       groups[3])
    }

    func test_locate_matches_affix_stripped() {
        // Raw group text may carry punctuation tokens; the query word may too.
        let groups = [group("Cloud,", 0.0, 0.4)]
        XCTAssertEqual(HarvestSpanLocator.locate(groups: groups, word: "(cloud)", rawOrdinal: 0),
                       groups[0])
    }

    func test_locate_out_of_range_returns_nil() {
        let groups = [group("cloud", 0.0, 0.4)]
        XCTAssertNil(HarvestSpanLocator.locate(groups: groups, word: "cloud", rawOrdinal: 1))
        XCTAssertNil(HarvestSpanLocator.locate(groups: groups, word: "cloud", rawOrdinal: -1))
        XCTAssertNil(HarvestSpanLocator.locate(groups: groups, word: "kiwi", rawOrdinal: 0))
    }
}
#endif
