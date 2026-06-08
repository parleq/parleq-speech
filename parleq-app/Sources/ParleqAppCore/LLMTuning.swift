// LLMTuning — config-file knobs for the LLM-request parameters Parleq
// otherwise hardcodes.
//
// These were previously compile-time constants scattered across every
// provider (temperature 0, maxOutputTokens 1024, the per-model
// thinkingBudget split, the TTFT watchdog ladder, the 30/60s request
// timeouts). Power users on slow links, long-form dictators whose
// cleanup output exceeds the old 1024-token ceiling, and folks running
// thinking-heavy models all hit walls they couldn't move without a
// rebuild. The `llm.tuning` config section exposes them.
//
// SCOPE: config-file only. There is intentionally NO Settings UI and NO
// MDM managed key in this pass — these are deliberately advanced,
// rarely-touched knobs. The Settings UI would imply they're routine.
//
// All fields are launch-read: providers consult `LLMTuning.current`,
// which `main.swift` sets ONCE from the loaded config before any
// provider is constructed. Changing `llm.tuning` therefore requires an
// app restart, same as the other launch-read config (provider, model,
// region, hotkey, audio routing). This matches how the codebase already
// treats launch-time config — there is no live re-read seam for these.

import Foundation

/// Tunable LLM-request parameters loaded from the `llm.tuning` config
/// section. Every field is optional-with-default; an absent section (or
/// absent key) yields the built-in behavior Parleq shipped before this
/// knob existed (modulo the `maxOutputTokens` 1024 → 2048 default raise,
/// documented below).
public struct LLMTuning: Sendable, Equatable {
    /// Gemini `thinkingConfig.thinkingBudget`.
    ///
    /// `nil` (the default) keeps the built-in per-model logic: 0 on
    /// Flash / Flash-Lite (chain-of-thought disabled — invariant #3),
    /// a 128-token floor on Pro (which rejects 0 with a 400). When set,
    /// the value is passed VERBATIM to every Gemini `thinkingBudget`
    /// (both the direct-API path and the Vertex Gemini path), clamped to
    /// `0...32768`.
    ///
    /// CAUTION: Gemini 2.5 Pro rejects a budget below 128 with a 400
    /// ("This model only works in thinking mode"). Setting this to a
    /// sub-128 value while using Pro is the user's choice — Parleq does
    /// not second-guess it, since the same field also drives Flash where
    /// 0 is valid and desirable.
    public var thinkingBudget: Int?

    /// Maximum visible-output tokens. Applied wherever a max-tokens
    /// parameter exists per provider: Gemini / Vertex `maxOutputTokens`,
    /// OpenAI / Azure `max_tokens` (standard family), Vertex Anthropic
    /// `max_tokens`, Bedrock inference `maxTokens`.
    ///
    /// Default RAISED from the historical 1024 to 2048. Rationale: at
    /// 1024 the cleanup pass of a long dictation (roughly ~750+ words)
    /// could truncate mid-sentence, silently dropping the tail of the
    /// transcript — a data-loss-shaped failure the user only notices
    /// after the fact. 2048 covers essentially every realistic single
    /// dictation while staying small enough to keep latency and cost
    /// negligible. Clamped to `64...65536`.
    ///
    /// Note on reasoning models (OpenAI / Azure o-series, gpt-5): their
    /// `max_completion_tokens` budget includes a large HIDDEN reasoning
    /// channel and is held at a 4096 FLOOR independent of this knob — a
    /// 2048 cap there would starve reasoning and truncate output to
    /// empty. This knob raises that floor when set above 4096 but never
    /// lowers it.
    public var maxOutputTokens: Int

    /// Sampling temperature. Applied wherever temperature is currently
    /// hardcoded (Gemini / Vertex Gemini, OpenAI / Azure standard
    /// family, Bedrock). Default 0 (deterministic cleanup). Clamped to
    /// `0...2`.
    ///
    /// NOT added to providers that deliberately omit temperature today:
    /// reasoning models (only accept 1.0) and the Vertex Anthropic
    /// native path (no temperature sent). This knob does not introduce a
    /// temperature where none existed.
    public var temperature: Double

    /// Time-to-first-token watchdog deadlines (seconds) for the
    /// fast-retry ladder used on non-thinking models. Each entry is one
    /// attempt's leash; a stall past the last entry falls back to raw
    /// ASR. Default `[5.5, 8.0]`. Each entry clamped to `1...120`;
    /// invalid entries dropped; at most 4 entries kept. An all-invalid /
    /// empty list falls back to the default.
    public var ttftDeadlineSeconds: [Double]

