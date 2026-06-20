import XCTest
@testable import ParleqAppCore

final class LearnedStoreTests: XCTestCase {

    private func termProposal(_ term: String, confidence: Double, op: LearningProposal.Op = .add) -> LearningProposal {
        LearningProposal(kind: .term, op: op, confidence: confidence, rationale: "r",
                         term: term, context: nil, aliases: nil, rule: nil)
    }
    private func styleProposal(_ rule: String, confidence: Double) -> LearningProposal {
        LearningProposal(kind: .style, op: .add, confidence: confidence, rationale: "r",
                         term: nil, context: nil, aliases: nil, rule: rule)
    }

    private func termProposalWithAliases(_ term: String, aliases: [String], confidence: Double) -> LearningProposal {
        LearningProposal(kind: .term, op: .add, confidence: confidence, rationale: "r",
                         term: term, context: nil, aliases: aliases, rule: nil)
    }

    func test_proposal_alias_colliding_with_user_term_is_suggested() {
        // A high-confidence learned proposal whose ALIAS matches a
        // user-authored entry's term must not auto-apply — the ASR
        // rescorer biases on aliases, so this could hijack the user term.
        let existing = [DictionaryEntry(term: "Acme", source: .user)]
        let decision = LearnedStore.route(
            termProposalWithAliases("Acmd", aliases: ["acme"], confidence: 0.99), against: existing)
        XCTAssertEqual(decision, .suggest,
                       "A proposed alias colliding with a user entry's term must route to suggest")
    }

    func test_proposal_term_colliding_with_user_alias_is_suggested() {
        let existing = [DictionaryEntry(term: "Acme", aliases: ["akmee"], source: .user)]
        let decision = LearnedStore.route(
            termProposal("Akmee", confidence: 0.99), against: existing)
        XCTAssertEqual(decision, .suggest,
                       "A proposed term colliding with a user entry's alias must route to suggest")
    }

    func test_proposal_alias_with_no_user_collision_still_auto_applies() {
        let existing = [DictionaryEntry(term: "Parleq", source: .user)]
        let decision = LearnedStore.route(
            termProposalWithAliases("Mira", aliases: ["meera"], confidence: 0.9), against: existing)
        XCTAssertEqual(decision, .autoApply,
                       "Aliases that don't collide with any user entry shouldn't block auto-apply")
    }

    func test_high_confidence_term_add_auto_applies_when_no_collision() {
        let existing = [DictionaryEntry(term: "Parleq", source: .user)]
        let decision = LearnedStore.route(termProposal("Mira", confidence: 0.9), against: existing)
        XCTAssertEqual(decision, .autoApply, "High-confidence non-colliding term add should auto-apply")
    }

    func test_low_confidence_term_add_is_suggested() {
        let decision = LearnedStore.route(termProposal("Mira", confidence: 0.5), against: [])
        XCTAssertEqual(decision, .suggest, "Below the confidence threshold -> suggest")
    }

    func test_term_change_colliding_with_user_entry_is_suggested() {
        let existing = [DictionaryEntry(term: "Acme", source: .user)]
        let decision = LearnedStore.route(termProposal("Acme", confidence: 0.99, op: .modify), against: existing)
        XCTAssertEqual(decision, .suggest,
                       "A learned change touching a user-authored entry must never auto-apply")
    }

    func test_term_change_colliding_with_learned_entry_can_auto_apply() {
        let existing = [DictionaryEntry(term: "Mira", source: .learned)]
        let decision = LearnedStore.route(termProposal("Mira", confidence: 0.9, op: .modify), against: existing)
        XCTAssertEqual(decision, .autoApply,
                       "Updating a previously-learned entry is safe to auto-apply")
    }

    func test_retire_op_is_always_suggested() {
        let existing = [DictionaryEntry(term: "Mira", source: .learned)]
        let decision = LearnedStore.route(termProposal("Mira", confidence: 0.99, op: .retire), against: existing)
        XCTAssertEqual(decision, .suggest, "Retiring an entry is higher-impact -> always confirm")
    }

