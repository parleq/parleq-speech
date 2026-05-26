// HotkeyListener — global press-and-hold hotkey via CGEventTap.
//
// CGEventTap is the lowest-friction way on macOS to detect a modifier
// key being held down and released globally (i.e., regardless of
// which app is focused). The Carbon RegisterEventHotKey API can do
// global key+modifier chords but does not expose modifier-key release
// events, which we need for press-and-hold semantics.
//
// CGEventTap requires the Accessibility permission. The system shows
// a permission prompt the first time `CGEvent.tapCreate` runs from a
// process that hasn't been trusted yet. If the prompt is dismissed
// without granting access, `CGEvent.tapCreate` returns nil and we
// surface a clear error.
//
// v0.1 supports modifier-only press-and-hold bindings: option-left/
// right, control-left/right, command-left/right, shift-left/right,
// fn. Key-with-modifier chords (e.g. control+space) are deferred to
// a later milestone — they need a different detection path because
// CGEventTap delivers chord-key-down via .keyDown events, not
// .flagsChanged.
//
// Detection works by watching `flagsChanged` events, reading the raw
// keyCode to identify which physical modifier changed, and checking
// the device-dependent flag bits to distinguish press from release
// AND to disambiguate left vs right within the same modifier family.
// Auto-repeat doesn't fire on modifier holds, so we don't need
// debounce — just edge detection.

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public enum HotkeyError: Error, CustomStringConvertible {
    case accessibilityNotGranted
    case tapCreateFailed
    case runLoopSourceFailed
    case unknownBinding(String)

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            return """
                Accessibility permission required. Grant it in:
                  System Settings → Privacy & Security → Accessibility
                Then re-launch parleq-app.
                """
        case .tapCreateFailed:
            return "CGEvent.tapCreate returned nil (likely permission)."
        case .runLoopSourceFailed:
            return "CFMachPortCreateRunLoopSource returned nil."
        case .unknownBinding(let s):
            return """
                Unknown hotkey binding "\(s)". Supported v0.1 bindings:
                  option-left, option-right, control-left, control-right,
                  command-left, command-right, shift-left, shift-right, fn
                """
        }
    }
}

/// HotkeyBinding identifies one physical modifier key. v0.1 only
/// handles modifier-only press-and-hold bindings; key+modifier
/// chords land in a later milestone.
public struct HotkeyBinding: Sendable {
    /// The physical key's keyCode (CGKeyCode). The same key on left
    /// vs right (e.g. left-Option=58, right-Option=61) gets a
    /// different keyCode.
    public let keyCode: Int64
    /// Bit in CGEventFlags that's set when this key is held. Used
    /// to read the press state independently of other modifiers
    /// being held simultaneously. The values come from the
    /// device-dependent flag bits documented in IOKit/hidsystem.
    public let pressedFlagBit: UInt64
    /// Human-readable label for logs.
    public let displayName: String

    /// Parse a config-string binding like "option-right". Returns
    /// nil for unrecognized values; HotkeyListener.start surfaces
    /// the error.
    public static func parse(_ binding: String) -> HotkeyBinding? {
        switch binding.lowercased() {
        case "option-left", "alt-left":
            return HotkeyBinding(keyCode: 58, pressedFlagBit: 0x020, displayName: "left Option")
        case "option-right", "alt-right":
            return HotkeyBinding(keyCode: 61, pressedFlagBit: 0x040, displayName: "right Option")
        case "control-left", "ctrl-left":
            return HotkeyBinding(keyCode: 59, pressedFlagBit: 0x001, displayName: "left Control")
        case "control-right", "ctrl-right":
            return HotkeyBinding(keyCode: 62, pressedFlagBit: 0x2000, displayName: "right Control")
        case "command-left", "cmd-left":
            return HotkeyBinding(keyCode: 55, pressedFlagBit: 0x008, displayName: "left Command")
        case "command-right", "cmd-right":
            return HotkeyBinding(keyCode: 54, pressedFlagBit: 0x010, displayName: "right Command")
        case "shift-left":
            return HotkeyBinding(keyCode: 56, pressedFlagBit: 0x002, displayName: "left Shift")
        case "shift-right":
            return HotkeyBinding(keyCode: 60, pressedFlagBit: 0x004, displayName: "right Shift")
        case "fn":
            // Fn doesn't have a left/right distinction; the maskSecondaryFn
            // bit (0x800000) is the canonical "Fn pressed" indicator.
            return HotkeyBinding(keyCode: 63, pressedFlagBit: 0x800000, displayName: "Fn")
        default:
            return nil
        }
    }

    public static let defaultBinding = HotkeyBinding.parse("option-right")!
}

/// Context for a key-down event: which gesture variants apply.
public struct HotkeyDownEvent {
    /// True if this key-down landed within the double-tap window
    /// of the most recent key-up — i.e., the user is doing a
    /// double-tap-and-hold (quick-mode gesture).
    public let isDoubleTapHold: Bool
    /// True if either Shift key was held at the moment the hotkey
    /// went down. Used to open the staging mode (curate references
    /// before dictating).
    public let isShiftHeld: Bool
}

