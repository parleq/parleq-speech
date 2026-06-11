// UsageLedger — append-only JSONL of every LLM call Parleq makes,
// plus a pricing table and aggregation helpers so the Settings
// window can show "today / this month / all time" totals + cost.
//
// Storage: ~/.parleq/usage.jsonl. One JSON object per line. Append
// is the only mutation; old entries are immutable. The user can
// `cat`/`jq` the file directly, or delete it to reset.
//
// No transcripts, prompts, or API keys land in the ledger by
// design — only timestamp, model, token counts, latency, and the
// destination app's bundle ID. That keeps the file safe to share
// for cost-debugging or back up alongside dotfiles.
//
// Threading: append() is nonisolated and dispatches the file I/O
// onto a private utility queue, so callers in @Sendable contexts
// (the LLM stream's .done callback fires on URLSession's queue)
// can call it without main-thread hops or actor ceremony.
// aggregate() reads synchronously and is meant for the
// SettingsWindow's view-on-appear path.

import Foundation

/// One LLM call. Schema is stable on disk — adding fields is
/// fine (use Optional + default in decode), removing or renaming
/// requires a migration.
struct UsageEntry: Codable, Sendable {
    let ts: Date
    /// "cleanup" for the post-ASR pass that prepares text for the
    /// overlay; "refine" for the user-driven follow-up turn.
    let kind: String
    /// Provider string. Current values: "gemini", "bedrock", "vertex",
    /// "azure", "openai", "local". Drives the Pricing lookup with model.
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let ttftMs: Int
    let totalMs: Int
    /// Bundle ID of the app the user pasted into. Useful for
    /// per-app breakdowns later. Optional because Paster can
    /// occasionally fail to capture a bundle ID (rare; processes
    /// without a UI bundle).
    let targetApp: String?
}

/// Per-bucket totals (today, this month, all time).
struct UsageBucket: Sendable {
    var calls: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var costUSD: Double = 0
}

struct UsageAggregate: Sendable {
    let today: UsageBucket
    /// 0.14.0 PR 5 (#220): rolling-7-day bucket used by the Stats
    /// section. `Calendar`'s standard `startOfWeek` would tie us
    /// to locale week-start (Sunday in US, Monday in many EU
    /// locales) — a rolling 7-day window is more useful for the
    /// "am I dictating more or less than last week?" framing.
    let thisWeek: UsageBucket
    let thisMonth: UsageBucket
    let allTime: UsageBucket
    /// All-time totals re-bucketed per (provider, model) so the
    /// Settings UI can show "where the cost is going" — e.g. how
    /// many calls went to Bedrock Haiku vs Gemini Flash. Sorted by
    /// call count descending, capped only by however many distinct
    /// models the user has dictated against (typically 1–3).
    let byModel: [ModelBreakdown]
    /// Most recent entries first, capped at recentLimit so the
    /// Settings window can show a manageable list without
    /// streaming the whole file into a SwiftUI list view.
    let recent: [UsageEntry]

    static let empty = UsageAggregate(
        today: UsageBucket(), thisWeek: UsageBucket(),
        thisMonth: UsageBucket(), allTime: UsageBucket(),
        byModel: [], recent: []
    )
}

/// One row in the per-model breakdown — provider + raw model ID +
/// the totals bucket. The `displayName` helper produces a friendly
/// label for the UI (Bedrock model IDs are long and ARN-shaped;
/// users care about "Claude Haiku 4.5", not the inference-profile
/// path).
struct ModelBreakdown: Sendable, Identifiable {
    let provider: String
    let model: String
    let bucket: UsageBucket

    var id: String { "\(provider):\(model)" }

