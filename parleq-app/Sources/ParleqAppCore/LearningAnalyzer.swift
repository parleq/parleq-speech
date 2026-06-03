// LearningAnalyzer — the off-hot-path brain of "learn from corrections".
//
// Periodically (threshold + idle, rate-capped) it takes a slice of the
// CorrectionJournal plus the CURRENT custom dictionary, asks the already-
// configured cleanup LLM to propose dictionary/style optimizations, and
// hands validated proposals to LearnedStore. Providers stream text only
// (no JSON-schema API), so the model is told to emit a fenced ```json
// block which we extract + decode tolerantly: malformed or out-of-range
// proposals are DROPPED, never trusted. Slice 1 routes only `.term`
// proposals (LearnedStore); `.style` proposals are parsed but deferred
// to slice 2's consumer.

import Foundation

/// A validated proposal from the analysis LLM. `kind` selects the
/// payload: `.term` -> term/context/aliases; `.style` -> rule.
struct LearningProposal: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable { case term, style }
    enum Op: String, Sendable, Equatable { case add, modify, merge, retire }

    let kind: Kind
    let op: Op
    let confidence: Double
    let rationale: String
    // term payload
    let term: String?
    let context: String?
    let aliases: [String]?
    // style payload
    let rule: String?
}

extension LearningAnalyzer {

    /// Lenient DTO: all fields optional / String-typed so a single bad
    /// enum value drops one proposal instead of failing the whole batch.
    private struct ProposalsEnvelope: Decodable {
        let proposals: [FailableDecodable<ProposalDTO>]
    }
    /// Decodes an element, swallowing a per-element decode failure to
    /// `nil` instead of throwing — so one proposal with a wrong-typed
    /// field (e.g. `confidence` as a string) drops just that proposal
    /// rather than failing the whole batch.
    private struct FailableDecodable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(T.self)
        }
    }
    private struct ProposalDTO: Decodable {
        let kind: String?
        let op: String?
        let confidence: Double?
        let rationale: String?
        let term: String?
        let context: String?
        let aliases: [String]?
        let rule: String?
    }

    /// Extract + validate proposals from the model's text response.
    /// Returns [] on any failure. Public for unit testing.
    nonisolated static func parseProposals(from text: String) -> [LearningProposal] {
        guard let jsonData = extractJSON(from: text) else { return [] }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(ProposalsEnvelope.self, from: jsonData) else { return [] }
        return envelope.proposals.compactMap { $0.value }.compactMap(validate)
    }

    /// Pull the JSON object out of a possibly-fenced response. Prefers a
    /// ```json fence; falls back to the first balanced `{ ... }` span.
    nonisolated private static func extractJSON(from text: String) -> Data? {
        if let fenceRange = text.range(of: "```json") {
            let afterFence = text[fenceRange.upperBound...]
            if let close = afterFence.range(of: "```") {
                return afterFence[..<close.lowerBound].data(using: .utf8)
            }
        }
        // Fallback: first '{' to last '}'.
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            return text[open...close].data(using: .utf8)
        }
        return nil
    }

    // Bounds for durable learned fields (see `validate`). Dictionary terms
    // and aliases are short — a name or product, not a sentence.
    nonisolated static let maxDurableFieldChars = 64
    nonisolated static let maxDurableFieldWords = 5
    nonisolated static let maxDurableAliases = 12
    nonisolated static let maxDurableContextChars = 80

    /// Clause/prose punctuation that has no place in a name or product term —
    /// its presence is a cheap signal the value is dictation text. (Periods,
    /// hyphens, apostrophes, and ampersands are allowed — abbreviations,
    /// compound names, and "AT&T"-style terms use them.)
    nonisolated static let durableProseMarkers: Set<Character> = [
        ",", ";", ":", "!", "?", "\"", "“", "”", "…"
    ]

    /// Accept `raw` only if it's a short, word-level value — a plausible
    /// dictionary term or alias, not a sentence. This is defense-in-depth to
    /// keep dictation-derived text out of config.json; the primary guards are
    /// that the model is asked for terms, confidence gating, and (for accept)
    /// user review. Returns the trimmed value, or nil so the caller drops it.
    nonisolated static func wordLevel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxDurableFieldChars else { return nil }
        // Clause punctuation → reject (prose, not a term).
        guard !trimmed.contains(where: { durableProseMarkers.contains($0) }) else { return nil }
        let words = trimmed.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard words.count <= maxDurableFieldWords else { return nil }
        // A multi-word value ending in a period is a sentence
        // ("call mom today."), not a term — but a one/two-token abbreviation
        // ("Ph.D.", "Acme Inc.") is fine, so only reject at 3+ words.
        if words.count >= 3, trimmed.hasSuffix(".") { return nil }
        return trimmed
    }

    /// Collapse a freeform context label to a single short line. Used only
    /// for entries the user reviews before accepting; auto-applied entries
    /// drop context entirely.
    nonisolated static func boundedContext(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxDurableContextChars))
    }

    nonisolated private static func validate(_ dto: ProposalDTO) -> LearningProposal? {
        guard let kindRaw = dto.kind, let kind = LearningProposal.Kind(rawValue: kindRaw),
              let opRaw = dto.op, let op = LearningProposal.Op(rawValue: opRaw),
              let confidence = dto.confidence, (0.0...1.0).contains(confidence),
              let rationale = dto.rationale, !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        switch kind {
        case .term:
            // Privacy chokepoint: the durable fields we may persist to
            // config.json (term, aliases, context) must be short, word-level
            // values — never a sentence — so correction-derived freeform text
            // can't leak onto disk. A "term" or alias that reads like a
            // phrase is dropped; the context label is collapsed to a single
            // short line. (Auto-apply drops context entirely — see
            // `LearnedStore.applyTermProposal`.)
            guard let rawTerm = dto.term, let term = wordLevel(rawTerm) else { return nil }
            let aliases = (dto.aliases ?? []).compactMap(wordLevel)
            return LearningProposal(kind: .term, op: op, confidence: confidence, rationale: rationale,
                                    term: term,
                                    context: boundedContext(dto.context),
                                    aliases: aliases.isEmpty ? nil : Array(aliases.prefix(maxDurableAliases)),
                                    rule: nil)
        case .style:
            guard let rule = dto.rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else { return nil }
            return LearningProposal(kind: .style, op: op, confidence: confidence, rationale: rationale,
                                    term: nil, context: nil, aliases: nil, rule: rule)
        }
    }
}

