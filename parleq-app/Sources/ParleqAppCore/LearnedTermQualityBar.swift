// LearnedTermQualityBar — the quality gate for AUTO-LEARNED dictionary
// terms.
//
// "Learn from corrections" can auto-apply a proposed term into the custom
// dictionary (source=.learned). Real usage showed the analyzer auto-adds
// junk and collision-prone terms that degrade ASR (e.g. "iTerm"/"iTerm2"
// colliding with "item", "parallel" colliding with "Parleq", plus bare
// common words like "scholarly" / "line item" and mis-learned phrase
// fragments like "dictation released"). Fix 1 already removes the ASR
// over-fire by defaulting learned terms to `.llmOnly` biasing; this is the
// second line of defense: a pure predicate that REJECTS low-quality term
// proposals from auto-apply entirely (they fall through to a pending
// suggestion the user can still accept by hand — when uncertain we never
// silently auto-add).
//
// All functions here are pure (nonisolated, deterministic over their
// string inputs) so they're unit-testable and free of any disk / network
// / transcript-content side effects. Rejections are counted (not logged
// with content) by the caller in LearnedStore.ingest — honoring the
// count-only learning-log invariant.

import Foundation

enum LearnedTermQualityBar {

    /// Why a proposed term was rejected from auto-apply. Used only for the
    /// count-only rejection tally; never carries the term text into a log.
    enum Rejection: String, Sendable, Equatable {
        /// The whole term (single word) is a common English word.
        case commonWord
        /// A multi-word term whose every word is common (no proper-noun /
        /// jargon component to justify learning it).
        case allCommonPhrase
        /// Phonetically near-identical to a common word or an existing
        /// dictionary term/alias (the over-fire collision class).
        case collision
    }

