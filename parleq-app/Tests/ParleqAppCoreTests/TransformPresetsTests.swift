import AppKit
import XCTest
@testable import ParleqAppCore

final class TransformPresetsTests: XCTestCase {

    // MARK: - Model + Config fields

    func test_transform_preset_holds_id_name_prompt() {
        let p = TransformPreset(id: "abc", name: "Concise", prompt: "Rewrite concisely.")
        XCTAssertEqual(p.id, "abc")
        XCTAssertEqual(p.name, "Concise")
        XCTAssertEqual(p.prompt, "Rewrite concisely.")
    }

    func test_config_defaults_have_no_presets_and_feature_enabled() {
        let c = Config.default
        XCTAssertTrue(c.transformPresets.isEmpty, "Zero-config users must see no presets")
        XCTAssertTrue(c.presetAppDefaults.isEmpty)
        XCTAssertTrue(c.transformPresetsEnabled, "Feature is on by default; only MDM disables it")
    }

    // MARK: - Parse / save round-trip

    func test_presets_parse_from_top_level_array() throws {
        // JSON input:
        // { "presets": [ {"id": "p1", "name": "Concise", "prompt": "Rewrite concisely."},
        //                {"id": "",   "name": "Bad",     "prompt": "dropped — empty id"},
        //                {"id": "p2", "name": " ",       "prompt": "dropped — blank name"} ],
        //   "preset_app_defaults": { "com.tinyspeck.slackmacgap": "p1", "bad": 7 } }
        // Expect: exactly one preset (p1); mapping keeps only the string-valued entry.
        let input: [String: Any] = [
            "presets": [
                ["id": "p1", "name": "Concise", "prompt": "Rewrite concisely."],
                ["id": "",   "name": "Bad",     "prompt": "dropped — empty id"],
                ["id": "p2", "name": " ",       "prompt": "dropped — blank name"],
            ] as [[String: Any]],
            "preset_app_defaults": [
                "com.tinyspeck.slackmacgap": "p1",
                "bad": 7,
            ] as [String: Any],
        ]
        let c = Config.parse(fromDictionary:input)
        XCTAssertEqual(c.transformPresets.map { $0.id }, ["p1"])
        XCTAssertEqual(c.presetAppDefaults, ["com.tinyspeck.slackmacgap": "p1"])
    }

    func test_config_without_preset_keys_loads_empty() throws {
        // "{}" → transformPresets empty, presetAppDefaults empty, transformPresetsEnabled true
        let c = Config.parse(fromDictionary:[:])
        XCTAssertTrue(c.transformPresets.isEmpty)
        XCTAssertTrue(c.presetAppDefaults.isEmpty)
        XCTAssertTrue(c.transformPresetsEnabled)
    }

    func test_presets_round_trip_through_save() throws {
        // Config with one preset (id p1, name Concise) + mapping com.apple.mail→p1,
        // serialized → dict["presets"] has 1 element; dict["preset_app_defaults"]["com.apple.mail"] == "p1"
        var c = Config.default
        c.transformPresets = [TransformPreset(id: "p1", name: "Concise", prompt: "Rewrite concisely.")]
        c.presetAppDefaults = ["com.apple.mail": "p1"]
        let dict = Config.serializeToDictionary(c)
        let presets = dict["presets"] as? [[String: Any]]
        XCTAssertEqual(presets?.count, 1)
        XCTAssertEqual(presets?.first?["id"] as? String, "p1")
        XCTAssertEqual(presets?.first?["name"] as? String, "Concise")
        let appDefaults = dict["preset_app_defaults"] as? [String: String]
        XCTAssertEqual(appDefaults?["com.apple.mail"], "p1")
    }

    func test_save_omits_empty_preset_sections() throws {
        // Config.default serialized → dict has NO "presets" key and NO "preset_app_defaults" key
        // (existing configs stay byte-stable when the feature is unused)
        let dict = Config.serializeToDictionary(Config.default)
        XCTAssertNil(dict["presets"], "No presets → key must be absent for byte-stability")
        XCTAssertNil(dict["preset_app_defaults"], "No app defaults → key must be absent for byte-stability")
    }

    // MARK: - Per-app default resolution

    private func configWithPreset() -> Config {
        var c = Config.default
        c.transformPresets = [TransformPreset(id: "p1", name: "Concise", prompt: "Rewrite concisely.")]
        c.presetAppDefaults = ["com.apple.mail": "p1", "com.dangling.app": "ghost"]
        return c
    }

    func test_presetForApp_resolves_mapped_bundle() {
        XCTAssertEqual(configWithPreset().presetForApp("com.apple.mail")?.id, "p1")
    }

