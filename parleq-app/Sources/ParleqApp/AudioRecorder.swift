// AudioRecorder — captures microphone audio between start() and stop()
// and writes it as a 16-bit mono 16 kHz WAV file.
//
// AVAudioEngine's input node delivers audio at the hardware's native
// sample rate and channel count (typically 44.1 / 48 kHz, 1 or 2
// channels) in Float32. The FluidAudio sidecar's /inference endpoint
// expects 16-bit signed LE mono at 16 kHz. We use AVAudioConverter
// to downsample / channel-mix / requantize each buffer in-line, then
// accumulate the resulting int16 samples until stop(), where we
// write a single .wav file with a standard 44-byte header.
//
// Real-time pacing for streaming ASR isn't relevant in M1 — we're
// using batch /inference. M4 introduces the streaming client; the
// audio capture here is still useful for that path because the same
// PCM samples can be streamed instead of accumulated.
//
// macOS asks for microphone permission the first time AVAudioEngine
// starts. The system dialog attributes the request to the parent
// process (Terminal during `swift run` development, the app bundle
// at distribution time).

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioRecorderError: Error, CustomStringConvertible {
    case converterCreateFailed
    case engineStartFailed(Error)
    case writeFailed(Error)

    var description: String {
        switch self {
        case .converterCreateFailed:
            return "AVAudioConverter init failed (input/output format mismatch?)"
        case .engineStartFailed(let underlying):
            return "AVAudioEngine.start failed: \(underlying)"
        case .writeFailed(let underlying):
            return "WAV write failed: \(underlying)"
        }
    }
}

final class AudioRecorder {
    private static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var accumulated: [Int16] = []
    private var isRunning = false
    /// When set, every captured-and-resampled int16 PCM chunk is
    /// also pushed to this callback in addition to being buffered
    /// for the WAV write at stop(). Used by the streaming ASR path
    /// (StreamingASRSession) to forward chunks to the sidecar in
    /// real time. Set to nil for batch-only mode.
    var chunkHandler: (@Sendable (Data) -> Void)?

    /// When set, every audio buffer's normalized RMS level (0…1, after
    /// dBFS clamp/expand) is pushed here so the overlay can drive a
    /// live sound-wave visualization during capture. Called from the
    /// AVAudioEngine tap thread; the handler must hop to MainActor
    /// before touching SwiftUI state. Set to nil for headless capture.
    var levelHandler: (@Sendable (Float) -> Void)?

    /// When true, before starting capture we switch the engine's
    /// input device to the built-in mic if (and only if) the system
    /// default input is Bluetooth. This keeps BT headphones in A2DP
    /// so any audio currently playing through them isn't pulled into
    /// HFP/SCO (which sounds like the music briefly pausing and
    /// changing quality). Wired from Config.continueOtherAudio.
    /// Only consulted when no explicit device is selected.
    var continueOtherAudio: Bool = true

    /// User's explicit microphone choice, persisted as a Core Audio
    /// device UID (e.g. "BuiltInMicrophoneDevice", "AppleHDAEngineInput:1B,0,1,0:1",
    /// "94:db:c9:ab:cd:ef:input"). Empty string means "System Default
    /// + auto-route" (the default behavior driven by `continueOtherAudio`).
    /// Wired from Config.audioInputDeviceUID via the menu-bar
    /// Microphone submenu and ParleqApp launch wiring.
    ///
    /// Resolution: when non-empty AND the UID resolves to a currently-
    /// connected device, that device is used. When the UID does not
    /// resolve (device unplugged, AirPods disconnected), we fall back
    /// to System Default behavior (with the BT auto-route heuristic
    /// gated on `continueOtherAudio`). Onlookers in the menu will see
    /// the "missing device" item rendered as a placeholder until the
    /// device reconnects.
    var explicitInputDeviceUID: String = ""

