import XCTest
@testable import ParleqAppCore

/// Tests for the `llm.tuning` config section (#55): parse round-trip,
/// clamping, defaults-when-absent, omit-when-default serialization, and
/// the geminiGenerationConfig override/nil-default wiring.
final class LLMTuningConfigTests: XCTestCase {

    // Save/restore the process-global so a test that sets it can't leak
    // into another (the global is launch-set in production; here we drive
    // it directly).
    private var savedTuning = LLMTuning()
    override func setUp() { super.setUp(); savedTuning = LLMTuning.current }
    override func tearDown() { LLMTuning.current = savedTuning; super.tearDown() }

    // MARK: - Defaults

    func test_defaults() {
        let t = LLMTuning()
        XCTAssertNil(t.thinkingBudget, "nil = built-in 0/128 split")
        XCTAssertEqual(t.maxOutputTokens, 2048, "raised from the historical 1024")
        XCTAssertEqual(t.temperature, 0)
        XCTAssertEqual(t.ttftDeadlineSeconds, [5.5, 8.0])
        XCTAssertEqual(t.ttftDeadlineThinkingSeconds, [25.0])
        XCTAssertEqual(t.requestTimeoutSeconds, 60)
        XCTAssertTrue(t.isDefault)
        XCTAssertEqual(t.overriddenKeys, [])
    }

    func test_config_default_carries_default_tuning() {
        XCTAssertTrue(Config.default.llmTuning.isDefault)
    }

    func test_absent_tuning_section_yields_default() {
        // An llm section with no "tuning" key leaves the default.
        let dict: [String: Any] = ["llm": ["provider": "gemini", "model": "gemini-2.5-flash"]]
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertTrue(parsed.llmTuning.isDefault)
    }

    // MARK: - Parse round-trip (all keys)

