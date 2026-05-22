// OpenAIReasoningModels — shared helper used by both OpenAIProvider
// (api.openai.com) and AzureOpenAIProvider (Azure OpenAI Service)
// since both speak the Chat Completions wire format and both need
// to detect o-series models at request time.
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
    // Enumerate all known o-series prefixes. Each entry is checked
    // as an exact match ("o1") AND as a versioned-snapshot prefix
    // ("o1-2024-12-17"). Add new o-series families here when released.
    // Prefixes ordered longest-first as a readability convention, but
    // ordering doesn't affect the result: the function returns Bool, so
    // any matching prefix produces `true` regardless of which one hits
    // first. The mini vs non-mini distinction (for vision capability)
    // is resolved at call sites (e.g. AzureOpenAIProvider.supportsVision)
    // not here. The prefix-aware match catches dated snapshot IDs such
    // as "o1-2024-12-17" and "o4-mini-2025-04-16" that users enter
    // via the Custom… route.
    let prefixes = ["o1-mini", "o3-mini", "o4-mini", "o1", "o3"]
    for prefix in prefixes {
        if m == prefix || m.hasPrefix(prefix + "-") {
            return true
        }
    }
    return false
}
