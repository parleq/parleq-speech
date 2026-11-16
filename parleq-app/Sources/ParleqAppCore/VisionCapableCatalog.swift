// VisionCapableCatalog — curated list of vision-capable models the
// Setup Wizard's AdvancedModelStep offers per-provider.
//
// The Settings Models tab uses the per-provider model-options lists
// (geminiModelOptions, bedrockModelOptions, etc.) directly rather
// than calling here, since Settings exposes both cleanup-tier and
// context-tier model options. The catalog stays focused on the
// wizard, where vision-capability filtering is meaningful (the
// AdvancedModel step is specifically about routing reference-aware
// turns to a vision-capable model).

import Foundation

enum VisionCapableCatalog {
    /// Vision-capable models that share auth with `provider`, in the
    /// curated picker order (cheapest/fastest first). Empty for providers
    /// without a vision-capable variant.
    ///
    /// Derived from `ModelCatalog` filtered by
    /// `ModelCapability.supportsVision`, so a catalog refresh (like the
    /// 0.47.1 retired-model sweep) can never leave this list offering a
    /// model the pickers no longer do.
    static func visionModels(forProvider provider: String) -> [ModelIdentifier] {
        let p = provider.lowercased()
        return ModelCatalog.models(forProvider: p)
            .map { ModelIdentifier(provider: p, model: $0) }
            .filter { ModelCapability.supportsVision($0) }
    }
}
