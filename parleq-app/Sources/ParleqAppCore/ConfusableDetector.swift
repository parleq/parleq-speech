// ConfusableDetector — decides which of FluidAudio's mishears of a dictionary
// term are REAL WORDS the user might also say (and so warrant capturing a
// contrastive negative), versus non-word mishears (which are aliases only).
//
// "Real word" is judged on-device by the macOS system spell checker
// (NSSpellChecker, English) — no bundled wordlist, no network. A mishear that
// spell-checks clean AND differs from the term is a confusable; e.g. the wizard
// hears "Keavi" as "kiwi" (real → confusable) and as "kaevy" (not a word →
// alias only).

import AppKit
import Foundation

@MainActor
public enum ConfusableDetector {

    /// True iff `word` is a real English word per the system spell checker.
    /// Requires ≥ 2 letters and all-letters (rejects fragments/punctuation).
    public static func isRealWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, w.allSatisfy({ $0.isLetter }) else { return false }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: w, startingAt: 0)
        // location == NSNotFound means the checker found NO misspelling → real word.
        return range.location == NSNotFound
    }

    /// From the raw mishears FluidAudio produced for `term`, return the distinct
    /// real-word confusables (case-insensitive dedup, first-seen order), dropping
    /// non-words and any mishear equal to the term itself.
    public static func confusables(mishears: [String], term: String) -> [String] {
        let termKey = term.lowercased().filter { $0.isLetter }
        var seen = Set<String>()
        var out: [String] = []
        for raw in mishears {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = word.lowercased().filter { $0.isLetter }
            guard !key.isEmpty, key != termKey, !seen.contains(key) else { continue }
            guard isRealWord(word) else { continue }
            seen.insert(key)
            out.append(word)
        }
        return out
    }
}
