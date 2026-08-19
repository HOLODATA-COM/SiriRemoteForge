import Foundation

/// The modifier identity captured by the macOS shortcut recorder. Left-side modifiers use the
/// compact historic tokens (`cmd`, `ctrl`, `opt`, `shift`); right-side modifiers stay explicit so
/// HyperVibe can reproduce side-sensitive hyperkeys such as `rctrl+rcmd+ropt`.
public enum ShortcutModifier: String, CaseIterable, Hashable, Sendable {
    case control = "ctrl"
    case rightControl = "rctrl"
    case command = "cmd"
    case rightCommand = "rcmd"
    case option = "opt"
    case rightOption = "ropt"
    case shift = "shift"
    case rightShift = "rshift"
    case function = "fn"

    fileprivate var order: Int {
        switch self {
        case .control: return 0
        case .rightControl: return 1
        case .command: return 2
        case .rightCommand: return 3
        case .option: return 4
        case .rightOption: return 5
        case .shift: return 6
        case .rightShift: return 7
        case .function: return 8
        }
    }

    /// Generic modifier family used only to avoid duplicating a tracked left/right key with the
    /// family-level flag supplied on the same NSEvent.
    public var family: String {
        switch self {
        case .control, .rightControl: return "control"
        case .command, .rightCommand: return "command"
        case .option, .rightOption: return "option"
        case .shift, .rightShift: return "shift"
        case .function: return "function"
        }
    }

    /// macOS virtual key codes. Kept as integers so SiriRemoteCore remains free of AppKit/Carbon.
    public init?(macKeyCode: UInt16) {
        switch macKeyCode {
        case 59: self = .control
        case 62: self = .rightControl
        case 55: self = .command
        case 54: self = .rightCommand
        case 58: self = .option
        case 61: self = .rightOption
        case 56: self = .shift
        case 60: self = .rightShift
        case 63: self = .function
        default: return nil
        }
    }
}

/// Converts physical macOS key events and manually entered aliases into the canonical strings used
/// by `Action.keystroke`, `pushToTalk`, `repeatKey`, and `KeyMap`.
public enum ShortcutCodec {
    /// Build a deterministic canonical chord. Multiple physical modifiers from the same family are
    /// retained (for example `cmd+rcmd`), while repeated copies of the exact same key are removed.
    public static func canonical(modifiers: [ShortcutModifier], keyToken: String?) -> String? {
        let ordered = Array(Set(modifiers)).sorted { $0.order < $1.order }
        var tokens = ordered.map(\.rawValue)
        if let keyToken, !keyToken.isEmpty { tokens.append(keyToken.lowercased()) }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: "+")
    }

    /// Normalize manual input and reject anything the executor cannot reproduce. Modifier aliases
    /// and named-key aliases collapse to the same canonical spelling emitted by the recorder.
    public static func normalize(_ input: String) -> String? {
        // Accept the compact symbols shown by the recorder as well as config vocabulary, so a
        // displayed chord such as `⌘⇧T` can be pasted into the advanced text field verbatim.
        let expanded = input
            .replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⌥", with: "opt+")
            .replacingOccurrences(of: "⇧", with: "shift+")
        let rawTokens = expanded.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return nil }

        var modifiers: [ShortcutModifier] = []
        var keyToken: String?
        for raw in rawTokens {
            if let modifier = normalizedModifier(raw) {
                modifiers.append(modifier)
                continue
            }
            guard keyToken == nil, let key = normalizedKey(raw) else { return nil }
            keyToken = key
        }
        return canonical(modifiers: modifiers, keyToken: keyToken)
    }

    /// Physical non-modifier key code → config token. The table intentionally mirrors KeyMap's
    /// executable vocabulary, including navigation, punctuation and F1–F20.
    public static func keyToken(macKeyCode code: UInt16) -> String? {
        keyCodes[code]
    }

    private static func normalizedModifier(_ token: String) -> ShortcutModifier? {
        switch token {
        case "ctrl", "control", "lctrl", "lcontrol": return .control
        case "rctrl", "rcontrol": return .rightControl
        case "cmd", "command", "lcmd", "lcommand": return .command
        case "rcmd", "rcommand": return .rightCommand
        case "opt", "option", "alt", "lopt", "loption", "lalt": return .option
        case "ropt", "roption", "ralt": return .rightOption
        case "shift", "lshift": return .shift
        case "rshift": return .rightShift
        case "fn", "function": return .function
        default: return nil
        }
    }

    private static func normalizedKey(_ token: String) -> String? {
        if token.count == 1, let scalar = token.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) || "[]-=`;'\\,./".contains(Character(token)) {
            return token
        }
        switch token {
        case "escape": return "esc"
        case "return": return "enter"
        case "backspace": return "delete"
        case "forward-delete", "forward_delete": return "forwarddelete"
        case "page-up", "page_up": return "pageup"
        case "page-down", "page_down": return "pagedown"
        default: return namedKeys.contains(token) ? token : nil
        }
    }

    private static let namedKeys: Set<String> = [
        "up", "down", "left", "right", "esc", "enter", "space", "tab", "delete",
        "forwarddelete", "home", "end", "pageup", "pagedown", "help",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
        "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    ]

    private static let keyCodes: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
        38: "j", 40: "k", 45: "n", 46: "m",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
        26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        36: "enter", 48: "tab", 49: "space", 51: "delete", 53: "esc",
        114: "help", 115: "home", 116: "pageup", 117: "forwarddelete", 119: "end",
        121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18",
        80: "f19", 90: "f20",
    ]
}

/// Platform-neutral state machine behind the AppKit recorder. It makes the physical modifier
/// press/release sequence testable without synthesizing global keyboard events.
public struct ShortcutCaptureState: Sendable {
    private var activeModifierCodes = Set<UInt16>()
    private var modifierHistory = Set<ShortcutModifier>()

    public init() {}

    public var activeModifiers: [ShortcutModifier] {
        activeModifierCodes.compactMap(ShortcutModifier.init(macKeyCode:))
    }

    public mutating func reset() {
        activeModifierCodes.removeAll()
        modifierHistory.removeAll()
    }

    /// Toggle one physical modifier edge. Returns a canonical modifier-only chord exactly when the
    /// final key is released; otherwise returns nil and keeps recording.
    public mutating func modifierChanged(macKeyCode code: UInt16) -> String? {
        guard let modifier = ShortcutModifier(macKeyCode: code) else { return nil }
        if activeModifierCodes.contains(code) {
            activeModifierCodes.remove(code)
        } else {
            activeModifierCodes.insert(code)
            modifierHistory.insert(modifier)
        }
        guard activeModifierCodes.isEmpty, !modifierHistory.isEmpty else { return nil }
        return ShortcutCodec.canonical(modifiers: Array(modifierHistory), keyToken: nil)
    }

    /// Build a normal chord from the physical modifiers currently down plus generic family flags
    /// (needed when a modifier was already held before the recorder became first responder).
    public func shortcut(macKeyCode code: UInt16,
                         fallbackModifiers: [ShortcutModifier]) -> String? {
        guard let key = ShortcutCodec.keyToken(macKeyCode: code) else { return nil }
        var modifiers = activeModifiers
        var families = Set(modifiers.map(\.family))
        for modifier in fallbackModifiers where !families.contains(modifier.family) {
            modifiers.append(modifier)
            families.insert(modifier.family)
        }
        return ShortcutCodec.canonical(modifiers: modifiers, keyToken: key)
    }
}
