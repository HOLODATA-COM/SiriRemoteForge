//
//  VoiceAudioCapture.swift
//  HyperVibe
//
//  A non-real-time reader over HyperVibe's two existing 48 kHz audio rings. It probes briefly for
//  live Siri Remote audio, otherwise locks the utterance to the pinned built-in microphone. Locking
//  one source per utterance avoids a mid-sentence timbre jump and makes streamed PCM deterministic.
//

import Foundation

struct VoiceCapturedAudio {
    enum Source: String {
        case remote
        case builtIn
    }

    let pcm16: Data
    let sampleRate: Int
    let source: Source
    let frameCount: Int
    let meanSquare: Double

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }
}

/// All mutable state is confined to `queue`; public methods only enqueue work or consume the
/// single-producer AsyncStream.
final class VoiceAudioCaptureSession: @unchecked Sendable {
    static let outputSampleRate = 24_000

    let chunks: AsyncStream<Data>

    private let queue = DispatchQueue(label: "com.hypervibe.voice-audio-capture",
                                      qos: .userInitiated)
    private let continuation: AsyncStream<Data>.Continuation
    private let minimumDuration: TimeInterval
    private let maxDuration: TimeInterval
    private let onMinimumDurationReached: () -> Void
    private let onMaximumDuration: () -> Void
    private let onFirstAudioChunk: () -> Void

    private var timer: DispatchSourceTimer?
    private var startedAtNanoseconds: UInt64 = 0
    private var stopped = false
    private var source: VoiceCapturedAudio.Source?

    private var builtinCursor: UInt64 = 0
    private var remoteCursor: UInt64 = 0
    private var remoteBaseline: UInt64 = 0
    private var remoteWasLive = false
    private var remoteAdvancedFrames: UInt64 = 0

    private var builtinProbe: [Float] = []
    private var remoteProbe: [Float] = []
    private var builtinBuffer = [Float](repeating: 0, count: 4096)
    private var remoteBuffer = [Float](repeating: 0, count: 4096)
    private var downsampler = Downsampler48To24()

    private var capturedPCM = Data()
    private var capturedFrames = 0
    private var sumSquares: Double = 0
    private var announcedFirstChunk = false
    private var announcedMinimumDuration = false
    /// The begin cue is played by the Mac while capture is already hot. A tiny lock-protected
    /// monotonic deadline lets the audio queue consume—but not publish—those acoustic frames, so
    /// neither Realtime nor the Final WAV can transcribe HyperVibe's own acknowledgement.
    private let exclusionLock = NSLock()
    private var excludeUntilNanoseconds: UInt64 = 0

    /// Capture starts on the raw press edge, before the 200 ms hold discriminator. A 120 ms probe
    /// therefore finishes before Voice becomes visible, while still giving the remote stream six
    /// complete 20 ms packets to prove freshness.
    private let probeNanoseconds: UInt64 = 120_000_000
    private let remotePreRollFrames: UInt64 = 14_400 // 300 ms at 48 kHz

    init(minimumDuration: TimeInterval,
         maxDuration: TimeInterval,
         onMinimumDurationReached: @escaping () -> Void,
         onMaximumDuration: @escaping () -> Void,
         onFirstAudioChunk: @escaping () -> Void = {}) {
        self.minimumDuration = max(0, minimumDuration)
        self.maxDuration = max(1, maxDuration)
        self.onMinimumDurationReached = onMinimumDurationReached
        self.onMaximumDuration = onMaximumDuration
        self.onFirstAudioChunk = onFirstAudioChunk
        var localContinuation: AsyncStream<Data>.Continuation!
        // At the 120 s hard limit this is still only ~5.8 MB of PCM. Unbounded buffering avoids
        // dropping the beginning of an utterance if TLS/WebSocket setup is unusually slow.
        chunks = AsyncStream<Data>(bufferingPolicy: .unbounded) {
            localContinuation = $0
        }
        continuation = localContinuation
        builtinProbe.reserveCapacity(6_000)
        remoteProbe.reserveCapacity(15_000)
        capturedPCM.reserveCapacity(65_536)
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() async -> VoiceCapturedAudio {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: VoiceCapturedAudio(
                        pcm16: Data(), sampleRate: Self.outputSampleRate,
                        source: .builtIn, frameCount: 0, meanSquare: 0
                    ))
                    return
                }
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    func excludeAcousticFeedback(for duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(min(1, duration) * 1_000_000_000)
        exclusionLock.lock()
        excludeUntilNanoseconds = max(excludeUntilNanoseconds, now &+ delta)
        exclusionLock.unlock()
    }

