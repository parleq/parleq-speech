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
        XCTAssertEqual(p["Claude"], .phoneticEligible)    // Claude is a distinctive proper noun (not common, no phonetic collision per LearnedTermQualityBar) → eligible for the multi-token merge path. The policy gates ONLY the merge path, not single-word matching, so this does not increase single-word over-fire risk; the merge veto + over-fire baseline guard it.
        XCTAssertEqual(p["Go"], .contextOnly)             // real word ("go" is in commonWords)
        XCTAssertEqual(p["worktree"], .contextOnly)       // .llmOnly forces contextOnly
    }
}
#endif
