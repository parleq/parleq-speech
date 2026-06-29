import XCTest
@testable import ParleqAppCore

/// Round-trip coverage for the Concord "spoken form" dictionary field
/// (`DictionaryEntry.spokenForms`, on-disk key `spoken_forms`). Mirrors
/// the serialize → parse idiom used by LLMTuningConfigTests.
final class DictionarySpokenFormsConfigTests: XCTestCase {
    func test_spoken_forms_round_trip() {
        var c = Config.default
        c.customDictionary = [
            DictionaryEntry(
                term: "iTerm",
                context: "terminal app",
                aliases: ["i term"],
                spokenForms: ["iterm terminal", "eye term terminal"]
            ),
        ]
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        guard let entry = parsed.customDictionary.first(where: { $0.term == "iTerm" }) else {
            XCTFail("iTerm entry should survive the round-trip")
            return
        }
        XCTAssertEqual(entry.spokenForms, ["iterm terminal", "eye term terminal"])
        XCTAssertEqual(entry.aliases, ["i term"])
    }

    func test_empty_spoken_forms_omitted_from_serialization() {
        var c = Config.default
        c.customDictionary = [DictionaryEntry(term: "Acme")]
        let dict = Config.serializeToDictionary(c)
        guard let dictionary = dict["dictionary"] as? [String: Any],
              let terms = dictionary["terms"] as? [[String: Any]],
              let acme = terms.first(where: { ($0["term"] as? String) == "Acme" })
        else {
            XCTFail("Acme term should serialize")
            return
        }
        XCTAssertNil(acme["spoken_forms"],
                     "Empty spokenForms must be omitted (mirrors aliases)")
    }

    func test_missing_spoken_forms_key_parses_as_empty() {
        // Backward compat: a config written before this field existed
        // (no "spoken_forms" key) must load with spokenForms == [].
        let c = Config.parse(fromDictionary: [
            "dictionary": [
                "terms": [
                    ["term": "Legacy", "aliases": ["leg a see"]],
                ],
            ],
        ])
        guard let entry = c.customDictionary.first(where: { $0.term == "Legacy" }) else {
            XCTFail("Legacy entry should parse")
            return
        }
        XCTAssertEqual(entry.spokenForms, [])
        XCTAssertEqual(entry.aliases, ["leg a see"])
    }

    // MARK: - voice-enrollment harvest routing (E2E "E2E to E" bug)

    /// Multi-word harvested mishears must route to spokenForms (Concord's per-word
    /// dictionary matcher ignores multi-word aliases); single-word ones stay aliases.
    /// Regression: "E2E" enrolled, FluidAudio heard "E2E to E"/"E to E", which were
    /// stored as multi-word aliases and so never corrected the mishear.
    func test_enrolled_mishears_route_multiword_to_spoken_forms() {
        let (aliases, spoken) = SettingsModel.partitionEnrolledMishears(
            ["E2E to E", "E to E", "eToo", "e2e"])
        XCTAssertEqual(spoken, ["E2E to E", "E to E"])
        XCTAssertEqual(aliases, ["eToo", "e2e"])
    }

    /// Dedup is case-insensitive against existing aliases AND spokenForms, and within
    /// the incoming batch.
    func test_enrolled_mishears_dedup_against_existing() {
        let (aliases, spoken) = SettingsModel.partitionEnrolledMishears(
            ["E to E", "newbie", "Keavi", "newbie"],
            existingAliases: ["keavi"],
            existingSpoken: ["e to e"])
        XCTAssertEqual(spoken, [])
        XCTAssertEqual(aliases, ["newbie"])
    }
}
