// ReferenceCapture — captures a window's content via ScreenCaptureKit
// and extracts text via Vision.framework OCR.
//
// All heavy work (SCK capture, OCR) runs off the main actor; only the
// thumbnail rendering (NSImage lockFocus) and app-metadata resolution
// (NSWorkspace) hop back to MainActor. The class itself is non-isolated
// so callers from any actor can `await captureWindow(...)` without
// pinning the main thread for the duration.
//
// Identification: capture takes a `CGWindowID`, which is stable for
// the lifetime of a window. The picker (WindowPicker.swift) hands
// the ID through directly — no PID+title disambiguation needed.
//
// Permission: requires Screen Recording (TCC). A preflight check at
// the top of `captureWindow` throws `.permissionDenied` if not
// currently granted; ScreenCaptureKit errors that indicate permission
// problems (userDeclined, missingEntitlements) are also remapped.
// Other capture failures surface as `.captureFailed(detail)`.

import AppKit
import CoreGraphics
import CoreVideo
import PDFKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

enum CaptureError: Error, LocalizedError, CustomStringConvertible {
    case permissionDenied
    case windowNotFound
    case captureFailed(String)
    case ocrFailed(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission denied."
        case .windowNotFound:
            return "Window not found (may have been closed)."
        case .captureFailed(let detail):
            return "Capture failed: \(detail)"
        case .ocrFailed(let detail):
            return "OCR failed: \(detail)"
        }
    }

    var errorDescription: String? { description }
}

protocol ReferenceCapturer: Sendable {
    /// Capture the on-screen window with the given CGWindowID.
    /// `displayTitle` is what the picker showed the user at selection
    /// time — used as the Reference's label so chip rendering and the
    /// LLM prompt stay aligned with what the user actually clicked,
    /// even if SCK reports a slightly different / nil title later.
    func captureWindow(windowID: CGWindowID, displayTitle: String) async throws -> Reference
}

final class ScreenCaptureKitReferenceCapture: ReferenceCapturer, @unchecked Sendable {
    func captureWindow(windowID: CGWindowID, displayTitle: String) async throws -> Reference {
        // Preflight TCC. If denied, surface a specific error so the UI
        // can prompt rather than showing a generic capture failure.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        // Resolve the SCWindow by ID. onScreenWindowsOnly:false matches
        // the picker's enumeration — without this, a window from a
        // suspended macOS Space shows up in the picker but can't be
        // resolved here, surfacing as a confusing 'window not found'
        // error after the user has already clicked it.
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let scWindow = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        // Resolve the scale factor from the screen that actually contains
        // this window — NSScreen.main only follows keyboard focus, which
        // is wrong on mixed-DPI setups (Retina laptop + non-Retina external).
        let scaleFactor = await scaleFactor(for: scWindow.frame)

        // Cap capture dimensions. 1600 wide is plenty for OCR (which
        // downscales to 2000 anyway) and avoids whatever per-stream
        // resource limit SCK hits at higher sizes on some windows.
        let maxCaptureDimension: CGFloat = 1600
        let baseWidth = scWindow.frame.width * scaleFactor
        let baseHeight = scWindow.frame.height * scaleFactor
        let longest = max(baseWidth, baseHeight, 1)
        let clamp = min(1, maxCaptureDimension / longest)
        let captureWidth = max(Int((baseWidth * clamp).rounded()), 64)
        let captureHeight = max(Int((baseHeight * clamp).rounded()), 64)

        // Explicit pixel format + color space + queue depth. Default
        // values vary across macOS versions and some windows reject
        // captures unless these are pinned. Pin to a known-good combo
        // (BGRA + sRGB + queueDepth 3 is the SCK-sample-app default
        // and works reliably across apps with unusual rendering paths
        // — iOS Simulator's Metal backing, Zen's Firefox compositor,
        // etc.).
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 3

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let bundleID = scWindow.owningApplication?.bundleIdentifier ?? "unknown"

        let cgImage: CGImage
        do {
            cgImage = try await Self.captureWithRetry(
                filter: filter,
                config: config,
                scWindow: scWindow,
                bundleID: bundleID,
                captureSize: CGSize(width: captureWidth, height: captureHeight),
                scaleFactor: scaleFactor
            )
        } catch {
            if Self.isPermissionError(error) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.captureFailed(String(describing: error))
        }

        // App metadata + icon — main-actor lookup (NSWorkspace is main-only).
        // displayTitle (from the picker) is authoritative for the label;
        // SCK's scWindow.title is unreliable (sometimes nil for utility
        // windows) and the user picked the window based on what the
        // picker showed them.
        let metadata = await mainActorMetadata(for: scWindow)

        // OCR off the main actor.
        let ocrText = try await Self.runOCR(cgImage)

        // Thumbnail uses NSImage.lockFocus, which is main-actor-only.
        let thumbnail = await Self.makeThumbnail(cgImage, maxSize: NSSize(width: 64, height: 40))

        // Serialize the captured frame to PNG once at capture time so a
        // later text→image chip toggle (Phase 2) has data without
        // re-running the capture pipeline. Memory cost is bounded by
        // the chip strip's natural overflow + RAM-only retention until
        // Accept/Cancel.
        let pngData: Data? = {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        }()

        return Reference(
            id: UUID(),
            source: .window(bundleID: metadata.bundleID, title: displayTitle),
            label: displayTitle,
            appIcon: metadata.appIcon,
            thumbnail: thumbnail,
            captureDate: Date(),
            captureMode: .text,
            textContent: ocrText,
            imageData: pngData
        )
    }

