import XCTest
@testable import ParleqAppCore

@MainActor
final class ConversationStateTests: XCTestCase {
    func test_initial_state_has_no_references() {
        let state = ConversationState()
        XCTAssertEqual(state.references.count, 0)
        XCTAssertFalse(state.isReferenceAware)
        XCTAssertEqual(state.currentOutput, "")
    }

    func test_set_references_makes_reference_aware() {
        let state = ConversationState()
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.apple.safari", title: "Test"),
            label: "Test",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "some text",
            imageData: nil
        )
        state.setReferences([ref])
        XCTAssertTrue(state.isReferenceAware)
        XCTAssertEqual(state.references.count, 1)
        XCTAssertEqual(state.references[0].label, "Test")
    }

    func test_turn_lifecycle_begin_append_finalize() {
        let state = ConversationState()
        let started = state.beginTurn(userInstruction: "Write a summary")
        XCTAssertTrue(started)
        XCTAssertEqual(state.currentOutput, "")

        state.appendToCurrentTurn("Hello ")
        state.appendToCurrentTurn("world")
        XCTAssertEqual(state.currentOutput, "Hello world")

        state.finalizeCurrentTurn()
        XCTAssertEqual(state.currentOutput, "Hello world")
        XCTAssertTrue(state.turns.last?.isComplete == true)
    }

    // MARK: - Guard branches (RoboRev L28)

    func test_beginTurn_while_prior_turn_still_streaming_returns_false() {
        // beginTurn should return false (and not append a new turn) if
        // the previous turn has not yet been finalized.
        let state = ConversationState()
        let first = state.beginTurn(userInstruction: "Turn one")
        XCTAssertTrue(first, "First beginTurn on empty state should succeed")

        // Start a second turn without finalizing the first.
        let second = state.beginTurn(userInstruction: "Turn two")
        XCTAssertFalse(second, "beginTurn while prior turn is streaming should return false")

        // Only one turn should exist.
        XCTAssertEqual(state.turns.count, 1, "A rejected beginTurn must not append a new turn")
        XCTAssertEqual(state.turns[0].userInstruction, "Turn one")
    }

    func test_beginTurn_succeeds_after_prior_turn_finalized() {
        // Verify that finalizing the first turn re-opens the gate for a
        // second beginTurn — the standard happy-path multi-turn flow.
        let state = ConversationState()
        _ = state.beginTurn(userInstruction: "First")
        state.appendToCurrentTurn("response one")
        state.finalizeCurrentTurn()

        let second = state.beginTurn(userInstruction: "Second")
        XCTAssertTrue(second, "beginTurn after finalization should succeed")
        XCTAssertEqual(state.turns.count, 2)
    }

    func test_appendToCurrentTurn_when_no_turns_is_noop() {
        // appendToCurrentTurn with an empty turns array must not crash
        // and must leave the state unchanged.
        let state = ConversationState()
        state.appendToCurrentTurn("should be ignored")
        XCTAssertEqual(state.turns.count, 0)
        XCTAssertEqual(state.currentOutput, "")
    }

    func test_appendToCurrentTurn_after_finalize_is_noop() {
        // Late streaming callbacks after finalizeCurrentTurn (e.g. a
        // race between session reset and in-flight stream events) must
        // not modify the already-finalized response.
        let state = ConversationState()
        _ = state.beginTurn(userInstruction: "question")
        state.appendToCurrentTurn("good answer")
        state.finalizeCurrentTurn()

        // Late chunk after finalize.
        state.appendToCurrentTurn(" late chunk")

        XCTAssertEqual(state.currentOutput, "good answer", "Late chunk after finalize must be silently dropped")
        XCTAssertTrue(state.turns.last?.isComplete == true, "Turn must remain complete after late append")
    }

    func test_finalizeCurrentTurn_with_no_turns_is_noop() {
        // Calling finalizeCurrentTurn on a fresh ConversationState must
        // not crash and must leave the state empty.
        let state = ConversationState()
        state.finalizeCurrentTurn()
        XCTAssertEqual(state.turns.count, 0)
        XCTAssertEqual(state.currentOutput, "")
    }

    func test_currentOutput_reflects_streaming_chunks_before_finalize() {
        // Verify currentOutput accumulates correctly while streaming
        // (i.e. before finalizeCurrentTurn is called).
        let state = ConversationState()
        _ = state.beginTurn(userInstruction: "stream me")
        state.appendToCurrentTurn("part A")
        XCTAssertEqual(state.currentOutput, "part A")
        state.appendToCurrentTurn(", part B")
        XCTAssertEqual(state.currentOutput, "part A, part B")
    }
}
