import XCTest
@testable import ParleqAppCore

/// Unit coverage for the pure decision logic behind the in-process streaming
/// model downloader (#89). The byte-streaming itself (URLSessionDataDelegate)
/// needs a real ~6 GB network download to exercise and is verified manually;
/// everything that can be made pure is tested here.
final class HFDownloadTests: XCTestCase {

    // MARK: resolve URL

    func testResolveURLMatchesHuggingFaceLayout() {
        let url = HFDownload.resolveURL(
            host: URL(string: "https://huggingface.co")!,
            namespace: "mlx-community",
            name: "gemma-4-E4B-it-qat-4bit",
            revision: "main",
            path: "model-00001-of-00002.safetensors")
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/mlx-community/gemma-4-E4B-it-qat-4bit/resolve/main/model-00001-of-00002.safetensors")
    }

    func testResolveURLPreservesNestedSubPaths() {
        let url = HFDownload.resolveURL(
            host: URL(string: "https://huggingface.co")!,
            namespace: "org",
            name: "repo",
            revision: "main",
            path: "subdir/file.json")
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/org/repo/resolve/main/subdir/file.json")
    }

    // MARK: path-traversal guard

    func testUnsafeRepoPathRejectsAbsoluteAndDotDot() {
        XCTAssertTrue(HFDownload.isUnsafeRepoPath("/etc/passwd"))
        XCTAssertTrue(HFDownload.isUnsafeRepoPath("../../escape"))
        XCTAssertTrue(HFDownload.isUnsafeRepoPath("subdir/../../escape"))
    }

    func testUnsafeRepoPathAllowsNormalPaths() {
        XCTAssertFalse(HFDownload.isUnsafeRepoPath("model.safetensors"))
        XCTAssertFalse(HFDownload.isUnsafeRepoPath("subdir/config.json"))
    }

    // MARK: per-file plan (resume / skip / fresh)

    func testPlanSkipsFullyDownloadedFile() {
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 100, expectedBytes: 100), .skip)
    }

    func testPlanResumesPartialFile() {
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 40, expectedBytes: 100), .resume(from: 40))
    }

    func testPlanFreshWhenNothingOnDisk() {
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 0, expectedBytes: 100), .fresh)
    }

    func testPlanFreshWhenOnDiskExceedsExpected() {
        // Corrupt / stale partial larger than the expected size → start over.
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 150, expectedBytes: 100), .fresh)
    }

    func testPlanResumesWhenExpectedSizeUnknown() {
        // listFiles omitted the size: a non-empty partial is still worth resuming.
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 40, expectedBytes: nil), .resume(from: 40))
    }

    func testPlanFreshWhenExpectedUnknownAndNothingOnDisk() {
        XCTAssertEqual(HFDownload.plan(onDiskBytes: 0, expectedBytes: nil), .fresh)
    }

    // MARK: Range header

    func testRangeHeaderForNonZeroOffset() {
        XCTAssertEqual(HFDownload.rangeHeader(resumingFrom: 40), "bytes=40-")
    }

    func testRangeHeaderNilForZeroOffset() {
        XCTAssertNil(HFDownload.rangeHeader(resumingFrom: 0))
    }

    // MARK: progress fraction

    func testFractionIsByteAccurate() {
        XCTAssertEqual(HFDownload.fraction(downloaded: 250, total: 1000), 0.25, accuracy: 1e-9)
    }

    func testFractionClampsToOneAndHandlesZeroTotal() {
        XCTAssertEqual(HFDownload.fraction(downloaded: 1200, total: 1000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HFDownload.fraction(downloaded: 0, total: 0), 0.0, accuracy: 1e-9)
    }
}