/// Thread-safe text accumulator for the streaming LLM response.
/// `AssembledTextBox` in AppState.swift is private, so we define an
/// equivalent here. The onEvent closure is @Sendable (fires on
/// URLSession's queue), so we cannot capture-and-mutate a plain `var`
/// under Swift 6 strict concurrency — this reference type is the
/// correct pattern.
private final class StreamTextBox: @unchecked Sendable {
    private var _value: String = ""
    func append(_ chunk: String) { _value.append(chunk) }
    var value: String { _value }
}

/// Captures the terminal `.done` summary from the @Sendable stream
/// callback (same single-thread serial-delivery assumption as
/// StreamTextBox / AppState's AssembledTextBox).
private final class StreamSummaryBox: @unchecked Sendable {
    private var _summary: LLMStreamSummary?
    func set(_ summary: LLMStreamSummary) { _summary = summary }
    var value: LLMStreamSummary? { _summary }
}

@MainActor
final class LearningAnalyzer {
    static let shared = LearningAnalyzer()

    /// Term proposals at or above this confidence (and not colliding
    /// with a user entry) auto-apply; below it they're suggested.
    nonisolated static let autoApplyConfidenceThreshold = 0.8

    /// Fire analysis once this many new corrections accumulate.
    nonisolated static let triggerThreshold = 5
    /// Don't run analysis more than once per this interval (rate cap).
    nonisolated static let minIntervalSeconds: TimeInterval = 600
    /// Cap the journal slice handed to the model so token cost is bounded.
    nonisolated static let maxRecordsPerRun = 40

