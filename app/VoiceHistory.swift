//
//  VoiceHistory.swift
//  HyperVibe
//
//  Small, app-scoped memory for ordinary dictation. Existing appProfiles are reused as style
//  groups; apps without an explicit profile keep an independent bundle-scoped history.
//

import AppKit
import ApplicationServices
import Foundation

struct VoicePromptContext: Equatable, Sendable {
    let styleKey: String
    let bundleIdentifier: String?
    let applicationName: String

    static func resolve(bundleIdentifier: String?, applicationName: String,
                        appProfiles: [String: String]) -> VoicePromptContext {
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundle, !bundle.isEmpty,
           let profile = appProfiles[bundle]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profile.isEmpty {
            return VoicePromptContext(
                styleKey: "group:\(profile.lowercased())",
                bundleIdentifier: bundle,
                applicationName: name
            )
        }
        if let bundle, !bundle.isEmpty {
            return VoicePromptContext(
                styleKey: "app:\(bundle.lowercased())",
                bundleIdentifier: bundle,
                applicationName: name
            )
        }
        let stableName = name.isEmpty ? "unknown" : name.lowercased()
        return VoicePromptContext(
            styleKey: "app-name:\(stableName)",
            bundleIdentifier: nil,
            applicationName: name
        )
    }
}

struct VoiceHistoryExample: Codable, Equatable, Sendable {
    let sourceTranscript: String
    let finalText: String

    enum CodingKeys: String, CodingKey {
        case sourceTranscript = "source_transcript"
        case finalText = "final_text"
    }
}

private struct VoiceHistoryRecord: Codable {
    let id: UUID
    let timestamp: Date
    let styleKey: String
    let bundleIdentifier: String?
    let applicationName: String
    let sourceTranscript: String
    let finalText: String
}

/// History is deliberately serialized away from the main actor. A synchronous prompt read drains
/// earlier queued writes first, so the next dictation can immediately learn from the previous one.
final class VoiceHistoryStore: @unchecked Sendable {
    static let shared = VoiceHistoryStore()

    private struct Payload: Codable {
        var version = 1
        var recordsByStyle: [String: [VoiceHistoryRecord]] = [:]
    }

    private let fileManager: FileManager
    private let rootURL: URL
    let historyURL: URL
    private let queue = DispatchQueue(label: "com.hypervibe.voice-history", qos: .utility)
    private var cachedPayload: Payload?

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = rootURL ?? base
            .appendingPathComponent("HyperVibe", isDirectory: true)
            .appendingPathComponent("VoiceHistory", isDirectory: true)
        historyURL = self.rootURL.appendingPathComponent("history.json", isDirectory: false)
    }

    func preload() {
        queue.async { [self] in _ = loadLocked() }
    }

    func append(id: UUID, sourceTranscript: String, finalText: String,
                context: VoicePromptContext) {
        let source = Self.bounded(sourceTranscript)
        let output = Self.bounded(finalText)
        guard !source.isEmpty, !output.isEmpty else { return }
        queue.async { [self] in
            var payload = loadLocked()
            var records = payload.recordsByStyle[context.styleKey] ?? []
            records.append(VoiceHistoryRecord(
                id: id, timestamp: Date(), styleKey: context.styleKey,
                bundleIdentifier: context.bundleIdentifier,
                applicationName: context.applicationName,
                sourceTranscript: source, finalText: output
            ))
            if records.count > 100 { records.removeFirst(records.count - 100) }
            payload.recordsByStyle[context.styleKey] = records
            do {
                try writeLocked(payload)
                cachedPayload = payload
            } catch {
                // The voice result has already been delivered. History must remain an optional
                // quality layer and can never turn successful dictation into a visible failure.
                print("Voice history write failed: \(error.localizedDescription)")
            }
        }
    }

    func replaceFinalText(id: UUID, with finalText: String, context: VoicePromptContext) {
        let output = Self.bounded(finalText)
        guard !output.isEmpty else { return }
        queue.async { [self] in
            var payload = loadLocked()
            guard var records = payload.recordsByStyle[context.styleKey],
                  let index = records.lastIndex(where: { $0.id == id }) else { return }
            let old = records[index]
            records[index] = VoiceHistoryRecord(
                id: old.id, timestamp: old.timestamp, styleKey: old.styleKey,
                bundleIdentifier: old.bundleIdentifier, applicationName: old.applicationName,
                sourceTranscript: old.sourceTranscript, finalText: output
            )
            payload.recordsByStyle[context.styleKey] = records
            do {
                try writeLocked(payload)
                cachedPayload = payload
            } catch {
                print("Voice history correction write failed: \(error.localizedDescription)")
            }
        }
    }

    func recent(for context: VoicePromptContext, limit: Int = 20,
                characterBudget: Int = 12_000) -> [VoiceHistoryExample] {
        queue.sync { [self] in
            let records = loadLocked().recordsByStyle[context.styleKey] ?? []
            var remaining = max(0, characterBudget)
            var newestFirst: [VoiceHistoryExample] = []
            for record in records.reversed().prefix(max(0, limit)) {
                let cost = record.sourceTranscript.count + record.finalText.count
                guard cost <= remaining || newestFirst.isEmpty else { break }
                newestFirst.append(VoiceHistoryExample(
                    sourceTranscript: record.sourceTranscript,
                    finalText: record.finalText
                ))
                remaining = max(0, remaining - cost)
            }
            return newestFirst.reversed()
        }
    }

    /// Test/support synchronization; production prompt reads already provide the same ordering.
    func flush() { queue.sync {} }

    func storedCount(for context: VoicePromptContext) -> Int {
        queue.sync { [self] in
            loadLocked().recordsByStyle[context.styleKey]?.count ?? 0
        }
    }

    private func loadLocked() -> Payload {
        if let cachedPayload { return cachedPayload }
        guard fileManager.fileExists(atPath: historyURL.path) else {
            let empty = Payload()
            cachedPayload = empty
            return empty
        }
        do {
            try rejectSymbolicLink(historyURL)
            let data = try Data(contentsOf: historyURL, options: .mappedIfSafe)
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            guard decoded.version == 1 else { throw StoreError.unsupportedVersion }
            cachedPayload = decoded
            return decoded
        } catch {
            print("Voice history read failed: \(error.localizedDescription)")
            let empty = Payload()
            cachedPayload = empty
            return empty
        }
    }

    private func writeLocked(_ payload: Payload) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        try data.write(to: historyURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: historyURL.path
        )
        excludeFromBackup(historyURL)
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
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootURL.path
        )
        excludeFromBackup(rootURL)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw StoreError.symbolicLink
        }
    }

    private func excludeFromBackup(_ input: URL) {
        var url = input
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func bounded(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(8_000))
    }

    private enum StoreError: Error {
        case invalidDirectory
        case symbolicLink
        case unsupportedVersion
    }
}

