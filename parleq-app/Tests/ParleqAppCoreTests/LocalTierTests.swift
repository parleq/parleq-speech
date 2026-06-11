import XCTest
@testable import ParleqAppCore

final class LocalTierTests: XCTestCase {
    func testLocalConfigDecodeAndDefaults() {
        // Non-default values are stored and round-trip through parse.
        let c = Config.parse(fromDictionary: [
            "llm": [
                "provider": "local",
                "local": [
                    "residency": "keep",
                    "idle_unload_minutes": 7,
                    "allow_unsupported_ram": true,
                ],
            ],
        ])
        XCTAssertEqual(c.localResidency, .keep)
        XCTAssertEqual(c.localIdleUnloadMinutes, 7)
        XCTAssertTrue(c.localAllowUnsupportedRAM)

        // Empty dict yields all defaults.
        let empty = Config.parse(fromDictionary: [:])
        XCTAssertEqual(empty.localResidency, .auto)
        XCTAssertNil(empty.localIdleUnloadMinutes)
        XCTAssertFalse(empty.localAllowUnsupportedRAM)
    }

    func testRAMTiers() {
        XCTAssertEqual(RAMTier.forPhysicalMemory(8 << 30), .unsupported)
        XCTAssertEqual(RAMTier.forPhysicalMemory(12 << 30), .cautioned)
        XCTAssertEqual(RAMTier.forPhysicalMemory(16 << 30), .cautioned)
        XCTAssertEqual(RAMTier.forPhysicalMemory(23 << 30), .cautioned)
        XCTAssertEqual(RAMTier.forPhysicalMemory(24 << 30), .comfortable)
        XCTAssertEqual(RAMTier.forPhysicalMemory(64 << 30), .comfortable)
    }

    // MARK: - Round-trip serialization (mirrors LLMTuningConfigTests style)

