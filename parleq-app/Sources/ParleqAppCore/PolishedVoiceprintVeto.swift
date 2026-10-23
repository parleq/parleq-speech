// PolishedVoiceprintVeto — the enrolled-voiceprint over-fire veto for
// POLISHED cleanup (cloud or on-device LLM), issue #125.
//
// The acoustic voiceprint gate normally lives inside Concord (the Instant
// tier). Polished turns never go through Concord, but ASR-side CTC biasing
// in LocalASR still rewrites a dictionary alias to its term (e.g. a term
// "Acme" with the common-word alias "acne": "I have acne" → "I have Acme")
// before cleanup — and the Polished prompt's `(also: …)` alias hint can
// reintroduce the term even if the swap were undone. So before a Polished
// call we run ONLY Concord's per-word dictionary stage (every other Instant
// stage is off — the Polished prompt does that work itself) with the
// voiceprint gate, and keep ONLY its acoustic verdicts:
//
//   • a REVERT (the ASR emitted the term, the audio says it was the
//     confusable) is applied to the raw transcript the LLM sees;
//   • every vetoed term (revert or exact-alias reject) loses its aliases from
//     THIS call's vocabulary hint, and the heard word is listed as
//     keep-as-is in the prompt.
//
// Forward dictionary substitutions the stage would make are DISCARDED: the
// Polished prompt already does forward dictionary correction, and stacking
// Concord's substitutions onto it would change Polished output on dictations
// the veto has no opinion about.
//
// Compliance: pure in-memory transform. Nothing here writes to disk or logs
// transcript content (invariants #1, #2); callers log counts only.

import Foundation
#if Concord
import Concord
#endif

/// The per-utterance result of the Polished voiceprint veto. Compiled in
/// every build (OSS builds simply never produce one), so the prompt-shaping
/// seam in `streamCleanupOrRefine` needs no `#if`.
public struct VoiceprintVetoOutcome: Sendable, Equatable {
    /// The raw transcript with voiceprint reverts applied (unchanged when the
    /// veto only rejected an exact alias that the ASR left as heard).
    public let text: String
    /// Lowercased canonical terms the voiceprint vetoed in this utterance.
    public let vetoedTerms: Set<String>
    /// The heard words to keep exactly as spoken (deduped, first-seen order).
    public let keepWords: [String]

    public init(text: String, vetoedTerms: Set<String>, keepWords: [String]) {
        self.text = text
        self.vetoedTerms = vetoedTerms
        self.keepWords = keepWords
    }

    /// The dictionary to show the LLM for this call: a vetoed term keeps its
    /// entry (a genuine use elsewhere in the utterance still benefits) but
    /// loses its aliases, so the prompt no longer says "acne means Acme".
    public func promptDictionary(_ dictionary: [DictionaryEntry]) -> [DictionaryEntry] {
        guard !vetoedTerms.isEmpty else { return dictionary }
        return dictionary.map { entry in
            guard vetoedTerms.contains(entry.term.lowercased()), !entry.aliases.isEmpty else { return entry }
            var e = entry
            e.aliases = []
            return e
        }
    }
}

enum PolishedVoiceprintVeto {

    /// Strip leading/trailing non-word characters and lowercase — the same
    /// core the Concord dictionary stage matches on (`splitAffixes`).
    static func core(_ token: Substring) -> (pre: Substring, core: Substring, post: Substring) {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var start = token.startIndex, end = token.endIndex
        while start < end, !isWord(token[start]) { start = token.index(after: start) }
        while end > start, !isWord(token[token.index(before: end)]) { end = token.index(before: end) }
        return (token[token.startIndex..<start], token[start..<end], token[end..<token.endIndex])
    }

    /// Cheap prefilter: the ENROLLED single-word dictionary entries whose term
    /// or an alias appears verbatim (case-insensitive, affixes stripped) in the
    /// transcript. Empty → the veto has nothing to judge, so the caller skips
    /// building the gate entirely (zero added latency on ordinary dictations).
    static func relevantEntries(transcript: String, dictionary: [DictionaryEntry],
                                enrolledTermIDs: [String]) -> [DictionaryEntry] {
        let enrolled = Set(enrolledTermIDs.map { $0.lowercased() })
        guard !enrolled.isEmpty else { return [] }
        let words = Set(transcript.split(whereSeparator: { $0.isWhitespace })
            .map { core($0).core.lowercased() }.filter { !$0.isEmpty })
        guard !words.isEmpty else { return [] }
        return dictionary.filter { entry in
            let term = entry.term.lowercased()
            guard enrolled.contains(term), !term.contains(" "), !term.isEmpty else { return false }
            if words.contains(term) { return true }
            return entry.aliases.contains { words.contains($0.lowercased()) }
        }
    }

