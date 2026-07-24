//
//  test_decoder.swift — offline validation for OpusVoiceDecoder.
//
//  There is no remote audio yet (that needs the HCI-capture spike), so we manufacture a
//  known Opus packet with libopus's encoder, decode it through the REAL OpusVoiceDecoder,
//  and assert the output is the right length and non-silent. The encoder is confined to
//  this test file — the shipping app links decode only.
//
//  Also writes a decoded tone to /tmp so the WavWriter path is exercised end to end.
//

import Foundation

private func fail(_ msg: String) -> Never { print("❌ \(msg)"); exit(1) }

@main
enum DecoderTest {
    static func main() {
        let fs: Int32 = 48000
        let frame = 960 // 20 ms @ 48 kHz — the remote's frame duration

        // --- manufacture a test packet (encoder is test-only; the app never encodes) ---
        var encErr: Int32 = 0
        guard let enc = opus_encoder_create(fs, 1, 2048 /* OPUS_APPLICATION_VOIP */, &encErr),
              encErr == 0 else { fail("opus_encoder_create err=\(encErr)") }

        var pcmIn = [Int16](repeating: 0, count: frame)
        for i in 0..<frame {
            pcmIn[i] = Int16(9000.0 * sin(2.0 * Double.pi * 440.0 * Double(i) / Double(fs)))
        }

        var packet = [UInt8](repeating: 0, count: 4000)
        let nbytes = pcmIn.withUnsafeBufferPointer { pin in
            packet.withUnsafeMutableBufferPointer { pout in
                opus_encode(enc, pin.baseAddress!, Int32(frame), pout.baseAddress!, Int32(pout.count))
            }
        }
        guard nbytes > 0 else { fail("opus_encode returned \(nbytes)") }
        let opusPayload = Data(packet.prefix(Int(nbytes)))
        print("• test packet: \(nbytes) bytes, TOC=0x\(String(packet[0], radix: 16))")

        // --- decode through the module under test ---
        guard let dec = OpusVoiceDecoder(sampleRate: fs) else { fail("OpusVoiceDecoder init failed") }

        guard let pcm = dec.decode(opusPayload) else { fail("decode() returned nil") }
        guard pcm.count == frame else { fail("decoded \(pcm.count) samples, expected \(frame)") }
        var sq = 0.0
        for s in pcm { sq += Double(s) * Double(s) }
        let rms = (sq / Double(pcm.count)).squareRoot()
        guard rms > 100 else { fail("decoded audio is silent (RMS=\(rms))") }
        print("✅ decode(): \(pcm.count) samples, RMS=\(String(format: "%.1f", rms))")

        // --- concealment must produce a frame, not crash ---
        let plc = dec.conceal()
        guard plc.count == frame else { fail("conceal() returned \(plc.count) samples") }
        print("✅ conceal(): \(plc.count) samples")

        // --- Speech-facing buffer conversion ---
        guard let buf = dec.floatBuffer(pcm) else { fail("floatBuffer() returned nil") }
        guard Int(buf.frameLength) == frame else { fail("floatBuffer frameLength \(buf.frameLength)") }
        print("✅ floatBuffer(): \(buf.frameLength) frames, \(buf.format.sampleRate) Hz")

        // --- WAV writer exercised (proves the debug-listen path) ---
        let wav = WavWriter.data(pcm, sampleRate: fs)
        let out = "/tmp/opus_decoder_selftest.wav"
        try? wav.write(to: URL(fileURLWithPath: out))
        print("✅ wrote \(wav.count)-byte WAV → \(out)")

        opus_encoder_destroy(enc)
        print("🎉 OpusVoiceDecoder OK")
    }
}