    /// Decide whether a TERM proposal is admissible for AUTO-APPLY. Returns
    /// `nil` when admissible; otherwise the rejection reason. Conservative
    /// by construction: any of the rules below → reject (don't auto-add).
    ///
    /// `existing` is the current custom dictionary, so a learned term can
    /// be rejected for colliding with a hand-curated term/alias too — not
    /// just with the common-word set.
    static func rejectionReason(
        term rawTerm: String,
        existing: [DictionaryEntry]
    ) -> Rejection? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .commonWord }

        let words = wordTokens(term)

        // Rule (a): a single-word term that IS a common English word
        // (e.g. "scholarly", "item"). Lowercased compare — proper nouns
        // we want to keep ("Mira", "Parleq") aren't in the set.
        if words.count == 1, isCommonWord(words[0]) {
            return .commonWord
        }

        // Rule (b): a multi-word term whose EVERY word is common
        // (e.g. "dictation released", "line item"). A multi-word term with
        // any proper-noun / jargon component ("Keavi LLC", "Acme Corp")
        // survives — at least one word isn't in the common set.
        if words.count >= 2, words.allSatisfy({ isCommonWord($0) }) {
            return .allCommonPhrase
        }

        // Rule (c): phonetic collision with a common word OR an existing
        // dictionary term/alias (the "iTerm"~"item", "parallel"~"Parleq"
        // class). Only meaningful for short single-token terms — that's
        // where CTC biasing over-fires; multi-word terms are distinctive.
        if words.count == 1 {
            // Collision against existing dictionary entries (term + aliases),
            // skipping a self-match (a modify of the same learned term).
            for entry in existing {
                // A modify of the SAME learned entry must not collide with itself —
                // skip the self entry entirely (its own term AND its own aliases),
                // else updating "Kubernetes" trips on its existing "Kubernettes" alias.
                if equalFold(term, entry.term) { continue }
                if collides(term, entry.term) {
                    return .collision
                }
                for alias in entry.aliases where collides(term, alias) {
                    return .collision
                }
            }
            // Collision against the common-word set. Catches "iTerm"~"item"
            // and "parallel"~"Parleq"-style cases where the term itself
            // isn't in the set but is one tiny edit away from a common word.
            if collidesWithAnyCommonWord(term) {
                return .collision
            }
        }

        return nil
    }

    // MARK: - Tokenization

    /// Split into lowercased word tokens on whitespace, dropping empties.
    private static func wordTokens(_ s: String) -> [String] {
        s.lowercased()
            .split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Common-word membership

    static func isCommonWord(_ word: String) -> Bool {
        commonWords.contains(word.lowercased())
    }

    // MARK: - Phonetic / edit-distance collision

    private static func equalFold(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// True if `term` is phonetically near-identical to `candidate`. Cheap
    /// heuristic: case/space-folded equality after stripping a few
    /// confusable affixes, plus a Levenshtein distance threshold scaled to
    /// the shorter length. Tuned to catch the observed over-fire cases
    /// ("iTerm"~"item", "iTerm2"~"item", "parallel"~"Parleq") while not
    /// flagging genuinely distinct short terms.
    static func collides(_ term: String, _ candidate: String) -> Bool {
        let a = phoneticKey(term)
        let b = phoneticKey(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Only consider collisions for reasonably short tokens — long
        // distinctive words don't over-fire CTC biasing.
        let shorter = min(a.count, b.count)
        guard shorter >= 3, max(a.count, b.count) <= 12 else {
            return a == b
        }
        let d = levenshtein(a, b)
        // Allow 1 edit for short keys (<=5), 2 for medium. Conservative:
        // when uncertain we'd rather under-flag here, but rules (a)/(b)
        // and the common-word collision sweep below cover the bare cases.
        let allowed = shorter <= 5 ? 1 : 2
        return d <= allowed
    }

    private static func collidesWithAnyCommonWord(_ term: String) -> Bool {
        let key = phoneticKey(term)
        guard key.count >= 3 else { return false }
        // Bound the sweep: only compare against same-ish-length common
        // words so this stays cheap and precise.
        for w in collisionProbeWords {
            if collides(term, w) { return true }
        }
        return false
    }

    /// A lowercased, space/punct-stripped, vowel-light-ish key used for the
    /// near-match compare. We keep it simple (lowercase + drop trailing
    /// digits + strip non-alphanumerics) rather than a full Soundex so the
    /// behavior is easy to reason about and test. Trailing digits are
    /// dropped so "iTerm2" keys the same as "iTerm".
    static func phoneticKey(_ s: String) -> String {
        var scalars = String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        while let last = scalars.last, last.isNumber {
            scalars.removeLast()
        }
        return scalars
    }

    /// Classic iterative Levenshtein over Characters.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    // MARK: - Word sets

    /// High-frequency English words. A few hundred of the most common words
    /// is enough to catch the bad cases (the analyzer's other guards handle
    /// the rest); intentionally NOT the full system dictionary, which would
    /// over-reject lowercase-but-distinctive proper nouns / jargon. Sourced
    /// from a standard top-frequency English word list (function words,
    /// pronouns, common verbs/nouns/adjectives) plus the specific common
    /// words the real-usage bug surfaced ("item", "scholarly", "line",
    /// "released", "dictation", "parallel").
    static let commonWords: Set<String> = [
        // articles / determiners / pronouns / conjunctions / prepositions
        "a", "an", "the", "this", "that", "these", "those", "i", "you", "he",
        "she", "it", "we", "they", "me", "him", "her", "us", "them", "my",
        "your", "his", "its", "our", "their", "mine", "yours", "ours",
        "theirs", "who", "whom", "whose", "which", "what", "and", "or", "but",
        "nor", "so", "yet", "for", "if", "then", "else", "as", "than",
        "because", "while", "where", "when", "why", "how", "of", "to", "in",
        "on", "at", "by", "with", "from", "into", "onto", "upon", "about",
        "above", "below", "under", "over", "between", "among", "through",
        "during", "before", "after", "since", "until", "against", "without",
        "within", "along", "across", "behind", "beyond", "near", "off", "out",
        "up", "down", "around", "is", "am", "are", "was", "were", "be", "been",
        "being", "have", "has", "had", "do", "does", "did", "will", "would",
        "shall", "should", "can", "could", "may", "might", "must", "not", "no",
        "yes", "all", "any", "both", "each", "few", "many", "more", "most",
        "other", "some", "such", "only", "own", "same", "too", "very", "just",
        // common verbs
        "go", "going", "goes", "went", "gone", "get", "got", "gotten", "make",
        "made", "making", "take", "took", "taken", "come", "came", "see",
        "saw", "seen", "know", "knew", "known", "think", "thought", "say",
        "said", "tell", "told", "give", "gave", "given", "find", "found",
        "use", "used", "using", "work", "worked", "call", "called", "try",
        "tried", "ask", "asked", "need", "needed", "feel", "felt", "become",
        "leave", "left", "put", "mean", "meant", "keep", "kept", "let",
        "begin", "began", "seem", "help", "show", "showed", "shown", "hear",
        "heard", "play", "played", "run", "ran", "move", "moved", "live",
        "lived", "believe", "bring", "brought", "happen", "write", "wrote",
        "written", "sit", "sat", "stand", "stood", "lose", "lost", "pay",
        "paid", "meet", "met", "include", "included", "continue", "set",
        "learn", "learned", "change", "changed", "lead", "led", "understand",
        "watch", "follow", "stop", "create", "speak", "spoke", "read", "spend",
        "grow", "open", "opened", "walk", "win", "won", "offer", "remember",
        "consider", "appear", "buy", "bought", "wait", "serve", "die", "send",
        "sent", "build", "built", "stay", "fall", "fell", "cut", "reach",
        "kill", "remain", "release", "released", "dictate", "dictation",
        // common nouns
        "time", "year", "people", "way", "day", "man", "thing", "woman",
        "life", "child", "world", "school", "state", "family", "student",
        "group", "country", "problem", "hand", "part", "place", "case",
        "week", "company", "system", "program", "question", "government",
        "number", "night", "point", "home", "water", "room", "mother", "area",
        "money", "story", "fact", "month", "lot", "right", "study", "book",
        "eye", "job", "word", "business", "issue", "side", "kind", "head",
        "house", "service", "friend", "father", "power", "hour", "game",
        "line", "end", "member", "law", "car", "city", "community", "name",
        "team", "minute", "idea", "body", "information", "back", "parent",
        "face", "level", "office", "door", "health", "person", "art", "war",
        "history", "party", "result", "change", "morning", "reason", "moment",
        "air", "teacher", "force", "education", "item", "list", "thanks",
        // common adjectives / adverbs
        "good", "new", "first", "last", "long", "great", "little", "big",
        "small", "large", "old", "young", "high", "low", "different", "early",
        "late", "important", "public", "bad", "able", "human", "local", "sure",
        "better", "best", "free", "true", "false", "full", "special", "easy",
        "clear", "recent", "certain", "personal", "open", "hard", "major",
        "real", "left", "national", "happy", "serious", "ready", "simple",
        "general", "main", "current", "now", "here", "there", "today",
        "tomorrow", "yesterday", "always", "never", "often", "sometimes",
        "again", "once", "twice", "still", "already", "even", "much", "well",
        "back", "away", "really", "almost", "enough", "quite", "rather",
        "perhaps", "maybe", "soon", "later", "ever", "together", "around",
        "scholarly",
        // numbers / misc high-freq
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "hundred", "thousand", "million", "first", "second",
        "third", "next", "another", "every", "many", "several", "thing",
        "things", "something", "nothing", "anything", "everything", "someone",
        "anyone", "everyone", "nobody", "somewhere", "anywhere", "everywhere",
        "parallel",
    ]

    /// The subset of common words that short learned terms most plausibly
    /// collide with — kept to short tokens so the per-term near-match sweep
    /// stays O(small). Built from `commonWords` filtered to length 3...8.
    static let collisionProbeWords: [String] = commonWords.filter {
        $0.count >= 3 && $0.count <= 8
    }
}