    private func startOnQueue() {
        guard timer == nil, !stopped else { return }
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        announceMinimumDurationIfNeeded()

        var active: UInt32 = 0
        if srm_builtin_audio_state(&builtinCursor, &active) != 0 { builtinCursor = 0 }
        if srm_remote_audio_state(&remoteBaseline, &active) == 0 {
            remoteCursor = remoteBaseline
        } else {
            remoteBaseline = 0
            remoteCursor = 0
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard !stopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= startedAtNanoseconds,
           Double(now - startedAtNanoseconds) / 1_000_000_000 >= maxDuration {
            _ = stopOnQueue()
            DispatchQueue.main.async { [onMaximumDuration] in onMaximumDuration() }
            return
        }

        // Once a source wins the 120 ms probe, stop touching the other ring entirely. This halves
        // ring reads and removes two transient Array allocations from every steady-state tick.
        if source == .builtIn {
            let count = readBuiltin()
            append48k(builtinBuffer, count: count)
            return
        }
        if source == .remote {
            let count = readRemoteIfLive()
            append48k(remoteBuffer, count: count)
            return
        }

        let builtinCount = readBuiltin()
        let remoteCount = readRemoteIfLive()

        if source == nil {
            if builtinCount > 0 {
                builtinProbe.append(contentsOf: builtinBuffer.prefix(builtinCount))
            }
            if remoteCount > 0 {
                remoteProbe.append(contentsOf: remoteBuffer.prefix(remoteCount))
            }

            if remoteWasLive && remoteAdvancedFrames >= 960 {
                select(.remote)
            } else if now - startedAtNanoseconds >= probeNanoseconds {
                select(.builtIn)
            }
            return
        }

    }

    private func readBuiltin() -> Int {
        var active: UInt32 = 0
        let count = builtinBuffer.withUnsafeMutableBufferPointer { buffer in
            srm_builtin_audio_read(&builtinCursor, buffer.baseAddress,
                                   buffer.count, &active)
        }
        guard active != 0, count > 0 else { return 0 }
        return Int(count)
    }

    private func readRemoteIfLive() -> Int {
        var current: UInt64 = 0
        var active: UInt32 = 0
        guard srm_remote_audio_state(&current, &active) == 0, active != 0 else { return 0 }

        if !remoteWasLive {
            guard current > remoteBaseline else { return 0 }
            remoteWasLive = true
            remoteAdvancedFrames = current - remoteBaseline
            remoteCursor = remoteBaseline > remotePreRollFrames
                ? remoteBaseline - remotePreRollFrames : 0
        } else if current > remoteCursor {
            remoteAdvancedFrames = max(remoteAdvancedFrames, current - remoteBaseline)
        }

        let count = remoteBuffer.withUnsafeMutableBufferPointer { buffer in
            srm_remote_audio_read(&remoteCursor, buffer.baseAddress,
                                  buffer.count, &active)
        }
        guard count > 0 else { return 0 }
        return Int(count)
    }

    private func select(_ selected: VoiceCapturedAudio.Source) {
        guard source == nil else { return }
        source = selected
        switch selected {
        case .remote:
            append48k(remoteProbe)
        case .builtIn:
            append48k(builtinProbe)
        }
        builtinProbe.removeAll(keepingCapacity: false)
        remoteProbe.removeAll(keepingCapacity: false)
    }

    private func append48k(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append48k($0) }
    }

    private func append48k(_ buffer: [Float], count: Int) {
        guard count > 0 else { return }
        buffer.withUnsafeBufferPointer { pointer in
            append48k(UnsafeBufferPointer(rebasing: pointer.prefix(count)))
        }
    }

    private func append48k(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let chunk = downsampler.convert(samples)
        guard !chunk.isEmpty else { return }
        exclusionLock.lock()
        let excluded = DispatchTime.now().uptimeNanoseconds < excludeUntilNanoseconds
        exclusionLock.unlock()
        // Conversion still advances the decimator across excluded frames, avoiding a stale odd
        // sample at the first real speech packet after the cue.
        guard !excluded else { return }
        capturedPCM.append(chunk)
        capturedFrames += chunk.count / MemoryLayout<Int16>.size
        if !announcedFirstChunk {
            announcedFirstChunk = true
            onFirstAudioChunk()
        }
        announceMinimumDurationIfNeeded()

        chunk.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for littleEndian in values {
                let value = Double(Int16(littleEndian: littleEndian)) / 32768.0
                sumSquares += value * value
            }
        }
        continuation.yield(chunk)
    }

    private func announceMinimumDurationIfNeeded() {
        guard !announcedMinimumDuration,
              Double(capturedFrames) / Double(Self.outputSampleRate) >= minimumDuration else {
            return
        }
        announcedMinimumDuration = true
        DispatchQueue.main.async { [onMinimumDurationReached] in
            onMinimumDurationReached()
        }
    }

    @discardableResult
    private func stopOnQueue() -> VoiceCapturedAudio {
        if !stopped {
            stopped = true
            timer?.cancel()
            timer = nil
            if source == nil {
                select(remoteWasLive && remoteAdvancedFrames >= 480 ? .remote : .builtIn)
            }
            continuation.finish()
        }
        let selected = source ?? .builtIn
        return VoiceCapturedAudio(
            pcm16: capturedPCM,
            sampleRate: Self.outputSampleRate,
            source: selected,
            frameCount: capturedFrames,
            meanSquare: capturedFrames > 0 ? sumSquares / Double(capturedFrames) : 0
        )
    }
}

/// Voice-grade 2:1 conversion. Averaging each adjacent pair is both a decimator and a one-tap
/// anti-alias filter; keeping the odd frame across chunks prevents timing drift at packet edges.
struct Downsampler48To24 {
    private var pending: Float?

    mutating func convert(_ input: [Float]) -> Data {
        input.withUnsafeBufferPointer { convert($0) }
    }

    mutating func convert(_ input: UnsafeBufferPointer<Float>) -> Data {
        guard !input.isEmpty else { return Data() }
        let carried = pending
        let sampleCount = (input.count + (carried == nil ? 0 : 1)) / 2
        var output = Data(count: sampleCount * MemoryLayout<Int16>.size)
        var index = 0
        var outputIndex = 0
        var nextPending: Float?
        output.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            if let first = carried {
                values[outputIndex] = Self.encode((first + input[0]) * 0.5)
                outputIndex += 1
                index = 1
            }
            while index + 1 < input.count {
                values[outputIndex] = Self.encode((input[index] + input[index + 1]) * 0.5)
                outputIndex += 1
                index += 2
            }
            if index < input.count { nextPending = input[index] }
        }
        pending = nextPending
        return output
    }

    private static func encode(_ sample: Float) -> Int16 {
        let finite = sample.isFinite ? sample : 0
        let clamped = max(-1, min(1, finite))
        return Int16(clamped * 32767).littleEndian
    }
}