    func test_all_keys_round_trip() {
        var c = Config.defaults
        c.llmTuning = LLMTuning(
            thinkingBudget: 256,
            maxOutputTokens: 4096,
            temperature: 0.7,
            ttftDeadlineSeconds: [3.0, 6.0, 10.0],
            ttftDeadlineThinkingSeconds: [30.0, 45.0],
            requestTimeoutSeconds: 90
        )
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.llmTuning.thinkingBudget, 256)
        XCTAssertEqual(parsed.llmTuning.maxOutputTokens, 4096)
        XCTAssertEqual(parsed.llmTuning.temperature, 0.7, accuracy: 1e-9)
        XCTAssertEqual(parsed.llmTuning.ttftDeadlineSeconds, [3.0, 6.0, 10.0])
        XCTAssertEqual(parsed.llmTuning.ttftDeadlineThinkingSeconds, [30.0, 45.0])
        XCTAssertEqual(parsed.llmTuning.requestTimeoutSeconds, 90)
    }

    func test_thinking_budget_zero_round_trips_distinct_from_nil() {
        // 0 is a meaningful override (Flash disable) distinct from nil
        // (built-in split). It must survive serialize → parse as 0.
        var c = Config.defaults
        c.llmTuning.thinkingBudget = 0
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.llmTuning.thinkingBudget, 0)
    }

    // MARK: - Clamping / dropping

    func test_scalar_clamping() {
        let obj: [String: Any] = [
            "thinking_budget": 999999,       // > 32768 → clamp
            "max_output_tokens": 10,         // < 64 → clamp
            "temperature": 5.0,              // > 2 → clamp
            "request_timeout_seconds": 1.0,  // < 5 → clamp
        ]
        let t = Config.parseLLMTuning(obj)
        XCTAssertEqual(t.thinkingBudget, 32768)
        XCTAssertEqual(t.maxOutputTokens, 64)
        XCTAssertEqual(t.temperature, 2.0)
        XCTAssertEqual(t.requestTimeoutSeconds, 5.0)
    }

    func test_scalar_clamping_lower_and_upper_extremes() {
        let low = Config.parseLLMTuning([
            "thinking_budget": -50,
            "max_output_tokens": 0,
            "temperature": -1.0,
            "request_timeout_seconds": 99999.0,
        ])
        XCTAssertEqual(low.thinkingBudget, 0)
        XCTAssertEqual(low.maxOutputTokens, 64)
        XCTAssertEqual(low.temperature, 0.0)
        XCTAssertEqual(low.requestTimeoutSeconds, 300.0)
    }

    func test_ttft_list_clamps_entries() {
        // Below 1 and above 120 clamp (not drop); only non-numbers drop.
        let t = Config.parseLLMTuning([
            "ttft_deadline_seconds": [0.1, 500.0, 7.0],
        ])
        XCTAssertEqual(t.ttftDeadlineSeconds, [1.0, 120.0, 7.0])
    }

    func test_ttft_list_drops_non_numeric_and_caps_at_four() {
        let t = Config.parseLLMTuning([
            "ttft_deadline_seconds": [2.0, "nope", 3.0, 4.0, 5.0, 6.0],
        ])
        // "nope" dropped; remaining 5 capped to first 4.
        XCTAssertEqual(t.ttftDeadlineSeconds, [2.0, 3.0, 4.0, 5.0])
    }

    func test_ttft_all_invalid_falls_back_to_default() {
        let t = Config.parseLLMTuning([
            "ttft_deadline_seconds": ["a", "b"],
            "ttft_deadline_thinking_seconds": [],
        ])
        XCTAssertEqual(t.ttftDeadlineSeconds, [5.5, 8.0], "all-invalid → default")
        XCTAssertEqual(t.ttftDeadlineThinkingSeconds, [25.0], "empty → default")
    }

    // MARK: - Omit-when-default serialization

    func test_defaults_omit_tuning_key() {
        let dict = Config.serializeToDictionary(Config.defaults)
        let llm = dict["llm"] as? [String: Any]
        XCTAssertNotNil(llm)
        XCTAssertNil(llm?["tuning"], "an all-default tuning emits no tuning key")
    }

    func test_partial_override_emits_only_changed_keys() {
        var c = Config.defaults
        c.llmTuning.requestTimeoutSeconds = 120
        let dict = Config.serializeToDictionary(c)
        let tuning = (dict["llm"] as? [String: Any])?["tuning"] as? [String: Any]
        XCTAssertNotNil(tuning)
        XCTAssertEqual(tuning?["request_timeout_seconds"] as? Double, 120)
        // Unchanged fields are omitted.
        XCTAssertNil(tuning?["max_output_tokens"])
        XCTAssertNil(tuning?["temperature"])
        XCTAssertNil(tuning?["thinking_budget"])
        XCTAssertNil(tuning?["ttft_deadline_seconds"])
    }

    func test_overridden_keys_lists_changed_fields() {
        var t = LLMTuning()
        t.maxOutputTokens = 1024
        t.temperature = 1.0
        XCTAssertEqual(Set(t.overriddenKeys), ["max_output_tokens", "temperature"])
    }

    // MARK: - mergeForSave round-trips tuning (no MDM key for it)

    func test_mergeForSave_carries_tuning() {
        var c = Config.defaults
        c.llmTuning.maxOutputTokens = 8192
        let dict = Config.mergeForSave(c, existing: [:])
        let tuning = (dict["llm"] as? [String: Any])?["tuning"] as? [String: Any]
        XCTAssertEqual(tuning?["max_output_tokens"] as? Int, 8192)
    }

    // MARK: - geminiGenerationConfig wiring

    func test_geminiGenerationConfig_uses_builtin_split_when_nil() {
        LLMTuning.current = LLMTuning()  // default: thinkingBudget nil
        let flash = LLMClient(model: "gemini-2.5-flash")
        let flashCfg = flash.geminiGenerationConfig()
        XCTAssertEqual((flashCfg["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0,
                       "Flash defaults to 0")
        XCTAssertEqual(flashCfg["maxOutputTokens"] as? Int, 2048)
        XCTAssertEqual(flashCfg["temperature"] as? Double, 0)

        let pro = LLMClient(model: "gemini-2.5-pro")
        let proCfg = pro.geminiGenerationConfig()
        XCTAssertEqual((proCfg["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 128,
                       "Pro defaults to the 128 floor")
    }

    func test_geminiGenerationConfig_honors_override_verbatim() {
        LLMTuning.current = LLMTuning(thinkingBudget: 512, maxOutputTokens: 4096, temperature: 0.5)
        // Even Pro gets the verbatim override (user's choice).
        let pro = LLMClient(model: "gemini-2.5-pro")
        let cfg = pro.geminiGenerationConfig()
        XCTAssertEqual((cfg["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 512)
        XCTAssertEqual(cfg["maxOutputTokens"] as? Int, 4096)
        XCTAssertEqual(cfg["temperature"] as? Double, 0.5)

        // Flash also honors the override (not forced to 0).
        let flash = LLMClient(model: "gemini-2.5-flash")
        XCTAssertEqual((flash.geminiGenerationConfig()["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 512)
    }

    func test_resolvedThinkingBudget() {
        XCTAssertEqual(LLMTuning().resolvedThinkingBudget(forModel: "gemini-2.5-flash"), 0)
        XCTAssertEqual(LLMTuning().resolvedThinkingBudget(forModel: "gemini-2.5-pro"), 128)
        var t = LLMTuning(); t.thinkingBudget = 0
        XCTAssertEqual(t.resolvedThinkingBudget(forModel: "gemini-2.5-pro"), 0,
                       "explicit 0 override beats the Pro floor (user's choice)")
    }

    func test_withCurrent_restores() {
        let before = LLMTuning.current
        LLMTuning.withCurrent(LLMTuning(maxOutputTokens: 9000)) {
            XCTAssertEqual(LLMTuning.current.maxOutputTokens, 9000)
        }
        XCTAssertEqual(LLMTuning.current.maxOutputTokens, before.maxOutputTokens)
    }
}
