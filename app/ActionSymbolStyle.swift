//
//  ActionSymbolStyle.swift
//  HyperVibe
//
//  One semantic vocabulary for every action symbol shown by HyperVibe. The persistent widget,
//  the large hold HUD and the transient Layer/connection HUD must not independently decide that
//  the same action is blue in one place, white in another and animated as something unrelated in
//  a third. This file is the single source of truth for colour, authored SF Symbol layers and
//  native symbol motion.
//

import AppKit
import Symbols

/// Motion is selected from the action's meaning, never randomly. Keeping this independent of any
/// one HUD also means a configured custom SF Symbol still behaves like the action it represents.
enum ActionSymbolCue: Equatable {
    case layer
    case volumeUp
    case volumeDown
    case brightnessUp
    case brightnessDown
    case next
    case previous
    case playback
    case back
    case mute
    case destructive
    case sleep
    case search
    case appWheel
    case copy
    case paste
    case cut
    case repeatAction
    case directionLeft
    case directionRight
    case directionUp
    case directionDown
    case expand
    case collapse
    case pointer
    case click
    case contextClick
    case scroll
    case confirm
    case voice
    case launch
    case connected
    case disconnected
    case generic
}

enum ActionSymbolStyle {

    struct Presentation {
        let tint: NSColor
        let cue: ActionSymbolCue
    }

    static func presentation(for action: Action) -> Presentation {
        Presentation(tint: tint(for: action), cue: cue(for: action))
    }

    // MARK: - Semantic colour

    /// Adaptive system colours deliberately carry established macOS meaning:
    /// destructive window/app operations are red; cautionary but reversible operations are orange;
    /// confirmation is green; navigation is blue; media is pink; pointer interaction is teal.
    /// Shape and copy still communicate the action, so colour is never the only signal.
    static func tint(for action: Action) -> NSColor {
        switch action {
        case .keystroke(let keys), .repeatKey(let keys, _, _):
            return tint(forKeystroke: keys)
        case .pushToTalk:
            return .systemRed
        case .media(let raw):
            switch raw.lowercased() {
            case "volup", "volumeup", "voldown", "volumedown": return .systemBlue
            case "mute": return .systemOrange
            default: return .systemPink
            }
        case .mouse:
            return .systemTeal
        case .launch, .appWheel, .mode:
            return .systemIndigo
        case .shell(let command):
            let lower = command.lowercased()
            if lower.contains("sleep") || lower.contains("pmset") { return .systemIndigo }
            if ActionVisual.appName(fromOpenCommand: command) != nil { return .systemIndigo }
            return .systemPurple
        case .applescript(let script):
            let lower = script.lowercased()
            if isDestructiveScript(lower) { return .systemRed }
            if isMuteScript(lower) { return .systemOrange }
            if isMediaScript(lower) { return .systemPink }
            return .systemPurple
        case .space, .fullscreen:
            return .systemBlue
        case .minimize:
            return .systemOrange
        case .closeWindow:
            return .systemRed
        case .layer, .layerCycle:
            // Layer-specific configured colours are applied by the caller when the destination is
            // known; indigo is the safe semantic fallback for a mode/layer command in isolation.
            return .systemIndigo
        case .brightness, .brightnessStep:
            return .systemOrange
        }
    }

    private static func tint(forKeystroke keys: String) -> NSColor {
        let tokens = keyTokens(keys)
        let command = hasCommand(tokens)
        if command && (tokens.contains("q") || tokens.contains("w")) { return .systemRed }
        if command, tokens.contains("x") { return .systemOrange }
        if command && (tokens.contains("c") || tokens.contains("v")) { return .systemBlue }
        if command, tokens.contains("space") { return .systemIndigo }
        if !tokens.isDisjoint(with: ["left", "right", "up", "down"]) { return .systemBlue }
        if tokens.contains("enter") || tokens.contains("return") { return .systemGreen }
        // Character deletion is routine and immediately undoable. Red is reserved for closing a
        // window or quitting an app, which makes the Back hold ladder become progressively urgent.
        if tokens.contains("delete") || tokens.contains("backspace")
            || tokens.contains("forwarddelete") || tokens.contains("escape")
            || tokens.contains("esc") { return .systemBlue }
        return .controlAccentColor
    }

    // MARK: - Semantic motion

