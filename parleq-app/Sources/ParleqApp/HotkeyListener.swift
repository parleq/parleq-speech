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

enum HotkeyError: Error, CustomStringConvertible {
    case accessibilityNotGranted
    case tapCreateFailed
    case runLoopSourceFailed
    case unknownBinding(String)

    var description: String {
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
struct HotkeyBinding {
    /// The physical key's keyCode (CGKeyCode). The same key on left
    /// vs right (e.g. left-Option=58, right-Option=61) gets a
    /// different keyCode.
    let keyCode: Int64
    /// Bit in CGEventFlags that's set when this key is held. Used
    /// to read the press state independently of other modifiers
    /// being held simultaneously. The values come from the
    /// device-dependent flag bits documented in IOKit/hidsystem.
    let pressedFlagBit: UInt64
    /// Human-readable label for logs.
    let displayName: String

    /// Parse a config-string binding like "option-right". Returns
    /// nil for unrecognized values; HotkeyListener.start surfaces
    /// the error.
    static func parse(_ binding: String) -> HotkeyBinding? {
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

    static let defaultBinding = HotkeyBinding.parse("option-right")!
}

/// Context for a key-down event: which gesture variants apply.
struct HotkeyDownEvent {
    /// True if this key-down landed within the double-tap window
    /// of the most recent key-up — i.e., the user is doing a
    /// double-tap-and-hold (quick-mode gesture).
    let isDoubleTapHold: Bool
    /// True if either Shift key was held at the moment the hotkey
    /// went down. Used to open the staging mode (curate references
    /// before dictating).
    let isShiftHeld: Bool
}

final class HotkeyListener {
    /// Time window for treating "down → up → down (and hold)" as a
    /// double-tap-and-hold gesture. Empirically: 300 ms is faster
    /// than a deliberate hold-then-hold-again sequence and slow
    /// enough to forgive a fumbled tap.
    private static let doubleTapWindow: TimeInterval = 0.3

    private let binding: HotkeyBinding
    private let onKeyDown: (HotkeyDownEvent) -> Void
    private let onKeyUp: () -> Void
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

    init(
        binding: HotkeyBinding = .defaultBinding,
        onKeyDown: @escaping (HotkeyDownEvent) -> Void,
        onKeyUp: @escaping () -> Void
    ) {
        self.binding = binding
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    func start() throws {
        guard ensureAccessibility() else {
            throw HotkeyError.accessibilityNotGranted
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
            onKeyDown(HotkeyDownEvent(isDoubleTapHold: isDoubleTap, isShiftHeld: isShiftHeld))
        } else {
            lastKeyUpAt = Date().timeIntervalSinceReferenceDate
            onKeyUp()
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .flagsChanged {
            listener.handle(event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}

// ensureAccessibility prompts the user (with the system dialog) the
// first time it's called from an untrusted process. Subsequent calls
// short-circuit. Returns whether the process is currently trusted.
private func ensureAccessibility() -> Bool {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    let opts = [key: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}
