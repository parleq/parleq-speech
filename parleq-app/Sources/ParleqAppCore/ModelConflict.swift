// ModelConflict — describes mismatches between the selected model
// and the attached references' capture modes. Pure-data; the view
// layer (ModelBadge red-dot + Accept-row warning) reads this to
// decide what to surface.
//
// ModelCapability — static per-model capability table for view-layer
// use where no LLMProvider instance is available (e.g. the picker
// shows model IDs, not provider objects). Mirrors the per-concrete-
// class supportsVision implementations; kept small and local so the
// view layer doesn't import provider types just to render a 👁 icon.

import Foundation

enum ModelConflict: Equatable, Sendable {
    /// Vision-mode references are attached, but the picked model
    /// can't accept images. References will be sent as text
    /// (image content lost) unless the user explicitly downgrades
    /// or switches model.
    case visionRefsButNonVisionModel(refCount: Int)

    /// Derive the conflict (if any) from current state. nil
    /// means no conflict; safe to submit.
    ///
    /// `modelSupportsVision` should come from
    /// `LLMProvider.supportsVision` on the currently-selected
    /// provider (post-override resolution). `references` is the
    /// OverlayModel's references array.
    static func from(
        modelSupportsVision: Bool,
        references: [Reference]
    ) -> ModelConflict? {
        if modelSupportsVision { return nil }
        let visionCount = references.filter { $0.captureMode == .image }.count
        if visionCount == 0 { return nil }
        return .visionRefsButNonVisionModel(refCount: visionCount)
    }
}

/// Static per-model vision capability table for view-layer use
/// (ModelBadge, ModelPicker). Mirrors the `supportsVision` logic
/// in each concrete LLMProvider without requiring a live provider
/// instance. The duplication is intentional and bounded: one switch
/// per provider family, updated whenever a new model is added.
enum ModelCapability {
    /// True for models that THINK before their first token — Gemini Pro
    /// (cannot disable thinking; routinely 10-20s TTFT) and the
    /// OpenAI/Azure reasoning families. The TTFT watchdog (task #41
    /// follow-up) gives these a single generous deadline instead of the
    /// fast-model retry ladder: retrying a thinking model throws away a
    /// half-finished think, and the raw-first display means a long
    /// deadline costs the user nothing (the raw text is acceptable the
    /// whole time). Conservative default: false (fast deadlines).
    static func expectsExtendedTTFT(provider: String, model: String) -> Bool {
        let m = model.lowercased()
        switch provider.lowercased() {
        case "gemini", "vertex":
            // Gemini 2.5 Pro thinks mandatorily; Gemini 4 Argon showed
            // 2.4-4.6s TTFT with outliers to ~19s even at thinkingLevel
            // low (2026-11). Flash / Flash-Lite run with thinking off or
            // minimal (invariant #3) — fast.
            return m.contains("pro") || m.contains("argon")
        case "openai", "azure":
            // Reasoning models (o-series, gpt-5, gpt-6) can deliberate
            // before the first token — EXCEPT on OpenAI direct when sent
            // reasoning_effort "none" (e.g. gpt-6-luna), which streams as
            // promptly as a standard model. Azure always sends "low".
            guard isOpenAIReasoningModel(m) else { return false }
            if provider.lowercased() == "openai" {
                return openAIReasoningEffort(forModel: m) != "none"
            }
            return true
        case "bedrock":
            // (BedrockBearerProvider also reports providerName "bedrock".)
            // GPT-OSS runs with reasoning_effort=low (invariant #4);
            // Claude models stream promptly without extended thinking.
            return false
        default:
            return false
        }
    }

    /// Returns true iff the given `ModelIdentifier` corresponds to a
    /// model that can accept image inputs. Conservative default: false.
    static func supportsVision(_ id: ModelIdentifier) -> Bool {
        let m = id.model.lowercased()
        switch id.provider.lowercased() {
        case "gemini":
            return ModelCatalog.geminiSupportsVision(m)
        case "vertex":
            // Vertex hosts Gemini directly; Anthropic Claude routes
            // through publishers/anthropic but only in specific
            // regions, so Claude entries are not in the curated
            // Vertex dropdown (see issue #34). The capability table
            // still recognizes Claude IDs via contains("claude") so
            // a user typing one via Custom… gets correct vision
            // detection. Gemini 1.5 family was retired from Vertex
            // in 2025 — gone from the capability table.
            if m.contains("claude") { return true }
            return ModelCatalog.geminiSupportsVision(m)
        case "bedrock", "bedrock-bearer":
            // All Claude models on Bedrock support vision.
            // Amazon Nova Pro + Nova Lite are multimodal; Nova Micro
            // is text-only on the Converse path Parleq uses.
            // Meta Llama and Mistral are text-only on Bedrock Converse.
            // GPT-OSS-120B (gpt-oss-120b-1:0) is text-only.
            if m.contains("claude") { return true }
            if m.contains("nova-pro") || m.contains("nova-lite") { return true }
            // Nova Micro, Llama, Mistral, GPT-OSS — text-only on our path.
            return false
        case "azure", "openai":
            return openAIModelSupportsVision(m)
        default:
            return false  // conservative; explicit allowlist only
        }
    }
}
