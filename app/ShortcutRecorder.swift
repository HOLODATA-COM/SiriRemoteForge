//
//  ShortcutRecorder.swift
//  HyperVibe
//
//  Native macOS shortcut capture for the Layout editor. The recorder consumes keyDown and
//  flagsChanged while it owns first responder, then emits the same canonical tokens KeyMap executes.
//

import AppKit
import SwiftUI

/// SwiftUI wrapper that offers physical shortcut recording first and a deliberate text fallback.
/// The fallback remains useful for pasting a chord or authoring a side-specific modifier sequence.
struct ShortcutRecorderField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var manualMode = false
    @State private var manualText: String
    @State private var manualError = false
    @FocusState private var manualFocused: Bool

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _manualText = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 6) {
            if manualMode {
                TextField("cmd+shift+t", text: $manualText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .focused($manualFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(manualError ? Color.red : Color.clear, lineWidth: 1)
                    )
                    .onSubmit {
                        if commitManual() { manualMode = false }
                    }
                    .help(manualError
                          ? L("Use one key plus optional modifiers, for example ⌘⇧T or cmd+shift+t.")
                          : L("Advanced text entry"))
            } else {
                NativeShortcutRecorder(value: value) { shortcut in
                    manualText = shortcut
                    manualError = false
                    onCommit(shortcut)
                }
                .frame(width: 170, height: 26)
            }

            Button {
                if manualMode {
                    if commitManual() { manualMode = false }
                } else {
                    manualText = value
                    manualError = false
                    manualMode = true
                    DispatchQueue.main.async { manualFocused = true }
                }
            } label: {
                Image(systemName: manualMode ? "keyboard" : "pencil")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .help(manualMode ? L("Return to shortcut recording") : L("Edit shortcut as text"))

            if !value.isEmpty || !manualText.isEmpty {
                Button {
                    manualText = ""
                    manualError = false
                    onCommit("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .help(L("Clear shortcut"))
            }
        }
        .onChange(of: value) { newValue in
            if !manualFocused { manualText = newValue }
        }
        .onChange(of: manualFocused) { focused in
            guard manualMode, !focused else { return }
            _ = commitManual()
        }
    }

    @discardableResult
    private func commitManual() -> Bool {
        let trimmed = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            manualError = false
            onCommit("")
            return true
        }
        guard let normalized = ShortcutCodec.normalize(trimmed) else {
            manualError = true
            NSSound.beep()
            return false
        }
        manualText = normalized
        manualError = false
        onCommit(normalized)
        return true
    }
}

private struct NativeShortcutRecorder: NSViewRepresentable {
    let value: String
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCommit = onCommit
        button.shortcut = value
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onCommit = onCommit
        if !button.isRecording { button.shortcut = value }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: Void) {
        button.cancelRecording()
    }
}

/// NSButton is intentionally used instead of a global event monitor: it captures only while the
/// user deliberately records and is first responder, so ordinary Settings shortcuts remain normal.
private final class ShortcutRecorderButton: NSButton {
    var onCommit: ((String) -> Void)?
    var shortcut = "" { didSet { if !isRecording { refreshAppearance() } } }
    private(set) var isRecording = false

    private var captureState = ShortcutCaptureState()
    private var feedbackGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        controlSize = .regular
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel(L("Shortcut recorder"))
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        captureState.reset()
        feedbackGeneration += 1
        isRecording = true
        bezelColor = .controlAccentColor
        contentTintColor = .white
        title = L("Press shortcut…")
        toolTip = L("Press a shortcut · Esc cancels · Delete clears")
        window?.makeFirstResponder(self)
    }

    func beginRecordingForTesting() {
        beginRecording()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        captureState.reset()
        feedbackGeneration += 1
        refreshAppearance()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { cancelRecording() }
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }

        let code = UInt16(event.keyCode)
        if code == 53 { // Escape always cancels recording.
            finishWithoutCommit()
            return
        }

        let modifiers = fallbackModifiers(from: event)
        if code == 51, modifiers.isEmpty, captureState.activeModifiers.isEmpty {
            // Delete clears; the text fallback can still author a plain `delete` shortcut.
            finish(with: "")
            return
        }
        guard let canonical = captureState.shortcut(
                macKeyCode: code, fallbackModifiers: modifiers) else {
            showUnsupportedFeedback()
            return
        }
        finish(with: canonical)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        let code = UInt16(event.keyCode)
        guard ShortcutModifier(macKeyCode: code) != nil else { return }
        let completedModifierChord = captureState.modifierChanged(macKeyCode: code)
        refreshRecordingPreview()

        // A chord made entirely from modifiers completes when the last physical modifier is
        // released. A normal shortcut commits earlier in keyDown, while all modifiers are held.
        if let canonical = completedModifierChord {
            finish(with: canonical)
        }
    }

    private func fallbackModifiers(from event: NSEvent) -> [ShortcutModifier] {
        var result: [ShortcutModifier] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.command) { result.append(.command) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.shift) { result.append(.shift) }
        if flags.contains(.function) { result.append(.function) }
        return result
    }

    private func refreshRecordingPreview() {
        if let canonical = ShortcutCodec.canonical(
            modifiers: captureState.activeModifiers, keyToken: nil) {
            title = Action.keystroke(keys: canonical).displayLabel
        } else {
            title = L("Press shortcut…")
        }
    }

    private func finish(with canonical: String) {
        isRecording = false
        captureState.reset()
        shortcut = canonical
        refreshAppearance()
        onCommit?(canonical)
        window?.makeFirstResponder(nil)
    }

    private func finishWithoutCommit() {
        isRecording = false
        captureState.reset()
        refreshAppearance()
        window?.makeFirstResponder(nil)
    }

    private func showUnsupportedFeedback() {
        feedbackGeneration += 1
        let generation = feedbackGeneration
        title = L("Unsupported key")
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.isRecording, self.feedbackGeneration == generation else { return }
            self.refreshRecordingPreview()
        }
    }

    private func refreshAppearance() {
        bezelColor = nil
        contentTintColor = .labelColor
        title = shortcut.isEmpty
            ? L("Click to record")
            : Action.keystroke(keys: shortcut).displayLabel
        toolTip = shortcut.isEmpty
            ? L("Click, then press the shortcut on your keyboard")
            : L("Recorded as %@", shortcut)
    }
}