    private var lastRunAt: Date?
    private var isRunning = false

    private init() {}

    /// Pure gate (unit-tested). Run when there's a backlog at/above the
    /// threshold AND the rate cap has elapsed.
    nonisolated static func shouldRun(
        unanalyzedCount: Int,
        threshold: Int,
        lastRunAt: Date?,
        now: Date,
        minIntervalSeconds: TimeInterval
    ) -> Bool {
        guard unanalyzedCount >= threshold, threshold > 0, unanalyzedCount > 0 else { return false }
        if let last = lastRunAt, now.timeIntervalSince(last) < minIntervalSeconds { return false }
        return true
    }

    /// Called after each capture (threshold path) and from the idle
    /// timer (threshold=1). `provider` is the cleanup provider AppState
    /// already resolved — reused so analysis crosses no new boundary and
    /// we don't duplicate provider construction. No-ops off the hot path.
    func runIfDue(provider: any LLMProvider, threshold: Int) async {
        guard !isRunning else { return }
        // Defense-in-depth: never send correction snippets to the LLM
        // when the feature is off, even if a caller forgot to gate. A
        // backlog can persist on disk after the user disables without
        // purging; this guard ensures it's never transmitted.
        guard Config.load().config.learnFromCorrectionsEnabled else { return }
        let journal = CorrectionJournal.shared
        // Prune age/count-expired records before doing anything else, so
        // an idle session that has sat past `learnedCorrectionsRetentionHours`
        // never hands the LLM records that have aged out (retention is
        // otherwise only enforced on record/config changes).
        journal.pruneExpired()
        guard Self.shouldRun(unanalyzedCount: journal.unanalyzedCount, threshold: threshold,
                             lastRunAt: lastRunAt, now: Date(), minIntervalSeconds: Self.minIntervalSeconds) else { return }
        isRunning = true
        lastRunAt = Date()
        defer { isRunning = false }

        // Pull only records not yet analyzed (oldest-first, bounded) so
        // consecutive runs never re-analyze overlapping records.
        let records = journal.unanalyzedRecords(limit: Self.maxRecordsPerRun)
        guard !records.isEmpty else { return }

        let (config, _) = Config.load()
        // Respect the custom-dictionary feature gate: when the dictionary
        // is disabled, cleanup sends an empty dictionary, so analysis must
        // too — don't ship the user's proprietary terms to the LLM behind
        // a feature they've turned off.
        let dictForPrompt = config.customDictionaryEnabled ? config.customDictionary : []
        let systemPrompt = SystemPrompts.learningAnalysis(currentDictionary: dictForPrompt)
        // buildUserMessage may drop records that don't fit the prompt
        // budget; only the `included` ones are actually analyzed, so only
        // those get marked analyzed below (dropped ones stay for next run).
        let (userMessage, analyzedRecords) = Self.buildUserMessage(records)

        // Accumulate streamed chunks. The onEvent closure is @Sendable,
        // so we CANNOT capture-and-mutate a plain `var` (Swift 6 strict
        // concurrency data race). Use StreamTextBox / StreamSummaryBox —
        // local equivalents of AppState's private AssembledTextBox.
        // Capture the journal generation before the async call so we can
        // discard results if the user clears the ring (Clear all /
        // disable-purge) while analysis is in flight.
        let generationAtStart = journal.generation
        let box = StreamTextBox()
        let summaryBox = StreamSummaryBox()
        do {
            try await provider.generateStreaming(
                systemPrompt: systemPrompt,
                messages: [LLMMessage(role: "user", content: userMessage)],
                onEvent: { event in
                    switch event {
                    case .chunk(let text): box.append(text)
                    case .done(let summary): summaryBox.set(summary)
                    }
                }
            )
        } catch {
            // No-op: retry next trigger. Count-only log (no transcript text).
            FileHandle.standardError.write("[parleq] LearningAnalyzer: analysis failed (\(records.count) records)\n".data(using: .utf8) ?? Data())
            return
        }

        // Record token usage so analysis LLM egress is reflected in the
        // Usage view + cost ledger (kind "learning"; no paste target).
        if let summary = summaryBox.value {
            UsageLedger.shared.append(UsageEntry(
                ts: Date(),
                kind: "learning",
                provider: provider.providerName,
                model: provider.model,
                inputTokens: summary.inputTokens,
                outputTokens: summary.outputTokens,
                ttftMs: Int(summary.ttft * 1000),
                totalMs: Int(summary.totalLatency * 1000),
                targetApp: nil
            ))
        }

        // If the user cleared the journal while the LLM call was in
        // flight, discard the results — don't resurrect cleared data as
        // suggestions or applied dictionary changes. (Usage was logged
        // above: the call really happened and its cost is real.)
        guard journal.generation == generationAtStart else {
            FileHandle.standardError.write("[parleq] LearningAnalyzer: journal cleared mid-analysis; discarding results\n".data(using: .utf8) ?? Data())
            return
        }
        // Also discard if the feature was disabled while the call was in
        // flight (e.g. the user toggled off and chose "Keep Data", so the
        // ring wasn't cleared) — don't apply learned changes after the
        // user turned learning off. (clear() / disable-purge and
        // retention→0 are covered by the generation check above.)
        guard Config.load().config.learnFromCorrectionsEnabled else {
            FileHandle.standardError.write("[parleq] LearningAnalyzer: feature disabled mid-analysis; discarding results\n".data(using: .utf8) ?? Data())
            return
        }

        let proposals = Self.parseProposals(from: box.value)
        let applied = LearnedStore.shared.ingest(proposals)
        // Mark exactly the records that made it into the prompt (by id)
        // so they're never re-analyzed; records dropped for budget or
        // that arrived mid-flight stay unanalyzed for a later run.
        journal.markAnalyzed(analyzedRecords)
        FileHandle.standardError.write("[parleq] LearningAnalyzer: \(proposals.count) proposals, \(applied) auto-applied\n".data(using: .utf8) ?? Data())
    }

