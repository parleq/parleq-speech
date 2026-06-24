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
}
