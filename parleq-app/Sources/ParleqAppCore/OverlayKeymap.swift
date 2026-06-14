// OverlayKeymap — pure key resolution for the review overlay's in-place edit
// mode (#85). The overlay is read-only with single-key review gestures
// (Enter/Esc/Space/C/V/P/1–9) until E enters edit mode, which suspends those
// gestures and applies an editor keymap. Keeping the decision table here (off
// the NSPanel) makes it unit-testable; the panel/focus wiring consumes it.
import Foundation

public enum OverlayKeymap {
    /// The keys this resolver distinguishes; everything else is `.other`.
    public enum Key: Equatable, Sendable {
        case returnKey
        case escape
        case letterE
        case letterS
        case other
    }

    public enum Action: Equatable, Sendable {
        case enterEditMode      // bare E in review → focus the editor
        case insertNewline      // Return (no ⌘) in edit mode
        case commitAndAccept    // ⌘Return in edit mode → keep edits + paste
        case saveAndReview      // ⌘S in edit mode → keep edits, back to review
        case discardAndReview   // Esc in edit mode → drop edits, back to review
        case reviewKey          // not editing: hand to the existing review-key handler
        case typeIntoEditor     // editing: an ordinary character — let the editor handle it
    }

    /// `hasOtherModifiers` covers Shift/Control/Option (anything but Command).
    /// It gates the bare-E review gesture so only an unmodified E enters edit
    /// mode (matching the other single-key review gestures); it's irrelevant in
    /// edit mode, where only Command distinguishes the shortcuts from typing.
    public static func action(
        key: Key, hasCommand: Bool, hasOtherModifiers: Bool = false, isEditing: Bool
    ) -> Action {
        if !isEditing {
            // Only a truly bare E opens edit mode; E with ANY modifier (incl. ⌘E,
            // Shift+E, Option+E) is a review key, like the V/C/P gestures.
            let bareE = key == .letterE && !hasCommand && !hasOtherModifiers
            return bareE ? .enterEditMode : .reviewKey
        }
        switch key {
        case .escape:
            return .discardAndReview
        case .returnKey:
            return hasCommand ? .commitAndAccept : .insertNewline
        case .letterS:
            return hasCommand ? .saveAndReview : .typeIntoEditor
        case .letterE, .other:
            return .typeIntoEditor
        }
    }
}
