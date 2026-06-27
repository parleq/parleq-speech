// CorrectionPolicyClassifier — assigns a CorrectionPolicy to each
// user dictionary entry, keyed by canonical term (original case).
//
// The policy controls which matching strategies Concord may apply
// for that term. An absent key is treated identically to .contextOnly
// by the engine.
//
// Classification rules (in priority order):
//   1. acousticGated   — the term has an enrolled voiceprint (enrolled
//                        is the set of lowercased term IDs with a print).
//   2. contextOnly     — biasing == .llmOnly (ASR-excluded term; the
//                        LLM pass handles it, not the on-device corrector).
//   3. phoneticEligible — LearnedTermQualityBar says the term is
//                        phonetically distinctive and collision-free
//                        (rejectionReason returns nil).
//   4. contextOnly     — otherwise (common word, phonetic collision, etc).
//
// No caching layer: the dictionary is a handful of terms and classify
// runs in-process synchronously per utterance — the cost is negligible.

#if Concord
import Concord

enum CorrectionPolicyClassifier {

    /// Classify each entry in `entries` against the enrolled voiceprint set.
    ///
    /// - Parameters:
    ///   - entries: The full user dictionary for this utterance.
    ///   - enrolled: Lowercased term IDs that have an enrolled voiceprint.
    /// - Returns: Map from `entry.term` (original case) → `CorrectionPolicy`.
    static func classify(
        _ entries: [DictionaryEntry],
        enrolled: Set<String>
    ) -> [String: CorrectionPolicy] {
        var result: [String: CorrectionPolicy] = [:]
        for entry in entries {
            let policy: CorrectionPolicy
            if enrolled.contains(entry.term.lowercased()) {
                policy = .acousticGated
            } else if entry.biasing == .llmOnly {
                policy = .contextOnly
            } else if LearnedTermQualityBar.rejectionReason(term: entry.term, existing: entries) == nil {
                policy = .phoneticEligible
            } else {
                policy = .contextOnly
            }
            result[entry.term] = policy
        }
        return result
    }
}
#endif
