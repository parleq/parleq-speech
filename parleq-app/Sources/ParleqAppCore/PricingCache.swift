// PricingCache — keep the LLM-cost table current without code
// changes by overlaying live data from LiteLLM's community-
// maintained pricing JSON on top of our bundled fallback rates.
//
// LiteLLM publishes `model_prices_and_context_window.json` on
// GitHub, keyed by model ID, with `input_cost_per_token` and
// `output_cost_per_token` for hundreds of models across providers
// (Gemini, Bedrock, OpenAI, Anthropic-direct, and many others). We
// fetch it on app launch (background, non-blocking), cache to
// `~/.parleq/pricing-cache.json` for 24 h, and merge it with the
// bundled defaults so:
//   - LiteLLM's price wins when both sources have a model.
//   - The bundled default fills the gap when LiteLLM doesn't know.
//   - If the fetch fails (offline, repo gone, etc.) we keep
//     serving from whatever we have on disk + the bundled
//     defaults; no user-visible breakage.
//
// Lookups try several model-ID variants because LiteLLM keys
// some Bedrock models under "bedrock/<model>" and some Gemini
// models under "gemini/<model>". Our entries use the bare IDs
// the providers themselves return.

import Foundation

enum LiteLLMPricing {
    /// Raw GitHub URL of the JSON file. The "main" branch is what
    /// the LiteLLM team treats as canonical. They publish on every
    /// pricing change; the file's history is a useful audit log.
    public static let url = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Refresh interval. 24 h is the conservative default — LiteLLM
    /// updates land sub-daily during pricing changes, but for
    /// dictation use we don't need fresh-by-the-hour. Cache miss
    /// (cold launch on a plane) falls back to bundled defaults so
    /// a stale cache never blocks a dictation.
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
}

/// Singleton that holds the merged pricing table and refreshes it
/// from LiteLLM in the background. Thread-safe via `NSLock`. Reads
/// are uncontended in practice (writes only happen during refresh),
/// so the lock cost is in the noise.
public final class PricingCache: @unchecked Sendable {
    public static let shared = PricingCache()

    private let cacheURL: URL
    private let lock = NSLock()
    /// Merged table. Initialized to `Pricing.bundledDefaults`; the
    /// disk cache (if present + parseable) is overlaid in `init`,
    /// and the live fetch overlays again on completion.
    private var table: [String: ModelPrice] = [:]
    /// Last successful fetch timestamp, used by the Settings UI to
    /// show "refreshed X hours ago". Read from the cache file's
    /// mtime if present; nil if we've never successfully fetched.
    private var _lastRefresh: Date?
    /// Dedupe in-flight fetches so quick-fire `refreshIfStale()`
    /// calls (e.g. multiple launch paths) don't race.
    private var fetchInFlight = false

