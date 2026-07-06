#if Concord
import XCTest
import Concord
@testable import ParleqAppCore

/// Pure span-mapping + revert for the overlay's on-device-corrector highlight +
/// per-correction-undo feature. Maps applied Concord EditRecords to character
/// ranges in the shown text; reverts one span back to its original.
final class CorrectionHighlightTests: XCTestCase {

    private func edit(
        _ original: String, _ replacement: String,
        applied: Bool = true, range: Range<Int>? = nil,
        stage: EditStage = .dictionary
    ) -> EditRecord {
        EditRecord(stage: stage, original: original, replacement: replacement,
                   applied: applied, wordRange: range)
    }

    private func slice(_ text: String, _ span: CorrectionSpan) -> String {
        String(text[span.range])
    }

    // MARK: spans()

    func testReasonProvenanceCarriedIntoSpan() {
        // RoboRev-7511: heal-vs-harvest routing needs the acoustic gate's revert
        // provenance, not shape inference. The reason string must survive the
        // EditRecord -> CorrectionSpan mapping (and the editRecordFor round-trip
        // preserves it on re-maps).
        let text = "the cloud provider"
        let revert = EditRecord(stage: .dictionary, original: "Claude", replacement: "cloud",
                                applied: true, reason: "acoustic-validate revert")
        let normal = EditRecord(stage: .dictionary, original: "parlay", replacement: "provider",
                                applied: true)
        let spans = CorrectionHighlight.spans(in: text, edits: [revert, normal])
        XCTAssertEqual(spans.count, 2)
        let revertSpan = spans.first { $0.replacement == "cloud" }
        let normalSpan = spans.first { $0.replacement == "provider" }
        XCTAssertEqual(revertSpan?.reason, "acoustic-validate revert")
        XCTAssertTrue(revertSpan?.isValidateRevert ?? false)
        XCTAssertNil(normalSpan?.reason)
        XCTAssertFalse(normalSpan?.isValidateRevert ?? true)
    }


