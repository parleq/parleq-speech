// CorrectionHighlight — pure span-mapping + revert helpers for the overlay's
// "what did the on-device corrector change?" highlight + per-correction undo
// feature (Concord-only).
//
// Concord emits a per-edit `EditRecord` (stage, original, replacement,
// wordRange, applied, …). For DISPLAY we only care about edits that were
// actually applied (`applied == true`): each one replaced `original` with
// `replacement` somewhere in the cleaned transcript. To highlight the changed
// spans we locate each `replacement` substring inside the SHOWN text and
// compute its character range.
//
// This file holds the pure, SwiftUI/AppKit-free, unit-testable logic:
//   - `spans(in:edits:)` — map applied EditRecords → character ranges, numbered
//      1..N in reading order.
//   - `revert(text:span:)` — replace a span's replacement back with its
//      original, returning the new text (used by per-correction undo).
//
// No transcript/edit content is logged or persisted here — these are pure
// transforms over in-memory strings handed in by the caller.

import Concord
import Foundation

/// One highlighted correction the overlay can render + let the user undo.
/// `range` is a Swift `String.Index` range into the EXACT text it was mapped
/// against (so it stays valid only for that string snapshot).
struct CorrectionSpan: Equatable {
    /// 1-based number shown in the overlay + typed (Option+digit) to undo.
    let number: Int
    /// The character range of `replacement` in the mapped text.
    let range: Range<String.Index>
    /// What the ASR originally produced (what undo reverts TO).
    let original: String
    /// What Concord changed it to (the text currently shown in `range`).
    let replacement: String
    /// Which Concord stage produced this edit (dictionary / number / say-as …).
    let stage: EditStage
    /// The edit's original token range (nil for deterministic number/compound
    /// edits). Carried so a re-map after an undo / manual edit can re-anchor:
    /// without it a ranged dictionary/say-as edit falls back to first-occurrence
    /// matching and could re-attach to the wrong duplicate occurrence.
    let wordRange: Range<Int>?
}

enum CorrectionHighlight {
    /// Map the APPLIED edits to character ranges in `text`, numbered 1..N in
    /// reading order (left-to-right by position in the shown text).
    ///
    /// Mapping strategy — anchored to each edit's `wordRange`, robust to the hard cases:
    ///   - An edit whose `replacement` ALSO appears earlier UNCHANGED (e.g. "API api" →
    ///     "API API" with the 2nd token edited): a plain first-match would highlight/undo
    ///     the wrong (already-correct) occurrence. Instead we anchor to the character offset
    ///     of the edit's `wordRange` token and pick the occurrence CLOSEST to it — so the
    ///     edited token wins. (Closest-not-exact tolerates cross-stage token drift: a
    ///     wordRange recorded on an intermediate-stage text needn't index-align with the
    ///     final cleaned text, but the nearest occurrence is still the right one.)
    ///   - The same `replacement` appearing for two DIFFERENT edits: each claims a distinct
    ///     occurrence (we exclude already-claimed ranges), each anchored to its own token.
    ///   - A `replacement` not present at all (a later/manual edit rewrote it): dropped — no
    ///     crash, no bogus range; the rest still map and stay correctly numbered.
    ///
    /// Only `applied == true` edits with a non-empty `replacement` participate.
    /// Empty-replacement edits (pure deletions) have no visible span to mark.
    static func spans(in text: String, edits: [EditRecord]) -> [CorrectionSpan] {
        // Stable order: by wordRange (reading order); ties and nil-ranges keep EMISSION order
        // (Concord emits left-to-right), so the deterministic number/compound edits — which have
        // no wordRange — stay correctly sequenced for the cursor below.
        let applied = edits
            .filter { $0.applied && !$0.replacement.isEmpty }
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.wordRange?.lowerBound ?? Int.max
                let r = rhs.element.wordRange?.lowerBound ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element }

        // Char offset of each space-delimited token's start (matches Concord's
        // `split(separator: " ")` tokenization, the basis of `wordRange`).
        let tokenStarts = tokenStartOffsets(in: text)

        var claimed: [Range<String.Index>] = []
        // Cursor for nil-wordRange edits (deterministic number/compound) ONLY — advanced solely
        // by THESE matches, so their left-to-right emission order maps to left-to-right
        // occurrences. Kept SEPARATE from the wordRange anchoring so a ranged dictionary/say-as
        // edit can never push it forward and strand an earlier number on a wrong later occurrence.
        var nilCursor = text.startIndex
        var found: [(range: Range<String.Index>, edit: EditRecord)] = []
        for edit in applied {
            // All unclaimed occurrences of this replacement, left-to-right.
            let occurrences = ranges(of: edit.replacement, in: text)
                .filter { occ in !claimed.contains { $0.overlaps(occ) } }
            guard !occurrences.isEmpty else { continue }   // not present / all claimed → drop

            let best: Range<String.Index>
            if let lo = edit.wordRange?.lowerBound, lo >= 0, lo < tokenStarts.count {
                // Ranged edit (dictionary / say-as): anchor to its token; closest occurrence wins.
                let anchor = tokenStarts[lo]
                best = occurrences.min {
                    abs(text.distance(from: text.startIndex, to: $0.lowerBound) - anchor)
                        < abs(text.distance(from: text.startIndex, to: $1.lowerBound) - anchor)
                }!
            } else {
                // nil-wordRange edit: first unclaimed occurrence at/after the dedicated cursor.
                best = occurrences.first { $0.lowerBound >= nilCursor } ?? occurrences[0]
                nilCursor = best.upperBound
            }
            found.append((best, edit))
            claimed.append(best)
        }

        // Number in final on-screen reading order (left-to-right by position).
        let ordered = found.sorted { $0.range.lowerBound < $1.range.lowerBound }
        return ordered.enumerated().map { idx, item in
            CorrectionSpan(
                number: idx + 1,
                range: item.range,
                original: item.edit.original,
                replacement: item.edit.replacement,
                stage: item.edit.stage,
                wordRange: item.edit.wordRange
            )
        }
    }

    /// Char offset (from `text.startIndex`) of the start of each space-delimited token —
    /// mirrors Concord's `split(separator: " ")` so a `wordRange` index maps to a position.
    private static func tokenStartOffsets(in text: String) -> [Int] {
        var starts: [Int] = []
        var offset = 0
        var inToken = false
        for ch in text {
            if ch == " " {
                inToken = false
            } else if !inToken {
                starts.append(offset)
                inToken = true
            }
            offset += 1
        }
        return starts
    }

    /// Every (non-overlapping, left-to-right) range where `needle` occurs in `text`.
    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while let r = text.range(of: needle, range: start..<text.endIndex) {
            out.append(r)
            start = r.upperBound
        }
        return out
    }

    /// Revert one correction: replace the `replacement` text at `span.range`
    /// with `span.original`, returning the new text. The range must be valid
    /// for `text` (the caller re-derives spans against the current text before
    /// each undo, so this holds).
    static func revert(text: String, span: CorrectionSpan) -> String {
        var out = text
        out.replaceSubrange(span.range, with: span.original)
        return out
    }
}
