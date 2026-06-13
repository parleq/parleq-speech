import XCTest
@testable import ParleqAppCore

/// Unit tests for `modelDownloadProgress` — the byte-weighted download-progress
/// calculation (#87). The bug it fixes: file-count weighting made the bar jump
/// to ~30% (the dominant shard's start fraction) and then appear frozen while
/// the multi-GB shard downloaded.
final class LocalModelProgressTests: XCTestCase {

    // A realistic shape: three tiny files + one ~4 GB shard at index 1.
    private let sizes: [Int?] = [10, 4_000_000_000, 10, 10]

    func test_byteWeighted_dominantShard_startsNearZero_notOneOverCount() {
        // Count-weighting would put the shard's START at index/total = 1/4 = 25%.
        // Byte-weighting puts it at ~10 bytes / ~4 GB ≈ 0%.
        let atStart = modelDownloadProgress(byteSizes: sizes, index: 1, fileFraction: 0)
        XCTAssertLessThan(atStart, 0.01,
                          "shard start should be a sliver, not the 25% file-count step")
    }

    func test_byteWeighted_midShard_reflectsBytes() {
        let mid = modelDownloadProgress(byteSizes: sizes, index: 1, fileFraction: 0.5)
        XCTAssertEqual(mid, (10.0 + 2_000_000_000.0) / 4_000_000_030.0, accuracy: 1e-9,
                       "half the shard ≈ half the total bytes")
    }

    func test_continuous_acrossFileBoundary() {
        // End of file i (fraction 1) must equal start of file i+1 (fraction 0) —
        // no jump at boundaries.
        let endOf1 = modelDownloadProgress(byteSizes: sizes, index: 1, fileFraction: 1)
        let startOf2 = modelDownloadProgress(byteSizes: sizes, index: 2, fileFraction: 0)
        XCTAssertEqual(endOf1, startOf2, accuracy: 1e-12)
    }

    func test_reachesOne_atLastFileComplete() {
        XCTAssertEqual(modelDownloadProgress(byteSizes: sizes, index: 3, fileFraction: 1),
                       1.0, accuracy: 1e-12)
    }

    func test_fallsBackToCountWeight_whenAnySizeMissing() {
        let mixed: [Int?] = [nil, 100]   // one unknown size → count-weighting
        XCTAssertEqual(modelDownloadProgress(byteSizes: mixed, index: 0, fileFraction: 0.5),
                       0.25, accuracy: 1e-12)
        XCTAssertEqual(modelDownloadProgress(byteSizes: mixed, index: 1, fileFraction: 0),
                       0.5, accuracy: 1e-12)
    }

    func test_guards_and_clamps() {
        XCTAssertEqual(modelDownloadProgress(byteSizes: [], index: 0, fileFraction: 0.5), 0,
                       "empty → 0")
        XCTAssertEqual(modelDownloadProgress(byteSizes: [100], index: 5, fileFraction: 0.5), 0,
                       "out-of-range index → 0")
        XCTAssertEqual(modelDownloadProgress(byteSizes: [100], index: 0, fileFraction: 2.0),
                       1.0, accuracy: 1e-12, "fraction clamped to 1")
        XCTAssertEqual(modelDownloadProgress(byteSizes: [100], index: 0, fileFraction: -1.0),
                       0.0, accuracy: 1e-12, "fraction clamped to 0")
    }

    func test_allZeroSizes_fallBackToCountWeight() {
        // Degenerate: sizes present but total is 0 → avoid divide-by-zero, use count.
        let zeros: [Int?] = [0, 0]
        XCTAssertEqual(modelDownloadProgress(byteSizes: zeros, index: 1, fileFraction: 0),
                       0.5, accuracy: 1e-12)
    }
}
