import XCTest
@testable import ParleqAppCore

/// Pure model for #84 — a minimal config-driven map from the double-tap entry
/// gestures to a fixed set of actions (the foundation #83's continuous-recording
/// gesture binds into). The CGEventTap detection and AppState behavior are wired
/// elsewhere; the parse/default/resolve logic is pure and tested here.
final class GestureMapTests: XCTestCase {

    // MARK: action enum

    func testGestureActionRawValuesAreStable() {
        // Raw values are the on-disk config tokens — keep them stable.
        XCTAssertEqual(GestureAction.dictate.rawValue, "dictate")
        XCTAssertEqual(GestureAction.quickMode.rawValue, "quick")
        XCTAssertEqual(GestureAction.continuousRecording.rawValue, "continuous")
        XCTAssertEqual(GestureAction.disabled.rawValue, "disabled")
    }

    // MARK: defaults

    func testDefaultsPreserveTodaysBehaviorPlusContinuous() {
        // Double-tap-and-hold has always been quick mode; double-tap-and-release
        // is the new continuous-recording gesture (#83).
        XCTAssertEqual(GestureMap.defaults.action(for: .doubleTapHold), .quickMode)
        XCTAssertEqual(GestureMap.defaults.action(for: .doubleTapRelease), .continuousRecording)
    }

    // MARK: parse

    func testParseOverridesAGesture() {
        let map = GestureMap.parse(["double-tap-release": "quick"])
        XCTAssertEqual(map.action(for: .doubleTapRelease), .quickMode)
        // Unspecified gesture keeps its default.
        XCTAssertEqual(map.action(for: .doubleTapHold), .quickMode)
    }

    func testParseEmptyYieldsDefaults() {
        XCTAssertEqual(GestureMap.parse([:]), GestureMap.defaults)
    }

    func testParseUnknownActionFallsBackToDefault() {
        // A typo / unknown action token must not silently disable the gesture —
        // fall back to that gesture's default.
        let map = GestureMap.parse(["double-tap-release": "bogus"])
        XCTAssertEqual(map.action(for: .doubleTapRelease), .continuousRecording)
    }

    func testParseIgnoresUnknownGestureKeys() {
        let map = GestureMap.parse(["triple-tap": "dictate"])
        XCTAssertEqual(map, GestureMap.defaults)
    }

    func testParseCanDisableAGesture() {
        let map = GestureMap.parse(["double-tap-hold": "disabled"])
        XCTAssertEqual(map.action(for: .doubleTapHold), .disabled)
    }

    // MARK: round-trip

    func testSerializeRoundTrips() {
        let map = GestureMap.parse(["double-tap-hold": "continuous", "double-tap-release": "disabled"])
        XCTAssertEqual(GestureMap.parse(map.serialized()), map)
    }

    // MARK: Config integration

    func testConfigParsesHotkeyGestures() {
        let c = Config.parse(fromDictionary: [
            "hotkey": ["binding": "option-left",
                       "gestures": ["double-tap-release": "quick"]]
        ])
        XCTAssertEqual(c.hotkeyBinding, "option-left")
        XCTAssertEqual(c.hotkeyGestureMap.action(for: .doubleTapRelease), .quickMode)
        XCTAssertEqual(c.hotkeyGestureMap.action(for: .doubleTapHold), .quickMode) // default
    }

    func testConfigDefaultsWhenNoGestures() {
        let c = Config.parse(fromDictionary: [:])
        XCTAssertEqual(c.hotkeyGestureMap.action(for: .doubleTapRelease), .continuousRecording)
    }
}
