import XCTest
@testable import ParleqAppCore

final class LearnedTermQualityBarTests: XCTestCase {

    private func assertRejected(_ term: String, _ expected: LearnedTermQualityBar.Rejection,
                                existing: [DictionaryEntry] = [],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(LearnedTermQualityBar.rejectionReason(term: term, existing: existing),
                       expected, "expected '\(term)' rejected as \(expected)", file: file, line: line)
    }
    private func assertAccepted(_ term: String, existing: [DictionaryEntry] = [],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(LearnedTermQualityBar.rejectionReason(term: term, existing: existing),
                     "expected '\(term)' accepted", file: file, line: line)
    }

    // Rule (a): bare common word
    func test_bare_common_word_rejected() {
        assertRejected("scholarly", .commonWord)
        assertRejected("item", .commonWord)
        assertRejected("Item", .commonWord)        // case-insensitive
        assertRejected("released", .commonWord)
    }

    // Rule (b): all-common multi-word phrase
    func test_all_common_phrase_rejected() {
        assertRejected("line item", .allCommonPhrase)
        assertRejected("dictation released", .allCommonPhrase)
    }

    // Rule (b) must NOT reject phrases with a proper-noun / jargon component.
    func test_phrase_with_proper_noun_component_accepted() {
        assertAccepted("Keavi LLC")
        assertAccepted("Acme Corp")
        assertAccepted("Parleq settings")  // "Parleq" not common
    }

    // Rule (c): phonetic collisions — the observed over-fire cases.
    func test_iterm_collides_with_item() {
        assertRejected("iTerm", .collision)
        assertRejected("iTerm2", .collision)       // trailing digit stripped
    }

    func test_parallel_collides_with_parleq_existing_term() {
        let existing = [DictionaryEntry(term: "Parleq", source: .user)]
        // "parallel" is in the common set, but also collides with Parleq.
        // Either way it must be rejected; assert it's not accepted.
        XCTAssertNotNil(
            LearnedTermQualityBar.rejectionReason(term: "parallel", existing: existing))
    }

    func test_collision_with_existing_dictionary_term() {
        let existing = [DictionaryEntry(term: "Mira", source: .user)]
        assertRejected("Mirah", .collision, existing: existing)  // 1 edit from Mira
    }

    func test_collision_with_existing_alias() {
        let existing = [DictionaryEntry(term: "Acme", aliases: ["widget"], source: .user)]
        assertRejected("widgit", .collision, existing: existing)
    }

    // Distinctive proper nouns must survive (no false positives).
    func test_distinctive_proper_nouns_accepted() {
        assertAccepted("Mira")
        assertAccepted("Parleq")
        assertAccepted("Kubernetes")
        assertAccepted("Häagen-Dazs")
        assertAccepted("FluidAudio")
    }

    // Self-match on a modify of the same learned term must not be a collision.
    func test_modify_self_not_a_collision() {
        let existing = [DictionaryEntry(term: "Mira", source: .learned)]
        assertAccepted("Mira", existing: existing)
        assertAccepted("mira", existing: existing)  // case-fold self-match
    }

    func test_modify_self_with_near_match_alias_not_a_collision() {
        // RoboRev 64e899a Low: modifying an entry must skip its OWN aliases too —
        // updating "Kubernetes" must not trip on its existing near-match alias.
        let existing = [DictionaryEntry(term: "Kubernetes", aliases: ["Kubernettes"], source: .learned)]
        assertAccepted("Kubernetes", existing: existing)
    }

    func test_phoneticKey_strips_trailing_digits_and_punct() {
        XCTAssertEqual(LearnedTermQualityBar.phoneticKey("iTerm2"), "iterm".lowercased())
        XCTAssertEqual(LearnedTermQualityBar.phoneticKey("AT&T"), "att")
    }

    func test_levenshtein_basic() {
        XCTAssertEqual(LearnedTermQualityBar.levenshtein("item", "iterm"), 1)
        XCTAssertEqual(LearnedTermQualityBar.levenshtein("abc", "abc"), 0)
        XCTAssertEqual(LearnedTermQualityBar.levenshtein("abc", "xyz"), 3)
    }
}