/// Observes only the accessibility value of the exact field HyperVibe just inserted into. It does
/// not install a keyboard event tap and never forwards the pre-existing field contents. A stable,
/// bounded rewrite of the inserted span becomes feedback for the matching history record.
final class VoiceCorrectionMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hypervibe.voice-correction-monitor",
                                      qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var generation = 0

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func observe(target: VoiceTextTarget, insertedText: String,
                 onCorrection: @escaping (String) -> Void) {
        guard let element = target.focusedElement,
              let originalValue = target.valueBeforeInsertion,
              let originalRange = target.selectedRangeBeforeInsertion,
              originalRange.location >= 0, originalRange.length >= 0,
              originalRange.location + originalRange.length <= originalValue.utf16.count,
              !insertedText.isEmpty else { return }

        let original = originalValue as NSString
        let prefix = original.substring(to: originalRange.location)
        let suffix = original.substring(from: originalRange.location + originalRange.length)
        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()
        queue.async { [self] in
            AXUIElementSetMessagingTimeout(element, 0.025)
            var pending: String?
            var stableTicks = 0
            // 75 × 0.4 s: enough time for a deliberate backspace/retype correction without
            // retaining the target for the rest of the app session.
            for _ in 0..<75 {
                guard isCurrent(token) else { return }
                Thread.sleep(forTimeInterval: 0.4)
                guard isCurrent(token),
                      let candidate = Self.insertedSpan(
                        element: element, prefix: prefix, suffix: suffix
                      ) else { return }
                guard candidate != insertedText else {
                    pending = nil
                    stableTicks = 0
                    continue
                }
                guard Self.isPlausibleCorrection(candidate, of: insertedText) else { continue }
                if candidate == pending {
                    stableTicks += 1
                } else {
                    pending = candidate
                    stableTicks = 1
                }
                if stableTicks >= 3 {
                    onCorrection(candidate)
                    return
                }
            }
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private static func insertedSpan(element: AXUIElement, prefix: String,
                                     suffix: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success, let current = value as? String,
              current.utf16.count <= 100_000,
              current.hasPrefix(prefix), current.hasSuffix(suffix) else { return nil }
        let valueString = current as NSString
        let start = (prefix as NSString).length
        let end = valueString.length - (suffix as NSString).length
        guard end >= start else { return nil }
        return valueString.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlausibleCorrection(_ candidate: String, of original: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 8_000 else { return false }
        let ratio = Double(candidate.count) / Double(max(1, original.count))
        guard ratio >= 0.40 && ratio <= 2.0 else { return false }
        // The cleanup guard is intentionally permissive for one-word technical corrections (for
        // example an ASR homophone) and conservative for longer unrelated replacement text.
        return VoiceTextProcessor.isPlausibleRewrite(candidate, original: original)
            || VoiceTextProcessor.isPlausibleRewrite(original, original: candidate)
    }
}
