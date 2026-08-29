//
//  VoiceTextDelivery.swift
//  HyperVibe
//
//  Captures the user's real text target before the non-activating Voice HUD appears, then delivers
//  text without stealing focus. Final mode starts with a guarded Command-V transaction because
//  Chromium can report a successful AX write without emitting a DOM input event; native AX and
//  Unicode CGEvents remain independent fallbacks. Streaming stays clipboard-free.
//

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

struct VoiceTextTarget: @unchecked Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let focusedElement: AXUIElement?
    let focusSignature: VoiceTextFocusSignature?
    let selectedTextSettable: Bool
    let isSecure: Bool
}

/// Long-lived AX element references are not stable in every editor. React/Electron applications
/// can rebuild the accessibility node for the same visible composer while Voice is listening.
/// Keep semantic and geometric identity beside the raw node so that a same-field replacement can
/// be accepted without weakening the app/window/focus safety checks.
struct VoiceTextFocusSignature: Equatable {
    let role: String?
    let subrole: String?
    let identifier: String?
    let placeholder: String?
    let frame: CGRect?
    let selectedTextSettable: Bool

    var isEditableText: Bool {
        if selectedTextSettable { return true }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        default:
            return false
        }
    }

    /// True only when two different AX nodes still describe the same visible editor. A stable
    /// identifier is strongest. Otherwise their editable role, placeholder (when both exist), and
    /// substantially overlapping screen bounds must agree. Two unrelated fields therefore remain
    /// rejected even inside the same frontmost app.
    func isCompatibleReplacement(for original: VoiceTextFocusSignature) -> Bool {
        guard isEditableText, original.isEditableText else { return false }
        if let oldID = Self.nonEmpty(original.identifier),
           let newID = Self.nonEmpty(identifier) {
            return oldID == newID
        }
        guard Self.textRoleFamily(role) == Self.textRoleFamily(original.role) else {
            return false
        }
        if let oldPlaceholder = Self.nonEmpty(original.placeholder),
           let newPlaceholder = Self.nonEmpty(placeholder),
           oldPlaceholder != newPlaceholder {
            return false
        }
        guard let oldFrame = original.frame, let newFrame = frame,
              oldFrame.width > 0, oldFrame.height > 0,
              newFrame.width > 0, newFrame.height > 0 else { return false }
        let overlap = oldFrame.intersection(newFrame)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        let smallerArea = min(oldFrame.width * oldFrame.height,
                              newFrame.width * newFrame.height)
        return overlap.width * overlap.height / smallerArea >= 0.58
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func textRoleFamily(_ role: String?) -> String? {
        switch role {
        case "AXTextField", "AXTextArea":
            return "text"
        case "AXComboBox":
            return "combo"
        default:
            return role
        }
    }
}

/// The only target information captured synchronously on the raw press edge. NSWorkspace's
/// frontmost-process lookup is local and fast; all cross-process AX messaging is resolved off the
/// main thread from this immutable seed.
struct VoiceTextTargetSeed: Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let applicationName: String
}

enum VoiceTextDeliveryOutcome: Equatable {
    case inserted
    case copied
    case focusChanged
    case secureField
    case unavailable

    var wasDelivered: Bool {
        self == .inserted || self == .copied
    }
}

enum VoiceFinalDeliveryMethod: String, Equatable {
    case clipboardPaste
    case accessibilitySelectedText
    case unicodeEvents
}

/// NSPasteboard does not expose a lossless snapshot primitive. Preserve every item/type as bytes,
/// then restore only if the marker and changeCount prove nobody touched the clipboard meanwhile.
private struct VoicePasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// Cross-process Accessibility calls are synchronous Mach IPC and can stall even with a messaging
/// timeout. Keep every dynamic focus/security check and AX write on one ordered worker so a slow
/// editor cannot freeze the HUD or the rest of HyperVibe's main run loop.
private final class VoiceTextDeliveryWorker: @unchecked Sendable {
    private static let pasteKeyCode: CGKeyCode = 9
    private let queue = DispatchQueue(label: "com.hypervibe.voice-text-delivery",
                                      qos: .userInitiated)
    private let eventSource: CGEventSource?

    init() {
        eventSource = CGEventSource(stateID: .privateState)
        eventSource?.localEventsSuppressionInterval = 0
    }

