// HarvestSpanLocator — pure ordinal math for correction-time negative harvest.
//
// Maps a corrected word (an undone correction span, or an E-edited word) to the
// ordinal of its word-group in the RAW ASR output, so the harvest can pool exactly
// the audio span the user corrected. The dictionary stage preserves word order:
// un-substituted occurrences remain literal in the cleaned text and substituted
// ones are exactly the correction spans — so the raw ordinal is computable from
// overlay state alone.
//
// Zero-junk consistency guard: the expected total of matching raw groups (derived
// from the shown/before text + spans) must equal the ACTUAL count of matching raw
// groups; any mismatch (a compound/number stage consumed an occurrence, ordinal
// drift — the known boundary documented in ConcordEngine) returns nil and the
// caller skips the harvest silently. A skipped harvest costs a future correction;
// a mislocated one poisons a template.

#if Concord
import Foundation

enum HarvestSpanLocator {
    /// One raw-ASR word-group: its (token-joined) text + the audio span it covers.
    /// `text` may carry token punctuation; matching is by `core(_:)`.
    struct GroupSpan: Equatable {
        let text: String
        let startSeconds: Double
        let endSeconds: Double
    }

    /// Affix-stripped, lowercased word core: trims non-letter characters from both
    /// ends and lowercases. Interior punctuation is preserved (a word like
    /// "don't" keeps its apostrophe) — v1 harvest labels are alphabetic-only, so
    /// interior-punctuation words simply never match (zero-junk skip).
    static func core(_ word: some StringProtocol) -> String {
        var s = Substring(word)
        while let f = s.first, !f.isLetter { s = s.dropFirst() }
        while let l = s.last, !l.isLetter { s = s.dropLast() }
        return s.lowercased()
    }

    /// Whitespace-separated words of `text` with their ranges (Concord's
    /// word-splitting convention).
    private static func wordsWithRanges(_ text: String) -> [(range: Range<String.Index>, word: Substring)] {
        var result: [(Range<String.Index>, Substring)] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            result.append((i..<j, text[i..<j]))
            i = j
        }
        return result
    }

    /// Trigger (a): the raw ordinal of an undone span's HEARD word (`original`).
    /// Inputs come from the PRE-revert overlay state:
    /// - `shownText` / `spanRange`: the cleaned text and the undone span's range in it.
    /// - `allSpans`: every correction span (number + original), pre-revert.
    /// - `groupMatchCount`: how many raw word-groups core-match `original`.
    ///
    /// `ordinal = literalCoreMatchesBefore(spanRange) + priorSameOriginalSpans`
    /// (literal = un-substituted occurrences still visible in the shown text;
    /// substituted occurrences are exactly the same-original spans, in number order).
    /// Guard: `groupMatchCount == literalTotal + sameOriginalSpanTotal`.
    static func rawOrdinalForUndo(shownText: String, spanRange: Range<String.Index>,
                                  original: String,
                                  allSpans: [(number: Int, original: String)],
                                  spanNumber: Int,
                                  groupMatchCount: Int) -> Int? {
        let target = core(original)
        guard !target.isEmpty else { return nil }
        var literalBefore = 0
        var literalTotal = 0
        for (range, word) in wordsWithRanges(shownText) where core(word) == target {
            literalTotal += 1
            if range.lowerBound < spanRange.lowerBound { literalBefore += 1 }
        }
        let sameOriginal = allSpans.filter { core($0.original) == target }
        let priorSame = sameOriginal.filter { $0.number < spanNumber }.count
        guard groupMatchCount == literalTotal + sameOriginal.count else { return nil }
        let ordinal = literalBefore + priorSame
        guard ordinal >= 0, ordinal < groupMatchCount else { return nil }
        return ordinal
    }

    /// Trigger (b): the raw-EMITTED ordinal of the term at word index `wordIndex`
    /// in `beforeText` (the pre-edit shown text).
    /// - `substitutionSpanStarts`: `range.lowerBound` of every correction span whose
    ///   REPLACEMENT core-matches the term — those occurrences were substituted in,
    ///   NOT ASR-emitted, so they are subtracted. The indices MUST index into
    ///   `beforeText` (capture spans BEFORE any post-edit remap — RoboRev-7484).
    /// - Returns nil when `wordIndex` falls inside a substitution span (that audio
    ///   is the heard confusable; trigger (a) covers it via undo).
    ///
    /// `ordinal = coreMatchesBefore(wordIndex) − substitutionSpanStartsBefore`.
    /// Guard: `groupMatchCount == coreMatchTotal − substitutionSpanTotal`.
    static func rawOrdinalForEdit(beforeText: String, wordIndex: Int, term: String,
                                  substitutionSpanStarts: [String.Index],
                                  substitutionSpanTotal: Int,
                                  groupMatchCount: Int) -> Int? {
        let target = core(term)
        guard !target.isEmpty else { return nil }
        let words = wordsWithRanges(beforeText)
        guard wordIndex >= 0, wordIndex < words.count else { return nil }
        let edited = words[wordIndex]
        guard core(edited.word) == target else { return nil }
        // The edited occurrence must not itself be a substituted-in span.
        if substitutionSpanStarts.contains(where: {
            $0 >= edited.range.lowerBound && $0 < edited.range.upperBound
        }) {
            return nil
        }
        var coreBefore = 0
        var coreTotal = 0
        for (i, w) in words.enumerated() where core(w.word) == target {
            coreTotal += 1
            if i < wordIndex { coreBefore += 1 }
        }
        let subsBefore = substitutionSpanStarts.filter { $0 < edited.range.lowerBound }.count
        guard groupMatchCount == coreTotal - substitutionSpanTotal else { return nil }
        let ordinal = coreBefore - subsBefore
        guard ordinal >= 0, ordinal < groupMatchCount else { return nil }
        return ordinal
    }

    /// The k-th (0-based `rawOrdinal`) group whose text core-matches `word`;
    /// nil when out of range.
    static func locate(groups: [GroupSpan], word: String, rawOrdinal: Int) -> GroupSpan? {
        guard rawOrdinal >= 0 else { return nil }
        let target = core(word)
        guard !target.isEmpty else { return nil }
        let matches = groups.filter { core($0.text) == target }
        guard rawOrdinal < matches.count else { return nil }
        return matches[rawOrdinal]
    }
}
#endif
