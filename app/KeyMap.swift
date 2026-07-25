//
//  KeyMap.swift
//  HyperVibe (config engine integration)
//
//  Parses keystroke strings like "cmd+shift+up", "ctrl+9", or a modifier-only chord like
//  "rctrl+rcmd+ropt" into ordered modifier keys + an optional main key. Supports left/right
//  modifier variants (right ones carry the device-specific NX flag so apps that distinguish
//  sides see the right key).
//

import Carbon.HIToolbox
import CoreGraphics

enum KeyMap {
    /// A parsed keystroke. `mainKey` is nil for a modifier-only chord (a "hyperkey").
    struct Combo {
        var mods: [(keyCode: CGKeyCode, flag: CGEventFlags)]
        var flags: CGEventFlags   // union of all modifier flags
        var mainKey: CGKeyCode?
    }

    /// Parse a combo string. Returns nil on any unknown token or if more than one main key.
    static func parse(_ combo: String) -> Combo? {
        let tokens = combo.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var mods: [(keyCode: CGKeyCode, flag: CGEventFlags)] = []
        var flags: CGEventFlags = []
        var mainKey: CGKeyCode?
        for t in tokens {
            if let m = modifier(t) {
                mods.append(m)
                flags.insert(m.flag)
            } else if let code = keyCode(for: t) {
                if mainKey != nil { return nil }   // at most one non-modifier key
                mainKey = CGKeyCode(code)
            } else {
                return nil
            }
        }
        return Combo(mods: mods, flags: flags, mainKey: mainKey)
    }

    /// Modifier token → (virtual keycode, event flag). Right variants OR in the device-specific
    /// NX flag bit so apps that check left/right see the correct side.
    private static func modifier(_ token: String) -> (keyCode: CGKeyCode, flag: CGEventFlags)? {
        // Each flag ORs in the device-specific NX bit (left or right) on top of the generic mask,
        // matching a real keyboard — system-level shortcuts (Spaces, Mission Control) check it.
        switch token {
        case "cmd", "command", "lcmd", "lcommand":
            return (CGKeyCode(kVK_Command), flag(.maskCommand, 0x8))      // NX_DEVICELCMDKEYMASK
        case "rcmd", "rcommand":
            return (CGKeyCode(kVK_RightCommand), flag(.maskCommand, 0x10)) // NX_DEVICERCMDKEYMASK
        case "ctrl", "control", "lctrl", "lcontrol":
            return (CGKeyCode(kVK_Control), flag(.maskControl, 0x1))       // NX_DEVICELCTLKEYMASK
        case "rctrl", "rcontrol":
            return (CGKeyCode(kVK_RightControl), flag(.maskControl, 0x2000)) // NX_DEVICERCTLKEYMASK
        case "opt", "option", "alt", "lopt", "loption", "lalt":
            return (CGKeyCode(kVK_Option), flag(.maskAlternate, 0x20))     // NX_DEVICELALTKEYMASK
        case "ropt", "roption", "ralt":
            return (CGKeyCode(kVK_RightOption), flag(.maskAlternate, 0x40)) // NX_DEVICERALTKEYMASK
        case "shift", "lshift":
            return (CGKeyCode(kVK_Shift), flag(.maskShift, 0x2))          // NX_DEVICELSHIFTKEYMASK
        case "rshift":
            return (CGKeyCode(kVK_RightShift), flag(.maskShift, 0x4))      // NX_DEVICERSHIFTKEYMASK
        case "fn", "function":
            return (CGKeyCode(kVK_Function), .maskSecondaryFn)
        default:
            return nil
        }
    }