    func test_style_proposal_is_deferred_in_slice1() {
        let decision = LearnedStore.route(styleProposal("Be concise", confidence: 0.99), against: [])
        XCTAssertEqual(decision, .deferStyle,
                       "Slice 1 has no style consumer; style proposals are deferred")
    }

    func test_applyTermAdd_appends_learned_entry() {
        var dict = [DictionaryEntry(term: "Parleq", source: .user)]
        LearnedStore.applyTermProposal(termProposal("Mira", confidence: 0.9), to: &dict)
        XCTAssertEqual(dict.count, 2)
        let added = dict.first { $0.term == "Mira" }
        XCTAssertEqual(added?.source, .learned, "Auto-applied entry must carry source=.learned")
    }

    func test_applyTermModify_updates_existing_learned_entry_in_place() {
        var dict = [DictionaryEntry(term: "Mira", aliases: [], source: .learned)]
        let p = LearningProposal(kind: .term, op: .modify, confidence: 0.9, rationale: "r",
                                 term: "Mira", context: "a coworker", aliases: ["meera"], rule: nil)
        LearnedStore.applyTermProposal(p, to: &dict)
        XCTAssertEqual(dict.count, 1, "Modify must not duplicate")
        XCTAssertEqual(dict[0].aliases, ["meera"])
        XCTAssertEqual(dict[0].source, .learned)
    }

    func test_unionAliases_keeps_existing_adds_new_caseInsensitive() {
        let r = LearnedStore.unionAliases(prior: ["meera", "Mira"], proposed: ["MEERA", "mirah"])
        XCTAssertEqual(r, ["meera", "Mira", "mirah"],
                       "Existing aliases kept in order; only case-insensitively new ones appended")
    }