    init() {
        // 16 kHz mono int16 LE — matches what /inference expects
        // after the sidecar strips the 44-byte WAV header.
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    /// Pre-instantiate the engine's input audio unit and apply the
    /// device override BEFORE the user's first hotkey press. Without
    /// this, the first capture has to lazily create the underlying
    /// AudioUnit (which momentarily attaches to the system default
    /// input) and only then switch to the built-in mic — that brief
    /// attach is what pauses BT music on the first capture. After
    /// pre-warming, the AudioUnit is already bound to the right
    /// device, so engine.start() doesn't have to do HAL routing.
    /// Does NOT start the engine; the mic is not actively captured.
    func prewarm() {
        let input = engine.inputNode
        applyInputDeviceOverride(on: input, context: "prewarm")
        // Touching inputFormat forces AudioUnit instantiation so the
        // device override has a unit to land on.
        _ = input.inputFormat(forBus: 0)
        engine.prepare()
    }

    /// Run a brief silent capture cycle — full start + tap install +
    /// short delay + stop — and discard the bytes. Exercises every
    /// cold-start code path (HAL routing, AudioUnit boot, tap
    /// install, AVAudioConverter creation, first buffer arrival)
    /// before the user's first hotkey press, so the user's first
    /// real capture isn't a 90 ms first-buffer-only stub.
    ///
    /// Synchronous on purpose: the only safe moment to call this is
    /// right after sidecar warmup, when the app has just become
    /// ready and the user has nothing to interact with yet. Blocking
    /// MainActor here avoids the ugly race where a hotkey press
    /// arrives mid-warmup and calls start() on an engine that's
    /// already in a brief-test cycle. The orange mic indicator
    /// flashes briefly while this runs — disclosed in
    /// THIRD_PARTY_LICENSES.md / SECURITY_REVIEW.md.
    ///
    /// Best-effort: any failure returns silently; the user's first
    /// real capture will pay the cold-start cost itself in that case.
    func warmupCapture(durationMillis: Int = 250) {
        guard !isRunning else { return }
        do {
            try start()
        } catch {
            logStderr("[parleq] audio[warmup]: start failed: \(error)")
            return
        }
        Thread.sleep(forTimeInterval: TimeInterval(durationMillis) / 1000.0)
        _ = try? stop()
        // Drop the warmup samples — they were never the user's
        // speech. Subsequent start() resets `accumulated` anyway,
        // but clear here too so a hypothetical caller that peeked
        // at the recorder between warmup and first capture wouldn't
        // see stale data.
        accumulated.removeAll(keepingCapacity: false)
        logStderr("[parleq] audio[warmup]: \(durationMillis)ms warmup capture complete")
    }

    /// Begin capturing. The first call after launch may block briefly
    /// while AVAudioEngine acquires the microphone. Throws if
    /// permission was denied or the engine fails to start.
    func start() throws {
        guard !isRunning else { return }
        accumulated.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        // Re-apply the device override on every capture in case the
        // user changed audio devices between captures (e.g. plugged
        // in/out a BT headset). prewarm() already did this once at
        // launch; this call covers subsequent device changes.
        applyInputDeviceOverride(on: input, context: "capture")
        let inputFormat = input.inputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterCreateFailed
        }
        self.converter = conv

        // Buffer size of 4096 frames at 48 kHz ≈ 85 ms — small enough
        // not to add user-perceivable lag at hotkey-up, large enough
        // not to thrash the run loop.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            self?.process(buffer: buf)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(error)
        }
        isRunning = true
    }

    /// Stop capture and return the accumulated samples wrapped in a
    /// 16-bit mono WAV `Data`, plus the audio duration. The buffer
    /// stays in memory — Parleq never writes input audio to disk
    /// (enforced by enterprise compliance policy on Bedrock-using
    /// apps; covered by issue #17). After stop() the recorder may
    /// be start()ed again for the next utterance.
    func stop() throws -> Capture {
        guard isRunning else {
            return Capture(wavData: Data(), durationSeconds: 0)
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false

        let sampleCount = accumulated.count
        let duration = TimeInterval(sampleCount) / AudioRecorder.targetSampleRate
        let data = buildWAVData(samples: accumulated, sampleRate: Int(AudioRecorder.targetSampleRate))
        return Capture(wavData: data, durationSeconds: duration)
    }

    /// Return value from `stop()`. Carries the WAV bytes plus the
    /// audio duration so the caller can short-circuit obviously-
    /// empty utterances (accidental hotkey taps, etc.) without
    /// running the ASR/LLM pipeline.
    struct Capture {
        let wavData: Data
        let durationSeconds: TimeInterval
    }

    private func applyInputDeviceOverride(on input: AVAudioInputNode, context: String) {
        // Resolution priority:
        //   1. Explicit user selection (audio.input_device_uid). When
        //      this is set and resolves to a connected device, that
        //      device wins — even if it's a BT headset that would
        //      otherwise trigger the auto-route to built-in mic.
        //   2. Auto-route heuristic. When no explicit selection (or
        //      the saved UID doesn't resolve) AND continueOtherAudio
        //      is true AND the system default is Bluetooth, route to
        //      the built-in mic to keep BT music in A2DP.
        //   3. Fall through. Leave the engine on whatever it picked
        //      (the system default).
        guard let au = input.audioUnit else { return }
        let target: (id: AudioDeviceID, label: String)?
        if !explicitInputDeviceUID.isEmpty,
           let id = deviceID(forUID: explicitInputDeviceUID) {
            target = (id, "user selection \(explicitInputDeviceUID)")
        } else if continueOtherAudio, let id = preferredAutoRouteInputDeviceID() {
            target = (id, "built-in mic (BT auto-route)")
        } else {
            target = nil
        }
        guard let target = target else { return }
        var dev = target.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            size
        )
        if status != noErr {
            logStderr("[parleq] audio[\(context)]: could not set input device (\(status))")
        } else {
            logStderr("[parleq] audio[\(context)]: routed input to \(target.label)")
        }
    }

    private func process(buffer inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        // Estimate output frame count for capacity; converter handles
        // the actual count and may produce slightly fewer frames per
        // call than the linear estimate would suggest.
        let inFrames = Int(inputBuffer.frameLength)
        let inRate = inputBuffer.format.sampleRate
        let estimated = AVAudioFrameCount(Double(inFrames) * outputFormat.sampleRate / inRate) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: estimated
        ) else { return }

        // The input-source closure is called multiple times until the
        // converter has filled the output buffer or run out of data.
        // We provide our single inputBuffer once and then signal
        // .noDataNow. A reference-type box is used for the
        // first-call flag so Swift 6's Sendable analysis stays happy
        // (the class wraps the mutable state by reference instead of
        // letting the closure capture a mutable var by value).
        let provided = FirstCallBox()
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !provided.done {
                provided.done = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if status == .error || error != nil { return }

        let outFrames = Int(outputBuffer.frameLength)
        guard outFrames > 0, let int16Data = outputBuffer.int16ChannelData else { return }
        let channel = int16Data[0]
        accumulated.append(contentsOf: UnsafeBufferPointer(start: channel, count: outFrames))

        // Level meter: compute RMS over this chunk, convert to dBFS,
        // clamp to a -50…0 dB window, and normalize to 0…1 so the
        // overlay's wave bars get a perceptually reasonable signal
        // (quiet speech ≈ 0.4, raised voice ≈ 0.8, silence ≈ 0).
        // Buffer is small (~85 ms / ~1360 samples at 16 kHz) so an
        // in-line scalar pass is cheap on the audio thread.
        if let levelHandler = levelHandler {
            var sumSq: Double = 0
            for i in 0..<outFrames {
                let s = Double(channel[i]) / 32768.0
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Double(max(1, outFrames)))
            let db = 20 * log10(max(rms, 1e-7))
            let normalized = Float(max(0, min(1, (db + 50) / 50)))
            levelHandler(normalized)
        }

        // Streaming hook: copy this chunk into a Data and push to
        // the handler. The capture-thread cost of the copy is small
        // (chunks are ~5-15 KiB); the handler itself is expected to
        // be cheap (e.g. write to a bound OutputStream that buffers
        // and lets URLSession drain when ready).
        if let chunkHandler = chunkHandler {
            let byteCount = outFrames * MemoryLayout<Int16>.size
            let chunkData = channel.withMemoryRebound(to: UInt8.self, capacity: byteCount) {
                Data(bytes: $0, count: byteCount)
            }
            chunkHandler(chunkData)
        }
    }
}

