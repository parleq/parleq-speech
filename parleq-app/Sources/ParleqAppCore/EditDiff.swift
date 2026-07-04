// EditDiff — conservative 1:1 word-replacement diff for E-edit harvest (trigger b).
//
// Deliberately mechanical and strict (zero-junk over recall, spec D2): the edit is
// harvestable only when it is expressible as ≤ HarvestPolicy.maxEditReplacements
// pure position-wise word replacements — equal word counts, no insert / delete /
// reorder / rewrite. This misses some genuine fixes (e.g. the user also deleted a
// filler word); that's the intended posture — downstream validation (voiceprint
// presence + phonetic confusability) further filters each pair.

#if Concord
import Foundation

enum EditDiff {
    /// One position-wise word replacement. `before`/`after` are VERBATIM (affixes
    /// kept) — callers core-normalize as needed; `wordIndex` indexes the
    /// whitespace-split before-text.
    struct WordReplacement: Equatable {
        let before: String
        let after: String
        let wordIndex: Int
    }

    /// nil unless the edit is ≤ `HarvestPolicy.maxEditReplacements` pure
    /// position-wise word replacements (equal word counts). `[]` when the texts
    /// split to identical word sequences (whitespace-only change).
    ///
    /// Reorder guard (RoboRev-7508): when any changed AFTER word core-matches any
    /// changed BEFORE word, the edit looks like a moved/swapped word rather than
    /// a mishear correction — e.g. "Claude cloud" → "cloud Claude" would otherwise
    /// yield a (Claude → cloud) pair whose audio is the TRUE term, and the
    /// downstream phonetic gate passes for confusables, poisoning the voiceprint.
    /// The whole edit returns nil (zero-junk; a case-only self-edit also lands
    /// here, which the coordinator's self-label guard would reject anyway).
    static func singleWordReplacements(before: String, after: String) -> [WordReplacement]? {
        let beforeWords = before.split(whereSeparator: { $0.isWhitespace })
        let afterWords = after.split(whereSeparator: { $0.isWhitespace })
        guard beforeWords.count == afterWords.count else { return nil }
        var replacements: [WordReplacement] = []
        for (i, (b, a)) in zip(beforeWords, afterWords).enumerated() where b != a {
            replacements.append(WordReplacement(before: String(b), after: String(a), wordIndex: i))
            if replacements.count > HarvestPolicy.maxEditReplacements { return nil }
        }
        let changedBeforeCores = Set(replacements.map { HarvestSpanLocator.core($0.before) })
        for r in replacements where changedBeforeCores.contains(HarvestSpanLocator.core(r.after)) {
            return nil   // moved/swapped word (or self-edit) — never harvestable
        }
        return replacements
    }
}
#endif