    /// Serialize the journal slice for the model. Length-only is not
    /// possible here (the model needs the text), but this stays within
    /// the opt-in consent: the same provider already saw this text.
    /// Build the analysis prompt AND report which records were actually
    /// included. Refine records can hold full before/after dictations, so
    /// each field is capped and the batch is capped — the newest records
    /// are kept and the oldest dropped if the budget is exhausted. The
    /// caller must mark ONLY the returned `included` records as analyzed;
    /// dropped records stay unanalyzed for a later run (per-field caps keep
    /// every single line well under the total, so at least one always fits
    /// — no record can be permanently starved). Returns chronological text.
    nonisolated static func buildUserMessage(_ records: [CorrectionRecord]) -> (text: String, included: [CorrectionRecord]) {
        let perFieldCap = 600
        let totalCap = 8000
        func cap(_ s: String?, _ n: Int) -> String {
            let t = s ?? ""
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }
        var keptLines: [String] = []
        var keptRecords: [CorrectionRecord] = []
        var used = 0
        // Oldest-first (records arrive oldest→newest). When the budget fills,
        // the records left over are the NEWEST — they stay unanalyzed and
        // re-appear in the next run. Iterating newest-first instead would let
        // a steady stream of new corrections starve the oldest indefinitely.
        for rec in records {
            let line: String
            switch rec.kind {
            case .refine:
                line = "- REFINE — instruction: \"\(cap(rec.instruction, perFieldCap))\" | before: \"\(cap(rec.before, perFieldCap))\" | after: \"\(cap(rec.after, perFieldCap))\""
            case .spellout:
                line = "- SPELLOUT — candidate term: \"\(cap(rec.term, 120))\" | in cleaned text: \"\(cap(rec.after, perFieldCap))\""
            }
            if !keptLines.isEmpty && used + line.count > totalCap { break }
            keptLines.append(line)
            keptRecords.append(rec)
            used += line.count
        }
        // Already chronological — no reversal needed.
        let text = (["Recent corrections:"] + keptLines).joined(separator: "\n")
        return (text, keptRecords)
    }
}
