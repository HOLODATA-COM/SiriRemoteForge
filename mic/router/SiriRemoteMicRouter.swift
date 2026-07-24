//
//  SiriRemoteMicRouter.swift
//
//  Reads PacketLogger nhdr text, extracts the Siri Remote's GATT voice notifications,
//  decodes Opus, and feeds 48 kHz mono Float32 audio to the HAL plug-in's shared ring.
//
import Darwin
import Foundation

private struct RouterOptions {
    var inputPath: String?
    var pklgPath: String?
    var exitOnEOF = false
    var wavPath: String?
    var writeRing = true
    var replayRealtime = false
    var expectedFrames: Int?
    var quiet = false
    var monitor = false
    var monitorBufferMs = 100

    static func parse(_ arguments: [String]) throws -> RouterOptions {
        var options = RouterOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--input":
                index += 1
                guard index < arguments.count else { throw RouterError.usage("--input needs a path") }
                options.inputPath = arguments[index]
            case "--pklg":
                index += 1
                guard index < arguments.count else { throw RouterError.usage("--pklg needs a path") }
                options.pklgPath = arguments[index]
            case "--exit-on-eof":
                options.exitOnEOF = true
            case "--wav":
                index += 1
                guard index < arguments.count else { throw RouterError.usage("--wav needs a path") }
                options.wavPath = arguments[index]
            case "--no-ring":
                options.writeRing = false
            case "--monitor":
                options.monitor = true
            case "--monitor-buffer-ms":
                index += 1
                guard index < arguments.count, let ms = Int(arguments[index]), ms >= 20, ms <= 1000 else {
                    throw RouterError.usage("--monitor-buffer-ms needs an integer 20…1000")
                }
                options.monitorBufferMs = ms
            case "--replay-realtime":
                options.replayRealtime = true
            case "--expect-frames":
                index += 1
                guard index < arguments.count, let count = Int(arguments[index]), count >= 0 else {
                    throw RouterError.usage("--expect-frames needs a non-negative integer")
                }
                options.expectedFrames = count
            case "--quiet":
                options.quiet = true
            case "-h", "--help":
                throw RouterError.help
            default:
                throw RouterError.usage("unknown argument: \(arguments[index])")
            }
            index += 1
        }
        if options.inputPath != nil && options.pklgPath != nil {
            throw RouterError.usage("--input and --pklg are mutually exclusive")
        }
        return options
    }
}

private enum RouterError: Error, CustomStringConvertible {
    case help
    case usage(String)
    case runtime(String)

    var description: String {
        switch self {
        case .help: return ""
        case .usage(let message), .runtime(let message): return message
        }
    }
}

private struct RouterStats {
    var inputLines = 0
    var voiceFrames = 0
    var decodedFrames = 0
    var decodeErrors = 0
    var duplicateFrames = 0
    var concealedFrames = 0
    var discontinuities = 0
    var decodedSamples = 0
    var sumSquares = 0.0
    var peak: Int16 = 0
}

private final class Router {
    private let options: RouterOptions
    private let decoder: OpusVoiceDecoder
    private let monitor: MonitorPlayer?
    private var previousSequence: UInt16?
    private var prebufferedSamples = 0
    private var producerPublished = false
    private var wavSamples: [Int16] = []
    private(set) var stats = RouterStats()

    // Three 20 ms packets absorb normal BLE scheduling jitter before CoreAudio begins pulling.
    private let prebufferTarget = 3 * 960

    init(options: RouterOptions) throws {
        self.options = options
        guard let decoder = OpusVoiceDecoder(sampleRate: 48000) else {
            throw RouterError.runtime("could not create the 48 kHz mono Opus decoder")
        }
        self.decoder = decoder

        if options.monitor {
            // Jitter budget from the CLI (default 100 ms). Re-prime after an underrun costs only
            // one 20 ms frame so a transient dip is a blip, not a full re-prime of silence.
            let primeFrames = UInt32(options.monitorBufferMs * 48)
            guard let player = MonitorPlayer(primeFrames: primeFrames,
                                             reprimeFrames: 960,
                                             maxLatencyFrames: 48000) else {
                throw RouterError.runtime("could not create the monitor audio player")
            }
            try player.start()
            self.monitor = player
        } else {
            self.monitor = nil
        }

        if options.writeRing {
            guard srm_ring_writer_open() == 0 else {
                throw RouterError.runtime(String(cString: srm_ring_writer_last_error()))
            }
            srm_ring_writer_install_signal_cleanup()
        }
    }