    static func cue(for action: Action) -> ActionSymbolCue {
        switch action {
        case .keystroke(let keys):
            return cue(forKeystroke: keys)
        case .repeatKey(let keys, _, _):
            let underlying = cue(forKeystroke: keys)
            return underlying == .generic ? .repeatAction : underlying
        case .pushToTalk:
            return .voice
        case .media(let raw):
            switch raw.lowercased() {
            case "volup", "volumeup": return .volumeUp
            case "voldown", "volumedown": return .volumeDown
            case "mute": return .mute
            case "next": return .next
            case "previous", "prev": return .previous
            default: return .playback
            }
        case .mouse(let op):
            switch op.lowercased() {
            case "move": return .pointer
            case "scroll": return .scroll
            case "rightclick", "right-click", "contextclick": return .contextClick
            default: return .click
            }
        case .launch:
            return .launch
        case .shell(let command):
            let lower = command.lowercased()
            if lower.contains("sleep") || lower.contains("pmset") { return .sleep }
            if ActionVisual.appName(fromOpenCommand: command) != nil { return .launch }
            return .generic
        case .applescript(let script):
            let lower = script.lowercased()
            if isDestructiveScript(lower) { return .destructive }
            if isMuteScript(lower) { return .mute }
            if lower.contains("next track") { return .next }
            if lower.contains("previous track") { return .previous }
            if lower.contains("playpause") || lower.contains("play pause") { return .playback }
            return .generic
        case .space(let direction):
            return direction < 0 ? .directionLeft : .directionRight
        case .fullscreen:
            return .expand
        case .minimize:
            return .collapse
        case .closeWindow:
            return .destructive
        case .appWheel:
            return .appWheel
        case .mode, .layer, .layerCycle:
            return .layer
        case .brightness(let value):
            return value >= 0.5 ? .brightnessUp : .brightnessDown
        case .brightnessStep(let direction):
            return direction >= 0 ? .brightnessUp : .brightnessDown
        }
    }

    private static func cue(forKeystroke keys: String) -> ActionSymbolCue {
        let tokens = keyTokens(keys)
        let command = hasCommand(tokens)
        let shift = !tokens.isDisjoint(with: ["shift", "lshift", "rshift"])
        if command && (tokens.contains("q") || tokens.contains("w")) { return .destructive }
        if command, tokens.contains("c") { return .copy }
        if command, tokens.contains("v") { return .paste }
        if command, tokens.contains("x") { return .cut }
        if command, tokens.contains("space") { return .search }
        if command, shift, tokens.contains("t") { return .repeatAction }
        if command && (tokens.contains("=") || tokens.contains("plus")) { return .expand }
        if command, tokens.contains("-") { return .collapse }
        if tokens.contains("left") { return .directionLeft }
        if tokens.contains("right") { return .directionRight }
        if tokens.contains("up") { return .directionUp }
        if tokens.contains("down") { return .directionDown }
        if tokens.contains("delete") || tokens.contains("backspace")
            || tokens.contains("forwarddelete") || tokens.contains("escape")
            || tokens.contains("esc") { return .back }
        if tokens.contains("enter") || tokens.contains("return") { return .confirm }
        if tokens.contains("tab") { return .directionRight }
        return .generic
    }