    func testAnchorsToWordRangeNotEarlierUnchangedOccurrence() {
        // RoboRev aaba4e2 Medium: "API api" with the 2nd token edited (api->API) -> "API API",
        // wordRange 1..<2. Must anchor to the EDITED (second) occurrence, not the unchanged first,
        // so undo yields "API api" (not "api API").
        let text = "API API"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("api", "API", range: 1..<2)])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(text.distance(from: text.startIndex, to: spans[0].range.lowerBound), 4)
        XCTAssertEqual(CorrectionHighlight.revert(text: text, span: spans[0]), "API api")
    }

    func testNilRangeNumberEditNotPushedByRangedEdit() {
        // RoboRev 64ef08d Medium: a nil-wordRange number edit uses its OWN cursor (from the start)
        // and must not be pushed past its occurrence by a ranged dict/say-as edit's anchor.
        // "25 and Parleq is 25": number edit -> the FIRST "25"; dict -> "Parleq"; trailing "25" unchanged.
        let text = "25 and Parleq is 25"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("twenty five", "25", range: nil, stage: .deterministicNumber),
            edit("parlay", "Parleq", range: 2..<3, stage: .dictionary),
        ])
        let numberSpan = spans.first { $0.replacement == "25" }!
        XCTAssertEqual(text.distance(from: text.startIndex, to: numberSpan.range.lowerBound), 0,
                       "the nil-range number edit must map to the FIRST '25', not the trailing one")
    }

    func testWordRangeSurvivesRemapAfterUndoOrEdit() {
        // Audit finding: a re-map (after an undo or manual edit) reconstructs
        // EditRecords from the surviving CorrectionSpans. If the span dropped
        // wordRange, a ranged edit would fall back to first-occurrence matching
        // and re-anchor to the WRONG duplicate. Simulate that reconstruction
        // (mirrors AppState.editRecordFor) and confirm the anchor is preserved.
        let text = "API API"
        let spans1 = CorrectionHighlight.spans(in: text, edits: [edit("api", "API", range: 1..<2)])
        XCTAssertEqual(spans1[0].wordRange, 1..<2, "span must carry the edit's wordRange")

        // Reconstruct exactly like AppState.editRecordFor (preserving wordRange).
        let reconstructed = spans1.map {
            EditRecord(stage: $0.stage, original: $0.original,
                       replacement: $0.replacement, applied: true, wordRange: $0.wordRange)
        }
        let spans2 = CorrectionHighlight.spans(in: text, edits: reconstructed)
        XCTAssertEqual(text.distance(from: text.startIndex, to: spans2[0].range.lowerBound), 4,
                       "after re-map the edit must STILL anchor to the second (edited) occurrence")
        XCTAssertEqual(CorrectionHighlight.revert(text: text, span: spans2[0]), "API api")
    }

    func testTimestampsSurviveRemapAfterUndoOrEdit() {
        // Feature B (Task 5): startSeconds/endSeconds must survive the same
        // EditRecord -> CorrectionSpan -> editRecordFor round-trip as
        // wordRange/reason above. If AppState.editRecordFor silently dropped
        // them, a SECOND undo in the same review window would silently fall
        // back to positional matching with no indication.
        let text = "the Claude provider"
        let gated = EditRecord(stage: .dictionary, original: "cloud", replacement: "Claude",
                               applied: true, wordRange: 1..<2,
                               startSeconds: 0.5, endSeconds: 0.9)
        let spans1 = CorrectionHighlight.spans(in: text, edits: [gated])
        XCTAssertEqual(spans1[0].startSeconds, 0.5, "span must carry the edit's startSeconds")
        XCTAssertEqual(spans1[0].endSeconds, 0.9, "span must carry the edit's endSeconds")

        // Reconstruct exactly like AppState.editRecordFor (preserving timestamps).
        let reconstructed = spans1.map {
            EditRecord(stage: $0.stage, original: $0.original,
                       replacement: $0.replacement, applied: true, wordRange: $0.wordRange,
                       startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                       reason: $0.reason)
        }
        XCTAssertEqual(reconstructed[0].startSeconds, 0.5,
                       "timestamps must survive the editRecordFor re-map round-trip")
        XCTAssertEqual(reconstructed[0].endSeconds, 0.9,
                       "timestamps must survive the editRecordFor re-map round-trip")
    }

    func testSingleAppliedEditMapsToItsRange() {
        let text = "I love Parleq for dictation"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("parlay", "Parleq")])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].number, 1)
        XCTAssertEqual(spans[0].original, "parlay")
        XCTAssertEqual(spans[0].replacement, "Parleq")
        XCTAssertEqual(slice(text, spans[0]), "Parleq")
    }

    func testUnappliedEditsAreIgnored() {
        let text = "the quick brown fox"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("kwik", "quick", applied: false),
        ])
        XCTAssertTrue(spans.isEmpty)
    }

    // MARK: Task 6 — margin-gated "considered" over-fire surfacing

    func testConsideredEditBelowThresholdSurfacesFlaggedSpan() {
        // Feature A: a "considered" record (applied: false, replacement == original,
        // non-empty) with a BORDERLINE (small) gate margin must surface as a span
        // flagged isValidateConsidered, even though `applied` is false.
        let text = "the confusable word"
        let considered = EditRecord(
            stage: .dictionary, original: "confusable", replacement: "confusable",
            applied: false, gateDecision: "accept",
            gateMargin: LocalConcordConstants.consideredBorderlineMargin - 0.01,
            wordRange: 1..<2, reason: "acoustic-validate considered")
        let spans = CorrectionHighlight.spans(in: text, edits: [considered])
        XCTAssertEqual(spans.count, 1)
        XCTAssertTrue(spans[0].isValidateConsidered)
        XCTAssertEqual(spans[0].reason, "acoustic-validate considered")
        XCTAssertEqual(slice(text, spans[0]), "confusable")
    }

    func testConsideredEditAtExactThresholdSurfaces() {
        // The condition is `<=`, so a margin exactly AT the threshold is a
        // reachable, must-surface boundary case (RoboRev finding).
        let text = "the confusable word"
        let considered = EditRecord(
            stage: .dictionary, original: "confusable", replacement: "confusable",
            applied: false, gateDecision: "accept",
            gateMargin: LocalConcordConstants.consideredBorderlineMargin,
            wordRange: 1..<2, reason: "acoustic-validate considered")
        let spans = CorrectionHighlight.spans(in: text, edits: [considered])
        XCTAssertEqual(spans.count, 1)
        XCTAssertTrue(spans[0].isValidateConsidered)
    }

    func testConsideredEditAboveThresholdDoesNotSurface() {
        // A confident accept (large margin) is NOT borderline — must NOT surface,
        // even though it shares the "considered" reason string.
        let text = "the confusable word"
        let considered = EditRecord(
            stage: .dictionary, original: "confusable", replacement: "confusable",
            applied: false, gateDecision: "accept",
            gateMargin: LocalConcordConstants.consideredBorderlineMargin + 0.01,
            wordRange: 1..<2, reason: "acoustic-validate considered")
        let spans = CorrectionHighlight.spans(in: text, edits: [considered])
        XCTAssertTrue(spans.isEmpty)
    }

    func testConsideredEditWithNilMarginDoesNotSurface() {
        // No margin at all (shouldn't happen for a real considered record, but
        // the `?? .infinity` fallback must fail SAFE — never surface without a
        // margin to gate on).
        let text = "the confusable word"
        let considered = EditRecord(
            stage: .dictionary, original: "confusable", replacement: "confusable",
            applied: false, gateDecision: "accept", gateMargin: nil,
            wordRange: 1..<2, reason: "acoustic-validate considered")
        let spans = CorrectionHighlight.spans(in: text, edits: [considered])
        XCTAssertTrue(spans.isEmpty)
    }

    func testOrdinaryAppliedEditIsUnaffectedByConsideredWidening() {
        // A normal applied correction (no gate provenance at all) must still
        // surface exactly as before, and must NOT be flagged as considered.
        let text = "I love Parleq for dictation"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("parlay", "Parleq")])
        XCTAssertEqual(spans.count, 1)
        XCTAssertFalse(spans[0].isValidateConsidered)
    }

    func testEmptyReplacementIsIgnored() {
        // Pure deletions have no visible span to mark.
        let text = "hello world"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("uh", "")])
        XCTAssertTrue(spans.isEmpty)
    }

    func testNumberingFollowsReadingOrder() {
        // Two edits, lower wordRange first; numbered 1,2 left-to-right.
        let text = "send to iTerm then open API docs"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("api", "API", range: 5..<6),
            edit("iterm", "iTerm", range: 2..<3),
        ])
        XCTAssertEqual(spans.map(\.number), [1, 2])
        XCTAssertEqual(spans.map(\.replacement), ["iTerm", "API"])
        XCTAssertEqual(slice(text, spans[0]), "iTerm")
        XCTAssertEqual(slice(text, spans[1]), "API")
    }

    func testRepeatedReplacementMapsToSuccessiveOccurrences() {
        // Same replacement text twice — each edit lands on a DISTINCT occurrence.
        let text = "API and API again"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("api", "API", range: 0..<1),
            edit("api", "API", range: 2..<3),
        ])
        XCTAssertEqual(spans.count, 2)
        // Distinct ranges.
        XCTAssertNotEqual(spans[0].range, spans[1].range)
        XCTAssertTrue(spans[0].range.lowerBound < spans[1].range.lowerBound)
        XCTAssertEqual(slice(text, spans[0]), "API")
        XCTAssertEqual(slice(text, spans[1]), "API")
    }

    func testReplacementNotPresentIsDroppedNotCrashing() {
        // An edit whose replacement isn't in the (manually rewritten) text is
        // dropped; the remaining edit still maps and stays numbered.
        let text = "I love Parleq"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("ghost", "vanished"),          // not present → dropped
            edit("parlay", "Parleq"),
        ])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].number, 1)
        XCTAssertEqual(spans[0].replacement, "Parleq")
    }

    func testEmptyEditsYieldsEmptySpans() {
        XCTAssertTrue(CorrectionHighlight.spans(in: "anything", edits: []).isEmpty)
    }

    // MARK: revert()

    func testRevertReplacesSpanWithOriginal() {
        let text = "I love Parleq for dictation"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("parlay", "Parleq")])
        let reverted = CorrectionHighlight.revert(text: text, span: spans[0])
        XCTAssertEqual(reverted, "I love parlay for dictation")
    }

    func testRevertOnlyTheTargetedOccurrence() {
        let text = "API and API again"
        let spans = CorrectionHighlight.spans(in: text, edits: [
            edit("api", "API", range: 0..<1),
            edit("api", "API", range: 2..<3),
        ])
        // Revert the SECOND occurrence only.
        let reverted = CorrectionHighlight.revert(text: text, span: spans[1])
        XCTAssertEqual(reverted, "API and api again")
    }

    func testReMapAfterRevertRenumbersRemaining() {
        // Simulate AppState's re-map: revert #1, then re-derive spans for the
        // survivor — it should renumber to 1.
        let text = "send to iTerm then open API docs"
        let edits = [
            edit("iterm", "iTerm", range: 2..<3),
            edit("api", "API", range: 5..<6),
        ]
        var spans = CorrectionHighlight.spans(in: text, edits: edits)
        let reverted = CorrectionHighlight.revert(text: text, span: spans[0]) // undo iTerm
        XCTAssertEqual(reverted, "send to iterm then open API docs")
        // Re-map the survivor (API) against the new text.
        let survivors = [edit("api", "API")]
        spans = CorrectionHighlight.spans(in: reverted, edits: survivors)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].number, 1)
        XCTAssertEqual(slice(reverted, spans[0]), "API")
    }

    // MARK: Task 7 — considered-flag undo routes to edit-at-word, not revert

    /// `planUndo` is the pure decision AppState.undoCorrection delegates to:
    /// given the shown text + current spans + the pressed number, decide
    /// whether this is an ordinary revert or (Feature A) a "considered"
    /// over-fire that must route into edit-at-word instead. Testing this pure
    /// function exercises the routing decision without needing a live
    /// AppState/OverlayWindow (which nothing in this suite constructs).

    private func consideredEdit(
        _ word: String, range: Range<Int>, margin: Double = LocalConcordConstants.consideredBorderlineMargin
    ) -> EditRecord {
        EditRecord(stage: .dictionary, original: word, replacement: word,
                   applied: false, gateDecision: "accept", gateMargin: margin,
                   wordRange: range, reason: "acoustic-validate considered")
    }

    func testPlanUndoOnConsideredSpanDoesNotMutateText() {
        // (a) no text mutation: a considered span has original == replacement,
        // so a text revert would be a silent no-op. The plan for a considered
        // span must be `.editAtWord`, which carries NO text at all — by
        // construction there is nothing for the caller to mutate `currentText`
        // with.
        let text = "the confusable word is here"
        let spans = CorrectionHighlight.spans(in: text, edits: [consideredEdit("confusable", range: 1..<2)])
        XCTAssertEqual(spans.count, 1)
        XCTAssertTrue(spans[0].isValidateConsidered)

        guard let action = CorrectionHighlight.planUndo(text: text, spans: spans, number: 1) else {
            return XCTFail("expected a plan for the considered span")
        }
        guard case .editAtWord = action else {
            return XCTFail("expected .editAtWord for a considered span, got \(action)")
        }
    }

    func testPlanUndoOnConsideredSpanRemovesAndRenumbersRemainder() {
        // (b) span removed + remainder renumbered — same mechanics as an
        // ordinary undo's re-map, just against the UNCHANGED text.
        let text = "send to iTerm then open confusable docs"
        let edits = [
            edit("iterm", "iTerm", range: 2..<3),
            consideredEdit("confusable", range: 5..<6),
        ]
        let spans = CorrectionHighlight.spans(in: text, edits: edits)
        XCTAssertEqual(spans.count, 2)
        let consideredNumber = spans.first { $0.isValidateConsidered }!.number

        guard let action = CorrectionHighlight.planUndo(text: text, spans: spans, number: consideredNumber),
              case .editAtWord(let remaining, _) = action else {
            return XCTFail("expected .editAtWord for the considered span")
        }
        XCTAssertEqual(remaining.count, 1, "the considered flag must be dropped from the overlay")
        XCTAssertEqual(remaining[0].replacement, "iTerm")
        XCTAssertEqual(remaining[0].number, 1, "the surviving span must renumber to 1")
    }

    func testPlanUndoOnConsideredSpanSignalsFocusWordRange() {
        // (c) "enter edit mode at this word": the plan must carry the
        // considered span's wordRange forward so the caller can position the
        // edit-at-word entry.
        let text = "the confusable word is here"
        let spans = CorrectionHighlight.spans(in: text, edits: [consideredEdit("confusable", range: 1..<2)])
        guard let action = CorrectionHighlight.planUndo(text: text, spans: spans, number: 1),
              case .editAtWord(_, let focusWordRange) = action else {
            return XCTFail("expected .editAtWord for the considered span")
        }
        XCTAssertEqual(focusWordRange, 1..<2, "must carry the considered span's wordRange forward")
    }

    func testPlanUndoOnOrdinaryCorrectionStillReverts() {
        // Ordinary corrections' undo behavior is UNCHANGED by Task 7: a normal
        // applied edit still plans a text revert, not edit-at-word.
        let text = "I love Parleq for dictation"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("parlay", "Parleq")])
        guard let action = CorrectionHighlight.planUndo(text: text, spans: spans, number: 1) else {
            return XCTFail("expected a plan for the ordinary span")
        }
        guard case .revert(let newText, let remaining) = action else {
            return XCTFail("expected .revert for an ordinary correction, got \(action)")
        }
        XCTAssertEqual(newText, "I love parlay for dictation")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPlanUndoReturnsNilForUnknownNumber() {
        let text = "I love Parleq for dictation"
        let spans = CorrectionHighlight.spans(in: text, edits: [edit("parlay", "Parleq")])
        XCTAssertNil(CorrectionHighlight.planUndo(text: text, spans: spans, number: 99))
    }

    func testEditRecordForRoundTripsWordRangeTimestampsAndReason() {
        // CorrectionHighlight.editRecord(for:) is the shared reconstruction
        // AppState.editRecordFor now delegates to — pin the round-trip here so
        // a future edit to either can't silently drop a field (RoboRev-7511
        // class of bug).
        let text = "the Claude provider"
        let gated = EditRecord(stage: .dictionary, original: "cloud", replacement: "Claude",
                               applied: true, wordRange: 1..<2,
                               startSeconds: 0.5, endSeconds: 0.9,
                               reason: "acoustic-validate revert")
        let span = CorrectionHighlight.spans(in: text, edits: [gated])[0]
        let reconstructed = CorrectionHighlight.editRecord(for: span)
        XCTAssertEqual(reconstructed.wordRange, 1..<2)
        XCTAssertEqual(reconstructed.startSeconds, 0.5)
        XCTAssertEqual(reconstructed.endSeconds, 0.9)
        XCTAssertEqual(reconstructed.reason, "acoustic-validate revert")
        XCTAssertTrue(reconstructed.applied)
    }
}
#endif
