// SpellOutDetector — deterministic detection of spelled-out words in a
// raw ASR transcript, for the "learn from corrections" journal.
//
// Spell-out has no fired signal anywhere else in the app: the cleanup
// prompt (SystemPrompts.baseCleanup) tells the LLM to assemble letter-
// by-letter spellings ("M I R A" -> "Mira") internally, but nothing
// surfaces that a spell-out happened. This detector recovers the signal
// cheaply from text we already have, so CorrectionJournal can record a
// candidate dictionary term.
//
// Scope: letter-by-letter forms only — space / hyphen / period
// separated single letters ("M I R A", "M-I-R-A", "M. I. R. A."),
// including the compact dot form with no spaces ("M.I.R.A"). The
// phonetic form ("em eye arr ay") is intentionally NOT detected here
// (the cleanup LLM still handles it; it's just not captured as a
// candidate). Final capitalization (acronym vs proper noun) is the
// analysis LLM's job — this produces a stable proper-noun-cased
// candidate key.

import Foundation

enum SpellOutDetector {
    /// Minimum consecutive single-letter tokens to count as a spell-out.
    /// Two letters ("U R") is too noisy (matches "you are"-style ASR);
    /// three is the empirical floor for an intentional spelling.
    static let minLetters = 3

    /// Extract assembled candidate terms from a raw transcript. Returns
    /// [] when no spelled-letter run of length >= minLetters is present.
    static func candidates(in raw: String) -> [String] {
        // Fold hyphens AND periods to spaces so "M-I-R-A" and the compact
        // "M.I.R.A" tokenize like "M I R A". Raw ASR is largely unpunctuated,
        // so this rarely affects anything but spelled-letter runs.
        let normalized = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let tokens = normalized.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })

        var out: [String] = []
        var run: [Character] = []

        func flush() {
            if run.count >= minLetters {
                out.append(assemble(run))
            }
            run.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            // A single uppercase-letter token is a spelled letter (periods
            // and hyphens were already folded to spaces above). Lowercase
            // single-letter tokens ("a", "I") are common words in ASR
            // output and must not be treated as spell-out letters.
            if token.count == 1, let ch = token.first, ch.isUppercase {
                run.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// Join the letters and apply proper-noun casing as the stable
    /// candidate key. The analysis LLM decides final casing later.
    private static func assemble(_ letters: [Character]) -> String {
        let joined = String(letters)
        return joined.prefix(1).uppercased() + joined.dropFirst().lowercased()
    }
}