    deinit {
        if options.writeRing { srm_ring_writer_close() }
    }

    func consume(_ line: String) throws {
        stats.inputLines += 1
        guard let frame = VoiceFrameParser.parse(line) else { return }
        try consume(frame)
    }

    func consume(_ frame: RemoteVoiceFrame) throws {
        stats.voiceFrames += 1

        if let previous = previousSequence {
            let distance = Int(frame.sequence &- previous)
            if distance == 0 {
                stats.duplicateFrames += 1
                return
            }
            if distance > 1 && distance <= 10 {
                for _ in 1..<distance {
                    let concealed = decoder.conceal()
                    guard !concealed.isEmpty else { break }
                    try publish(concealed)
                    stats.concealedFrames += 1
                }
            } else if distance > 10 {
                // A new Siri hold normally restarts the sequence at zero. Do not synthesize a
                // huge gap; the next real packet establishes the new stream.
                stats.discontinuities += 1
            }
        }
        previousSequence = frame.sequence

        guard let samples = decoder.decode(frame.opusPayload) else {
            stats.decodeErrors += 1
            return
        }
        try publish(samples)
        stats.decodedFrames += 1

        if options.replayRealtime {
            let duration = Double(samples.count) / 48000.0
            usleep(useconds_t(duration * 1_000_000.0))
        }
    }

    private func publish(_ samples: [Int16]) throws {
        monitor?.enqueue(samples)
        stats.decodedSamples += samples.count
        for sample in samples {
            let magnitude = sample == Int16.min ? Int16.max : abs(sample)
            if magnitude > stats.peak { stats.peak = magnitude }
            stats.sumSquares += Double(sample) * Double(sample)
        }
        if options.wavPath != nil { wavSamples.append(contentsOf: samples) }

        if options.writeRing {
            let result = samples.withUnsafeBufferPointer {
                srm_ring_writer_write_int16($0.baseAddress, $0.count)
            }
            guard result == 0 else {
                throw RouterError.runtime(String(cString: srm_ring_writer_last_error()))
            }
            prebufferedSamples += samples.count
            if !producerPublished && prebufferedSamples >= prebufferTarget {
                srm_ring_writer_set_active(1)
                producerPublished = true
            }
        }
    }

    /// Tail PacketLogger's growing binary `.pklg` (`packetlogger convert -o FILE.pklg`). A file
    /// never exerts backpressure on PacketLogger, so this is lossless regardless of read speed;
    /// we reassemble the ACL fragments ourselves. Reads from offset 0 of what must be a FRESH
    /// capture, so the byte stream is always record-aligned. Loops until EOF (with --exit-on-eof,
    /// for offline replay) or until the process is signalled (live).
    func runPklg(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw RouterError.runtime("could not open \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        let extractor = PklgVoiceExtractor()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, bufferSize)
            }
            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                for frame in extractor.ingest(data) {
                    try consume(frame)
                }
            } else if n == 0 {
                if options.exitOnEOF { break }
                if gInterrupted != 0 { break }
                usleep(4000)                 // 4 ms: tail -f poll for the next flush
            } else {
                if errno == EINTR { continue }
                throw RouterError.runtime("read(\(path)): \(String(cString: strerror(errno)))")
            }
        }
    }

    var monitorUnderruns: UInt64 { monitor?.underruns ?? 0 }
    var monitorSilenceFrames: UInt64 { monitor?.silenceFrames ?? 0 }

    func finish() throws {
        monitor?.stop()
        if options.writeRing {
            srm_ring_writer_set_active(0)
        }
        if let wavPath = options.wavPath {
            let data = WavWriter.data(wavSamples, sampleRate: 48000)
            try data.write(to: URL(fileURLWithPath: wavPath), options: .atomic)
        }
    }
}

