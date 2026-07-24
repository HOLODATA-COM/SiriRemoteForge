//
//  PklgTailReader.swift
//
//  Lossless live capture straight from PacketLogger's binary `.pklg`.
//
//  Why not the stdout stream? `packetlogger convert -s …` (text to a pipe) drops ~half the
//  voice frames the moment the reader drains slower than the capture produces — a slow pipe
//  consumer backs up PacketLogger's stdout and it discards HCI. The shipping app RemotePilot
//  sidesteps this exactly the same way we do: it never uses a live pipe. It runs
//  `convert -s -f nhdr > tempfile` (a FILE, which never blocks the writer) and tails the file
//  on a dedicated queue, reassembling PDUs app-side (its `A2854HCIReassembler`/`PendingPDU`).
//
//  We take the strictly safer variant: `packetlogger convert -o FILE.pklg`, the tool's
//  lossless capture mode (proven byte-for-byte in a controlled A/B), and tail that binary file.
//  A regular file never exerts backpressure on PacketLogger, so nothing is dropped no matter
//  how we read; we reassemble the ACL fragments ourselves.
//
//  `.pklg` record layout (all fields big-endian):
//      [length:u32][seconds:u32][microseconds:u32][type:u8][payload: length-9 bytes]
//  `length` counts everything after itself (secs+usecs+type+payload). type 0x03 = ACL received.
//  The remote's voice ATT notification (~99 B) usually spans two ACL fragments, so a single
//  record is only part of a frame — reassembly at the L2CAP layer is mandatory. Validated: the
//  known-good cap_mic.pklg reassembles to exactly 804 frames, identical to the text capture.
//
import Foundation

final class PklgVoiceExtractor {
    // Bytes read from the file that do not yet form a complete record wait here.
    private var residual = [UInt8]()
    // Per ACL connection handle: the in-progress L2CAP PDU being reassembled.
    private var assembling: [Int: (l2capLength: Int, buffer: [UInt8])] = [:]

    /// Number of `.pklg` records seen (any type) — for arrival-cadence diagnostics.
    private(set) var recordsScanned = 0

    /// Feed freshly-read file bytes; returns any voice frames that completed in this batch.
    /// Safe to call with reads that split records arbitrarily — partial records are retained.
    func ingest(_ data: Data) -> [RemoteVoiceFrame] {
        if !data.isEmpty { residual.append(contentsOf: data) }
        var frames: [RemoteVoiceFrame] = []
        var offset = 0
        let count = residual.count

        while offset + 4 <= count {
            let length = Int(residual[offset]) << 24
                | Int(residual[offset + 1]) << 16
                | Int(residual[offset + 2]) << 8
                | Int(residual[offset + 3])
            // A well-formed record (read from offset 0 of a fresh capture) is always aligned;
            // a length below the 9-byte header floor would mean corruption — stop and wait.
            if length < 9 { break }
            let recordEnd = offset + 4 + length
            if recordEnd > count { break }              // record not fully written yet

            let type = residual[offset + 12]
            if type == 0x03 {                            // ACL data received
                let payload = Array(residual[(offset + 13)..<recordEnd])
                if let frame = handleAcl(payload) { frames.append(frame) }
            }
            recordsScanned += 1
            offset = recordEnd
        }

        if offset > 0 { residual.removeFirst(offset) }
        return frames
    }

    /// One received ACL packet: `[handle+flags:u16 LE][acl_len:u16 LE][acl data]`.
    /// PB flags (bits 12-13 of the header): 0b10/0b00 = first fragment of an L2CAP PDU,
    /// 0b01 = continuation. We accumulate per handle until the full L2CAP PDU is present.
    private func handleAcl(_ payload: [UInt8]) -> RemoteVoiceFrame? {
        guard payload.count >= 4 else { return nil }
        let header = Int(payload[0]) | (Int(payload[1]) << 8)
        let handle = header & 0x0FFF
        let pb = (header >> 12) & 0x3
        let aclLength = Int(payload[2]) | (Int(payload[3]) << 8)
        let dataEnd = min(4 + aclLength, payload.count)
        guard dataEnd > 4 else { return nil }
        let aclData = payload[4..<dataEnd]

        if pb == 0x2 || pb == 0x0 {                     // first fragment
            guard aclData.count >= 2 else { assembling[handle] = nil; return nil }
            let l2capLength = Int(aclData[aclData.startIndex]) | (Int(aclData[aclData.startIndex + 1]) << 8)
            assembling[handle] = (l2capLength, Array(aclData))
        } else if pb == 0x1 {                            // continuation
            guard assembling[handle] != nil else { return nil }
            assembling[handle]!.buffer.append(contentsOf: aclData)
        } else {
            return nil
        }

        guard let state = assembling[handle] else { return nil }
        // L2CAP PDU is complete once we have its 4-byte header plus `l2capLength` payload bytes.
        guard state.buffer.count >= 4 + state.l2capLength else { return nil }
        assembling[handle] = nil

        // Reuse the proven extractor: the reassembled PDU is `[len:2][cid=04 00][ATT…]`, so the
        // signature `04 00 1B 35 00` sits at offset 2 and the value parse is byte-identical to
        // the text path.
        let handleString = String(format: "0x%04X", handle)
        return VoiceFrameParser.parse(bytes: state.buffer, handle: handleString)
    }
}