    func testLocalConfigSerializeRoundTrip() {
        // Set three non-default local fields, serialize, parse back, assert all three.
        var c = Config.defaults
        c.localResidency = .idle
        c.localIdleUnloadMinutes = 9
        c.localAllowUnsupportedRAM = true

        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.localResidency, .idle)
        XCTAssertEqual(parsed.localIdleUnloadMinutes, 9)
        XCTAssertTrue(parsed.localAllowUnsupportedRAM)
    }

    func testLocalDefaultsOmitLocalKey() {
        // An all-default Config must not emit a "local" key inside "llm"
        // (mirrors the tuning omit-when-default test in LLMTuningConfigTests).
        let dict = Config.serializeToDictionary(Config.defaults)
        let llm = dict["llm"] as? [String: Any]
        XCTAssertNotNil(llm)
        XCTAssertNil(llm?["local"], "all-default local config emits no local key")
    }

    // MARK: - Invalid residency falls back to .auto

    func testLocalConfigInvalidResidencyFallsToAuto() {
        let c = Config.parse(fromDictionary: [
            "llm": ["local": ["residency": "bogus"]],
        ])
        XCTAssertEqual(c.localResidency, .auto,
                       "unrecognized residency string must fall back to .auto")
    }

    // MARK: - ResidencyPolicy — pure policy function

    func testResidencyPolicy() {
        // .auto with RAM tier picks the tier-default idle timeout.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .auto, tier: .cautioned, configMinutes: nil),
            .unloadAfter(minutes: 3))
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .auto, tier: .comfortable, configMinutes: nil),
            .unloadAfter(minutes: 30))

        // .keep always returns keepLoaded regardless of tier.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .keep, tier: .cautioned, configMinutes: nil),
            .keepLoaded)
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .keep, tier: .comfortable, configMinutes: nil),
            .keepLoaded)

        // configMinutes override applies in both .idle and .auto.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .idle, tier: .comfortable, configMinutes: 7),
            .unloadAfter(minutes: 7))
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .auto, tier: .comfortable, configMinutes: 7),
            .unloadAfter(minutes: 7))

        // .idle with no configMinutes falls through to the tier default.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .idle, tier: .cautioned, configMinutes: nil),
            .unloadAfter(minutes: 3))
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .idle, tier: .comfortable, configMinutes: nil),
            .unloadAfter(minutes: 30))

        // .unsupported tier is most conservative: 3-minute default.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .auto, tier: .unsupported, configMinutes: nil),
            .unloadAfter(minutes: 3))
        // configMinutes still respected even on unsupported tier.
        XCTAssertEqual(
            ResidencyPolicy.effective(residency: .auto, tier: .unsupported, configMinutes: 1),
            .unloadAfter(minutes: 1))
    }

    // MARK: - LocalModelStore — paths, ready marker, and remove()

    @MainActor
    func testModelStorePathsAndReadyMarker() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalModelStore(checkpoint: "org/some-model", rootDirectory: tmp)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertTrue(store.modelDirectory.path.hasSuffix("org--some-model"))
        try FileManager.default.createDirectory(at: store.modelDirectory, withIntermediateDirectories: true)
        try Data().write(to: store.modelDirectory.appendingPathComponent(".parleq-ready"))
        XCTAssertEqual(LocalModelStore(checkpoint: "org/some-model", rootDirectory: tmp).state, .ready)
        LocalModelStore(checkpoint: "org/some-model", rootDirectory: tmp).remove()
        XCTAssertEqual(LocalModelStore(checkpoint: "org/some-model", rootDirectory: tmp).state, .notDownloaded)
    }

    // MARK: - KV prefix-cache key + LRU (Task 9)

    func testPrefixCacheKeyHashesPrefixText() {
        let a = SystemPrefixCacheKey(checkpoint: "m", prefixText: "hello")
        let b = SystemPrefixCacheKey(checkpoint: "m", prefixText: "hello")
        let c = SystemPrefixCacheKey(checkpoint: "m", prefixText: "hello!")
        let d = SystemPrefixCacheKey(checkpoint: "other", prefixText: "hello")

        // Same checkpoint + same text → equal key (cache hit).
        XCTAssertEqual(a, b)
        // One-character change in the prefix → different key (natural invalidation).
        XCTAssertNotEqual(a, c)
        // Different checkpoint, same text → different key (model-specific KV state).
        XCTAssertNotEqual(a, d)

        // Hash is a deterministic SHA-256 hex of the UTF-8 bytes.
        XCTAssertEqual(
            SystemPrefixCacheKey.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(a.prefixHash.count, 64)
    }

    func testPrefixCacheLRUInsertGetAndRecency() {
        var lru = PrefixCacheLRU<Int>(capacity: 2)
        let k1 = SystemPrefixCacheKey(checkpoint: "m", prefixText: "1")
        let k2 = SystemPrefixCacheKey(checkpoint: "m", prefixText: "2")

        XCTAssertNil(lru.get(k1))
        XCTAssertNil(lru.insert(k1, 10), "first insert evicts nothing")
        XCTAssertNil(lru.insert(k2, 20), "second insert at capacity evicts nothing")
        XCTAssertEqual(lru.count, 2)
        XCTAssertEqual(lru.get(k1), 10)
        XCTAssertEqual(lru.get(k2), 20)

        // Replacing an existing key never evicts and updates the value.
        XCTAssertNil(lru.insert(k1, 11))
        XCTAssertEqual(lru.get(k1), 11)
        XCTAssertEqual(lru.count, 2)
    }

    func testPrefixCacheLRUEvictsLeastRecentlyUsed() {
        var lru = PrefixCacheLRU<Int>(capacity: 2)
        let k1 = SystemPrefixCacheKey(checkpoint: "m", prefixText: "1")
        let k2 = SystemPrefixCacheKey(checkpoint: "m", prefixText: "2")
        let k3 = SystemPrefixCacheKey(checkpoint: "m", prefixText: "3")

        lru.insert(k1, 1)
        lru.insert(k2, 2)
        // Touch k1 so k2 becomes the least-recently-used.
        _ = lru.get(k1)
        // Inserting a third key at capacity evicts the LRU (k2), returning its value.
        let evicted = lru.insert(k3, 3)
        XCTAssertEqual(evicted, 2, "k2 was least-recently-used and must be evicted")
        XCTAssertFalse(lru.contains(k2))
        XCTAssertTrue(lru.contains(k1))
        XCTAssertTrue(lru.contains(k3))
        XCTAssertEqual(lru.count, 2)
    }

    func testPrefixCacheLRURemoveAllReturnsValues() {
        var lru = PrefixCacheLRU<Int>(capacity: 4)
        lru.insert(SystemPrefixCacheKey(checkpoint: "m", prefixText: "a"), 1)
        lru.insert(SystemPrefixCacheKey(checkpoint: "m", prefixText: "b"), 2)
        let dropped = lru.removeAll().sorted()
        XCTAssertEqual(dropped, [1, 2], "removeAll returns every held value for release")
        XCTAssertEqual(lru.count, 0)
    }

    // MARK: - $0 pricing for on-device runs (Task 12)

    /// The local model's checkpoint ID must never appear in any cloud pricing
    /// table — `Pricing.cost` must return nil so `aggregate()` short-circuits
    /// to 0 via the provider=="local" guard.
    func testLocalCheckpointNotInPricingTable() {
        let cost = Pricing.cost(
            model: LocalModelDefaults.checkpoint,
            inputTokens: 10_000,
            outputTokens: 2_000
        )
        XCTAssertNil(cost,
            "LocalModelDefaults.checkpoint must not match any bundled pricing entry " +
            "— on-device runs are free and should never show a non-zero cloud cost")
    }

    /// ModelBreakdown.displayName for the local checkpoint must be a human-
    /// readable label rather than the raw HuggingFace checkpoint string.
    func testLocalCheckpointDisplayName() {
        let breakdown = ModelBreakdown(
            provider: "local",
            model: LocalModelDefaults.checkpoint,
            bucket: UsageBucket(calls: 3, inputTokens: 1000, outputTokens: 200, costUSD: 0)
        )
        XCTAssertFalse(breakdown.displayName.contains("/"),
            "displayName for the local checkpoint must not expose the raw org/model path")
        XCTAssertFalse(breakdown.displayName.isEmpty,
            "displayName for the local checkpoint must not be empty")
    }

    // MARK: - LocalModelStore.onStateChanged transitions (Task 12)

    /// `onStateChanged` must NOT fire during `init` — the initial state is
    /// established synchronously without triggering the callback.
    @MainActor
    func testOnStateChangedNotCalledOnInit() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fired = false
        let store = LocalModelStore(checkpoint: "org/test-model", rootDirectory: tmp)
        store.onStateChanged = { _ in fired = true }
        XCTAssertFalse(fired, "onStateChanged must not fire during init")
        XCTAssertEqual(store.state, .notDownloaded)
    }

    /// `remove()` must transition the store to .notDownloaded and fire
    /// `onStateChanged(.notDownloaded)` — even when called on a store that
    /// is already in .notDownloaded (idempotent remove).
    @MainActor
    func testOnStateChangedFiresOnRemove() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Seed a ready marker so init resolves to .ready.
        let dirName = "org--ready-model"
        let modelDir = tmp.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data().write(to: modelDir.appendingPathComponent(".parleq-ready"))

        let store = LocalModelStore(checkpoint: "org/ready-model", rootDirectory: tmp)
        XCTAssertEqual(store.state, .ready, "seeded store must start in .ready")

        var receivedStates: [LocalModelStore.State] = []
        store.onStateChanged = { receivedStates.append($0) }

        store.remove()

        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertEqual(receivedStates, [.notDownloaded],
            "remove() must fire exactly one .notDownloaded transition")
    }

    /// `download()` with an invalid checkpoint (no slash → `Repo.ID(rawValue:)`
    /// returns nil) must fire `.downloading(progress: 0)` synchronously, then
    /// `.failed(…)` asynchronously before returning from the internal task.
    @MainActor
    func testOnStateChangedFiresDownloadingThenFailedForInvalidCheckpoint() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // "no-slash" has no "/" so Repo.ID(rawValue:) returns nil → fast .failed path.
        let store = LocalModelStore(checkpoint: "no-slash", rootDirectory: tmp)
        XCTAssertEqual(store.state, .notDownloaded)

        var receivedStates: [LocalModelStore.State] = []
        store.onStateChanged = { receivedStates.append($0) }

        store.download()

        // .downloading(progress: 0) fires synchronously inside download().
        XCTAssertEqual(receivedStates.first, .downloading(progress: 0),
            "download() must immediately fire .downloading before the async task runs")

        // Poll for the .failed transition. The guard fires before any network
        // call so this is fast, but a bounded loop is more robust than a fixed
        // yield count if extra suspension points are added in future.
        for _ in 0..<50 {
            await Task.yield()
            if case .failed = receivedStates.last { break }
        }

        // Exactly two state transitions: .downloading(0) then .failed.
        // The Repo.ID guard is synchronous so no extra intermediate states
        // can be injected between them.
        XCTAssertEqual(receivedStates.count, 2,
            "download() with an invalid checkpoint must fire exactly .downloading then .failed")
        XCTAssertEqual(receivedStates.first, .downloading(progress: 0),
            "first state must be .downloading(progress: 0)")
        if case .failed = receivedStates.last {
            // Expected: Repo.ID guard returned nil → .failed.
        } else {
            XCTFail("last state must be .failed, got \(String(describing: receivedStates.last))")
        }
    }
}