/// Build a 44-byte-header PCM WAV `Data` from 16-bit signed LE mono
/// samples at the given rate. Memory-only — never written to disk.
/// AVFoundation's WAV writer would also work but only writes to a
/// URL, and we don't want input audio to touch the filesystem.
private func buildWAVData(samples: [Int16], sampleRate: Int) -> Data {
    let bytesPerSample = 2
    let numChannels = 1
    let byteRate = sampleRate * numChannels * bytesPerSample
    let dataSize = samples.count * bytesPerSample
    let chunkSize = 36 + dataSize
    var header = Data(capacity: 44)
    header.append("RIFF".data(using: .ascii)!)
    header.append(uint32LE(UInt32(chunkSize)))
    header.append("WAVE".data(using: .ascii)!)
    header.append("fmt ".data(using: .ascii)!)
    header.append(uint32LE(16))                           // fmt chunk size
    header.append(uint16LE(1))                            // PCM format
    header.append(uint16LE(UInt16(numChannels)))
    header.append(uint32LE(UInt32(sampleRate)))
    header.append(uint32LE(UInt32(byteRate)))
    header.append(uint16LE(UInt16(numChannels * bytesPerSample))) // block align
    header.append(uint16LE(16))                           // bits per sample
    header.append("data".data(using: .ascii)!)
    header.append(uint32LE(UInt32(dataSize)))

    var body = Data(count: dataSize)
    body.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Int16.self)
        for (i, s) in samples.enumerated() {
            dst[i] = s.littleEndian
        }
    }

    return header + body
}

