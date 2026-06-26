import XCTest
@testable import ParleqAppCore

@MainActor
final class ConfusableDetectorTests: XCTestCase {

    func test_isRealWord_accepts_real_rejects_nonword_and_fragment() {
        XCTAssertTrue(ConfusableDetector.isRealWord("kiwi"))
        XCTAssertTrue(ConfusableDetector.isRealWord("cloud"))
        XCTAssertFalse(ConfusableDetector.isRealWord("kaevy"), "not an English word")
        XCTAssertFalse(ConfusableDetector.isRealWord("a"), "too short")
        XCTAssertFalse(ConfusableDetector.isRealWord("k1wi"), "non-letters rejected")
    }

    func test_confusables_keeps_realword_drops_nonword_and_term() {
        let out = ConfusableDetector.confusables(
            mishears: ["kiwi", "Kiwi", "kaevy", "keavi"], term: "Keavi")
        XCTAssertEqual(out, ["kiwi"],
                       "dedup case-insensitively, drop the non-word 'kaevy' and the term 'keavi'")
    }

    func test_confusables_empty_when_no_realword_mishears() {
        let out = ConfusableDetector.confusables(mishears: ["kaevy", "qux", ""], term: "Keavi")
        XCTAssertEqual(out, [])
    }
}
