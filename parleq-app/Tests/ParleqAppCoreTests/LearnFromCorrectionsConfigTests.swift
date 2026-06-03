import XCTest
@testable import ParleqAppCore

final class LearnFromCorrectionsConfigTests: XCTestCase {

    // MARK: - DictionaryEntry.source

    func test_dictionary_entry_source_defaults_to_user() {
        let entry = DictionaryEntry(term: "Parleq")
        XCTAssertEqual(entry.source, .user,
                       "A hand-authored entry must default to .user so learned entries are distinguishable")
    }

    func test_dictionary_entry_source_can_be_learned() {
        let entry = DictionaryEntry(term: "Mira", source: .learned)
        XCTAssertEqual(entry.source, .learned)
    }

    func test_dictionary_source_round_trips_raw_value() {
        XCTAssertEqual(DictionarySource(rawValue: "user"), .user)
        XCTAssertEqual(DictionarySource(rawValue: "learned"), .learned)
        XCTAssertEqual(DictionarySource.learned.rawValue, "learned")
    }

    // MARK: - Config fields

    func test_learnFromCorrectionsEnabled_defaults_to_false() {
        XCTAssertFalse(Config.default.learnFromCorrectionsEnabled,
                       "The feature persists transcript-derived text + sends it to the LLM — must be opt-in (off by default)")
    }

    func test_learned_corrections_retention_defaults_to_nil() {
        XCTAssertNil(Config.default.learnedCorrectionsMaxEntries)
        XCTAssertNil(Config.default.learnedCorrectionsRetentionHours)
    }

    func test_learnFromCorrectionsEnabled_round_trips() {
        var c = Config.default
        c.learnFromCorrectionsEnabled = true
        XCTAssertTrue(c.learnFromCorrectionsEnabled)
        c.learnedCorrectionsMaxEntries = 0
        XCTAssertEqual(c.learnedCorrectionsMaxEntries, 0,
                       "0 must be representable — it's the disable-entirely lever, distinct from nil (unlimited)")
    }
}