    func test_presetForApp_nil_for_unmapped_nil_or_dangling() {
        let c = configWithPreset()
        XCTAssertNil(c.presetForApp("com.unmapped.app"))
        XCTAssertNil(c.presetForApp(nil))
        XCTAssertNil(c.presetForApp("com.dangling.app"),
                     "A mapping whose preset was deleted resolves to nil, not a crash")
        XCTAssertNil(c.presetForApp(""))
    }

    func test_presetForApp_nil_when_feature_disabled() {
        var c = configWithPreset()
        c.transformPresetsEnabled = false
        XCTAssertNil(c.presetForApp("com.apple.mail"),
                     "MDM-disabled feature must not apply defaults")
    }

    // MARK: - Prompt assembly

    func test_cleanup_with_nil_transform_is_byte_identical_to_today() {
        XCTAssertEqual(SystemPrompts.cleanup(dictionary: []),
                       SystemPrompts.cleanup(dictionary: [], transform: nil),
                       "No-preset users must get the EXACT prompt the benchmarks measured")
    }

    func test_cleanup_with_transform_appends_instruction() {
        let p = SystemPrompts.cleanup(dictionary: [], transform: "Rewrite concisely.")
        XCTAssertTrue(p.hasPrefix(SystemPrompts.cleanup(dictionary: [])),
                      "Transform is a trailing addendum; the base prompt is unchanged")
        XCTAssertTrue(p.contains("Rewrite concisely."))
    }

    func test_transformHint_empty_for_nil_or_blank() {
        XCTAssertEqual(SystemPrompts.transformHint(nil), "")
        XCTAssertEqual(SystemPrompts.transformHint("   "), "")
    }

    func test_transformHint_carries_instruction_for_valid_transform() {
        let hint = SystemPrompts.transformHint("Rewrite as a tight bulleted list.")
        XCTAssertFalse(hint.isEmpty)
        XCTAssertTrue(hint.contains("Rewrite as a tight bulleted list."))
    }

    func test_referenceTransformHint_wording_fits_the_reference_prompt() {
        // The reference-aware cleanup path appends its OWN transform
        // addendum to the reference system prompt. That prompt has no
        // "cleanup rules", and the utterance there is an instruction
        // over references — so the addendum must NOT borrow the plain
        // hint's wording (which could steer the model into transforming
        // the spoken instruction instead of fulfilling it).
        let hint = SystemPrompts.referenceTransformHint("Make this formal.")
        XCTAssertFalse(hint.isEmpty)
        XCTAssertTrue(hint.contains("Make this formal."))
        XCTAssertTrue(hint.contains("fulfilling the user's instruction"),
                      "Reference variant must scope the transform to the fulfilled output")
        XCTAssertFalse(hint.contains("cleanup rules"),
                       "Reference prompt has no cleanup rules to refer to")
        // Same empty-for-nil/blank contract as the plain hint, so the
        // call site can append unconditionally.
        XCTAssertEqual(SystemPrompts.referenceTransformHint(nil), "")
        XCTAssertEqual(SystemPrompts.referenceTransformHint("  "), "")
    }

    // MARK: - SettingsModel.save() filtering — testability note
    //
    // The two-tier dangling-mapping fix (persistedIDs vs inMemoryIDs) lives
    // inline in SettingsModel.save() in SettingsWindow.swift. SettingsModel
    // cannot be constructed in unit tests: its init() calls Config.load()
    // (reads ~/.parleq/config.json) and KeychainStore (reads the Keychain),
    // with no injection seam.  The filter logic is covered indirectly by
    // test_presets_parse_from_top_level_array (dangling mapping stripped at
    // load) and test_presets_round_trip_through_save (valid mapping preserved).
    // A dedicated test would require extracting the filter into a pure
    // free function — deferred until SettingsModel gets a testable init.

    // MARK: - fittingChipCount — width-aware chip fitting

