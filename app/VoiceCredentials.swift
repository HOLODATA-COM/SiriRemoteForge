//
//  VoiceCredentials.swift
//  HyperVibe
//
//  Cloud voice credentials never enter config.jsonc, UserDefaults, logs, crash text, or the app
//  bundle. Certificate-bound builds use the login Keychain; public ad-hoc builds use a dedicated,
//  current-user-only JSON file under Application Support so native Voice remains available in beta.
//

import Combine
import Foundation
import Security

enum VoiceCredentialKind: String, CaseIterable {
    case openAI = "openai-api-key"
    case deepSeek = "deepseek-api-key"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        }
    }
}

enum VoiceCredentialStore {
    private static let cacheLock = NSLock()
    private static var cached: [VoiceCredentialKind: String] = [:]
    private static var confirmedMissing = Set<VoiceCredentialKind>()
    private static var loadedAll = false
    private static var mutationGeneration: UInt64 = 0
    private static var resolvedStorageBackend: Backend?

    enum Backend: Equatable {
        case keychain
        case localJSON
    }

    /// UI-safe snapshot. Code-signature validation can consult Security.framework and must not be
    /// performed while SwiftUI is evaluating a view body on the main thread.
    static var cachedBackend: Backend? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return resolvedStorageBackend
    }

    private static func resolveBackend() -> Backend {
        cacheLock.lock()
        if let value = resolvedStorageBackend {
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()

        let value: Backend = VoiceCredentialBrokerClient.shared.isAvailable
            ? .keychain : .localJSON
        cacheLock.lock()
        if resolvedStorageBackend == nil { resolvedStorageBackend = value }
        let resolved = resolvedStorageBackend ?? value
        cacheLock.unlock()
        return resolved
    }

    /// Hot-path/readiness lookup only. It never launches the helper or touches Keychain.
    static func cachedContains(_ kind: VoiceCredentialKind) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cached[kind] != nil
    }

    /// Move the one helper launch away from App startup's main thread. Completion is always on the
    /// main queue so ObservableObject state and coordinator prewarming can update safely.
    static func preload(_ completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = resolveBackend()
            _ = read(.openAI) // one batch request loads both OpenAI and DeepSeek
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func contains(_ kind: VoiceCredentialKind) -> Bool {
        read(kind) != nil
    }

    static func read(_ kind: VoiceCredentialKind) -> String? {
        // Explicit API benchmarks may use caller-provided environment variables, but the normal
        // App never reads shell state. This keeps headless tests independent from the installed
        // credential broker and cannot expose a secret through logs or UI state.
        if CommandLine.arguments.contains("--test-voice-api"),
           let value = ProcessInfo.processInfo.environment[kind.environmentName],
           !value.isEmpty {
            return value
        }

        cacheLock.lock()
        if let value = cached[kind] { cacheLock.unlock(); return value }
        if confirmedMissing.contains(kind) { cacheLock.unlock(); return nil }
        if loadedAll { cacheLock.unlock(); return nil }
        let generation = mutationGeneration
        cacheLock.unlock()

        let brokerResults = VoiceCredentialBrokerClient.shared.readAll()
        let localResults = try? LocalJSONCredentialStore.shared.readAll()

        cacheLock.lock()
        guard mutationGeneration == generation else {
            let value = cached[kind]
            cacheLock.unlock()
            return value
        }
        for candidate in VoiceCredentialKind.allCases {
            let brokerResult = brokerResults?[candidate.rawValue]
            let brokerValue: String? = {
                guard brokerResult?.status == errSecSuccess,
                      let data = brokerResult?.data,
                      let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                    return nil
                }
                return value
            }()
            if let value = brokerValue ?? localResults?[candidate.rawValue], !value.isEmpty {
                cached[candidate] = value
                confirmedMissing.remove(candidate)
            } else {
                confirmedMissing.insert(candidate)
            }
        }
        loadedAll = true
        let value = cached[kind]
        cacheLock.unlock()
        return value
    }

    static func save(_ value: String, as kind: VoiceCredentialKind) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw VoiceCredentialError.empty
        }
        switch resolveBackend() {
        case .keychain:
            let status = VoiceCredentialBrokerClient.shared.save(
                account: kind.rawValue, value: Data(clean.utf8)
            )
            guard status == errSecSuccess else {
                throw VoiceCredentialError.keychain(status)
            }
        case .localJSON:
            do {
                try LocalJSONCredentialStore.shared.save(clean, account: kind.rawValue)
            } catch {
                throw VoiceCredentialError.localStorage
            }
        }
        cacheLock.lock()
        cached[kind] = clean
        confirmedMissing.remove(kind)
        mutationGeneration &+= 1
        cacheLock.unlock()
    }

    static func remove(_ kind: VoiceCredentialKind) throws {
        if resolveBackend() == .keychain {
            let status = VoiceCredentialBrokerClient.shared.remove(account: kind.rawValue)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw VoiceCredentialError.keychain(status)
            }
        }
        do {
            // Remove a legacy beta-file copy too. Otherwise a credential deleted after moving to
            // a certificate-bound build could silently reappear through the read fallback.
            try LocalJSONCredentialStore.shared.remove(account: kind.rawValue)
        } catch {
            throw VoiceCredentialError.localStorage
        }
        cacheLock.lock()
        cached.removeValue(forKey: kind)
        confirmedMissing.insert(kind)
        mutationGeneration &+= 1
        cacheLock.unlock()
    }
}

