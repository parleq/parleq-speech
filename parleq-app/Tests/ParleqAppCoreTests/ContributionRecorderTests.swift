import XCTest
@testable import ParleqAppCore

/// Tests for `ContributionRecorder` (the durable, armed-only flywheel
/// sink) and the `ContributionRecord.correctorPairEligible` derivation.
/// Hermetic: each test injects a temp `baseDirectory` so nothing touches
/// the real `~/.parleq/flywheel/`.
final class ContributionRecorderTests: XCTestCase {

    private var tempBase: URL!

    override func setUp() {
        super.setUp()
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("flywheel-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempBase { try? FileManager.default.removeItem(at: tempBase) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRecord(
        disposition: ContributionDisposition = .accepted,
        asrTranscript: String = "instal sneak",
        cleaned: String? = "install Snyk",
        finalText: String? = "install Snyk",
        cleanupFailed: Bool = false,
        referenceWindowsAttached: Bool = false,
        transformApplied: Bool = false,
        refined: Bool = false,
        wav: Data? = nil
    ) -> ContributionRecord {
        ContributionRecord(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            disposition: disposition,
            asrTranscript: asrTranscript,
            cleaned: cleaned,
            finalText: finalText,
            cleanupFailed: cleanupFailed,
            diagnostics: nil,
            vocabulary: ["Snyk"],
            asrModel: "parakeet-tdt-v3",
            fluidaudioVersion: "0.14.5",
            llm: "gemini:gemini-2.5-flash",
            appBundle: "com.apple.dt.Xcode",
            referenceWindowsAttached: referenceWindowsAttached,
            transformApplied: transformApplied,
            refined: refined,
            refineTurns: [],
            spelloutTerms: [],
            wav: wav
        )
    }

    private func manifestLines() throws -> [[String: Any]] {
        let url = tempBase.appendingPathComponent("manifest.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    // MARK: - Write paths

    func test_first_write_creates_manifest_with_one_line() async throws {
        let recorder = ContributionRecorder(baseDirectory: tempBase)
        await recorder.capture(makeRecord())
        let lines = try manifestLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["asr_transcript"] as? String, "instal sneak")
        XCTAssertEqual(lines[0]["final"] as? String, "install Snyk")
        XCTAssertEqual(lines[0]["corrector_pair_eligible"] as? Bool, true)
        XCTAssertEqual(lines[0]["disposition"] as? String, "accepted")
    }

    func test_second_write_appends_a_second_line() async throws {
        let recorder = ContributionRecorder(baseDirectory: tempBase)
        await recorder.capture(makeRecord(asrTranscript: "one"))
        await recorder.capture(makeRecord(asrTranscript: "two"))
        let lines = try manifestLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["asr_transcript"] as? String, "one")
        XCTAssertEqual(lines[1]["asr_transcript"] as? String, "two")
    }

    func test_audio_written_when_wav_present() async throws {
        let recorder = ContributionRecorder(baseDirectory: tempBase)
        let wav = Data(repeating: 0x7F, count: 256)
        await recorder.capture(makeRecord(wav: wav))
        let lines = try manifestLines()
        let rel = try XCTUnwrap(lines[0]["audio"] as? String)
        XCTAssertTrue(rel.hasPrefix("audio/") && rel.hasSuffix(".wav"))
        let audioURL = tempBase.appendingPathComponent(rel)
        XCTAssertEqual(try Data(contentsOf: audioURL).count, 256)
    }

    func test_write_failure_is_silent_and_writes_nothing() async {
        // Put a regular FILE where the audio/ directory needs to be, so
        // createDirectory throws → the capture fails silently.
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let audioPath = tempBase.appendingPathComponent("audio")
        FileManager.default.createFile(atPath: audioPath.path, contents: Data("x".utf8))

        let recorder = ContributionRecorder(baseDirectory: tempBase)
        await recorder.capture(makeRecord())  // must not throw / crash

        let manifestURL = tempBase.appendingPathComponent("manifest.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path),
                       "a failed capture must not write a manifest line")
    }

    // MARK: - corrector_pair_eligible derivation

    func test_eligible_for_clean_accepted_pair() {
        XCTAssertTrue(makeRecord().correctorPairEligible)
    }

    func test_not_eligible_when_discarded() {
        XCTAssertFalse(
            makeRecord(disposition: .discarded, cleaned: nil, finalText: nil).correctorPairEligible)
    }

    func test_not_eligible_when_cleanup_failed() {
        // Cleanup failed → cleaned nil, final is the raw fallback.
        XCTAssertFalse(
            makeRecord(cleaned: nil, finalText: "instal sneak", cleanupFailed: true)
                .correctorPairEligible)
    }

    func test_not_eligible_when_no_provider_cleanup() {
        // provider=none: cleanup skipped, raw pasted, cleanupFailed=false
        // but cleaned=nil and final==asr_transcript (identity pair).
        XCTAssertFalse(
            makeRecord(cleaned: nil, finalText: "instal sneak", cleanupFailed: false)
                .correctorPairEligible)
    }

    func test_not_eligible_when_reference_or_transform_or_refined() {
        XCTAssertFalse(makeRecord(referenceWindowsAttached: true).correctorPairEligible)
        XCTAssertFalse(makeRecord(transformApplied: true).correctorPairEligible)
        XCTAssertFalse(makeRecord(refined: true).correctorPairEligible)
    }
}
