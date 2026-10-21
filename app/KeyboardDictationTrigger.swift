//
//  KeyboardDictationTrigger.swift
//  HyperVibe
//
//  A global keyboard shortcut that toggles Voice: one completed press starts recording, the next
//  stops it. Capture is primed on key-down; key-up commits the gesture without a hold timer.
//
//  Two shortcut shapes are supported, because the recorder can produce both:
//
//  * A chord with a main key (`ctrl+opt+space`). The main key's down/up are swallowed while the
//    chord is held, so it never also types into the focused app. Either physical side of each
//    modifier counts, as it does for every other macOS shortcut.
//  * A modifier-only shortcut (`ropt`, `rcmd`). Modifier events are never swallowed -- doing so
//    would leave other apps with stuck modifier state -- so the trigger only observes. The side is
//    significant here. Adding another key or modifier invalidates that gesture (Command-Tab,
//    Option-E), without stopping an already running recording.
//
//  The event tap runs on its own thread. Every keystroke on the system passes through it, and a
//  tap serviced by a busy main run loop both lags all typing and gets disabled by the system for
//  timing out. The thread only classifies events into press/release/interrupt edges; the state
//  machine and every call into Voice run on main.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Parsed form of `dictation.keyboardShortcut`.
struct KeyboardDictationShortcut: Equatable {
    /// Physical modifier keys, side specific (`kVK_RightCommand` is not `kVK_Command`).
    let modifierKeys: Set<CGKeyCode>
    /// The non-modifier key, or nil for a modifier-only shortcut.
    let mainKey: CGKeyCode?