    var displayName: String {
        switch model {
        case "gemini-2.5-flash":      return "Gemini 2.5 Flash"
        case "gemini-2.5-flash-lite": return "Gemini 2.5 Flash Lite"
        case "gemini-2.5-pro":        return "Gemini 2.5 Pro"
        case "us.anthropic.claude-haiku-4-5-20251001-v1:0",
             "anthropic.claude-haiku-4-5-20251001-v1:0":
            return "Claude Haiku 4.5 (Bedrock)"
        case "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
             "anthropic.claude-sonnet-4-5-20250929-v1:0":
            return "Claude Sonnet 4.5 (Bedrock)"
        case "openai.gpt-oss-120b-1:0": return "GPT-OSS 120B (Bedrock)"
        case "openai.gpt-oss-20b-1:0":  return "GPT-OSS 20B (Bedrock)"
        // On-device model: show a user-friendly name rather than the
        // raw HuggingFace checkpoint string.
        case LocalModelDefaults.checkpoint: return "On-device (Gemma 4 E4B)"
        default: return model
        }
    }
}

/// Per-1M-token rates. Add new models here as we use them.
/// Sources: https://ai.google.dev/pricing (Gemini),
/// https://aws.amazon.com/bedrock/pricing/ (Bedrock if/when we
/// add it). User can override via ~/.parleq/config.json's
/// `pricing` section in a future iteration; hardcoded for now.
struct ModelPrice: Sendable {
    let inputPerMillionUSD: Double
    let outputPerMillionUSD: Double
}

enum Pricing {
    /// Bundled fallback rates, baked in at build time. Used when
    /// `PricingCache` hasn't yet fetched LiteLLM's live JSON
    /// (cold launch, offline, fetch failed) or when LiteLLM
    /// doesn't have an entry for a particular model. Verify
    /// against the provider's pricing page if costs feel off —
    /// both Google and AWS have periodically tweaked these and
    /// added tiered pricing (different rates above 128k context,
    /// etc.) which we don't model yet. Sources:
    ///   - Gemini: https://ai.google.dev/pricing
    ///   - Bedrock: https://aws.amazon.com/bedrock/pricing/
    /// Bedrock prices below match the model's underlying rate;
    /// cross-region inference profile prefixes (`us.*`) bill at
    /// the same rate as the bare model IDs.
    static let bundledDefaults: [String: ModelPrice] = [
        // Google Gemini direct API.
        "gemini-2.5-flash":      ModelPrice(inputPerMillionUSD: 0.30, outputPerMillionUSD: 2.50),
        "gemini-2.5-flash-lite": ModelPrice(inputPerMillionUSD: 0.10, outputPerMillionUSD: 0.40),
        "gemini-2.5-pro":        ModelPrice(inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0),

        // AWS Bedrock — Anthropic Claude.
        "us.anthropic.claude-haiku-4-5-20251001-v1:0":
            ModelPrice(inputPerMillionUSD: 1.00, outputPerMillionUSD: 5.00),
        "anthropic.claude-haiku-4-5-20251001-v1:0":
            ModelPrice(inputPerMillionUSD: 1.00, outputPerMillionUSD: 5.00),
        "us.anthropic.claude-sonnet-4-5-20250929-v1:0":
            ModelPrice(inputPerMillionUSD: 3.00, outputPerMillionUSD: 15.00),
        "anthropic.claude-sonnet-4-5-20250929-v1:0":
            ModelPrice(inputPerMillionUSD: 3.00, outputPerMillionUSD: 15.00),

        // AWS Bedrock — OpenAI open-weight family.
        "openai.gpt-oss-120b-1:0":
            ModelPrice(inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.60),
        "openai.gpt-oss-20b-1:0":
            ModelPrice(inputPerMillionUSD: 0.07, outputPerMillionUSD: 0.30),
    ]

    /// Cost lookup. Delegates to `PricingCache.shared`, which
    /// merges live LiteLLM data with the bundled defaults above.
    /// Returns nil if neither source has the model — UI then
    /// renders cost as "—" instead of guessing wrong.
    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        PricingCache.shared.cost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}

final class UsageLedger: @unchecked Sendable {
    /// Singleton. AppState writes to it from the LLM .done
    /// callback (on URLSession's queue); SettingsWindow reads from
    /// it on the main actor when the window opens. Both paths use
    /// the file as the source of truth, so no in-memory cache
    /// invalidation to worry about.
    static let shared = UsageLedger()

