import Foundation

public enum Action: Equatable {
    case keystroke(keys: String)
    case media(key: String)
    case mouse(op: String)
    case launch(app: String?, url: String?)
    case shell(command: String)
    case applescript(script: String)
    case mode(to: String)
    // Momentary layer: while the bound button is physically held, resolve bindings against the
    // named layer mode (a normal `config.modes` entry, e.g. "tvLayer") instead of the app mode.
    // Pushed on press, popped on release (see Controller.pushLayer/popLayer).
    case layer(String)
    case space(direction: Int)   // switch macOS Spaces: -1 = left, +1 = right
    // Auto-repeat a keystroke while the button is physically held (HID sends no auto-repeat).
    // `delay` = seconds before repeating starts; `interval` = seconds between repeats.
    case repeatKey(keys: String, delay: Double, interval: Double)
    // Set all displays' backlight to `value` (0...1). value 0 = minimum (used by button.power to
    // dim without sleeping); any button/touch then restores to max (Brightness.restoreIfDimmed).
    case brightness(Double)
}

public extension Action {
    /// A short, human-readable label for this action, for display in the settings UI.
    /// Pragmatic, not exhaustive — keystrokes render modifier symbols, media/mouse/space get
    /// friendly names, `shell`/`applescript`/`launch` are summarised.
    var displayLabel: String {
        switch self {
        case .keystroke(let keys):      return ActionLabel.keystroke(keys)
        case .media(let key):           return ActionLabel.media(key)
        case .mouse(let op):            return ActionLabel.mouse(op)
        case .launch(let app, let url): return app ?? url ?? "Launch"
        case .shell(let command):       return ActionLabel.shell(command)
        case .applescript(let script):  return ActionLabel.applescript(script)
        case .space(let direction):     return direction < 0 ? "Space ←" : "Space →"
        case .mode(let to):             return "Mode: \(to)"
        case .layer(let name):          return "Layer: \(name)"
        case .repeatKey(let keys, _, _): return ActionLabel.keystroke(keys) + " ⟳"
        case .brightness(let value):    return "Brightness \(Int(value * 100))%"
        }
    }
}

/// Formatting helpers for `Action.displayLabel`.
private enum ActionLabel {
    /// "cmd+shift+[" → "⌘⇧[", "up" → "↑", modifier-only chord "rctrl+rcmd+ropt" → "⌃⌘⌥".
    static func keystroke(_ combo: String) -> String {
        let tokens = combo.lowercased().split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var symbols = ""
        var key = ""
        for t in tokens {
            if let sym = modifierSymbol(t) { symbols += sym }
            else { key = keyLabel(t) }
        }
        if key.isEmpty { return symbols.isEmpty ? combo : symbols }   // modifier-only chord
        return symbols + key
    }

    private static func modifierSymbol(_ t: String) -> String? {
        switch t {
        case "cmd", "command", "lcmd", "lcommand", "rcmd", "rcommand":            return "⌘"
        case "ctrl", "control", "lctrl", "lcontrol", "rctrl", "rcontrol":         return "⌃"
        case "opt", "option", "alt", "lopt", "loption", "lalt", "ropt", "roption", "ralt": return "⌥"
        case "shift", "lshift", "rshift":                                         return "⇧"
        default: return nil
        }
    }

    private static func keyLabel(_ t: String) -> String {
        switch t {
        case "up":                return "↑"
        case "down":              return "↓"
        case "left":              return "←"
        case "right":             return "→"
        case "enter", "return":   return "⏎"
        case "esc", "escape":     return "esc"
        case "space":             return "Space"
        case "tab":               return "⇥"
        case "delete", "backspace": return "⌫"
        case "home":              return "Home"
        case "end":               return "End"
        case "pageup":            return "Page ↑"
        case "pagedown":          return "Page ↓"
        default:                  return t.count == 1 ? t.uppercased() : t
        }
    }

    static func media(_ key: String) -> String {
        switch key.lowercased() {
        case "playpause":         return "Play / Pause"
        case "next":              return "Next"
        case "previous":          return "Previous"
        case "volup", "volumeup": return "Volume +"
        case "voldown", "volumedown": return "Volume −"
        case "mute":              return "Mute"
        default:                  return key
        }
    }

    static func mouse(_ op: String) -> String {
        switch op.lowercased() {
        case "click":      return "Click"
        case "rightclick": return "Right-click"
        case "move":       return "Move"
        case "scroll":     return "Scroll"
        default:           return op
        }
    }

