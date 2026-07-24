//
//  ActionVisual.swift
//  HyperVibe
//
//  Turns a binding into something showable: a short label and an icon. Used by the hold-progress
//  HUD, where "what will run if I let go now" has to be readable at a glance.
//
//  Order of preference, most specific first:
//    1. `label` / `icon` written in config.jsonc for that binding
//    2. the REAL application icon, for anything that opens an app — `launch`, and also
//       `shell` commands of the `open -a "Some App"` form, which is how most app launches are
//       actually written. Shown alone, without a label.
//    3. the REAL application icon again for an action AIMED at an app (`tell application "X" …`),
//       this time beside the label — it drives that app, it does not open it
//    4. an SF Symbol picked from the action kind
//

import AppKit

enum ActionVisual {

    struct Visual {
        let label: String
        let image: NSImage?
        /// True when `image` is the real icon of the app being opened. An app icon already says
        /// which app this is, and it is a picture rather than a glyph — pairing it with the name
        /// only makes the two fight over the same optical centre. So the HUD shows it alone, and
        /// bigger. Writing an explicit `label` in config turns this off and puts the name back.
        let iconOnly: Bool
    }

    /// Sizes chosen so a solo app icon carries the card on its own, while a symbol sitting beside
    /// text stays close to the text's own weight.
    private static let soloSize: CGFloat = 44
    private static let inlineSize: CGFloat = 28

    static func resolve(_ action: Action, _ presentation: Config.Presentation?) -> Visual {
        let named = presentation?.label.flatMap { $0.isEmpty ? nil : $0 }

        // A custom SF Symbol always wins, and always keeps its label — it was chosen deliberately.
        if let iconName = presentation?.icon, !iconName.isEmpty,
           let sym = symbol(iconName, size: inlineSize) {
            return Visual(label: named ?? fallbackLabel(action), image: sym, iconOnly: false)
        }

        if let app = launchedAppName(action), let icon = appIcon(named: app) {
            if let named = named {
                icon.size = NSSize(width: inlineSize, height: inlineSize)
                return Visual(label: named, image: icon, iconOnly: false)
            }
            icon.size = NSSize(width: soloSize, height: soloSize)
            return Visual(label: app, image: icon, iconOnly: true)
        }

        // An action AIMED at an app (rather than one that opens it) still shows that app's icon —
        // far more recognisable than the generic per-kind symbol — but keeps its label, because
        // "tell Music to playpause" is not "open Music" and must not read as though it were.
        if let app = targetedAppName(action), let icon = appIcon(named: app) {
            icon.size = NSSize(width: inlineSize, height: inlineSize)
            return Visual(label: named ?? fallbackLabel(action), image: icon, iconOnly: false)
        }

        return Visual(label: named ?? fallbackLabel(action),
                      image: symbol(defaultSymbolName(action), size: inlineSize),
                      iconOnly: false)
    }

    private static func fallbackLabel(_ action: Action) -> String {
        // An `open -a` shell command reads far better as the app's name than as the raw command.
        if case .shell(let command) = action, let app = appName(fromOpenCommand: command) {
            return app
        }
        return action.displayLabel
    }

    // MARK: - App icons

    /// The app an action opens, whether written as `launch` or as an `open -a` shell command.
    private static func launchedAppName(_ action: Action) -> String? {
        switch action {
        case .launch(let app, _):    return app
        case .shell(let command):    return appName(fromOpenCommand: command)
        default:                     return nil
        }
    }

    /// The app an action drives without opening it: `tell application "Music" to …`.
    private static func targetedAppName(_ action: Action) -> String? {
        guard case .applescript(let script) = action else { return nil }
        return firstMatch(#"\btell\s+application\s+(?:"([^"]+)"|'([^']+)')"#, in: script)
    }

    /// Pull the app out of `open -a "Some App"` / `open -g -a 'Some App'` / `open -a SomeApp`.
    /// Returns nil for any other command, including `open <url>`, which opens no app by name.
    static func appName(fromOpenCommand command: String) -> String? {
        firstMatch(#"\bopen\b[^\n]*?\s-a\s+(?:"([^"]+)"|'([^']+)'|([^\s'"]+))"#, in: command)
    }

    /// First non-empty capture group of `pattern` in `text`.
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                let name = String(text[r]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static var iconCache: [String: NSImage] = [:]

    /// Find an app by display name and return its icon. Checks the standard locations directly —
    /// CoreServices matters here because system pieces like Mission Control live there, not in
    /// /Applications.
    static func appIcon(named name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached.copy() as? NSImage }
        guard let url = applicationURL(named: name) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[name] = icon
        return icon.copy() as? NSImage
    }

    /// Locate an application by display name. Shared with the launcher so an app that shows an icon
    /// is by construction one that can be opened — the two cannot disagree about what a name means.
    static func applicationURL(named name: String) -> URL? {
        let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        var candidates = [
            "/Applications/\(bare).app",
            "/System/Applications/\(bare).app",
            "/System/Applications/Utilities/\(bare).app",
            "/System/Library/CoreServices/\(bare).app",
            NSHomeDirectory() + "/Applications/\(bare).app",
        ]
        // Also let LaunchServices try — it resolves bundle IDs and non-standard install locations.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bare) {
            candidates.insert(url.path, at: 0)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - SF Symbols

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    /// A reasonable symbol per action kind, so nothing ever shows up blank.
    private static func defaultSymbolName(_ action: Action) -> String {
        switch action {
        case .keystroke:   return "keyboard"
        case .pushToTalk:  return "mic.fill"
        case .media:       return "playpause.fill"
        case .mouse:       return "cursorarrow.click"
        case .launch:      return "arrow.up.forward.app"
        case .shell:       return "terminal"
        case .applescript: return "applescript"
        case .mode:        return "rectangle.on.rectangle"
        case .layer:       return "square.stack.3d.up.fill"
        case .space:       return "rectangle.split.3x1"
        case .fullscreen:  return "arrow.up.left.and.arrow.down.right"
        case .minimize:    return "arrow.down.right.and.arrow.up.left"
        case .closeWindow: return "xmark.circle.fill"
        case .appWheel:    return "circle.grid.3x3.fill"
        case .repeatKey:   return "repeat"
        case .brightness:  return "sun.max.fill"
        }
    }
}