    // MARK: - Main-actor helpers

    @MainActor
    private func scaleFactor(for windowFrame: CGRect) -> CGFloat {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) })
            ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2.0
    }

    @MainActor
    private func mainActorMetadata(for scWindow: SCWindow) -> (bundleID: String, appIcon: NSImage?) {
        let bundleID = scWindow.owningApplication?.bundleIdentifier ?? "unknown"
        var appIcon: NSImage? = nil
        if let app = scWindow.owningApplication,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return (bundleID, appIcon)
    }

    @MainActor
    private static func makeThumbnail(_ image: CGImage, maxSize: NSSize) -> NSImage {
        let imageSize = NSSize(width: image.width, height: image.height)
        let ratio = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        let targetSize = NSSize(
            width: imageSize.width * ratio,
            height: imageSize.height * ratio
        )
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: imageSize).draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()
        return thumbnail
    }

    // MARK: - Background work (off main actor)

    /// SCK capture with a "nudge then retry" fallback. The first attempt
    /// hits SCScreenshotManager directly. If SCK refuses with -3811
    /// "Failed to start stream due to audio/video capture failure",
    /// the source app is almost certainly on a suspended macOS Space
    /// (compositor paused, no live frames available). In that case we
    /// activate the source app briefly via NSRunningApplication, wait
    /// a moment for the WindowServer to bring its window back into the
    /// render tree, and retry the capture.
    ///
    /// The activation IS visible to the user (the source app's Space
    /// comes forward), but the alternative is a confusing error after
    /// they already clicked the window. This matches what Zoom / Loom
    /// / similar tools do.
    private static func captureWithRetry(
        filter: SCContentFilter,
        config: SCStreamConfiguration,
        scWindow: SCWindow,
        bundleID: String,
        captureSize: CGSize,
        scaleFactor: CGFloat
    ) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch let error as NSError {
            let isStartStreamFailure =
                error.domain == SCStreamErrorDomain &&
                error.code == -3811   // failedToStartStream (suspended Space, paused compositor)
            guard isStartStreamFailure else {
                Self.logStderr(
                    "[parleq] reference-capture SCK capture failed: \(error) " +
                    "(window=\(Int(scWindow.frame.width))×\(Int(scWindow.frame.height)) " +
                    "scale=\(scaleFactor) capture=\(Int(captureSize.width))×\(Int(captureSize.height)) " +
                    "bundle=\(bundleID))"
                )
                throw error
            }

            // Nudge the app forward so WindowServer composes its
            // window again, then retry. Stay on the main actor for
            // NSRunningApplication.activate.
            //
            // Save the current frontmost BEFORE activating the source
            // app so we can restore focus once the capture is done.
            // For regular multi-window Spaces, activate() on the
            // prior frontmost cleanly switches focus back. For
            // full-screen Spaces (each full-screen app on its own
            // dedicated Space), macOS's WindowServer treats them
            // specially — plain activate() does not switch the
            // visible Space back. See task #212 for what was tried
            // (CGEvent Cmd+Tab synthesis posted at HID level, dated
            // 2026-05-23 — does not work; macOS filters synthesized
            // Cmd+Tab to prevent apps from spoofing the App Switcher
            // and bypassing the full-screen-Space guardrail). The
            // restore here covers the common case; the full-screen
            // case is documented as a known limitation that needs
            // either private CGS APIs (yabai-style, fragile) or a
            // UX-level workaround (refuse-with-error / explanatory
            // chip).
            Self.logStderr(
                "[parleq] reference-capture got -3811 for \(bundleID); activating + retrying"
            )
            let pid = scWindow.owningApplication?.processID ?? 0
            let priorFrontmost = await MainActor.run { () -> NSRunningApplication? in
                NSWorkspace.shared.frontmostApplication
            }
            await MainActor.run {
                if pid != 0, let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [])
                }
            }
            // Wait for the WindowServer to register the activated window.
            // ~200ms is empirically enough; we won't tighten this until
            // the basic flow is proven.
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Restore focus on every exit path from the retry. If the
            // prior-frontmost app has quit since we snapshotted, the
            // activate() call is a best-effort no-op rather than an
            // error. Same priorFrontmost is reused in both success
            // and failure branches below.
            func restorePriorFrontmost() async {
                guard let prior = priorFrontmost else { return }
                await MainActor.run {
                    prior.activate(options: [])
                }
            }

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                await restorePriorFrontmost()
                return image
            } catch let retryError as NSError {
                Self.logStderr(
                    "[parleq] reference-capture SCK capture failed AFTER activation retry: \(retryError) " +
                    "(window=\(Int(scWindow.frame.width))×\(Int(scWindow.frame.height)) " +
                    "scale=\(scaleFactor) capture=\(Int(captureSize.width))×\(Int(captureSize.height)) " +
                    "bundle=\(bundleID))"
                )
                // Restore focus even on failure — leaving the user
                // stranded on the activated source app after an error
                // is worse than the error itself.
                await restorePriorFrontmost()
                throw retryError
            }
        }
    }

    /// Vision OCR. Dispatched onto a userInitiated background queue
    /// because `VNImageRequestHandler.perform` is synchronous and a
    /// .accurate full-window recognition runs hundreds of ms to seconds.
    ///
    /// Performance + reliability: large captures (e.g. Xcode full-screen
    /// on a Retina display can hit ~5K × 3K pixels) push Vision into
    /// memory territory where it sometimes fails or returns no
    /// observations. We downscale to a maximum of 2000 px wide before
    /// running OCR — accuracy doesn't materially suffer at that
    /// resolution and the runtime drops dramatically.
    private static func runOCR(_ image: CGImage) async throws -> String {
        let downscaled = downscaleForOCR(image, maxDimension: 2000) ?? image
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error = error {
                        let detail = (error as NSError).localizedDescription
                        Self.logStderr("[parleq] reference-capture OCR callback error: \(detail)")
                        continuation.resume(throwing: CaptureError.ocrFailed(detail))
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: downscaled, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    let detail = (error as NSError).localizedDescription
                    Self.logStderr("[parleq] reference-capture OCR perform error: \(detail) (image=\(downscaled.width)×\(downscaled.height))")
                    continuation.resume(throwing: CaptureError.ocrFailed(detail))
                }
            }
        }
    }

    /// Downscale a CGImage so its longest dimension is at most
    /// `maxDimension`, preserving aspect. Returns nil on failure (the
    /// caller falls back to the original).
    private static func downscaleForOCR(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let srcW = image.width
        let srcH = image.height
        let longest = max(srcW, srcH)
        if longest <= maxDimension { return image }
        let scale = Double(maxDimension) / Double(longest)
        let dstW = Int((Double(srcW) * scale).rounded())
        let dstH = Int((Double(srcH) * scale).rounded())

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return context.makeImage()
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    }

    /// SCStreamErrorDomain codes that indicate the user (or system)
    /// declined screen recording. Mapped to `.permissionDenied` so
    /// the UI can prompt rather than show a raw error string. The
    /// preflight CGPreflightScreenCaptureAccess() covers the
    /// "permission missing at call time" case; this only catches the
    /// rare race where TCC flips during the SCK call itself.
    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain else { return false }
        return ns.code == SCStreamError.Code.userDeclined.rawValue
            || ns.code == SCStreamError.Code.missingEntitlements.rawValue
    }
}

