//
//  VoiceTextDelivery.swift
//  HyperVibe
//
//  Captures the user's real text target before the non-activating Voice HUD appears, then delivers
//  text without stealing focus. Final mode starts with a guarded Command-V transaction because
//  Chromium can report a successful AX write without emitting a DOM input event; native AX and
//  Unicode CGEvents remain independent fallbacks. Streaming stays clipboard-free until direct
//  delivery fails, when the authoritative completed result is always preserved there.
//

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CryptoKit
import Foundation

struct VoiceTextTarget: @unchecked Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let focusedElement: AXUIElement?
    let focusSignature: VoiceTextFocusSignature?
    /// Exact AX selection captured on the physical press edge. A nil value is different from an
    /// empty selection: nil means the target did not expose readable Accessibility selection data.
    let selectedText: String?
    let selectedTextReadable: Bool
    let selectedTextSettable: Bool
    let isSecure: Bool
    /// A bounded pre-insertion snapshot enables correction learning without observing global keys.
    /// It is retained only for the active turn and is never written to history.
    let valueBeforeInsertion: String?
    let selectedRangeBeforeInsertion: CFRange?

    init(pid: pid_t, bundleIdentifier: String?, applicationName: String,
         focusedElement: AXUIElement?, focusSignature: VoiceTextFocusSignature?,
         selectedText: String?, selectedTextReadable: Bool,
         selectedTextSettable: Bool, isSecure: Bool,
         valueBeforeInsertion: String? = nil,
         selectedRangeBeforeInsertion: CFRange? = nil) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.focusedElement = focusedElement
        self.focusSignature = focusSignature
        self.selectedText = selectedText
        self.selectedTextReadable = selectedTextReadable
        self.selectedTextSettable = selectedTextSettable
        self.isSecure = isSecure
        self.valueBeforeInsertion = valueBeforeInsertion
        self.selectedRangeBeforeInsertion = selectedRangeBeforeInsertion
    }

    func withCompatibilitySelection(_ text: String) -> Self {
        Self(pid: pid, bundleIdentifier: bundleIdentifier, applicationName: applicationName,
             focusedElement: focusedElement, focusSignature: focusSignature,
             selectedText: text, selectedTextReadable: true,
             selectedTextSettable: selectedTextSettable, isSecure: isSecure,
             valueBeforeInsertion: valueBeforeInsertion,
             selectedRangeBeforeInsertion: selectedRangeBeforeInsertion)
    }

    var selectionState: VoiceTextSelectionState {
        if isSecure { return .secure }
        // Selection editing is opt-in by positive evidence: only a readable, non-empty selection
        // may divert the turn away from ordinary dictation. A large class of writable web/Electron
        // editors exposes an empty AXSelectedText value but reports that attribute as non-settable;
        // treating that combination as read-only rejected every normal Voice turn before delivery.
        // Missing/empty selection metadata therefore means "no detected selection", not "this
        // editor is read-only". Real delivery still performs its independent focus/secure checks.
        guard focusedElement != nil, selectedTextReadable,
              let selectedText, !selectedText.isEmpty else { return .none }
        // Some Electron/custom editors (including WeChat) expose a real editable text role but
        // mark AXSelectedText non-settable. Their normal Command-V path can still replace the
        // active selection, so treating that role as read-only would unnecessarily discard a
        // perfectly replaceable edit.
        return selectedTextSettable || focusSignature?.isEditableText == true
            ? .editable(text: selectedText) : .readOnly(text: selectedText)
    }
}

enum VoiceTextSelectionState: Equatable {
    case none
    case editable(text: String)
    case readOnly(text: String?)
    case secure
}

enum VoiceSelectionReplacementOutcome: Equatable {
    case replaced
    case focusChanged
    case selectionChanged
    case readOnly
    case secureField
    case accessibilityUnavailable
    case unconfirmed
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
    /// Paste was dispatched but editor consumption is unproven; verified text remains copied.
    case pasteSent
    /// Paste may have happened, but neither insertion nor clipboard retention is confirmed.
    case unconfirmed
    case focusChanged
    case secureField
    case unavailable

    var wasDelivered: Bool {
        self == .inserted || self == .copied || self == .pasteSent
    }
}