private func uint32LE(_ v: UInt32) -> Data {
    var le = v.littleEndian
    return Data(bytes: &le, count: 4)
}

private func uint16LE(_ v: UInt16) -> Data {
    var le = v.littleEndian
    return Data(bytes: &le, count: 2)
}

// FirstCallBox is a one-shot mutable flag used inside an
// AVAudioConverter input-source closure. It exists purely to dodge a
// Swift 6 Sendable warning that we'd otherwise hit by capturing a
// mutable Bool in the closure: AVAudioConverter calls the input
// closure serially on the audio thread, so there's no real
// concurrency, but the compiler can't know that.
private final class FirstCallBox {
    var done: Bool = false
}

// MARK: - Input-device selection

/// Decide which AudioDeviceID to bind to when the user has NOT
/// picked an explicit microphone — i.e., they're on "System Default".
/// Returns nil if we should leave the engine on its default input
/// (the system default isn't Bluetooth, so capturing won't disrupt
/// music). Returns the built-in mic's ID when the system default IS
/// Bluetooth AND a built-in mic exists. The auto-route heuristic
/// is gated by Config.continueOtherAudio at the call site; this
/// function answers "if we wanted to auto-route, where would we
/// send it?".
private func preferredAutoRouteInputDeviceID() -> AudioDeviceID? {
    guard let defaultInput = systemDefaultInputDevice() else { return nil }
    let tt = transportType(of: defaultInput)
    let isBluetooth = tt == kAudioDeviceTransportTypeBluetooth
        || tt == kAudioDeviceTransportTypeBluetoothLE
    guard isBluetooth else { return nil }
    return builtInMicDeviceID()
}

/// Public describe-shape of an input device, for the menu-bar
/// submenu. `uid` is the stable Core Audio identifier we persist;
/// `name` is the user-facing label. Includes a `transportLabel`
/// that the menu can use to disambiguate same-named entries
/// (e.g. two pairs of AirPods with identical model names).
struct InputDeviceInfo: Hashable, Sendable {
    let uid: String
    let name: String
    let transportLabel: String?
}

/// Enumerate every connected input device that has at least one
/// input stream. The returned array is in Core Audio's natural
/// order (which roughly tracks plug-in order); the menu-bar code
/// is welcome to sort by name. Safe to call from any thread —
/// Core Audio HAL queries are inherently re-entrant.
func availableInputDevices() -> [InputDeviceInfo] {
    var size: UInt32 = 0
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size, &ids
    )
    var out: [InputDeviceInfo] = []
    for id in ids {
        guard deviceHasInputStreams(id) else { continue }
        // Match macOS's own input-device picker behavior. Three filters:
        //   1. Devices that set kAudioDevicePropertyIsHidden = true are
        //      flagged by their owners as "not for end users" (sidecar
        //      processes, helper aggregates, ScreenCaptureKit shims).
        //      macOS Sound prefs honor this flag; so do we.
        //   2. kAudioDeviceTransportTypeAutoAggregate is the runtime-
        //      created aggregate macOS spins up when an app asks for a
        //      capture topology that doesn't have a single physical
        //      backing device (e.g. screen + mic recording). Always
        //      transient, never a thing the user picked.
        //   3. Aggregate-transport devices flagged as private (the
        //      kAudioAggregateDevicePropertyIsPrivate bit) are
        //      system-created aggregates — the canonical one is
        //      CADeviceDefaultAggregate that ships on macOS Sequoia.
        //      macOS doesn't always set IsHidden on these even though
        //      Sound prefs hides them; the private-aggregate flag is
        //      the reliable signal.
        // User-created aggregates (made in Audio MIDI Setup) report
        // IsPrivate == false and stay visible. Same for Virtual
        // devices (BlackHole, Audio Hijack, Loopback) — those
        // represent real user choices.
        if isHidden(id) { continue }
        let tt = transportType(of: id)
        if tt == kAudioDeviceTransportTypeAutoAggregate { continue }
        if tt == kAudioDeviceTransportTypeAggregate, isPrivateAggregate(id) { continue }
        guard let uid = deviceUID(of: id), !uid.isEmpty else { continue }
        let name = deviceName(of: id) ?? "Unnamed input"
        out.append(InputDeviceInfo(
            uid: uid,
            name: name,
            transportLabel: transportLabel(for: tt)
        ))
    }
    return out
}

