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

    // MARK: - Trigger (b): editedGroup (position-based)

    private func group(_ text: String, _ start: Double, _ end: Double) -> HarvestSpanLocator.GroupSpan {
        HarvestSpanLocator.GroupSpan(text: text, startSeconds: start, endSeconds: end)
    }

    func test_edit_locates_group_by_position_even_when_text_was_rescored() {
        // THE BUG REPRO. LocalASR CTC vocab-rescore rewrote the TEXT (cloud→Claude)
        // but the raw token timings keep the acoustically-heard "cloud". The cleaned
        // before-text has "Claude" at word 1; the raw groups have "cloud" at index 1.
        // Locating BY POSITION must return the heard-"cloud" span (the audio the user
        // actually spoke) — text-matching "Claude" against the raw groups finds
        // nothing, which is exactly the failure this fix corrects.
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5),
                      group("provider", 0.5, 0.9), group("bills", 0.9, 1.1),
                      group("monthly", 1.1, 1.5)]
        let before = "The Claude provider bills monthly"
        XCTAssertEqual(
            HarvestSpanLocator.editedGroup(groups: groups, beforeText: before, wordIndex: 1),
            groups[1],
            "must pool the heard 'cloud' span by position, not text-match 'Claude'")
    }

    func test_edit_literal_token_emit_also_located_by_position() {
        // The ASR literally emitted the term in TOKENS (timings carry "Claude").
        // Position-based location still returns the right span — the audio the user
        // is correcting — with no special-casing.
        let groups = [group("ask", 0.0, 0.2), group("Claude", 0.2, 0.6),
                      group("please", 0.6, 0.9)]
        let before = "ask Claude please"
        XCTAssertEqual(
            HarvestSpanLocator.editedGroup(groups: groups, beforeText: before, wordIndex: 1),
            groups[1])
    }

    func test_edit_position_count_mismatch_returns_nil() {
        // A count-changing stage (rescore merge "e to e"→"e2e", or Concord
        // dedup/compound/number) broke the 1:1 position mapping ⇒ skip (zero-junk).
        let groups = [group("e", 0.0, 0.2), group("to", 0.2, 0.3), group("e", 0.3, 0.5)]
        let before = "e2e rocks"   // 2 cleaned words vs 3 raw groups
        XCTAssertNil(
            HarvestSpanLocator.editedGroup(groups: groups, beforeText: before, wordIndex: 0),
            "raw-group count ≠ before-word count ⇒ skip harvest (zero-junk)")
    }

    func test_edit_position_out_of_range_returns_nil() {
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5)]
        let before = "the Claude"
        XCTAssertNil(HarvestSpanLocator.editedGroup(groups: groups, beforeText: before, wordIndex: 5))
        XCTAssertNil(HarvestSpanLocator.editedGroup(groups: groups, beforeText: before, wordIndex: -1))
    }

    // MARK: - locate()

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

    // MARK: - Task 5: locateByTime (timestamp-anchored harvest)

    func test_locateByTime_returns_overlapping_group() {
        // Window matches group 2 ("provider", 0.5–0.9) exactly.
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5),
                      group("provider", 0.5, 0.9), group("bills", 0.9, 1.1)]
        XCTAssertEqual(
            HarvestSpanLocator.locateByTime(startSeconds: 0.5, endSeconds: 0.9, groups: groups),
            2)
    }

    func test_locateByTime_returns_nil_when_window_overlaps_nothing() {
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5)]
        XCTAssertNil(
            HarvestSpanLocator.locateByTime(startSeconds: 2.0, endSeconds: 2.4, groups: groups))
    }

    func test_locateByTime_picks_max_overlap_when_window_spans_two_groups() {
        // Window [0.4, 0.85] overlaps group 1 ("cloud", 0.1–0.5) by 0.1s and
        // group 2 ("provider", 0.5–0.9) by 0.35s — group 2 has more overlap.
        let groups = [group("the", 0.0, 0.1), group("cloud", 0.1, 0.5),
                      group("provider", 0.5, 0.9), group("bills", 0.9, 1.1)]
        XCTAssertEqual(
            HarvestSpanLocator.locateByTime(startSeconds: 0.4, endSeconds: 0.85, groups: groups),
            2)
    }
}
#endif
