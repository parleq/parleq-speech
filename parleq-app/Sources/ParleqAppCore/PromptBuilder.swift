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
    ///
    /// Only `.text` references are inlined here. `.image` references are
    /// carried as image content parts in the returned `LLMMessage` via
    /// `buildFirstTurnMessage` — this method is kept for the fallback
    /// string-only path and for tests that check text inlining.
    static func firstTurnUserContent(
        references: [Reference],
        destination: String?,
        instruction: String
    ) -> String {
        var parts: [String] = []
        for (i, ref) in references.enumerated() {
            // Image-mode references are not inlined as text blocks —
            // they travel as image content parts in the LLMMessage.
            guard ref.captureMode == .text else { continue }
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

    /// Build the first-turn `LLMMessage` for a reference-aware session.
    /// Text references are inlined in the text part (as fenced blocks
    /// in the instruction string). Image references are prepended as
    /// `.image` parts so the LLM sees both in a single message turn.
    static func buildFirstTurnMessage(
        references: [Reference],
        destination: String?,
        instruction: String
    ) -> LLMMessage {
        var messageParts: [Part] = []

        // Image references go first as image parts.
        for ref in references where ref.captureMode == .image {
            if let data = ref.imageData {
                messageParts.append(.image(data: data, mimeType: "image/png"))
            }
        }

        // Text instruction (with text references inlined) goes last.
        let textContent = firstTurnUserContent(
            references: references,
            destination: destination,
            instruction: instruction
        )
        messageParts.append(.text(textContent))

        return LLMMessage(role: "user", parts: messageParts)
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
        case .file(let url):
            return "Reference \(index) — \(url.lastPathComponent)"
        case .clipboard(let label):
            return "Reference \(index) — \(label)"
        }
    }

    /// Return the inline text content for a reference. Only called for
    /// `.text` references — `.image` references travel as image content
    /// parts via `buildFirstTurnMessage` and are not inlined here.
    private static func renderedContent(for ref: Reference) -> String {
        switch ref.captureMode {
        case .text:
            return ref.textContent ?? "(no text extracted)"
        case .image:
            // Should not be reached — callers guard on captureMode == .text.
            // Belt-and-suspenders placeholder so the LLM gets a legible
            // signal if it somehow is.
            return "(image reference)"
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
