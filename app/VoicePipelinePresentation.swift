//
//  VoicePipelinePresentation.swift
//  HyperVibe
//
//  One visual vocabulary for native Voice's post-capture pipeline.  The always-on status card
//  and the temporary Typeless-style Voice capsule deliberately render different compositions,
//  but they must never disagree about which stage, colour, symbol, or motion is active.
//

import AppKit

/// Resolves the same ordered Layer colour vocabulary used by the always-on status surface. Voice
/// keeps the active Layer's identity while its particle geometry changes state, so colour no
/// longer resets to anonymous white whenever the temporary orb appears.
enum VoiceLayerPalette {
    static func tint(for rawLayerID: String?,
                     layers: [Config.LayerDefinition]) -> NSColor {
        let id = rawLayerID?.uppercased() ?? "BASE"
        if let definition = layers.first(where: { $0.id.uppercased() == id }),
           let raw = definition.color,
           let configured = configuredColor(raw) {
            return configured
        }
        if id == "BASE" { return .systemGreen }
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange,
                                  .systemPink, .systemTeal, .systemIndigo]
        if id.hasPrefix("L"), let number = Int(id.dropFirst()), number > 0 {
            return palette[(number - 1) % palette.count]
        }
        if let ordinal = layers.firstIndex(where: { $0.id.uppercased() == id }), ordinal > 0 {
            return palette[(ordinal - 1) % palette.count]
        }
        return .systemBlue
    }

    private static func configuredColor(_ raw: String) -> NSColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "accent", "accentcolor", "controlaccentcolor": return .controlAccentColor
        case "red", "systemred": return .systemRed
        case "orange", "systemorange": return .systemOrange
        case "yellow", "systemyellow": return .systemYellow
        case "green", "systemgreen": return .systemGreen
        case "mint", "systemmint": return .systemMint
        case "teal", "systemteal": return .systemTeal
        case "cyan", "systemcyan": return .systemCyan
        case "blue", "systemblue": return .systemBlue
        case "indigo", "systemindigo": return .systemIndigo
        case "purple", "systempurple": return .systemPurple
        case "pink", "systempink": return .systemPink
        case "brown", "systembrown": return .systemBrown
        case "gray", "grey", "systemgray", "systemgrey": return .systemGray
        default:
            guard value.hasPrefix("#") else { return nil }
            let digits = String(value.dropFirst())
            guard (digits.count == 6 || digits.count == 8),
                  let packed = UInt64(digits, radix: 16) else { return nil }
            let hasAlpha = digits.count == 8
            let red = CGFloat((packed >> (hasAlpha ? 24 : 16)) & 0xff) / 255
            let green = CGFloat((packed >> (hasAlpha ? 16 : 8)) & 0xff) / 255
            let blue = CGFloat((packed >> (hasAlpha ? 8 : 0)) & 0xff) / 255
            let alpha = hasAlpha ? CGFloat(packed & 0xff) / 255 : 1
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }
}

/// Shared visual semantics for the global Voice selector. Both floating surfaces read this exact
/// vocabulary so a hardware mode switch cannot show different names, colours, or symbols.
extension Config.DictationMode {
    var presentationTitle: String {
        switch self {
        case .external: return L("External Voice")
        case .final: return L("Final Voice")
        case .streaming: return L("Live Voice")
        }
    }

    var presentationDetail: String {
        switch self {
        case .external: return L("Uses the configured side-button action")
        case .final: return L("Polished after release · every Layer")
        case .streaming: return L("Streams while speaking · every Layer")
        }
    }

    var presentationBadge: String {
        switch self {
        case .external: return "EXTERNAL"
        case .final: return "FINAL"
        case .streaming: return "LIVE"
        }
    }

    var presentationSymbol: String {
        switch self {
        case .external: return "keyboard.badge.ellipsis"
        case .final: return "text.badge.checkmark"
        case .streaming: return "bolt.horizontal.circle.fill"
        }
    }

