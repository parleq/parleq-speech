// LocalTokenizerBridge — Faithful inline port of the mlx-swift-lm tokenizer-adaptor
// macro expansions.
//
// Source macros:
//   - `#huggingFaceTokenizerLoader()` → expands to `TransformersTokenizerLoader`
//   - `#adaptHuggingFaceTokenizer`    → expands to `TransformersTokenizerBridge`
//   Both are defined in `HuggingFaceIntegrationMacros.swift` inside mlx-swift-lm.
//
// Why a port instead of the macro?
//   Using the macros requires importing the `MLXHuggingFace` macro module, which
//   drags in the full macro plugin build machinery at compile time. Inlining the
//   ~30-line expansion keeps the dependency surface minimal while remaining a
//   faithful, reviewable translation of exactly what the macros produce.
//
// Used by:
//   - `ResidencyManager.loadContainer()` — passes `TransformersTokenizerLoader`
//     directly to `LLMModelFactory.shared.loadContainer(from:using:)`.
//   - `LocalLLMProvider` (from the on-device provider task onward) — will consume
//     `TransformersTokenizerLoader` / `TransformersTokenizerBridge` directly when
//     it needs a tokenizer outside of `ResidencyManager`.

import Foundation
import MLXLMCommon
import Tokenizers

// MARK: - TransformersTokenizerLoader

/// Concrete `TokenizerLoader` backed by `swift-transformers`.
///
/// Mirrors what `#huggingFaceTokenizerLoader()` expands to, inlined here so
/// we don't need the `MLXHuggingFace` macro import site.
struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

// MARK: - TransformersTokenizerBridge

/// Bridges `Tokenizers.Tokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`.
/// Ported from the `#adaptHuggingFaceTokenizer` macro expansion.
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses decode(tokens:) while MLXLMCommon uses decode(tokenIds:).
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }

    // MARK: - KV prefix-cache support (Task 9)
    //
    // The standard `applyChatTemplate(messages:tools:additionalContext:)` above
    // always renders with `add_generation_prompt: true` (it forwards to the
    // swift-transformers convenience overload, whose default is true). For the
    // KV prefix cache we need to render the SYSTEM block ALONE *without* the
    // trailing generation prompt, so the resulting tokens are an exact leading
    // prefix of the full system+user render. This method exposes the
    // full-control swift-transformers overload with `addGenerationPrompt:`
    // pinned to a caller-supplied value.
    //
    // See `ResidencyManager`'s prefix-cache logic for how the system-only
    // render (addGenerationPrompt: false) is verified to be a token-exact
    // prefix of the full render before any cached KV state is reused.
    func renderTemplate(
        messages: [[String: any Sendable]],
        addGenerationPrompt: Bool,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: nil,
                addGenerationPrompt: addGenerationPrompt,
                truncation: false,
                maxLength: nil,
                tools: nil,
                additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