    /// `open -a "Mission Control"` → "Mission Control"; anything else → the trimmed/shortened command.
    static func shell(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = openAppName(trimmed) { return app }
        return shorten(trimmed)
    }

    private static func openAppName(_ cmd: String) -> String? {
        guard let r = cmd.range(of: "open -a ") else { return nil }
        var rest = String(cmd[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        if let q = rest.first, q == "\"" || q == "'" {
            rest.removeFirst()
            if let end = rest.firstIndex(of: q) { rest = String(rest[..<end]) }
        } else if let space = rest.firstIndex(of: " ") {
            rest = String(rest[..<space])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Recognise the common Apple Music control scripts; otherwise just "AppleScript".
    static func applescript(_ script: String) -> String {
        let s = script.lowercased()
        if s.contains("next track")     { return "Next track" }
        if s.contains("previous track") { return "Previous track" }
        if s.contains("playpause") || s.contains("play pause") { return "Play / Pause" }
        if s.contains("mute")           { return "Mute" }
        return "AppleScript"
    }

    static func shorten(_ s: String, max: Int = 30) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}

extension Action: Decodable {
    private enum K: String, CodingKey {
        case action, keys, key, op, app, url, command, script, to, delay, interval, value
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .action) {
        case "keystroke":   self = .keystroke(keys: try c.decode(String.self, forKey: .keys))
        case "media":       self = .media(key: try c.decode(String.self, forKey: .key))
        case "mouse":       self = .mouse(op: try c.decode(String.self, forKey: .op))
        case "launch":      self = .launch(app: try c.decodeIfPresent(String.self, forKey: .app),
                                           url: try c.decodeIfPresent(String.self, forKey: .url))
        case "shell":       self = .shell(command: try c.decode(String.self, forKey: .command))
        case "applescript": self = .applescript(script: try c.decode(String.self, forKey: .script))
        case "mode":        self = .mode(to: try c.decode(String.self, forKey: .to))
        case "layer":       self = .layer(try c.decode(String.self, forKey: .to))
        case "space":       self = .space(direction: (try c.decode(String.self, forKey: .to)) == "left" ? -1 : 1)
        case "repeatKey":   self = .repeatKey(keys: try c.decode(String.self, forKey: .keys),
                                              delay: try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0.3,
                                              interval: try c.decodeIfPresent(Double.self, forKey: .interval) ?? 0.045)
        case "brightness":  self = .brightness(try c.decodeIfPresent(Double.self, forKey: .value) ?? 0)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: K.action, in: c, debugDescription: "unknown action '\(other)'")
        }
    }
}

extension Action: Encodable {
    /// The exact inverse of `init(from:)`: emit `{"action":"<type>", <params>}` so a written config
    /// re-parses to the same `Action`. `layer` and `space` reuse the `to` key (matching decode).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .keystroke(let keys):
            try c.encode("keystroke", forKey: .action)
            try c.encode(keys, forKey: .keys)
        case .media(let key):
            try c.encode("media", forKey: .action)
            try c.encode(key, forKey: .key)
        case .mouse(let op):
            try c.encode("mouse", forKey: .action)
            try c.encode(op, forKey: .op)
        case .launch(let app, let url):
            try c.encode("launch", forKey: .action)
            try c.encodeIfPresent(app, forKey: .app)
            try c.encodeIfPresent(url, forKey: .url)
        case .shell(let command):
            try c.encode("shell", forKey: .action)
            try c.encode(command, forKey: .command)
        case .applescript(let script):
            try c.encode("applescript", forKey: .action)
            try c.encode(script, forKey: .script)
        case .mode(let to):
            try c.encode("mode", forKey: .action)
            try c.encode(to, forKey: .to)
        case .layer(let name):
            try c.encode("layer", forKey: .action)
            try c.encode(name, forKey: .to)
        case .space(let direction):
            try c.encode("space", forKey: .action)
            try c.encode(direction < 0 ? "left" : "right", forKey: .to)
        case .repeatKey(let keys, let delay, let interval):
            try c.encode("repeatKey", forKey: .action)
            try c.encode(keys, forKey: .keys)
            try c.encode(delay, forKey: .delay)
            try c.encode(interval, forKey: .interval)
        case .brightness(let value):
            try c.encode("brightness", forKey: .action)
            try c.encode(value, forKey: .value)
        }
    }
}
