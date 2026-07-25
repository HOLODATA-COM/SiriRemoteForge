//
//  ShortcutRecorder.swift
//  HyperVibe
//
//  A narrow AppKit bridge for recording physical keyboard shortcuts. SwiftUI TextField cannot
//  reliably capture Esc, function keys, modifier-only chords, or menu equivalents such as Cmd-Q:
//  the responder chain consumes them first. This view temporarily installs a session event tap
//  that captures and suppresses one chord before macOS handles shortcuts such as Option-Tab, then
//  returns the stable KeyMap string to SwiftUI. The tap is strictly time-bounded and always removed.
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    let onRecord: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onRecord: onRecord)
    }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = { [weak coordinator = context.coordinator] shortcut in
            coordinator?.record(shortcut)
        }
        view.shortcut = value
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onRecord = onRecord
        if !view.isRecording, view.shortcut != value {
            view.shortcut = value
        }
    }

    final class Coordinator {
        var value: Binding<String>
        var onRecord: (String) -> Void

        init(value: Binding<String>, onRecord: @escaping (String) -> Void) {
            self.value = value
            self.onRecord = onRecord
        }

        func record(_ shortcut: String) {
            value.wrappedValue = shortcut
            onRecord(shortcut)
        }
    }
}

final class ShortcutRecorderView: NSView {
    var onRecord: ((String) -> Void)?
    var shortcut = "" { didSet { refresh() } }
    private(set) var isRecording = false

    private let label = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let countdownProgress = NSProgressIndicator()
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var recordingTimeout: DispatchWorkItem?
    private var countdownTimer: Timer?
    private var recordingDeadline: TimeInterval = 0
    private var fullCaptureAvailable = false
    private var heldModifiers = Set<String>()
    private var chordModifiers = Set<String>()
    private static let captureDuration: TimeInterval = 6

