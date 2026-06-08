import XCTest
@testable import ParleqAppCore

/// Bridge 1 — suggest-to-create transform presets from recurring refine
/// patterns. Covers analyzer JSON parse of the new "preset" kind, the
/// always-suggest routing (never auto-applied), the pure config-write on
/// accept, the eligibility gate (feature gating, cap, dismissed/duplicate
/// suppression), and the content hash.
final class PresetSuggestionBridgeTests: XCTestCase {

    private func presetProposal(name: String, prompt: String, confidence: Double = 0.9) -> LearningProposal {
        LearningProposal(kind: .preset, op: .add, confidence: confidence, rationale: "r",
                         presetName: name, presetPrompt: prompt)
    }

    // MARK: - Analyzer JSON parse

    func test_parses_preset_proposal_kind() {
        let text = """
        ```json
        {"proposals":[
          {"kind":"preset","op":"add","confidence":0.85,"rationale":"User keeps asking to shorten","name":"Concise","prompt":"Rewrite the text to be as concise as possible while preserving all key information."}
        ]}
        ```
        """
        let proposals = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].kind, .preset)
        XCTAssertEqual(proposals[0].presetName, "Concise")
        XCTAssertEqual(proposals[0].presetPrompt,
                       "Rewrite the text to be as concise as possible while preserving all key information.")
    }

    func test_drops_preset_proposal_with_empty_name_or_prompt() {
        let noName = #"{"proposals":[{"kind":"preset","op":"add","confidence":0.9,"rationale":"r","name":"  ","prompt":"Make it concise."}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: noName).isEmpty,
                      "A preset proposal needs a non-empty name")
        let noPrompt = #"{"proposals":[{"kind":"preset","op":"add","confidence":0.9,"rationale":"r","name":"Concise","prompt":""}]}"#
        XCTAssertTrue(LearningAnalyzer.parseProposals(from: noPrompt).isEmpty,
                      "A preset proposal needs a non-empty prompt")
    }

    func test_preset_name_and_prompt_are_length_bounded() {
        let longName = String(repeating: "x", count: 200)
        let longPrompt = String(repeating: "y", count: 2000)
        let text = "{\"proposals\":[{\"kind\":\"preset\",\"op\":\"add\",\"confidence\":0.9,\"rationale\":\"r\",\"name\":\"\(longName)\",\"prompt\":\"\(longPrompt)\"}]}"
        let proposals = LearningAnalyzer.parseProposals(from: text)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertLessThanOrEqual(proposals[0].presetName?.count ?? 0, LearningAnalyzer.maxPresetNameChars)
        XCTAssertLessThanOrEqual(proposals[0].presetPrompt?.count ?? 0, LearningAnalyzer.maxPresetPromptChars)
    }

    // MARK: - Routing

    func test_preset_proposal_routes_to_suggest_never_auto_applies() {
        let decision = LearnedStore.route(
            presetProposal(name: "Concise", prompt: "Rewrite concisely.", confidence: 0.99),
            against: [])
        XCTAssertEqual(decision, .suggest,
                       "A preset proposal must NEVER auto-apply, regardless of confidence")
    }

    // MARK: - Prompt gating (terms pipeline unaffected)

    func test_analysis_prompt_invites_presets_only_when_enabled() {
        let withPresets = SystemPrompts.learningAnalysis(currentDictionary: [], proposePresets: true)
        XCTAssertTrue(withPresets.contains("\"preset\""),
                      "Presets-on prompt must invite the preset kind")
        let withoutPresets = SystemPrompts.learningAnalysis(currentDictionary: [], proposePresets: false)
        XCTAssertFalse(withoutPresets.contains("\"kind\":\"preset\""),
                       "Presets-off prompt must not advertise the preset shape")
        // Terms pipeline is present in both.
        XCTAssertTrue(withPresets.contains("\"kind\":\"term\""))
        XCTAssertTrue(withoutPresets.contains("\"kind\":\"term\""))
    }

    func test_analysis_prompt_default_is_terms_only() {
        // No-arg-presets default matches the explicit false form.
        XCTAssertEqual(SystemPrompts.learningAnalysis(currentDictionary: []),
                       SystemPrompts.learningAnalysis(currentDictionary: [], proposePresets: false))
    }

    // MARK: - Accept writes a config preset (pure)

    func test_accept_appends_preset_to_config() {
        var c = Config.default
        c.transformPresets = []
        let result = LearnedStore.configByAddingPreset(to: c, name: "Concise", prompt: "Rewrite concisely.")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.config.transformPresets.count, 1)
        XCTAssertEqual(result?.config.transformPresets.first?.name, "Concise")
        XCTAssertEqual(result?.config.transformPresets.first?.prompt, "Rewrite concisely.")
    }

    func test_accept_trims_and_rejects_blank() {
        var c = Config.default
        let trimmed = LearnedStore.configByAddingPreset(to: c, name: "  Tidy  ", prompt: "  Tidy it up.  ")
        XCTAssertEqual(trimmed?.preset.name, "Tidy")
        XCTAssertEqual(trimmed?.preset.prompt, "Tidy it up.")
        XCTAssertNil(LearnedStore.configByAddingPreset(to: c, name: "   ", prompt: "x"),
                     "Blank name → no preset created")
        XCTAssertNil(LearnedStore.configByAddingPreset(to: c, name: "x", prompt: "   "),
                     "Blank prompt → no preset created")
        c.transformPresetsEnabled = false
        XCTAssertNil(LearnedStore.configByAddingPreset(to: c, name: "X", prompt: "Y"),
                     "Feature off (MDM) → no preset created even on accept")
    }

    // MARK: - Eligibility gate (gating, cap, dedupe, dismissed)

    func test_eligibility_requires_both_features() {
        let p = presetProposal(name: "Concise", prompt: "Rewrite concisely.")
        XCTAssertFalse(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: false, presetsEnabled: true,
            dismissedHashes: [], pendingPresetHashes: [], pendingPresetCount: 0),
            "learn-from-corrections off → not eligible")
        XCTAssertFalse(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: true, presetsEnabled: false,
            dismissedHashes: [], pendingPresetHashes: [], pendingPresetCount: 0),
            "presets off → not eligible")
        XCTAssertTrue(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: true, presetsEnabled: true,
            dismissedHashes: [], pendingPresetHashes: [], pendingPresetCount: 0),
            "both on, fresh → eligible")
    }

    func test_eligibility_respects_cap() {
        let p = presetProposal(name: "Concise", prompt: "Rewrite concisely.")
        XCTAssertFalse(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: true, presetsEnabled: true,
            dismissedHashes: [], pendingPresetHashes: [],
            pendingPresetCount: LearnedStore.maxPendingPresetSuggestions),
            "At the cap → not eligible")
    }

    func test_eligibility_suppresses_dismissed_and_duplicate() {
        let p = presetProposal(name: "Concise", prompt: "Rewrite concisely.")
        let hash = LearnedStore.presetContentHash(p)
        XCTAssertFalse(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: true, presetsEnabled: true,
            dismissedHashes: [hash], pendingPresetHashes: [], pendingPresetCount: 0),
            "Previously dismissed content → not eligible")
        XCTAssertFalse(LearnedStore.presetSuggestionEligible(
            p, learnEnabled: true, presetsEnabled: true,
            dismissedHashes: [], pendingPresetHashes: [hash], pendingPresetCount: 1),
            "An equivalent suggestion already pending → not eligible")
    }

    func test_content_hash_folds_case_and_whitespace() {
        let a = presetProposal(name: "A", prompt: "Rewrite   the Text CONCISELY.")
        let b = presetProposal(name: "B", prompt: "rewrite the text concisely.")
        XCTAssertEqual(LearnedStore.presetContentHash(a), LearnedStore.presetContentHash(b),
                       "Hash ignores name, case, and whitespace runs")
    }
}
