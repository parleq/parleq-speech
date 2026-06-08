import XCTest
@testable import ParleqAppCore

/// Unit tests for the chained-refine coordination primitive
/// (`BaselineGate`). The gate is how a refine issued WHILE the first
/// cleanup is still streaming awaits that cleanup's FINAL text before
/// running its own pass — covering both orderings (cleanup resolves
/// before or after the refine starts awaiting) and the failure path
/// (a raw-fallback baseline is still a valid resolution).
///
/// These are the deterministically-unit-testable heart of the chained-
/// refine fix; the full AppState state-machine wiring (which touches
/// AppKit windows + the audio engine) is exercised by the morning
/// live test.
@MainActor
final class BaselineGateTests: XCTestCase {
    // Ordering A: the baseline resolves BEFORE the consumer awaits.
    // The await must return the already-resolved value immediately.
    func test_resolve_before_await_returns_value() async {
        let gate = BaselineGate()
        gate.resolve("final cleaned text")
        let value = await gate.value
        XCTAssertEqual(value, "final cleaned text")
    }

    // Ordering B: the consumer awaits BEFORE the baseline resolves.
    // The await must suspend, then wake with the resolved value once
    // the producer resolves — and it must observe resolution AFTER the
    // producer ran (the whole point of the await).
    func test_await_before_resolve_suspends_then_returns() async {
        let gate = BaselineGate()
        let producerRan = Expectation()

        let consumer = Task { @MainActor () -> String in
            await gate.value
        }
        // Give the consumer a chance to start awaiting.
        await Task.yield()
        XCTAssertFalse(consumer.isCancelled)

        producerRan.fulfill()
        gate.resolve("baseline after suspend")

        let value = await consumer.value
        XCTAssertTrue(producerRan.didFulfill)
        XCTAssertEqual(value, "baseline after suspend")
    }

    // The failure path: a raw-fallback baseline is resolved exactly the
    // same way as a successful cleanup — the gate carries whatever text
    // the producer hands it, including the raw fallback.
    func test_resolve_with_fallback_text_is_a_valid_baseline() async {
        let gate = BaselineGate()
        gate.resolve("raw fallback transcript")
        let value = await gate.value
        XCTAssertEqual(value, "raw fallback transcript")
    }

    // Idempotent resolution: a second resolve does not overwrite the
    // first (the cleanup completes exactly once; defensive against a
    // double-fire). Multiple awaiters all get the first value.
    func test_resolve_is_idempotent_and_fans_out_to_all_awaiters() async {
        let gate = BaselineGate()

        let a = Task { @MainActor in await gate.value }
        let b = Task { @MainActor in await gate.value }
        await Task.yield()

        gate.resolve("first")
        gate.resolve("second-ignored")

        let va = await a.value
        let vb = await b.value
        XCTAssertEqual(va, "first")
        XCTAssertEqual(vb, "first")
    }

    // A consumer awaiting a gate that is never resolved is freed when the
    // gate is cancelled (Esc / teardown), so no task leaks. Cancellation
    // resolves any waiters with the gate's last-known text (empty here).
    func test_cancel_releases_pending_awaiter() async {
        let gate = BaselineGate()
        let consumer = Task { @MainActor in await gate.value }
        await Task.yield()
        gate.cancel()
        let value = await consumer.value
        XCTAssertEqual(value, "")
    }
}

/// Tiny @MainActor fulfillment flag for ordering assertions (avoids the
/// XCTestExpectation main-thread fulfill timing quirks for these
/// synchronous-on-MainActor checks).
@MainActor
private final class Expectation {
    private(set) var didFulfill = false
    func fulfill() { didFulfill = true }
}
