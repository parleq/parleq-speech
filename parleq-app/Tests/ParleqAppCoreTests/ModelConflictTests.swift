import XCTest
@testable import ParleqAppCore

final class ModelConflictTests: XCTestCase {
    private func ref(mode: Reference.CaptureMode) -> Reference {
        return Reference(
            id: UUID(),
            source: .window(bundleID: "b", title: "t"),
            label: "L", appIcon: nil, thumbnail: nil,
            captureDate: Date(),
            captureMode: mode,
            textContent: mode == .text ? "x" : nil,
            imageData: mode == .image ? Data([0x89]) : nil
        )
    }

    func test_no_references_no_conflict() {
        XCTAssertNil(ModelConflict.from(modelSupportsVision: false, references: []))
    }

    func test_vision_model_never_conflicts() {
        let refs = [ref(mode: .image), ref(mode: .image)]
        XCTAssertNil(ModelConflict.from(modelSupportsVision: true, references: refs))
    }

    func test_text_refs_with_non_vision_model_no_conflict() {
        let refs = [ref(mode: .text), ref(mode: .text)]
        XCTAssertNil(ModelConflict.from(modelSupportsVision: false, references: refs))
    }

    func test_one_image_ref_with_non_vision_model_conflicts() {
        let refs = [ref(mode: .image)]
        XCTAssertEqual(
            ModelConflict.from(modelSupportsVision: false, references: refs),
            .visionRefsButNonVisionModel(refCount: 1)
        )
    }

    func test_mixed_modes_with_non_vision_model_counts_image_refs() {
        let refs = [ref(mode: .text), ref(mode: .image), ref(mode: .image), ref(mode: .text)]
        XCTAssertEqual(
            ModelConflict.from(modelSupportsVision: false, references: refs),
            .visionRefsButNonVisionModel(refCount: 2)
        )
    }
}