/// Headless bridge test used by release verification. Core tests cover the state machine and key
/// vocabulary; this additionally proves actual NSEvents reach the recorder button correctly.
@MainActor
enum ShortcutRecorderSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        let button = ShortcutRecorderButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26))
        var commits: [String] = []
        button.onCommit = { commits.append($0) }

        button.beginRecordingForTesting()
        button.flagsChanged(with: event(.flagsChanged, [.command], 55))
        button.flagsChanged(with: event(.flagsChanged, [.command, .shift], 56))
        button.keyDown(with: event(.keyDown, [.command, .shift], 17, characters: "t"))
        expect(commits.last == "cmd+shift+t", "main chord", into: &failures)

        button.beginRecordingForTesting()
        button.flagsChanged(with: event(.flagsChanged, [.function], 63))
        button.keyDown(with: event(.keyDown, [.function], 111))
        expect(commits.last == "fn+f12", "Fn + function key", into: &failures)

        button.beginRecordingForTesting()
        button.flagsChanged(with: event(.flagsChanged, [.function], 63))
        button.flagsChanged(with: event(.flagsChanged, [], 63))
        expect(commits.last == "fn", "Fn-only chord", into: &failures)

        button.beginRecordingForTesting()
        button.flagsChanged(with: event(.flagsChanged, [.control], 62))
        button.flagsChanged(with: event(.flagsChanged, [.control, .command], 54))
        button.flagsChanged(with: event(.flagsChanged, [.control, .command, .option], 61))
        button.flagsChanged(with: event(.flagsChanged, [.control, .command], 61))
        button.flagsChanged(with: event(.flagsChanged, [.control], 54))
        button.flagsChanged(with: event(.flagsChanged, [], 62))
        expect(commits.last == "rctrl+rcmd+ropt", "modifier-only chord", into: &failures)

        button.shortcut = "cmd+p"
        button.beginRecordingForTesting()
        button.keyDown(with: event(.keyDown, [], 51, characters: "\u{7f}"))
        expect(commits.last == "", "Delete clears", into: &failures)

        let countBeforeCancel = commits.count
        button.shortcut = "cmd+w"
        button.beginRecordingForTesting()
        button.keyDown(with: event(.keyDown, [], 53, characters: "\u{1b}"))
        expect(commits.count == countBeforeCancel && button.shortcut == "cmd+w",
               "Escape cancels", into: &failures)

        if let fnF12 = KeyMap.parse("fn+f12") {
            expect(fnF12.mods.count == 1 && fnF12.mods[0].keyCode == 63,
                   "Fn executor modifier", into: &failures)
            expect(fnF12.flags.contains(.maskSecondaryFn),
                   "Fn executor flag", into: &failures)
            expect(fnF12.mainKey == 111, "F12 executor key", into: &failures)
        } else {
            failures.append("Fn + F12 executor parse")
        }
        if let fnOnly = KeyMap.parse("fn") {
            expect(fnOnly.mods.count == 1 && fnOnly.mainKey == nil,
                   "Fn-only executor parse", into: &failures)
        } else {
            failures.append("Fn-only executor parse")
        }

        let saveModel = SettingsModel(initial: .default)
        saveModel.noteConfigSavePending(from: .tuning)
        saveModel.noteConfigSavePending(from: .layout)
        saveModel.noteConfigSaveSucceeded(from: .layout)
        expect(saveModel.configSaveState == .saving,
               "Layout success must not hide a pending Tuning save", into: &failures)
        saveModel.noteConfigSaveSucceeded(from: .tuning)
        expect(saveModel.configSaveState == .saved, "all saves complete", into: &failures)
        saveModel.noteConfigSaveFailed(
            NSError(domain: "ShortcutRecorderSelfTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "write failed"]),
            from: .layout
        )
        expect(saveModel.configSaveState == .failed("write failed"),
               "save error remains visible", into: &failures)
        saveModel.noteConfigSavePending(from: .layout)
        saveModel.noteConfigSaveSucceeded(from: .layout)
        expect(saveModel.configSaveState == .saved,
               "successful retry clears the error", into: &failures)

        if failures.isEmpty {
            // `applicationDidFinishLaunching` exits immediately after this returns. Write through
            // FileHandle so the release log cannot lose a buffered `print` just before `exit(0)`.
            FileHandle.standardOutput.write(Data("shortcut recorder self-test: PASS\n".utf8))
            return true
        }
        for failure in failures {
            FileHandle.standardError.write(Data("shortcut recorder self-test: FAIL: \(failure)\n".utf8))
        }
        return false
    }

    private static func event(_ type: NSEvent.EventType,
                              _ flags: NSEvent.ModifierFlags,
                              _ keyCode: UInt16,
                              characters: String = "") -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("could not create shortcut recorder test event")
        }
        return event
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ label: String,
                               into failures: inout [String]) {
        if !condition() { failures.append(label) }
    }
}