    /// TTFT watchdog deadlines (seconds) for thinking-class models
    /// (Gemini Pro, reasoning families) — one generous leash instead of
    /// the fast retry ladder. Default `[25.0]`. Same clamping rules as
    /// `ttftDeadlineSeconds`.
    public var ttftDeadlineThinkingSeconds: [Double]

    /// HTTP request timeout (seconds) applied to every provider's
    /// `URLRequest.timeoutInterval`. Default 60. Clamped to `5...300`.
    ///
    /// This UNIFIES the previously-inconsistent per-provider timeouts:
    /// the direct Gemini non-streaming path used 30s while every other
    /// path used 60s. They now share this single value. Does NOT apply
    /// to the OIDC auth HTTP client (a separate 30s timeout on the
    /// sign-in / token-exchange path, intentionally left independent of
    /// the cleanup-request timeout).
    public var requestTimeoutSeconds: Double

    public init(
        thinkingBudget: Int? = nil,
        maxOutputTokens: Int = 2048,
        temperature: Double = 0,
        ttftDeadlineSeconds: [Double] = [5.5, 8.0],
        ttftDeadlineThinkingSeconds: [Double] = [25.0],
        requestTimeoutSeconds: Double = 60
    ) {
        self.thinkingBudget = thinkingBudget
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.ttftDeadlineSeconds = ttftDeadlineSeconds
        self.ttftDeadlineThinkingSeconds = ttftDeadlineThinkingSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    // MARK: - Process-global (launch-read)

    /// The active tuning, set ONCE by `main.swift` from the loaded
    /// config before any provider is constructed. Providers and the
    /// AppState TTFT watchdog read this directly.
    ///
    /// `nonisolated(unsafe)` mirrors the codebase's other launch-time
    /// globals (e.g. `Sounds.enabled`): written exactly once at startup
    /// before any concurrent reader exists, then read-only for the
    /// process lifetime. The "restart required" semantics are documented
    /// at the top of this file and surfaced in the schema comment.
    /// Tests may assign and restore it freely (single-threaded test
    /// context — see `withCurrent`).
    public nonisolated(unsafe) static var current = LLMTuning()

    /// Test helper: run `body` with `current` temporarily replaced, then
    /// restore the prior value (even on throw). Keeps tests from leaking
    /// global state into each other.
    public static func withCurrent<R>(_ tuning: LLMTuning, _ body: () throws -> R) rethrows -> R {
        let saved = current
        current = tuning
        defer { current = saved }
        return try body()
    }

    // MARK: - Default-comparison helpers

    /// The set of `llm.tuning` JSON keys whose effective value differs
    /// from the built-in default. Used by `main.swift` for a count-only
    /// (key-name-only) startup log line and by the serializer to decide
    /// whether to emit the section. Numbers here are non-sensitive, but
    /// we log key names rather than values to keep the line terse.
    public var overriddenKeys: [String] {
        let d = LLMTuning()
        var keys: [String] = []
        if thinkingBudget != d.thinkingBudget { keys.append("thinking_budget") }
        if maxOutputTokens != d.maxOutputTokens { keys.append("max_output_tokens") }
        if temperature != d.temperature { keys.append("temperature") }
        if ttftDeadlineSeconds != d.ttftDeadlineSeconds { keys.append("ttft_deadline_seconds") }
        if ttftDeadlineThinkingSeconds != d.ttftDeadlineThinkingSeconds {
            keys.append("ttft_deadline_thinking_seconds")
        }
        if requestTimeoutSeconds != d.requestTimeoutSeconds { keys.append("request_timeout_seconds") }
        return keys
    }

    /// True when every field equals the built-in default — drives
    /// omit-when-default serialization.
    public var isDefault: Bool { overriddenKeys.isEmpty }

    // MARK: - Resolved-value accessors

    /// The Gemini thinking budget to send for `model`, honoring the
    /// override when present and otherwise the built-in 0/128 split.
    /// Returned value is already clamped (the override is clamped at
    /// parse time; the built-ins are in range).
    public func resolvedThinkingBudget(forModel model: String) -> Int {
        if let override = thinkingBudget { return override }
        return model.lowercased().contains("pro") ? 128 : 0
    }
}
