//
//  VoicePipelinePresentation.swift
//  HyperVibe
//
//  One visual vocabulary for native Voice's post-capture pipeline.  The always-on status card
//  and the temporary Typeless-style Voice capsule deliberately render different compositions,
//  but they must never disagree about which stage, colour, symbol, or motion is active.
//

import AppKit

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
    static func showsFloatingCapsule(for mode: Config.DictationMode) -> Bool {
        mode != .external
    }
}

enum VoicePipelineVisualStage: Int, CaseIterable, Equatable {
    case transcribing
    case polishing
    case inserting
    case inserted
    case copied
    case error

    init?(_ phase: VoiceDictationPhase) {
        switch phase {
        case .transcribing: self = .transcribing
        case .polishing: self = .polishing
        case .inserting: self = .inserting
        case .inserted: self = .inserted
        case .copied: self = .copied
        case .error: self = .error
        case .idle, .priming, .listening: return nil
        }
    }

    var title: String {
        switch self {
        case .transcribing: return L("Transcribing")
        case .polishing: return L("Polishing")
        case .inserting: return L("Inserting")
        case .inserted: return L("Inserted")
        case .copied: return L("Copied")
        case .error: return L("Voice Input")
        }
    }

    var configIconKey: String {
        switch self {
        case .transcribing: return "voice.transcribing"
        case .polishing: return "voice.polishing"
        case .inserting: return "voice.inserting"
        case .inserted: return "voice.inserted"
        case .copied: return "voice.copied"
        case .error: return "voice.error"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .polishing: return "wand.and.stars"
        case .inserting: return "text.cursor"
        case .inserted: return "checkmark.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .transcribing: return .systemOrange
        case .polishing: return .systemPurple
        case .inserting: return .systemBlue
        case .inserted: return .systemGreen
        case .copied: return .systemBlue
        case .error: return .systemRed
        }
    }

    var symbolCue: ActionSymbolCue {
        switch self {
        case .transcribing: return .voice
        case .polishing: return .search
        case .inserting: return .paste
        case .inserted: return .confirm
        case .copied: return .copy
        case .error: return .destructive
        }
    }

    var isTerminal: Bool {
        switch self {
        case .inserted, .copied, .error: return true
        case .transcribing, .polishing, .inserting: return false
        }
    }

    /// Stable pipeline progress for the dedicated capsule. Error and clipboard fallback are exits,
    /// not fictitious extra processing stages, so both land at the delivery edge.
    var progress: CGFloat {
        switch self {
        case .transcribing: return 0.18
        case .polishing: return 0.48
        case .inserting: return 0.76
        case .inserted, .copied, .error: return 1
        }
    }
}
