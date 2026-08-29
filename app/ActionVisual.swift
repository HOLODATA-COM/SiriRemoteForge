//
//  ActionVisual.swift
//  HyperVibe
//
//  Turns a binding into something showable: a short label and an icon. Used by the hold-progress
//  HUD, where "what will run if I let go now" has to be readable at a glance.
//
//  Order of preference, most specific first:
//    1. measured volume/brightness state (these are variable symbols, not static commands)
//    2. the REAL application icon, for anything that opens an app — `launch`, and also
//       `shell` commands of the `open -a "Some App"` form, which is how most app launches are
//       actually written. Shown alone, without a label.
//    3. `label` / `icon` written in config.jsonc for any ordinary binding
//    4. the REAL application icon again for an action AIMED at an app (`tell application "X" …`),
//       this time beside the label — it drives that app, it does not open it
//    5. an SF Symbol picked from the action kind
//

import AppKit

enum ActionVisual {

    struct Visual {
        let label: String
        let image: NSImage?
        /// Retain the source name when this is an SF Symbol. AppKit's public Symbols framework
        /// can animate symbol topology directly, but it intentionally does not expose SVG paths
        /// from an arbitrary `NSImage`; explicit provenance is therefore safer than guessing.
        let symbolName: String?
        /// True when `image` is the real icon of the app being opened. An app icon already says
        /// which app this is, and it is a picture rather than a glyph — pairing it with the name
        /// only makes the two fight over the same optical centre. So the HUD shows it alone, and
        /// bigger. Writing an explicit `label` in config turns this off and puts the name back.
        let iconOnly: Bool
        /// Shared across every action surface. A custom config icon may change the drawing, but it
        /// must not erase the action's severity or physical behaviour.
        let tint: NSColor
        let symbolCue: ActionSymbolCue
        /// Real system state for a stateful control symbol. Volume up/down and brightness up/down
        /// share one symbol family; this value, not the direction key, determines its visible fill.
        let controlState: ControlVisualState?
    }

    /// Sizes chosen so a solo app icon carries the card on its own, while a symbol sitting beside
    /// text stays close to the text's own weight.
    private static let soloSize: CGFloat = 44
    private static let inlineSize: CGFloat = 28

    static func resolve(_ action: Action, _ presentation: Config.Presentation?,
                        prefersTargetAppIcon: Bool = true,
                        controlStateOverride: ControlVisualState? = nil) -> Visual {
        let named = presentation?.label.flatMap { $0.isEmpty ? nil : $0 }
        let style = ActionSymbolStyle.presentation(for: action)
        let controlState = controlStateOverride ?? SystemControlState.snapshot(for: action)

        // Volume +/- and brightness +/- are changes to one system state, not four unrelated
        // commands. Their icon is therefore always the measured variable-value family: JSON may
        // name the action, but a static custom glyph must never contradict the real system state.
        if let controlState {
            let symbolName = stateSymbolName(for: controlState)
            if let image = symbol(symbolName, size: inlineSize,
                                  variableValue: controlState.isMuted ? nil : controlState.value) {
                return Visual(label: stateLabel(named: named, action: action,
                                                state: controlState), image: image,
                              symbolName: symbolName, iconOnly: false,
                              tint: style.tint, symbolCue: style.cue,
                              controlState: controlState)
            }
        }

        // Launching an App is the other deliberate exception to JSON icon selection. The installed
        // bundle is the source of truth, so every surface automatically follows an App icon update.
        if let app = launchedAppName(action), let icon = appIcon(named: app) {
            if let named = named {
                icon.size = NSSize(width: inlineSize, height: inlineSize)
                return Visual(label: named, image: icon, symbolName: nil, iconOnly: false,
                              tint: style.tint, symbolCue: style.cue,
                              controlState: controlState)
            }
            icon.size = NSSize(width: soloSize, height: soloSize)
            return Visual(label: app, image: icon, symbolName: nil, iconOnly: true,
                          tint: style.tint, symbolCue: style.cue,
                          controlState: controlState)
        }

        // A custom SF Symbol always wins, and always keeps its label — it was chosen deliberately.
        if let iconName = presentation?.icon, !iconName.isEmpty,
           let sym = symbol(iconName, size: inlineSize) {
            return Visual(label: named ?? fallbackLabel(action), image: sym,
                          symbolName: iconName, iconOnly: false,
                          tint: style.tint, symbolCue: style.cue,
                          controlState: controlState)
        }

        // An action AIMED at an app (rather than one that opens it) still shows that app's icon —
        // far more recognisable than the generic per-kind symbol — but keeps its label, because
        // "tell Music to playpause" is not "open Music" and must not read as though it were.
        if prefersTargetAppIcon,
           let app = targetedAppName(action), let icon = appIcon(named: app) {
            icon.size = NSSize(width: inlineSize, height: inlineSize)
            return Visual(label: named ?? fallbackLabel(action), image: icon,
                          symbolName: nil, iconOnly: false,
                          tint: style.tint, symbolCue: style.cue,
                          controlState: controlState)
        }

        let preferredName = defaultSymbolName(action)
        if let image = symbol(preferredName, size: inlineSize) {
            return Visual(label: named ?? fallbackLabel(action), image: image,
                          symbolName: preferredName, iconOnly: false,
                          tint: style.tint, symbolCue: style.cue,
                          controlState: controlState)
        }
        return Visual(label: named ?? fallbackLabel(action),
                      image: symbol("command", size: inlineSize),
                      symbolName: "command", iconOnly: false,
                      tint: style.tint, symbolCue: style.cue,
                      controlState: controlState)
    }