enum VoiceShortcutDispatchOutcome: Equatable {
    case sent, focusChanged, secureField, unavailable, cancelled
}

/// Cross-thread cancellation must be checked on the event worker, immediately before dispatch.
private final class VoiceDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct VoiceInsertionSnapshot {
    let value: String
    let selection: CFRange?

    func confirms(_ text: String, after: String) -> Bool {
        guard !text.isEmpty, after != value else { return false }
        let original = value as NSString
        if let selection {
            guard selection.location >= 0, selection.length >= 0,
                  selection.location <= original.length,
                  selection.length <= original.length - selection.location else { return false }
            return original.replacingCharacters(
                in: NSRange(location: selection.location, length: selection.length), with: text
            ) == after
        }
        // Without a caret range accept only one exact insertion, never a coincidental substring.
        let old = Array(value.utf16), new = Array(after.utf16), inserted = Array(text.utf16)
        guard new.count == old.count + inserted.count else { return false }
        var prefix = 0
        while prefix < old.count, old[prefix] == new[prefix] { prefix += 1 }
        return Array(new[prefix..<(prefix + inserted.count)]) == inserted
            && Array(new[(prefix + inserted.count)...]) == Array(old[prefix...])
    }
}

/// What a failed focused-element query means for delivery. A query that merely timed out
/// (`cannotComplete`: the app is busy or slow to answer) says nothing about where focus is; the PID
/// and Secure Input checks that run before it have already passed, so it must not discard the
/// dictation. Only a definite answer -- there is no focused element -- still rejects.
enum VoiceFocusQueryPolicy {
    static func outcome(for error: AXError) -> VoiceTextDeliveryOutcome? {
        error == .cannotComplete ? nil : .focusChanged
    }
}

enum VoiceFinalDeliveryMethod: String, Equatable {
    case clipboardPaste
    case accessibilitySelectedText
    case unicodeEvents
}

/// NSPasteboard does not expose a lossless snapshot primitive. Preserve every item/type as bytes,
/// then restore only if the marker and changeCount prove nobody touched the clipboard meanwhile.
struct VoicePasteboardSnapshot {
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
    private static let copyKeyCode: CGKeyCode = 8
    private let queue = DispatchQueue(label: "com.hypervibe.voice-text-delivery",
                                      qos: .userInitiated)
    private let eventSource: CGEventSource?

    init() {
        eventSource = CGEventSource(stateID: .privateState)
        eventSource?.localEventsSuppressionInterval = 0
    }

