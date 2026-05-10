// SidecarSupervisor — launches and monitors the bundled FluidAudio
// sidecar (the HTTP server hosting the Nemotron streaming ASR model).
//
// Lifecycle:
//   1. start() locates the sidecar binary inside the .app bundle's
//      Resources/sidecar/ directory. If running from `swift run`
//      (no .app bundle), there's nothing to launch — the supervisor
//      becomes a no-op and the user is expected to have started a
//      sidecar manually. This keeps development workflows working.
//   2. The child process inherits its own session and writes
//      stdout/stderr to /tmp/parleq-sidecar.log so a developer can
//      inspect FluidAudio's startup messages and any runtime
//      warnings (e.g. the Nemotron state-degradation symptoms we
//      saw earlier).
//   3. On unexpected termination, schedule a restart with exponential
//      backoff. After maxRestarts consecutive failures, give up so a
//      truly broken binary doesn't loop forever.
//   4. On app quit (NSApplication terminate), stop() is called from
//      the app delegate and the child gets SIGTERM — without this,
//      the sidecar would survive parent death and become an orphan
//      holding port 8767, breaking the next launch.
//
// External-sidecar coexistence: if the user has a manually-started
// sidecar already listening on port 8767, our launch will fail (port
// busy) and Hummingbird crashes immediately. The restart logic will
// loop forever. We handle this by health-checking up front: if a
// sidecar is already healthy, log "external sidecar detected" and
// skip launching ours.

import AppKit
import Foundation
import Security

@MainActor
final class SidecarSupervisor {
    private static let maxRestarts = 5
    private static let baseRestartDelaySeconds: TimeInterval = 1.0
    private static let logPath = "/tmp/parleq-sidecar.log"

    private var process: Process?
    private var restartTimer: Timer?
    private var consecutiveRestarts = 0
    /// True between start() and stop(). Used to distinguish a crash
    /// (restart it) from a clean shutdown (do nothing).
    private var shouldBeRunning = false
    /// True once /health has returned 200 at least once since the
    /// most recent (re)start. Flips to false again if /health stops
    /// responding (e.g. during a crash + restart cycle). The app
    /// gates first-capture intent on this so the user gets a clear
    /// "Initializing…" overlay instead of pressing the hotkey into
    /// a black hole during the sidecar's CoreML model-load window.
    private(set) var isReady = false {
        didSet {
            if oldValue != isReady { onReadyChanged?(isReady) }
        }
    }
    /// Fired when isReady transitions in either direction. The menu
    /// bar uses this to update its status line; AppState uses it to
    /// gate the hotkey behavior.
    var onReadyChanged: (@MainActor (Bool) -> Void)?
    private var readyPollTask: Task<Void, Never>?

