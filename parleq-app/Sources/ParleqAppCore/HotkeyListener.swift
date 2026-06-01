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

    /// Virtual keycode for P. Used by the "hold the dictation
    /// hotkey + tap P" gesture (0.14.0) — fires the
    /// "Show Parleq app window" intent without colliding with the
    /// system's Option-P = π typing, because the hotkey itself
    /// has to be held for the consumption to kick in. Brief
    /// Option-P taps that don't engage the dictation hold path
    /// fall through unchanged and still produce π.
    private static let pKeyCode: Int64 = 0x23
    /// C key (US layout). "hold-hotkey + C" attaches the CURRENT
    /// front window as a reference. Same hold-threshold treatment as
    /// P so a brief Option-C still types ç.
    private static let cKeyCode: Int64 = 0x08

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
    /// Fires the FIRST time P is pressed during a single hotkey
    /// hold. 0.14.0 "hold-hotkey + P" gesture for summoning the
    /// Parleq app window from anywhere. AppState's handler
    /// cancels the in-flight dictation and opens the app — the
    /// gesture is "instead of dictating, show me the app", not
    /// "after dictating".
    private let onPPressed: (() -> Void)?
    /// Fires the FIRST time C is pressed during a single hotkey hold.
    /// "hold-hotkey + C" attaches the current front window as a
    /// reference without opening the picker — the shortcut for "use
    /// what I'm looking at as context."
    private let onCPressed: (() -> Void)?
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
    /// Wall-clock of the most recent key-DOWN. Used by the P-key
    /// gesture's hold-threshold gate so brief hotkey taps don't
    /// hijack the standard Option-P (π) typing path. See
    /// `pHoldThreshold` for the value + rationale.
    private var keyDownAt: TimeInterval = 0
    /// Minimum hotkey-hold duration before the P-during-hold
    /// gesture engages. Kept in lockstep with the overlay-show
    /// delay (Config.overlayShowDelayMs, #56) so the "hold until
    /// the overlay appears, then tap P" mental model is honest —
    /// both UX cues fire at the same moment. A brief tap of
    /// Option-P (under this threshold) falls through to the system
    /// and types π exactly as the user expects. Mutable (not a
    /// static let) so `setPHoldThreshold(_:)` can sync it live when
    /// the user changes the overlay delay in Settings, without an
    /// app restart. Default 200ms matches Config's default.
    private var pHoldThreshold: TimeInterval = 0.200

    /// Update the P-gesture hold threshold to match the current
    /// overlay-show delay. Wired from main.swift at launch and from
    /// the Settings-save path so the gesture stays in sync with the
    /// configurable overlay delay (#56). Thread note: the event-tap
    /// callback reads `pHoldThreshold` on the main run loop (the tap
    /// source is added to CFRunLoopGetMain), and Settings save also
    /// runs on the main actor, so this plain assignment is
    /// race-free without locking.
    public func setPHoldThreshold(_ seconds: TimeInterval) {
        pHoldThreshold = max(0, seconds)
    }
    /// Per-hold flag set to true when Space is pressed while the
    /// dictation hotkey is held. Reset on each fresh key-DOWN.
    /// Reference Windows v2's latched-compose state machine
    /// consumes this flag at key-UP to decide whether to submit
    /// (false — release without space, the normal case) or to
    /// enter the latched state and open the picker (true).
    private var spacePressedThisHold = false
    /// Mirror of spacePressedThisHold for the 0.14.0 P-gesture.
    /// Reset on each fresh key-DOWN. Not strictly needed by
    /// HotkeyUpEvent (the P gesture fires synchronously via the
    /// onPPressed callback and aborts the capture before the
    /// hotkey is released), but tracked anyway for symmetry +
    /// to make the edge-trigger guard in handleKeyDown simple.
    private var pPressedThisHold = false
    /// Mirror of pPressedThisHold for the "hold-hotkey + C" gesture.
    private var cPressedThisHold = false
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
    /// P-key counterpart of pendingSpaceKeyUpToSwallow. Same
    /// rationale: if we consumed the P keyDown, we must also
    /// consume the matching keyUp so the focused app doesn't see
    /// a dangling release.
    private var pendingPKeyUpToSwallow = false
    /// C-key counterpart of pendingPKeyUpToSwallow.
    private var pendingCKeyUpToSwallow = false

    public init(
        binding: HotkeyBinding = .defaultBinding,
        onKeyDown: @escaping (HotkeyDownEvent) -> Void,
        onKeyUp: @escaping (HotkeyUpEvent) -> Void,
        onSpacePressed: (() -> Void)? = nil,
        onPPressed: (() -> Void)? = nil,
        onCPressed: (() -> Void)? = nil
    ) {
        self.binding = binding
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onSpacePressed = onSpacePressed
        self.onPPressed = onPPressed
        self.onCPressed = onCPressed
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
            // Reset the per-hold space + P flags at every fresh
            // down, so a key pressed during a *previous* hold
            // doesn't leak into this one.
            spacePressedThisHold = false
            pPressedThisHold = false
            cPressedThisHold = false
            // Record the hold-start time for the P-gesture's
            // hold-threshold gate (see pHoldThreshold).
            keyDownAt = now
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
        // macOS sets this on auto-repeat keyDowns of a held key. The
        // pending-swallow branches below are ONLY meant to swallow such
        // repeats of a key we already consumed; a fresh (non-repeat)
        // press while a pending flag is still set means the matching
        // keyUp was never seen (a window activation during a during-hold
        // attach — the picker for Space, ScreenCaptureKit for C — can
        // briefly disable the tap and drop that keyUp), leaving the flag
        // stale. See each branch.
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Space-during-hold path (Reference Windows v2 picker gesture).
        if keyCode == HotkeyListener.spaceKeyCode {
            if keyDown {
                let firstPressThisHold = !spacePressedThisHold
                spacePressedThisHold = true
                pendingSpaceKeyUpToSwallow = true
                if firstPressThisHold {
                    onSpacePressed?()
                }
                return true
            }
            if pendingSpaceKeyUpToSwallow {
                // Swallow only the auto-repeat of a still-held Space we
                // already consumed. A fresh press means the matching
                // keyUp was missed and the flag is stale — clear it and
                // let the press through, so a Space used in the review
                // overlay right after a during-hold attach reaches the
                // overlay instead of being silently eaten here.
                if isAutorepeat { return true }
                pendingSpaceKeyUpToSwallow = false
                return false
            }
            return false
        }
        // P-during-hold path (0.14.0 Show Parleq gesture). Same
        // shape as the Space path, with one critical difference:
        // a hold-duration threshold. The threshold preserves
        // standard Option-P = π typing for users whose dictation
        // hotkey IS Option (the common case). When the user
        // briefly taps Option-P to type π, the hotkey hold is
        // under the threshold so P passes through to the system.
        // When the user deliberately holds the hotkey long enough
        // for the dictation overlay to appear, they're in
        // "Parleq mode" and a subsequent P opens the app.
        // Matches the user's mental model: "hold until the
        // overlay shows, then press P."
        if keyCode == HotkeyListener.pKeyCode {
            if keyDown {
                let elapsed = Date().timeIntervalSinceReferenceDate - keyDownAt
                if elapsed < pHoldThreshold {
                    // Brief tap — pass P through so Option-P = π
                    // (and any other modifier-P shortcut) keeps
                    // working as the user expects.
                    return false
                }
                let firstPressThisHold = !pPressedThisHold
                pPressedThisHold = true
                pendingPKeyUpToSwallow = true
                if firstPressThisHold {
                    onPPressed?()
                }
                return true
            }
            if pendingPKeyUpToSwallow {
                // See the Space branch: only swallow auto-repeat; a
                // fresh press means the keyUp was missed, so clear the
                // stale flag and pass through.
                if isAutorepeat { return true }
                pendingPKeyUpToSwallow = false
                return false
            }
            return false
        }
        // C-during-hold path (attach current window as a reference).
        // Same shape and hold-threshold as the P path, so a brief
        // Option-C still types ç; only a deliberate hold engages it.
        if keyCode == HotkeyListener.cKeyCode {
            if keyDown {
                let elapsed = Date().timeIntervalSinceReferenceDate - keyDownAt
                if elapsed < pHoldThreshold {
                    return false
                }
                let firstPressThisHold = !cPressedThisHold
                cPressedThisHold = true
                pendingCKeyUpToSwallow = true
                if firstPressThisHold {
                    onCPressed?()
                }
                return true
            }
            if pendingCKeyUpToSwallow {
                // See the Space branch: only swallow auto-repeat; a
                // fresh press means the keyUp was missed (e.g. a window
                // activation briefly disabled the tap), so clear the
                // stale flag and pass through rather than eating it.
                if isAutorepeat { return true }
                pendingCKeyUpToSwallow = false
                return false
            }
            return false
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
        if keyCode == HotkeyListener.spaceKeyCode, pendingSpaceKeyUpToSwallow {
            pendingSpaceKeyUpToSwallow = false
            return true
        }
        if keyCode == HotkeyListener.pKeyCode, pendingPKeyUpToSwallow {
            pendingPKeyUpToSwallow = false
            return true
        }
        if keyCode == HotkeyListener.cKeyCode, pendingCKeyUpToSwallow {
            pendingCKeyUpToSwallow = false
            return true
        }
        return false
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