/// Plaintext fallback for ad-hoc public betas. It is deliberately separate from config.jsonc so a
/// shared configuration never carries paid API credentials. The App is the only supported writer;
/// the file is atomically replaced with mode 0600 inside a mode-0700 Application Support directory.
final class LocalJSONCredentialStore {
    static let shared = LocalJSONCredentialStore()

    private struct Payload: Codable {
        var version = 1
        var credentials: [String: String]
    }

    private let fileManager: FileManager
    private let rootURL: URL
    let credentialsURL: URL
    private let lock = NSLock()

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = rootURL ?? base
            .appendingPathComponent("HyperVibe", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
        credentialsURL = self.rootURL.appendingPathComponent("credentials.json", isDirectory: false)
    }

    func readAll() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return try readAllLocked()
    }

    func save(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var credentials = try readAllLocked()
        credentials[account] = value
        try writeLocked(credentials)
    }

    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: credentialsURL.path) else { return }
        var credentials = try readAllLocked()
        credentials.removeValue(forKey: account)
        if credentials.isEmpty {
            try rejectSymbolicLink(credentialsURL)
            try fileManager.removeItem(at: credentialsURL)
        } else {
            try writeLocked(credentials)
        }
    }

    private func readAllLocked() throws -> [String: String] {
        guard fileManager.fileExists(atPath: credentialsURL.path) else { return [:] }
        try rejectSymbolicLink(credentialsURL)
        let data = try Data(contentsOf: credentialsURL, options: .mappedIfSafe)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1 else { throw StoreError.unsupportedVersion }
        return payload.credentials
    }

    private func writeLocked(_ credentials: [String: String]) throws {
        try prepareDirectory()
        let payload = Payload(credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try data.write(to: credentialsURL, options: .atomic)
        try secure(credentialsURL, permissions: 0o600)
        excludeFromBackup(credentialsURL)
    }

    private func prepareDirectory() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try rejectSymbolicLink(rootURL)
            let attributes = try fileManager.attributesOfItem(atPath: rootURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw StoreError.invalidDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        try secure(rootURL, permissions: 0o700)
        excludeFromBackup(rootURL)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw StoreError.symbolicLink
        }
    }

    private func secure(_ url: URL, permissions: Int) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(permissions))], ofItemAtPath: url.path
        )
    }

    private func excludeFromBackup(_ input: URL) {
        var url = input
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private enum StoreError: Error {
        case invalidDirectory
        case symbolicLink
        case unsupportedVersion
    }
}

