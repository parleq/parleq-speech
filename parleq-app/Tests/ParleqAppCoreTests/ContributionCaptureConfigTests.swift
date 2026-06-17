import XCTest
@testable import ParleqAppCore

/// Tests for the hidden, acknowledgment-gated contribution-capture
/// arming flag and its `mergeForSave` preservation. Guards two
/// invariants: (1) arming requires the EXACT acknowledgment phrase — a
/// bare `true`, a wrong string, or an absent block never arm it; and
/// (2) `mergeForSave` preserves the `contribution` block verbatim across
/// Settings saves (it is intentionally not modeled / re-serialized, so
/// without explicit copy-through a save would silently drop a
/// contributor's armed flag — the original High finding).
final class ContributionCaptureConfigTests: XCTestCase {

    // MARK: - Arming gate

    func test_default_is_disarmed() {
        XCTAssertFalse(Config.default.contributionCaptureArmed)
    }

    func test_exact_acknowledgment_phrase_arms() {
        let c = Config.parse(fromDictionary: [
            "contribution": ["capture": Config.contributionCaptureAck]
        ])
        XCTAssertTrue(c.contributionCaptureArmed,
                      "the exact acknowledgment phrase must arm capture")
    }

    func test_bare_true_does_not_arm() {
        // A JSON `true` is a Bool, not the acknowledgment String — the
        // `as? String` parse fails and the flag stays false.
        let c = Config.parse(fromDictionary: [
            "contribution": ["capture": true]
        ])
        XCTAssertFalse(c.contributionCaptureArmed,
                       "a bare boolean true must NOT arm capture")
    }

    func test_wrong_string_does_not_arm() {
        let c = Config.parse(fromDictionary: [
            "contribution": ["capture": "yes"]
        ])
        XCTAssertFalse(c.contributionCaptureArmed,
                       "any string other than the exact phrase must NOT arm capture")
    }

    func test_absent_block_does_not_arm() {
        let c = Config.parse(fromDictionary: [:])
        XCTAssertFalse(c.contributionCaptureArmed)
    }

    // MARK: - mergeForSave preservation

    func test_mergeForSave_preserves_contribution_block_verbatim() {
        let existing: [String: Any] = [
            "contribution": ["capture": Config.contributionCaptureAck]
        ]
        let merged = Config.mergeForSave(Config.defaults, existing: existing)
        let block = merged["contribution"] as? [String: Any]
        XCTAssertEqual(block?["capture"] as? String, Config.contributionCaptureAck,
                       "a Settings save must preserve the armed contribution block")
    }

    func test_mergeForSave_does_not_synthesize_block_when_absent() {
        let merged = Config.mergeForSave(Config.defaults, existing: [:])
        XCTAssertNil(merged["contribution"],
                     "mergeForSave must not invent a contribution block")
    }

    func test_mergeForSave_preserves_block_alongside_populated_config() {
        var c = Config.defaults
        c.llmProvider = "bedrock"
        c.awsRegion = "us-east-1"
        c.customDictionary = [
            DictionaryEntry(term: "Snyk", context: "security tool",
                            aliases: ["sneak"], biasing: .asrAndLLM, source: .user)
        ]
        let existing: [String: Any] = [
            "llm": ["provider": "gemini"],
            "contribution": ["capture": Config.contributionCaptureAck],
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let block = merged["contribution"] as? [String: Any]
        XCTAssertEqual(block?["capture"] as? String, Config.contributionCaptureAck,
                       "the contribution block must survive a save of a fully-populated config")
        // Sanity: the rest of the config still serialized.
        XCTAssertEqual((merged["llm"] as? [String: Any])?["provider"] as? String, "bedrock")
    }
}