// MARK: - File + clipboard factory helpers

extension ScreenCaptureKitReferenceCapture {
    /// Wrap a file URL as a Reference. Reads the file synchronously
    /// into memory. captureMode is auto-detected from UTI:
    /// - image/* types → .image with the raw file bytes
    /// - PDF → .text via PDFKit text extraction
    /// - recognized text formats → .text (UTF-8)
    /// Throws on unreadable files or unsupported/disallowed types.
    ///
    /// The text-fallback path requires EITHER a specific safe UTType
    /// (html, json, xml, yaml, delimitedText, sourceCode, shellScript,
    /// propertyList) OR an explicit file extension from the curated
    /// allowlist. The broad `.text` / `.plainText` supertype is NOT
    /// accepted here because macOS assigns it to anything UTF-8
    /// readable — including ~/.ssh/id_rsa, ~/.aws/credentials, and
    /// other sensitive dotfiles. Extension-gating is the realistic
    /// safety net; UTType conformance is the secondary check for
    /// well-typed source files that carry the right UTI.
    public static func reference(forFileAt url: URL) throws -> Reference {
        let utType = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let label = url.lastPathComponent
        let appIcon = NSWorkspace.shared.icon(forFile: url.path)

        // Text-fallback allowlists — referenced by both the symlink target
        // re-check (immediately below, security-critical) and the actual
        // text-fallback branch further down. Hoisted out of the text branch
        // so the symlink check runs BEFORE image/PDF dispatch.
        //
        // safeRichTextTypes: specific UTTypes we accept regardless of
        // extension. The broad .plainText / .text supertypes are
        // intentionally excluded — they match anything UTF-8 readable,
        // including SSH keys, credential files, and dotfiles with no
        // extension.
        let safeRichTextTypes: [UTType] = [
            .html, .json, .xml, .yaml, .propertyList,
            .delimitedText, .sourceCode, .shellScript,
        ]
        // Files with an explicit extension in this set are allowed even
        // when macOS assigns a generic UTType. No-extension files (id_rsa,
        // credentials, etc.) are rejected by the empty-extension guard.
        let safeTextExtensions: Set<String> = [
            "txt", "md", "markdown", "rst", "org", "adoc",
            "json", "jsonc", "yaml", "yml", "toml",
            "xml", "html", "htm",
            "csv", "tsv",
            "swift", "py", "rs", "go", "js", "ts", "jsx", "tsx",
            "java", "kt", "c", "cpp", "cc", "h", "hpp", "m", "mm",
            "sh", "bash", "zsh", "fish",
            "log", "diff", "patch",
            "plist", "strings",
        ]

        // Classify a (UTType, extension) pair into one of four broad
        // families. The dispatch below routes on this family AND we use
        // it to enforce symlink target-matches-claimed-family.
        enum FileFamily: Equatable { case image, pdf, text, unknown }
        func family(of t: UTType?, ext rawExt: String) -> FileFamily {
            if let t {
                if t.conforms(to: .image) { return .image }
                if t.conforms(to: .pdf) { return .pdf }
                if safeRichTextTypes.contains(where: { t.conforms(to: $0) }) { return .text }
            }
            let ext = rawExt.lowercased()
            if !ext.isEmpty && safeTextExtensions.contains(ext) { return .text }
            return .unknown
        }

        let symlinkFamily = family(of: utType, ext: url.pathExtension)

        // Symlink target re-check — hoisted ABOVE the image/PDF dispatch.
        //
        // Threat: a symlink named "screenshot.png" pointing at
        // ~/.ssh/id_rsa or any other sensitive file. Without this check,
        // `url.resourceValues(forKeys: [.contentTypeKey])` reports the
        // UTType derived from the symlink's own filename (public.png),
        // so dispatch lands in the image branch, `Data(contentsOf: url)`
        // follows the symlink, and the target's bytes get shipped to
        // the LLM as a binary image attachment. Before #199 the symlink
        // re-check existed only after the text-fallback branch, which
        // the image/PDF branches reached first.
        //
        // Defense: require the symlink's claimed family and the resolved
        // target's family to MATCH and both be a recognized family
        // (image / pdf / text). Stricter than the previous "target must
        // pass any allowlist" gate — catches `screenshot.png → secret.pdf`
        // alongside the original `screenshot.png → id_rsa`. The label
        // still uses url.lastPathComponent so the chip's display name
        // reflects what the user dropped.
        //
        // isSymbolicLinkKey rather than `resolved != url` because
        // resolvingSymlinksInPath() also normalizes parent-directory
        // symlinks like /tmp → /private/tmp, which would fire on almost
        // every temp-directory drop without catching any actual attack.
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        if isSymlink {
            let resolved = url.resolvingSymlinksInPath()
            let resolvedType = try? resolved.resourceValues(forKeys: [.contentTypeKey]).contentType
            let resolvedFamily = family(of: resolvedType, ext: resolved.pathExtension)
            guard symlinkFamily != .unknown, resolvedFamily == symlinkFamily else {
                throw NSError(
                    domain: "ParleqReferenceCapture",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Symlink target file type does not match the symlink's claimed type, or is not an allowed reference type."]
                )
            }
        }

        if let utType, utType.conforms(to: .image) {
            let data = try Data(contentsOf: url)
            return Reference(
                id: UUID(),
                source: .file(url: url),
                label: label,
                appIcon: appIcon,
                thumbnail: nil,
                captureDate: Date(),
                captureMode: .image,
                textContent: nil,
                imageData: data
            )
        }

        if let utType, utType.conforms(to: .pdf) {
            let doc = PDFDocument(url: url)
            let text = doc?.string ?? ""
            return Reference(
                id: UUID(),
                source: .file(url: url),
                label: label,
                appIcon: appIcon,
                thumbnail: nil,
                captureDate: Date(),
                captureMode: .text,
                textContent: text,
                imageData: nil
            )
        }

        // Text fallback: require either a specific safe UTType OR a
        // recognized text-file extension. The broad .plainText / .text
        // supertypes are intentionally excluded — they match anything
        // UTF-8 readable, including SSH keys, credential files, and
        // dotfiles with no extension.
        let isRichText = safeRichTextTypes.contains { utType?.conforms(to: $0) == true }
        let ext = url.pathExtension.lowercased()
        let isAllowedTextExt = !ext.isEmpty && safeTextExtensions.contains(ext)
        guard isRichText || isAllowedTextExt else {
            throw NSError(
                domain: "ParleqReferenceCapture",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey:
                    "File type not allowed as a reference. Drag images, PDFs, " +
                    "or recognized text formats (txt, md, json, source code, etc.)."]
            )
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return Reference(
            id: UUID(),
            source: .file(url: url),
            label: label,
            appIcon: appIcon,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: text,
            imageData: nil
        )
    }

    /// Read the system pasteboard. Image data → .image; otherwise
    /// text → .text. Returns nil for an empty / unreadable pasteboard.
    public static func referenceFromClipboard() -> Reference? {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return Reference(
                id: UUID(),
                source: .clipboard(label: "Clipboard image"),
                label: "Clipboard image",
                appIcon: nil,
                thumbnail: nil,
                captureDate: Date(),
                captureMode: .image,
                textContent: nil,
                imageData: png
            )
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            return Reference(
                id: UUID(),
                source: .clipboard(label: "Clipboard text"),
                label: "Clipboard text",
                appIcon: nil,
                thumbnail: nil,
                captureDate: Date(),
                captureMode: .text,
                textContent: str,
                imageData: nil
            )
        }
        return nil
    }
}
