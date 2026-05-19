import XCTest
@testable import ParleqAppCore

@MainActor
final class PromptBuilderTests: XCTestCase {

    func test_text_only_reference_is_inlined_in_system_content_no_image_parts() throws {
        // A .text reference should be inlined in the text content string,
        // and the first-turn message should contain NO image parts.
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.apple.safari", title: "Article"),
            label: "Article",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "some article text",
            imageData: nil
        )

        let msg = PromptBuilder.buildFirstTurnMessage(
            references: [ref],
            destination: nil,
            instruction: "summarize"
        )

        // The text part should contain the inlined reference content.
        let hasText = msg.parts.contains {
            if case .text(let s) = $0 { return s.contains("some article text") }
            return false
        }
        XCTAssertTrue(hasText, "Text reference body should be inlined in the text part")

        // No image parts should be present.
        for part in msg.parts {
            if case .image = part { XCTFail("text-only reference should not emit image parts") }
        }
    }

    func test_image_mode_reference_emits_image_part_in_first_turn() throws {
        // A .image reference with imageData should produce an image Part
        // in the returned LLMMessage and NOT appear as inlined text.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.example.chart", title: "Q1 Results"),
            label: "Q1 Results",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .image,
            textContent: nil,
            imageData: png
        )

        let msg = PromptBuilder.buildFirstTurnMessage(
            references: [ref],
            destination: nil,
            instruction: "what is in this chart"
        )

        XCTAssertEqual(msg.role, "user")

        let imageParts = msg.parts.compactMap { part -> Data? in
            if case .image(let d, let mime) = part {
                XCTAssertEqual(mime, "image/png", "MIME type should be image/png")
                return d
            }
            return nil
        }
        XCTAssertEqual(imageParts, [png], "Image data should match the reference's imageData")

        // The instruction text should still be present in a text part.
        let hasInstruction = msg.parts.contains {
            if case .text(let s) = $0 { return s.contains("what is in this chart") }
            return false
        }
        XCTAssertTrue(hasInstruction, "Instruction text should be present in a text part")
    }

    func test_mixed_modes_text_inlined_image_as_part() throws {
        // When both .text and .image references are attached:
        // - text reference body appears in the text content block
        // - image reference appears as an image Part
        let textRef = Reference(
            id: UUID(),
            source: .window(bundleID: "com.apple.mail", title: "Email thread"),
            label: "Email thread",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "article body content",
            imageData: nil
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let imageRef = Reference(
            id: UUID(),
            source: .window(bundleID: "com.example.charts", title: "Chart"),
            label: "Chart",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .image,
            textContent: nil,
            imageData: png
        )

        let msg = PromptBuilder.buildFirstTurnMessage(
            references: [textRef, imageRef],
            destination: nil,
            instruction: "compare"
        )

        // Text reference content inlined in the text part.
        let textInlined = msg.parts.contains {
            if case .text(let s) = $0 { return s.contains("article body content") }
            return false
        }
        XCTAssertTrue(textInlined, "Text reference body should be inlined in the text part")

        // Image reference present as an image part.
        let imageParts = msg.parts.compactMap { part -> Data? in
            if case .image(let d, _) = part { return d }
            return nil
        }
        XCTAssertEqual(imageParts, [png], "Image reference should produce an image part")
    }

    func test_image_reference_missing_data_produces_no_image_part() throws {
        // An .image reference with nil imageData should not emit an image part.
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.example.app", title: "Window"),
            label: "Window",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .image,
            textContent: nil,
            imageData: nil   // missing data
        )

        let msg = PromptBuilder.buildFirstTurnMessage(
            references: [ref],
            destination: nil,
            instruction: "describe"
        )

        for part in msg.parts {
            if case .image = part { XCTFail("image reference with nil imageData should not emit an image part") }
        }
    }

    func test_legacy_content_string_is_text_only() throws {
        // LLMMessage.legacyContentString should join text parts and
        // ignore image parts.
        let png = Data([0x01, 0x02])
        let msg = LLMMessage(role: "user", parts: [
            .image(data: png, mimeType: "image/png"),
            .text("hello "),
            .text("world"),
        ])
        XCTAssertEqual(msg.legacyContentString, "hello world")
    }

    func test_convenience_init_produces_single_text_part() throws {
        // The convenience LLMMessage(role:content:) init should produce
        // a single .text part matching the content string.
        let msg = LLMMessage(role: "user", content: "test message")
        XCTAssertEqual(msg.parts.count, 1)
        if case .text(let s) = msg.parts[0] {
            XCTAssertEqual(s, "test message")
        } else {
            XCTFail("Expected .text part from convenience init")
        }
    }

    // MARK: - referenceLabel for Phase 2 Source types (.file and .clipboard)
    //
    // referenceLabel is private, so we verify its output indirectly
    // through firstTurnUserContent — the label appears as the opening
    // "[Reference N — …]" fence in the rendered text.

    func test_reference_label_file_uses_filename() {
        // .file source → label should be "Reference 1 — <filename>"
        let url = URL(fileURLWithPath: "/tmp/meeting-notes.txt")
        let ref = Reference(
            id: UUID(),
            source: .file(url: url),
            label: "meeting-notes.txt",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "notes content",
            imageData: nil
        )

        let content = PromptBuilder.firstTurnUserContent(
            references: [ref],
            destination: nil,
            instruction: "summarise"
        )

        XCTAssertTrue(
            content.contains("Reference 1 — meeting-notes.txt"),
            "File reference label should embed the filename; got:\n\(content)"
        )
    }

    func test_reference_label_file_deep_path_uses_last_component() {
        // Only the last path component should appear in the label —
        // not the full directory path.
        let url = URL(fileURLWithPath: "/Users/alice/Documents/specs/design.pdf")
        let ref = Reference(
            id: UUID(),
            source: .file(url: url),
            label: "design.pdf",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "spec content",
            imageData: nil
        )

        let content = PromptBuilder.firstTurnUserContent(
            references: [ref],
            destination: nil,
            instruction: "review"
        )

        XCTAssertTrue(
            content.contains("Reference 1 — design.pdf"),
            "File reference label should use lastPathComponent only; got:\n\(content)"
        )
        XCTAssertFalse(
            content.contains("/Users/alice"),
            "File reference label must not include parent directories"
        )
    }

    func test_reference_label_clipboard_passthrough() {
        // .clipboard source → label should be "Reference 1 — <label>"
        // where <label> is the string stored in the source enum.
        let ref = Reference(
            id: UUID(),
            source: .clipboard(label: "Clipboard text"),
            label: "Clipboard text",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "pasted text content",
            imageData: nil
        )

        let content = PromptBuilder.firstTurnUserContent(
            references: [ref],
            destination: nil,
            instruction: "expand"
        )

        XCTAssertTrue(
            content.contains("Reference 1 — Clipboard text"),
            "Clipboard reference label should pass through the source label; got:\n\(content)"
        )
    }

    func test_reference_label_clipboard_image_passthrough() {
        // Clipboard image references travel as image parts, so they
        // are NOT inlined as text blocks; firstTurnUserContent skips
        // them.  Verify no stray label appears.
        let ref = Reference(
            id: UUID(),
            source: .clipboard(label: "Clipboard image"),
            label: "Clipboard image",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .image,
            textContent: nil,
            imageData: Data([0x89, 0x50, 0x4E, 0x47])
        )

        let content = PromptBuilder.firstTurnUserContent(
            references: [ref],
            destination: nil,
            instruction: "describe"
        )

        // Image-mode refs are not inlined — no "[Reference 1 — …]" block.
        XCTAssertFalse(
            content.contains("Reference 1 — Clipboard image"),
            "Image-mode clipboard ref must not produce a text block in firstTurnUserContent"
        )
    }

    func test_reference_label_numbering_increments_across_sources() {
        // When a mix of source types is present, numbering must be
        // sequential across the entire reference list (not per-source-type).
        let fileRef = Reference(
            id: UUID(),
            source: .file(url: URL(fileURLWithPath: "/tmp/notes.txt")),
            label: "notes.txt",
            appIcon: nil, thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "notes",
            imageData: nil
        )
        let clipRef = Reference(
            id: UUID(),
            source: .clipboard(label: "Clipboard text"),
            label: "Clipboard text",
            appIcon: nil, thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "clip",
            imageData: nil
        )

        let content = PromptBuilder.firstTurnUserContent(
            references: [fileRef, clipRef],
            destination: nil,
            instruction: "combine"
        )

        XCTAssertTrue(content.contains("Reference 1 — notes.txt"), "First ref should be numbered 1")
        XCTAssertTrue(content.contains("Reference 2 — Clipboard text"), "Second ref should be numbered 2")
    }
}
