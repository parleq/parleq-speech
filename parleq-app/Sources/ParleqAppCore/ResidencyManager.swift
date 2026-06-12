// ResidencyManager — RAM-aware load/idle-unload policy for the on-device LLM.
//
// Two public surfaces:
//
//   ResidencyPolicy   — pure Equatable value, computed from (LocalResidency,
//                       RAMTier, configMinutes?). No I/O, trivially unit-testable.
//
//   ResidencyManager  — Swift actor that enforces the policy at runtime:
//                       lazy-loads the ModelContainer on first use, tracks active
//                       generation count, cancels/reschedules the idle-unload task
//                       on each use, and unloads when the idle deadline passes with
//                       no active generation.
//
// Load-call shape (ported from llm-proof/Sources/LLMProof/main.swift):
//
//   let container = try await LLMModelFactory.shared.loadContainer(
//       from: snapshotDirectory,
//       using: TransformersTokenizerLoader())
//
//   The tokenizer types (`TransformersTokenizerLoader`, `TransformersTokenizerBridge`)
//   live in LocalTokenizerBridge.swift — see that file for the port rationale.
//
// Lifetime note:
//   ResidencyManager is a process-lifetime singleton instantiated at app
//   startup. The idle-unload Task captures `self` strongly. This creates
//   a reference cycle (actor → Task → actor), but because the manager
//   lives for the entire process lifetime there is no leak — the cycle is
//   resolved at process exit. A comment below calls this out explicitly
//   instead of fighting the actor+weak pattern.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Policy

/// Pure, side-effect-free model residency policy.
///
/// `effective(residency:tier:configMinutes:)` maps the three config
/// dimensions to a concrete action. Tests cover every semantic corner;
/// no I/O occurs.
public enum ResidencyPolicy: Equatable, Sendable {
    /// Keep the model loaded indefinitely between dictations.
    case keepLoaded
    /// Unload the model after `minutes` of idle time.
    case unloadAfter(minutes: Int)

    /// Compute the effective policy.
    ///
    /// Priority order:
    ///   1. `.keep` residency → always `.keepLoaded`.
    ///   2. `configMinutes` override → `.unloadAfter(configMinutes)` for both
    ///      `.auto` and `.idle`.
    ///   3. RAM-tier default: cautioned / unsupported → 3 min; comfortable → 30 min.
    public static func effective(
        residency: LocalResidency,
        tier: RAMTier,
        configMinutes: Int?
    ) -> ResidencyPolicy {
        switch residency {
        case .keep:
            return .keepLoaded
        case .auto, .idle:
            if let minutes = configMinutes {
                return .unloadAfter(minutes: minutes)
            }
            return .unloadAfter(minutes: tier.defaultIdleMinutes)
        }
    }
}

// MARK: - RAMTier idle-minute defaults

private extension RAMTier {
    /// Idle-unload default for this tier, matching `LocalModelDefaults`.
    var defaultIdleMinutes: Int {
        switch self {
        case .unsupported, .cautioned:
            return LocalModelDefaults.idleUnloadMinutesCautioned   // 3
        case .comfortable:
            return LocalModelDefaults.idleUnloadMinutesComfortable // 30
        }
    }
}

// MARK: - ResidencyManager actor