    var presentationTint: NSColor {
        switch self {
        case .external: return .systemBlue
        case .final: return .systemPurple
        case .streaming: return .systemOrange
        }
    }

    var presentationCue: ActionSymbolCue {
        switch self {
        case .external: return .connected
        case .final: return .confirm
        case .streaming: return .voice
        }
    }
}

enum VoiceModePresentationPolicy {
    /// External never owns a real capture: a held Side button continues through the configured
    /// action engine and therefore must not open the temporary listening capsule.
    static func showsFloatingCapsule(for mode: Config.DictationMode) -> Bool {
        mode != .external
    }

    /// Selecting a mode is a different presentation boundary from holding it. The selector must
    /// confirm all three destinations, including External, or the capsule appears to blink out on
    /// every third Mute+Side chord and the user cannot tell which route is active.
    static func showsModeSwitchCapsule(for mode: Config.DictationMode) -> Bool {
        switch mode {
        case .external, .final, .streaming: return true
        }
    }
}

enum VoicePipelineVisualStage: Int, CaseIterable, Equatable {
    case transcribing
    case polishing
    case rewriting
    case inserting
    case inserted
    case replaced
    case copied
    case error

    init?(_ phase: VoiceDictationPhase) {
        switch phase {
        case .transcribing: self = .transcribing
        case .polishing: self = .polishing
        case .rewriting: self = .rewriting
        case .inserting: self = .inserting
        case .inserted: self = .inserted
        case .replaced: self = .replaced
        case .copied: self = .copied
        case .error: self = .error
        case .idle, .priming, .listening: return nil
        }
    }

    var title: String {
        switch self {
        case .transcribing: return L("Transcribing")
        case .polishing: return L("Polishing")
        case .rewriting: return L("Rewriting Selection")
        case .inserting: return L("Inserting")
        case .inserted: return L("Inserted")
        case .replaced: return L("Selection Updated")
        case .copied: return L("Copied")
        case .error: return L("Voice Input")
        }
    }

    var configIconKey: String {
        switch self {
        case .transcribing: return "voice.transcribing"
        case .polishing: return "voice.polishing"
        case .rewriting: return "voice.selection.rewriting"
        case .inserting: return "voice.inserting"
        case .inserted: return "voice.inserted"
        case .replaced: return "voice.selection.replaced"
        case .copied: return "voice.copied"
        case .error: return "voice.error"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .polishing: return "wand.and.stars"
        case .rewriting: return "square.and.pencil"
        case .inserting: return "text.cursor"
        case .inserted: return "checkmark.circle.fill"
        case .replaced: return "checkmark.seal.fill"
        case .copied: return "doc.on.doc.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .transcribing: return .systemOrange
        case .polishing: return .systemPurple
        case .rewriting: return .systemIndigo
        case .inserting: return .systemBlue
        case .inserted: return .systemGreen
        case .replaced: return .systemGreen
        case .copied: return .systemBlue
        case .error: return .systemRed
        }
    }

    var symbolCue: ActionSymbolCue {
        switch self {
        case .transcribing: return .voice
        case .polishing: return .search
        case .rewriting: return .search
        case .inserting: return .paste
        case .inserted: return .confirm
        case .replaced: return .confirm
        case .copied: return .copy
        case .error: return .destructive
        }
    }

    var isTerminal: Bool {
        switch self {
        case .inserted, .replaced, .copied, .error: return true
        case .transcribing, .polishing, .rewriting, .inserting: return false
        }
    }

    /// Stable pipeline progress for the dedicated capsule. Error and clipboard fallback are exits,
    /// not fictitious extra processing stages, so both land at the delivery edge.
    var progress: CGFloat {
        switch self {
        case .transcribing: return 0.18
        case .polishing: return 0.48
        case .rewriting: return 0.58
        case .inserting: return 0.76
        case .inserted, .replaced, .copied, .error: return 1
        }
    }
}
