import XCTest
import CoreGraphics
@testable import ParleqAppCore

/// Unit tests for the synthetic-paste flag composition and the
/// modifier-clear predicate that fix the long-standing tap-accept
/// drop: tapping the dictation hotkey (a modifier) to accept could
/// post Cmd-V while that modifier was still physically down, so the
/// target saw Cmd-Option-V and ignored the paste.
///
/// The CGEvent POST can't run headless, but the two decisions that
/// make the fix correct — "what flags does the synthetic event
/// carry?" and "is it safe to post yet?" — are pure functions and are
/// exercised here. Enter-accept (no modifier held) must proceed
/// immediately; tap-accept (modifier set) must report not-clear until
/// the modifier lifts.
final class PasterFlagCompositionTests: XCTestCase {

    // MARK: - pasteEventFlags: always exactly Command

    func test_paste_event_flags_are_exactly_command() {
        // The synthetic Cmd-V's OWN flags are overridden, never
        // inherited. No matter what, the result is precisely
        // .maskCommand — no Option/Shift/Control/Fn can ride along.
        XCTAssertEqual(Paster.pasteEventFlags(), .maskCommand)
    }

    func test_paste_event_flags_command_bit_is_set() {
        XCTAssertTrue(Paster.pasteEventFlags().contains(.maskCommand),
                      "Command must be present or Cmd-V wouldn't paste")
    }

    func test_paste_event_flags_strip_all_corrupting_modifiers() {
        // Defensive: the outgoing flags must contain none of the
        // modifiers that, riding along, would turn Cmd-V into a
        // shortcut apps ignore.
        let outgoing = Paster.pasteEventFlags()
        XCTAssertFalse(outgoing.contains(.maskAlternate), "Option must be stripped")
        XCTAssertFalse(outgoing.contains(.maskControl), "Control must be stripped")
        XCTAssertFalse(outgoing.contains(.maskShift), "Shift must be stripped")
        XCTAssertFalse(outgoing.contains(.maskSecondaryFn), "Fn must be stripped")
    }

    // MARK: - modifierMaskClear: the bounded-wait predicate

    func test_no_modifiers_held_proceeds_immediately() {
        // Enter-accept path: nothing held → clear → post now.
        let state: CGEventFlags = []
        XCTAssertTrue(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers),
            "With no modifiers down (Enter accept), paste must proceed immediately"
        )
    }

    func test_hotkey_option_still_down_is_not_clear() {
        // Tap-accept with the default right-Option hotkey still
        // physically down: NOT clear → the wait loop must keep polling.
        let state: CGEventFlags = .maskAlternate
        XCTAssertFalse(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers),
            "Option held (the racy tap-accept window) must block the post"
        )
    }

    func test_control_hotkey_still_down_is_not_clear() {
        // The hotkey is configurable; Control-* is a valid binding.
        let state: CGEventFlags = .maskControl
        XCTAssertFalse(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers))
    }

    func test_shift_hotkey_still_down_is_not_clear() {
        let state: CGEventFlags = .maskShift
        XCTAssertFalse(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers))
    }

    func test_fn_hotkey_still_down_is_not_clear() {
        let state: CGEventFlags = .maskSecondaryFn
        XCTAssertFalse(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers))
    }

    func test_modifier_lifted_becomes_clear() {
        // Simulate the transition the wait loop is waiting for: the
        // modifier was down, then the user's key-up propagated.
        let held: CGEventFlags = .maskAlternate
        XCTAssertFalse(
            Paster.modifierMaskClear(state: held, mask: Paster.pasteCorruptingModifiers))
        let lifted: CGEventFlags = []
        XCTAssertTrue(
            Paster.modifierMaskClear(state: lifted, mask: Paster.pasteCorruptingModifiers),
            "Once the hotkey modifier lifts, the post must be allowed to proceed"
        )
    }

    func test_unrelated_flags_do_not_block_paste() {
        // Caps-lock / numeric-pad / coalesced device bits are not in
        // the corrupting set and must NOT hold up the paste — only the
        // shortcut-corrupting modifiers gate it.
        let state: CGEventFlags = [.maskAlphaShift, .maskNumericPad]
        XCTAssertTrue(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers),
            "Caps-lock / numeric-pad must not block the paste (they don't corrupt Cmd-V)"
        )
    }

    func test_multiple_modifiers_held_is_not_clear() {
        let state: CGEventFlags = [.maskAlternate, .maskShift]
        XCTAssertFalse(
            Paster.modifierMaskClear(state: state, mask: Paster.pasteCorruptingModifiers))
    }

    // MARK: - corrupting-modifier set composition

    func test_corrupting_modifier_set_covers_every_hotkey_family() {
        // Every modifier a hotkey binding can use must be in the
        // corrupting set, or that binding's tap-accept would still be
        // able to leak its modifier onto the paste.
        let set = Paster.pasteCorruptingModifiers
        XCTAssertTrue(set.contains(.maskCommand))
        XCTAssertTrue(set.contains(.maskAlternate))
        XCTAssertTrue(set.contains(.maskControl))
        XCTAssertTrue(set.contains(.maskShift))
        XCTAssertTrue(set.contains(.maskSecondaryFn))
    }
}
