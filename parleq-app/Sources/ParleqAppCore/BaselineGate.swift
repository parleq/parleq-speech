// BaselineGate — coordination primitive for the chained-refine flow.
//
// When the user presses the hotkey while the FIRST cleanup is still
// streaming (phase == .cleaning), Parleq captures the refine
// instruction immediately WITHOUT cancelling that cleanup. The cleanup
// runs to completion in the background and its final text becomes the
// baseline the refine operates on. The refine pass must therefore wait
// for that baseline before it builds its messages.
//
// This gate is that wait. The background cleanup `resolve(_:)`s the gate
// with its final text (the cleaned output, or the raw fallback on
// failure — both are valid baselines); the refine task `await`s
// `value`. Two orderings both work:
//   - cleanup finishes BEFORE the refine awaits → `value` returns the
//     already-resolved text immediately (zero added latency);
//   - refine awaits BEFORE cleanup finishes → the await suspends and
//     wakes when the cleanup resolves.
//
// `cancel()` (Esc / teardown) releases any pending awaiter with the
// gate's last-known text so no awaiting task leaks.
//
// @MainActor because the whole AppState state machine — including the
// cleanup-completion callback and the refine task — runs on the main
// actor; resolution and awaiting are therefore provably serial and need
// no extra locking. Resolution is idempotent: the cleanup completes
// exactly once, but a defensive double-resolve keeps the first value.

import Foundation

@MainActor
final class BaselineGate {
    private var resolved = false
    private var text: String = ""
    /// Continuations of awaiters that arrived before resolution. Woken
    /// in resolve()/cancel(). Plural so multiple awaiters (e.g. a
    /// defensive second reader) all wake with the same value.
    private var waiters: [CheckedContinuation<String, Never>] = []

    init() {}

    /// Resolve the baseline with `finalText`. Idempotent — the first
    /// resolution wins; later calls are ignored. Wakes every pending
    /// awaiter with the resolved text.
    func resolve(_ finalText: String) {
        guard !resolved else { return }
        resolved = true
        text = finalText
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume(returning: finalText) }
    }

    /// Release any pending awaiter without a real baseline (Esc /
    /// teardown). Resolves with the last-known text (empty unless a
    /// prior resolve set it) so awaiters don't hang. Idempotent.
    func cancel() {
        guard !resolved else {
            // Already resolved — nothing is waiting; nothing to do.
            return
        }
        resolved = true
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume(returning: text) }
    }

    /// The resolved baseline text. Returns immediately if already
    /// resolved; otherwise suspends until resolve()/cancel().
    var value: String {
        get async {
            if resolved { return text }
            return await withCheckedContinuation { cont in
                if resolved {
                    // Resolved between the check above and here (can't
                    // happen on @MainActor without an await, but cheap
                    // to guard).
                    cont.resume(returning: text)
                } else {
                    waiters.append(cont)
                }
            }
        }
    }
}