    func insertStreamingDelta(_ delta: String,
                              into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await perform {
            guard !delta.isEmpty else { return .inserted }
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            if target.selectedTextSettable, target.focusedElement != nil {
                if let rejection = Self.immediateMutationRejection(
                    target, verifyFocusedElement: true
                ) { return rejection }
                if Self.setSelectedText(delta, target: target) { return .inserted }
            }
            return self.postUnicode(delta, target: target)
        }
    }

    /// Returns nil only when the target is still safe but does not expose settable AX text.
    func insertSelectedText(_ text: String,
                            into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        await perform {
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            guard target.selectedTextSettable, target.focusedElement != nil else { return nil }
            if let rejection = Self.immediateMutationRejection(
                target, verifyFocusedElement: true
            ) { return rejection }
            return Self.setSelectedText(text, target: target) ? .inserted : nil
        }
    }

    func insertUnicode(_ text: String,
                       into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await perform {
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            return self.postUnicode(text, target: target)
        }
    }

    func postPasteShortcut(into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await perform {
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            guard AXIsProcessTrusted(), let eventSource = self.eventSource,
                  let commandDown = CGEvent(keyboardEventSource: eventSource,
                                            virtualKey: 0x37, keyDown: true),
                  let vDown = CGEvent(keyboardEventSource: eventSource,
                                      virtualKey: Self.pasteKeyCode, keyDown: true),
                  let vUp = CGEvent(keyboardEventSource: eventSource,
                                    virtualKey: Self.pasteKeyCode, keyDown: false),
                  let commandUp = CGEvent(keyboardEventSource: eventSource,
                                          virtualKey: 0x37, keyDown: false) else {
                return .unavailable
            }
            // Event construction is complete; this is the last possible guard before mutating the
            // newly focused app. It closes the AX-query-to-paste TOCTOU window.
            if let rejection = Self.immediateMutationRejection(
                target, verifyFocusedElement: true
            ) { return rejection }
            commandDown.flags = .maskCommand
            vDown.flags = .maskCommand
            vUp.flags = .maskCommand
            commandUp.flags = []
            commandDown.post(tap: .cghidEventTap)
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)
            commandUp.post(tap: .cghidEventTap)
            return .inserted
        }
    }

    func rejection(of target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        await perform {
            Self.targetRejection(target, currentPID: Self.currentFrontmostPID())
        }
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }

    private static func targetRejection(
        _ target: VoiceTextTarget, currentPID: pid_t?
    ) -> VoiceTextDeliveryOutcome? {
        if target.isSecure || IsSecureEventInputEnabled() { return .secureField }
        guard currentPID == target.pid else { return .focusChanged }
        // Some web views expose no focused AX element. PID stability is the strongest available
        // signal there; sparse accessibility alone must not make those editors unusable.
        guard let original = target.focusedElement else { return nil }
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.008)
        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &currentValue
        ) == .success,
              let currentValue else { return .focusChanged }
        let current = currentValue as! AXUIElement
        AXUIElementSetMessagingTimeout(current, 0.008)
        let role = attributeString(current, kAXRoleAttribute)
        let subrole = attributeString(current, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField"
            || IsSecureEventInputEnabled() {
            return .secureField
        }
        if CFEqual(original, currentValue) { return nil }
        guard let originalSignature = target.focusSignature else { return .focusChanged }
        let currentSignature = focusSignature(
            current, selectedTextSettable: selectedTextIsSettable(current)
        )
        return currentSignature.isCompatibleReplacement(for: originalSignature)
            ? nil : .focusChanged
    }

    /// Fetch the frontmost PID immediately before the AX check/write, on the same ordered worker.
    /// Callers await this worker asynchronously, so synchronising this tiny AppKit lookup onto the
    /// main queue cannot block the UI and closes the old focus-change TOCTOU window.
    private static func currentFrontmostPID() -> pid_t? {
        DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    /// A full target check above may spend several milliseconds in cross-process AX. Repeat only
    /// the two safety-critical observations immediately before mutation so an intervening App
    /// switch or Secure Input transition can never redirect dictated text.
    private static func immediateMutationRejection(
        _ target: VoiceTextTarget, verifyFocusedElement: Bool
    ) -> VoiceTextDeliveryOutcome? {
        if target.isSecure || IsSecureEventInputEnabled() { return .secureField }
        guard currentFrontmostPID() == target.pid else { return .focusChanged }
        guard verifyFocusedElement, let original = target.focusedElement else { return nil }
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.002)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue else { return .focusChanged }
        if CFEqual(original, focusedValue) { return nil }
        guard let originalSignature = target.focusSignature else { return .focusChanged }
        let current = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(current, 0.002)
        let currentSignature = focusSignature(
            current, selectedTextSettable: selectedTextIsSettable(current)
        )
        return currentSignature.isCompatibleReplacement(for: originalSignature)
            ? nil : .focusChanged
    }

    private static func setSelectedText(_ text: String, target: VoiceTextTarget) -> Bool {
        guard target.selectedTextSettable, let element = target.focusedElement else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    private func postUnicode(
        _ text: String, target: VoiceTextTarget
    ) -> VoiceTextDeliveryOutcome {
        guard AXIsProcessTrusted(), let eventSource else { return .unavailable }
        for chunk in VoiceTextDeliverer.unicodeChunks(text, maximumUTF16Units: 20) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource,
                                     virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource,
                                   virtualKey: 0, keyDown: false) else { return .unavailable }
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            // Re-check every chunk. A long multilingual transcript can span many CGEvents, and a
            // mid-insertion App switch must stop before the next chunk reaches the new destination.
            if let rejection = Self.immediateMutationRejection(
                target, verifyFocusedElement: true
            ) { return rejection }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return .inserted
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func selectedTextIsSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success && settable.boolValue
    }

    fileprivate static func focusSignature(
        _ element: AXUIElement, selectedTextSettable: Bool
    ) -> VoiceTextFocusSignature {
        VoiceTextFocusSignature(
            role: attributeString(element, kAXRoleAttribute),
            subrole: attributeString(element, kAXSubroleAttribute),
            identifier: attributeString(element, kAXIdentifierAttribute),
            placeholder: attributeString(element, kAXPlaceholderValueAttribute),
            frame: elementFrame(element),
            selectedTextSettable: selectedTextSettable
        )
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue
              ) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