    private static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let view = Unmanaged<ShortcutRecorderView>.fromOpaque(userInfo).takeUnretainedValue()
        return view.handleEventTap(type: type, event: event)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 24) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        countdownLabel.alignment = .right
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.isHidden = true
        addSubview(countdownLabel)

        countdownProgress.style = .bar
        countdownProgress.isIndeterminate = false
        countdownProgress.minValue = 0
        countdownProgress.maxValue = Self.captureDuration
        countdownProgress.controlSize = .mini
        countdownProgress.isHidden = true
        addSubview(countdownProgress)

        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut recorder")
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        recordingTimeout?.cancel()
        countdownTimer?.invalidate()
        removeEventTap()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    override func layout() {
        super.layout()
        if isRecording && fullCaptureAvailable {
            let countdownWidth: CGFloat = 40
            label.alignment = .left
            label.frame = NSRect(
                x: 7, y: 4,
                width: max(0, bounds.width - countdownWidth - 16),
                height: max(0, bounds.height - 6)
            )
            countdownLabel.frame = NSRect(
                x: max(7, bounds.width - countdownWidth - 6), y: 4,
                width: countdownWidth, height: max(0, bounds.height - 6)
            )
            countdownProgress.frame = NSRect(
                x: 5, y: 1,
                width: max(0, bounds.width - 10), height: 2
            )
        } else {
            label.alignment = .center
            label.frame = bounds.insetBy(dx: 7, dy: 3)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers.removeAll()
        chordModifiers.removeAll()
        window?.makeFirstResponder(self)
        installCapture()
        scheduleTimeout()
        refresh()
    }

    private func stopRecording() {
        guard isRecording || localMonitor != nil || eventTap != nil else { return }
        isRecording = false
        fullCaptureAvailable = false
        heldModifiers.removeAll()
        chordModifiers.removeAll()
        recordingTimeout?.cancel()
        recordingTimeout = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        removeEventTap()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        refresh()
    }

    /// Install the session tap first: unlike an AppKit local monitor it sits before macOS shortcut
    /// handling, so Tab, Cmd-Tab, Option-Tab, Escape, menu equivalents, and function keys arrive.
    /// The local monitor remains only as a mouse-cancel path and a permission-denied fallback.
    private func installCapture() {
        removeEventTap()
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown
        ]
        let mask = types.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if let eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            fullCaptureAvailable = true
        } else {
            fullCaptureAvailable = false
            NSSound.beep()
        }

        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }

            switch event.type {
            case .keyDown:
                // The event tap normally consumes this before AppKit. This fallback is used only
                // when macOS declined tap creation (usually missing Accessibility permission).
                guard self.eventTap == nil else { return nil }
                self.recordKeyDown(
                    keyCode: event.keyCode,
                    isRepeat: event.isARepeat,
                    modifiers: self.modifiers(from: event.modifierFlags)
                )
                return nil
            case .flagsChanged:
                guard self.eventTap == nil else { return nil }
                self.recordFlagsChanged(keyCode: event.keyCode)
                return nil
            case .leftMouseDown:
                guard event.window === self.window else { return event }
                // Let the click continue. A click elsewhere cancels; clicking this control simply
                // restarts recording through mouseDown after this monitor returns.
                self.stopRecording()
                return event
            default:
                return event
            }
        }
    }

    private func removeEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func scheduleTimeout() {
        recordingTimeout?.cancel()
        countdownTimer?.invalidate()
        recordingDeadline = ProcessInfo.processInfo.systemUptime + Self.captureDuration
        updateCountdown()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecording()
            self.window?.makeFirstResponder(nil)
        }
        recordingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDuration, execute: work)
    }

    private func updateCountdown() {
        let remaining = max(0, recordingDeadline - ProcessInfo.processInfo.systemUptime)
        countdownLabel.stringValue = String(format: "%.1fs", remaining)
        countdownProgress.doubleValue = remaining
    }

    /// Return true to suppress this event from the rest of the login session.
    private func handleEventTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A slow callback or secure-input transition may disable a tap. Re-enable while the
            // bounded recording window is alive; stop immediately if its port has disappeared.
            if isRecording, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            } else {
                stopRecording()
            }
            return false
        }
        guard isRecording else { return false }

        switch type {
        case .keyDown:
            recordKeyDown(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                modifiers: modifiers(from: event.flags)
            )
            return true
        case .keyUp:
            // Do not leak the release half of a chord whose press half was suppressed.
            return true
        case .flagsChanged:
            recordFlagsChanged(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            )
            return true
        case .leftMouseDown, .rightMouseDown:
            // A click anywhere after recording begins is an explicit cancel, but the click itself
            // continues to its destination.
            stopRecording()
            return false
        default:
            return false
        }
    }

    private func recordKeyDown(keyCode: UInt16, isRepeat: Bool, modifiers: Set<String>) {
        guard !isRepeat, let key = KeyMap.token(for: keyCode) else {
            NSSound.beep()
            return
        }
        var combined = heldModifiers
        // If recording began while modifiers were already held, their flagsChanged press happened
        // before the monitor existed. Preserve the chord with generic-side fallback tokens.
        for token in modifiers {
            if token == "fn" {
                combined.insert(token)
            } else if !containsSide(of: token, in: combined) {
                combined.insert(token)
            }
        }
        finish(tokens: ordered(combined) + [key])
    }

    private func recordFlagsChanged(keyCode: UInt16) {
        // Caps Lock is a toggle key, not a held chord modifier.
        if Int(keyCode) == kVK_CapsLock {
            finish(tokens: ["capslock"])
            return
        }
        guard let token = KeyMap.modifierToken(for: keyCode) else {
            NSSound.beep()
            return
        }
        if heldModifiers.contains(token) {
            heldModifiers.remove(token)
            if heldModifiers.isEmpty, !chordModifiers.isEmpty {
                finish(tokens: ordered(chordModifiers))
            } else {
                refresh()
            }
        } else {
            heldModifiers.insert(token)
            chordModifiers.insert(token)
            refresh()
        }
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> Set<String> {
        var result = Set<String>()
        if flags.contains(.control) { result.insert("ctrl") }
        if flags.contains(.option) { result.insert("opt") }
        if flags.contains(.shift) { result.insert("shift") }
        if flags.contains(.command) { result.insert("cmd") }
        if flags.contains(.function) { result.insert("fn") }
        return result
    }

    private func modifiers(from flags: CGEventFlags) -> Set<String> {
        var result = Set<String>()
        if flags.contains(.maskControl) { result.insert("ctrl") }
        if flags.contains(.maskAlternate) { result.insert("opt") }
        if flags.contains(.maskShift) { result.insert("shift") }
        if flags.contains(.maskCommand) { result.insert("cmd") }
        if flags.contains(.maskSecondaryFn) { result.insert("fn") }
        return result
    }

    private func finish(tokens: [String]) {
        let result = tokens.joined(separator: "+")
        shortcut = result
        stopRecording()
        onRecord?(result)
        window?.makeFirstResponder(nil)
    }

    private func containsSide(of family: String, in tokens: Set<String>) -> Bool {
        tokens.contains(family) || tokens.contains("l\(family)") || tokens.contains("r\(family)")
    }

    private func ordered(_ tokens: Set<String>) -> [String] {
        let rank: [String: Int] = [
            "lctrl": 0, "rctrl": 1, "ctrl": 2,
            "lopt": 3, "ropt": 4, "opt": 5,
            "lshift": 6, "rshift": 7, "shift": 8,
            "lcmd": 9, "rcmd": 10, "cmd": 11,
            "fn": 12,
        ]
        return tokens.sorted {
            let a = rank[$0] ?? 99, b = rank[$1] ?? 99
            return a == b ? $0 < $1 : a < b
        }
    }

    private func refresh() {
        guard label.superview != nil else { return }
        if isRecording {
            if fullCaptureAvailable {
                label.stringValue = heldModifiers.isEmpty
                    ? "Press a shortcut…"
                    : display(ordered(heldModifiers).joined(separator: "+")) + "  press a key"
                countdownLabel.isHidden = false
                countdownProgress.isHidden = false
                label.textColor = .controlAccentColor
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                setAccessibilityValue("Recording for up to six seconds")
            } else {
                countdownLabel.isHidden = true
                countdownProgress.isHidden = true
                label.stringValue = "Full capture unavailable"
                label.textColor = .systemRed
                layer?.borderColor = NSColor.systemRed.cgColor
                layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
                setAccessibilityValue("Full capture unavailable; check Accessibility permission")
            }
        } else {
            countdownLabel.isHidden = true
            countdownProgress.isHidden = true
            label.stringValue = shortcut.isEmpty ? "Click to record" : display(shortcut)
            label.textColor = shortcut.isEmpty ? .secondaryLabelColor : .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            setAccessibilityValue(shortcut.isEmpty ? "No shortcut" : shortcut)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func display(_ value: String) -> String {
        value.split(separator: "+").map { token in
            switch token.lowercased() {
            case "cmd", "lcmd": return "⌘"
            case "rcmd": return "⌘R"
            case "ctrl", "lctrl": return "⌃"
            case "rctrl": return "⌃R"
            case "opt", "lopt": return "⌥"
            case "ropt": return "⌥R"
            case "shift", "lshift": return "⇧"
            case "rshift": return "⇧R"
            case "fn": return "fn"
            case "up": return "↑"
            case "down": return "↓"
            case "left": return "←"
            case "right": return "→"
            case "esc": return "Esc"
            case "enter": return "Return"
            case "delete": return "Delete"
            case "forwarddelete": return "Forward Delete"
            case "space": return "Space"
            case "tab": return "Tab"
            case "pageup": return "Page Up"
            case "pagedown": return "Page Down"
            default:
                if token.lowercased().hasPrefix("keycode") {
                    return "Key \(token.dropFirst("keycode".count))"
                }
                return token.uppercased()
            }
        }.joined(separator: " ")
    }
}