/// Resolve a persisted UID back to a live `AudioDeviceID`. Returns
/// nil when the device is no longer connected — caller's cue to
/// fall back to System Default behavior.
func deviceID(forUID uid: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size, &ids
    )
    for id in ids {
        if deviceUID(of: id) == uid, deviceHasInputStreams(id) {
            return id
        }
    }
    return nil
}

private func deviceUID(of deviceID: AudioDeviceID) -> String? {
    var cfString: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfString)
    guard status == noErr, let s = cfString?.takeRetainedValue() else { return nil }
    return s as String
}

private func deviceName(of deviceID: AudioDeviceID) -> String? {
    var cfString: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfString)
    guard status == noErr, let s = cfString?.takeRetainedValue() else { return nil }
    return s as String
}

/// Map a Core Audio transport type to a short human-readable label
/// for the menu (e.g. "Built-in", "USB", "Bluetooth", "AirPlay").
/// Returns nil for transports we don't bother labeling so the menu
/// can render just the device name on its own.
private func transportLabel(for transportType: UInt32) -> String? {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:     return "Built-in"
    case kAudioDeviceTransportTypeUSB:         return "USB"
    case kAudioDeviceTransportTypeBluetooth:   return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
    case kAudioDeviceTransportTypeContinuityCaptureWired:
        return "Continuity Camera (USB)"
    case kAudioDeviceTransportTypeContinuityCaptureWireless:
        return "Continuity Camera"
    case kAudioDeviceTransportTypeVirtual:     return "Virtual"
    default: return nil
    }
}

private func systemDefaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr, 0, nil, &size, &deviceID
    )
    return status == noErr && deviceID != 0 ? deviceID : nil
}

private func transportType(of deviceID: AudioDeviceID) -> UInt32 {
    var transportType: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transportType)
    return transportType
}

private func builtInMicDeviceID() -> AudioDeviceID? {
    var size: UInt32 = 0
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &size, &ids
    )
    for id in ids {
        if transportType(of: id) == kAudioDeviceTransportTypeBuiltIn,
           deviceHasInputStreams(id) {
            return id
        }
    }
    return nil
}

/// Read kAudioDevicePropertyIsHidden. Devices set this flag to signal
/// "hide me from end-user pickers" — Apple uses it for the auxiliary
/// devices ScreenCaptureKit and Voice Processing IO Unit instantiate
/// at capture time, and third-party drivers use it for their internal
/// helpers (e.g. a wrapper aggregate around a USB mic). Returns false
/// for devices that don't expose the property (the common case) and
/// for devices that expose it as zero.
private func isHidden(_ deviceID: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIsHidden,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &addr) else { return false }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
    return status == noErr && value != 0
}

/// Read kAudioAggregateDevicePropertyIsPrivate. Only meaningful when
/// the device's transport type is kAudioDeviceTransportTypeAggregate —
/// the property is on AudioAggregateDevice, not on every AudioObject.
/// System-created aggregates (CADeviceDefaultAggregate, the helpers
/// AVAudioEngine voice-processing IO spins up behind a real mic) set
/// this bit; user-created aggregates from Audio MIDI Setup don't.
///
/// The constant isn't auto-imported into Swift as of macOS 14 SDK, so
/// we declare the fourcc selector ('priv') inline. Returns false for
/// devices that don't expose the property (the common case — every
/// non-aggregate device), which is the safe default — we only want
/// to *exclude* on a positive match.
private func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
    // 'priv' fourcc — kAudioAggregateDevicePropertyIsPrivate.
    let selector: AudioObjectPropertySelector =
        AudioObjectPropertySelector(("p" as Character).asciiValue!) << 24 |
        AudioObjectPropertySelector(("r" as Character).asciiValue!) << 16 |
        AudioObjectPropertySelector(("i" as Character).asciiValue!) << 8 |
        AudioObjectPropertySelector(("v" as Character).asciiValue!)
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &addr) else { return false }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
    return status == noErr && value != 0
}

private func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
    return status == noErr && size > 0
}

private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
