// CarrierSentences — the read-aloud sentences the voice-enrollment wizard shows
// so the user speaks a term in varied, natural contexts.
//
// Two sources, same shape ([String], each containing the term once):
//   • Built-in TEMPLATES — the always-available floor. Frames deliberately vary
//     the term's position and phonetic neighborhood (sentence-initial / medial /
//     final; after vowels vs. stops; statements vs. questions) for coarticulation
//     coverage. Work offline, with provider=none, and on any LLM failure.
//   • LLM ENHANCEMENT — when a cleanup LLM is configured, a one-shot prompt asks
//     for topical variants. Any failure (no provider, error, timeout, garbled or
//     too-few usable lines) silently falls back to the templates.
//
// Pure value logic — no I/O beyond the injected `llm` closure. The user can edit
// or regenerate any sentence in the UI, so neither source is load-bearing alone.

import Foundation

public enum CarrierSentences {

    /// Carrier frames. Each contains the literal `{term}` exactly once. Ordered
    /// so the first handful already spread the term across positions/contexts.
    public static let templates: [String] = [
        "{term} is what I meant.",                 // sentence-initial
        "I use {term} every day.",                 // medial, after a vowel
        "Let me open {term} now.",                 // medial, after a stop
        "Can you add {term} to the list?",         // medial, in a question
        "I was just talking about {term}.",        // sentence-final
        "We should try {term} for this.",          // medial
        "Tell me more about {term}.",              // sentence-final, after a vowel
        "This is about {term}, specifically.",     // medial, before a pause
        "They asked me about {term} earlier.",     // medial, after a vowel
        "I'll send the {term} details over.",      // medial, possessive-ish context
    ]

    /// Fill `count` template frames with `term`, in template order. Cycles if
    /// `count` exceeds the number of templates (rare — the wizard uses ~6).
    /// Deterministic — used for the initial load (and as the negative-carrier
    /// floor) so the first set is stable.
    public static func fallback(term: String, count: Int) -> [String] {
        filled(term: term, count: count, order: Array(templates.indices))
    }

    /// Like `fallback`, but draws from a shuffled template order so successive
    /// calls return a DIFFERENT valid set — used by the wizard's "Regenerate
    /// sentences" so a templates-only fallback doesn't look broken. Each call
    /// still yields `count` distinct term-containing frames (distinct as long as
    /// `count` ≤ the template count, which the wizard guarantees).
    public static func fallbackVaried(term: String, count: Int) -> [String] {
        filled(term: term, count: count, order: templates.indices.shuffled())
    }

    /// Shared filler: maps the first `count` entries of `order` (cycling if
    /// needed) into term-filled frames.
    private static func filled(term: String, count: Int, order: [Int]) -> [String] {
        guard count > 0, !order.isEmpty else { return [] }
        return (0..<count).map { i in
            templates[order[i % order.count]].replacingOccurrences(of: "{term}", with: term)
        }
    }

    /// Produce `count` carrier sentences for `term`. Tries the injected one-shot
    /// `llm` closure (prompt in → text out, or nil on failure); parses its lines;
    /// uses them only if at least `count` are usable, else falls back to templates.
    /// `llm == nil` → straight to templates.
    /// `varied` selects the template fallback flavor when the LLM path is
    /// unavailable or fails: `false` (default) → stable `fallback`; `true` →
    /// shuffled `fallbackVaried`, so the wizard's "Regenerate" yields a fresh
    /// set even with no generative provider. (A live LLM already varies its
    /// output per call, so the flag only matters on the template floor.)
    public static func generate(term: String,
                                count: Int,
                                llm: (@Sendable (String) async -> String?)?,
                                varied: Bool = false) async -> [String] {
        let fb = { varied ? fallbackVaried(term: term, count: count)
                          : fallback(term: term, count: count) }
        guard let llm else { return fb() }
        let prompt = """
        Write \(count) short, natural, everyday sentences that each use the exact word \
        "\(term)" once, in varied positions (start, middle, end). One sentence per line, \
        no numbering, no quotes.
        """
        guard let raw = await llm(prompt) else { return fb() }
        let parsed = parseLines(raw, term: term)
        return parsed.count >= count ? Array(parsed.prefix(count)) : fb()
    }

    /// Parse model output into usable carrier lines: split on newlines, trim,
    /// strip a leading list marker (`1.` / `2)` / `-` / `*`), drop empties and
    /// surrounding quotes, and keep only lines in which the term appears EXACTLY
    /// ONCE as a STANDALONE word (case-insensitive).
    ///
    /// A bare substring match (`Keavi's`, `Keavi-related`) is rejected: it would
    /// later fail the enroller's slot locator (`termSlotIndex`, which compares the
    /// whole whitespace-word's letters-only form) and silently break enrollment.
    /// Matching the SAME way here keeps the carrier set and the slot locator in
    /// agreement.
    static func parseLines(_ raw: String, term: String) -> [String] {
        return raw
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                s = stripLeadingMarker(s)
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && standaloneOccurrences(of: term, in: $0) == 1 }
    }

    /// Alphanumeric lowercase normalization. Keeps letters AND digits (so "GPT-4"
    /// → "gpt4", "S3" → "s3" must appear in full — a line with only "GPT" is
    /// rejected) while still dropping punctuation, so "Keavi." / "KEAVI," count but
    /// "Keavi's" / "Keavi-related" do not. This is intentionally AT LEAST as strict
    /// as the enroller's letters-only slot key (`VoiceprintCoordinator.norm`): any
    /// line that passes here still contains the term for the enroller to locate, so
    /// the two stay in agreement. (Residual: purely-symbolic distinctions like the
    /// "++" in "C++" still normalize away — a rare case; the template fallback covers
    /// any shortfall and the enroller is no stricter.)
    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Count of times the FULL term phrase appears in `line` as a run of
    /// consecutive STANDALONE words (each word's letters-only form matching the
    /// term's, in order). For a multi-word term like "New York" both words must
    /// appear adjacent and in order — a line with only "New" does NOT count — so a
    /// carrier always carries the whole spoken phrase, not just its first sub-word
    /// (which the enroller separately uses only to anchor the audio slot).
    private static func standaloneOccurrences(of term: String, in line: String) -> Int {
        let termWords = term.split(whereSeparator: { $0.isWhitespace }).map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !termWords.isEmpty else { return 0 }
        let lineWords = line.split(whereSeparator: { $0.isWhitespace }).map { norm(String($0)) }
        guard lineWords.count >= termWords.count else { return 0 }
        var count = 0
        for start in 0...(lineWords.count - termWords.count)
        where Array(lineWords[start..<start + termWords.count]) == termWords {
            count += 1
        }
        return count
    }

    /// Strip a leading enumeration marker like "1. ", "2) ", "- ", "* ".
    private static func stripLeadingMarker(_ s: String) -> String {
        var chars = Substring(s)
        // numeric marker: digits then . or )
        var idx = chars.startIndex
        while idx < chars.endIndex, chars[idx].isNumber { idx = chars.index(after: idx) }
        if idx > chars.startIndex, idx < chars.endIndex, chars[idx] == "." || chars[idx] == ")" {
            chars = chars[chars.index(after: idx)...]
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
        // bullet marker
        if let first = chars.first, first == "-" || first == "*" || first == "•" {
            return String(chars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