    /// Physical modifier key → stable config token. Used by the shortcut recorder so left/right
    /// variants survive recording and replay.
    static func modifierToken(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Command:      return "lcmd"
        case kVK_RightCommand: return "rcmd"
        case kVK_Control:      return "lctrl"
        case kVK_RightControl: return "rctrl"
        case kVK_Option:       return "lopt"
        case kVK_RightOption:  return "ropt"
        case kVK_Shift:        return "lshift"
        case kVK_RightShift:   return "rshift"
        case kVK_Function:     return "fn"
        default:               return nil
        }
    }

    private static func flag(_ generic: CGEventFlags, _ deviceBit: UInt64) -> CGEventFlags {
        CGEventFlags(rawValue: generic.rawValue | deviceBit)
    }

    private static func keyCode(for token: String) -> Int? {
        if token.count == 1, let ch = token.first {
            if let c = letters[ch] { return c }
            if let d = digits[ch] { return d }
        }
        // Lossless fallback emitted by the recorder for physical keys not yet named here (for
        // example JIS/ISO-specific keys). Keeping the hardware key code makes capture/replay
        // layout-independent without waiting for a new token-table release.
        if token.hasPrefix("keycode"),
           let raw = Int(token.dropFirst("keycode".count)),
           (0...Int(UInt16.max)).contains(raw) {
            return raw
        }
        return named[token]
    }

    /// Physical main key → stable config token. Key codes are layout-independent, matching
    /// Karabiner-style recording: the same physical key replays even when the input source changes.
    static func token(for keyCode: UInt16) -> String? {
        let code = Int(keyCode)
        if let pair = letters.first(where: { $0.value == code }) { return String(pair.key) }
        if let pair = digits.first(where: { $0.value == code }) { return String(pair.key) }
        if let named = preferredNamed.first(where: { $0.value == code })?.key { return named }
        return "keycode\(code)"
    }

    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]

    private static let digits: [Character: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    private static let named: [String: Int] = [
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "esc": kVK_Escape, "escape": kVK_Escape,
        "enter": kVK_Return, "return": kVK_Return,
        "space": kVK_Space, "tab": kVK_Tab,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete,
        "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "help": kVK_Help,
        "capslock": kVK_CapsLock,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
        "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "mute": kVK_Mute, "volumeup": kVK_VolumeUp, "volumedown": kVK_VolumeDown,
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1,
        "keypad2": kVK_ANSI_Keypad2, "keypad3": kVK_ANSI_Keypad3,
        "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7,
        "keypad8": kVK_ANSI_Keypad8, "keypad9": kVK_ANSI_Keypad9,
        "keypaddecimal": kVK_ANSI_KeypadDecimal,
        "keypadmultiply": kVK_ANSI_KeypadMultiply,
        "keypadplus": kVK_ANSI_KeypadPlus,
        "keypadclear": kVK_ANSI_KeypadClear,
        "keypaddivide": kVK_ANSI_KeypadDivide,
        "keypadenter": kVK_ANSI_KeypadEnter,
        "keypadminus": kVK_ANSI_KeypadMinus,
        "keypadequals": kVK_ANSI_KeypadEquals,
        "section": kVK_ISO_Section,
        // Punctuation. Braces { } are Shift + [ ] — write them as e.g. "cmd+shift+[".
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "\\": kVK_ANSI_Backslash,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    ]

    /// One canonical token per physical key for recording (aliases such as escape/return omitted).
    private static let preferredNamed: [String: Int] = [
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "esc": kVK_Escape, "enter": kVK_Return, "space": kVK_Space, "tab": kVK_Tab,
        "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "help": kVK_Help, "capslock": kVK_CapsLock,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
        "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "mute": kVK_Mute, "volumeup": kVK_VolumeUp, "volumedown": kVK_VolumeDown,
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1,
        "keypad2": kVK_ANSI_Keypad2, "keypad3": kVK_ANSI_Keypad3,
        "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7,
        "keypad8": kVK_ANSI_Keypad8, "keypad9": kVK_ANSI_Keypad9,
        "keypaddecimal": kVK_ANSI_KeypadDecimal, "keypadmultiply": kVK_ANSI_KeypadMultiply,
        "keypadplus": kVK_ANSI_KeypadPlus, "keypadclear": kVK_ANSI_KeypadClear,
        "keypaddivide": kVK_ANSI_KeypadDivide, "keypadenter": kVK_ANSI_KeypadEnter,
        "keypadminus": kVK_ANSI_KeypadMinus, "keypadequals": kVK_ANSI_KeypadEquals,
        "section": kVK_ISO_Section,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "\\": kVK_ANSI_Backslash,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    ]
}