private func printUsage() {
    print("""
    Usage:
      srm_router [--input TRACE.txt | --pklg FILE.pklg] [--monitor] [--monitor-buffer-ms N]
                 [--wav OUTPUT.wav] [--no-ring] [--exit-on-eof]
                 [--replay-realtime] [--expect-frames N] [--quiet]

    Sources (pick one; default is stdin):
      --pklg FILE.pklg   Tail PacketLogger's LOSSLESS binary capture live and reassemble the
                         ACL fragments ourselves. This is the clean live path — a file never
                         backs up PacketLogger, so no frames are dropped. Read from a FRESH file.
      --input TRACE.txt  Decode a saved `-f nhdr` text trace (offline).
      (stdin)            Read `packetlogger convert -s -f nhdr` text lines from a pipe.

      --exit-on-eof      With --pklg, stop at end-of-file instead of tailing (offline replay).
      --monitor          Play decoded audio live to the default output (the ear monitor).
      --monitor-buffer-ms N  Jitter-buffer prime target, 20…1000 (default 100).

    Live ear-monitor (see ./live_monitor.sh for a ready-to-run wrapper):
      sudo packetlogger convert -o /tmp/srm_live.pklg      # lossless capture (needs root)
      ./srm_router --pklg /tmp/srm_live.pklg --monitor --no-ring
    """)
}

// Set by SIGINT/SIGTERM so the --pklg tail loop can stop cleanly and still print stats + WAV.
// Only installed for the --no-ring monitor path; the ring path keeps its own _exit handlers so
// a dead producer never looks live to the HAL plug-in.
private var gInterrupted: sig_atomic_t = 0

@main
enum SiriRemoteMicRouterMain {
    static func main() {
        do {
            let options = try RouterOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let router = try Router(options: options)

            if !options.writeRing {
                signal(SIGINT) { _ in gInterrupted = 1 }
                signal(SIGTERM) { _ in gInterrupted = 1 }
            }

            if let path = options.pklgPath {
                try router.runPklg(path: path)
            } else if let path = options.inputPath {
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                contents.enumerateLines { line, _ in
                    do {
                        try router.consume(line)
                    } catch {
                        fputs("srm_router: \(error)\n", stderr)
                        exit(1)
                    }
                }
            } else {
                while let line = readLine() {
                    try router.consume(line)
                }
            }

            try router.finish()
            let stats = router.stats
            let rms = stats.decodedSamples == 0
                ? 0.0
                : (stats.sumSquares / Double(stats.decodedSamples)).squareRoot()
            if !options.quiet {
                print("srm_router: lines=\(stats.inputLines) voice=\(stats.voiceFrames) "
                    + "decoded=\(stats.decodedFrames) bad=\(stats.decodeErrors) "
                    + "duplicates=\(stats.duplicateFrames) plc=\(stats.concealedFrames) "
                    + "discontinuities=\(stats.discontinuities)")
                print(String(format: "srm_router: samples=%d rms=%.1f peak=%d ring_write=%llu",
                             stats.decodedSamples, rms, Int(stats.peak),
                             srm_ring_writer_write_index()))
                if options.monitor {
                    print("srm_router: monitor underruns=\(router.monitorUnderruns) "
                        + "silence_frames=\(router.monitorSilenceFrames)")
                }
            }
            if let expected = options.expectedFrames, stats.voiceFrames != expected {
                throw RouterError.runtime("expected \(expected) voice frames, got \(stats.voiceFrames)")
            }
            if stats.decodeErrors != 0 {
                throw RouterError.runtime("\(stats.decodeErrors) Opus frame(s) failed to decode")
            }
        } catch RouterError.help {
            printUsage()
        } catch {
            fputs("srm_router: \(error)\n", stderr)
            printUsage()
            exit(2)
        }
    }
}