    func test_applyTermMerge_unions_aliases_not_replace() {
        var dict = [DictionaryEntry(term: "Mira", aliases: ["meera"], source: .learned)]
        let p = LearningProposal(kind: .term, op: .merge, confidence: 0.9, rationale: "r",
                                 term: "Mira", context: nil, aliases: ["mira-bot"], rule: nil)
        LearnedStore.applyTermProposal(p, to: &dict)
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict[0].aliases, ["meera", "mira-bot"],
                       "A merge must keep the existing alias and add the new one, not replace")
    }

    func test_autoApplied_distinctive_term_defaults_to_asrAndLLM_biasing() {
        // A DISTINCTIVE auto-learned term (one that reached auto-apply by passing the
        // quality bar's collision check) gets full biasing — ASR-layer included — so a
        // mangled jargon term is fixed at the source. The collision-prone class never
        // reaches this path (the quality bar routes it to suggestions).
        var dict: [DictionaryEntry] = []
        LearnedStore.applyTermProposal(termProposal("Mira", confidence: 0.95), to: &dict)
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict[0].biasing, .asrAndLLM,
                       "Distinctive auto-learned terms get full asrAndLLM biasing")
        XCTAssertEqual(dict[0].source, .learned)
    }

    func test_autoApplied_collision_prone_alias_downgrades_to_llmOnly() {
        // 285a09c: aliases also drive ASR biasing. A distinctive term ("Mira") with a
        // collision-prone alias ("item", a common word) must fall back to llmOnly — otherwise
        // "item" would over-fire to "Mira" at the ASR layer.
        var dict: [DictionaryEntry] = []
        LearnedStore.applyTermProposal(
            termProposalWithAliases("Mira", aliases: ["item"], confidence: 0.95), to: &dict)
        XCTAssertEqual(dict[0].biasing, .llmOnly,
                       "A collision-prone alias forces the whole entry to cleanup-only biasing")
    }

    func test_autoApplied_distinctive_alias_keeps_asrAndLLM() {
        // A distinctive alias (not a common word, doesn't collide with another term) keeps full
        // biasing — alias-resembles-its-own-term is self-excluded, so it isn't a false downgrade.
        var dict: [DictionaryEntry] = []
        LearnedStore.applyTermProposal(
            termProposalWithAliases("Kubernetes", aliases: ["kubernetis"], confidence: 0.95), to: &dict)
        XCTAssertEqual(dict[0].biasing, .asrAndLLM)
    }

    func test_autoApply_modify_with_unsafe_alias_overrides_prior_asrAndLLM() {
        // 4f11a1c: alias safety must OVERRIDE prior biasing — a modify adding a collision-prone
        // alias ("item") to an existing .asrAndLLM entry must drop the WHOLE entry to .llmOnly.
        var dict = [DictionaryEntry(term: "Mira", aliases: ["meera"], biasing: .asrAndLLM, source: .learned)]
        LearnedStore.applyTermProposal(
            termProposalWithAliases("Mira", aliases: ["item"], confidence: 0.95), to: &dict)
        XCTAssertEqual(dict[0].biasing, .llmOnly)
    }

    func test_autoApply_merge_preserves_spokenForms() {
        // bcf90e6: a learned merge must NOT drop existing say-as spoken forms.
        var dict = [DictionaryEntry(term: "iTerm", spokenForms: ["iterm terminal"],
                                    biasing: .llmOnly, source: .learned)]
        LearnedStore.applyTermProposal(
            termProposalWithAliases("iTerm", aliases: ["eyeterm"], confidence: 0.95), to: &dict)
        XCTAssertEqual(dict[0].spokenForms, ["iterm terminal"])
    }

    func test_autoApply_modify_preserves_prior_biasing() {
        // A modify on an existing learned (llmOnly) entry keeps llmOnly.
        var dict = [DictionaryEntry(term: "Mira", biasing: .llmOnly, source: .learned)]
        let p = LearningProposal(kind: .term, op: .modify, confidence: 0.9, rationale: "r",
                                 term: "Mira", context: nil, aliases: ["meera"], rule: nil)
        LearnedStore.applyTermProposal(p, to: &dict)
        XCTAssertEqual(dict[0].biasing, .llmOnly)
    }

    // Fix 2: the quality bar routes junk/collision-prone proposals to
    // .suggest instead of .autoApply.
    func test_common_word_term_routes_to_suggest() {
        let decision = LearnedStore.route(termProposal("scholarly", confidence: 0.99), against: [])
        XCTAssertEqual(decision, .suggest,
                       "A bare common word must not auto-apply (quality bar)")
    }

    func test_all_common_phrase_routes_to_suggest() {
        let decision = LearnedStore.route(termProposal("line item", confidence: 0.99), against: [])
        XCTAssertEqual(decision, .suggest,
                       "An all-common-word phrase must not auto-apply")
    }

    func test_iterm_collision_routes_to_suggest() {
        let decision = LearnedStore.route(termProposal("iTerm", confidence: 0.99), against: [])
        XCTAssertEqual(decision, .suggest,
                       "A term phonetically colliding with a common word must not auto-apply")
    }

    func test_distinctive_term_still_auto_applies() {
        let decision = LearnedStore.route(termProposal("Kubernetes", confidence: 0.9), against: [])
        XCTAssertEqual(decision, .autoApply,
                       "A distinctive, non-colliding term must still auto-apply")
    }

    func test_autoApply_drops_freeform_context() {
        var dict: [DictionaryEntry] = []
        let p = LearningProposal(kind: .term, op: .add, confidence: 0.95, rationale: "r",
                                 term: "Mira", context: "a descriptive label", aliases: ["meera"], rule: nil)
        LearnedStore.applyTermProposal(p, to: &dict)
        XCTAssertEqual(dict.count, 1)
        XCTAssertNil(dict[0].context,
                     "Auto-applied (unreviewed) entries must not persist freeform context to disk")
        XCTAssertEqual(dict[0].aliases, ["meera"], "Word-level aliases are kept — they drive ASR biasing")
        XCTAssertEqual(dict[0].source, .learned)
    }
}
