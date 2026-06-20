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
}

enum CorrectionHighlight {
    /// Map the APPLIED edits to character ranges in `text`, numbered 1..N in
    /// reading order (left-to-right by position in the shown text).
    ///
    /// Mapping strategy — robust to the two hard cases:
    ///   - An edit whose `replacement` appears MULTIPLE times: we walk the
    ///     edits in `wordRange` order (the order Concord applied them, which is
    ///     left-to-right in the transcript) and advance a per-replacement search
    ///     cursor, so two edits with the same replacement text land on distinct,
    ///     successive occurrences rather than both on the first.
    ///   - An edit whose `replacement` can't be found at all (e.g. a later edit
    ///     or a manual edit rewrote that region): it is simply dropped from the
    ///     highlight set — no crash, no bogus range. The remaining edits still
    ///     map and stay correctly numbered.
    ///
    /// Only `applied == true` edits with a non-empty `replacement` participate.
    /// Empty-replacement edits (pure deletions) have no visible span to mark.
    static func spans(in text: String, edits: [EditRecord]) -> [CorrectionSpan] {
        let applied = edits
            .filter { $0.applied && !$0.replacement.isEmpty }
            // Token order = transcript reading order; nil wordRanges sort last
            // but keep a stable relative order via enumerated index.
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.wordRange?.lowerBound ?? Int.max
                let r = rhs.element.wordRange?.lowerBound ?? Int.max
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        // Per-replacement search cursor: where to start the next search for a
        // given replacement string, so repeated replacements advance.
        var searchStart = text.startIndex
        var found: [(range: Range<String.Index>, edit: EditRecord)] = []
        for edit in applied {
            // Search from the running cursor so edits are matched in order and
            // a repeated replacement picks the NEXT occurrence.
            if let r = text.range(of: edit.replacement, range: searchStart..<text.endIndex) {
                found.append((r, edit))
                searchStart = r.upperBound
            } else if let r = text.range(of: edit.replacement) {
                // Fallback: the in-order cursor overshot (edits weren't strictly
                // left-to-right, or an earlier replacement consumed the cursor).
                // Take the first occurrence anywhere rather than dropping it.
                found.append((r, edit))
            }
            // else: not present at all — drop (manual edit / rewrite).
        }

        // Number in final on-screen reading order (by range position), so the
        // digits the user sees increase top-to-bottom / left-to-right even if
        // the fallback above matched out of order.
        let ordered = found.sorted { $0.range.lowerBound < $1.range.lowerBound }
        return ordered.enumerated().map { idx, item in
            CorrectionSpan(
                number: idx + 1,
                range: item.range,
                original: item.edit.original,
                replacement: item.edit.replacement,
                stage: item.edit.stage
            )
        }
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
