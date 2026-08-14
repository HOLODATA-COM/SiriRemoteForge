import Foundation

private func fail(_ message: String) -> Never {
    fputs("parser test: \(message)\n", stderr)
    exit(1)
}

@main
enum VoiceFrameParserTest {
    static func main() {
        let a2854 = "Jul 23 15:45:23.502  Siri Remote  0x04A2  RECV  "
            + "06 24 0E 00 0A 00 04 00 1B 35 00 CA 5B 34 12 03 B8 AA BB"
        guard let frame = VoiceFrameParser.parse(a2854) else { fail("A2854 frame rejected") }
        guard frame.connectionHandle == "0x04A2" else { fail("dynamic handle not retained") }
        guard frame.sequence == 0x1234 else { fail("sequence decoded as \(frame.sequence)") }
        guard Array(frame.opusPayload) == [0xB8, 0xAA, 0xBB] else { fail("payload mismatch") }

        let a2540 = a2854.replacingOccurrences(of: "1B 35 00", with: "1B 36 00")
        guard let a2540Frame = VoiceFrameParser.parse(a2540) else { fail("A2540 frame rejected") }
        guard a2540Frame.sequence == 0x1234 else { fail("A2540 sequence mismatch") }
        guard Array(a2540Frame.opusPayload) == [0xB8, 0xAA, 0xBB]
        else { fail("A2540 payload mismatch") }

        guard VoiceFrameParser.parse(a2854.replacingOccurrences(of: "RECV", with: "SEND")) == nil
        else { fail("SEND packet accepted") }
        guard VoiceFrameParser.parse(a2854.replacingOccurrences(of: "1B 35 00", with: "1B 37 00")) == nil
        else { fail("unsupported ATT handle accepted") }
        guard VoiceFrameParser.parse(String(a2854.dropLast(3))) == nil
        else { fail("truncated packet accepted") }
        guard VoiceFrameParser.parse(a2854.replacingOccurrences(of: "B8 AA BB", with: "78 AA BB")) == nil
        else { fail("wrong Opus TOC accepted") }

        print("parser test: PASS")
    }
}