/// Enforces the `ResidencyPolicy` for the on-device `ModelContainer`.
///
/// - Lazy load: the first `withModel` call loads the container from
///   `snapshotDirectory` using `LLMModelFactory.shared`.
/// - Active-generation guard: `activeGenerations` is incremented for
///   the duration of each `withModel` body. The idle-unload task checks
///   this count before unloading; if any generation is active it re-sleeps
///   until the next deadline.
/// - Cancellation-safe idle timer: each `withModel` completion cancels the
///   previous unload task and schedules a fresh one. A new use before the
///   deadline fires simply cancels the pending task.
/// - `.keepLoaded` policy: the idle-unload task is never created.
///
/// Lifetime: This actor is intended to be a process-lifetime singleton.
/// The idle-unload `Task` captures `self` strongly, forming a reference
/// cycle (actor → Task → actor). Because the manager lives until process
/// exit there is no practical leak — the cycle resolves at process exit.
/// Do not use this actor as a short-lived object without adding explicit
/// `unloadNow()` + task cancellation in the deinit path.
public actor ResidencyManager {

    // MARK: - Stored state

    private let snapshotDirectory: URL
    private let policy: ResidencyPolicy

    private var container: ModelContainer?
    private var activeGenerations: Int = 0
    /// Set when unloadNow() is called while a generation is in flight; the
    /// generation's defer drops the container as soon as activeGenerations
    /// reaches zero, so "Remove model" frees memory promptly even mid-cleanup
    /// (and even under .keepLoaded) instead of waiting for the idle timer.
    private var pendingUnload: Bool = false
    private var lastUse: Date = .distantPast
    private var idleUnloadTask: Task<Void, Never>?

    /// In-flight container load, shared by all callers. The first caller to
    /// observe `container == nil && loadTask == nil` creates this task; every
    /// concurrent caller (warm + dictation, or two dictations) awaits the SAME
    /// task instead of starting a second ~6 GB load. See `acquireContainer()`
    /// for the reentrancy-safety reasoning (the assignment must happen before
    /// the first suspension so reentrant callers observe it).
    private var loadTask: Task<ModelContainer, Error>?

    /// Monotonic identity for the loaded container. Incremented every time a
    /// fresh container is stored. A holder can capture the epoch before a
    /// suspension and verify it is unchanged afterwards to confirm the same
    /// container is still loaded (used to guard the prefix-cache insert).
    private var containerEpoch: UInt64 = 0

    /// KV prefix cache (Task 9). Maps a (checkpoint, system-prefix hash) key to
    /// the KV state produced by prefilling ONLY that system-prompt prefix. On a
    /// hit we clone the cached state and extend the clone with the per-utterance
    /// user suffix — never mutating the shared copy. The cache holds GPU memory,
    /// so it is dropped whenever the container is (idle unload / unloadNow).
    ///
    /// Lives inside the actor's isolation, alongside `container`: the cached
    /// `[KVCache]` is non-Sendable (MLXArray-backed) and must never escape this
    /// isolation except as a freshly-cloned copy handed into a `perform` body.
    ///
    /// INVARIANT: every entry holds system-prefix KV state ONLY. No
    /// user/assistant turn is ever prefilled into a cached entry (HARD
    /// INVARIANT #5). The build path prefills exactly the system-only render.
    private var prefixCache = PrefixCacheLRU<PrefixCacheEntry>(
        capacity: LocalModelDefaults.prefixCacheCapacity)

    /// Whether a KV prefix cache entry is currently held (for tests / probes).
    public var hasPrefixCache: Bool { prefixCache.count > 0 }

    // MARK: - Init

    /// Designated initialiser.
    ///
    /// `store` is `@MainActor`-isolated. We capture only the stable URL it
    /// exposes (`snapshotDirectory`) at init time via a synchronous `MainActor`
    /// accessor — callers must `await` this init from a `MainActor` context or
    /// use `Task { @MainActor in … }` to ensure the store is ready.
    ///
    /// Design choice: capturing the URL rather than a reference to the store
    /// avoids holding a cross-isolation reference to a `@MainActor` object
    /// inside the actor's isolated storage, sidestepping Sendable friction.
    /// The init is `@MainActor` so the store's `snapshotDirectory` (a
    /// `@MainActor`-isolated property) can be read synchronously at init time.
    @MainActor
    public init(store: LocalModelStore, policy: ResidencyPolicy) {
        self.snapshotDirectory = store.snapshotDirectory
        self.policy = policy
    }

    // MARK: - Public interface

    /// Whether a `ModelContainer` is currently loaded.
    public var isLoaded: Bool { container != nil }

    /// Execute `body` with a guaranteed-live `ModelContainer`.
    ///
    /// - Loads the container on first call (or after an idle unload).
    /// - Increments `activeGenerations` for the lifetime of `body` so
    ///   the idle timer cannot unload the model mid-generation.
    /// - After `body` returns, schedules (or refreshes) the idle-unload
    ///   task according to the policy. `.keepLoaded` skips scheduling.
    public func withModel<T: Sendable>(
        _ body: @Sendable (ModelContainer) async throws -> T
    ) async throws -> T {
        // Ensure the container is loaded (coalesced — see acquireContainer()).
        let container = try await acquireContainer()

        // Guard the generation so idle-unload knows the model is in use.
        activeGenerations += 1
        lastUse = Date()

        // Cancel any pending idle-unload — we are about to use the model.
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        defer {
            activeGenerations -= 1
            lastUse = Date()
            if activeGenerations == 0 && pendingUnload {
                // A remove()/unloadNow() arrived mid-generation — honor it now.
                pendingUnload = false
                dropContainerAndPrefixCache()
            } else {
                scheduleIdleUnloadIfNeeded()
            }
        }

        return try await body(container)
    }

    /// Immediately unload the model container (for tests and UI "Free memory").
    ///
    /// No-op if no generation is currently active (does not interrupt an
    /// in-flight `withModel` body — the container is not cleared until the
    /// body finishes and `activeGenerations` drops to zero).
    public func unloadNow() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard activeGenerations == 0 else {
            // A generation is in flight — defer the drop to its completion
            // so we don't tear the container out from under it.
            pendingUnload = true
            return
        }
        pendingUnload = false
        dropContainerAndPrefixCache()
    }

    /// Drop the container AND the KV prefix cache together. The cached KV state
    /// is GPU-resident and is only valid for the loaded container, so the two
    /// must always be released as a unit — never leave a prefix cache alive
    /// after the model it was prefilled against has been unloaded.
    private func dropContainerAndPrefixCache() {
        // Nothing loaded → nothing to free. Skip the Metal-pool flush and the log
        // line so a cold launch (state == .notDownloaded → unloadNow()) doesn't
        // run Memory.clearCache() on an empty pool and emit a spurious
        // "unloaded model (gpu cache 0 MB → 0 MB)" line every time. The real
        // remove-while-loaded path (container != nil) still frees + logs.
        guard container != nil else { return }
        container = nil
        // Bump the epoch so any holder that captured the prior epoch (e.g.
        // warmPrefix) detects the container is gone and refuses to bind a
        // prefix-cache entry to it.
        containerEpoch &+= 1
        // Releasing the boxes drops the only strong references to the cached
        // MLXArray-backed KV state, freeing the GPU memory it holds.
        prefixCache.removeAll()
        // Returns the Metal buffer pool to the OS; without this, container = nil
        // leaves ~6 GB of GPU pages cached until system memory pressure —
        // breaking the user-facing "frees the memory after a few minutes" promise.
        let cacheBefore = Memory.cacheMemory / (1024 * 1024)
        Memory.clearCache()
        let cacheAfter = Memory.cacheMemory / (1024 * 1024)
        logStderr("[parleq] local: unloaded model (gpu cache \(cacheBefore) MB → \(cacheAfter) MB)")
    }

    // MARK: - Private helpers

    /// Coalesced container acquisition. ALL load paths (warm + generation) go
    /// through here so at most one ~6 GB load is ever in flight.
    ///
    /// Reentrancy-safety reasoning (the whole point of this method):
    /// `ResidencyManager` is an actor, so its methods are reentrant across
    /// `await` — while one caller is suspended inside `loadContainer()`, another
    /// caller can run. The old `if container == nil { container = await load() }`
    /// pattern let BOTH callers observe `container == nil` and each start a load,
    /// producing two simultaneous ~6 GB models (≈12 GB spike → OOM risk).
    ///
    /// Here the deciding read (`container`, `loadTask`) and the `loadTask`
    /// assignment all execute SYNCHRONOUSLY within a single actor-isolated region
    /// — there is no `await` between observing `loadTask == nil` and storing the
    /// new `loadTask`. Actor reentrancy can only interleave another caller at an
    /// `await` suspension point; because the create-and-store happens with no
    /// intervening suspension, a second caller that runs later is guaranteed to
    /// see the already-stored `loadTask` and join it rather than starting a
    /// second load. Only the `await task.value` (and the post-await bookkeeping)
    /// run after a suspension, and by then the shared task is visible.
    private func acquireContainer() async throws -> ModelContainer {
        if let container { return container }

        // Join an in-flight load if one exists.
        if let loadTask {
            return try await loadTask.value
        }

        // Start the single shared load. The assignment below happens with no
        // intervening `await`, so any reentrant caller observes this `loadTask`.
        let task = Task { try await loadContainer() }
        loadTask = task
        do {
            let c = try await task.value
            // First completer wins the store; subsequent joiners re-read the
            // already-set `container` on their own resumption. Guard against a
            // unloadNow()/idle-unload that may have raced in while suspended:
            // only adopt this result if nothing else is loaded.
            if container == nil {
                container = c
                containerEpoch &+= 1
            }
            loadTask = nil
            // Return the live container (a concurrent drop could theoretically
            // have nulled it; fall back to the freshly-loaded `c` so the caller
            // always gets a usable container for this acquisition).
            return container ?? c
        } catch {
            // Load failed: clear the shared task so a later caller can retry,
            // then propagate. This catch runs synchronously after `task.value`
            // throws, with no intervening `await`, so no concurrent caller can
            // have swapped in a different `loadTask` between the resumption and
            // this clear — `loadTask` is still the task we stored above.
            loadTask = nil
            throw error
        }
    }

    private func loadContainer() async throws -> ModelContainer {
        // TODO(upstream-gemma4): register the KV-shared-aware vendored Gemma 4
        // text model OVER the factory's stock "gemma4" type before the first
        // load. The pinned mlx-swift-lm (b95dc78) creates k/v projections
        // unconditionally for all layers and cannot load the canonical Gemma 4
        // QAT checkpoint (which omits them for the KV-shared layers); the fix
        // has not merged upstream. See VendoredGemma4Text.swift for the full
        // mechanism + provenance. Remove this call (and the vendored file) once
        // upstream ships the gating fix and the pin is bumped.
        //
        // The QAT checkpoint's top-level config.json has model_type "gemma4",
        // so _load(from:) dispatches via that key → our creator decodes the
        // multimodal config, extracts text_config, and builds a text-only
        // VendoredGemma4Model. registerModelType overwrites the existing entry
        // on this shared factory instance; calling it again is harmless
        // (idempotent — it just re-stores the same closure).
        await Self.registerVendoredGemma4IfNeeded()

        print("[ResidencyManager] loading model from \(snapshotDirectory.lastPathComponent)")
        let c = try await LLMModelFactory.shared.loadContainer(
            from: snapshotDirectory,
            using: TransformersTokenizerLoader())
        print("[ResidencyManager] model loaded")
        // Bound MLX's retained Metal free-buffer pool while the model stays
        // loaded, so phys_footprint sits near the honest weights floor (~6–7 GB)
        // instead of ballooning to ~10 GB after a generation peak. Set once per
        // load (not per generation); additive to — never a replacement for —
        // idle-unload + clearCache(), which fully releases the pool on drop.
        // The C setter reports the previous limit, so we can log the change
        // (count-only — no model/transcript content).
        let previousLimitMB = Memory.cacheLimit / (1024 * 1024)
        // PARLEQ_GPU_CACHE_MB: measurement/tuning override (MB). Lets the
        // footprint↔latency sweep pick a value without rebuilding. Falls back
        // to the shipped default when unset/invalid.
        let limitBytes: Int = {
            if let mb = ProcessInfo.processInfo.environment["PARLEQ_GPU_CACHE_MB"],
               let v = Int(mb), v >= 0 {
                return v * 1024 * 1024
            }
            return LocalModelDefaults.gpuCacheLimitBytes
        }()
        Memory.cacheLimit = limitBytes
        logStderr(
            "[parleq] local: gpu cache limit \(previousLimitMB) MB → " +
            "\(limitBytes / (1024 * 1024)) MB")
        return c
    }

    /// TODO(upstream-gemma4): register the vendored KV-shared-aware Gemma 4 text
    /// model over the factory's "gemma4" type. Idempotent. Remove on upstream merge.
    private static func registerVendoredGemma4IfNeeded() async {
        await LLMModelFactory.shared.typeRegistry.registerModelType("gemma4") { data in
            let configuration = try JSONDecoder.json5().decode(
                VendoredGemma4Configuration.self, from: data)
            return VendoredGemma4Model(configuration)
        }
    }

    private func scheduleIdleUnloadIfNeeded() {
        guard case .unloadAfter(let minutes) = policy else { return }
        let deadline = lastUse.addingTimeInterval(Double(minutes) * 60)

        // Cancel any previous unload task before creating a new one.
        idleUnloadTask?.cancel()

        // Strong capture is intentional — see lifetime note in the file header.
        idleUnloadTask = Task {
            do {
                let sleepNs = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
                try await Task.sleep(nanoseconds: sleepNs)
            } catch {
                // Cancelled — a new use or unloadNow() fired; do nothing.
                return
            }
            // Re-check: if a generation is in flight, reschedule rather than
            // unloading.
            if activeGenerations > 0 {
                scheduleIdleUnloadIfNeeded()
                return
            }
            // Decide based on actual idleness, not on how punctual the wake was.
            // The task may wake late (memory pressure, system sleep); a late wake
            // must NOT silently drop the timer — that would pin the model resident
            // forever. Recompute the idle deadline from the current lastUse:
            //   - If lastUse moved forward (a use landed after this task was
            //     scheduled) but we're still inside the idle window, RESCHEDULE
            //     for the remaining time.
            //   - Otherwise the model has been genuinely idle for the full
            //     interval — UNLOAD, regardless of how late the wake was.
            let idleInterval = Double(minutes) * 60
            let idleDeadline = lastUse.addingTimeInterval(idleInterval)
            if idleDeadline.timeIntervalSinceNow > 0 {
                // A newer use moved the deadline forward; wait out the remainder.
                scheduleIdleUnloadIfNeeded()
                return
            }
            // Idle for the full interval — unload. Drops the KV prefix cache too;
            // it holds GPU memory and is only valid for this now-unloaded container.
            dropContainerAndPrefixCache()
            print("[ResidencyManager] idle unload after \(minutes)m (+ prefix cache)")
        }
    }

    /// Warm the KV prefix cache for a system prompt off the hot path.
    ///
    /// Called at launch (provider == local) and on prefix-hash change so the
    /// first real dictation hits a warm cache. Loads the container if needed and
    /// prefills the system prefix into a cached entry. Best-effort: any failure
    /// (model not ready, render shape, OOM) is swallowed — a cold first
    /// dictation simply pays the uncached prefill, exactly as before. NEVER call
    /// this on the dictation hot path; spawn it at low QoS.
    ///
    /// No-op if an entry for this prefix is already cached.
    ///
    /// `parameters` must match the GenerateParameters used by streamCleanup's
    /// live path: models whose newCache varies by parameters (e.g. rotating-
    /// window size) would build structurally incompatible caches if warm and live
    /// diverge. Pass nil here when streamCleanup passes nil, or pass the same
    /// params when streamCleanup passes non-nil — the two call sites must agree.
    public func warmPrefix(
        checkpoint: String,
        systemPrompt: String,
        parameters: GenerateParameters? = nil
    ) async {
        let key = SystemPrefixCacheKey(checkpoint: checkpoint, prefixText: systemPrompt)
        if prefixCache.contains(key) { return }

        // Participate in the use/idle protocol exactly like the generation path:
        // mark active use and cancel any pending idle-unload BEFORE the awaits so
        // an idle-unload task cannot null `container` (and drop the prefix cache)
        // while we are prefilling against it. The defer mirrors withModel:
        // decrement and reschedule the idle timer.
        activeGenerations += 1
        lastUse = Date()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        defer {
            activeGenerations -= 1
            lastUse = Date()
            if activeGenerations == 0 && pendingUnload {
                // A remove()/unloadNow() arrived mid-generation — honor it now.
                pendingUnload = false
                dropContainerAndPrefixCache()
            } else {
                scheduleIdleUnloadIfNeeded()
            }
        }

        do {
            // Coalesced load (shared with the dictation path — never double-loads).
            let container = try await acquireContainer()
            // Capture the epoch of the container we are about to prefill against,
            // so the final insert can verify it is still the same one.
            let builtEpoch = containerEpoch

            // Render system-only tokens and prefill them into a fresh cache.
            let ac = AdditionalContextBox(["enable_thinking": false])
            let systemTokens: [Int] = try await container.perform { [ac] context in
                guard let bridge = context.tokenizer as? TransformersTokenizerBridge else {
                    return []
                }
                return try bridge.renderTemplate(
                    messages: [["role": "system", "content": systemPrompt]],
                    addGenerationPrompt: false,
                    additionalContext: ac.value)
            }
            guard !systemTokens.isEmpty else { return }

            let built = try await container.perform { [systemTokens, parameters] context in
                // Use the same `parameters` as streamCleanup's miss path so the
                // two newCache() calls produce structurally compatible cache objects.
                let cache = context.model.newCache(parameters: parameters)
                let input = LMInput(tokens: MLXArray(systemTokens))
                let result = try context.model.prepare(input, cache: cache, windowSize: nil)
                if case .tokens(let remainder) = result, remainder.tokens.size > 0 {
                    _ = context.model(remainder[.newAxis], cache: cache, state: nil)
                }
                eval(cache)
                return KVCacheBox(cache)
            }
            // Ownership guard: only store the entry if it still belongs to the
            // container we prefilled against. Holding an active-use count already
            // prevents idle-unload from running mid-warm, but this is the
            // belt-and-suspenders check mirroring the rest of the file — if the
            // container was replaced (epoch moved), the built KV state is bound to
            // a torn-down container, so drop it rather than caching a dangling entry.
            guard containerEpoch == builtEpoch, container === self.container else {
                return
            }
            prefixCache.insert(key, PrefixCacheEntry(cache: built))
            print("[ResidencyManager] warmed prefix cache (\(systemTokens.count) tokens)")
        } catch {
            // Best-effort: swallow. Next dictation just prefills uncached.
            return
        }
    }

    /// Warm the cleanup-prompt prefix for the given dictionary, off the hot
    /// path. Convenience over `warmPrefix` that builds the exact cleanup system
    /// prompt the dictation path will use (`SystemPrompts.cleanup`, no transform
    /// — per-app preset transforms warm lazily on first use). Best-effort.
    public func warmCleanupPrefix(checkpoint: String, dictionary: [DictionaryEntry]) async {
        let prompt = SystemPrompts.cleanup(dictionary: dictionary, transform: nil)
        await warmPrefix(checkpoint: checkpoint, systemPrompt: prompt)
    }

    // MARK: - KV prefix-cache generation (Task 9)

    /// Stream a cleanup/refine generation, reusing a cached system-prompt KV
    /// prefix when one is available.
    ///
    /// Mechanism (the on-device TTFT win):
    ///   1. Render the system prefix ALONE (`add_generation_prompt: false`) and
    ///      the full system+user prompt (`add_generation_prompt: true`) through
    ///      the model's own chat template.
    ///   2. On a cache hit for the system prefix, CLONE the cached `[KVCache]`
    ///      (a deep copy of every per-layer cache — Standard + Rotating) and
    ///      prefill only the USER suffix onto the clone. On a miss, prefill the
    ///      system prefix once into a fresh cache, store it, then clone for use.
    ///   3. The shared cached copy is never mutated; the clone is discarded
    ///      after the call. No user/assistant turn is ever written into a cached
    ///      entry (HARD INVARIANT #5).
    ///
    /// Safety: before reusing any cached state we assert the system-only render
    /// is a token-exact PREFIX of the full render. If the tokenizer ever
    /// produced a non-prefix (e.g. a template that folds the system text into
    /// the user turn), we fall back to a plain full-prompt prefill — never
    /// splice mismatched KV state (which would corrupt output).
    ///
    /// `onChunk`/`onSummary` are invoked from inside the model isolation as the
    /// stream produces text and completes. `inputTokens` reported to the
    /// summary is the FULL prompt length (system + user), not the suffix.
    ///
    /// - Returns: time-to-first-chunk (seconds from `started`) or nil if no
    ///   visible text was produced.
    public func streamCleanup(
        checkpoint: String,
        systemPrompt: String,
        turns: [(role: String, text: String)],
        params: GenerateParameters,
        additionalContext: [String: any Sendable],
        started: Date,
        onChunk: @Sendable (String) -> Void,
        onSummary: @Sendable (_ firstChunkAt: TimeInterval?, _ inputTokens: Int, _ outputTokens: Int) -> Void
    ) async throws {
        // Container + idle-guard bookkeeping (mirrors withModel).
        let container = try await acquireContainer()

        activeGenerations += 1
        lastUse = Date()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        defer {
            activeGenerations -= 1
            lastUse = Date()
            if activeGenerations == 0 && pendingUnload {
                // A remove()/unloadNow() arrived mid-generation — honor it now.
                pendingUnload = false
                dropContainerAndPrefixCache()
            } else {
                scheduleIdleUnloadIfNeeded()
            }
        }

        // --- 1. Render system-only and full prompts to token ids. ---
        // Both renders run inside the model isolation (the tokenizer/processor
        // are not Sendable). Token-id arrays ARE Sendable, so they cross back
        // out cleanly. The additionalContext (enable_thinking: false) is applied
        // at render time, exactly as the live ChatSession path does.
        let acBox = AdditionalContextBox(additionalContext)
        let rendered: RenderedPrompts = try await container.perform { [acBox] context in
            guard let bridge = context.tokenizer as? TransformersTokenizerBridge else {
                // Unknown tokenizer shape — signal "no cache" so the caller uses
                // the uncached path. Should not happen with our loader.
                return RenderedPrompts(system: [], full: [], cacheable: false)
            }
            let ac = acBox.value

            let systemTokens = try bridge.renderTemplate(
                messages: [["role": "system", "content": systemPrompt]],
                addGenerationPrompt: false,
                additionalContext: ac)

            var fullMessages: [[String: any Sendable]] = [
                ["role": "system", "content": systemPrompt]
            ]
            for turn in turns {
                let role = (turn.role == "assistant" || turn.role == "model") ? "model" : "user"
                fullMessages.append(["role": role, "content": turn.text])
            }
            let fullTokens = try bridge.renderTemplate(
                messages: fullMessages,
                addGenerationPrompt: true,
                additionalContext: ac)

            // The cache is only usable if the system render is a strict,
            // non-empty token prefix of the full render.
            let cacheable =
                !systemTokens.isEmpty
                && systemTokens.count < fullTokens.count
                && Array(fullTokens.prefix(systemTokens.count)) == systemTokens
            return RenderedPrompts(system: systemTokens, full: fullTokens, cacheable: cacheable)
        }

        // --- 2. Resolve a cloned prefix cache (build on miss), or nil. ---
        let key = SystemPrefixCacheKey(checkpoint: checkpoint, prefixText: systemPrompt)
        var clonedCache: KVCacheBox? = nil
        if rendered.cacheable {
            let systemTokens = rendered.system
            if let entry = prefixCache.get(key) {
                // Hit: clone the shared cached state (deep copy, inside isolation).
                let box = entry.cache
                clonedCache = await container.perform { [box] _ in
                    KVCacheBox(box.value.map { $0.copy() })
                }
            } else {
                // Miss: prefill ONLY the system prefix into a fresh cache, eval,
                // store the shared copy, then clone for this call.
                let built = try await container.perform { [systemTokens] context in
                    let cache = context.model.newCache(parameters: params)
                    let input = LMInput(tokens: MLXArray(systemTokens))
                    // Default LLMModel.prepare consumes all but the trailing
                    // chunk; feed that remainder through the model so the entire
                    // system prefix lands in the cache (offset == systemTokens.count).
                    let result = try context.model.prepare(
                        input, cache: cache, windowSize: nil)
                    if case .tokens(let remainder) = result, remainder.tokens.size > 0 {
                        _ = context.model(
                            remainder[.newAxis], cache: cache, state: nil)
                    }
                    eval(cache)
                    return KVCacheBox(cache)
                }
                let entry = PrefixCacheEntry(cache: built)
                prefixCache.insert(key, entry)
                // Clone the freshly-stored shared copy for this call so we never
                // mutate the cached entry during generation.
                let sharedBox = built
                clonedCache = await container.perform { [sharedBox] _ in
                    KVCacheBox(sharedBox.value.map { $0.copy() })
                }
            }
        }

        // --- 3. Generate. ---
        let fullTokens = rendered.full
        // Authoritative split point: the system-prefix token count. We already
        // asserted (step 1, `cacheable`) that fullTokens.prefix(prefixCount) is
        // exactly the cached system tokens, so feeding fullTokens[prefixCount...]
        // onto the cloned cache extends it with precisely the user + generation
        // -prompt tokens — no overlap, no gap, no duplicate <bos>.
        let prefixCount = rendered.system.count
        let cacheBox = clonedCache  // nil → plain full prefill (cache miss / non-cacheable)
        try await container.perform { [cacheBox, fullTokens, prefixCount] context in
            // With a prefix cache we feed only the USER suffix (the tokens after
            // the cached system prefix); without one we feed the full prompt.
            let promptTokens: [Int]
            let seedCache: [KVCache]?
            if let cacheBox {
                promptTokens = Array(fullTokens.suffix(fullTokens.count - prefixCount))
                seedCache = cacheBox.value
            } else {
                promptTokens = fullTokens
                seedCache = nil
            }

            let input = LMInput(tokens: MLXArray(promptTokens))
            var first: TimeInterval?
            var genCount = 0

            let stream = try generate(
                input: input, cache: seedCache, parameters: params, context: context)
            for await item in stream {
                switch item {
                case .chunk(let text):
                    if !text.isEmpty {
                        if first == nil { first = Date().timeIntervalSince(started) }
                        onChunk(text)
                    }
                case .info(let info):
                    genCount = info.generationTokenCount
                case .toolCall:
                    break
                }
            }
            // Report the FULL prompt length as inputTokens for accurate
            // accounting (the stream's own promptTokenCount would be suffix-only
            // on a cache hit).
            onSummary(first, fullTokens.count, genCount)
        }
    }
}

