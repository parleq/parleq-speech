import Foundation

/// Process-launch facts captured once at startup, so UI can reason about what
/// the *running* process actually loaded versus what `config.json` now says.
public enum LaunchInfo {
    /// The cleanup provider this process launched with (`config.llmProvider` at
    /// startup, or "local" in eval mode). Set once in `main.swift`; read by the
    /// on-device restart affordance. Empty until set.
    @MainActor public static var cleanupProvider: String = ""

    /// The on-device model checkpoint (`config.selectedLocalModel.checkpoint`)
    /// this process launched with. Set once in `main.swift` alongside
    /// `cleanupProvider`, regardless of whether the launch provider was
    /// "local" — so a later switch TO local can still compare against it.
    /// Empty until set.
    @MainActor public static var localModel: String = ""
}

/// True when on-device cleanup is configured and the model is ready, but the
/// running process launched with a *different* provider — so the app must be
/// restarted to actually start using on-device (the provider is instantiated
/// once at launch and not re-read). Also true when the process already
/// launched with on-device active but the user has since picked a
/// *different on-device model* (`launchModel != configModel`) — the
/// ResidencyManager/LocalLLMProvider checkpoint is baked in at launch too, so
/// a model swap needs the same restart-to-activate affordance.
///
/// Entry-point-agnostic by design: it keys off process state vs. config state,
/// so it is correct whether on-device was enabled from the **Settings** provider
/// picker or the **Setup Wizard** — both end at `config == local` + model ready
/// while the live process still predates that. Gating on `modelReady` also fixes
/// the timing: the call-to-action appears when the model is actually usable, not
/// the instant the provider is changed. Pure; unit-testable.
///
/// `launchModel`/`configModel` default to "" for back-compat with callers that
/// don't track model identity — an empty `launchModel` never trips the
/// model-swap branch (`!launchModel.isEmpty` guard), so omitting them is
/// equivalent to the old provider-only signature.
public func onDeviceActivationPending(
    launchProvider: String, configProvider: String, modelReady: Bool,
    launchModel: String = "", configModel: String = ""
) -> Bool {
    guard configProvider == "local" && modelReady else { return false }
    if launchProvider != "local" { return true }
    return !launchModel.isEmpty && launchModel != configModel
}