    private init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".parleq")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        self.cacheURL = URL(
            fileURLWithPath: (dir as NSString).appendingPathComponent("pricing-cache.json")
        )
        // Start with bundled defaults; overlay disk cache (if any).
        self.table = Pricing.bundledDefaults
        loadCacheFromDisk()
    }

    // MARK: - Public

    /// Cost in USD for a single LLM call, or nil if the model isn't
    /// in our merged table. Falls through three lookup variants so
    /// LiteLLM's "bedrock/anthropic.claude-…" keys match our raw
    /// "us.anthropic.claude-…" model IDs.
    public func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        for candidate in Self.modelKeyVariants(model) {
            if let p = table[candidate] {
                return Double(inputTokens) / 1_000_000.0 * p.inputPerMillionUSD
                    + Double(outputTokens) / 1_000_000.0 * p.outputPerMillionUSD
            }
        }
        return nil
    }

    /// Most recent successful fetch timestamp, or nil if we've
    /// never successfully fetched. Used for the Settings UI's
    /// "refreshed X ago" line.
    public var lastRefresh: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRefresh
    }

    /// Kick off a background refresh if the on-disk cache is stale
    /// or missing. Safe to call from app launch; dispatches the
    /// network fetch off the caller's queue, no-ops if a fetch is
    /// already in flight.
    ///
    /// Set `PARLEQ_DISABLE_LIVE_PRICING=1` in the environment to
    /// suppress the network fetch entirely — bundled defaults
    /// continue to serve, but no third-party data is downloaded.
    /// Useful for locked-down work-machine deployments where any
    /// outbound HTTPS to a non-approved host needs justification.
    public func refreshIfStale() {
        if ProcessInfo.processInfo.environment["PARLEQ_DISABLE_LIVE_PRICING"] == "1" {
            FileHandle.standardError.write(
                "[parleq] pricing: live fetch disabled via PARLEQ_DISABLE_LIVE_PRICING; using bundled defaults\n"
                    .data(using: .utf8) ?? Data()
            )
            return
        }
        // MDM-gateable: a managed profile can pin `livePricingEnabled`
        // to false to suppress this third-party outbound entirely for
        // locked-down / air-gapped fleets (the bundled price table then
        // serves). nil = unmanaged → live pricing on (default).
        if ManagedConfig.managedBool(forKey: "livePricingEnabled") == false {
            FileHandle.standardError.write(
                "[parleq] pricing: live fetch disabled by MDM policy (livePricingEnabled=false); using bundled defaults\n"
                    .data(using: .utf8) ?? Data()
            )
            return
        }
        let needsRefresh: Bool
        lock.lock()
        if fetchInFlight {
            lock.unlock()
            return
        }
        let last = _lastRefresh ?? .distantPast
        let age = Date().timeIntervalSince(last)
        needsRefresh = age >= LiteLLMPricing.cacheLifetime
        if needsRefresh { fetchInFlight = true }
        lock.unlock()
        guard needsRefresh else { return }
        Task.detached { [weak self] in
            await self?.fetchAndCache()
        }
    }

    // MARK: - Internal

    /// Read the on-disk cache (if present + parseable) and overlay
    /// it onto the in-memory table. Bundled defaults stay as the
    /// fallback for models LiteLLM doesn't know about.
    private func loadCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let parsed = try? Self.parseLiteLLM(data: data)
        else { return }
        for (k, v) in parsed { table[k] = v }
        // Use the file's mtime as our "last refresh" signal —
        // matches what the user sees if they `ls -la` the cache.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            _lastRefresh = mtime
        }
    }

    /// Fetch the LiteLLM JSON, write it to disk, and overlay it on
    /// the in-memory table. Failure is non-fatal — we keep serving
    /// from whatever's already there. Lock-protected mutations are
    /// extracted into sync helpers so we never hold the lock across
    /// an `await` (Swift 6 strict-concurrency forbids it).
    private func fetchAndCache() async {
        defer { clearFetchInFlight() }
        do {
            var request = URLRequest(url: LiteLLMPricing.url)
            request.timeoutInterval = 15
            request.setValue("Parleq", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "PricingCache", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "non-2xx HTTP from LiteLLM JSON"]
                )
            }
            let parsed = try Self.parseLiteLLM(data: data)
            try? data.write(to: cacheURL, options: .atomic)
            let count = commitParsedTable(parsed)
            let msg = "[parleq] pricing: refreshed \(count) entries from LiteLLM\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
        } catch {
            let msg = "[parleq] pricing: refresh failed, using existing data: \(error)\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
        }
    }

    /// Sync helper used by `fetchAndCache` so the lock is never
    /// held across an `await`. Returns the entry count that was
    /// merged in (for the refresh log line).
    private func commitParsedTable(_ parsed: [String: ModelPrice]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        for (k, v) in parsed { table[k] = v }
        _lastRefresh = Date()
        return parsed.count
    }

    private func clearFetchInFlight() {
        lock.lock()
        defer { lock.unlock() }
        fetchInFlight = false
    }

    /// Parse LiteLLM's JSON into `[String: ModelPrice]`. The file
    /// has a metadata entry `"sample_spec"` plus per-model entries;
    /// we skip anything missing the cost fields rather than error
    /// out, since LiteLLM tracks many model types (embeddings,
    /// images, etc.) that don't have token-pair pricing.
    private static func parseLiteLLM(data: Data) throws -> [String: ModelPrice] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "PricingCache", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LiteLLM JSON not a top-level object"]
            )
        }
        var out: [String: ModelPrice] = [:]
        for (key, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            // LiteLLM uses tiny per-token doubles
            // (e.g. 0.0000003 for $0.30/MTok). Convert to our
            // per-million units.
            let input: Double? = (entry["input_cost_per_token"] as? Double)
                ?? (entry["input_cost_per_token"] as? NSNumber).map { $0.doubleValue }
            let output: Double? = (entry["output_cost_per_token"] as? Double)
                ?? (entry["output_cost_per_token"] as? NSNumber).map { $0.doubleValue }
            guard let inputPerToken = input, let outputPerToken = output else { continue }
            out[key] = ModelPrice(
                inputPerMillionUSD: inputPerToken * 1_000_000,
                outputPerMillionUSD: outputPerToken * 1_000_000
            )
        }
        return out
    }

    /// Try several model-ID variants when looking up a price.
    /// LiteLLM keys some Bedrock models under "bedrock/…" and some
    /// Gemini models under "gemini/…"; we use the bare provider IDs
    /// internally. Variants are tried in order; the first match
    /// wins.
    private static func modelKeyVariants(_ model: String) -> [String] {
        var variants: [String] = [model]
        if model.hasPrefix("us.") {
            // us.anthropic.claude-… → anthropic.claude-…
            // us.anthropic.claude-… → bedrock/anthropic.claude-…
            let bare = String(model.dropFirst("us.".count))
            variants.append(bare)
            variants.append("bedrock/" + bare)
        } else if model.contains("anthropic.") || model.contains("openai.") || model.contains("amazon.") {
            // anthropic.claude-… → bedrock/anthropic.claude-…
            variants.append("bedrock/" + model)
        } else if model.hasPrefix("gemini-") {
            // gemini-2.5-flash → gemini/gemini-2.5-flash
            variants.append("gemini/" + model)
        }
        return variants
    }
}
