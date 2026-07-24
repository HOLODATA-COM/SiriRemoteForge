//
//  OpusVoiceDecoder.swift
//  HyperVibe — voice pipeline (stage ③: Opus → PCM)
//
//  Decodes the Siri Remote's microphone frames. The 3rd-gen remote (A2854) streams its
//  mic as raw Opus packets — CELT-only, wideband (16 kHz), 20 ms per frame, TOC 0xb8 —
//  one packet per BLE HID report 0xFA, only while the Siri button is held. The remote
//  only ever SENDS audio, so this is DECODE-ONLY: no encoder is linked into the app.
//
//  Frames reach here already stripped of their report header by the HCI parser (stage ②);
//  this takes the bare Opus payload and returns 48 kHz mono PCM. The decoder is created at
//  48 kHz on purpose — libopus upsamples the 16 kHz wideband content internally, so the
//  output drops straight into Speech.framework / AVAudioEngine without a resample step.
//
//  Validated 2026-07-23 by an encode→decode round-trip against Homebrew libopus 1.6.1
//  (960 samples out, non-silent). See mic/test_decoder.swift.
//
//  libopus is BSD-licensed and GPL-3.0-compatible. Build dependency: `brew install opus`.
//

import Foundation
import AVFoundation

final class OpusVoiceDecoder {
    /// Output sample rate. 48 kHz feeds Speech.framework directly; libopus handles the
    /// 16 kHz-wideband → 48 kHz upsample for us.
    let sampleRate: Int32

    /// The remote's frame is 20 ms; at 48 kHz that is 960 samples. We size every decode
    /// buffer to 120 ms (5760) so a merged or oversized packet can never overrun.
    private let maxFrameSamples: Int32 = 5760

    private let decoder: OpaquePointer

    /// Returns nil if libopus cannot create a decoder (wrong sample rate, out of memory).
    init?(sampleRate: Int32 = 48000) {
        var err: Int32 = 0
        guard let d = opus_decoder_create(sampleRate, 1, &err), err == 0 else { return nil }
        self.decoder = d
        self.sampleRate = sampleRate
    }

    deinit { opus_decoder_destroy(decoder) }

    /// Decode one Opus packet to mono Int16 PCM at `sampleRate`. Returns nil on a decode
    /// error (a corrupt packet); the caller may follow with `conceal()` to keep timing.
    func decode(_ opusPacket: Data) -> [Int16]? {
        guard !opusPacket.isEmpty else { return nil }
        var pcm = [Int16](repeating: 0, count: Int(maxFrameSamples))
        let n = opusPacket.withUnsafeBytes { raw -> Int32 in
            let bytes = raw.bindMemory(to: UInt8.self)
            return pcm.withUnsafeMutableBufferPointer { out in
                opus_decode(decoder, bytes.baseAddress, Int32(opusPacket.count),
                            out.baseAddress!, maxFrameSamples, 0)
            }
        }
        guard n > 0 else { return nil }
        pcm.removeLast(pcm.count - Int(n))
        return pcm
    }

    /// Packet-loss concealment: when the sequence number jumps, ask libopus to synthesize
    /// one frame from its internal state (`opus_decode` with a NULL packet). `frameSamples`
    /// is 960 for the remote's 20 ms frame at 48 kHz.
    func conceal(frameSamples: Int32 = 960) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: Int(frameSamples))
        let n = pcm.withUnsafeMutableBufferPointer { out in
            opus_decode(decoder, nil, 0, out.baseAddress!, frameSamples, 0)
        }
        guard n > 0 else { return [] }
        pcm.removeLast(pcm.count - Int(n))
        return pcm
    }

    /// Wrap decoded PCM in a Float32 mono buffer for Speech.framework
    /// (`SFSpeechAudioBufferRecognitionRequest.append`).
    func floatBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(sampleRate),
                                      channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let chan = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { chan[0][i] = Float(samples[i]) / 32768.0 }
        return buf
    }
}

/// Minimal little-endian 16-bit PCM WAV serializer — for hearing decoded remote audio
/// during bring-up (stage ② dumps a capture, we decode it and write a .wav to listen).
/// Not used in the shipping path; keep it, it is the fastest way to prove a real capture.
enum WavWriter {
    static func data(_ samples: [Int16], sampleRate: Int32) -> Data {
        let bytesPerSample = 2, channels = 1
        let dataBytes = samples.count * bytesPerSample
        let byteRate = Int(sampleRate) * channels * bytesPerSample
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(channels * bytesPerSample)); u16(16)
        str("data"); u32(UInt32(dataBytes))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
