// ConversationState — references + multi-turn history for a single
// dictation overlay session.
//
// One ConversationState exists per overlay session. It is created
// when dictation starts and discarded on accept / cancel / fresh
// hotkey from idle. References are immutable for the session's
// lifetime in Phase 1 (add/remove between turns is a Phase 2
// affordance). Turns accumulate as the user iterates.

import Foundation

@MainActor
final class ConversationState {
    /// Captured references attached to this session. Phase 1: filled
    /// once before the first turn fires; not mutated until session
    /// ends. Phase 2 will permit add/remove between turns.
    private(set) var references: [Reference] = []

    /// Each turn: the user's dictated instruction + the streamed
    /// assistant response. Streaming model: chunks accumulate into
    /// `assistantResponse` as they arrive; `isComplete` flips to true
    /// when the provider signals end-of-stream. The pair (response,
    /// isComplete) keeps the streaming vs. completed invariant
    /// unambiguous through the lifecycle — beginTurn() can refuse to
    /// open a new turn while a prior one is still streaming.
    private(set) var turns: [Turn] = []

    struct Turn {
        var userInstruction: String
        var assistantResponse: String  // built incrementally via appendToCurrentTurn
        var isComplete: Bool           // flipped by finalizeCurrentTurn
    }

    /// Replace references wholesale (Phase 1 — single set at session start).
    func setReferences(_ refs: [Reference]) {
        references = refs
    }

    /// Begin a new turn with the given user instruction.
    /// Returns true if appended; false if the previous turn is still
    /// streaming (caller should finalize before starting a new one).
    @discardableResult
    func beginTurn(userInstruction: String) -> Bool {
        if let last = turns.last, !last.isComplete {
            return false
        }
        turns.append(Turn(
            userInstruction: userInstruction,
            assistantResponse: "",
            isComplete: false
        ))
        return true
    }

    /// Append a streamed chunk to the current turn. Logs and no-ops if
    /// there is no open turn or the current turn is already complete —
    /// either indicates a late callback after session reset / accept.
    func appendToCurrentTurn(_ chunk: String) {
        guard !turns.isEmpty else { return }
        let i = turns.count - 1
        guard !turns[i].isComplete else { return }
        turns[i].assistantResponse += chunk
    }

    /// Mark the current turn as complete (provider signaled end-of-stream).
    /// The accumulated `assistantResponse` becomes the final output.
    func finalizeCurrentTurn() {
        guard !turns.isEmpty else { return }
        let i = turns.count - 1
        turns[i].isComplete = true
    }

    /// True when this session has at least one reference attached.
    var isReferenceAware: Bool {
        !references.isEmpty
    }

    /// The user-visible "current cleaned text" — last turn's assistant
    /// response, or empty string if streaming has not produced any
    /// output yet.
    var currentOutput: String {
        turns.last?.assistantResponse ?? ""
    }
}

#if DEBUG
extension ConversationState {
    static func sample() -> ConversationState {
        let s = ConversationState()
        s.setReferences([Reference.sampleWindow])
        _ = s.beginTurn(userInstruction: "Reply confirming Tuesday at 2pm")
        s.appendToCurrentTurn("Hi Sam — Tuesday at 2pm works. I'll bring the deck. Thanks!")
        s.finalizeCurrentTurn()
        return s
    }
}
#endif