    var isModifierOnly: Bool { mainKey == nil }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let canonical = ShortcutCodec.normalize(trimmed),
              let combo = KeyMap.parse(canonical) else { return nil }
        let modifiers = Set(combo.mods.map(\.keyCode))
        // A bare key ("space", "f5") would be swallowed everywhere on the system.
        guard !modifiers.isEmpty else { return nil }
        modifierKeys = modifiers
        mainKey = combo.mainKey
    }

    /// Modifier families a chord requires, as generic event flags. Caps Lock, the numeric-pad bit
    /// and the Fn bit that macOS sets on arrow and function keys are deliberately ignored unless
    /// the shortcut itself names Fn.
    var requiredFamilies: CGEventFlags {
        var flags: CGEventFlags = []
        for key in modifierKeys {
            switch Int(key) {
            case kVK_Control, kVK_RightControl: flags.insert(.maskControl)
            case kVK_Command, kVK_RightCommand: flags.insert(.maskCommand)
            case kVK_Option, kVK_RightOption: flags.insert(.maskAlternate)
            case kVK_Shift, kVK_RightShift: flags.insert(.maskShift)
            case kVK_Function: flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    /// Whether a key-down's modifier state is exactly this chord's.
    func chordMatches(_ flags: CGEventFlags) -> Bool {
        var compared: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        if modifierKeys.contains(CGKeyCode(kVK_Function)) { compared.insert(.maskSecondaryFn) }
        return flags.intersection(compared) == requiredFamilies.intersection(compared)
    }

    /// The physical modifiers that are down, from the device-specific bits macOS carries on every
    /// modifier event. Deriving the whole set from each event, rather than toggling on each one,
    /// cannot drift out of step after a missed event (a tap re-enable, sleep, Secure Input).
    static func physicalModifiers(_ flags: CGEventFlags) -> Set<CGKeyCode> {
        let raw = flags.rawValue
        var down = Set<CGKeyCode>()
        if raw & 0x0000_0001 != 0 { down.insert(CGKeyCode(kVK_Control)) }       // NX_DEVICELCTLKEYMASK
        if raw & 0x0000_2000 != 0 { down.insert(CGKeyCode(kVK_RightControl)) }  // NX_DEVICERCTLKEYMASK
        if raw & 0x0000_0008 != 0 { down.insert(CGKeyCode(kVK_Command)) }       // NX_DEVICELCMDKEYMASK
        if raw & 0x0000_0010 != 0 { down.insert(CGKeyCode(kVK_RightCommand)) }  // NX_DEVICERCMDKEYMASK
        if raw & 0x0000_0020 != 0 { down.insert(CGKeyCode(kVK_Option)) }        // NX_DEVICELALTKEYMASK
        if raw & 0x0000_0040 != 0 { down.insert(CGKeyCode(kVK_RightOption)) }   // NX_DEVICERALTKEYMASK
        if raw & 0x0000_0002 != 0 { down.insert(CGKeyCode(kVK_Shift)) }         // NX_DEVICELSHIFTKEYMASK
        if raw & 0x0000_0004 != 0 { down.insert(CGKeyCode(kVK_RightShift)) }    // NX_DEVICERSHIFTKEYMASK
        if flags.contains(.maskSecondaryFn) { down.insert(CGKeyCode(kVK_Function)) }
        return down
    }
}

enum KeyboardDictationEdge: Equatable {
    case pressed
    case released
    /// Another key or modifier joined a modifier-only shortcut: it was an ordinary chord.
    case interrupted
}

/// Only consume Escape during an owned voice turn; retain key-up ownership after cancellation.
struct VoiceEscapeClassifier {
    var active = false
    private var held = false

    mutating func handle(key: CGKeyCode, down: Bool, repeatKey: Bool) -> (cancel: Bool, swallow: Bool) {
        guard key == CGKeyCode(kVK_Escape) else { return (false, false) }
        if !down {
            let consumed = held
            held = false
            return (false, consumed)
        }
        if held { return (false, true) }
        guard active, !repeatKey else { return (false, false) }
        held = true
        return (true, true)
    }
}

/// Pure event classification, kept separate from the tap so the self-test can drive it.
struct KeyboardDictationClassifier {
    let shortcut: KeyboardDictationShortcut
    private var modifierShortcutHeld = false
    private var modifierAwaitingRelease = false
    private var chordHeld = false

    init(shortcut: KeyboardDictationShortcut) {
        self.shortcut = shortcut
    }

    struct Result: Equatable {
        var edge: KeyboardDictationEdge?
        var swallow: Bool
    }

    mutating func modifiersChanged(_ flags: CGEventFlags) -> Result {
        guard shortcut.isModifierOnly else { return Result(edge: nil, swallow: false) }
        let down = KeyboardDictationShortcut.physicalModifiers(flags)
        if modifierAwaitingRelease {
            if down.isDisjoint(with: shortcut.modifierKeys) { modifierAwaitingRelease = false }
            return Result(edge: nil, swallow: false)
        }
        let satisfied = down == shortcut.modifierKeys
        defer { modifierShortcutHeld = satisfied }
        if satisfied && !modifierShortcutHeld { return Result(edge: .pressed, swallow: false) }
        if !satisfied && modifierShortcutHeld {
            // Releasing a shortcut key ends the press; adding a different modifier means the user
            // was starting some other chord.
            let onlyReleased = down.isSubset(of: shortcut.modifierKeys)
            modifierAwaitingRelease = !down.isDisjoint(with: shortcut.modifierKeys)
            return Result(edge: onlyReleased ? .released : .interrupted, swallow: false)
        }
        return Result(edge: nil, swallow: false)
    }

    mutating func keyDown(_ keyCode: CGKeyCode, flags: CGEventFlags, isRepeat: Bool) -> Result {
        if shortcut.isModifierOnly {
            guard modifierShortcutHeld else { return Result(edge: nil, swallow: false) }
            modifierShortcutHeld = false
            modifierAwaitingRelease = true
            return Result(edge: .interrupted, swallow: false)
        }
        guard keyCode == shortcut.mainKey else { return Result(edge: nil, swallow: false) }
        if chordHeld { return Result(edge: nil, swallow: true) }   // auto-repeat while held
        guard !isRepeat, shortcut.chordMatches(flags) else { return Result(edge: nil, swallow: false) }
        chordHeld = true
        return Result(edge: .pressed, swallow: true)
    }

    mutating func keyUp(_ keyCode: CGKeyCode) -> Result {
        guard !shortcut.isModifierOnly, chordHeld, keyCode == shortcut.mainKey else {
            return Result(edge: nil, swallow: false)
        }
        chordHeld = false
        return Result(edge: .released, swallow: true)
    }
}

/// Completed shortcut gestures toggle recording. Main thread only.
final class KeyboardDictationTrigger {
    enum State: Equatable { case idle, pending, listening }

    /// Returns true when Voice accepted the press.
    var onPrime: (() -> Bool)?
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEnd: (() -> Void)?
    var onAbandon: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var state: State = .idle
    private var stopArmed = false
    private var configuredShortcut: KeyboardDictationShortcut?
    private let tap = KeyboardShortcutTap()

    init() {
        tap.onEdge = { [weak self] edge in
            DispatchQueue.main.async { self?.handle(edge) }
        }
        tap.onEscape = { [weak self] in
            DispatchQueue.main.async { self?.onEscape?() }
        }
    }

    func setCancellationActive(_ active: Bool) { tap.setCancellationActive(active) }

    /// Install, change or remove the start shortcut. An already installed tap may remain to
    /// classify Escape, but passes every event through when both voice and the shortcut are off.
    func setShortcut(_ text: String) {
        let shortcut = KeyboardDictationShortcut(text)
        if shortcut == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rmDebug("⌨️ voice shortcut '\(text)' is not a usable shortcut; keyboard trigger off")
        }
        guard shortcut != configuredShortcut else { return }
        configuredShortcut = shortcut
        let previous = state
        captureEnded()
        if previous == .pending { onCancel?() }
        if previous == .listening { onAbandon?() }
        tap.setShortcut(shortcut)
    }

    func handle(_ edge: KeyboardDictationEdge) {
        switch (state, edge) {
        case (.idle, .pressed):
            guard onPrime?() == true else { return }
            state = .pending
        case (.pending, .released):
            state = .listening
            onBegin?()
        case (.pending, .interrupted):
            state = .idle
            onCancel?()
        case (.listening, .pressed):
            stopArmed = true
        case (.listening, .released):
            guard stopArmed else { return }
            captureEnded()
            onEnd?()
        case (.listening, .interrupted):
            // Ordinary typing/chords during hands-free recording do not cancel the utterance.
            stopArmed = false
        default:
            break
        }
    }

    /// The coordinator can end capture itself (maximum duration, target rejection, failure).
    /// Forget the toggle then, so the next shortcut starts a fresh turn instead of stopping a
    /// recording which has already ended. This only resets local state; it never calls back.
    func captureEnded() {
        state = .idle
        stopArmed = false
    }
}

/// Owns the CGEvent tap and its thread. Classification happens on the tap thread under a lock;
/// edges are handed to `onEdge` for the main thread.
private final class KeyboardShortcutTap {
    var onEdge: ((KeyboardDictationEdge) -> Void)?
    var onEscape: (() -> Void)?

    private let lock = NSLock()
    private var classifier: KeyboardDictationClassifier?
    private var escape = VoiceEscapeClassifier()
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Set by `stop()` under the lock. A thread that has not yet published its run loop checks it
    /// before running, so a shortcut removed immediately after being set cannot leave a tap behind.
    private var stopRequested = false

    func setShortcut(_ shortcut: KeyboardDictationShortcut?) {
        lock.lock()
        let unchanged = classifier?.shortcut == shortcut
        guard !unchanged else { lock.unlock(); return }
        classifier = shortcut.map { KeyboardDictationClassifier(shortcut: $0) }
        lock.unlock()
        if shortcut != nil, thread == nil {
            start()
        }
    }

    func setCancellationActive(_ active: Bool) {
        lock.lock()
        escape.active = active
        lock.unlock()
        // Remote-only users need Escape even with no keyboard start shortcut configured.
        if active, thread == nil { start() }
    }

    private func start() {
        lock.lock()
        stopRequested = false
        lock.unlock()
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "com.hypervibe.voice-keyboard-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func stop() {
        lock.lock()
        stopRequested = true
        let loop = runLoop
        let tap = eventTap
        runLoop = nil
        eventTap = nil
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    private func runTapLoop() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<KeyboardShortcutTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rmDebug("❌ voice keyboard shortcut: CGEvent.tapCreate failed — check Accessibility permission")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        runLoop = loop
        lock.unlock()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        rmDebug("⌨️ voice keyboard shortcut tap installed")
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        rmDebug("⌨️ voice keyboard shortcut tap removed")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            rmDebug("⚠️ voice keyboard shortcut tap was disabled — re-enabled")
            return Unmanaged.passUnretained(event)
        }
        // HyperVibe's own synthetic keystrokes (the Command-V of a paste, a remote keystroke
        // binding) must never look like the user pressing the shortcut.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown || type == .keyUp {
            let result = escape.handle(key: keyCode, down: type == .keyDown,
                                       repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            if result.swallow {
                lock.unlock()
                if result.cancel { onEscape?() }
                return nil
            }
        }
        guard var classifier else {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let result: KeyboardDictationClassifier.Result
        switch type {
        case .flagsChanged:
            result = classifier.modifiersChanged(event.flags)
        case .keyDown:
            result = classifier.keyDown(
                keyCode, flags: event.flags,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            result = classifier.keyUp(keyCode)
        default:
            result = .init(edge: nil, swallow: false)
        }
        self.classifier = classifier
        lock.unlock()

        if let edge = result.edge { onEdge?(edge) }
        return result.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
