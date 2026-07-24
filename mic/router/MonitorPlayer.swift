//
//  MonitorPlayer.swift
//
//  In-process live "ear monitor": decoded PCM is pushed into a lock-free SPSC ring
//  (MonitorAudioRing.c) and an AVAudioSourceNode render callback pulls a steady stream to the
//  default output. This BYPASSES the HAL virtual device + coreaudiod ring (whose crude resync
//  pops). The AVAudioEngine output clock pulls smoothly; the ring's prime/underrun/overflow
//  policy (in C, owned by the render thread) absorbs the bursty ~50 fps delivery.
//
//  The render callback does no locking, no allocation and no Swift bridging beyond a single C
//  call — the correctness fix over the previous NSLock ring, which was neither real-time-safe
//  nor cheap on the audio thread.
//
import AVFoundation

final class MonitorPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let sampleRate: Double = 48000
    private let gain: Float

    /// - Parameters:
    ///   - gain: compensates for the remote mic's low close-talk capture level.
    ///   - primeFrames: buffer to accumulate before releasing audio (jitter budget).
    ///   - reprimeFrames: buffer to re-accumulate after an underrun (small → fast recovery).
    ///   - maxLatencyFrames: drop oldest beyond this backlog (bounds monitor latency).
    init?(gain: Float = 4.0,
          primeFrames: UInt32 = 4800,
          reprimeFrames: UInt32 = 960,
          maxLatencyFrames: UInt32 = 48000) {
        self.gain = gain
        mon_ring_configure(primeFrames, reprimeFrames, maxLatencyFrames)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }
        // No `self` capture: the callback only touches the global C ring, so there is no
        // retain cycle and nothing to synchronise on the render thread.
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            let out = abl[0].mData!.assumingMemoryBound(to: Float.self)
            mon_ring_read(out, Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    /// Push decoded Int16 PCM into the ring. Non-blocking; gain + hard-clip applied in C.
    func enqueue(_ samples: [Int16]) {
        samples.withUnsafeBufferPointer { mon_ring_write_int16($0.baseAddress, $0.count, gain) }
    }

    var underruns: UInt64 { mon_ring_underruns() }
    var silenceFrames: UInt64 { mon_ring_silence_frames() }
}
