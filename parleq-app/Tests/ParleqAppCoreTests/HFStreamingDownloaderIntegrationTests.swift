import XCTest
@testable import ParleqAppCore

/// Real-network integration coverage for HFStreamingDownloader (#89). Gated on
/// PARLEQ_HF_DOWNLOAD_IT=1 so the normal `swift test` run stays offline/fast.
/// Exercises a genuine HF LFS file (tokenizer.json, ~32 MB) — the same
/// resolve→CDN-302→chunked-stream path the multi-GB model shards take — to
/// prove the bar moves WITHIN a file (the whole point of #89) and that resume
/// reconstructs an identical file.
///
/// Run:  PARLEQ_HF_DOWNLOAD_IT=1 swift test --filter HFStreamingDownloaderIntegrationTests
final class HFStreamingDownloaderIntegrationTests: XCTestCase {
    private let repoNamespace = "mlx-community"
    private let repoName = "gemma-4-E4B-it-qat-4bit"
    private let lfsPath = "tokenizer.json"   // ~32 MB LFS file → CDN redirect

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARLEQ_HF_DOWNLOAD_IT"] == "1",
            "Set PARLEQ_HF_DOWNLOAD_IT=1 to run the real-network download integration test.")
    }

    private func resolveURL(_ path: String) -> URL {
        HFDownload.resolveURL(
            host: URL(string: "https://huggingface.co")!,
            namespace: repoNamespace, name: repoName, revision: "main", path: path)
    }

    func testStreamsLFSFileWithWithinFileProgress() async throws {
        try skipUnlessEnabled()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parleq-it-\(UUID().uuidString)")
            .appendingPathComponent(lfsPath)
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }

        let provisionalTotal: Int64 = 32_000_000
        let collector = FractionCollector()
        let plan = HFPlannedFile(
            url: resolveURL(lfsPath), destination: dest, expectedBytes: provisionalTotal, action: .fresh)

        try await HFStreamingDownloader().download([plan], totalBytes: provisionalTotal) {
            collector.append($0)
        }

        let size = LocalModelStore.fileSize(at: dest)
        let fractions = collector.values
        XCTAssertGreaterThan(size, 30_000_000, "LFS file should be ~32 MB")
        // The point of #89: many progress updates WITHIN one file, ending at 1.0.
        XCTAssertGreaterThan(fractions.count, 10, "progress should advance many times within the file")
        XCTAssertEqual(fractions.last ?? -1, 1.0, accuracy: 1e-9)
        // Monotonic non-decreasing.
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "progress must not go backwards")
        }
    }

    func testResumeReconstructsIdenticalFile() async throws {
        try skipUnlessEnabled()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parleq-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("full-\(lfsPath)")
        let resumed = dir.appendingPathComponent("resumed-\(lfsPath)")

        // 1. Full reference download.
        try await HFStreamingDownloader().download(
            [HFPlannedFile(url: resolveURL(lfsPath), destination: full, expectedBytes: nil, action: .fresh)],
            totalBytes: 32_000_000) { _ in }
        let fullSize = LocalModelStore.fileSize(at: full)
        XCTAssertGreaterThan(fullSize, 30_000_000)
        let fullData = try Data(contentsOf: full)

        // 2. Seed a half-complete partial, then resume from that offset.
        let half = fullSize / 2
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fullData.prefix(Int(half)).write(to: resumed)
        XCTAssertEqual(LocalModelStore.fileSize(at: resumed), half)

        try await HFStreamingDownloader().download(
            [HFPlannedFile(
                url: resolveURL(lfsPath), destination: resumed,
                expectedBytes: fullSize, action: .resume(from: half))],
            totalBytes: fullSize) { _ in }

        // 3. Resumed file must be byte-identical to the reference.
        XCTAssertEqual(LocalModelStore.fileSize(at: resumed), fullSize)
        XCTAssertEqual(try Data(contentsOf: resumed), fullData, "resumed file must match a full download")
    }
}

/// Thread-safe progress sink — the downloader's onProgress fires on an arbitrary
/// (delegate) queue, so collecting into a plain var would race under Swift 6.
private final class FractionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
