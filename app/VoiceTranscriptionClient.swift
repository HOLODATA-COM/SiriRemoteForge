//
//  VoiceTranscriptionClient.swift
//  HyperVibe
//
//  OpenAI's two intentionally separate speech paths:
//    - bounded/final: gpt-transcribe over /v1/audio/transcriptions
//    - live/streaming: gpt-live-transcribe over the Realtime transcription WebSocket
//

import Foundation

enum VoiceTranscriptionError: LocalizedError {
    case missingCredential
    case invalidAudio
    case invalidResponse
    case service(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingCredential: return L("No OpenAI API key is saved.")
        case .invalidAudio: return L("No usable speech was recorded.")
        case .invalidResponse: return L("The transcription service returned an invalid response.")
        case .service(let message): return message
        case .timedOut: return L("Transcription timed out. The recording is still available to retry.")
        case .cancelled: return L("Dictation was cancelled.")
        }
    }
}

final class VoiceTranscriptionClient {
    private let session: URLSession
    private let realtimeSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        // Voice input is interactive. Waiting silently for connectivity is worse than returning a
        // useful failure immediately, and a later press can use the coordinator's fresh prewarm.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)

        let realtimeConfiguration = URLSessionConfiguration.ephemeral
        realtimeConfiguration.timeoutIntervalForRequest = 15
        realtimeConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        realtimeConfiguration.waitsForConnectivity = false
        realtimeConfiguration.httpMaximumConnectionsPerHost = 2
        realtimeSession = URLSession(configuration: realtimeConfiguration)
    }

    func transcribeFinal(
        _ audio: VoiceCapturedAudio,
        model: String,
        languageHints: [String],
        dictionary: [Config.DictationTerm]
    ) async throws -> String {
        guard let key = VoiceCredentialStore.read(.openAI) else {
            throw VoiceTranscriptionError.missingCredential
        }
        guard audio.frameCount >= audio.sampleRate / 10, !audio.pcm16.isEmpty else {
            throw VoiceTranscriptionError.invalidAudio
        }

        let boundary = "HyperVibe-\(UUID().uuidString)"
        var body = MultipartBody(boundary: boundary)
        body.addField(name: "model", value: model)
        body.addField(name: "response_format", value: "json")
        for language in Self.normalizedLanguageHints(languageHints) {
            body.addField(name: "languages[]", value: language)
        }
        for keyword in Self.normalizedKeywords(dictionary) {
            body.addField(name: "keywords[]", value: keyword)
        }
        let prompt = Self.contextPrompt(dictionary)
        if !prompt.isEmpty { body.addField(name: "prompt", value: prompt) }
        body.addFile(name: "file", filename: "hypervibe-dictation.wav",
                     contentType: "audio/wav", data: WAVEncoder.encode(audio))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finish()

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String else {
            throw VoiceTranscriptionError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openRealtime(
        model: String,
        minimalDelay: Bool,
        languageHints: [String],
        dictionary: [Config.DictationTerm],
        onDelta: @escaping (String) async -> Void,
        onPreview: @escaping (String) async -> Void,
        onDrained: @escaping () async -> Void
    ) async throws -> VoiceRealtimeTranscriptionSession {
        guard let key = VoiceCredentialStore.read(.openAI) else {
            // No receive loop will be created, so close the callback barrier here. The router
            // latches an early drain until the physical press attaches its handlers.
            await onDrained()
            throw VoiceTranscriptionError.missingCredential
        }
        return try await VoiceRealtimeTranscriptionSession.connect(
            apiKey: key,
            urlSession: realtimeSession,
            model: model,
            minimalDelay: minimalDelay,
            languages: Self.normalizedLanguageHints(languageHints),
            keywords: Self.normalizedKeywords(dictionary),
            prompt: Self.contextPrompt(dictionary),
            onDelta: onDelta,
            onPreview: onPreview,
            onDrained: onDrained
        )
    }

    static func normalizedLanguageHints(_ raw: [String]) -> [String] {
        unique(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    static func normalizedKeywords(_ dictionary: [Config.DictationTerm]) -> [String] {
        unique(dictionary.map(\.term).filter {
            !$0.isEmpty && !$0.contains("<") && !$0.contains(">")
                && !$0.contains("\r") && !$0.contains("\n")
        }).prefix(500).map { $0 }
    }

    static func contextPrompt(_ dictionary: [Config.DictationTerm]) -> String {
        let aliases = dictionary.compactMap { entry -> String? in
            let clean = entry.aliases.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return nil }
            return "\(clean.joined(separator: ", ")) → \(entry.term)"
        }
        guard !aliases.isEmpty else { return "" }
        return "可能出现以下专有词；仅在确实听到时采用标准拼写：" + aliases.joined(separator: "; ")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceTranscriptionError.service(
                VoiceAPIError.safeMessage(data: data, statusCode: http.statusCode)
            )
        }
    }
}

// MARK: - Realtime transcription

actor RealtimeTranscriptState {
    private var ready = false
    private var deltas = ""
    private var completed: String?
    private var failure: String?
    private var terminalError: VoiceTranscriptionError?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readyWaiterID: UUID?
    private var readyTimeoutTask: Task<Void, Never>?
    private var resultWaiter: CheckedContinuation<String, Error>?
    private var resultWaiterID: UUID?
    private var resultTimeoutTask: Task<Void, Never>?

    func apply(_ data: Data) throws -> (
        delta: String?, preview: String?, didComplete: Bool
    ) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw VoiceTranscriptionError.invalidResponse
        }
        switch type {
        case "session.updated", "transcription_session.updated":
            ready = true
            resolveReadyWaiter(.success(()))
            return (nil, nil, false)
        case "conversation.item.input_audio_transcription.delta":
            let delta = json["delta"] as? String ?? ""
            deltas.append(delta)
            return (delta.isEmpty ? nil : delta, deltas, false)
        case "conversation.item.input_audio_transcription.completed":
            // Preserve the server's exact committed text. Streaming deltas may already have
            // inserted leading/trailing whitespace; trimming here makes strict suffix
            // reconciliation fail and can copy a duplicate authoritative transcript.
            let text = json["transcript"] as? String ?? deltas
            completed = text
            resolveResultWaiter(.success(text))
            return (nil, text, true)
        case "conversation.item.input_audio_transcription.failed", "error":
            let message: String
            if let error = json["error"] as? [String: Any] {
                message = error["message"] as? String
                    ?? error["type"] as? String
                    ?? L("Realtime transcription failed.")
            } else {
                message = json["message"] as? String ?? L("Realtime transcription failed.")
            }
            failure = message
            let error = VoiceTranscriptionError.service(message)
            terminalError = error
            resolveReadyWaiter(.failure(error))
            resolveResultWaiter(.failure(error))
            throw error
        default:
            return (nil, nil, false)
        }
    }

    func markFailure(_ message: String) {
        if failure == nil { failure = message }
        guard completed == nil, terminalError == nil else { return }
        let error = VoiceTranscriptionError.service(message)
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    func markCancelled() {
        guard completed == nil, terminalError == nil else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    /// Handshake success and terminal failure share a direct wake-up. A proxy rejection or socket
    /// close before `session.updated` therefore falls back immediately instead of burning the old
    /// fixed four-second readiness timeout.
    func waitUntilReady(timeoutNanoseconds: UInt64) async throws {
        if ready { return }
        if let terminalError { throw terminalError }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if ready {
                    continuation.resume()
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    precondition(readyWaiter == nil)
                    readyWaiter = continuation
                    readyWaiterID = waiterID
                    readyTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        await self?.timeoutReadyWaiter(id: waiterID)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelReadyWaiter(id: waiterID) }
        })
    }

    /// Direct continuation wake-up removes the old 10 ms result polling interval (about 5 ms
    /// average release-tail latency) while retaining a hard timeout and cancellation semantics.
    func waitForResult(timeoutNanoseconds: UInt64) async throws -> String {
        if let completed { return completed }
        if let terminalError { throw terminalError }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                // Actor reentrancy can let the terminal event arrive as the cancellation handler is
                // installed. Re-check before storing so no completion can be lost.
                if let completed {
                    continuation.resume(returning: completed)
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    precondition(resultWaiter == nil)
                    resultWaiter = continuation
                    resultWaiterID = waiterID
                    resultTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        await self?.timeoutResultWaiter(id: waiterID)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelResultWaiter(id: waiterID) }
        })
    }

    func result() -> String? { completed }
    func error() -> String? { failure }

    private func resolveReadyWaiter(
        _ result: Result<Void, VoiceTranscriptionError>
    ) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        readyWaiterID = nil
        switch result {
        case .success: waiter.resume()
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func resolveResultWaiter(
        _ result: Result<String, VoiceTranscriptionError>
    ) {
        resultTimeoutTask?.cancel()
        resultTimeoutTask = nil
        guard let waiter = resultWaiter else { return }
        resultWaiter = nil
        resultWaiterID = nil
        switch result {
        case .success(let text): waiter.resume(returning: text)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func timeoutResultWaiter(id: UUID) {
        guard resultWaiterID == id else { return }
        let error = VoiceTranscriptionError.timedOut
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func cancelResultWaiter(id: UUID) {
        guard resultWaiterID == id else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func timeoutReadyWaiter(id: UUID) {
        guard readyWaiterID == id else { return }
        let error = VoiceTranscriptionError.timedOut
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }

    private func cancelReadyWaiter(id: UUID) {
        guard readyWaiterID == id else { return }
        let error = VoiceTranscriptionError.cancelled
        terminalError = error
        resolveReadyWaiter(.failure(error))
        resolveResultWaiter(.failure(error))
    }
}

final class VoiceRealtimeTranscriptionSession {
    private let webSocket: URLSessionWebSocketTask
    private let state: RealtimeTranscriptState
    private var receiveTask: Task<Void, Never>?
    private let closeLock = NSLock()
    private var closed = false

    private init(webSocket: URLSessionWebSocketTask, state: RealtimeTranscriptState) {
        self.webSocket = webSocket
        self.state = state
    }

    static func connect(
        apiKey: String,
        urlSession: URLSession,
        model: String,
        minimalDelay: Bool,
        languages: [String],
        keywords: [String],
        prompt: String,
        onDelta: @escaping (String) async -> Void,
        onPreview: @escaping (String) async -> Void,
        onDrained: @escaping () async -> Void
    ) async throws -> VoiceRealtimeTranscriptionSession {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = urlSession.webSocketTask(with: request)
        let state = RealtimeTranscriptState()
        let live = VoiceRealtimeTranscriptionSession(webSocket: socket, state: state)
        socket.resume()
        live.receiveTask = Task { [weak live] in
            do {
                while !Task.isCancelled, live != nil {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    let change = try await state.apply(data)
                    if let delta = change.delta { await onDelta(delta) }
                    // A delta already lets the UI extend its preview. Only publish the cumulative
                    // callback for non-delta events (notably the server's final committed text),
                    // avoiding two MainActor hops and two SwiftUI invalidations per token.
                    else if let preview = change.preview { await onPreview(preview) }
                }
            } catch is CancellationError {
                await state.markCancelled()
            } catch {
                await state.markFailure(error.localizedDescription)
            }
            if Task.isCancelled || live == nil { await state.markCancelled() }
            // One terminal barrier for success, transport failure and cancellation. Because every
            // delta/preview callback above is awaited, reaching here proves the callback stream is
            // fully drained before either normal reconciliation or a concurrent REST fallback.
            await onDrained()
        }

        var transcription: [String: Any] = ["model": model]
        if !languages.isEmpty { transcription["languages"] = languages }
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        if !prompt.isEmpty { transcription["prompt"] = prompt }
        // `delay: minimal` is a tunable-latency feature of gpt-live-transcribe. The high-accuracy
        // gpt-transcribe route supports committed Realtime turns but rejects this live-only field;
        // sending it there caused a hidden reconnect loop instead of a reusable warm Final socket.
        if minimalDelay { transcription["delay"] = "minimal" }
        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        do {
            try await socket.send(.string(try jsonString(update)))
            try await state.waitUntilReady(timeoutNanoseconds: 4_000_000_000)
            return live
        } catch {
            await live.cancel()
            if let message = await state.error() {
                throw VoiceTranscriptionError.service(message)
            }
            throw error
        }
    }

    func append(_ pcm16: Data) async throws {
        guard !pcm16.isEmpty, !isClosed else { return }
        // Base64's alphabet is JSON-string safe. Building this fixed envelope directly avoids a
        // dictionary and JSONSerialization pass for every 20 ms audio packet (50 times/second).
        let message = Self.audioAppendMessage(pcm16)
        try await webSocket.send(.string(message))
        if let message = await state.error() {
            throw VoiceTranscriptionError.service(message)
        }
    }

    static func audioAppendMessage(_ pcm16: Data) -> String {
        #"{"type":"input_audio_buffer.append","audio":""#
            + pcm16.base64EncodedString() + #""}"#
    }

    func finish() async throws -> String {
        guard !isClosed else { throw VoiceTranscriptionError.cancelled }
        try await webSocket.send(.string(#"{"type":"input_audio_buffer.commit"}"#))
        do {
            let text = try await state.waitForResult(timeoutNanoseconds: 15_000_000_000)
            close(code: .normalClosure)
            return text
        } catch {
            close(code: .goingAway)
            throw error
        }
    }

    func cancel() async {
        close(code: .goingAway)
    }

    func ping() async throws {
        guard !isClosed else { throw VoiceTranscriptionError.cancelled }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            webSocket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func close(code: URLSessionWebSocketTask.CloseCode) {
        closeLock.lock()
        guard !closed else { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        receiveTask?.cancel()
        webSocket.cancel(with: code, reason: nil)
    }

    private var isClosed: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return closed
    }

    private static func jsonString(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoiceTranscriptionError.invalidResponse
        }
        return string
    }
}

// MARK: - Encoders

enum WAVEncoder {
    static func encode(_ audio: VoiceCapturedAudio) -> Data {
        let bytesPerSample: UInt16 = 2
        let channels: UInt16 = 1
        let dataSize = UInt32(clamping: audio.pcm16.count)
        let byteRate = UInt32(audio.sampleRate) * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * bytesPerSample

        var data = Data(capacity: 44 + audio.pcm16.count)
        data.appendASCII("RIFF")
        data.appendLE(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // linear PCM
        data.appendLE(channels)
        data.appendLE(UInt32(audio.sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(UInt16(16))
        data.appendASCII("data")
        data.appendLE(dataSize)
        data.append(audio.pcm16)
        return data
    }
}

private struct MultipartBody {
    let boundary: String
    private var data = Data()

    init(boundary: String) { self.boundary = boundary }

    mutating func addField(name: String, value: String) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(Data(value.utf8))
        data.appendASCII("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data file: Data) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        data.appendASCII("Content-Type: \(contentType)\r\n\r\n")
        data.append(file)
        data.appendASCII("\r\n")
    }

    mutating func finish() -> Data {
        data.appendASCII("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(Data(string.utf8)) }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
