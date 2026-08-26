//
//  VoiceFrameParser.swift
//
//  Parser for PacketLogger's `convert -s -f nhdr` line format. The connection handle is
//  intentionally not hard-coded: it changes after Bluetooth reconnects.
//
import Foundation

struct RemoteVoiceFrame {
    let connectionHandle: String
    let sequence: UInt16
    let opusPayload: Data
}

enum VoiceFrameParser {
    private static let notificationSignature: [UInt8] = [0x04, 0x00, 0x1B]
    // Firmware 0x0021 used ATT value handle 0x0035; firmware 0x0033 shifts the same
    // Opus notification to 0x0036. Keep both known layouts explicit so unrelated ATT
    // notifications still have to pass the sequence/length/TOC validation below.
    private static let voiceValueHandles: Set<UInt16> = [0x0035, 0x0036]

    static func parse(_ line: String) -> RemoteVoiceFrame? {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard let directionIndex = fields.firstIndex(of: "RECV"),
              directionIndex >= 1,
              directionIndex + 1 < fields.count else {
            return nil
        }

        let handle = String(fields[directionIndex - 1])
        guard handle.hasPrefix("0x"), handle.count == 6 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(fields.count - directionIndex - 1)
        for field in fields[(directionIndex + 1)...] {
            guard field.count == 2, let byte = UInt8(field, radix: 16) else { return nil }
            bytes.append(byte)
        }

        return parse(bytes: bytes, handle: handle)
    }

    /// Core extractor shared by the text path and the binary `.pklg` path. `bytes` must be a
    /// buffer that contains the ATT notification signature `04 00 1B`, a known voice value
    /// handle, and the notification value. For the text path this is the whole
    /// raw ACL packet; for the binary path it is the reassembled L2CAP PDU. The logic beyond the
    /// signature — sequence, Opus length, TOC 0xB8 — is identical, so both paths decode the same
    /// frames (verified: cap_mic.pklg → 804 frames, byte-for-byte with the text capture).
    static func parse(bytes: [UInt8], handle: String) -> RemoteVoiceFrame? {
        guard let signatureIndex = firstIndex(of: notificationSignature, in: bytes),
              signatureIndex + notificationSignature.count + 2 <= bytes.count else { return nil }
        let attributeIndex = signatureIndex + notificationSignature.count
        let attributeHandle = UInt16(bytes[attributeIndex])
            | (UInt16(bytes[attributeIndex + 1]) << 8)
        guard voiceValueHandles.contains(attributeHandle) else { return nil }
        let valueIndex = attributeIndex + 2
        guard valueIndex + 5 <= bytes.count else { return nil }

        let sequence = UInt16(bytes[valueIndex + 2])
            | (UInt16(bytes[valueIndex + 3]) << 8)
        let opusLength = Int(bytes[valueIndex + 4])
        let opusIndex = valueIndex + 5
        guard opusLength >= 2, opusIndex + opusLength <= bytes.count else { return nil }

        let payload = Array(bytes[opusIndex..<(opusIndex + opusLength)])
        guard payload.first == 0xB8 else { return nil }
        return RemoteVoiceFrame(connectionHandle: handle,
                                sequence: sequence,
                                opusPayload: Data(payload))
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }
}
