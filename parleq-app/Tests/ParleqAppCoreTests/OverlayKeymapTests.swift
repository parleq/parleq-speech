import XCTest
@testable import ParleqAppCore

/// Pure key resolution for #85's in-place edit mode. The overlay stays read-only
/// with single-key review gestures until E enters edit mode, which suspends those
/// gestures and applies the edit keymap (Enter=newline, ⌘Enter=commit+accept,
/// ⌘S=save→review, Esc=discard→review). The NSPanel keyDown + focus wiring is
/// verified in the manual walkthrough; this decision table is pure and tested here.
final class OverlayKeymapTests: XCTestCase {

    // MARK: review state (not editing)

    func testEEntersEditMode() {
        XCTAssertEqual(OverlayKeymap.action(key: .letterE, hasCommand: false, isEditing: false),
                       .enterEditMode)
    }

    func testCommandEDoesNotEnterEditMode() {
        // ⌘E is not the bare-E gesture — leave it to the review-key handler.
        XCTAssertEqual(OverlayKeymap.action(key: .letterE, hasCommand: true, isEditing: false),
                       .reviewKey)
    }

    func testOtherKeysInReviewGoToReviewHandler() {
        XCTAssertEqual(OverlayKeymap.action(key: .returnKey, hasCommand: false, isEditing: false),
                       .reviewKey)
        XCTAssertEqual(OverlayKeymap.action(key: .escape, hasCommand: false, isEditing: false),
                       .reviewKey)
        XCTAssertEqual(OverlayKeymap.action(key: .other, hasCommand: false, isEditing: false),
                       .reviewKey)
    }

    // MARK: edit mode

    func testEnterIsNewlineInEditMode() {
        XCTAssertEqual(OverlayKeymap.action(key: .returnKey, hasCommand: false, isEditing: true),
                       .insertNewline)
    }

    func testCommandEnterCommitsAndAccepts() {
        XCTAssertEqual(OverlayKeymap.action(key: .returnKey, hasCommand: true, isEditing: true),
                       .commitAndAccept)
    }

    func testCommandSSavesAndReturnsToReview() {
        XCTAssertEqual(OverlayKeymap.action(key: .letterS, hasCommand: true, isEditing: true),
                       .saveAndReview)
    }

    func testEscapeDiscardsAndReturnsToReview() {
        XCTAssertEqual(OverlayKeymap.action(key: .escape, hasCommand: false, isEditing: true),
                       .discardAndReview)
    }

    func testPlainSTypesIntoEditor() {
        // Bare S in edit mode is just a character — only ⌘S saves.
        XCTAssertEqual(OverlayKeymap.action(key: .letterS, hasCommand: false, isEditing: true),
                       .typeIntoEditor)
    }

    func testPlainETypesIntoEditor() {
        XCTAssertEqual(OverlayKeymap.action(key: .letterE, hasCommand: false, isEditing: true),
                       .typeIntoEditor)
    }

    func testOtherKeysTypeIntoEditor() {
        XCTAssertEqual(OverlayKeymap.action(key: .other, hasCommand: false, isEditing: true),
                       .typeIntoEditor)
    }
}