    func insertStreamingDelta(_ delta: String,
                              into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await performCancellable(cancelled: .unavailable) { cancellation in
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
                guard !cancellation.isCancelled else { return .unavailable }
                if Self.setSelectedText(delta, target: target) { return .inserted }
            }
            return self.postUnicode(delta, target: target, cancellation: cancellation)
        }
    }

    /// Returns nil only when the target is still safe but does not expose settable AX text.
    func insertSelectedText(_ text: String,
                            into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        let cancelled: VoiceTextDeliveryOutcome? = .unavailable
        return await performCancellable(cancelled: cancelled) { cancellation in
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            guard target.selectedTextSettable, target.focusedElement != nil else { return nil }
            if let rejection = Self.immediateMutationRejection(
                target, verifyFocusedElement: true
            ) { return rejection }
            guard !cancellation.isCancelled else { return .unavailable }
            return Self.setSelectedText(text, target: target) ? .inserted : nil
        }
    }

    func insertUnicode(_ text: String,
                       into target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome {
        await performCancellable(cancelled: .unavailable) { cancellation in
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection
            }
            return self.postUnicode(text, target: target, cancellation: cancellation)
        }
    }

    func postPasteShortcut(into target: VoiceTextTarget) async -> VoiceShortcutDispatchOutcome {
        await postCommandShortcut(keyCode: Self.pasteKeyCode, into: target)
    }

    func postCopyShortcut(into target: VoiceTextTarget) async -> VoiceShortcutDispatchOutcome {
        await postCommandShortcut(keyCode: Self.copyKeyCode, into: target)
    }

    private func postCommandShortcut(keyCode: CGKeyCode,
                                     into target: VoiceTextTarget) async
        -> VoiceShortcutDispatchOutcome {
        let cancellation = VoiceDeliveryCancellation()
        return await withTaskCancellationHandler(operation: {
        await perform {
            guard !cancellation.isCancelled else { return .cancelled }
            if let rejection = Self.targetRejection(
                target, currentPID: Self.currentFrontmostPID()
            ) {
                return rejection == .secureField ? .secureField : .focusChanged
            }
            guard AXIsProcessTrusted(), let eventSource = self.eventSource,
                  let commandDown = CGEvent(keyboardEventSource: eventSource,
                                            virtualKey: 0x37, keyDown: true),
                  let keyDown = CGEvent(keyboardEventSource: eventSource,
                                        virtualKey: keyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: eventSource,
                                      virtualKey: keyCode, keyDown: false),
                  let commandUp = CGEvent(keyboardEventSource: eventSource,
                                          virtualKey: 0x37, keyDown: false) else {
                return .unavailable
            }
            // Event construction is complete; this is the last possible guard before mutating the
            // newly focused app. It closes the AX-query-to-paste TOCTOU window.
            if let rejection = Self.immediateMutationRejection(
                target, verifyFocusedElement: true
            ) { return rejection == .secureField ? .secureField : .focusChanged }
            guard !cancellation.isCancelled else { return .cancelled }
            commandDown.flags = .maskCommand
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            commandUp.flags = []
            commandDown.post(tap: .cghidEventTap)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            commandUp.post(tap: .cghidEventTap)
            return .sent
        }
        }, onCancel: { cancellation.cancel() })
    }

    func insertionSnapshot(in target: VoiceTextTarget) async -> VoiceInsertionSnapshot? {
        await perform {
            guard Self.targetRejection(target, currentPID: Self.currentFrontmostPID()) == nil,
                  let element = Self.currentEditableElement(target),
                  let value = Self.attributeString(element, kAXValueAttribute),
                  value.utf16.count <= 100_000 else { return nil }
            return VoiceInsertionSnapshot(value: value, selection: Self.selectedRange(element))
        }
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                          &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func currentEditableElement(_ target: VoiceTextTarget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, mutationCheckTimeout)
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                          &current) == .success, let current else { return nil }
        let element = current as! AXUIElement
        AXUIElementSetMessagingTimeout(element, mutationCheckTimeout)
        let signature = focusSignature(element, selectedTextSettable: selectedTextIsSettable(element))
        guard signature.role != "AXSecureTextField", signature.subrole != "AXSecureTextField",
              !IsSecureEventInputEnabled(), signature.isEditableText
        else { return nil }
        if let original = target.focusedElement, !CFEqual(original, current) {
            guard let previous = target.focusSignature,
                  signature.isCompatibleReplacement(for: previous) else { return nil }
        }
        return element
    }

    func confirmsInsertion(_ text: String, in target: VoiceTextTarget,
                           before: VoiceInsertionSnapshot) async -> Bool {
        guard let after = await insertionSnapshot(in: target) else { return false }
        return before.confirms(text, after: after.value)
    }

    func rejection(of target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        await perform {
            Self.targetRejection(target, currentPID: Self.currentFrontmostPID())
        }
    }

    /// Replace only the exact AX selection captured at press time. This path deliberately does not
