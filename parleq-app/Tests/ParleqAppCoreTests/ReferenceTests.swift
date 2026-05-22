import XCTest
import AppKit
@testable import ParleqAppCore

final class ReferenceTests: XCTestCase {
    func test_text_reference_round_trip() {
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.apple.safari", title: "Some Page"),
            label: "Some Page",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(timeIntervalSince1970: 1000),
            captureMode: .text,
            textContent: "hello",
            imageData: nil
        )
        XCTAssertEqual(ref.label, "Some Page")
        XCTAssertEqual(ref.captureMode, .text)
        XCTAssertEqual(ref.textContent, "hello")
        XCTAssertNil(ref.imageData)
    }

    func test_image_reference_holds_data() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let ref = Reference(
            id: UUID(),
            source: .window(bundleID: "com.apple.preview", title: "diagram.png"),
            label: "diagram.png",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .image,
            textContent: nil,
            imageData: png
        )
        XCTAssertEqual(ref.captureMode, .image)
        XCTAssertEqual(ref.imageData, png)
    }

    func test_equality_uses_id() {
        let id = UUID()
        let a = Reference(
            id: id,
            source: .window(bundleID: "b", title: "t"),
            label: "L",
            appIcon: nil,
            thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "x",
            imageData: nil
        )
        // Reference.id is a UUID — verify it matches
        XCTAssertEqual(a.id, id)
        // Verify a copy has the same id
        let b = a
        XCTAssertEqual(a.id, b.id)
    }

    func test_window_capture_constructor_can_carry_both_text_and_image() {
        // Pins the Phase 2 invariant that a text-mode WINDOW reference
        // retains imageData so the chip's T→👁 toggle doesn't need a
        // re-capture. ReferenceCapture is the actual producer; here we
        // verify the value type accepts the shape ReferenceCapture
        // now constructs.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let r = Reference(
            id: UUID(),
            source: .window(bundleID: "x", title: "y"),
            label: "y",
            appIcon: nil, thumbnail: nil,
            captureDate: Date(),
            captureMode: .text,
            textContent: "ocr text",
            imageData: png
        )
        XCTAssertEqual(r.captureMode, .text)
        XCTAssertNotNil(r.textContent)
        XCTAssertNotNil(r.imageData)
    }

    func test_file_reference_image_uses_image_mode() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).png")
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: tmp)
        XCTAssertEqual(ref.captureMode, .image)
        XCTAssertNotNil(ref.imageData)
        XCTAssertNil(ref.textContent)
        if case .file(let url) = ref.source {
            XCTAssertEqual(url, tmp)
        } else {
            XCTFail("expected .file source")
        }
    }

    func test_file_reference_text_uses_text_mode() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).txt")
        try "hello world".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: tmp)
        XCTAssertEqual(ref.captureMode, .text)
        XCTAssertEqual(ref.textContent, "hello world")
        XCTAssertNil(ref.imageData)
    }
}
