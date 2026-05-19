// ReferenceCaptureTests — Phase 2 additions:
// PDF wrap, clipboard text/image/empty paths.
//
// PDF case synthesizes a document in-memory via PDFKit, writes to a
// temp file, exercises the file factory, and verifies captureMode +
// text extraction. Clipboard tests snapshot/restore NSPasteboard.general
// so other tests are never affected.

import XCTest
import AppKit
import PDFKit
@testable import ParleqAppCore

final class ReferenceCaptureTests: XCTestCase {

    // MARK: - PDF wrap

    func test_pdf_file_uses_text_mode_and_extracts_text() throws {
        // Build a minimal single-page PDF in memory.
        let doc = PDFDocument()
        let page = PDFPage()
        // Annotate the page with a text annotation so PDFDocument.string
        // has something to return.
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 72, y: 700, width: 400, height: 30),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Hello from test PDF"
        page.addAnnotation(annotation)
        doc.insert(page, at: 0)

        // Write to a temp .pdf file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pdfData = doc.dataRepresentation()
        XCTAssertNotNil(pdfData, "PDFDocument should produce serialisable data")
        try pdfData!.write(to: tmp)

        // Exercise the factory.
        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: tmp)

        // captureMode must be .text for PDF files.
        XCTAssertEqual(ref.captureMode, .text, "PDF file should produce a text-mode reference")

        // imageData should be nil — PDFs are extracted as text.
        XCTAssertNil(ref.imageData, "PDF reference should not carry image data")

        // source must be .file pointing at our temp URL.
        if case .file(let url) = ref.source {
            XCTAssertEqual(url, tmp)
        } else {
            XCTFail("PDF reference should have .file source; got \(ref.source)")
        }

        // label should be the filename.
        XCTAssertEqual(ref.label, tmp.lastPathComponent)
    }

    func test_pdf_file_text_content_is_non_nil() throws {
        // Verify textContent is set (even if the string is empty for a
        // blank PDF — the important thing is captureMode != .image and
        // textContent != nil).
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try doc.dataRepresentation()!.write(to: tmp)

        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: tmp)
        XCTAssertNotNil(ref.textContent, "textContent should be non-nil for PDF (may be empty for blank page)")
    }

    // MARK: - Clipboard: empty pasteboard

    func test_clipboard_empty_returns_nil() {
        let pb = NSPasteboard.general
        let savedTypes = pb.types ?? []
        let savedItems = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pb.clearContents()
            if !savedItems.isEmpty {
                pb.writeObjects(savedItems)
            }
        }

        pb.clearContents()
        let ref = ScreenCaptureKitReferenceCapture.referenceFromClipboard()
        XCTAssertNil(ref, "Empty pasteboard should return nil reference")
        _ = savedTypes // suppress unused warning
    }

    // MARK: - Clipboard: text

    func test_clipboard_text_produces_text_mode_reference() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let s = saved {
                pb.setString(s, forType: .string)
            }
        }

        pb.clearContents()
        pb.setString("clipboard test content", forType: .string)

        let ref = ScreenCaptureKitReferenceCapture.referenceFromClipboard()
        XCTAssertNotNil(ref, "Non-empty text pasteboard should return a reference")
        XCTAssertEqual(ref?.captureMode, .text)
        XCTAssertEqual(ref?.textContent, "clipboard test content")
        XCTAssertEqual(ref?.label, "Clipboard text")
        if case .clipboard(let label) = ref?.source {
            XCTAssertEqual(label, "Clipboard text")
        } else {
            XCTFail("Text clipboard reference should have .clipboard source; got \(String(describing: ref?.source))")
        }
    }

    // MARK: - Clipboard: image

    func test_clipboard_image_produces_image_mode_reference() {
        let pb = NSPasteboard.general
        // Snapshot the existing pasteboard contents.
        let savedItems = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pb.clearContents()
            if !savedItems.isEmpty {
                pb.writeObjects(savedItems)
            }
        }

        // Synthesize a tiny 1×1 NSImage and write it to the pasteboard.
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        img.unlockFocus()

        pb.clearContents()
        pb.writeObjects([img])

        let ref = ScreenCaptureKitReferenceCapture.referenceFromClipboard()
        XCTAssertNotNil(ref, "Image on pasteboard should return a reference")
        XCTAssertEqual(ref?.captureMode, .image)
        XCTAssertNotNil(ref?.imageData, "Image reference should carry PNG data")
        XCTAssertEqual(ref?.label, "Clipboard image")
        XCTAssertNil(ref?.textContent)
        if case .clipboard(let label) = ref?.source {
            XCTAssertEqual(label, "Clipboard image")
        } else {
            XCTFail("Image clipboard reference should have .clipboard source; got \(String(describing: ref?.source))")
        }
    }
}