private extension VoiceCredentialKind {
    var environmentName: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .deepSeek: return "DEEPSEEK_API_KEY"
        }
    }
}

/// The broker executable is intentionally tiny and version-stable. macOS's legacy login-keychain
/// ACL keys access to the executable CDHash, so isolating credentials here prevents every ordinary
/// HyperVibe UI rebuild from causing another Keychain prompt. Calls are cached above and therefore
/// never occur on the physical button hot path.
private final class VoiceCredentialBrokerClient {
    static let shared = VoiceCredentialBrokerClient()

    private let lock = NSLock()

    struct ReadResult {
        let data: Data?
        let status: OSStatus
    }

    var isAvailable: Bool {
        let brokerURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/HyperVibeCredentialBroker.xpc")
            .appendingPathComponent("Contents/MacOS/HyperVibeCredentialBroker")
        return Self.validBroker(at: brokerURL)
    }

    func readAll() -> [String: ReadResult]? {
        let result = run(arguments: ["--read-credentials"], timeout: 3)
        guard result.status == errSecSuccess, let payload = result.payload,
              let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: [String: Any]] else { return nil }
        var parsed: [String: ReadResult] = [:]
        for (account, entry) in root {
            guard let number = entry["status"] as? NSNumber else { continue }
            let data = (entry["value"] as? String).flatMap { Data(base64Encoded: $0) }
            parsed[account] = ReadResult(data: data, status: OSStatus(number.int32Value))
        }
        return parsed
    }

    func read(account: String) -> (data: Data?, status: OSStatus) {
        let result = run(arguments: ["--read-credential", account], timeout: 3)
        guard result.status == errSecSuccess,
              let encoded = result.payload,
              let data = Data(base64Encoded: encoded) else {
            return (nil, result.status)
        }
        return (data, errSecSuccess)
    }

    func save(account: String, value: Data) -> OSStatus {
        let saved = run(arguments: ["--save-credential", account], input: value,
                        timeout: 30).status
        guard saved == errSecSuccess else { return saved }
        let authorized = run(arguments: ["--authorize-credential", account], timeout: 120).status
        guard authorized == errSecSuccess else { return authorized }
        // "Allow" authorizes only the helper instance above; "Always Allow" also makes this fresh,
        // non-interactive helper read succeed. Never report Saved until persistence is proven.
        return read(account: account).status
    }

    func remove(account: String) -> OSStatus {
        run(arguments: ["--remove-credential", account], timeout: 10).status
    }

    private func run(arguments: [String], input inputData: Data? = nil,
                     timeout: TimeInterval) -> (status: OSStatus, payload: String?) {
        // Serialize helper processes so Keychain mutation and response parsing can never overlap.
        // This path runs only at launch/settings time; the physical-button path reads the cache.
        lock.lock()
        defer { lock.unlock() }
        let brokerURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/HyperVibeCredentialBroker.xpc")
            .appendingPathComponent("Contents/MacOS/HyperVibeCredentialBroker")
        guard Self.validBroker(at: brokerURL) else { return (errSecAuthFailed, nil) }

        let inputPipe = Pipe()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = brokerURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if let inputData {
                try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
            }
            try inputPipe.fileHandleForWriting.close()
            guard finished.wait(timeout: .now() + timeout) == .success else {
                if process.isRunning { process.terminate() }
                return (errSecInteractionNotAllowed, nil)
            }
            let response = output.fileHandleForReading.readDataToEndOfFile()
            let lines = (String(data: response, encoding: .utf8) ?? "")
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = lines.first, let status = Int32(first) else {
                return (errSecInternalError, nil)
            }
            return (OSStatus(status), lines.count > 1 ? String(lines[1]) : nil)
        } catch {
            if process.isRunning { process.terminate() }
            return (errSecNotAvailable, nil)
        }
    }

    private static func validBroker(at url: URL) -> Bool {
        guard let requirementText = peerRequirement(identifier: "com.hypervibe.app.CredentialBroker")
        else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString, [], &requirement
        ) == errSecSuccess, let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Derive the peer requirement from this binary's own designated requirement, preserving its
    /// signing certificate while swapping only the bundle identifier. Identifier-only validation
    /// is forgeable, so ad-hoc builds intentionally cannot invoke the credential broker; a public
    /// build must use a certificate-bound signing workflow before Keychain voice credentials work.
    private static func peerRequirement(identifier: String) -> String? {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var ownRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &ownRequirement) == errSecSuccess,
              let ownRequirement else { return nil }
        var textValue: CFString?
        guard SecRequirementCopyString(ownRequirement, [], &textValue) == errSecSuccess,
              let text = textValue as String? else { return nil }
        guard let range = text.range(of: #"identifier \"[^\"]+\""#,
                                     options: .regularExpression) else { return nil }
        let replaced = text.replacingCharacters(
            in: range, with: "identifier \"\(identifier)\""
        )
        if replaced.contains("certificate leaf") { return replaced }
        return nil
    }
}

