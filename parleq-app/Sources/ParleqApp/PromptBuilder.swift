// PromptBuilder — builds the system prompt and user content blocks
// for the LLM call, depending on whether references are attached.
//
// Two modes:
//
// 1. Cleanup mode (no references): uses the existing cleanup
//    system prompt (see SystemPrompts.swift). User-content blocks
//    are just the dictated text. Identical to today's behavior.
//
// 2. Reference-aware mode (refs attached): swaps in the
//    reference-aware system prompt. The user-content block of the
//    first turn includes the references as bracketed blocks, the
//    paste-destination, and the dictated instruction. Subsequent
//    turns are plain instructions (the LLM already has refs in its
//    conversation context).

import AppKit
import Foundation

enum PromptBuilder {
    /// System prompt for reference-aware sessions. Frames the
    /// assistant's role as "act on user's instruction using
    /// attached references" rather than "polish the user's words."
    static let referenceAwareSystem: String = """
        You are a writing assistant. The user is dictating with attached
        reference materials. Their utterance is an instruction about or
        using the references. Apply the instruction as given; use the
        references as source material, context, or target as the
        instruction implies. Match the destination application's tone
        (Mail, Slack, etc.) when relevant.

        Output ONLY the requested text — no preamble, no explanation,
        no markdown formatting unless the user explicitly requests it,
        no quotation marks around the output.
        """

    /// Render the first-turn user content with references, destination,
    /// and instruction. Subsequent turns use `subsequentTurnUserContent`.
    static func firstTurnUserContent(
        references: [Reference],
        destination: String?,
        instruction: String
    ) -> String {
        var parts: [String] = []
        for (i, ref) in references.enumerated() {
            let label = referenceLabel(ref, index: i + 1)
            let content = renderedContent(for: ref)
            parts.append("[\(label)]")
            parts.append(content)
            parts.append("[End \(label)]")
            parts.append("")
        }
        if let dest = destination, !dest.isEmpty {
            parts.append("Destination: \(dest)")
            parts.append("")
        }
        parts.append("Instruction: \(instruction)")
        return parts.joined(separator: "\n")
    }

    /// Subsequent turns: just the new instruction. The references
    /// and prior turns are already in the conversation context, so
    /// the provider's prompt cache hits them at the cached rate.
    static func subsequentTurnUserContent(instruction: String) -> String {
        instruction
    }

    private static func referenceLabel(_ ref: Reference, index: Int) -> String {
        switch ref.source {
        case .window(let bundleID, let title):
            let appName = appNameFromBundleID(bundleID) ?? bundleID
            return "Reference \(index) — \(appName) — \(sanitizeTitle(title))"
        }
    }

    /// Phase 1: only .text references are produced. Branch on captureMode
    /// rather than nil-coalescing on textContent so that a missing-text
    /// .text reference (OCR returned empty) doesn't mislead the LLM into
    /// looking for a nonexistent attached image.
    private static func renderedContent(for ref: Reference) -> String {
        switch ref.captureMode {
        case .text:
            return ref.textContent ?? "(no text extracted)"
        case .image:
            return ref.imageData != nil
                ? "(image reference; see attached image)"
                : "(image reference; image data missing)"
        }
    }

    /// Strip characters that would muddle the `[Reference N — App — title]`
    /// framing (embedded quotes / newlines). Titles otherwise pass through.
    private static func sanitizeTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func appNameFromBundleID(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
