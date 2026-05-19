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
    /// Returns true iff the given `ModelIdentifier` corresponds to a
    /// model that can accept image inputs. Conservative default: false.
    static func supportsVision(_ id: ModelIdentifier) -> Bool {
        let m = id.model.lowercased()
        switch id.provider.lowercased() {
        case "gemini":
            // Gemini 2.5 Flash + Pro are multimodal; Flash-Lite is
            // text-only. Gemini 1.5 family was retired from the
            // direct v1beta endpoint in 2025 and is gone from the
            // capability table — any 1.5 request 404s.
            switch m {
            case "gemini-2.5-flash", "gemini-2.5-pro":
                return true
            case "gemini-2.5-flash-lite":
                return false
            default:
                return false
            }
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
            switch m {
            case "gemini-2.5-flash", "gemini-2.5-pro":
                return true
            case "gemini-2.5-flash-lite":
                return false
            default:
                return false
            }
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
        case "azure":
            // gpt-4o family (gpt-4o, gpt-4o-mini) supports vision.
            // gpt-4.1 and gpt-4.1-mini support vision; gpt-4.1-nano
            // is text-only (smallest, cheapest, no multimodal path).
            // gpt-4-turbo supports vision.
            if m.contains("gpt-4o") { return true }
            if m == "gpt-4.1" || m == "gpt-4.1-mini" { return true }
            if m == "gpt-4-turbo" { return true }
            return false
        default:
            return false  // conservative; explicit allowlist only
        }
    }
}