enum VoiceCredentialError: LocalizedError {
    case empty
    case keychain(OSStatus)
    case localStorage

    var errorDescription: String? {
        switch self {
        case .empty:
            return L("The API key is empty.")
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return L("Keychain couldn't save the credential: %@", detail)
        case .localStorage:
            return L("The local API credential file is unavailable.")
        }
    }
}

enum VoiceCredentialConnectionState: Equatable {
    case loading
    case saving
    case idle
    case testing
    case valid
    case invalid(String)
}

/// Settings-facing status only. Raw keys never become @Published values and therefore never enter
/// SwiftUI diagnostics or view descriptions.
final class VoiceCredentialModel: ObservableObject {
    @Published private(set) var hasOpenAIKey = false
    @Published private(set) var hasDeepSeekKey = false
    @Published private(set) var openAIConnection: VoiceCredentialConnectionState = .loading
    @Published private(set) var deepSeekConnection: VoiceCredentialConnectionState = .loading
    @Published private(set) var storageBackend: VoiceCredentialStore.Backend?

    private let session: URLSession
    var onCredentialsChanged: (() -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh() {
        hasOpenAIKey = VoiceCredentialStore.cachedContains(.openAI)
        hasDeepSeekKey = VoiceCredentialStore.cachedContains(.deepSeek)
        storageBackend = VoiceCredentialStore.cachedBackend
    }

    func preload() {
        VoiceCredentialStore.preload { [weak self] in
            self?.refresh()
            self?.openAIConnection = .idle
            self?.deepSeekConnection = .idle
            self?.onCredentialsChanged?()
        }
    }

    func save(_ value: String, kind: VoiceCredentialKind,
              completion: @escaping (String?) -> Void) {
        setConnection(.saving, for: kind)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String?
            do {
                try VoiceCredentialStore.save(value, as: kind)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.setConnection(.idle, for: kind)
                if message == nil { self.onCredentialsChanged?() }
                completion(message)
            }
        }
    }

    func remove(_ kind: VoiceCredentialKind,
                completion: @escaping (String?) -> Void) {
        setConnection(.saving, for: kind)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String?
            do {
                try VoiceCredentialStore.remove(kind)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.setConnection(.idle, for: kind)
                if message == nil { self.onCredentialsChanged?() }
                completion(message)
            }
        }
    }

    func test(_ kind: VoiceCredentialKind) {
        guard let key = VoiceCredentialStore.read(kind) else {
            let message = kind == .openAI
                ? VoiceAPIError.missingOpenAIKeyMessage
                : L("API Key is missing · add it in Settings → Voice")
            setConnection(.invalid(message), for: kind)
            return
        }
        setConnection(.testing, for: kind)

        let endpoint: URL
        switch kind {
        case .openAI:
            endpoint = URL(string: "https://api.openai.com/v1/models/gpt-transcribe")!
        case .deepSeek:
            endpoint = URL(string: "https://api.deepseek.com/models")!
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { [weak self] data, response, error in
            let result: VoiceCredentialConnectionState
            if let error {
                result = .invalid(VoiceAPIError.userFacingMessage(for: error))
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = .valid
            } else {
                let http = response as? HTTPURLResponse
                result = .invalid(VoiceAPIError.safeMessage(data: data,
                                                            statusCode: http?.statusCode))
            }
            DispatchQueue.main.async { self?.setConnection(result, for: kind) }
        }.resume()
    }

    private func setConnection(_ state: VoiceCredentialConnectionState,
                               for kind: VoiceCredentialKind) {
        switch kind {
        case .openAI: openAIConnection = state
        case .deepSeek: deepSeekConnection = state
        }
    }
}