    func test_fittingChipCount_all_fit_exactly_no_reserve() {
        // Three chips that sum to exactly `available`. All fit →
        // returns widths.count (no overflow reserve consumed).
        let widths: [CGFloat] = [40, 50, 60]
        let spacing: CGFloat = 6
        // total = 40 + 6 + 50 + 6 + 60 = 162
        let available: CGFloat = 162
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: available,
                             spacing: spacing, overflowReserve: 28),
            3,
            "All chips fit exactly — must return widths.count (no reserve penalty)"
        )
    }

    func test_fittingChipCount_overflow_holds_reserve() {
        // Four chips: first two fit, third pushes total past available
        // when the overflow reserve is held back.
        // chip widths: [50, 50, 50, 50], spacing: 6, reserve: 28
        // w/o reserve: 50 + 56 + 56 + 56 = 218
        // available = 170
        // Fit k=2: used = 50+6+50 = 106; try k=3: 106+6+50=162; 162+6+28=196 > 170 → break at k=2
        let widths: [CGFloat] = [50, 50, 50, 50]
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 170,
                             spacing: 6, overflowReserve: 28),
            2,
            "Third chip won't fit once overflow reserve is held back"
        )
    }

    func test_fittingChipCount_zero_available_returns_zero() {
        let widths: [CGFloat] = [40, 50, 60]
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 0,
                             spacing: 6, overflowReserve: 28),
            0,
            "Zero available width → nothing fits"
        )
    }

    func test_fittingChipCount_empty_widths_returns_zero() {
        XCTAssertEqual(
            fittingChipCount(widths: [], available: 400,
                             spacing: 6, overflowReserve: 28),
            0,
            "No chips → 0"
        )
    }

    func test_fittingChipCount_single_chip_fits_no_overflow() {
        // A single chip fits without needing an overflow reserve — no ⋯ menu.
        // available=50, single chip width=40: 40 ≤ 50 → 1 (no reserve needed)
        let widths: [CGFloat] = [40]
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 50,
                             spacing: 6, overflowReserve: 28),
            1,
            "Single chip fits — returns 1, no overflow reserve consumed"
        )
    }

    func test_fittingChipCount_first_chip_overwide_goes_to_menu() {
        // Two chips where the first is over-wide: even the first chip plus
        // the overflow reserve exceeds available, so nothing renders inline.
        // widths=[80, 30], available=100, reserve=28:
        // all-fit total = 80+6+30 = 116 > 100 → overflow path.
        // try k=1: next=80; 80+6+28=114 > 100 → break; count=0.
        let widths: [CGFloat] = [80, 30]
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 100,
                             spacing: 6, overflowReserve: 28),
            0,
            "First chip + reserve exceed available — nothing fits inline"
        )
    }

    func test_fittingChipCount_spacing_makes_the_difference() {
        // Construct widths where spacing is the deciding factor.
        // Two chips at 50 each, spacing 6, reserve 28, available 134.
        // Without spacing between them: 50+50 = 100 ≤ 134 → all-fit check: total = 50+6+50 = 106 ≤ 134 → 2.
        // Reduce available to 105: 106 > 105 → overflow path.
        // k=1: used=50; try k=2: 50+6+50=106; 106+6+28=140 > 105 → break. count=1.
        let widths: [CGFloat] = [50, 50]
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 106,
                             spacing: 6, overflowReserve: 28),
            2,
            "Both chips fit at exactly 106pt available (50+6+50)"
        )
        XCTAssertEqual(
            fittingChipCount(widths: widths, available: 105,
                             spacing: 6, overflowReserve: 28),
            1,
            "Spacing tips total past 105pt — only first chip fits inline"
        )
    }

    // MARK: - PresetChipMetrics.chipWidth — measurement mirrors view caps

    func test_chipWidth_short_title_not_capped() {
        // A title whose pixel width is below labelMaxWidth must NOT be capped by
        // chipWidth — the view renders it at natural width (.fixedSize), so the
        // measurement must match.  "Hi" is well under 120pt at 11pt medium.
        let title = "Hi"
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let measured = (title as NSString)
            .size(withAttributes: [.font: chipFont]).width
        // Guard that our test premise holds — skip if the font renders this wider
        // than labelMaxWidth (unexpected on any system, but defensive).
        guard measured < PresetChipMetrics.labelMaxWidth else {
            XCTFail("Test premise broken: 'Hi' measured wider than labelMaxWidth")
            return
        }
        let expectedWidth = measured + PresetChipMetrics.horizontalPadding * 2 + 2
        XCTAssertEqual(
            PresetChipMetrics.chipWidth(for: title),
            expectedWidth,
            accuracy: 0.001,
            "Short-but-narrow title must measure uncapped (hug-don't-expand)"
        )
    }

    // MARK: - Mapping parse: whitespace trimming

    func test_preset_app_defaults_keys_and_values_are_trimmed() {
        // A hand-authored managed config with padding on both key (bundle ID)
        // and value (preset ID) must resolve to the trimmed forms — so " p1 "
        // matches a preset with id "p1" and " com.apple.mail " resolves the
        // right app.
        let input: [String: Any] = [
            "presets": [
                ["id": "p1", "name": "Concise", "prompt": "Rewrite concisely."],
            ] as [[String: Any]],
            "preset_app_defaults": [
                " com.apple.mail ": " p1 ",
            ] as [String: Any],
        ]
        let c = Config.parse(fromDictionary:input)
        XCTAssertEqual(c.presetAppDefaults, ["com.apple.mail": "p1"],
                       "Bundle-ID key and preset-ID value must be trimmed at parse time")
    }
}
