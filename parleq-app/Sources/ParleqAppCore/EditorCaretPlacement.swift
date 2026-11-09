// EditorCaretPlacement — click-to-edit support for the review overlay.
//
// Clicking the review text opens the in-place editor with the caret at the
// clicked spot. The click is recorded in the review text's OWN coordinates
// (top-left of the text), not the screen, so the result doesn't depend on how
// far the overlay was scrolled. Those coordinates are then fed to the editor's
// own NSTextView layout (SwiftUI's TextEditor is NSTextView-backed on macOS),
// which avoids re-deriving glyph positions from SwiftUI's Text layout.
//
// Logs nothing: no geometry, no indices, no text.

import AppKit

/// Where the user clicked to open the editor.
struct EditClick: Equatable {
    /// Location inside the review text, origin at its top-left.
    let textPoint: CGPoint
    /// Screen y of the click (AppKit screen coordinates, y up). Used to keep the
    /// clicked line at the same height on screen once the editor is up.
    let screenY: CGFloat
}

/// Content-area layout rule, kept pure so it can be unit tested.
enum OverlayContentLayout {
    /// Whether `contentArea` wraps the content in its fixed-height ScrollView.
    ///
    /// Never while editing: the editor's height differs from the review text's,
    /// so re-measuring mid-edit could cross the threshold, and crossing the
    /// if/else in `contentArea` rebuilds the TextEditor — dropping focus after a
    /// keystroke and, once seen, blanking the text. The editor caps itself at the
    /// threshold and scrolls internally instead.
    static func usesScrollContainer(measuredHeight: CGFloat,
                                    threshold: CGFloat,
                                    editing: Bool) -> Bool {
        !editing && measuredHeight > threshold
    }
}

@MainActor
enum EditorCaretPlacement {
    /// Settle delay before the focus fallback. SwiftUI's @FocusState normally
    /// lands within this window; the fallback covers the cases where it doesn't.
    static let settleDelay: TimeInterval = 0.2

    /// New clip-view bounds origin y that puts a line whose top is currently at
    /// `lineTopOnScreen` at `wantedTopOnScreen` (both AppKit screen y, y up).
    /// Unclamped; the caller constrains it to the scrollable range.
    static func clipOriginY(currentOriginY: CGFloat,
                            lineTopOnScreen: CGFloat,
                            wantedTopOnScreen: CGFloat,
                            clipIsFlipped: Bool) -> CGFloat {
        let delta = wantedTopOnScreen - lineTopOnScreen
        // Flipped clip (y down): a larger origin moves content up on screen.
        return currentOriginY + (clipIsFlipped ? delta : -delta)
    }

    /// Called when the in-place editor appears in `panel`. Aligns the editor's
    /// text with the review text, places the caret at `click` when the editor
    /// was opened by a click, and makes sure the editor ends up focused.
    static func editorDidAppear(in panel: NSWindow, click: EditClick?) {
        DispatchQueue.main.async {
            guard let textView = editorTextView(in: panel) else { return }
            // TextEditor's default 5pt line-fragment padding shifts its text right
            // of the review Text; zero it so the editor opens without a sideways
            // jump and the click maps to the same glyph.
            textView.textContainer?.lineFragmentPadding = 0
            var placed: NSRange?
            if let click {
                placed = placeCaret(click, in: textView, panel: panel)
            }
            let textAtPlacement = textView.string
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                // The editor may have closed (Esc / ⌘S) or been rebuilt meanwhile.
                guard panel.isVisible, editorTextView(in: panel) === textView else { return }
                if panel.firstResponder !== textView {
                    panel.makeFirstResponder(textView)
                }
                // Focus arriving can move the selection; restore the placed caret
                // unless the user has already typed.
                if let placed, textView.string == textAtPlacement,
                   textView.selectedRange() != placed {
                    textView.setSelectedRange(placed)
                    textView.scrollRangeToVisible(placed)
                }
            }
        }
    }

    /// The in-place editor's text view: the panel's only non-field-editor,
    /// editable NSTextView.
    static func editorTextView(in panel: NSWindow) -> NSTextView? {
        guard let root = panel.contentView else { return nil }
        func find(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, tv.isEditable, !tv.isFieldEditor { return tv }
            for sub in view.subviews {
                if let tv = find(sub) { return tv }
            }
            return nil
        }
        return find(root)
    }

    private static func placeCaret(_ click: EditClick,
                                   in textView: NSTextView,
                                   panel: NSWindow) -> NSRange? {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let point = NSPoint(x: click.textPoint.x + origin.x, y: click.textPoint.y + origin.y)
        let index = textView.characterIndexForInsertion(at: point)
        let range = NSRange(location: index, length: 0)
        textView.setSelectedRange(range)

        let length = (textView.string as NSString).length
        guard length > 0 else { return range }
        let glyph = layout.glyphIndexForCharacter(at: min(index, length - 1))
        var lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        lineRect.origin.x += origin.x
        lineRect.origin.y += origin.y

        // Bring the line into view through each enclosing scroller (innermost
        // first), then scroll so it sits where the user clicked.
        var current: NSView = textView
        while let scroller = current.enclosingScrollView, let document = scroller.documentView {
            document.scrollToVisible(textView.convert(lineRect, to: document))
            let clip = scroller.contentView
            let lineTopInWindow = textView.convert(lineRect.origin, to: nil)
            let lineTopOnScreen = panel.convertPoint(toScreen: lineTopInWindow).y
            var bounds = clip.bounds
            bounds.origin.y = clipOriginY(currentOriginY: bounds.origin.y,
                                          lineTopOnScreen: lineTopOnScreen,
                                          wantedTopOnScreen: click.screenY + lineRect.height / 2,
                                          clipIsFlipped: clip.isFlipped)
            clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
            scroller.reflectScrolledClipView(clip)
            current = scroller
        }
        return range
    }
}