public final class HotkeyListener {
    /// Time window for treating "down → up → down (and hold)" as a
    /// double-tap-and-hold gesture. Empirically: 300 ms is faster
    /// than a deliberate hold-then-hold-again sequence and slow
    /// enough to forgive a fumbled tap.
    private static let doubleTapWindow: TimeInterval = 0.3

    /// Virtual keycode for the Space bar on US/QWERTY. macOS
    /// dispatches Space by keyCode regardless of layout, same as
    /// the modifier keys.
    private static let spaceKeyCode: Int64 = 0x31

    private let binding: HotkeyBinding
    private let onKeyDown: (HotkeyDownEvent) -> Void
    private let onKeyUp: (HotkeyUpEvent) -> Void
    /// Fires the FIRST time Space is pressed during a single hotkey
    /// hold. Subsequent presses within the same hold (e.g. auto-
    /// repeats, or the user releasing and re-pressing Space) do not
    /// re-fire. Used by AppState to surface visual feedback the
    /// instant Space is recognized — without this, the user gets no
    /// signal that Space landed until they release the hotkey and
    /// the picker opens, which feels unresponsive on the dominant
    /// "Space-then-immediately-release" path.
    private let onSpacePressed: (() -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Press-state tracking: CGEventTap delivers a flagsChanged event
    // every time the modifier bitmap changes, but we only want to
    // emit onKeyDown / onKeyUp on the leading and trailing edges of
    // *our* key.
    private var keyDown = false
    /// Wall-clock of the most recent key-UP. Used to detect the
    /// "double-tap-and-hold" gesture: a key-DOWN within
    /// doubleTapWindow seconds of a prior key-UP.
    private var lastKeyUpAt: TimeInterval = 0
    /// Per-hold flag set to true when Space is pressed while the
    /// dictation hotkey is held. Reset on each fresh key-DOWN.
    /// Reference Windows v2's latched-compose state machine
    /// consumes this flag at key-UP to decide whether to submit
    /// (false — release without space, the normal case) or to
    /// enter the latched state and open the picker (true).
    private var spacePressedThisHold = false
    /// Cross-cutting flag tracking a Space keyDown we consumed.
    /// Set when the keyDown is swallowed; checked when the
    /// matching keyUp arrives so we also consume it. Without this,
    /// the focused app would see a dangling Space keyUp with no
    /// matching keyDown — which can fire keyUp-only shortcuts or
    /// confuse key-state trackers in web pages and native apps.
    /// Lifetime spans whichever happens first: matching Space
    /// keyUp arrives, OR Space gets re-pressed while still
    /// expected to release (which is just a key-repeat we
    /// already-decided to swallow). Independent of the dictation
    /// hotkey's hold state — Space might be released after the
    /// dictation hotkey has already been released, and we still
    /// need to swallow that lingering keyUp.
    private var pendingSpaceKeyUpToSwallow = false

    public init(
        binding: HotkeyBinding = .defaultBinding,
        onKeyDown: @escaping (HotkeyDownEvent) -> Void,
        onKeyUp: @escaping (HotkeyUpEvent) -> Void,
        onSpacePressed: (() -> Void)? = nil
    ) {
        self.binding = binding
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onSpacePressed = onSpacePressed
    }

    public func start() throws {
        guard ensureAccessibility() else {
            throw HotkeyError.accessibilityNotGranted
        }

        // .flagsChanged for the modifier-key press/release;
        // .keyDown so we can also see plain Space presses (which
        // don't change the modifier bitmap and thus don't fire
        // flagsChanged); .keyUp so we can swallow the matching
        // Space release after we've consumed its down. Without
        // .keyUp the focused app would see a dangling keyUp.
        // The callback dispatches by event type.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // .defaultTap (not .listenOnly) so we can RETURN NIL to
        // consume a Space event when it's pressed during a hold —
        // the user is signaling Parleq via Space, not typing a
        // space character into the focused app. Flag/modifier
        // events are still passed through to other apps; only
        // Space-during-our-hold gets consumed.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: HotkeyListener.eventTapCallback,
            userInfo: userInfo
        ) else {
            throw HotkeyError.tapCreateFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw HotkeyError.runLoopSourceFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    private func handle(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == binding.keyCode else { return }
        // Read the device-dependent flag bit corresponding to this
        // physical key. The bit is set when the key is currently
        // held; clear when released. This bypasses the more general
        // .maskAlternate / .maskCommand etc bits, which conflate
        // left and right copies of the same modifier.
        let isDown = (event.flags.rawValue & binding.pressedFlagBit) != 0
        if isDown == keyDown { return }
        keyDown = isDown
        // We're already on the main run loop (the source was added to
        // CFRunLoopGetMain() in start()), so callbacks run on main —
        // no dispatch needed.
        if isDown {
            let now = Date().timeIntervalSinceReferenceDate
            let isDoubleTap = (now - lastKeyUpAt) < HotkeyListener.doubleTapWindow
            // maskShift covers both left and right Shift.
            let isShiftHeld = event.flags.contains(.maskShift)
            // Reset the per-hold space flag at every fresh down,
            // so a Space pressed during a *previous* hold doesn't
            // leak into this one.
            spacePressedThisHold = false
            onKeyDown(HotkeyDownEvent(isDoubleTapHold: isDoubleTap, isShiftHeld: isShiftHeld))
        } else {
            lastKeyUpAt = Date().timeIntervalSinceReferenceDate
            let upEvent = HotkeyUpEvent(spaceWasPressedDuringHold: spacePressedThisHold)
            // Defensive reset on emit — anything that happens after
            // this point belongs to a new hold cycle.
            spacePressedThisHold = false
            onKeyUp(upEvent)
        }
    }

    /// Returns true if the event was consumed (caller should not
    /// pass it through). Fires for:
    ///   (a) Space pressed WHILE the dictation hotkey is held —
    ///       starts the consume cycle, sets both spacePressedThisHold
    ///       and the cross-cutting pendingSpaceKeyUpToSwallow flag.
    ///   (b) Subsequent Space keyDowns (typically auto-repeat) while
    ///       pendingSpaceKeyUpToSwallow is still set. macOS
    ///       auto-repeats keyDown events when a key is held; these
    ///       belong to the same physical press we already consumed,
    ///       and would otherwise leak through if the dictation
    ///       hotkey is released before Space is.
    /// Other keyDowns pass through unchanged.
    private func handleKeyDown(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == HotkeyListener.spaceKeyCode else { return false }
        // Case (a): the dictation hotkey is held. Start consume cycle.
        if keyDown {
            // Fire onSpacePressed only on the FIRST press of this
            // hold — subsequent calls into case (a) would imply the
            // user released Space and re-pressed it (rare; we'd want
            // to surface that too if we tracked it), but in practice
            // case (b) handles auto-repeats and a re-press would
            // arrive as case (a) AFTER a Space keyUp. Guarding on
            // the prior spacePressedThisHold value keeps the
            // callback edge-triggered.
            let firstPressThisHold = !spacePressedThisHold
            spacePressedThisHold = true
            pendingSpaceKeyUpToSwallow = true
            if firstPressThisHold {
                onSpacePressed?()
            }
            return true
        }
        // Case (b): auto-repeat of an already-consumed Space press.
        // Keep the pending-keyUp flag set; consume the repeat so the
        // focused app doesn't see a partial sequence.
        if pendingSpaceKeyUpToSwallow {
            return true
        }
        return false
    }

    /// Returns true if the keyUp was consumed (caller should not
    /// pass it through). Fires only for the Space release that
    /// matches a previously-swallowed Space keyDown. All other
    /// keyUps pass through unchanged. Decoupled from `keyDown`
    /// (the dictation-hotkey hold state) because Space might be
    /// released AFTER the dictation hotkey has been released
    /// (user lets go of option-right first, then Space) — we
    /// still need to swallow the lingering keyUp.
    private func handleKeyUp(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == HotkeyListener.spaceKeyCode, pendingSpaceKeyUpToSwallow else {
            return false
        }
        pendingSpaceKeyUpToSwallow = false
        return true
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .flagsChanged:
            listener.handle(event: event)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if listener.handleKeyDown(event: event) {
                // Consume: return nil so the focused app doesn't
                // see the Space keystroke.
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if listener.handleKeyUp(event: event) {
                // Consume the matching Space keyUp so the focused
                // app doesn't see a dangling release with no
                // matching press.
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout:
            // macOS disables .defaultTap callbacks that take too
            // long. Re-enable so hotkey detection survives extreme
            // system load (unlikely to ever happen given how fast
            // this callback is, but the standard CGEventTap
            // pattern). Without this the tap stays dead and no
            // amount of hotkey pressing would register again until
            // the user restarts Parleq.
            if let tap = listener.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            // Similar to timeout — user-input disable also wants
            // an explicit re-enable. Rare in practice but covered
            // for symmetry.
            if let tap = listener.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Context for a key-up event. The press-and-hold gesture released;
/// what additional state was observed during the hold?
public struct HotkeyUpEvent {
    /// True if the Space key was pressed at any point during the
    /// hold that's now ending. Reference Windows v2's latched-
    /// compose state machine uses this to decide whether the
    /// release submits (false) or transitions into the latched
    /// state to open the picker (true).
    public let spaceWasPressedDuringHold: Bool
}

// ensureAccessibility prompts the user (with the system dialog) the
// first time it's called from an untrusted process. Subsequent calls
// short-circuit. Returns whether the process is currently trusted.
private func ensureAccessibility() -> Bool {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    let opts = [key: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}