enum VoiceAPIError {
    static var missingOpenAIKeyMessage: String {
        L("OpenAI API Key is missing · add and test it in Settings → Voice")
    }

    /// Convert transport and typed Voice errors into one short, actionable vocabulary shared by
    /// the Settings connection row, the persistent status widget and the temporary Voice capsule.
    /// Raw provider strings remain useful for retry classification but never need to fill the UI.
    static func userFacingMessage(for error: Error) -> String {
        if let selection = error as? VoiceSelectionEditError,
           let message = selection.errorDescription {
            return message
        }
        if let voice = error as? VoiceTranscriptionError {
            switch voice {
            case .missingCredential:
                return missingOpenAIKeyMessage
            case .invalidAudio:
                return L("No usable speech · speak for at least one second and try again")
            case .invalidResponse:
                return L("Voice service returned an invalid result · try again")
            case .service(let message):
                return classifiedMessage(raw: message, statusCode: httpStatus(in: message))
            case .timedOut:
                return L("Voice service timed out · check the network and try again")
            case .cancelled:
                return L("Dictation was cancelled.")
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff:
                return L("Can't reach the Voice service · check the network")
            case .timedOut:
                return L("Voice service timed out · check the network and try again")
            default:
                return L("Voice input failed · check Settings → Voice and try again")
            }
        }
        return classifiedMessage(raw: error.localizedDescription, statusCode: nil)
    }

    /// Cloud errors often include request IDs and model details but should never echo credentials
    /// or force a user to interpret an HTTP response.
    static func safeMessage(data: Data?, statusCode: Int?) -> String {
        var raw: String?
        if let data,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            raw = message
        }
        return classifiedMessage(raw: raw, statusCode: statusCode)
    }

    private static func classifiedMessage(raw: String?, statusCode: Int?) -> String {
        let value = raw?.lowercased() ?? ""
        if statusCode == 401 || statusCode == 403
            || value.contains("invalid_api_key") || value.contains("incorrect api key")
            || value.contains("authentication") || value.contains("unauthorized") {
            return L("API Key is invalid · replace and test it in Settings → Voice")
        }
        if statusCode == 429 || value.contains("insufficient_quota")
            || value.contains("quota") || value.contains("rate limit")
            || value.contains("billing") {
            return L("API quota is unavailable or rate-limited · check the account")
        }
        if value.contains("model_not_found") || value.contains("unsupported model")
            || value.contains("invalid model") || value.contains("model does not exist") {
            return L("Selected Voice model is unavailable · change it in Settings → Voice")
        }
        if let statusCode, (500...599).contains(statusCode) {
            return L("Voice service is temporarily unavailable · try again shortly")
        }
        if statusCode != nil {
            return L("Voice request was rejected · check Settings → Voice and try again")
        }
        if value.contains("network") || value.contains("connection")
            || value.contains("offline") || value.contains("timed out") {
            return L("Can't reach the Voice service · check the network")
        }
        return L("Voice input failed · check Settings → Voice and try again")
    }

    private static func httpStatus(in message: String) -> Int? {
        let pattern = #"(?i)http\s+([1-5][0-9]{2})"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: message, range: NSRange(message.startIndex..., in: message)
              ),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }
}
