import XCTest
@testable import ParleqAppCore

final class CarrierSentencesTests: XCTestCase {

    private func containsOnce(_ sentence: String, _ term: String) -> Bool {
        let lc = sentence.lowercased()
        let parts = lc.components(separatedBy: term.lowercased())
        return parts.count == 2   // exactly one occurrence
    }

    func test_fallback_yields_distinct_filled_frames() {
        let out = CarrierSentences.fallback(term: "Keavi", count: 6)
        XCTAssertEqual(out.count, 6)
        XCTAssertTrue(out.allSatisfy { $0.contains("Keavi") }, "every frame contains the term")
        XCTAssertTrue(out.allSatisfy { !$0.contains("{term}") }, "the slot is filled")
        XCTAssertEqual(Set(out).count, 6, "frames are distinct")
    }

    func test_fallbackVaried_keeps_invariants_and_differs_across_calls() {
        // Invariants hold every call: count, distinct, term-filled.
        for _ in 0..<8 {
            let out = CarrierSentences.fallbackVaried(term: "Keavi", count: 6)
            XCTAssertEqual(out.count, 6)
            XCTAssertTrue(out.allSatisfy { $0.contains("Keavi") && !$0.contains("{term}") })
            XCTAssertEqual(Set(out).count, 6, "frames are distinct")
        }
        // Across several calls the ordering varies (6-of-10 shuffles colliding
        // every time is astronomically unlikely — guards the "looks broken" bug).
        let sets = (0..<12).map { _ in CarrierSentences.fallbackVaried(term: "Keavi", count: 6) }
        XCTAssertGreaterThan(Set(sets.map { $0.joined(separator: "|") }).count, 1,
                             "successive regenerations should differ")
    }

    func test_fallback_cycles_when_count_exceeds_templates() {
        let out = CarrierSentences.fallback(term: "X", count: CarrierSentences.templates.count + 2)
        XCTAssertEqual(out.count, CarrierSentences.templates.count + 2)
        XCTAssertTrue(out.allSatisfy { $0.contains("X") })
    }

    func test_generate_uses_clean_llm_output_when_enough() async {
        let llm: @Sendable (String) async -> String? = { _ in
            """
            1. I open Keavi daily.
            2. Let me try Keavi now.
            3. Keavi is great.
            4. We use Keavi here.
            5. Tell me about Keavi.
            6. I mentioned Keavi earlier.
            """
        }
        let out = await CarrierSentences.generate(term: "Keavi", count: 6, llm: llm)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out[0], "I open Keavi daily.", "numbering stripped")
        XCTAssertTrue(out.allSatisfy { $0.contains("Keavi") })
        XCTAssertTrue(out.allSatisfy { !$0.contains(".") || !$0.hasPrefix("1") }, "no list markers remain")
    }

    func test_generate_falls_back_when_too_few_usable() async {
        // Only 3 lines contain the term → < 6 requested → templates.
        let llm: @Sendable (String) async -> String? = { _ in "I love Keavi.\n2. Using Keavi today.\nKeavi rocks." }
        let out = await CarrierSentences.generate(term: "Keavi", count: 6, llm: llm)
        XCTAssertEqual(out.count, 6)
        XCTAssertTrue(out.allSatisfy { $0.contains("Keavi") })
    }

    func test_generate_falls_back_on_nil_llm_and_nil_output() async {
        let none = await CarrierSentences.generate(term: "Keavi", count: 6, llm: nil)
        XCTAssertEqual(none.count, 6)
        let failed = await CarrierSentences.generate(term: "Keavi", count: 6, llm: { _ in nil })
        XCTAssertEqual(failed.count, 6)
        XCTAssertTrue((none + failed).allSatisfy { $0.contains("Keavi") })
    }

    func test_parseLines_drops_nonterm_and_strips_quotes() {
        let parsed = CarrierSentences.parseLines("\"I use Keavi.\"\n- Something else\n* Keavi again", term: "Keavi")
        XCTAssertEqual(parsed, ["I use Keavi.", "Keavi again"])
    }

    func test_parseLines_requires_standalone_word_not_substring() {
        let raw = """
        I use Keavi daily.
        Keavi's API is nice.
        A Keavi-related task.
        I mentioned Keavi twice: Keavi rocks.
        Plain Keavi here.
        """
        // Only the two lines with exactly one STANDALONE "Keavi" survive:
        //  - "Keavi's" / "Keavi-related" are substring matches (rejected),
        //  - the double-occurrence line has two standalone hits (rejected).
        let parsed = CarrierSentences.parseLines(raw, term: "Keavi")
        XCTAssertEqual(parsed, ["I use Keavi daily.", "Plain Keavi here."])
    }

    func test_parseLines_multiword_term_requires_full_phrase() {
        let raw = """
        I love New York in the fall.
        New shoes today.
        She moved from York to here.
        We saw New York, New York signs.
        """
        // A multi-word term must appear as the full consecutive phrase exactly once:
        //  - "New shoes" (only "New") and "from York" (only "York") are rejected,
        //  - the doubled "New York ... New York" line has two phrase hits (rejected),
        //  - only the single clean occurrence survives.
        let parsed = CarrierSentences.parseLines(raw, term: "New York")
        XCTAssertEqual(parsed, ["I love New York in the fall."])
    }

    func test_parseLines_digit_bearing_term_requires_full_token() {
        let raw = """
        I asked GPT for help.
        We use GPT-4 at work.
        """
        // "GPT-4" normalizes to "gpt4": the bare "GPT" line is rejected, only the
        // line with the full "GPT-4" token survives.
        let parsed = CarrierSentences.parseLines(raw, term: "GPT-4")
        XCTAssertEqual(parsed, ["We use GPT-4 at work."])
    }
}