/// use Command-C/Command-V, Unicode events, or a clipboard fallback. The deliverer may subsequently
/// run its separately guarded compatibility route for a custom editable AX role; the coordinator
/// preserves every completed rewrite on the clipboard if all replacement routes fail.
    func replaceSelection(with replacement: String,
                          in target: VoiceTextTarget) async -> VoiceSelectionReplacementOutcome {
        await performCancellable(cancelled: .unconfirmed) { cancellation in
            guard !replacement.isEmpty else { return .accessibilityUnavailable }
            if target.isSecure || IsSecureEventInputEnabled() { return .secureField }
            guard Self.currentFrontmostPID() == target.pid else { return .focusChanged }
            guard let capturedElement = target.focusedElement,
                  target.selectedTextReadable,
                  let capturedText = target.selectedText else {
                return .accessibilityUnavailable
            }

            let appElement = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(appElement, 0.012)
            var focusedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
            ) == .success, let focusedValue else { return .focusChanged }
            let currentElement = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(currentElement, 0.012)
            let role = Self.attributeString(currentElement, kAXRoleAttribute)
            let subrole = Self.attributeString(currentElement, kAXSubroleAttribute)
            guard role != "AXSecureTextField", subrole != "AXSecureTextField",
                  !IsSecureEventInputEnabled() else { return .secureField }

            if !CFEqual(capturedElement, focusedValue) {
                guard let originalSignature = target.focusSignature else { return .focusChanged }
                let currentSignature = Self.focusSignature(
                    currentElement,
                    selectedTextSettable: Self.selectedTextIsSettable(currentElement)
                )
                guard currentSignature.isCompatibleReplacement(for: originalSignature) else {
                    return .focusChanged
                }
            }

            var currentSelectionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                currentElement, kAXSelectedTextAttribute as CFString, &currentSelectionValue
            ) == .success, let currentText = currentSelectionValue as? String else {
                return .accessibilityUnavailable
            }
            guard currentText == capturedText else { return .selectionChanged }
            guard Self.selectedTextIsSettable(currentElement) else { return .readOnly }
            let before = Self.attributeString(currentElement, kAXValueAttribute)
            let selection = Self.selectedRange(currentElement)
            guard !cancellation.isCancelled else { return .unconfirmed }
            let changed = AXUIElementSetAttributeValue(
                currentElement, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef
            ) == .success
            guard changed else { return .accessibilityUnavailable }
            guard let before, before.utf16.count <= 100_000,
                  let after = Self.attributeString(currentElement, kAXValueAttribute),
                  VoiceInsertionSnapshot(value: before, selection: selection).confirms(replacement, after: after)
            else { return .unconfirmed }
            return .replaced
        }
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }

    private func performCancellable<T>(cancelled: T,
                                      _ operation: @escaping (VoiceDeliveryCancellation) -> T) async -> T {
        let cancellation = VoiceDeliveryCancellation()
        return await withTaskCancellationHandler(operation: {
            await perform { cancellation.isCancelled ? cancelled : operation(cancellation) }
        }, onCancel: { cancellation.cancel() })
    }

    private static func targetRejection(
        _ target: VoiceTextTarget, currentPID: pid_t?
    ) -> VoiceTextDeliveryOutcome? {
        if target.isSecure || IsSecureEventInputEnabled() { return .secureField }
        guard currentPID == target.pid else {
            rmDebug("📝 voice-delivery check: frontmost app changed "
                    + "pid=\(currentPID.map(String.init) ?? "none") expected=\(target.pid)")
            return .focusChanged
        }
        // Some web views expose no focused AX element. PID stability is the strongest available
        // signal there; sparse accessibility alone must not make those editors unusable.
        guard let original = target.focusedElement else { return nil }
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, focusCheckTimeout)
        var currentValue: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &currentValue
        )
        guard query == .success, let currentValue else {
            return focusQueryFailure(query, stage: "check")
        }
        let current = currentValue as! AXUIElement
        AXUIElementSetMessagingTimeout(current, focusCheckTimeout)
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
        guard currentSignature.isCompatibleReplacement(for: originalSignature) else {
            rmDebug("📝 voice-delivery check: focused element changed "
                    + "role=\(currentSignature.role ?? "none") expected=\(originalSignature.role ?? "none")")
            return .focusChanged
        }
        return nil
    }

    /// Cross-process AX budgets. These run on the delivery worker, never on main, so a slow editor
    /// only delays its own insertion. The former 8 ms / 2 ms budgets were below what a busy Chrome,
    /// Electron or terminal process answers in on a loaded machine, and every miss was reported as
    /// a focus change -- the text then went to the clipboard instead of the caret.
    private static let focusCheckTimeout: Float = 0.1
    private static let mutationCheckTimeout: Float = 0.05

    static func focusQueryFailure(_ error: AXError, stage: String) -> VoiceTextDeliveryOutcome? {
        let outcome = VoiceFocusQueryPolicy.outcome(for: error)
        rmDebug("📝 voice-delivery \(stage): focus query ax=\(error.rawValue) -> "
                + (outcome.map { "\($0)" } ?? "unanswered; the unchanged PID decides"))
        return outcome
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
        AXUIElementSetMessagingTimeout(appElement, mutationCheckTimeout)
        var focusedValue: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard query == .success, let focusedValue else {
            return focusQueryFailure(query, stage: "mutation")
        }
        if CFEqual(original, focusedValue) { return nil }
        guard let originalSignature = target.focusSignature else { return .focusChanged }
        let current = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(current, mutationCheckTimeout)
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
        _ text: String, target: VoiceTextTarget, cancellation: VoiceDeliveryCancellation
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
            guard !cancellation.isCancelled else { return .unavailable }
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
    private let pasteboard: NSPasteboard
    private var clipboardOperation = UUID()
    private static let diagnosticSalt = UUID().uuidString

    static func diagnosticFingerprint(_ text: String) -> String {
        let digest = SHA256.hash(data: Data((diagnosticSalt + text).utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "chars=\(text.count) hash=\(hash)"
    }

    /// After positive editor readback only, how long to wait before restoring the user's clipboard.
    /// It was 180 ms, which is shorter than a busy editor's Command-V latency on a loaded machine:
    /// the editor then read the already-restored clipboard, the transcript was gone, and the turn
    /// still logged `inserted`. Restoration is asynchronous, so the longer window costs no
    /// perceived latency, and the marker/changeCount guard still lets any copy made meanwhile win.
    static let clipboardRestoreDelayNanoseconds: UInt64 = 2_000_000_000

    /// The one restore that is scheduled but has not run yet.
    private var pendingRestore: (id: UUID, restore: () -> Void)?

    /// Final Voice values compatibility over microbenchmarks: native AX writes can return success
    /// for Chromium contenteditable nodes without dispatching the DOM input event. A guarded paste
    /// produces the same event path as the user's working Command-V, while the transaction below
    /// restores their clipboard when configured. AX and Unicode remain independent fallbacks.
    static let finalDeliveryOrder: [VoiceFinalDeliveryMethod] = [
        .clipboardPaste, .accessibilitySelectedText, .unicodeEvents,
    ]

    @MainActor
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

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
        var selectedText: String?
        var selectedTextReadable = false
        var valueBeforeInsertion: String?
        var selectedRangeBeforeInsertion: CFRange?
        if let focused {
            AXUIElementSetMessagingTimeout(focused, 0.025)
            AXUIElementIsAttributeSettable(
                focused, kAXSelectedTextAttribute as CFString, &selectedTextSettable
            )
            var selectedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, &selectedValue
            ) == .success, let value = selectedValue as? String {
                selectedText = value
                selectedTextReadable = true
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focused, kAXValueAttribute as CFString, &value
            ) == .success, let text = value as? String, text.utf16.count <= 100_000 {
                valueBeforeInsertion = text
            }
            var rangeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue
            ) == .success, let rangeValue,
               CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                    selectedRangeBeforeInsertion = range
                }
            }
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
            selectedText: selectedText,
            selectedTextReadable: selectedTextReadable,
            selectedTextSettable: selectedTextSettable.boolValue,
            isSecure: isSecure,
            valueBeforeInsertion: valueBeforeInsertion,
            selectedRangeBeforeInsertion: selectedRangeBeforeInsertion
        )
    }

    /// Resolve AX first, then use a reversible Command-C probe only when an app exposes no
    /// non-empty AX selection. This compatibility path is what lets WeChat and other custom
    /// editors participate in selection rewriting without making every ordinary Voice press pay a
    /// clipboard round-trip. The user's clipboard is restored before recording reaches its hold
    /// threshold, and a concurrent clipboard change is never overwritten.
    @MainActor
    func resolveTargetForVoice(_ seed: VoiceTextTargetSeed,
                               detectSelection: Bool) async -> VoiceTextTarget {
        let target = await Task.detached(priority: .userInitiated) {
            Self.resolveTarget(seed)
        }.value
        guard detectSelection, !target.isSecure,
              target.selectionState == .none,
              let selected = await compatibilitySelectedText(in: target),
              !selected.isEmpty else { return target }
        rmDebug("📝 voice-selection compatibility copy app="
                + (target.bundleIdentifier ?? "unknown") + " chars=\(selected.count)")
        return target.withCompatibilitySelection(selected)
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
                      settings: Config.DictationSettings,
                      deliveryID: UUID = UUID(),
                      beforeDispatch: @MainActor () async -> Bool = { !Task.isCancelled }) async -> VoiceTextDeliveryOutcome {
        guard !text.isEmpty, !Task.isCancelled else { return .unavailable }
        guard settings.autoInsert, let target else {
            rmDebug("📝 voice-delivery final route=copy reason=no-target-or-auto-insert-off")
            return copy(text, deliveryID: deliveryID)
        }
        let bundle = target.bundleIdentifier ?? "unknown"
        let role = target.focusSignature?.role ?? "none"
        rmDebug("📝 voice-delivery final begin id=\(deliveryID) app=\(bundle) role=\(role) "
                + "axSelected=\(target.selectedTextSettable)")

        for method in Self.finalDeliveryOrder {
            guard await beforeDispatch(), !Task.isCancelled else { return .unavailable }
            let outcome: VoiceTextDeliveryOutcome?
            switch method {
            case .clipboardPaste:
                outcome = await pasteViaClipboard(
                    text, target: target,
                    restore: settings.restoreClipboardAfterInsert, deliveryID: deliveryID,
                    beforeDispatch: beforeDispatch
                )
            case .accessibilitySelectedText:
                let before = await worker.insertionSnapshot(in: target)
                outcome = await worker.insertSelectedText(text, into: target)
                if outcome == .inserted, !(await confirms(text, target: target, before: before)) {
                    guard !Task.isCancelled else { return .unavailable }
                    return copy(text, deliveryID: deliveryID) == .copied ? .pasteSent : .unconfirmed
                }
            case .unicodeEvents:
                let before = await worker.insertionSnapshot(in: target)
                outcome = await worker.insertUnicode(text, into: target)
                if outcome == .inserted, !(await confirms(text, target: target, before: before)) {
                    guard !Task.isCancelled else { return .unavailable }
                    return copy(text, deliveryID: deliveryID) == .copied ? .pasteSent : .unconfirmed
                }
            }
            guard !Task.isCancelled else { return .unavailable }
            guard let outcome else {
                rmDebug("📝 voice-delivery final route=\(method.rawValue) result=unsupported")
                continue
            }
            rmDebug("📝 voice-delivery final route=\(method.rawValue) result=\(outcome)")
            switch outcome {
            case .pasteSent, .unconfirmed:
                // A second route could duplicate text after an unacknowledged successful paste.
                return outcome
            case .inserted:
                return .inserted
            case .secureField:
                return copy(text, deliveryID: deliveryID)
            case .focusChanged:
                return copy(text, deliveryID: deliveryID)
            case .copied:
                return .copied
            case .unavailable:
                continue
            }
        }
        guard !Task.isCancelled else { return .unavailable }
        let fallback = copy(text, deliveryID: deliveryID)
        rmDebug("📝 voice-delivery final route=copy-fallback result=\(fallback)")
        return fallback
    }

    @MainActor
    @discardableResult
    func copy(_ text: String, deliveryID: UUID = UUID()) -> VoiceTextDeliveryOutcome {
        guard !text.isEmpty else { return .unavailable }
        clipboardOperation = UUID()
        pendingRestore = nil
        pasteboard.clearContents()
        let accepted = pasteboard.setString(text, forType: .string)
        let verified = accepted && pasteboard.string(forType: .string) == text
        rmDebug("📝 voice-clipboard copy id=\(deliveryID) verified=\(verified) "
                + Self.diagnosticFingerprint(text) + " change=\(pasteboard.changeCount)")
        if verified { monitorClipboard(deliveryID: deliveryID) }
        return verified ? .copied : .unavailable
    }

    @MainActor
    private func monitorClipboard(deliveryID: UUID) {
        let operation = clipboardOperation, count = pasteboard.changeCount
        Task { @MainActor [weak self] in
            for delay: UInt64 in [250_000_000, 2_000_000_000] {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.clipboardOperation == operation else { return }
                let retained = self.pasteboard.changeCount == count
                rmDebug("📝 voice-clipboard retained id=\(deliveryID) owned=\(retained) "
                        + "change=\(self.pasteboard.changeCount)")
                if !retained { return }
            }
        }
    }

    func targetRejection(_ target: VoiceTextTarget) async -> VoiceTextDeliveryOutcome? {
        await worker.rejection(of: target)
    }

    @MainActor
    func replaceSelection(_ replacement: String, in target: VoiceTextTarget,
                          restoreClipboardAfterPaste: Bool = true) async
        -> VoiceSelectionReplacementOutcome {
        let strict = await worker.replaceSelection(with: replacement, in: target)
        guard strict == .accessibilityUnavailable || strict == .readOnly,
              target.focusSignature?.isEditableText == true,
              let captured = target.selectedText else { return strict }

        // A custom editor may rebuild its AX node or expose no settable selection at all. Verify
        // the still-visible selection with the same reversible copy path immediately before paste;
        // only the exact captured text is eligible for replacement.
        guard let current = await compatibilitySelectedText(in: target) else {
            return .accessibilityUnavailable
        }
        guard current == captured else { return .selectionChanged }
        let pasted = await pasteViaClipboard(
            replacement, target: target, restore: restoreClipboardAfterPaste
        )
        switch pasted {
        case .inserted:
            rmDebug("📝 voice-selection replacement route=guardedClipboardPaste result=replaced")
            return .replaced
        case .focusChanged: return .focusChanged
        case .secureField: return .secureField
        case .pasteSent, .unconfirmed: return .unconfirmed
        case .copied, .unavailable: return .accessibilityUnavailable
        }
    }

    /// Run a scheduled clipboard restore now. Every clipboard transaction calls this before taking
    /// its snapshot, so the snapshot is the user's real clipboard rather than the previous turn's
    /// transcript that is still waiting to be swapped out. Without it, two turns inside the
    /// restore window would leave the first transcript on the clipboard for good.
    @MainActor
    private func flushPendingRestore() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        pending.restore()
    }

    /// Copy only as a selection probe. A unique marker distinguishes "Copy did nothing" from a
    /// real selection, while changeCount prevents restoration from clobbering a clipboard update
    /// made concurrently by the user or another app.
    @MainActor
    private func compatibilitySelectedText(in target: VoiceTextTarget) async -> String? {
        if let rejection = await targetRejection(target) {
            rmDebug("📝 voice-selection compatibility copy rejected=\(rejection)")
            return nil
        }
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        flushPendingRestore()
        let operation = UUID()
        clipboardOperation = operation
        rmDebug("📝 voice-clipboard probe begin id=\(operation) change=\(pasteboard.changeCount)")
        let snapshot = VoicePasteboardSnapshot(pasteboard)
        let marker = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(marker, forType: Self.markerType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        let markerChangeCount = pasteboard.changeCount

        let shortcut = await worker.postCopyShortcut(into: target)
        guard shortcut == .sent, !Task.isCancelled, clipboardOperation == operation else {
            if clipboardOperation == operation, pasteboard.changeCount == markerChangeCount,
               pasteboard.string(forType: Self.markerType) == marker {
                snapshot.restore(to: pasteboard)
            }
            return nil
        }

        var captured: String?
        var capturedChangeCount = markerChangeCount
        // Native and Chromium editors normally publish synchronously; the short bounded poll also
        // covers custom Electron bridges without adding latency to the physical 200 ms opener.
        for _ in 0..<8 {
            do { try await Task.sleep(nanoseconds: 12_000_000) } catch { break }
            guard clipboardOperation == operation else { return nil }
            guard pasteboard.changeCount != markerChangeCount else { continue }
            capturedChangeCount = pasteboard.changeCount
            captured = pasteboard.string(forType: .string)
            break
        }
        guard clipboardOperation == operation else { return nil }
        if pasteboard.changeCount == capturedChangeCount {
            snapshot.restore(to: pasteboard)
            rmDebug("📝 voice-clipboard probe restored id=\(operation) change=\(pasteboard.changeCount)")
        }
        guard !Task.isCancelled, let captured, !captured.isEmpty, captured != marker else { return nil }
        return captured
    }

    @MainActor
    private func pasteViaClipboard(_ text: String, target: VoiceTextTarget,
                                   restore: Bool, deliveryID: UUID = UUID(),
                                   beforeDispatch: @MainActor () async -> Bool = { !Task.isCancelled }) async -> VoiceTextDeliveryOutcome {
        if let rejection = await targetRejection(target) { return rejection }
        guard AXIsProcessTrusted(), !Task.isCancelled else { return .unavailable }
        let before = await worker.insertionSnapshot(in: target)
        guard !Task.isCancelled else { return .unavailable }
        return await performPasteTransaction(text, restore: restore, deliveryID: deliveryID,
            admit: beforeDispatch,
            dispatch: { await self.worker.postPasteShortcut(into: target) },
            confirm: { await self.confirms(text, target: target, before: before) })
    }

    @MainActor
    private func confirms(_ text: String, target: VoiceTextTarget,
                          before: VoiceInsertionSnapshot?) async -> Bool {
        guard let before else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 350_000_000
        for _ in 0..<6 {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 35_000_000) } catch { return false }
            if await worker.confirmsInsertion(text, in: target, before: before) { return true }
            if Task.isCancelled { return false }
        }
        return false
    }

    /// Same transaction in production and isolated-pasteboard regression tests; test closures emit no keys.
    @MainActor
    func performPasteTransaction(_ text: String, restore: Bool, deliveryID: UUID = UUID(),
                                 restoreDelay: UInt64 = clipboardRestoreDelayNanoseconds,
                                 admit: @MainActor () async -> Bool = { !Task.isCancelled },
                                 dispatch: () async -> VoiceShortcutDispatchOutcome,
                                 confirm: () async -> Bool) async -> VoiceTextDeliveryOutcome {
        guard !Task.isCancelled else { return .unavailable }
        flushPendingRestore()
        let operation = UUID()
        clipboardOperation = operation
        let pasteboard = self.pasteboard
        let snapshot = VoicePasteboardSnapshot(pasteboard)
        let marker = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(marker, forType: Self.markerType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), pasteboard.string(forType: .string) == text,
              pasteboard.string(forType: Self.markerType) == marker else { return .unavailable }
        let transactionChangeCount = pasteboard.changeCount
        rmDebug("📝 voice-clipboard staged id=\(deliveryID) " + Self.diagnosticFingerprint(text)
                + " change=\(transactionChangeCount)")
        let restoreIfOwned = { [weak self] in
            guard let self else { return }
            let markerSurvived = self.clipboardOperation == operation
                && pasteboard.changeCount == transactionChangeCount
                && pasteboard.string(forType: Self.markerType) == marker
            if markerSurvived { snapshot.restore(to: pasteboard) }
            rmDebug("📝 voice-clipboard restore id=\(deliveryID) owned=\(markerSurvived)")
        }

        // Give Chromium/WebKit one event turn to observe the new pasteboard ownership.
        do { try await Task.sleep(nanoseconds: 25_000_000) } catch {
            restoreIfOwned()
            return .unavailable
        }
        guard await admit(), !Task.isCancelled else {
            restoreIfOwned()
            return .unavailable
        }
        guard clipboardOperation == operation,
              pasteboard.changeCount == transactionChangeCount,
              pasteboard.string(forType: .string) == text else { return .unavailable }
        let pasteOutcome = await dispatch()
        guard pasteOutcome == .sent else {
            restoreIfOwned()
            switch pasteOutcome {
            case .focusChanged: return .focusChanged
            case .secureField: return .secureField
            case .cancelled, .unavailable, .sent: return .unavailable
            }
        }

        let confirmed = await confirm()
        guard clipboardOperation == operation, !Task.isCancelled else { return .unconfirmed }
        let retained = pasteboard.changeCount == transactionChangeCount
            && pasteboard.string(forType: .string) == text
        rmDebug("📝 voice-delivery paste id=\(deliveryID) confirmed=\(confirmed) clipboard=\(retained)")
        guard confirmed else {
            if retained { monitorClipboard(deliveryID: deliveryID) }
            return retained ? .pasteSent : .unconfirmed
        }

        // Do not charge the async web-editor consumption window to perceived insertion latency.
        // Restoration remains conditional on both the marker and changeCount, so a clipboard change
        // made by the user during this window always wins.
        if restore, retained {
            let id = UUID()
            pendingRestore = (id, restoreIfOwned)
            Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: restoreDelay) } catch { return }
                guard let self, self.pendingRestore?.id == id else { return }
                self.pendingRestore = nil
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
