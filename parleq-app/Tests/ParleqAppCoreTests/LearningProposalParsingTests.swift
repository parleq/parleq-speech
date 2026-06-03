import XCTest
@testable import ParleqAppCore

final class LearningProposalParsingTests: XCTestCase {

    func test_parses_fenced_json_block() {
        let text = """
        Here are my proposals:
        ```json
        {"proposals":[
          {"kind":"term","op":"add","confidence":0.92,"rationale":"User spelled it out twice","term":"Mira"},
          {"kind":"style","op":"add","confidence":0.7,"rationale":"User keeps making it formal","rule":"Prefer a formal register"}
        ]}
        ```
        """
        let proposals = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals[0].kind, .term)
        XCTAssertEqual(proposals[0].op, .add)
        XCTAssertEqual(proposals[0].term, "Mira")
        XCTAssertEqual(proposals[1].kind, .style)
        XCTAssertEqual(proposals[1].rule, "Prefer a formal register")
    }

    func test_parses_bare_json_without_fence() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":0.9,"rationale":"r","term":"Acme"}]}"#
        XCTAssertEqual(LearningAnalyzer.parseProposals(from: text).count, 1)
    }

    func test_drops_invalid_confidence() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":1.7,"rationale":"r","term":"X"}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: text).isEmpty,
                      "confidence outside 0...1 must be dropped")
    }

    func test_drops_unknown_kind_or_op() {
        let text = #"{"proposals":[{"kind":"emoji","op":"add","confidence":0.9,"rationale":"r","term":"X"},{"kind":"term","op":"frobnicate","confidence":0.9,"rationale":"r","term":"Y"}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: text).isEmpty,
                      "Unknown kind/op values must be dropped, not crash")
    }

    func test_drops_term_proposal_with_empty_term() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":0.9,"rationale":"r","term":"  "}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: text).isEmpty,
                      "A term proposal needs a non-empty term")
    }

    func test_drops_style_proposal_with_empty_rule() {
        let text = #"{"proposals":[{"kind":"style","op":"add","confidence":0.9,"rationale":"r"}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: text).isEmpty,
                      "A style proposal needs a non-empty rule")
    }

    func test_garbage_returns_empty() {
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: "no json here at all").isEmpty)
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: "").isEmpty)
    }

    func test_keeps_valid_drops_invalid_in_same_batch() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":0.9,"rationale":"good","term":"Keep"},{"kind":"term","op":"add","confidence":5,"rationale":"bad","term":"Drop"}]}"#
        let proposals = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(proposals.map { $0.term }, ["Keep"])
    }

    // MARK: - Durable-field bounding (privacy: no freeform text on disk)

    func test_wordLevel_accepts_short_rejects_phrases() {
        XCTAssertEqual(LearningAnalyzer.wordLevel("  Mira  "), "Mira")
        XCTAssertEqual(LearningAnalyzer.wordLevel("John Smith"), "John Smith")
        XCTAssertNil(LearningAnalyzer.wordLevel("this is a six word long phrase"),
                     "A six-word phrase is dictation text, not a term/alias")
        XCTAssertNil(LearningAnalyzer.wordLevel(String(repeating: "a", count: 65)),
                     "Over the char cap must be rejected")
        XCTAssertNil(LearningAnalyzer.wordLevel("   "))
    }

    func test_wordLevel_rejects_prose_punctuation() {
        XCTAssertNil(LearningAnalyzer.wordLevel("buy milk, eggs"), "Comma signals prose")
        XCTAssertNil(LearningAnalyzer.wordLevel("really?"), "Question mark signals prose")
        XCTAssertNil(LearningAnalyzer.wordLevel("wait: now"), "Colon signals prose")
        XCTAssertNil(LearningAnalyzer.wordLevel("call mom today."),
                     "A 3-word value ending in a period is a sentence, not a term")
    }

    func test_wordLevel_allows_names_abbreviations_and_compounds() {
        XCTAssertEqual(LearningAnalyzer.wordLevel("New York City"), "New York City")
        XCTAssertEqual(LearningAnalyzer.wordLevel("Ph.D."), "Ph.D.", "Single-token abbreviation is fine")
        XCTAssertEqual(LearningAnalyzer.wordLevel("Acme Inc."), "Acme Inc.", "Two-token abbreviated name is fine")
        XCTAssertEqual(LearningAnalyzer.wordLevel("co-worker"), "co-worker", "Hyphenated compound is fine")
        XCTAssertEqual(LearningAnalyzer.wordLevel("AT&T"), "AT&T", "Ampersand term is fine")
    }

    func test_boundedContext_collapses_and_truncates() {
        XCTAssertNil(LearningAnalyzer.boundedContext(nil))
        XCTAssertNil(LearningAnalyzer.boundedContext("   \n  "))
        XCTAssertEqual(LearningAnalyzer.boundedContext("voice  dictation\napp"), "voice dictation app",
                       "Whitespace/newlines collapse to single spaces")
        let long = LearningAnalyzer.boundedContext(String(repeating: "x ", count: 100)) ?? ""
        XCTAssertLessThanOrEqual(long.count, 80, "Context is truncated to the cap")
        XCTAssertFalse(long.contains("\n"))
    }

    func test_drops_sentence_like_term() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":0.9,"rationale":"r","term":"please remember to buy more milk today"}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: text).isEmpty,
                      "A sentence-like term is dictation text — it must not become a durable dictionary entry")
    }

    func test_drops_phrase_aliases_keeps_word_level() {
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":0.9,"rationale":"r","term":"Mira","aliases":["meera","this alias is far too long to be a real token"]}]}"#
        let p = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].aliases, ["meera"],
                       "Phrase-like aliases are dropped; word-level ones kept")
    }

    func test_type_mismatch_in_one_proposal_drops_only_that_proposal() {
        // `confidence` as a string is a TYPE mismatch (not just out of
        // range). A naive [ProposalDTO] decode throws on the whole array
        // and loses the valid proposal too; per-element FailableDecodable
        // must drop only the bad element.
        let text = #"{"proposals":[{"kind":"term","op":"add","confidence":"high","rationale":"bad type","term":"Drop"},{"kind":"term","op":"add","confidence":0.9,"rationale":"good","term":"Keep"}]}"#
        let proposals = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(proposals.map { $0.term }, ["Keep"],
                       "A type mismatch in one proposal must not discard the rest of the batch")
    }
}
