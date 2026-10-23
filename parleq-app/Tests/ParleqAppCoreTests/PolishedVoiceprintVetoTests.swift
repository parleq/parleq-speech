import XCTest
@testable import ParleqAppCore
#if Concord
import Concord
#endif

/// Issue #125: the enrolled-voiceprint veto on POLISHED cleanup. Uses the
/// public generic example — term "Acme" with the common-word alias "acne".
final class PolishedVoiceprintVetoTests: XCTestCase {

    private let acme = DictionaryEntry(term: "Acme", context: "finance app", aliases: ["acne"])
    private let other = DictionaryEntry(term: "Parleq", aliases: ["parlay"])

    // MARK: Prompt shaping (all builds)

    func testPromptDictionaryDropsOnlyVetoedTermsAliases() {
        let outcome = VoiceprintVetoOutcome(text: "I have acne", vetoedTerms: ["acme"], keepWords: ["acne"])
        let shaped = outcome.promptDictionary([acme, other])
        XCTAssertEqual(shaped.map(\.term), ["Acme", "Parleq"], "the term itself stays listed")
        XCTAssertEqual(shaped[0].aliases, [])
        XCTAssertEqual(shaped[0].context, "finance app")
        XCTAssertEqual(shaped[1].aliases, ["parlay"], "non-vetoed terms keep their aliases")
        let prompt = SystemPrompts.cleanup(dictionary: shaped, transform: nil)
        XCTAssertFalse(prompt.contains("\"acne\""), "the prompt must not map the vetoed alias to the term")
        XCTAssertTrue(prompt.contains("\"parlay\""))
    }

    func testKeepHint() {
        XCTAssertEqual(SystemPrompts.voiceprintKeepHint([]), "")
        XCTAssertEqual(SystemPrompts.voiceprintKeepHint(["  "]), "")
        let hint = SystemPrompts.voiceprintKeepHint(["acne"])
        XCTAssertTrue(hint.contains("\"acne\""))
        XCTAssertTrue(hint.hasPrefix("Voice-verified words"))
    }

    func testPrefilterSkipsWithoutEnrolledTermOrHeardWord() {
        typealias V = PolishedVoiceprintVeto
        XCTAssertTrue(V.relevantEntries(transcript: "I have acne", dictionary: [acme], enrolledTermIDs: []).isEmpty,
                      "nothing enrolled → no gate build")
        XCTAssertTrue(V.relevantEntries(transcript: "the weather is fine", dictionary: [acme],
                                        enrolledTermIDs: ["Acme"]).isEmpty,
                      "no term/alias heard → no gate build")
        XCTAssertEqual(V.relevantEntries(transcript: "I have acne.", dictionary: [acme, other],
                                         enrolledTermIDs: ["acme"]).map(\.term), ["Acme"],
                       "alias heard (punctuation stripped, case-insensitive) → only the enrolled entry")
        XCTAssertEqual(V.relevantEntries(transcript: "Ask Acme, then", dictionary: [acme],
                                         enrolledTermIDs: ["Acme"]).map(\.term), ["Acme"])
    }

    func testPolishedVetoTargetRouting() {
        let cloud = StubProvider()
        XCTAssertTrue(isPolishedVetoTarget(llm: cloud, asRefine: false, refineBehavior: .interpret))
        XCTAssertTrue(isPolishedVetoTarget(llm: cloud, asRefine: true, refineBehavior: .interpret))
        XCTAssertFalse(isPolishedVetoTarget(llm: cloud, asRefine: true, refineBehavior: .appendVerbatim),
                       "Raw refinement is untouched")
        XCTAssertFalse(isPolishedVetoTarget(llm: nil, asRefine: false, refineBehavior: .interpret),
                       "Raw cleanup (no provider) is untouched")
        #if Concord
        XCTAssertFalse(isPolishedVetoTarget(llm: ConcordCleanupProvider(), asRefine: false,
                                            refineBehavior: .interpret),
                       "Instant runs the veto inside Concord itself")
        #endif
    }

    #if Concord
    // MARK: Veto core (Concord builds) — fake gate, no audio

    /// A gate that says every "Acme"/"acne" span was really the word "acne".
    private let saysConfusable: AcousticGate = { ctx in
        guard ctx.termID == "Acme" else { return .noOpinion }
        return ctx.originalWord.lowercased() == "acme" ? .revert(to: "acne", margin: 2.0)
                                                       : .reject(margin: -2.0)
    }

    func testRevertsAnASRSwapAndPinsTheWord() throws {
        let out = try XCTUnwrap(PolishedVoiceprintVeto.evaluate(
            transcript: "I have Acme, it itches", entries: [acme], tokens: [], gate: saysConfusable))
        XCTAssertEqual(out.text, "I have acne, it itches", "punctuation preserved around the revert")
        XCTAssertEqual(out.vetoedTerms, ["acme"])
        XCTAssertEqual(out.keepWords, ["acne"])
    }

    func testExactAliasVetoKeepsTextAndPinsTheWord() throws {
        let out = try XCTUnwrap(PolishedVoiceprintVeto.evaluate(
            transcript: "I have acne", entries: [acme], tokens: [], gate: saysConfusable))
        XCTAssertEqual(out.text, "I have acne")
        XCTAssertEqual(out.vetoedTerms, ["acme"])
        XCTAssertEqual(out.keepWords, ["acne"])
    }

    func testForwardSubstitutionsAreDiscarded() {
        // No opinion / accept → nothing vetoed, and the seam never makes the
        // alias→term swap itself (that's the Polished prompt's job).
        XCTAssertNil(PolishedVoiceprintVeto.evaluate(
            transcript: "I have acne", entries: [acme], tokens: [], gate: { _ in .noOpinion }))
        XCTAssertNil(PolishedVoiceprintVeto.evaluate(
            transcript: "I use Acme daily", entries: [acme], tokens: [], gate: { _ in .accept(margin: 3.0) }))
    }

    func testOnlyTheVetoedOccurrenceIsReverted() throws {
        // First "Acme" really was the term; the second was the confusable.
        let gate: AcousticGate = { ctx in
            ctx.occurrence == 0 ? .accept(margin: 3.0) : .revert(to: "acne", margin: 2.0)
        }
        let out = try XCTUnwrap(PolishedVoiceprintVeto.evaluate(
            transcript: "Acme said Acme", entries: [acme], tokens: [], gate: gate))
        XCTAssertEqual(out.text, "Acme said acne")
    }

    func testMixedVerdictsApplyTheAcceptedAliasSwap() throws {
        // Same alias twice: the voiceprint accepts the first as the term and
        // vetoes the second. The alias leaves the prompt, so the accepted swap
        // must already be in the text the LLM sees.
        let gate: AcousticGate = { ctx in
            ctx.occurrence == 0 ? .accept(margin: 3.0) : .reject(margin: -2.0)
        }
        let out = try XCTUnwrap(PolishedVoiceprintVeto.evaluate(
            transcript: "acne said acne.", entries: [acme], tokens: [], gate: gate))
        XCTAssertEqual(out.text, "Acme said acne.")
        XCTAssertEqual(out.keepWords, ["acne"])
    }
    #endif
}

private struct StubProvider: LLMProvider {
    var model: String { "stub" }
    var providerName: String { "gemini" }
    var supportsVision: Bool { false }
    func generateStreaming(systemPrompt: String, messages: [LLMMessage],
                           onEvent: @Sendable (LLMStreamEvent) -> Void) async throws {}
}