    private let fileURL: URL
    private let writeQueue = DispatchQueue(
        label: "com.parleq.app.usage", qos: .utility
    )
    /// Cap on the number of "recent" entries surfaced to the UI.
    /// The on-disk file can be arbitrarily large; we just don't
    /// stream every line into a SwiftUI list.
    private static let recentLimit = 50

    private init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".parleq")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        self.fileURL = URL(
            fileURLWithPath: (dir as NSString).appendingPathComponent("usage.jsonl")
        )
    }

    /// Path the user can `cat` / `jq` / delete.
    var path: String { fileURL.path }

    /// Append a single entry. Fire-and-forget: returns immediately
    /// while the queue handles the file write. Failures are logged
    /// to stderr; we don't surface them to the caller because the
    /// LLM stream that produced the data is already finished and
    /// nothing useful happens in response to a write failure.
    func append(_ entry: UsageEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)  // newline → JSONL
        let url = fileURL
        writeQueue.async {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                let msg = "[parleq] usage-ledger: append failed: \(error)\n"
                FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
            }
        }
    }

    /// Read the whole ledger and bucket the entries. Synchronous;
    /// the file is small (a few KB to maybe a few hundred KB after
    /// many months of heavy use) and we only call this from the
    /// Settings window's reload paths.
    func aggregate() -> UsageAggregate {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [UsageEntry] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(UsageEntry.self, from: lineData) {
                entries.append(entry)
            }
        }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfToday
        // Rolling 7-day window — counts back from now() rather than
        // using cal.startOfWeek to avoid locale-dependent
        // Sunday/Monday week-start surprises. 0.14.0 PR 5 (#220).
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: now) ?? startOfToday

        var today = UsageBucket()
        var thisWeek = UsageBucket()
        var thisMonth = UsageBucket()
        var allTime = UsageBucket()
        // Per-(provider, model) accumulator keyed on a composite ID
        // so the same model name under different providers (in
        // theory; in practice we don't see this) wouldn't collide.
        var modelBuckets: [String: (provider: String, model: String, bucket: UsageBucket)] = [:]
        for e in entries {
            // On-device (local) runs are always free — the model checkpoint
            // string (e.g. "mlx-community/gemma-4-E4B-it-qat-4bit") will never
            // appear in any cloud pricing table, but explicitly short-circuit on
            // provider so "$0.0000" renders without a misleading "unknown pricing"
            // gap if the table ever coincidentally matched a future key.
            let cost: Double = e.provider == "local" ? 0 : (Pricing.cost(
                model: e.model,
                inputTokens: e.inputTokens,
                outputTokens: e.outputTokens
            ) ?? 0)
            if e.ts >= startOfToday { add(e, cost: cost, to: &today) }
            if e.ts >= startOfWeek { add(e, cost: cost, to: &thisWeek) }
            if e.ts >= startOfMonth { add(e, cost: cost, to: &thisMonth) }
            add(e, cost: cost, to: &allTime)

            let key = "\(e.provider):\(e.model)"
            var existing = modelBuckets[key]?.bucket ?? UsageBucket()
            add(e, cost: cost, to: &existing)
            modelBuckets[key] = (provider: e.provider, model: e.model, bucket: existing)
        }

        let byModel = modelBuckets.values
            .map { ModelBreakdown(provider: $0.provider, model: $0.model, bucket: $0.bucket) }
            .sorted { $0.bucket.calls > $1.bucket.calls }

        let recent = Array(entries.suffix(UsageLedger.recentLimit).reversed())
        return UsageAggregate(
            today: today, thisWeek: thisWeek, thisMonth: thisMonth,
            allTime: allTime, byModel: byModel, recent: recent
        )
    }

    /// Delete the ledger file. Used by the Settings window's
    /// "Clear usage history" button. Won't restore disk space
    /// instantly because the file is small to begin with, but
    /// gives the user a clean slate (and stops in-progress runs
    /// from contributing to legacy totals).
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func add(_ e: UsageEntry, cost: Double, to bucket: inout UsageBucket) {
        bucket.calls += 1
        bucket.inputTokens += e.inputTokens
        bucket.outputTokens += e.outputTokens
        bucket.costUSD += cost
    }
}