final class VoiceTextDeliverer {
    private static let markerType = NSPasteboard.PasteboardType(
        "com.hypervibe.voice-input.clipboard-transaction"
    )
    private let worker = VoiceTextDeliveryWorker()

    /// Final Voice values compatibility over microbenchmarks: native AX writes can return success
    /// for Chromium contenteditable nodes without dispatching the DOM input event. A guarded paste
    /// produces the same event path as the user's working Command-V, while the transaction below
    /// restores their clipboard when configured. AX and Unicode remain independent fallbacks.
    static let finalDeliveryOrder: [VoiceFinalDeliveryMethod] = [
        .clipboardPaste, .accessibilitySelectedText, .unicodeEvents,
    ]

    init() {}

    @MainActor
    func captureTargetSeed() -> VoiceTextTargetSeed? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return VoiceTextTargetSeed(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? L("Current App")
        )
    }

    /// Cross-process Accessibility queries can block a caller despite the target being otherwise
    /// healthy. Resolve them on a worker and bound each element's messaging time so neither a bad
    /// editor nor a hung app can move the physical 0.2-second Voice threshold.
    nonisolated static func resolveTarget(_ seed: VoiceTextTargetSeed) -> VoiceTextTarget {
        let appElement = AXUIElementCreateApplication(seed.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.08)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        let focused = focusedResult == .success
            ? (focusedValue as! AXUIElement?) : nil

        var selectedTextSettable: DarwinBoolean = false
        if let focused {
            AXUIElementSetMessagingTimeout(focused, 0.025)
            AXUIElementIsAttributeSettable(
                focused, kAXSelectedTextAttribute as CFString, &selectedTextSettable
            )
        }

        let role = focused.flatMap { Self.attributeString($0, kAXRoleAttribute) }
        let subrole = focused.flatMap { Self.attributeString($0, kAXSubroleAttribute) }
        let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
            || IsSecureEventInputEnabled()

        return VoiceTextTarget(
            pid: seed.pid,
            bundleIdentifier: seed.bundleIdentifier,
            applicationName: seed.applicationName,
            focusedElement: focused,
            focusSignature: focused.map {
                VoiceTextDeliveryWorker.focusSignature(
                    $0, selectedTextSettable: selectedTextSettable.boolValue
                )
            },
            selectedTextSettable: selectedTextSettable.boolValue,
            isSecure: isSecure
        )
    }

    /// True deltas only: the caller must never pass the cumulative preview here. There is no
    /// clipboard round-trip in the live path, so a partial result reaches the caret in one runloop.
    func insertStreamingDelta(_ delta: String,
                              into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await worker.insertStreamingDelta(delta, into: target)
    }

    @MainActor
    func deliverFinal(_ text: String,
                      to target: VoiceTextTarget?,
                      settings: Config.DictationSettings) async -> VoiceTextDeliveryOutcome {
        guard !text.isEmpty else { return .unavailable }
        guard settings.autoInsert, let target else {
            rmDebug("📝 voice-delivery final route=copy reason=no-target-or-auto-insert-off")
            return settings.copyOnFailure ? copy(text) : .unavailable
        }
        let bundle = target.bundleIdentifier ?? "unknown"
        let role = target.focusSignature?.role ?? "none"
        rmDebug("📝 voice-delivery final begin app=\(bundle) role=\(role) "
                + "axSelected=\(target.selectedTextSettable)")

        var lastOutcome: VoiceTextDeliveryOutcome = .unavailable
        for method in Self.finalDeliveryOrder {
            let outcome: VoiceTextDeliveryOutcome?
            switch method {
            case .clipboardPaste:
                outcome = await pasteViaClipboard(
                    text, target: target,
                    restore: settings.restoreClipboardAfterInsert
                )
            case .accessibilitySelectedText:
                outcome = await worker.insertSelectedText(text, into: target)
            case .unicodeEvents:
                outcome = await worker.insertUnicode(text, into: target)
            }
            guard let outcome else {
                rmDebug("📝 voice-delivery final route=\(method.rawValue) result=unsupported")
                continue
            }
            rmDebug("📝 voice-delivery final route=\(method.rawValue) result=\(outcome)")
            switch outcome {
            case .inserted:
                return .inserted
            case .secureField:
                return .secureField
            case .focusChanged:
                return settings.copyOnFailure ? copy(text) : .focusChanged
            case .copied:
                return .copied
            case .unavailable:
                lastOutcome = outcome
            }
        }
        let fallback = settings.copyOnFailure ? copy(text) : lastOutcome
        rmDebug("📝 voice-delivery final route=copy-fallback result=\(fallback)")
        return fallback
    }

    @MainActor
    @discardableResult
    func copy(_ text: String) -> VoiceTextDeliveryOutcome {
        guard !text.isEmpty else { return .unavailable }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string) ? .copied : .unavailable
    }

    func targetRejection(_ target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        await worker.rejection(of: target)
    }

    @MainActor
    private func pasteViaClipboard(_ text: String, target: VoiceTextTarget,
                                   restore: Bool) async -> VoiceTextDeliveryOutcome {
        if let rejection = await targetRejection(target) { return rejection }
        guard AXIsProcessTrusted() else { return .unavailable }
        let pasteboard = NSPasteboard.general
        let snapshot = VoicePasteboardSnapshot(pasteboard)
        let marker = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(marker, forType: Self.markerType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return .unavailable }
        let transactionChangeCount = pasteboard.changeCount
        let restoreIfOwned = {
            let markerSurvived = pasteboard.changeCount == transactionChangeCount
                && pasteboard.string(forType: Self.markerType) == marker
            if markerSurvived { snapshot.restore(to: pasteboard) }
        }

        // Give Chromium/WebKit one event turn to observe the new pasteboard ownership.
        try? await Task.sleep(nanoseconds: 25_000_000)
        let pasteOutcome = await worker.postPasteShortcut(into: target)
        guard pasteOutcome == .inserted else {
            restoreIfOwned()
            return pasteOutcome
        }

        // Do not charge the async web-editor consumption window to perceived insertion latency.
        // Restoration remains conditional on both the marker and changeCount, so a clipboard change
        // made by the user during this window always wins.
        if restore {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                restoreIfOwned()
            }
        }
        return .inserted
    }

    static func unicodeChunks(_ text: String, maximumUTF16Units: Int) -> [String] {
        guard maximumUTF16Units > 0, !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var count = 0
        for character in text {
            let units = String(character).utf16.count
            if !current.isEmpty, count + units > maximumUTF16Units {
                result.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func attributeString(
        _ element: AXUIElement, _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