    private static func keyTokens(_ keys: String) -> Set<String> {
        Set(keys.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private static func hasCommand(_ tokens: Set<String>) -> Bool {
        !tokens.isDisjoint(with: ["cmd", "command", "lcmd", "rcmd"])
    }

    private static func isDestructiveScript(_ lower: String) -> Bool {
        lower.contains(" to quit") || lower.contains("quit application")
            || lower.contains("close window") || lower.contains("perform action \"axclose\"")
    }

    private static func isMuteScript(_ lower: String) -> Bool {
        lower.contains("output muted") || lower.contains("set volume") || lower.contains(" set mute")
    }

    private static func isMediaScript(_ lower: String) -> Bool {
        lower.contains("next track") || lower.contains("previous track")
            || lower.contains("playpause") || lower.contains("play pause")
    }

    // MARK: - SF Symbols rendering and motion

    /// Preserve the symbol's authored primary/secondary/tertiary topology without using
    /// hierarchical rendering's progressively reduced opacity. The three equal palette entries
    /// keep every authored layer equally legible while Apple's by-layer effects can still address
    /// those layers independently. Symbols with fewer layers simply ignore the extra entries.
    static func hierarchicalImage(_ source: NSImage?, symbolName: String?, tint: NSColor) -> NSImage? {
        guard symbolName != nil, let source else { return source }
        return source.withSymbolConfiguration(.init(paletteColors: [tint, tint, tint]))
    }

    /// Magic Replace is topology-aware, not a universal SVG interpolator. Asking it to bridge
    /// unrelated silhouettes (for example Play → Delete) produces a transient merged blob before
    /// the fallback can settle. Restrict the native path to symbols that genuinely describe one
    /// object changing state; every unrelated action keeps the app's authored semantic 3D turn.
    static func supportsTopologyAwareReplacement(from oldName: String?,
                                                  to newName: String?) -> Bool {
        guard let oldName, let newName else { return false }
        let old = oldName.lowercased()
        let new = newName.lowercased()
        if old == new || removingFillSuffix(old) == removingFillSuffix(new) { return true }

        let relatedFamilies = [
            "speaker",                 // value waves / mute are one output state
            "sun.",                    // brightness variants are one display state
            "square.stack.3d.up",      // active/base layer fill variants
            "appletvremote.gen4",      // connected/disconnected fill variants
        ]
        return relatedFamilies.contains { old.hasPrefix($0) && new.hasPrefix($0) }
    }

    private static func removingFillSuffix(_ name: String) -> String {
        name.hasSuffix(".fill") ? String(name.dropLast(".fill".count)) : name
    }

    /// Native topology-aware replacement. Magic Replace is the most faithful path on macOS 15+;
    /// macOS 14 receives Apple's by-layer replacement, and the caller supplies the Core Animation
    /// fallback for the macOS 13 deployment floor.
    @available(macOS 14.0, *)
    static func replaceSymbol(in imageView: NSImageView, with image: NSImage,
                              cue: ActionSymbolCue?, speed: Double = 2.35) {
        // A replacement is a new semantic transaction. Cancel an interrupted effect before
        // installing the new transition so two variable-colour/bounce timelines can never fight
        // over the same authored layers.
        imageView.removeAllSymbolEffects(options: .default, animated: false)
        let options = SymbolEffectOptions.speed(speed)
        if #available(macOS 15.0, *) {
            imageView.setSymbolImage(
                image,
                contentTransition: .replace.magic(fallback: .replace.downUp.byLayer),
                options: options
            )
        } else {
            imageView.setSymbolImage(image, contentTransition: .replace.downUp.byLayer,
                                     options: options)
        }
        if let cue {
            apply(cue, to: imageView, clearExisting: false)
        }
    }

    /// Effects are intentionally brisk: they live inside a 0.2–0.3 second interaction envelope,
    /// and act on the symbol's own layers instead of scaling the entire card.
    @available(macOS 14.0, *)
    static func apply(_ cue: ActionSymbolCue, to imageView: NSImageView,
                      speed: Double = 2.8, clearExisting: Bool = true) {
        if clearExisting {
            // Discrete effects normally clean themselves up, but a new input may arrive before
            // their visual tail ends. Replacing that tail atomically prevents additive flicker.
            imageView.removeAllSymbolEffects(options: .default, animated: false)
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let options = SymbolEffectOptions.speed(speed)
        switch cue {
        case .volumeUp:
            imageView.addSymbolEffect(.variableColor.cumulative.nonReversing, options: options)
        case .volumeDown:
            imageView.addSymbolEffect(.variableColor.cumulative.reversing, options: options)
        case .mute:
            imageView.addSymbolEffect(.variableColor.iterative.reversing, options: options)
        case .brightnessUp:
            imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
        case .brightnessDown:
            imageView.addSymbolEffect(.bounce.down.byLayer, options: options)
        case .playback, .confirm:
            imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
        case .next:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.forward.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
            }
        case .previous, .back:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.backward.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.down.byLayer, options: options)
            }
        case .directionLeft:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.left.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.down.byLayer, options: options)
            }
        case .directionRight:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.right.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
            }
        case .directionUp:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.up.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
            }
        case .directionDown:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.down.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.down.byLayer, options: options)
            }
        case .layer:
            if #available(macOS 26.0, *) {
                imageView.addSymbolEffect(.drawOn.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.appear.up.byLayer, options: options)
            }
        case .destructive, .contextClick:
            imageView.addSymbolEffect(.pulse.byLayer, options: options)
        case .sleep:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.breathe.pulse.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.pulse.byLayer, options: options)
            }
        case .search:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.clockwise.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.pulse.byLayer, options: options)
            }
        case .appWheel, .repeatAction:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.rotate.clockwise.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.variableColor.iterative, options: options)
            }
        case .copy, .launch, .expand, .connected:
            imageView.addSymbolEffect(.bounce.up.byLayer, options: options)
        case .paste, .collapse, .disconnected:
            imageView.addSymbolEffect(.bounce.down.byLayer, options: options)
        case .cut:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.clockwise.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.byLayer, options: options)
            }
        case .pointer, .scroll:
            if #available(macOS 15.0, *) {
                imageView.addSymbolEffect(.wiggle.byLayer, options: options)
            } else {
                imageView.addSymbolEffect(.bounce.byLayer, options: options)
            }
        case .click, .generic:
            imageView.addSymbolEffect(.bounce.byLayer, options: options)
        case .voice:
            imageView.addSymbolEffect(.pulse.byLayer, options: options)
        }
    }
}
