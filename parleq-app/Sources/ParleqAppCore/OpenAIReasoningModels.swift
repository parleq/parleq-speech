// OpenAIReasoningModels — shared helper used by both OpenAIProvider
// (api.openai.com) and AzureOpenAIProvider (Azure OpenAI Service)
// since both speak the Chat Completions wire format and both need
// to detect reasoning models (o-series, gpt-5, gpt-6) at request time.
//
// Reasoning models differ from standard Chat Completions models in
// two ways that affect the request body:
//   - `max_completion_tokens` instead of `max_tokens`
//     (reasoning models also draw from an internal reasoning token
//     budget that is separate from the visible output budget; the
//     old `max_tokens` key was renamed to make that split explicit).
//   - `temperature` must be omitted entirely
//     (only the implicit default of 1.0 is accepted; passing any
//     other value, including 0, returns HTTP 400).
//
// System messages and SSE streaming are accepted unchanged.
//
// Note for AzureOpenAIProvider: Azure routes by deployment name, not
// model name, so the family is declared explicitly in Settings
// (AzureOpenAIProvider.Family.reasoning) and this helper is NOT used
// on that path. It is used only by OpenAIProvider, where the model
// string is the wire routing key and can be detected reliably.
// The helper lives here rather than inside OpenAIProvider so it
// can be called from tests without opening up private access.

import Foundation

/// Returns true iff `model` is an OpenAI reasoning (o-series) model
/// that requires the alternate Chat Completions parameter shape:
/// `max_completion_tokens` instead of `max_tokens`, and no
/// `temperature` key in the request body.
///
/// Detection is prefix-aware rather than exact-match so dated
/// snapshot IDs entered via the Custom… route (e.g. "o1-2024-12-17",
/// "o4-mini-2025-04-16") route through the reasoning parameter shape
/// instead of falling through to the standard shape and causing a 400.
/// Pattern: exact match OR `prefix-` pattern (e.g. "o1" matches
/// "o1" and "o1-2024-12-17"; "o4-mini" matches "o4-mini" and
/// "o4-mini-2025-04-16").
public func isOpenAIReasoningModel(_ model: String) -> Bool {
    let m = model.lowercased()
    // o-series: each entry is checked as an exact match ("o1") AND as a
    // versioned-snapshot prefix ("o1-2024-12-17", "o4-mini-2025-04-16")
    // so dated IDs entered via Custom… route through the reasoning shape.
    let prefixes = ["o1-mini", "o3-mini", "o4-mini", "o1", "o3"]
    for prefix in prefixes {
        if m == prefix || m.hasPrefix(prefix + "-") {
            return true
        }
    }
    // gpt-5 / gpt-6 families (gpt-5-mini, gpt-5.6-luna, gpt-6-luna,
    // gpt-6.1-sol, …) are all reasoning models: verified 2026-11 that
    // every one rejects `max_tokens` with a 400. The `-chat` variants
    // (gpt-5-chat-latest) are the non-reasoning exception.
    if (m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6")) && !m.contains("-chat") {
        return true
    }
    return false
}

/// The `reasoning_effort` to send for an OpenAI reasoning model on
/// api.openai.com. "none" (no hidden reasoning at all) for the models
/// verified to accept it (2026-11: gpt-6-luna TTFT 0.6-0.8s at "none"
/// vs 1.3s and 20-46 reasoning tokens at "low"); "low" for everything
/// else (gpt-6.1-sol rejects "none"; o-series predate it).
///
/// Azure keeps "low" unconditionally: its API-version gating of the
/// "none" value is unverified, and "low" is accepted everywhere.
public func openAIReasoningEffort(forModel model: String) -> String {
    let m = model.lowercased()
    let acceptsNone = ["gpt-6-luna", "gpt-6.1-terra", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]
    for id in acceptsNone where m == id || m.hasPrefix(id + "-") {
        return "none"
    }
    return "low"
}

/// Image-input capability for OpenAI-family model IDs (OpenAI direct and
/// Azure labels). Explicit allowlist; unknown IDs are text-only.
public func openAIModelSupportsVision(_ model: String) -> Bool {
    let m = model.lowercased()
    // gpt-4o family (and dated snapshots); audio/realtime previews
    // share the prefix but don't accept images via Chat Completions.
    let isGPT4o = (m == "gpt-4o" || m.hasPrefix("gpt-4o-"))
    let isNonVisionPreview = m.contains("audio-preview") || m.contains("realtime-preview")
    if isGPT4o && !isNonVisionPreview { return true }
    // gpt-4.1 family except nano (text-only).
    let isGPT41 = (m == "gpt-4.1" || m.hasPrefix("gpt-4.1-"))
    let isGPT41Nano = (m == "gpt-4.1-nano" || m.hasPrefix("gpt-4.1-nano-"))
    if isGPT41 && !isGPT41Nano { return true }
    if m == "gpt-4-turbo" { return true }
    // gpt-5 / gpt-6 families are multimodal.
    if m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") { return true }
    // o-series: o1, o3, o4-mini see images; o1-mini and o3-mini don't.
    if isOpenAIReasoningModel(m) {
        if m == "o1-mini" || m.hasPrefix("o1-mini-") { return false }
        if m == "o3-mini" || m.hasPrefix("o3-mini-") { return false }
        return true
    }
    return false
}
