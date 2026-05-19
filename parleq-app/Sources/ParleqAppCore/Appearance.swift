// Appearance — central knob for the Liquid Glass styling rollout.
//
// macOS 26 (Tahoe) introduced Liquid Glass as the system-wide visual
// language. Parleq targets macOS 14, so the new styling is opt-in via
// `#available(macOS 26, *)`. Below that we fall back to
// `.regularMaterial`-based backgrounds, which already look "glass-ish"
// (translucent + blurred) on macOS 14+ without requiring the new
// surface.
//
// Runtime override: set the env var `PARLEQ_LIQUID_GLASS=0` to force
// the legacy / fallback look even on macOS 26+, which is how we test
// the fallback path without changing the binary or downgrading the
// OS. `PARLEQ_LIQUID_GLASS=1` forces it on (default on macOS 26+,
// no-op below).

import SwiftUI

@MainActor
enum AppearancePreferences {
    /// True when the Liquid Glass styling should be used. Default is
    /// "on" on macOS 26 or later, "off" before. Overridable via env
    /// for testing both paths.
    static let liquidGlassEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["PARLEQ_LIQUID_GLASS"] {
        case "0", "false", "no", "off":
            return false
        case "1", "true", "yes", "on":
            return true
        default:
            break
        }
        if #available(macOS 26, *) {
            return true
        }
        return false
    }()
}

extension View {
    /// Apply Parleq's "panel" background — the surface used for the
    /// overlay, the picker, the chip cards. Routes between Liquid
    /// Glass (when available + enabled) and a translucent-material
    /// fallback that looks reasonable on macOS 14–25.
    @ViewBuilder
    func parleqPanelBackground(cornerRadius: CGFloat = 12, strokeOpacity: CGFloat = 0.2) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if AppearancePreferences.liquidGlassEnabled {
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                // `.glassEffect(in: shape)` applies Liquid Glass as
                // this view's *appearance*: a refracting, edge-
                // specular, depth-tinted surface clipped to `shape`.
                // Content (chips / transcript / buttons) renders ON
                // the glass automatically. No need for a separate
                // background or stroke — Liquid Glass paints its own
                // edge treatment.
                self.glassEffect(in: shape)
            } else {
                self.legacyPanelBackground(shape: shape, strokeOpacity: strokeOpacity)
            }
            #else
            self.legacyPanelBackground(shape: shape, strokeOpacity: strokeOpacity)
            #endif
        } else {
            self.legacyPanelBackground(shape: shape, strokeOpacity: strokeOpacity)
        }
    }

    /// Translucent-material fallback. Used pre-macOS-26 OR when
    /// liquid-glass is explicitly disabled.
    fileprivate func legacyPanelBackground(
        shape: some Shape,
        strokeOpacity: CGFloat
    ) -> some View {
        self
            .background(shape.fill(.regularMaterial))
            .overlay(shape.stroke(Color.secondary.opacity(strokeOpacity), lineWidth: 1))
    }
}
