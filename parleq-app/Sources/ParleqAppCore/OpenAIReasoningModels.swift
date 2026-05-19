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
/// The check is exact-match against the canonical lowercase IDs for
/// the five currently-released o-series models. New o-series releases
/// should be added here and to the model option lists in SettingsWindow.
internal func isOpenAIReasoningModel(_ model: String) -> Bool {
    let m = model.lowercased()
    return m == "o1" || m == "o1-mini"
        || m == "o3" || m == "o3-mini"
        || m == "o4-mini"
}