    /// Random bearer token shared between Parleq and the bundled
    /// sidecar process. Generated once at app launch and passed to
    /// the spawned sidecar via the `PARLEQ_SIDECAR_TOKEN` env var.
    /// ASRClient sends it as `Authorization: Bearer <token>` on
    /// every `/inference` request; the sidecar rejects requests
    /// without it. Locks down the localhost endpoint so other
    /// processes running as the same user can't submit audio for
    /// transcription against the user's loaded models.
    /// 256 bits of entropy from SecRandomCopyBytes — plenty for a
    /// per-launch token that never crosses a process boundary
    /// outside the spawn-time env.
    let sidecarToken: String = SidecarSupervisor.generateToken()

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Extremely unlikely fallback path. UUIDs on Apple platforms
        // are cryptographically random; concatenate two for entropy
        // parity with the SecRandom path.
        let a = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let b = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return a + b
    }

    /// Resolve the bundled sidecar path. Returns nil if we're running
    /// from `swift run` (no Contents/Resources/sidecar/ in the
    /// resource path) or the binary isn't present. Caller is
    /// expected to fall back to whatever the user started manually.
    static func bundledSidecarPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let candidate = (resourcePath as NSString)
            .appendingPathComponent("sidecar/fluidaudio-sidecar")
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return candidate
    }

    /// When false, start() skips the bundled-sidecar launch entirely.
    /// Set by ParleqApp.main to false when the user has configured a
    /// custom asr.endpoint pointing at an external ASR server (e.g.
    /// a Sherpa-ONNX or faster-whisper Python server). Saves ~5 GB of
    /// resident memory we'd otherwise pay for the unused FluidAudio
    /// sidecar.
    var manageBundledSidecar = true

    func start() {
        guard manageBundledSidecar else {
            // Custom asr.endpoint: user owns their external server's
            // lifecycle (e.g. running a Sherpa-ONNX or faster-whisper
            // server from a terminal). Don't poll /health (that
            // endpoint is bundled-sidecar-specific) and skip warmup
            // (warmup also targets the bundled sidecar). Mark ready
            // immediately so the hotkey isn't gated; if the external
            // server isn't reachable, ASR calls will fail with a
            // clear connection-refused error in the logs.
            log("custom asr.endpoint configured; not managing bundled sidecar")
            isReady = true
            return
        }
        // Always start the readiness poller — it covers both the
        // bundled-launch path and the external-sidecar path. The
        // poller transitions isReady to true the first time /health
        // returns 200, and back to false if /health stops responding.
        startReadyPoll()
        guard let path = SidecarSupervisor.bundledSidecarPath() else {
            log("no bundled sidecar found (dev mode? swift run); assuming external instance")
            return
        }
        // Race-light external-sidecar detection. We do a synchronous
        // GET /health with a tight timeout. If it responds, an
        // existing sidecar is running and we step aside. If not, we
        // launch ours.
        if isHealthy() {
            log("external sidecar already healthy on port 8767; skipping bundled launch")
            return
        }
        shouldBeRunning = true
        consecutiveRestarts = 0
        launch(path: path)
    }

    func stop() {
        shouldBeRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        readyPollTask?.cancel()
        readyPollTask = nil
        guard let process = process else { return }
        process.terminationHandler = nil
        process.terminate()
        // Best-effort wait so the OS reclaims the port before our
        // app fully exits. waitUntilExit is blocking, so cap it.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            log("sidecar didn't exit in 2s; killing")
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
    }

    /// User-initiated restart from the menu bar. Cleanly kills the
    /// current sidecar process and launches a fresh one. Used to
    /// recover from FluidAudio Nemotron's state-degradation bug
    /// (#5) — long sessions silently stop emitting partials, and a
    /// fresh process is the only known fix until the upstream issue
    /// is resolved. isReady drops to false during the relaunch so
    /// the menu bar shows "Initializing…" and the next hotkey
    /// surfaces the init overlay until warmup completes.
    func restart() {
        log("manual restart requested")
        guard let path = SidecarSupervisor.bundledSidecarPath() else {
            log("no bundled sidecar; cannot restart from supervisor (dev mode?)")
            return
        }
        stop()
        // stop() flipped shouldBeRunning false + cancelled poll task;
        // re-arm everything for the new process.
        shouldBeRunning = true
        consecutiveRestarts = 0
        warmupCompleted = false
        warmupAttempts = 0
        if isReady { isReady = false }
        startReadyPoll()
        launch(path: path)
    }

    /// True after we've successfully run a warmup inference for the
    /// CURRENT sidecar process. Resets to false on every sidecar
    /// crash + restart so the next instance re-warms before we
    /// declare ready. Without this, /health alone said "ready" but
    /// the user's first real capture still ate a 10-15 s CoreML JIT
    /// compile delay because the encoder/decoder/joint graphs
    /// haven't been exercised yet.
    private var warmupCompleted = false
    /// Warmup attempts for the current sidecar process. Capped so we
    /// don't infinitely retry if the warmup itself crashes the
    /// sidecar — after maxWarmupAttempts we declare ready anyway and
    /// fall back to "first capture eats JIT" behavior, which is at
    /// least no worse than before this commit.
    private var warmupAttempts = 0
    private static let maxWarmupAttempts = 3

    /// Background task that polls /health every 0.5 s. The first
    /// time /health returns OK after a sidecar (re)start, kick off a
    /// warmup HTTP request to /inference with synthetic audio so
    /// the model's CoreML graphs JIT-compile before we tell the app
    /// that everything is ready. Runs for the supervisor's whole
    /// lifetime (start → stop).
    private func startReadyPoll() {
        readyPollTask?.cancel()
        readyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let healthy = await Self.healthCheckAsync()
                if !healthy {
                    // Sidecar went down (or hasn't come up yet).
                    // Reset readiness + warmup so the next time it
                    // comes back up, we re-warm before declaring OK.
                    await MainActor.run {
                        if self.isReady {
                            self.isReady = false
                            self.log("isReady → false (sidecar lost /health)")
                        }
                        self.warmupCompleted = false
                        self.warmupAttempts = 0
                    }
                } else {
                    // Sidecar is up. If we haven't warmed it up yet,
                    // do that now (or accept fallback after N tries).
                    let needsWarmup = await MainActor.run { !self.warmupCompleted }
                    if needsWarmup {
                        let attempts = await MainActor.run {
                            self.warmupAttempts += 1
                            return self.warmupAttempts
                        }
                        self.log("running warmup (attempt \(attempts)/\(SidecarSupervisor.maxWarmupAttempts))")
                        let token = self.sidecarToken
                        let ok = await Self.warmupAsync(token: token)
                        await MainActor.run {
                            if ok {
                                self.warmupCompleted = true
                                self.log("warmup ok; isReady → true")
                                self.isReady = true
                            } else if attempts >= SidecarSupervisor.maxWarmupAttempts {
                                // Give up and accept /health alone.
                                // The user will see a longer first
                                // capture, but at least the system
                                // isn't stuck "Initializing…" forever.
                                self.warmupCompleted = true
                                self.log("warmup failed \(attempts) times; declaring ready anyway (first capture may be slow)")
                                self.isReady = true
                            } else {
                                self.log("warmup attempt \(attempts) failed; will retry")
                            }
                        }
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func healthCheckAsync() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8767/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// POST a small sine-wave WAV to /inference so the sidecar's
    /// Parakeet TDT v3 batch pipeline runs at least once. CoreML
    /// JIT-compiles the encoder/decoder/joint graphs on first
    /// inference; this triggers that compile during the
    /// "Initializing…" UX so the user's first real capture is fast.
    ///
    /// Earlier builds warmed via /stream-nemo (the now-removed
    /// streaming Nemotron endpoint) — when the sidecar slim-down
    /// dropped that route, this had to switch to /inference. The
    /// wire format is identical to what Parleq's ASRClient uses
    /// during normal operation, so the warmup exercises the same
    /// code path.
    ///
    /// Sine wave (440 Hz) instead of silence: zero-amplitude inputs
    /// previously triggered a CoreML "ios17.slice_by_index: zero
    /// shape error" because the model decoded no tokens and some
    /// downstream slice op got a zero-sized tensor. A non-zero
    /// signal exercises the full graph cleanly.
    ///
    /// Returns true if the POST returned 200, false otherwise (which
    /// includes "sidecar crashed mid-warmup" — connection error).
    private static func warmupAsync(token: String) async -> Bool {
        let pcm = generateSineWavePCM(seconds: 1.0)
        let wav = wrapPCMInWAVHeader(pcm: pcm, sampleRate: 16000)
        guard let url = URL(string: "http://127.0.0.1:8767/inference") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        // Match ASRClient's auth shape so the supervisor's warmup
        // exercises the same code path real dictations use.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // 30 s is generous; warmup-with-JIT typically completes in
        // 10-15 s on first invocation.
        request.timeoutInterval = 30
        request.httpBody = wav
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Build a 44-byte WAV header in front of int16 LE PCM samples
    /// so the sidecar's /inference endpoint can find the "RIFF"
    /// marker and decode normally. Mirrors AudioRecorder.swift's
    /// writeWAV helper.
    private static func wrapPCMInWAVHeader(pcm: Data, sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let numChannels = 1
        let byteRate = sampleRate * numChannels * bytesPerSample
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize
        var header = Data(capacity: 44)
        header.append("RIFF".data(using: .ascii)!)
        header.append(uint32LE(UInt32(chunkSize)))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(uint32LE(16))
        header.append(uint16LE(1))                                  // PCM
        header.append(uint16LE(UInt16(numChannels)))
        header.append(uint32LE(UInt32(sampleRate)))
        header.append(uint32LE(UInt32(byteRate)))
        header.append(uint16LE(UInt16(numChannels * bytesPerSample)))
        header.append(uint16LE(16))                                 // bits per sample
        header.append("data".data(using: .ascii)!)
        header.append(uint32LE(UInt32(dataSize)))
        return header + pcm
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private static func generateSineWavePCM(
        seconds: Double,
        frequency: Double = 440,
        amplitude: Double = 2000
    ) -> Data {
        let sampleRate = 16_000
        let totalSamples = Int(Double(sampleRate) * seconds)
        var data = Data(count: totalSamples * 2)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<totalSamples {
                let t = Double(i) / Double(sampleRate)
                dst[i] = Int16(sin(2 * .pi * frequency * t) * amplitude).littleEndian
            }
        }
        return data
    }

    // MARK: - Internal

    private func launch(path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        // If the user has any dictionary entries configured, hint to
        // the sidecar that it should pre-load the CTC vocabulary
        // models on startup. Without this hint the sidecar lazy-loads
        // them on the first request that carries an
        // X-Parleq-Vocabulary header — fine in steady state but the
        // first dictation pays a ~97 MB download / load. Pre-loading
        // in parallel with the TDT load hides that cost.
        var env = ProcessInfo.processInfo.environment
        let dictionary = Config.load().config.customDictionary
        if !dictionary.isEmpty {
            env["PARLEQ_VOCAB_PRELOAD"] = "1"
        }
        // Bearer token for /inference auth. Locks the sidecar's
        // localhost endpoint to requests carrying this token, so
        // other local processes running as the same user can't
        // submit audio against the user's loaded models.
        env["PARLEQ_SIDECAR_TOKEN"] = sidecarToken
        // Parent-PID watch. The sidecar reads this and arms a
        // kqueue NOTE_EXIT watch on the supervisor process; if
        // Parleq crashes (SIGTRAP, SIGSEGV, etc.) without going
        // through applicationWillTerminate, the kernel notifies
        // the kqueue, the sidecar self-terminates, and port 8767
        // is freed before the user relaunches Parleq. Without
        // this, an orphaned sidecar holding 8767 with the old
        // bearer token causes the next launch's ASR calls to 401.
        env["PARLEQ_SUPERVISOR_PID"] = String(getpid())
        proc.environment = env
        // Direct stdout+stderr to a single log file. Append mode so
        // restarts add to the existing log instead of clobbering.
        let logURL = URL(fileURLWithPath: SidecarSupervisor.logPath)
        if !FileManager.default.fileExists(atPath: SidecarSupervisor.logPath) {
            FileManager.default.createFile(atPath: SidecarSupervisor.logPath, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            proc.standardOutput = handle
            proc.standardError = handle
        }
        // terminationHandler fires on a background queue; hop to
        // MainActor so we can mutate state safely.
        proc.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(finished) }
        }
        do {
            try proc.run()
            self.process = proc
            log("launched sidecar pid=\(proc.processIdentifier) (logging to \(SidecarSupervisor.logPath))")
        } catch {
            log("failed to launch sidecar: \(error)")
            scheduleRestart(path: path)
        }
    }

    private func handleTermination(_ finished: Process) {
        // If a stop() came in concurrently, ignore; we already
        // released the process.
        if !shouldBeRunning {
            log("sidecar terminated cleanly during shutdown")
            return
        }
        let status = finished.terminationStatus
        log("sidecar exited unexpectedly (status=\(status))")
        self.process = nil
        if let path = SidecarSupervisor.bundledSidecarPath() {
            scheduleRestart(path: path)
        }
    }

    private func scheduleRestart(path: String) {
        consecutiveRestarts += 1
        if consecutiveRestarts > SidecarSupervisor.maxRestarts {
            log("sidecar failed \(consecutiveRestarts) times in a row; giving up — manual restart required")
            shouldBeRunning = false
            return
        }
        // Exponential backoff: 1, 2, 4, 8, 16 seconds.
        let delay = SidecarSupervisor.baseRestartDelaySeconds
            * pow(2.0, Double(consecutiveRestarts - 1))
        log("restarting sidecar in \(Int(delay))s (attempt \(consecutiveRestarts)/\(SidecarSupervisor.maxRestarts))")
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: delay, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.launch(path: path) }
        }
    }

    /// Synchronous health check with a 500 ms timeout. Used at startup
    /// to detect an externally-launched sidecar so we don't fight it
    /// for port 8767.
    private func isHealthy() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8767/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                healthy = true
            }
            _ = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.6)
        return healthy
    }

    private func log(_ message: String) {
        if let data = "[parleq] sidecar: \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
