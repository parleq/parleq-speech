import XCTest
import CryptoKit
@testable import ParleqAppCore

#if Concord
final class VoiceprintCryptoKeyTests: XCTestCase {
    func testOverrideBypassesKeychain() throws {
        let k = SymmetricKey(size: .bits256)
        XCTAssertEqual(try VoiceprintCryptoKey.key(override: k).withUnsafeBytes { Data($0) },
                       k.withUnsafeBytes { Data($0) })
    }
    func testFrozenConstants() {
        XCTAssertEqual(VoiceprintCryptoKey.keyService, "com.parleq.app")
        XCTAssertEqual(VoiceprintCryptoKey.keyAccount, "com.parleq.voiceprint.key")
    }
}
#endif