    #if Concord
    /// Concord with ONLY the per-word dictionary stage. Spoken forms are off
    /// too, so every `EditRecord.wordRange` indexes the raw transcript's
    /// space-split words — which is what lets `evaluate` apply a revert in
    /// place. Panphon is off: it only judges fuzzy forward substitutions,
    /// which this seam discards.
    static let engine = ConcordEngine(config: ConcordEngine.Config(
        enableNumbers: false, enableCompounds: false, enableDictionary: true,
        enableSpokenForms: false, enableQuestionMarks: false, enableHomophones: false,
        enableArticleAgreement: false, enableDuplicateCollapse: false,
        enableSpokenPunctuation: false, enablePanphonGate: false))

    /// Pure core (unit-tested with a fake gate): run the dictionary stage over
    /// `transcript` with `gate`, keep only the acoustic verdicts. Returns nil
    /// when the gate vetoed nothing.
    static func evaluate(transcript: String, entries: [DictionaryEntry],
                         tokens: [ConcordToken], gate: @escaping AcousticGate) -> VoiceprintVetoOutcome? {
        guard !entries.isEmpty else { return nil }
        // The words the veto may judge: each enrolled term + its aliases.
        var candidates: [String: String] = [:]   // lowercased word → lowercased canonical
        for e in entries {
            candidates[e.term.lowercased()] = e.term.lowercased()
            for a in e.aliases where !a.contains(" ") && !a.isEmpty {
                candidates[a.lowercased()] = e.term.lowercased()
            }
        }
        let dict = entries.map { DictionaryTerm(term: $0.term, aliases: $0.aliases, spokenForms: []) }
        let result = engine.clean(transcript: transcript, tokens: tokens, dictionary: dict,
                                  acousticGate: gate)

        // Same split the engine uses, so wordRange indexes line up.
        var words = transcript.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var vetoed: Set<String> = []
        var keep: [String] = []
        var changed = false
        for edit in result.edits where edit.stage == .dictionary && edit.gateDecision == "reject" {
            guard let range = edit.wordRange, range.count == 1, range.lowerBound < words.count,
                  let canonical = candidates[edit.original.lowercased()] else { continue }
            let i = range.lowerBound
            let heard: String
            if edit.applied {
                // Revert: the ASR wrote the term; the audio says it was the
                // confusable. Swap the core in place, keeping punctuation.
                let parts = core(Substring(words[i]))
                guard parts.core.lowercased() == edit.original.lowercased() else { continue }
                words[i] = String(parts.pre) + edit.replacement + String(parts.post)
                heard = edit.replacement
                changed = true
            } else {
                // Exact-alias veto: the heard word already stands; just pin it.
                heard = edit.original
            }
            vetoed.insert(canonical)
            if !keep.contains(where: { $0.lowercased() == heard.lowercased() }) { keep.append(heard) }
        }
        guard !vetoed.isEmpty else { return nil }
        // Mixed verdicts for one term: the voiceprint ACCEPTED one alias
        // occurrence as the term but vetoed another. The alias is about to
        // leave the prompt and the vetoed word is pinned, so the LLM could no
        // longer make the accepted swap — apply that voiceprint-verified
        // substitution here instead. (Only for vetoed terms: with no veto the
        // Polished prompt keeps doing forward correction as before.)
        for edit in result.edits where edit.stage == .dictionary && edit.applied
            && edit.gateDecision == "accept" && edit.gateMargin != nil {
            guard let range = edit.wordRange, range.count == 1, range.lowerBound < words.count,
                  let canonical = candidates[edit.original.lowercased()], vetoed.contains(canonical),
                  edit.original.lowercased() != canonical else { continue }
            let i = range.lowerBound
            let parts = core(Substring(words[i]))
            guard parts.core.lowercased() == edit.original.lowercased() else { continue }
            words[i] = String(parts.pre) + edit.replacement + String(parts.post)
            changed = true
        }
        return VoiceprintVetoOutcome(text: changed ? words.joined(separator: " ") : transcript,
                                     vetoedTerms: vetoed, keepWords: keep)
    }

    /// Full per-utterance entry point: prefilter, build the gate from the
    /// utterance's diagnostics, evaluate. nil when there is nothing to veto
    /// (no enrolled term/alias heard, no diagnostics/voiceprint, no reject).
    static func compute(transcript: String, diagnostics: ASRDiagnostics?,
                        dictionary: [DictionaryEntry], enrolledTermIDs: [String],
                        gateFactory: @Sendable (ASRDiagnostics?) async -> AcousticGate?) async -> VoiceprintVetoOutcome? {
        let entries = relevantEntries(transcript: transcript, dictionary: dictionary,
                                      enrolledTermIDs: enrolledTermIDs)
        guard !entries.isEmpty, let diagnostics else { return nil }
        guard let gate = await gateFactory(diagnostics) else { return nil }
        return evaluate(transcript: transcript, entries: entries,
                        tokens: ConcordCleanupProvider.buildTokens(from: diagnostics), gate: gate)
    }
    #endif
}
