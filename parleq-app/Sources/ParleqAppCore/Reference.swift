// Reference — captured context attached to a dictation turn.
//
// Immutable snapshot semantics: once captured, the underlying source
// (a window in Phase 1; files / clipboard in Phase 2) can change
// freely without affecting the reference. "What the user clicked"
// is what gets sent to the LLM, even if seconds pass.
//
// References live in RAM only. They are never persisted to disk and
// are released as soon as their containing dictation session completes
// (accept), is discarded (cancel), or a fresh dictation starts.
//
// CaptureMode is per-reference: `.text` ships OCR text (Phase 1
// default and only option), `.image` ships PNG-encoded image data
// (Phase 2).

import AppKit

// Note: Reference deliberately does not conform to Equatable. It holds
// NSImage (which isn't Equatable) and its primary use site is SwiftUI
// list diffing, which already keys on Identifiable.id. If a comparison
// is needed, compare .id explicitly.
public struct Reference: Identifiable {
    public let id: UUID
    public let source: Source
    public let label: String          // window title; displayed in chip
    public let appIcon: NSImage?      // chip icon; nil if not retrievable
    public let thumbnail: NSImage?    // 64×40 rendering of captured image
    public let captureDate: Date
    public var captureMode: CaptureMode
    public let textContent: String?   // OCR text when mode == .text
    public let imageData: Data?       // PNG-encoded image when mode == .image; Phase 2

    public init(
        id: UUID,
        source: Source,
        label: String,
        appIcon: NSImage?,
        thumbnail: NSImage?,
        captureDate: Date,
        captureMode: CaptureMode,
        textContent: String?,
        imageData: Data?
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.appIcon = appIcon
        self.thumbnail = thumbnail
        self.captureDate = captureDate
        self.captureMode = captureMode
        self.textContent = textContent
        self.imageData = imageData
    }

    public enum Source: Equatable {
        case window(bundleID: String, title: String)
        case file(url: URL)
        case clipboard(label: String)
    }

    public enum CaptureMode: Equatable {
        case text
        case image  // Phase 2 only — listed here for forward compatibility
    }
}

#if DEBUG
private func iconForBundle(_ bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
}

extension Reference {
    /// Sample reference for SwiftUI previews and visual smoke checks.
    @MainActor static let sampleWindow = Reference(
        id: UUID(),
        source: .window(bundleID: "com.apple.mail", title: "Re: launch timeline"),
        label: "Re: launch timeline",
        appIcon: iconForBundle("com.apple.mail"),
        thumbnail: nil,
        captureDate: Date(),
        captureMode: .text,
        textContent: """
        Hi team — thanks for the update. I wanted to confirm we can do
        Tuesday at 2pm. Let me know if you'd like me to bring the
        proposal deck. Best, Sam
        """,
        imageData: nil
    )

    @MainActor static let sampleSpec = Reference(
        id: UUID(),
        source: .window(bundleID: "com.apple.Safari", title: "Dashboard Spec"),
        label: "Dashboard Spec",
        appIcon: iconForBundle("com.apple.Safari"),
        thumbnail: nil,
        captureDate: Date(),
        captureMode: .text,
        textContent: "The dashboard layout uses a 3-column grid...",
        imageData: nil
    )
}
#endif