    private static func fallbackLabel(_ action: Action) -> String {
        if case .pushToTalk = action { return L("Voice Input") }
        // An `open -a` shell command reads far better as the app's name than as the raw command.
        if case .shell(let command) = action, let app = appName(fromOpenCommand: command) {
            return app
        }
        // The engine's English display label is used as the translation key so HUD action names
        // localize at the presentation boundary without coupling SiriRemoteCore to the UI language.
        return L(action.displayLabel)
    }

    /// Mute is a binary state, not a direction. The compact surface therefore names the measured
    /// result after the command: a slashed speaker reads `Mute`, and an unslashed speaker reads
    /// `Unmute`. A deliberately custom label still wins; the conventional Mute/Unmute labels are
    /// the only configured strings that opt into this live-state wording.
    private static func stateLabel(named: String?, action: Action,
                                   state: ControlVisualState) -> String {
        guard state.kind == .volume,
              SystemControlState.isSystemOutputMuteToggle(action) else {
            return named ?? fallbackLabel(action)
        }
        if let named {
            let conventional = Set(["mute", "unmute", L("Mute").lowercased(),
                                    L("Unmute").lowercased()])
            if !conventional.contains(named.lowercased()) { return named }
        }
        return state.isMuted ? L("Mute") : L("Unmute")
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

    /// One validation grammar for every JSON-driven symbol surface. SF Symbol availability varies
    /// by macOS release; walking the complete authored chain before the built-in fallback prevents
    /// an unsupported Layer override from accidentally skipping `layer.default`.
    static func firstValidSystemSymbol(_ candidates: [String?],
                                       fallback: String) -> String {
        for candidate in candidates.compactMap({ $0 }) where !candidate.isEmpty {
            if NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
                return candidate
            }
        }
        if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            return fallback
        }
        return "command"
    }

    private static func symbol(_ name: String, size: CGFloat,
                               variableValue: Double? = nil) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .medium)
        let image: NSImage?
        if let variableValue {
            image = NSImage(systemSymbolName: name,
                            variableValue: min(1, max(0, variableValue)),
                            accessibilityDescription: nil)
        } else {
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        return image?.withSymbolConfiguration(cfg)
    }

    private static func stateSymbolName(for state: ControlVisualState) -> String {
        switch state.kind {
        case .volume:
            return state.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill"
        case .brightness:
            // `sun.max.fill` is visually static even when created with `variableValue`. Apple's
            // outlined circle variant is the actual variable symbol: its authored ring advances
            // continuously with measured display brightness while the sun stays recognisable.
            return "sun.max.circle"
        }
    }

    /// A reasonable symbol per action kind, so nothing ever shows up blank.
    private static func defaultSymbolName(_ action: Action) -> String {
        switch action {
        case .keystroke(let keys): return keystrokeSymbolName(keys)
        case .pushToTalk:  return "mic.fill"
        case .media(let key):
            switch key.lowercased() {
            case "next": return "forward.end.fill"
            case "previous", "prev": return "backward.end.fill"
            case "volup", "volumeup", "voldown", "volumedown":
                return "speaker.wave.3.fill"
            case "mute": return "speaker.slash.fill"
            default: return "playpause.fill"
            }
        case .mouse(let op):
            switch op.lowercased() {
            case "move": return "cursorarrow.motionlines"
            case "scroll": return "arrow.up.and.down"
            case "rightclick": return "cursorarrow.click.2"
            default: return "cursorarrow.click"
            }
        case .launch:      return "arrow.up.forward.app"
        case .shell(let command):
            let lower = command.lowercased()
            if lower.contains("sleep") || lower.contains("pmset") { return "moon.fill" }
            return "terminal"
        case .applescript(let script):
            let lower = script.lowercased()
            if lower.contains("next track") { return "forward.end.fill" }
            if lower.contains("previous track") { return "backward.end.fill" }
            if lower.contains("playpause") || lower.contains("play pause") {
                return "playpause.fill"
            }
            if lower.contains("output muted") || lower.contains("set volume") {
                return "speaker.slash.fill"
            }
            if lower.contains(" to quit") || lower.contains("quit application") {
                return "power"
            }
            return "applescript"
        case .mode:        return "rectangle.on.rectangle"
        case .layer, .layerCycle: return "square.stack.3d.up.fill"
        case .space(let direction): return direction < 0 ? "arrow.left.square.fill" : "arrow.right.square.fill"
        case .fullscreen:  return "arrow.up.left.and.arrow.down.right"
        case .minimize:    return "arrow.down.right.and.arrow.up.left"
        case .closeWindow: return "xmark.circle.fill"
        case .appWheel:    return "circle.grid.3x3.fill"
        case .repeatKey(let keys, _, _): return keystrokeSymbolName(keys)
        case .brightness: return "sun.max.fill"
        case .brightnessStep: return "sun.max.fill"
        }
    }

    /// Prefer the actual object/action inside a shortcut over a generic keyboard. This keeps
    /// config-authored shortcuts visually alive too: arrows move directionally, copy/paste retain
    /// their document layers, and destructive window/app commands gain unmistakable geometry.
    private static func keystrokeSymbolName(_ keys: String) -> String {
        let tokens = keys.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let set = Set(tokens)
        let hasCommand = !set.isDisjoint(with: ["cmd", "command", "lcmd", "rcmd"])
        let hasShift = !set.isDisjoint(with: ["shift", "lshift", "rshift"])

        if set.contains("delete") || set.contains("backspace") { return "delete.left.fill" }
        if set.contains("forwarddelete") { return "delete.right.fill" }
        if hasCommand, set.contains("q") { return "power" }
        if hasCommand, set.contains("w") { return "xmark.square.fill" }
        if hasCommand, set.contains("c") { return "doc.on.doc" }
        if hasCommand, set.contains("v") { return "doc.on.clipboard" }
        if hasCommand, set.contains("x") { return "scissors" }
        if hasCommand, set.contains("space") { return "magnifyingglass" }
        if hasCommand, hasShift, set.contains("t") { return "arrow.counterclockwise" }
        if hasCommand, set.contains("=") { return "plus.magnifyingglass" }
        if hasCommand, set.contains("-") { return "minus.magnifyingglass" }
        if set.contains("left") { return "arrow.left" }
        if set.contains("right") { return "arrow.right" }
        if set.contains("up") { return "arrow.up" }
        if set.contains("down") { return "arrow.down" }
        if set.contains("enter") || set.contains("return") { return "return" }
        if set.contains("tab") { return "arrow.right.to.line" }
        if set.contains("esc") || set.contains("escape") { return "escape" }
        return "keyboard"
    }
}