// MARK: - KV prefix-cache support types

/// Boxes a non-Sendable `[KVCache]` so it can be carried across `perform`
/// isolation boundaries and held in actor-isolated storage. The KV state is
/// only ever produced/consumed inside the model isolation; this box is the
/// transport, not a shared-mutation seam.
final class KVCacheBox: @unchecked Sendable {
    let value: [KVCache]
    init(_ value: [KVCache]) { self.value = value }
}

/// One LRU entry: the SHARED system-prefix KV state.
/// `@unchecked Sendable` because `[KVCache]` is reference-typed MLX state held
/// only inside the actor; clones (not this shared copy) are what get mutated.
final class PrefixCacheEntry: @unchecked Sendable {
    let cache: KVCacheBox
    init(cache: KVCacheBox) {
        self.cache = cache
    }
}

/// Carries the model-specific `additionalContext` (e.g. enable_thinking:false)
/// across a `perform` boundary. The dictionary's values are `any Sendable`, so
/// the box is a checked Sendable.
struct AdditionalContextBox: @unchecked Sendable {
    let value: [String: any Sendable]
    init(_ value: [String: any Sendable]) { self.value = value }
}

/// Result of rendering the two prompts. `cacheable` is false when the system
/// render is not a strict token prefix of the full render (fail-safe → uncached).
private struct RenderedPrompts: Sendable {
    let system: [Int]
    let full: [Int]
    let cacheable: Bool
}

// MARK: - Errors

public enum ResidencyError: Error {
    case containerUnavailable
}

// MARK: - Logging

/// File-private stderr sink so ResidencyManager log lines land in app.log when
/// running under `open` (non-TTY), matching the pattern used by LocalASR and other
/// modules. The existing `print()` calls throughout this file target TTY/developer
/// mode (stdout, not captured by LogFile.install). This helper routes to stderr so
/// idle-unload events appear in the persisted log for users and support.
private func logStderr(_ message: String) {
    let stderr = Foundation.FileHandle.standardError
    if let data = (message + "\n").data(using: .utf8) {
        stderr.write(data)
    }
}
