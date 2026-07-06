import XCTest
@testable import ParleqAppCore

#if Concord

/// Unit tests for `VoiceprintCoordinator.termGroupRange` — the text-anchored
/// carrier↔transcription alignment that lets a term the current encoder splits
/// into a DIFFERENT number of word-groups than the enrollment carrier held
/// (acronyms/digits: "E2E" → "E to E") still localize to the full span it
/// occupies, instead of a single mis-indexed group.
///
/// The old localization applied the carrier word INDEX straight onto the fresh
/// transcription's word-groups, so an expanding term pointed at just its first
/// sub-word (or drifted entirely) → the span pooled the wrong audio → the
/// re-derived embedding failed the quality gate → the term was parked. These
/// pin the fix.
final class VoiceprintSpanAlignmentTests: XCTestCase {

    /// Build word-groups with 1-second slots so ranges are easy to read.
    private func groups(_ words: [String]) -> [VoiceprintDemo.WordGroup] {
        words.enumerated().map { i, w in
            VoiceprintDemo.WordGroup(text: w, startSeconds: Double(i), endSeconds: Double(i) + 0.9)
        }
    }

    private func range(term: String, carrier: String, fresh: [String]) -> Range<Int>? {
        VoiceprintCoordinator.termGroupRange(term: term, in: carrier, groups: groups(fresh))
    }

    // MARK: - Ordinary single-word terms (must match the pre-fix behavior)

    func test_single_word_term_at_start() {
        XCTAssertEqual(range(term: "Alpha", carrier: "Alpha is here",
                             fresh: ["Alpha", "is", "here"]), 0..<1)
    }

    func test_single_word_term_mid_sentence() {
        XCTAssertEqual(range(term: "Alpha", carrier: "the Alpha test",
                             fresh: ["the", "Alpha", "test"]), 1..<2)
    }

    func test_single_word_term_at_end() {
        XCTAssertEqual(range(term: "here", carrier: "Alpha is here",
                             fresh: ["Alpha", "is", "here"]), 2..<3)
    }

    // MARK: - THE FIX: acronym/digit terms that expand into more fresh groups

    func test_acronym_expands_mid_sentence() {
        // Carrier held "E2E" as one word (index 1); the current encoder hears
        // "E to E" (3 groups). The span must cover all three.
        XCTAssertEqual(range(term: "E2E", carrier: "the E2E test",
                             fresh: ["the", "E", "to", "E", "test"]), 1..<4)
    }

    func test_acronym_expands_at_start() {
        XCTAssertEqual(range(term: "E2E", carrier: "E2E is great",
                             fresh: ["E", "to", "E", "is", "great"]), 0..<3)
    }

    func test_acronym_expands_at_end() {
        XCTAssertEqual(range(term: "E2E", carrier: "we love E2E",
                             fresh: ["we", "love", "E", "to", "E"]), 2..<5)
    }

    // MARK: - Positional disambiguation (must not regress the "is"-confusable fix)

    func test_repeated_anchor_word_resolves_correct_occurrence() {
        // Two "is" anchors surround the term; alignment must pick the term
        // between them, not confuse the occurrences.
        XCTAssertEqual(range(term: "Alpha", carrier: "is Alpha is here",
                             fresh: ["is", "Alpha", "is", "here"]), 1..<2)
    }

    // MARK: - Degenerate cases

    func test_term_absent_from_carrier_returns_nil() {
        XCTAssertNil(range(term: "Zeta", carrier: "Alpha is here",
                           fresh: ["Alpha", "is", "here"]))
    }

    func test_missing_pre_anchor_falls_back_to_slot_index() {
        // "foo" didn't transcribe, so forward anchoring can't complete; the
        // fallback reproduces the old slot behavior (carrier index 1 → fresh
        // group 1) rather than failing outright. Graceful degradation, no
        // regression versus the pre-fix path.
        XCTAssertEqual(range(term: "Alpha", carrier: "foo Alpha bar",
                             fresh: ["Alpha", "bar"]), 1..<2)
    }
}

#endif
