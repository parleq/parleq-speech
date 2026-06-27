#if Concord
import XCTest
@testable import ParleqAppCore

final class CorrectionPolicyClassifierTests: XCTestCase {
    private func e(_ t: String, _ b: DictionaryBiasing = .asrAndLLM) -> DictionaryEntry {
        DictionaryEntry(term: t, aliases: [], biasing: b)
    }

    func testClassification() {
        let dict = [e("Keavi"), e("RoboRev"), e("Claude"), e("Go", .asrAndLLM), e("worktree", .llmOnly)]
        let p = CorrectionPolicyClassifier.classify(dict, enrolled: ["keavi"])
        XCTAssertEqual(p["Keavi"], .acousticGated)        // enrolled
        XCTAssertEqual(p["RoboRev"], .phoneticEligible)   // distinctive non-word per LearnedTermQualityBar
        XCTAssertEqual(p["Claude"], .contextOnly)         // real word / common
        XCTAssertEqual(p["Go"], .contextOnly)             // real word ("go" is in commonWords)
        XCTAssertEqual(p["worktree"], .contextOnly)       // .llmOnly forces contextOnly
    }
}
#endif
