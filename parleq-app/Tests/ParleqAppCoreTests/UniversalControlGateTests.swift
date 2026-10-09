import XCTest
@testable import ParleqAppCore

/// Universal Control: while this Mac's keyboard drives another Mac, modifier
/// flagsChanged events still arrive locally, so the hotkey started a capture on
/// BOTH machines. The gate keys off the UniversalControl agent being frontmost.
final class UniversalControlGateTests: XCTestCase {

    func testUniversalControlFrontmostIsRemote() {
        XCTAssertTrue(HotkeyListener.isRemoteControlFrontmost(bundleID: "com.apple.universalcontrol"))
        XCTAssertTrue(HotkeyListener.isRemoteControlFrontmost(bundleID: "com.apple.UniversalControl"))
    }

    func testOrdinaryAppsAreLocal() {
        for id in ["com.googlecode.iterm2", "com.apple.mail", "com.apple.universalaccess"] {
            XCTAssertFalse(HotkeyListener.isRemoteControlFrontmost(bundleID: id), id)
        }
        XCTAssertFalse(HotkeyListener.isRemoteControlFrontmost(bundleID: nil))
    }
}
