//
//  StatusWidget.swift
//  HyperVibe
//
//  Optional, always-on status surface. It rests on the current layer, springs briefly to the
//  action/app that just became active, then settles back to the layer. The panel never activates
//  HyperVibe, joins every Space (including full-screen Spaces), and remembers a display-relative
//  drag position so monitor rearrangements and resolution changes do not strand it off-screen.
//

import AppKit
import CoreGraphics
import CoreText
import QuartzCore
import Symbols

/// Microphones expose different analogue gain, so raw 0...1 envelopes are not visually
/// comparable: the same voice can look huge through the Siri Remote and tiny through the Mac's
/// built-in array. Normalize each Voice hold against its own slowly decaying acoustic peak after a
/// real noise gate. The waveform still carries syllable-to-syllable loudness, but changing Layer
/// (and therefore capture route) no longer changes the apparent size of the speaker's voice.
struct VoiceWaveformLevelNormalizer {
    private(set) var peak: CGFloat = 0.22

    mutating func reset() { peak = 0.22 }

    mutating func normalize(_ rawValue: Float) -> CGFloat {
        let raw = CGFloat(rawValue.isFinite ? min(1, max(0, rawValue)) : 0)
        let gate: CGFloat = 0.055
        // Release is wall-clock/display-tick based, including quiet gaps. A loud transient must not
        // pin the scale indefinitely merely because silence sits below the acoustic gate.
        peak = max(0.22, peak * 0.994)
        guard raw > gate else { return 0 }
        let gated = (raw - gate) / (1 - gate)
        // About a 5.5-second peak release at the 30 Hz display cadence. A word can soften without
        // instantly being auto-amplified, while a later sentence can still establish a new scale.
        peak = max(peak, gated)
        let relative = min(1, max(0, gated / peak))
        return min(1, pow(relative, 0.86) * 0.76)
    }
}

final class StatusWidgetController: NSObject, NSWindowDelegate {

    private final class StatusPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Returning this root view from hit-testing makes every visible part of the card a drag
    /// surface, including the icon and labels, without adding buttons or stealing app focus.
    private final class DragSurfaceView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    /// AppKit owns the material's light/dark and high-contrast decisions. Forward effective-
    /// appearance changes to the controller so custom Core Animation content can stay in sync
    /// with the native vibrant labels without polling or sampling the screen.
    private final class AdaptiveMaterialView: NSVisualEffectView {
        var appearanceDidChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in self?.appearanceDidChange?() }
        }
    }

    private struct Face {
        let key: String
        let title: String
        let subtitle: String
        let image: NSImage?
        let symbolName: String?
        let symbolCue: SymbolCue?
        let tint: NSColor
        /// When present, the symbol describes a measured system state rather than the direction
        /// of the binding that requested the change. Kept separate from `key` so a value update is
        /// an in-place redraw, never a fresh content transition.
        let controlState: ControlVisualState?
    }

    /// Shared with the large hold HUD and transient Layer HUD: one action can no longer acquire a
    /// different colour or physical meaning merely because it appears on another surface.
    private typealias SymbolCue = ActionSymbolCue

    private struct HoldItem {
        let key: String
        let action: Action
        let presentation: Config.Presentation?
        let isCancel: Bool
    }

    private struct TimedHoldItem {
        let threshold: TimeInterval
        let item: HoldItem
    }

    /// One point in the compact Voice history. Height carries loudness, hue position carries
    /// intonation relative to this speaker's slowly adapting baseline, confidence controls colour
    /// saturation, and brightness drives the small luminous cap.
    private struct VoiceVisualSample {
        let level: CGFloat
        let pitchPosition: CGFloat
        let pitchConfidence: CGFloat
        let brightness: CGFloat

        static let silence = VoiceVisualSample(level: 0, pitchPosition: 0,
                                               pitchConfidence: 0, brightness: 0)
    }

    /// Both treatments remain compiled into the compact widget so visual experiments never have
    /// to replace input/timing code. The user has currently selected the original water surface.
    private enum HoldProgressVisualStyle: Equatable {
        case water
        case glass
    }

    /// Motion is semantic, never random: once users learn how an App, tap, hold stage or Layer
    /// arrives, that movement becomes another readable dimension of the status surface.
    private enum IconMotion {
        case ordinary
        case layerRebuild(direction: CGFloat)
        case applicationArrival
        /// The App Wheel is nine independent destinations. Reveal its real SF Symbol pixels as a
        /// diagonal relay instead of scaling the complete 3×3 mark like an indivisible bitmap.
        case appWheelWave
        case actionImpulse(count: Int)
        case returnSweep
        case holdSequence
        /// A global Voice route advances independently of Layer. Three orbital traces briefly
        /// exchange depth around the exact destination symbol; the card itself never scales.
        case voiceModeSwitch(direction: CGFloat)
        /// Final Voice is one continuous signal changing state, not a stack of unrelated cards.
        /// The live SF Symbol keeps its authored layers while a short acoustic filament carries
        /// energy from the outgoing stage into the incoming one.
        case voicePipeline(VoicePipelineVisualStage)
        case settleToLayer

        var titleDirection: CGFloat {
            switch self {
            case .layerRebuild(let direction): return direction
            case .returnSweep: return -1
            case .settleToLayer: return -1
            case .voicePipeline: return 1
            case .voiceModeSwitch(let direction): return direction
            default: return 1
            }
        }

        var usesStrictByLayerReplacement: Bool {
            if case .voicePipeline = self { return true }
            return false
        }
    }

    private struct Surface {
        let panel: StatusPanel
        let cardView: NSVisualEffectView
        let cardLayer: CALayer
        let tintLayer: CAGradientLayer
        /// Layer identity is deliberately independent from the action/app palette. The outer aura
        /// lives outside the clipped card; the conic hairline stays above every card state.
        let layerIdentityAura: CAShapeLayer
        let layerIdentityBorder: CAGradientLayer
        let accentLayer: CALayer
        let glowLayer: CALayer
        let holdProgressContainer: CALayer
        let holdProgressWaterRoot: CALayer
        let holdProgressBackWave: CAShapeLayer
        let holdProgressFrontWave: CAShapeLayer
        let holdProgressCrest: CAShapeLayer
        let holdProgressGlassRoot: CALayer
        let holdProgressGlassBloom: CAGradientLayer
        let holdProgressGlassBands: [CAGradientLayer]
        let holdProgressGlassCaustics: [CAShapeLayer]
        let holdProgressRim: CAShapeLayer
        let rippleLayers: [CAShapeLayer]
        let voiceAmbientLayer: CAGradientLayer
        let voiceWaveformLayer: CALayer
        let voiceBaselineLayer: CALayer
        let voiceBarLayers: [CALayer]
        let voiceBarHighlightLayers: [CALayer]
        let voiceHeaderLabel: NSTextField
        let voiceLiveLabel: NSTextField
        let voicePitchLabel: NSTextField
        let voiceBrightnessLabel: NSTextField
        let contentView: NSView
        let normalContentView: NSView
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
    }

    /// Temporary copies of the three ordinary face elements. They preserve the outgoing visual
    /// after the real views have been configured for the destination, allowing icon→icon and
    /// text-line→text-line geometry to share one continuous transition instead of swapping pages.
    private struct NormalContentProxy {
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
        let symbolName: String?

        var views: [NSView] { [iconView, titleLabel, subtitleLabel] }
    }

    private enum DefaultsKey {
        static let displayID = "statusWidget.displayID"
        static let normalizedX = "statusWidget.normalizedX"
        static let normalizedY = "statusWidget.normalizedY"
    }

    private let windowSize = NSSize(width: 244, height: 112)
    private let cardFrame = NSRect(x: 20, y: 20, width: 204, height: 72)
    private let cornerRadius: CGFloat = 20
    private let defaults: UserDefaults
    private let surface: Surface

    private var configuredLayers: [String: Config.LayerDefinition] = [:]
    private var configuredOrdinals: [String: Int] = [:]
    private var configuredIcons: [String: String] = [:]
    private var currentLayerID = "BASE"
    private var currentPresentationKey: String?
    private var currentSymbolName: String?
    private var currentSymbolCue: SymbolCue?
    private var currentControlState: ControlVisualState?
    private var currentFaceTint = NSColor.controlAccentColor
    private var isTransient = false
    private var enabled = false
    private var idleGeneration = 0
    private var visibilityGeneration = 0
    private var moveGeneration = 0
    private var holdGeneration = 0
    private var isMovingProgrammatically = false
    private var isHolding = false
    /// Whether a Siri Remote is currently connected. Starts `false`: at launch no HID interface is
    /// confirmed yet, so the widget rests on the "not connected" face and plays the connect
    /// animation the moment the detector reports the remote (including an already-paired remote,
    /// which enumerates ~0.5 s after launch). Edge-deduplicated because the remote publishes several
    /// HID interfaces and the detector callback fires once per interface.
    private var isConnected = false
    private var holdBase: HoldItem?
    private var holdStages: [TimedHoldItem] = []
    private var holdStageDelays: [TimeInterval] = []
    private var holdVisualWorkItems: [DispatchWorkItem] = []
    private var activeHoldKey: String?
    private var holdVisualIsVisible = false
    /// The compact hold surface uses the same visual lead-in chosen for the large HUD. This is
    /// presentation only; `RemoteInputHandler` remains the sole tap/hold authority.
    private let holdProgressAppearDelay: TimeInterval = 0.18
    private let holdProgressVisualStyle: HoldProgressVisualStyle = .water
    private var holdProgressTimer: Timer?
    private var holdProgressStartedAt: CFTimeInterval = 0
    private var holdProgressLastTick: CFTimeInterval = 0
    private var holdProgressStage = -1
    private var holdProgressLevel: CGFloat = 0
    private var holdProgressDrainStartedAt: CFTimeInterval?
    private var holdProgressDrainFrom: CGFloat = 0
    private var holdProgressDrainDuration: TimeInterval {
        holdProgressVisualStyle == .water ? 0.12 : 0.16
    }
    private var isHoldProgressActive = false
    private var isVoiceWaveformActive = false
    private var voiceSelectionEditingContext: (characterCount: Int, applicationName: String)?
    private var voiceHistory = [VoiceVisualSample](repeating: .silence, count: 25)
    private var voicePitchBaselineLog2: CGFloat?
    private var voiceSmoothedPitchLog2: CGFloat?
    private var voicePitchPosition: CGFloat = 0
    private var voicePitchConfidence: CGFloat = 0
    private var voiceBrightness: CGFloat = 0
    private var voiceLevelNormalizer = VoiceWaveformLevelNormalizer()
    private var voiceMeterSuppressedUntil: CFTimeInterval = 0
    private var voiceLastVoicedAt: CFTimeInterval = 0
    private var voiceNeutralTint = NSColor.systemBlue
    private var voiceStartedAt: CFTimeInterval = 0
    private var voiceLastReadoutTick = -1
    /// Key-up and the coordinator's first post-capture phase are synchronous but separate
    /// callbacks. Keep the final acoustic silhouette alive across that boundary so it can become
    /// the Transcribing symbol directly instead of flashing the Layer face between them.
    private var awaitingNativeVoicePhase = false
    private var nativeVoiceHandoffGeneration = 0
    private var voicePipelineAccentRoot: CALayer?
    private var contentMorphGeneration = 0
    private var contentMorphProxyViews: [NSView] = []
    private var contentMorphTransientLayers: [CALayer] = []
    /// Invalidates delayed CoreAudio samples when another physical action arrives. A mute press can
    /// happen while the previous 280 ms icon transition is still landing; without this generation,
    /// that stale result could draw the wrong slash after a very fast second press.
    private var controlStateRefreshGeneration = 0
    private var pendingControlRefresh: (generation: Int, state: ControlVisualState)?
    private var releasedHold: (key: String, time: CFTimeInterval)?
    private var observerTokens: [NSObjectProtocol] = []
    /// A launch binding announces the destination before AppWatcher observes activation. Remember
    /// that app for a moment so the confirmed activation updates the subtitle instead of producing
    /// a second, visually noisy bounce of the same icon.
    private var pendingActivation: (name: String, time: CFTimeInterval)?
    private var lastEvent: (key: String, time: CFTimeInterval)?
    /// Rate-driven controls own one stable presentation for the complete burst. Their input can
    /// arrive faster than a 220 ms animation, so subsequent ticks extend the dwell (or atomically
    /// update direction) instead of replaying the entrance/effect from frame zero.
    private var activeContinuousFamily: String?

    init(layers: [Config.LayerDefinition], icons: [String: String] = [:], enabled: Bool,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.surface = Self.makeSurface(windowSize: windowSize, cardFrame: cardFrame,
                                        cornerRadius: cornerRadius)
        super.init()
        surface.panel.delegate = self
        (surface.cardView as? AdaptiveMaterialView)?.appearanceDidChange = { [weak self] in
            self?.materialAppearanceChanged()
        }
        configureHoldProgressVisualStyle()
        configuredIcons = icons
        normalize(layers)
        applyLayerIdentity(animated: false)

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.screenParametersChanged() })
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.activeSpaceChanged() })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Loc.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.relocalize() })

        setEnabled(enabled)
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Public state

    func configure(layers: [Config.LayerDefinition], icons: [String: String] = [:],
                   enabled: Bool) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.configuredIcons = icons
            self.normalize(layers)
            self.applyLayerIdentity(animated: self.enabled)
            self.setEnabledOnMain(enabled)
            if self.enabled, !self.isTransient, !self.isHolding {
                self.present(self.idleFace(), animated: false, returningToIdle: false)
            }
        }
    }

    func setEnabled(_ wanted: Bool) {
        onMain { [weak self] in self?.setEnabledOnMain(wanted) }
    }

    /// Re-render the resting face in the newly-selected language. Transient/hold faces relocalize
    /// on their next event, so only the idle face needs an explicit refresh here.
    private func relocalize() {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isConnected,
                  !self.isHolding, !self.isTransient else { return }
            self.present(self.idleFace(), animated: false, returningToIdle: false)
        }
    }

    /// `nil` is the base layer. A layer switch is itself a visible state transition and becomes the
    /// new resting face immediately; a stale action timer can never snap it back to the old layer.
    func setLayer(_ layer: String?, animated: Bool = true) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.activeContinuousFamily = nil
            let previousLayerID = self.currentLayerID
            let destinationLayerID = layer?.uppercased() ?? "BASE"
            self.currentLayerID = destinationLayerID
            self.applyLayerIdentity(
                animated: animated && self.enabled && previousLayerID != destinationLayerID
            )
            self.idleGeneration += 1
            guard !self.isHolding else { return }
            self.isTransient = false
            guard self.enabled else { return }
            if self.completeNativeVoiceHandoff(to: self.idleFace(), pipelineStage: nil) {
                return
            }
            let iconMotion: IconMotion = animated && previousLayerID != destinationLayerID
                ? .layerRebuild(direction: self.layerTransitionDirection(
                    from: previousLayerID, to: destinationLayerID
                ))
                : .ordinary
            self.present(self.idleFace(), animated: animated, returningToIdle: false,
                         iconMotion: iconMotion)
        }
    }

    /// Hardware Voice-mode feedback. This is a transient semantic state of the always-on surface,
    /// never a Layer change, so its return target remains whichever Layer is currently active.
    func showVoiceModeSwitch(_ mode: Config.DictationMode) {
        onMain { [weak self] in
            guard let self, self.enabled, self.isConnected, !self.isHolding else { return }
            self.idleGeneration += 1
            self.activeContinuousFamily = nil
            self.pendingActivation = nil
            let icon = self.configuredIcon("voice.mode.\(mode.rawValue)",
                                           fallback: mode.presentationSymbol)
            let face = Face(key: "voice-mode:\(mode.rawValue)",
                            title: mode.presentationTitle,
                            subtitle: mode.presentationDetail,
                            image: nil,
                            symbolName: icon,
                            symbolCue: mode.presentationCue,
                            tint: mode.presentationTint,
                            controlState: nil)
            self.presentTransient(face, duration: 0.78, animate: true,
                                  iconMotion: .voiceModeSwitch(direction: 1),
                                  playSymbolCue: false)
        }
    }

    /// Reflect the physical connection state. A connect edge plays a brief, celebratory animation
    /// and then settles onto the current layer; a disconnect edge rests on the "not connected" face.
    /// Edge-deduplicated, so the several per-interface callbacks of one physical connect animate once.
    func setConnected(_ connected: Bool, animated: Bool = true) {
        onMain { [weak self] in
            guard let self = self, connected != self.isConnected else { return }
            self.isConnected = connected

            // A connection edge supersedes any transient/hold presentation in flight.
            self.pendingActivation = nil
            self.releasedHold = nil
            self.lastEvent = nil
            self.activeContinuousFamily = nil
            self.idleGeneration += 1
            self.awaitingNativeVoicePhase = false
            self.nativeVoiceHandoffGeneration += 1
            self.voicePipelineAccentRoot?.removeFromSuperlayer()
            self.voicePipelineAccentRoot = nil
            if self.isHolding {
                self.isHolding = false
                self.holdGeneration += 1
                self.holdBase = nil
                self.holdStages = []
                self.holdStageDelays = []
                self.activeHoldKey = nil
                self.holdVisualIsVisible = false
                self.cancelHoldVisualWork()
                self.stopHoldProgress(immediate: true)
                self.setVoiceWaveformActive(false, immediate: true)
                self.stopHoldRipple(immediate: true)
            } else if self.isVoiceWaveformActive {
                // A disconnect can arrive in the tiny key-up → phase hand-off interval.
                self.setVoiceWaveformActive(false, immediate: true)
            }
            self.isTransient = false
            guard self.enabled else { return }

            // Visible only while a remote is connected: appear with an entrance, leave with an exit.
            if connected {
                self.showPanel(entranceAnimated: animated)
            } else {
                self.hidePanel(animated: animated)
            }
        }
    }

    func showApplication(bundleID: String, duration: TimeInterval = 0.90) {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isConnected, !self.isHolding else { return }
            self.activeContinuousFamily = nil
            let info = self.applicationInfo(bundleID: bundleID)
            let now = CACurrentMediaTime()
            let confirmsPendingLaunch: Bool
            if let pending = self.pendingActivation,
               now - pending.time < 2.5,
               self.normalizedAppName(pending.name) == self.normalizedAppName(info.name) {
                confirmsPendingLaunch = true
            } else {
                confirmsPendingLaunch = false
            }
            self.pendingActivation = nil

            let face = Face(key: "app:\(bundleID)", title: info.name, subtitle: L("Active App"),
                            image: info.icon, symbolName: nil, symbolCue: nil,
                            tint: self.tint(forBundleID: bundleID), controlState: nil)
            self.presentTransient(face, duration: duration, animate: !confirmsPendingLaunch,
                                  iconMotion: .applicationArrival,
                                  accentSweep: true)
        }
    }

    func showAction(_ handled: Controller.HandledAction,
                    durationOverride: TimeInterval? = nil,
                    controlStateOverride: ControlVisualState? = nil) {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isConnected, !self.isHolding else { return }
            // Layer actions already produce `setLayer` with the actual destination name/colour.
            // Showing their implementation label ("Next Layer") first is redundant and noisy.
            switch handled.action {
            case .layer, .layerCycle: return
            default: break
            }
            self.controlStateRefreshGeneration += 1
            self.pendingControlRefresh = nil
            let now = CACurrentMediaTime()
            let duration = durationOverride
                ?? self.duration(for: handled.key, action: handled.action)
            // A release-to-select action is reported immediately after `endHold`. Its face is
            // already on screen and has been visible for the whole hold, so only extend the dwell;
            // bouncing it again on key-up makes a frequent interaction feel nervous.
            if let released = self.releasedHold,
               released.key == handled.key, now - released.time < 0.30 {
                self.releasedHold = nil
                self.lastEvent = (handled.key, now)
                self.scheduleIdle(after: 0.48)
                if let presentationKey = self.currentPresentationKey {
                    self.scheduleControlStateRefresh(
                        for: handled, expectedPresentationKey: presentationKey,
                        duration: 0.48, disabled: controlStateOverride != nil
                    )
                }
                return
            }
            self.releasedHold = nil
            let continuousFamily = self.continuousFeedbackFamily(for: handled.action)
            // One physical mute edge is one visual transaction. `Controller` calls this immediately
            // before executing the action, so invert the measured state for the first frame. The
            // scheduled CoreAudio read below only confirms it; on success it is a no-op, while an
            // execution failure can still correct the face without leaving the UI dishonest.
            let visualStateOverride = controlStateOverride
                ?? SystemControlState.predictedMuteResult(for: handled.action)
            let face = self.actionFace(key: handled.key, action: handled.action,
                                       presentation: handled.presentation,
                                       subtitle: self.gestureLabel(for: handled.key),
                                       controlStateOverride: visualStateOverride)

            if let continuousFamily,
               self.isTransient,
               self.activeContinuousFamily == continuousFamily {
                // One volume/brightness/scroll burst is one visual state. An unchanged direction
                // needs no redraw at all; a direction change updates atomically without inserting
                // another 3D turn or restarting an SF Symbol effect.
                self.lastEvent = (handled.key, now)
                if self.currentPresentationKey == face.key,
                   self.currentControlState == face.controlState {
                    self.scheduleIdle(after: duration)
                } else {
                    self.presentTransient(face, duration: duration, animate: false,
                                          playSymbolCue: false)
                }
                self.scheduleControlStateRefresh(
                    for: handled, expectedPresentationKey: face.key,
                    duration: duration, disabled: controlStateOverride != nil
                )
                return
            }
            self.activeContinuousFamily = continuousFamily
            // Keep a held media/repeat action from re-springing the card on every timer tick. A
            // multi-tap gesture resolves to its own `.double`/`.triple` key and still animates; two
            // very fast identical base events share one visible pulse but extend its dwell.
            if let previous = self.lastEvent,
               previous.key == handled.key, now - previous.time < 0.22 {
                self.lastEvent = (handled.key, now)
                self.scheduleIdle(after: duration)
                self.scheduleControlStateRefresh(
                    for: handled, expectedPresentationKey: face.key,
                    duration: duration, disabled: controlStateOverride != nil
                )
                return
            }
            self.lastEvent = (handled.key, now)

            let launched = self.launchedAppName(handled.action)
            if let launched = launched {
                self.pendingActivation = (launched, now)
            } else {
                self.pendingActivation = nil
            }
            let iconMotion: IconMotion
            if launched != nil {
                // Opening an app is an arrival, not another button impact. Real app artwork gets
                // the same spatial aperture grammar as foreground-app recognition.
                iconMotion = .applicationArrival
            } else if self.isAppWheelAction(handled.action) {
                iconMotion = .appWheelWave
            } else if self.isBackButtonKey(handled.key) {
                iconMotion = .returnSweep
            } else {
                iconMotion = .actionImpulse(count: self.tapImpulseCount(for: handled.key))
            }
            self.presentTransient(face,
                                  duration: duration,
                                  animate: true,
                                  iconMotion: iconMotion,
                                  // A sweep is punctuation, not wallpaper. Reserve it for the
                                  // high-level event of opening an app; frequent commands keep the
                                  // quieter symbol/text choreography.
                                  accentSweep: launched != nil,
                                  playSymbolCue: continuousFamily == nil)
            self.scheduleControlStateRefresh(
                for: handled, expectedPresentationKey: face.key,
                duration: duration, disabled: controlStateOverride != nil
            )
        }
    }

    /// Pin the compact widget to the release-to-select action for the entire physical hold. The
    /// stage schedule shares `startedAt` and thresholds with RemoteInputHandler, so this view cannot
    /// lag behind the action the release path will actually choose.
    func beginHold(
        startedAt: CFTimeInterval,
        base: (key: String, action: Action, presentation: Config.Presentation?)?,
        stages: [(threshold: TimeInterval, key: String, action: Action,
                  presentation: Config.Presentation?, isCancel: Bool)]
    ) {
        onMain { [weak self] in
            guard let self = self, self.enabled else { return }
            self.holdGeneration += 1
            let generation = self.holdGeneration
            self.cancelHoldVisualWork()
            self.stopHoldProgress(immediate: true)
            self.stopHoldRipple(immediate: true)
            self.idleGeneration += 1
            self.isHolding = true
            self.isTransient = true
            self.holdVisualIsVisible = false
            self.releasedHold = nil
            self.pendingActivation = nil
            self.activeContinuousFamily = nil
            self.holdBase = base.map {
                HoldItem(key: $0.key, action: $0.action,
                         presentation: $0.presentation, isCancel: false)
            }
            self.holdStages = stages.map {
                TimedHoldItem(threshold: $0.threshold,
                              item: HoldItem(key: $0.key, action: $0.action,
                                             presentation: $0.presentation,
                                             isCancel: $0.isCancel))
            }
            self.holdStageDelays = self.holdStages.map(\.threshold)

            // Match the large HUD's deliberate 0.18 s visual lead-in. This preview does not
            // claim the gesture: the base action is still what release selects until the first
            // real threshold. Showing it early leaves enough visible runway for the selected
            // whole-card treatment instead of making progress appear at the first boundary.
            let now = CACurrentMediaTime()
            if !self.holdStages.isEmpty {
                // One work item only starts the visual clock. Stage faces are deliberately NOT
                // scheduled as independent callbacks: the same per-frame elapsed sample below now
                // chooses the face and water state atomically. If a configured threshold precedes
                // 180 ms, reveal at that real boundary rather than trailing the input state.
                let firstVisualDelay = min(self.holdProgressAppearDelay,
                                           self.holdStages[0].threshold)
                let delay = max(0, startedAt + firstVisualDelay - now)
                let previewWork = DispatchWorkItem { [weak self] in
                    guard let self = self, self.enabled, self.isHolding,
                          self.holdGeneration == generation else { return }
                    self.holdVisualIsVisible = true
                    self.startHoldRipple()
                    self.startHoldProgress(startedAt: startedAt)
                }
                self.holdVisualWorkItems.append(previewWork)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: previewWork)
            }
        }
    }

    /// End the pinned hold only on the physical release edge. Keep the selected face for a brief,
    /// quiet confirmation, then return to the current layer unless a newer event supersedes it.
    func endHold(firedIndex: Int) {
        onMain { [weak self] in
            guard let self = self, self.isHolding else { return }
            let selected: HoldItem?
            if firedIndex == 0 {
                selected = self.holdBase
            } else if self.holdStages.indices.contains(firedIndex - 1) {
                selected = self.holdStages[firedIndex - 1].item
            } else {
                selected = nil
            }

            let selectedIsLayer = selected.map { self.isLayerStateAction($0.action) } ?? false
            let selectedIsCancel = selected?.isCancel == true
            let hadVisibleHold = self.holdVisualIsVisible
            self.isHolding = false
            self.holdVisualIsVisible = false
            self.holdGeneration += 1
            self.cancelHoldVisualWork()
            self.stopHoldRipple(immediate: selectedIsCancel)
            self.stopHoldProgress(immediate: selectedIsCancel)
            self.setVoiceWaveformActive(false)
            if selectedIsLayer || selectedIsCancel {
                // A quick layer-cycle tap used to pass through `presentHold` here and briefly show
                // “Next Layer” even though showAction correctly suppressed it later. Return straight
                // to the already-updated destination Layer instead. The deepest hold's cancel face
                // follows the same rule: release is the interaction boundary, so it must reveal the
                // Layer immediately rather than dwelling on a redundant “Cancelled” confirmation.
                self.isTransient = false
                let destination = self.idleFace()
                self.present(destination,
                             animated: self.currentPresentationKey != destination.key,
                             returningToIdle: true)
            } else if let selected = selected {
                self.presentHold(selected,
                                 subtitle: selected.isCancel
                                     ? L("Cancelled")
                                     : (!hadVisibleHold && firedIndex == 0
                                         ? self.gestureLabel(for: selected.key)
                                         : L("Completed")),
                                 animated: self.activeHoldKey != selected.key)
                self.releasedHold = (selected.key, CACurrentMediaTime())
            }
            self.holdBase = nil
            self.holdStages = []
            self.holdStageDelays = []
            self.activeHoldKey = nil
            if selectedIsLayer || selectedIsCancel { return }
            self.scheduleIdle(after: 0.48)
        }
    }

    func beginContinuousAction(_ handled: Controller.HandledAction) {
        beginHold(startedAt: CACurrentMediaTime(),
                  base: (key: handled.key, action: handled.action,
                         presentation: handled.presentation),
                  stages: [])
        guard case .pushToTalk = handled.action else { return }
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isHolding,
                  self.holdBase?.key == handled.key else { return }
            self.awaitingNativeVoicePhase = false
            self.nativeVoiceHandoffGeneration += 1
            self.voicePipelineAccentRoot?.removeFromSuperlayer()
            self.voicePipelineAccentRoot = nil
            // Voice is driven by real microphone power. Do not layer the decorative looping
            // hold rings underneath it; silence should visibly settle to a flat waveform.
            self.stopHoldRipple(immediate: true)
            self.stopHoldProgress(immediate: true)
            if let voice = self.holdBase {
                self.holdVisualIsVisible = true
                // Preserve the real outgoing Layer/action while it slides away. Installing a
                // temporary "Voice Input" face before the console made a two-frame intermediary
                // flash; Voice now takes ownership directly and the completion face is prepared
                // only when the physical key is released.
                let face = self.actionFace(key: voice.key, action: voice.action,
                                           presentation: voice.presentation,
                                           subtitle: L("Listening · speak now"))
                self.activeHoldKey = voice.key
                self.currentPresentationKey = face.key
                self.applyColors(face.tint, animated: true)
            }
            self.setVoiceWaveformActive(true)
        }
    }

    /// Re-label the existing real-audio console as an edit instruction without navigating to a new
    /// card. The waveform remains continuous, while the small typographic readouts flip in 0.2 s.
    func showSelectionEditing(characterCount: Int, applicationName: String) {
        onMain { [weak self] in
            guard let self, self.enabled, self.isVoiceWaveformActive else { return }
            self.voiceSelectionEditingContext = (max(0, characterCount), applicationName)
            self.animateVoiceReadoutChange(self.surface.voiceHeaderLabel, to: "EDIT")
            self.animateVoiceReadoutChange(
                self.surface.voiceBrightnessLabel,
                to: "\(max(0, characterCount)) CHARS"
            )
            self.updateVoiceReadouts(with: self.voiceHistory.last ?? .silence, force: true)
        }
    }

    func endContinuousAction(key: String) {
        endContinuousAction(key: key, awaitsNativePhase: false)
    }

    /// Native Voice has an immediate coordinator phase after key-up; the legacy Layer 1 external
    /// push-to-talk path does not. Keeping these boundaries explicit prevents the old path from
    /// inheriting even the defensive 120 ms native hand-off window.
    func endNativeContinuousAction(key: String) {
        endContinuousAction(key: key, awaitsNativePhase: true)
    }

    private func endContinuousAction(key: String, awaitsNativePhase: Bool) {
        onMain { [weak self] in
            guard let self = self, self.isHolding else { return }
            // Only close the session that opened this key; a stale release from another mirrored
            // HID interface must not dismiss a newer continuous action.
            guard self.holdBase?.key == key else { return }
            if let base = self.holdBase, case .pushToTalk = base.action {
                self.endVoiceHold(awaitsNativePhase: awaitsNativePhase)
                return
            }
            self.endHold(firedIndex: 0)
        }
    }

    /// Voice is a mode of the same compact surface, not a navigated page. Key-up and the first
    /// post-capture coordinator phase are two callbacks on the same run-loop turn. Preserve the
    /// final real waveform between them: Final can turn it directly into Transcribing, while
    /// Streaming turns it directly back into its Layer. There is never a Layer flash in between.
    private func endVoiceHold(awaitsNativePhase: Bool) {
        isHolding = false
        holdVisualIsVisible = false
        holdGeneration += 1
        idleGeneration += 1
        cancelHoldVisualWork()
        stopHoldRipple()
        stopHoldProgress()
        awaitingNativeVoicePhase = true
        nativeVoiceHandoffGeneration += 1
        let handoffGeneration = nativeVoiceHandoffGeneration
        isTransient = true
        releasedHold = nil
        holdBase = nil
        holdStages = []
        holdStageDelays = []
        activeHoldKey = nil

        if !awaitsNativePhase {
            _ = completeNativeVoiceHandoff(to: idleFace(), pipelineStage: nil)
            return
        }

        // The coordinator normally answers synchronously. This defensive edge handles shutdown,
        // cancellation, or a future caller that omits its phase callback without leaving a frozen
        // waveform on screen. It does not add latency to the normal Final/Streaming paths.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.awaitingNativeVoicePhase,
                  self.nativeVoiceHandoffGeneration == handoffGeneration else { return }
            _ = self.completeNativeVoiceHandoff(to: self.idleFace(), pipelineStage: nil)
        }
    }

    /// Configure the hidden destination first, then let the existing 25 acoustic bars physically
    /// converge into that exact icon and let the Voice readouts fold into its labels. This is the
    /// only legal exit from a native Voice hold, which keeps both output modes frame-synchronous.
    @discardableResult
    private func completeNativeVoiceHandoff(to face: Face,
                                            pipelineStage: VoicePipelineVisualStage?) -> Bool {
        guard awaitingNativeVoicePhase else { return false }
        awaitingNativeVoicePhase = false
        nativeVoiceHandoffGeneration += 1
        configure(face: face, applyPalette: false)
        applyColors(face.tint, animated: true)
        currentPresentationKey = face.key
        isTransient = pipelineStage != nil
        setVoiceWaveformActive(false)
        if let pipelineStage {
            animateVoicePipelineIgnition(pipelineStage, expectedKey: face.key,
                                         cue: face.symbolCue)
        }
        return true
    }

    /// Native transcription keeps using the same physical card after the microphone edge ends.
    /// Work phases stay visible until superseded; terminal phases dwell briefly, then settle back
    /// to the Layer. No second panel and no page-navigation animation are introduced.
    func showNativeDictationPhase(_ phase: VoiceDictationPhase, message: String) {
        onMain { [weak self] in
            guard let self, self.enabled, self.isConnected, !self.isHolding else { return }
            switch phase {
            case .priming, .listening:
                return
            case .idle:
                if self.completeNativeVoiceHandoff(to: self.idleFace(), pipelineStage: nil) {
                    return
                }
                guard self.currentPresentationKey?.hasPrefix("native-dictation:") == true else {
                    return
                }
                self.idleGeneration += 1
                self.isTransient = false
                self.present(self.idleFace(), animated: true, returningToIdle: true,
                             iconMotion: .settleToLayer)
                return
            case .transcribing, .polishing, .rewriting, .inserting, .inserted, .replaced,
                 .copied, .error:
                break
            }
            guard let stage = VoicePipelineVisualStage(phase) else { return }
            let icon = self.configuredIcon(stage.configIconKey,
                                           fallback: stage.fallbackSymbol)
            let face = Face(key: "native-dictation:\(phase.rawValue)",
                            title: stage.title,
                            subtitle: message,
                            image: nil,
                            symbolName: icon,
                            symbolCue: stage.symbolCue,
                            tint: stage.tint,
                            controlState: nil)
            self.idleGeneration += 1
            self.isTransient = true
            if !self.completeNativeVoiceHandoff(to: face, pipelineStage: stage) {
                self.present(face, animated: true, returningToIdle: false,
                             iconMotion: .voicePipeline(stage))
            }
            if stage.isTerminal {
                self.scheduleIdle(after: phase == .error ? 2.2 : 1.0)
            }
        }
    }

    /// Real acoustic samples from BuiltinMicFeeder. Every bar retains its own loudness, relative
    /// pitch colour, voicing confidence, and spectral brightness, creating a short sound signature
    /// rather than a decorative time-based animation.
    func updateVoiceMeter(_ sample: VoiceMeterSample) {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isVoiceWaveformActive else { return }
            guard CACurrentMediaTime() >= self.voiceMeterSuppressedUntil else { return }
            self.voiceHistory.removeFirst()
            self.voiceHistory.append(self.voiceVisualSample(from: sample))
            self.renderVoiceBars(animated: true)
        }
    }

    /// Keep HyperVibe's own start cue out of the real-audio visualization. Resetting the adaptive
    /// reference here also prevents that short chirp from compressing the user's next few words.
    func suppressVoiceMeter(for duration: TimeInterval) {
        onMain { [weak self] in
            guard let self, duration.isFinite, duration > 0 else { return }
            self.voiceMeterSuppressedUntil = CACurrentMediaTime() + min(1, duration)
            self.voiceLevelNormalizer.reset()
            self.voiceHistory = [VoiceVisualSample](repeating: .silence,
                                                    count: self.surface.voiceBarLayers.count)
            if self.isVoiceWaveformActive { self.renderVoiceBars(animated: false) }
        }
    }

    private func voiceVisualSample(from sample: VoiceMeterSample) -> VoiceVisualSample {
        let level = voiceLevelNormalizer.normalize(sample.level)
        let rawBrightness = CGFloat(min(1, max(0,
            sample.brightness.isFinite ? sample.brightness : 0)))
        // A silent fricative/noise estimate must not leave a glowing cap behind. Preserve the
        // brightness dimension only while enough real acoustic energy is visible.
        let brightnessTarget = rawBrightness * min(1, level * 4)
        let brightnessResponse: CGFloat = brightnessTarget > voiceBrightness ? 0.24 : 0.11
        voiceBrightness += (brightnessTarget - voiceBrightness) * brightnessResponse

        let now = CACurrentMediaTime()
        let confidence = CGFloat(min(1, max(0,
            sample.pitchConfidence.isFinite ? sample.pitchConfidence : 0)))
        let hasVoicedPitch = sample.pitchHz.isFinite && sample.pitchHz >= 75 &&
            sample.pitchHz <= 400 && confidence >= 0.58 && level >= 0.025

        if hasVoicedPitch {
            var logPitch = CGFloat(log2(Double(sample.pitchHz)))
            if let previous = voiceSmoothedPitchLog2 {
                // Resolve the occasional octave ambiguity to the nearest plausible continuation.
                // Real speech rarely jumps a complete octave inside one 33 ms display frame.
                while logPitch - previous > 0.5 { logPitch -= 1 }
                while logPitch - previous < -0.5 { logPitch += 1 }
                let delta = min(0.20, max(-0.20, logPitch - previous))
                voiceSmoothedPitchLog2 = previous + delta * 0.34
            } else {
                voiceSmoothedPitchLog2 = logPitch
            }

            if voicePitchBaselineLog2 == nil { voicePitchBaselineLog2 = logPitch }
            if let smoothed = voiceSmoothedPitchLog2,
               let baseline = voicePitchBaselineLog2 {
                // About a five-second adaptation time keeps the palette personal to the speaker
                // while short rises/falls remain visible as intonation instead of moving the zero.
                let baselineDelta = min(0.25, max(-0.25, smoothed - baseline))
                voicePitchBaselineLog2 = baseline + baselineDelta * 0.006
                let semitones = (smoothed - (voicePitchBaselineLog2 ?? baseline)) * 12
                voicePitchPosition = min(1, max(-1, semitones / 5))
            }
            voicePitchConfidence = min(1, max(0, (confidence - 0.52) / 0.48))
            voiceLastVoicedAt = now
        } else {
            let age = max(0, now - voiceLastVoicedAt)
            if voiceLastVoicedAt > 0, age < 0.14 {
                // Hold colour through short consonants so a word remains one coherent gesture.
                voicePitchConfidence *= CGFloat(1 - age / 0.20)
            } else {
                voicePitchPosition += (0 - voicePitchPosition) * 0.08
                voicePitchConfidence *= 0.76
            }
        }

        return VoiceVisualSample(level: level,
                                 pitchPosition: voicePitchPosition,
                                 pitchConfidence: min(1, max(0, voicePitchConfidence)),
                                 brightness: min(1, max(0, voiceBrightness)))
    }

    // MARK: - Enable / transient lifecycle

    private func setEnabledOnMain(_ wanted: Bool) {
        guard wanted != enabled else {
            if wanted && isConnected {
                ensureReachable()
                surface.panel.orderFrontRegardless()
            }
            return
        }
        enabled = wanted
        if wanted {
            // The feature is on, but the surface only appears while a remote is actually connected.
            if isConnected { showPanel(entranceAnimated: true) }
        } else {
            hidePanel(animated: true)
        }
    }

    /// Bring the widget on screen and land on the current layer. Only called while `enabled &&
    /// isConnected`, so the entrance doubles as the connect animation.
    private func showPanel(entranceAnimated: Bool) {
        visibilityGeneration += 1
        idleGeneration += 1
        restorePosition()
        let displayID = bestScreen(for: surface.panel.frame)?.hudDisplayID ?? 0
        print("🧭 status widget shown — display \(displayID), frame \(NSStringFromRect(surface.panel.frame))")
        isTransient = false
        activeContinuousFamily = nil
        currentPresentationKey = nil
        configure(face: idleFace())
        surface.panel.orderFrontRegardless()
        guard entranceAnimated else {
            surface.panel.alphaValue = 1
            return
        }
        surface.panel.alphaValue = 0
        animateWidgetAppear()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.surface.panel.animator().alphaValue = 1
        }
    }

    /// Take the widget off screen with a precise exit, and reset any transient/hold state so the
    /// next entrance starts clean.
    private func hidePanel(animated: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        idleGeneration += 1
        pendingActivation = nil
        activeContinuousFamily = nil
        awaitingNativeVoicePhase = false
        nativeVoiceHandoffGeneration += 1
        voicePipelineAccentRoot?.removeFromSuperlayer()
        voicePipelineAccentRoot = nil
        isHolding = false
        holdGeneration += 1
        holdBase = nil
        holdStages = []
        holdStageDelays = []
        activeHoldKey = nil
        holdVisualIsVisible = false
        cancelHoldVisualWork()
        stopHoldProgress(immediate: true)
        setVoiceWaveformActive(false, immediate: true)
        stopHoldRipple(immediate: true)

        guard animated else {
            surface.panel.alphaValue = 0
            surface.panel.orderOut(nil)
            return
        }
        animateWidgetDisappear()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.surface.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.visibilityGeneration == generation,
                  !(self.enabled && self.isConnected) else { return }
            self.surface.panel.orderOut(nil)
        })
    }

    /// The component's physical frame never scales: its persistent Layer edge must stay perfectly
    /// registered with the material card. Entrance personality therefore belongs only to the icon
    /// and internal ripples while the whole panel performs its ordinary alpha fade.
    private func animateWidgetAppear() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if #available(macOS 14.0, *), currentSymbolName != nil {
            let options = SymbolEffectOptions.speed(2.65)
            surface.iconView.addSymbolEffect(.appear.up.byLayer, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                self?.surface.iconView.removeSymbolEffect(ofType: .appear,
                                                          options: options, animated: false)
            }
        }

        let iconPop = CAKeyframeAnimation(keyPath: "transform")
        iconPop.values = [
            NSValue(caTransform3D: spatialTransform(z: -16, scale: 0.76,
                                                    rotateX: -0.72, rotateY: 0.22,
                                                    perspective: 300)),
            NSValue(caTransform3D: spatialTransform(z: 6, scale: 1.04,
                                                    rotateX: 0.06, rotateY: -0.02,
                                                    perspective: 300)),
            NSValue(caTransform3D: spatialTransform(perspective: 300)),
        ]
        iconPop.keyTimes = [0.0, 0.72, 1.0]
        iconPop.duration = 0.28
        iconPop.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.20, 1.0)
        surface.iconView.layer?.add(iconPop, forKey: "widgetAppearIcon")

        for (index, ripple) in surface.rippleLayers.enumerated() {
            ripple.removeAnimation(forKey: "holdRipple")
            let rScale = CAKeyframeAnimation(keyPath: "transform.scale")
            rScale.values = [0.96, 1.08]
            rScale.keyTimes = [0.0, 1.0]
            let rOpacity = CAKeyframeAnimation(keyPath: "opacity")
            rOpacity.values = [0.0, 0.22, 0.0]
            rOpacity.keyTimes = [0.0, 0.24, 1.0]
            let rGroup = CAAnimationGroup()
            rGroup.animations = [rScale, rOpacity]
            let offset = Double(index) * 0.024
            rGroup.duration = 0.28 - offset
            rGroup.beginTime = ripple.convertTime(CACurrentMediaTime(), from: nil)
                + offset
            rGroup.fillMode = .backwards
            rGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(rGroup, forKey: "widgetAppearRing")
        }
    }

    /// Disconnect is the inverse relationship, not a reversed celebration: the semantic content
    /// resolves inward while the panel performs its independent 240 ms fade. The card itself never
    /// scales, so its location remains a stable frame of reference until it is gone.
    private func animateWidgetDisappear() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if #available(macOS 14.0, *), currentSymbolName != nil {
            let options = SymbolEffectOptions.speed(2.8)
            surface.iconView.addSymbolEffect(.disappear.down.byLayer, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                self?.surface.iconView.removeSymbolEffect(ofType: .disappear,
                                                          options: options, animated: false)
            }
        }

        let icon = CAKeyframeAnimation(keyPath: "transform")
        icon.values = [
            NSValue(caTransform3D: spatialTransform(perspective: 300)),
            NSValue(caTransform3D: spatialTransform(z: 3, scale: 0.97,
                                                    rotateX: -0.08,
                                                    perspective: 300)),
            NSValue(caTransform3D: spatialTransform(z: -18, scale: 0.68,
                                                    rotateX: 0.72, rotateY: -0.24,
                                                    perspective: 300)),
        ]
        icon.keyTimes = [0.0, 0.34, 1.0]
        icon.duration = 0.22
        icon.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 0, 1, 1)
        surface.iconView.layer?.add(icon, forKey: "widgetDisappearIcon")

        for (index, label) in [surface.titleLabel, surface.subtitleLabel].enumerated() {
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            drift.fromValue = 0
            drift.toValue = -1.5
            drift.duration = 0.18 + Double(index) * 0.02
            drift.timingFunction = CAMediaTimingFunction(name: .easeIn)
            label.layer?.add(drift, forKey: "widgetDisappearText")
        }
    }

    private func presentTransient(_ face: Face, duration: TimeInterval, animate: Bool,
                                  iconMotion: IconMotion = .ordinary,
                                  accentSweep: Bool = false,
                                  playSymbolCue: Bool = true) {
        isTransient = true
        present(face, animated: animate, returningToIdle: false,
                iconMotion: iconMotion,
                accentSweep: accentSweep,
                playSymbolCue: playSymbolCue)
        scheduleIdle(after: duration)
    }

    private func scheduleIdle(after duration: TimeInterval) {
        idleGeneration += 1
        let generation = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.enabled, self.idleGeneration == generation else { return }
            self.isTransient = false
            self.activeContinuousFamily = nil
            self.present(self.idleFace(), animated: true, returningToIdle: true,
                         iconMotion: .settleToLayer)
        }
    }

    private func present(_ face: Face, animated: Bool, returningToIdle: Bool,
                         iconMotion: IconMotion? = nil, accentSweep: Bool = false,
                         playSymbolCue: Bool = true) {
        // Content updates never surface the panel while it is intentionally hidden (no remote).
        guard enabled, isConnected else { return }
        ensureReachable()
        surface.panel.orderFrontRegardless()
        voicePipelineAccentRoot?.removeFromSuperlayer()
        voicePipelineAccentRoot = nil
        let contentChanges = currentPresentationKey != face.key
        let outgoing = animated && contentChanges ? makeNormalContentProxy() : nil
        applyColors(face.tint, animated: animated && contentChanges)
        configure(face: face)
        currentPresentationKey = face.key
        if animated {
            if contentChanges {
                animateContentTransition(from: outgoing,
                                         iconMotion: iconMotion
                                             ?? (returningToIdle ? .settleToLayer : .ordinary),
                                         accentSweep: accentSweep,
                                         symbolCue: playSymbolCue ? currentSymbolCue : nil)
            } else {
                if playSymbolCue, #available(macOS 14.0, *), currentSymbolName != nil {
                    applyNativeSymbolCue(currentSymbolCue, to: surface.iconView)
                } else {
                    animateCardResponse()
                }
            }
        }
    }

    private func presentHold(_ item: HoldItem, subtitle: String, animated: Bool) {
        guard !isLayerStateAction(item.action) else { return }
        let face = actionFace(key: item.key, action: item.action,
                              presentation: item.presentation, subtitle: subtitle)
        activeHoldKey = item.key
        present(face, animated: animated, returningToIdle: false,
                iconMotion: isAppWheelAction(item.action) ? .appWheelWave : .holdSequence)
    }

    private func cancelHoldVisualWork() {
        holdVisualWorkItems.forEach { $0.cancel() }
        holdVisualWorkItems.removeAll()
    }

    private func configure(face: Face, applyPalette: Bool = true) {
        currentFaceTint = face.tint
        // A Face may carry only semantic symbol provenance (native dictation phases do), and a
        // user-authored symbol can be unavailable on an older supported macOS. Resolve here at the
        // final presentation boundary and always retain a known system fallback; no transition is
        // allowed to land on an empty 40 pt icon slot.
        let resolvedImage: NSImage?
        let resolvedSymbolName: String?
        if let requested = face.symbolName,
           let image = face.image ?? symbol(requested, size: 26) {
            resolvedImage = image
            resolvedSymbolName = requested
        } else if let image = face.image {
            resolvedImage = image
            resolvedSymbolName = nil
        } else if let fallback = symbol("command.circle.fill", size: 26) {
            resolvedImage = fallback
            resolvedSymbolName = "command.circle.fill"
        } else if let fallback = symbol("command", size: 26) {
            resolvedImage = fallback
            resolvedSymbolName = "command"
        } else {
            resolvedImage = NSImage(size: NSSize(width: 26, height: 26))
            resolvedSymbolName = nil
        }
        currentSymbolName = resolvedSymbolName
        currentSymbolCue = face.symbolCue
        currentControlState = face.controlState
        if #available(macOS 14.0, *) {
            surface.iconView.removeAllSymbolEffects(options: .default, animated: false)
        }
        if let symbolName = resolvedSymbolName, let source = resolvedImage {
            // Hierarchical rendering uses the symbol's authored primary/secondary/tertiary layers
            // and derives accessible depth from one semantic system colour. It falls back to
            // monochrome automatically for a symbol without hierarchy.
            surface.iconView.image = ActionSymbolStyle.hierarchicalImage(
                source, symbolName: symbolName, tint: face.tint, cue: face.symbolCue
            )
            surface.iconView.contentTintColor = nil
        } else {
            surface.iconView.image = resolvedImage
            surface.iconView.contentTintColor = resolvedImage?.isTemplate == true ? face.tint : nil
        }
        surface.titleLabel.stringValue = face.title
        surface.subtitleLabel.stringValue = face.subtitle
        applyHoldContentContrast()
        if applyPalette { applyColors(face.tint, animated: false) }
        currentPresentationKey = face.key
    }

    // MARK: - Faces

    private func actionFace(key: String, action: Action,
                            presentation: Config.Presentation?, subtitle: String,
                            controlStateOverride: ControlVisualState? = nil) -> Face {
        let visual = ActionVisual.resolve(
            action, presentation, prefersTargetAppIcon: false,
            controlStateOverride: controlStateOverride
        )
        // A generic command placed on the physical Back key still reads as Back. An action with
        // stronger semantics wins: Close Window / Quit App must remain destructive and red.
        let cue: SymbolCue = visual.symbolCue == .generic && isBackButtonKey(key)
            ? .back : visual.symbolCue
        return Face(key: "action:\(key):\(visual.label)",
                    title: visual.label,
                    subtitle: subtitle,
                    image: visual.image,
                    symbolName: visual.symbolName,
                    symbolCue: cue,
                    tint: visual.tint,
                    controlState: visual.controlState)
    }

    private func isLayerStateAction(_ action: Action) -> Bool {
        switch action {
        case .layer, .layerCycle: return true
        default: return false
        }
    }

    private func isAppWheelAction(_ action: Action) -> Bool {
        if case .appWheel = action { return true }
        return false
    }

    private func idleFace() -> Face {
        let appearance = layerAppearance(currentLayerID)
        let symbolName = appearance.icon
        return Face(key: "layer:\(currentLayerID)", title: appearance.label,
                    subtitle: L("Current Layer"),
                    image: symbol(symbolName, size: 26),
                    symbolName: symbolName,
                    symbolCue: .layer,
                    tint: appearance.tint,
                    controlState: nil)
    }

    private func applicationInfo(bundleID: String) -> (name: String, icon: NSImage?) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let bundle = url.flatMap(Bundle.init(url:))
        let displayName = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? running?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? "Application"
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path).copy() as? NSImage } ?? nil
        return (displayName, icon)
    }

    private func launchedAppName(_ action: Action) -> String? {
        switch action {
        case .launch(let app, _): return app
        case .shell(let command): return ActionVisual.appName(fromOpenCommand: command)
        default: return nil
        }
    }

    private func normalizedAppName(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".app") { value.removeLast(4) }
        return value.replacingOccurrences(of: " ", with: "")
    }

    private func gestureLabel(for key: String) -> String {
        if key.hasSuffix(".taphold3") { return L("Tap + hold · stage 3") }
        if key.hasSuffix(".taphold2") { return L("Tap + hold · stage 2") }
        if key.hasSuffix(".taphold") { return L("Tap + hold") }
        if key.hasSuffix(".hold3") { return L("Long hold · stage 3") }
        if key.hasSuffix(".hold2") { return L("Long hold · stage 2") }
        if key.hasSuffix(".hold") { return L("Long hold") }
        if key.hasSuffix(".triple") { return L("Triple tap") }
        if key.hasSuffix(".double") { return L("Double tap") }
        if key.hasSuffix(".tap") { return L("Tap") }
        if key == "tap.two" { return L("Two-finger tap") }
        if key.hasPrefix("swipe.") { return L("Swipe") }
        if key.hasPrefix("ring.") { return L("Ring") }
        return L("Action")
    }

    /// Match direct-action feedback to the gesture that caused it. The rings are not decoration:
    /// one, two or three brief impulses make tap count readable before the subtitle is parsed.
    private func tapImpulseCount(for key: String) -> Int {
        if key.hasSuffix(".triple") { return 3 }
        if key.hasSuffix(".double") { return 2 }
        return 1
    }

    private func isBackButtonKey(_ key: String) -> Bool {
        key == "button.menu" || key == "button.menu.tap"
    }

    private func duration(for key: String, action: Action) -> TimeInterval {
        if key.hasSuffix(".taphold3") || key.hasSuffix(".hold3") { return 1.35 }
        if key.hasSuffix(".taphold2") || key.hasSuffix(".hold2") { return 1.20 }
        if key.hasSuffix(".taphold") || key.hasSuffix(".hold") { return 1.05 }
        if key.hasSuffix(".triple") { return 0.92 }
        if key.hasSuffix(".double") { return 0.82 }
        switch action {
        case .launch, .appWheel: return 0.95
        // A quick tap should still read as a deliberate state, not a notification flash. The
        // motion is small, but the face stays put long enough to register before returning home.
        default: return 0.72
        }
    }

    // MARK: - Layer/app/action colour

    private func normalize(_ layers: [Config.LayerDefinition]) {
        var definitions: [String: Config.LayerDefinition] = [:]
        var ordinals: [String: Int] = [:]
        for (index, layer) in layers.enumerated() {
            let id = layer.id.uppercased()
            definitions[id] = layer
            ordinals[id] = index + 1
        }
        configuredLayers = definitions
        configuredOrdinals = ordinals
    }

    /// Choose the shortest direction through the configured cyclic layer order. The normal
    /// next-layer path therefore keeps moving forward even on the last → first wrap, while a
    /// programmatic jump back one layer rolls the opposite way.
    private func layerTransitionDirection(from sourceID: String, to destinationID: String) -> CGFloat {
        guard configuredOrdinals.count > 1,
              let source = configuredOrdinals[sourceID.uppercased()],
              let destination = configuredOrdinals[destinationID.uppercased()]
        else { return 1 }
        let count = configuredOrdinals.count
        let sourceIndex = source - 1
        let destinationIndex = destination - 1
        let forward = (destinationIndex - sourceIndex + count) % count
        let backward = (sourceIndex - destinationIndex + count) % count
        return forward <= backward ? 1 : -1
    }

    private func layerAppearance(_ rawID: String) -> (label: String, tint: NSColor, icon: String) {
        let id = rawID.uppercased()
        let definition = configuredLayers[id]
        let explicitName = definition?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = explicitName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLayerName(id)
        let tint = definition?.color.flatMap(configuredColor) ?? fallbackLayerTint(id)
        let icon = ActionVisual.firstValidSystemSymbol(
            [definition?.icon, configuredIcons["layer.default"], configuredIcons["fallback"]],
            fallback: "square.stack.3d.up.fill"
        )
        return (label, tint, icon)
    }

    private func configuredIcon(_ key: String, fallback: String) -> String {
        ActionVisual.firstValidSystemSymbol(
            [configuredIcons[key], fallback, configuredIcons["fallback"]],
            fallback: "command.circle.fill"
        )
    }

    private func fallbackLayerName(_ id: String) -> String {
        if let ordinal = configuredOrdinals[id] { return L("Layer %d", ordinal) }
        if id == "BASE" { return L("Layer 1") }
        if id.hasPrefix("L"), let number = Int(id.dropFirst()), number > 0 {
            return L("Layer %d", number + 1)
        }
        return id
    }

    private func fallbackLayerTint(_ id: String) -> NSColor {
        if id == "BASE" { return .systemGreen }
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange,
                                  .systemPink, .systemTeal, .systemIndigo]
        if id.hasPrefix("L"), let number = Int(id.dropFirst()), number > 0 {
            return palette[(number - 1) % palette.count]
        }
        if let ordinal = configuredOrdinals[id], ordinal > 1 {
            return palette[(ordinal - 2) % palette.count]
        }
        return .systemBlue
    }

    private func configuredColor(_ raw: String) -> NSColor? {
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
            let alphaDigits = digits.count == 8
            let r = CGFloat((packed >> (alphaDigits ? 24 : 16)) & 0xff) / 255
            let g = CGFloat((packed >> (alphaDigits ? 16 : 8)) & 0xff) / 255
            let b = CGFloat((packed >> (alphaDigits ? 8 : 0)) & 0xff) / 255
            let a = alphaDigits ? CGFloat(packed & 0xff) / 255 : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    private func tint(forBundleID bundleID: String) -> NSColor {
        let id = bundleID.lowercased()
        if id.contains("music") || id.contains("spotify") { return .systemPink }
        if id.contains("chrome") || id.contains("safari") || id.contains("firefox") { return .systemBlue }
        if id.contains("terminal") || id.contains("warp") { return .systemIndigo }
        return .controlAccentColor
    }

    // MARK: - Animation

    private func copiedIconView(_ source: NSImageView) -> NSImageView {
        let icon = NSImageView(frame: source.frame)
        icon.image = source.image
        icon.imageScaling = source.imageScaling
        icon.imageAlignment = source.imageAlignment
        icon.contentTintColor = source.contentTintColor
        icon.wantsLayer = true
        return icon
    }

    private func copiedLabel(_ source: NSTextField) -> NSTextField {
        let label = NSTextField(labelWithString: source.stringValue)
        label.frame = source.frame
        label.font = source.font
        label.textColor = source.textColor
        label.alignment = source.alignment
        label.lineBreakMode = source.lineBreakMode
        label.maximumNumberOfLines = source.maximumNumberOfLines
        label.wantsLayer = true
        label.cell?.backgroundStyle = surface.cardView.interiorBackgroundStyle
        return label
    }

    private func makeNormalContentProxy() -> NormalContentProxy {
        contentMorphGeneration += 1
        // A new input is allowed to interrupt the previous 220–280 ms transformation. Resolve the
        // permanent destination hierarchy and discard its exact temporary reconstruction in one
        // disabled-actions transaction. Reading a stale presentation opacity here used to create a
        // fully empty card for ~150 ms when two actions arrived close together.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [surface.iconView.layer, surface.titleLabel.layer,
                      surface.subtitleLabel.layer].compactMap({ $0 }) {
            layer.removeAnimation(forKey: "contentMorphIncoming")
            layer.removeAnimation(forKey: "layerMorphIncoming")
            layer.removeAnimation(forKey: "connectedMorphIncoming")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
        contentMorphProxyViews.forEach { $0.removeFromSuperview() }
        contentMorphProxyViews.removeAll()
        contentMorphTransientLayers.forEach { $0.removeFromSuperlayer() }
        contentMorphTransientLayers.removeAll()
        CATransaction.commit()

        let icon = copiedIconView(surface.iconView)
        let title = copiedLabel(surface.titleLabel)
        let subtitle = copiedLabel(surface.subtitleLabel)
        let proxy = NormalContentProxy(iconView: icon, titleLabel: title,
                                       subtitleLabel: subtitle,
                                       symbolName: currentSymbolName)
        for view in proxy.views { surface.contentView.addSubview(view) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for destination in [icon.layer, title.layer, subtitle.layer] {
            destination?.opacity = 1
            destination?.transform = CATransform3DIdentity
        }
        CATransaction.commit()
        contentMorphProxyViews = proxy.views
        return proxy
    }

    private func finishContentMorph(generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.contentMorphGeneration == generation else { return }
            // Reveal the permanent hierarchy in the exact transaction that removes its temporary
            // reconstruction. Letting the hide animation expire on its own even a few milliseconds
            // earlier draws both copies for one refresh: the title looks heavier and appears to
            // jump by the rasterisation difference between CATextLayer and NSTextField.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [self.surface.iconView.layer, self.surface.titleLabel.layer,
                          self.surface.subtitleLabel.layer].compactMap({ $0 }) {
                layer.removeAnimation(forKey: "connectedMorphIncoming")
            }
            self.contentMorphProxyViews.forEach { $0.removeFromSuperview() }
            self.contentMorphProxyViews.removeAll()
            self.contentMorphTransientLayers.forEach { $0.removeFromSuperlayer() }
            self.contentMorphTransientLayers.removeAll()
            CATransaction.commit()
        }
    }

    private func animateContentTransition(from proxy: NormalContentProxy?,
                                          iconMotion: IconMotion,
                                          accentSweep: Bool,
                                          symbolCue: SymbolCue?) {
        animateConnectedLensMorph(from: proxy,
                                  direction: iconMotion.titleDirection,
                                  animateSubtitle: true,
                                  iconMotion: iconMotion,
                                  accentSweep: accentSweep,
                                  symbolCue: symbolCue)
    }

    /// A compact connected transition influenced by Apple's spatial continuity, Fluent's
    /// connected animation and Material's shared-axis motion. It deliberately avoids blur as the
    /// main effect: the icon is optically sliced, unchanged letters physically retain their place,
    /// changed letters fold through the baseline, and the subtitle follows a beat later.
    private func animateConnectedLensMorph(from proxy: NormalContentProxy?, direction: CGFloat,
                                           animateSubtitle: Bool, iconMotion: IconMotion,
                                           accentSweep: Bool, symbolCue: SymbolCue?) {
        guard let proxy = proxy else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            animateElementFlip(from: proxy, direction: direction,
                               animateSubtitle: animateSubtitle)
            return
        }

        let generation = contentMorphGeneration
        // 280 ms is the complete interval for this compact multi-track transformation. The
        // semantic object itself finishes in 220–280 ms; the final overlap is only an exact proxy →
        // permanent-view handoff, keeping every visible transition inside the requested 0.2–0.3 s.
        let duration: CFTimeInterval = 0.28
        let oldOpacities = proxy.views.map {
            $0.layer?.presentation()?.opacity ?? $0.layer?.opacity ?? 1
        }

        // Rasterise every endpoint before the animation clock exists. Core Animation commits only
        // after this main-thread turn returns; starting its clock before AppKit cacheDisplay calls
        // made the icon's entire first half elapse before the first composited frame.
        let oldIconSnapshot = makeViewSnapshot(proxy.iconView)
        let newIconSnapshot = makeViewSnapshot(surface.iconView)
        let oldTitleSnapshot = makeViewSnapshot(proxy.titleLabel)
        let newTitleSnapshot = makeViewSnapshot(surface.titleLabel)
        let oldSubtitleSnapshot = animateSubtitle ? makeViewSnapshot(proxy.subtitleLabel) : nil
        let newSubtitleSnapshot = animateSubtitle ? makeViewSnapshot(surface.subtitleLabel) : nil
        // All pieces start only after their expensive AppKit snapshots exist. Hold boundaries are
        // already driven by the water's display tick, so start that icon transaction at this exact
        // compositor commit; the other one-shot transitions retain a one-frame preparation edge.
        let isHoldBoundary: Bool
        if case .holdSequence = iconMotion { isHoldBoundary = true } else { isHoldBoundary = false }
        let timelineStart = CACurrentMediaTime() + (isHoldBoundary ? 0 : 0.016)
        if !animateSubtitle { proxy.subtitleLabel.removeFromSuperview() }

        var incomingLayers: [CALayer?] = [surface.titleLabel.layer]
        incomingLayers.insert(surface.iconView.layer, at: 0)
        if animateSubtitle { incomingLayers.append(surface.subtitleLabel.layer) }
        // The real destination stays hidden beneath an exact temporary reconstruction. Removing
        // the overlays at rest therefore cannot create a final flash or one-frame geometry snap.
        for layer in incomingLayers.compactMap({ $0 }) {
            let hidden = CAKeyframeAnimation(keyPath: "opacity")
            hidden.values = [0, 0, 1]
            hidden.keyTimes = [0, 0.86, 1]
            hidden.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            hidden.duration = duration
            hidden.beginTime = layer.convertTime(timelineStart, from: nil)
            hidden.fillMode = .both
            hidden.isRemovedOnCompletion = false
            layer.add(hidden, forKey: "connectedMorphIncoming")
        }

        var containers: [NSView] = []
        if !requiresAuthoredIconTransition(iconMotion),
           supportsNativeSymbolMorph(from: proxy.symbolName, to: currentSymbolName,
                                     allowingUnrelated: iconMotion.usesStrictByLayerReplacement),
           let oldImage = proxy.iconView.image,
           let newImage = surface.iconView.image {
            let iconMorph = makeNativeSymbolMorph(
                outgoing: proxy.iconView, incoming: surface.iconView,
                oldImage: oldImage, newImage: newImage,
                outgoingOpacity: oldOpacities[0], motion: iconMotion,
                cue: symbolCue,
                duration: semanticIconDuration(for: iconMotion),
                delay: isHoldBoundary ? 0 : 0.004,
                timelineStart: timelineStart
            )
            containers.append(iconMorph)
        } else {
            switch iconMotion {
            case .ordinary:
                let iconMorph = makeWholeSurfaceTurn(
                outgoing: proxy.iconView, incoming: surface.iconView,
                oldSnapshot: oldIconSnapshot, newSnapshot: newIconSnapshot,
                outgoingOpacity: oldOpacities[0], direction: direction,
                axisX: 0, axisY: 1, duration: 0.22,
                delay: 0.004, timelineStart: timelineStart
            )
                containers.append(iconMorph)
            default:
                let semanticIcon = makeSemanticIconTransition(
                outgoing: proxy.iconView, incoming: surface.iconView,
                oldSnapshot: oldIconSnapshot, newSnapshot: newIconSnapshot,
                outgoingOpacity: oldOpacities[0], motion: iconMotion,
                duration: semanticIconDuration(for: iconMotion),
                delay: isHoldBoundary ? 0 : 0.004,
                timelineStart: timelineStart
            )
                containers.append(semanticIcon)
            }
        }

        let titleMorph = makeWholeSurfaceTurn(
            outgoing: proxy.titleLabel, incoming: surface.titleLabel,
            oldSnapshot: oldTitleSnapshot, newSnapshot: newTitleSnapshot,
            outgoingOpacity: oldOpacities[1], direction: direction,
            axisX: 1, axisY: 0, duration: 0.22,
            delay: 0.030, timelineStart: timelineStart
        )
        containers.append(titleMorph)

        if animateSubtitle {
            let subtitleMorph = makeWholeSurfaceTurn(
                outgoing: proxy.subtitleLabel, incoming: surface.subtitleLabel,
                oldSnapshot: oldSubtitleSnapshot, newSnapshot: newSubtitleSnapshot,
                outgoingOpacity: oldOpacities[2], direction: direction,
                axisX: 1, axisY: 0, duration: 0.20,
                delay: 0.052, timelineStart: timelineStart
            )
            containers.append(subtitleMorph)
        }

        // The animated back faces and the permanent AppKit views overlap for the final 50 ms.
        // Their opacity sum remains one, hiding even sub-pixel rasterisation differences instead
        // of exposing them as a last-frame translation or font-weight pop.
        let landingBegin = timelineStart + duration * 0.86
        for (index, container) in containers.enumerated() {
            addConnectedKeyframes(
                keyPath: "opacity", values: [1, 0], keyTimes: [0, 1],
                duration: duration * 0.14, beginTime: landingBegin,
                timing: CAMediaTimingFunction(name: .easeInEaseOut),
                to: container.layer, key: "wholeSurfaceLanding\(index)"
            )
        }

        // App/launch emphasis is carried by the icon's spatial aperture. A previous full-card
        // light trace crossed the labels like a scratch and competed with the component-level
        // motion, so `accentSweep` intentionally adds no second overlay here.
        _ = accentSweep

        contentMorphProxyViews = containers
        let lead = max(0, timelineStart - CACurrentMediaTime())
        finishContentMorph(generation: generation, after: lead + duration + 0.035)
    }

    /// Treat the complete icon or line of text as one coherent optical surface. The icon is a true
    /// two-sided object: its front face turns through the vertical centre and the next symbol is
    /// literally its reverse face. Text uses a mutually-exclusive shallow page turn, so a title
    /// never becomes two superimposed words or an edge-on grille. Both endpoints are exact Retina
    /// snapshots of the real AppKit views.
    @discardableResult
    private func makeWholeSurfaceTurn(outgoing: NSView, incoming: NSView,
                                      oldSnapshot: LabelSnapshot?, newSnapshot: LabelSnapshot?,
                                      outgoingOpacity: Float, direction: CGFloat,
                                      axisX: CGFloat, axisY: CGFloat,
                                      duration: CFTimeInterval, delay: CFTimeInterval,
                                      timelineStart: CFTimeInterval) -> NSView {
        let container = NSView(frame: incoming.frame)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        outgoing.removeFromSuperview()
        surface.contentView.addSubview(container)

        guard let oldSnapshot = oldSnapshot, let newSnapshot = newSnapshot else {
            // Caching can fail for a view detached during application shutdown. Preserve a safe,
            // non-crashing handoff in that exceptional path; normal UI transitions always use the
            // coherent two-sided surface above.
            return makeSnapshotFallback(outgoing: outgoing, incoming: incoming,
                                        in: container, outgoingOpacity: outgoingOpacity,
                                        duration: duration, delay: delay,
                                        timelineStart: timelineStart)
        }

        // A line of text is much wider than it is tall. Modelling it as a 90-degree adjacent face
        // makes both words project into the same pixels for half the turn. The compact split-flap
        // treatment below keeps only one face visible at a time, swaps it at identical 56-degree
        // foreshortening, and never exposes a blank horizontal edge.
        if axisX > axisY {
            let frontView = makeSnapshotView(oldSnapshot, frame: container.bounds)
            let backView = makeSnapshotView(newSnapshot, frame: container.bounds)
            frontView.alphaValue = CGFloat(outgoingOpacity)
            backView.alphaValue = 0
            container.addSubview(frontView)
            container.addSubview(backView)
            animateLabelPageTurn(front: frontView, back: backView,
                                 direction: direction, duration: duration,
                                 begin: timelineStart + delay, container: container)
            return container
        }

        let rig = CATransformLayer()
        rig.bounds = container.bounds
        rig.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        rig.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let front = makeSnapshotLayer(oldSnapshot, frame: container.bounds)
        let back = makeSnapshotLayer(newSnapshot, frame: container.bounds)
        front.opacity = outgoingOpacity
        front.isDoubleSided = false
        back.isDoubleSided = false

        let sign: CGFloat = direction >= 0 ? 1 : -1
        var reverseFace = CATransform3DIdentity
        reverseFace = CATransform3DRotate(reverseFace, -sign * .pi,
                                           axisX, axisY, 0)
        back.transform = reverseFace
        rig.addSublayer(front)
        rig.addSublayer(back)
        container.layer?.addSublayer(rig)

        // A literal front/back flip. The narrow spectral edge is the only thing visible at 90°;
        // it makes the topology legible without adding blur, a second icon, or a full-card scale.
        let begin = timelineStart + delay
        let angles: [CGFloat] = [0, sign * .pi * 0.34, sign * .pi * 0.48,
                                 sign * .pi * 0.52, sign * .pi * 0.86,
                                 sign * .pi]
        let depths: [CGFloat] = [0, 5.5, 8.0, 8.0, 3.0, 0]
        let scales: [CGFloat] = [1, 1.025, 1.038, 1.038, 1.012, 1]
        let transforms = zip(zip(angles, depths), scales).map { pair, scale in
            NSValue(caTransform3D: spatialTransform(
                z: pair.1, scale: scale,
                rotateX: pair.0 * axisX, rotateY: pair.0 * axisY,
                perspective: axisY > axisX ? 310 : 520
            ))
        }
        addConnectedKeyframes(
            keyPath: "transform", values: transforms,
            keyTimes: [0, 0.32, 0.46, 0.54, 0.80, 1], duration: duration,
            beginTime: begin, timing: CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1),
            to: rig, key: "spatialPrismTurn"
        )
        if axisY > axisX {
            installPrismEdgeFlash(in: container, axisX: axisX, axisY: axisY,
                                  duration: duration, begin: begin)
        }
        return container
    }

    private func semanticIconDuration(for motion: IconMotion) -> CFTimeInterval {
        switch motion {
        case .actionImpulse: return 0.22
        case .returnSweep: return 0.25
        case .settleToLayer: return 0.22
        case .layerRebuild, .applicationArrival, .appWheelWave: return 0.28
        case .holdSequence: return 0.26
        case .voiceModeSwitch: return 0.24
        case .voicePipeline: return 0.26
        case .ordinary: return 0.22
        }
    }

    private func requiresAuthoredIconTransition(_ motion: IconMotion) -> Bool {
        switch motion {
        case .appWheelWave, .voiceModeSwitch: return true
        default: return false
        }
    }

    /// Morphicons' public engine consumes stroke-path data, while AppKit deliberately exposes an
    /// SF Symbol as `NSImage` rather than public SVG geometry. On supported systems the Symbols
    /// framework is the native topology-aware path: Magic Replace preserves related layers and
    /// falls back cleanly for unrelated symbols. macOS 13 keeps the compositor-only 3D fallback.
    private func supportsNativeSymbolMorph(from oldName: String?, to newName: String?,
                                           allowingUnrelated: Bool = false) -> Bool {
        guard oldName != nil, newName != nil else { return false }
        guard allowingUnrelated
                || ActionSymbolStyle.supportsTopologyAwareReplacement(from: oldName, to: newName)
        else { return false }
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Keep AppKit's live symbol view in the hierarchy so the Symbols framework can animate its
    /// real vector layers. A shallow parent-camera move and a semantic contour distinguish Layer,
    /// tap, return and hold events without fighting the native path morph inside the image view.
    @discardableResult
    private func makeNativeSymbolMorph(outgoing: NSImageView, incoming: NSImageView,
                                       oldImage: NSImage, newImage: NSImage,
                                       outgoingOpacity: Float, motion: IconMotion,
                                       cue: SymbolCue?,
                                       duration: CFTimeInterval, delay: CFTimeInterval,
                                       timelineStart: CFTimeInterval) -> NSView {
        let container = NSView(frame: incoming.frame)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        outgoing.removeFromSuperview()
        outgoing.frame = container.bounds
        outgoing.image = oldImage
        outgoing.alphaValue = CGFloat(outgoingOpacity)
        container.addSubview(outgoing)
        surface.contentView.addSubview(container)

        let begin = timelineStart + delay
        let spatial: [NSValue]
        let times: [NSNumber]
        switch motion {
        case .layerRebuild(let direction):
            let sign: CGFloat = direction >= 0 ? 1 : -1
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 300)),
                NSValue(caTransform3D: spatialTransform(z: 8, scale: 1.055,
                                                        rotateX: -0.08,
                                                        rotateY: sign * 0.30,
                                                        perspective: 300)),
                NSValue(caTransform3D: spatialTransform(z: 5, scale: 1.035,
                                                        rotateX: 0.06,
                                                        rotateY: -sign * 0.16,
                                                        perspective: 300)),
                NSValue(caTransform3D: spatialTransform(perspective: 300)),
            ]
            times = [0, 0.34, 0.70, 1]
        case .actionImpulse:
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 280)),
                NSValue(caTransform3D: spatialTransform(z: 10, scale: 1.07,
                                                        rotateX: -0.10,
                                                        perspective: 280)),
                NSValue(caTransform3D: spatialTransform(z: -2, scale: 0.985,
                                                        rotateX: 0.04,
                                                        perspective: 280)),
                NSValue(caTransform3D: spatialTransform(perspective: 280)),
            ]
            times = [0, 0.38, 0.76, 1]
        case .returnSweep:
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 285)),
                NSValue(caTransform3D: spatialTransform(x: -1.2, z: 7, scale: 1.04,
                                                        rotateY: -0.38,
                                                        perspective: 285)),
                NSValue(caTransform3D: spatialTransform(x: 0.3, z: 2, scale: 1.015,
                                                        rotateY: 0.06,
                                                        perspective: 285)),
                NSValue(caTransform3D: spatialTransform(perspective: 285)),
            ]
            times = [0, 0.42, 0.82, 1]
        case .holdSequence:
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 290)),
                NSValue(caTransform3D: spatialTransform(y: 0.8, z: 8, scale: 1.045,
                                                        rotateX: -0.28,
                                                        perspective: 290)),
                NSValue(caTransform3D: spatialTransform(y: -0.2, z: 2,
                                                        rotateX: 0.055,
                                                        perspective: 290)),
                NSValue(caTransform3D: spatialTransform(perspective: 290)),
            ]
            times = [0, 0.38, 0.80, 1]
        case .voicePipeline(let stage):
            // The vector symbol remains live while its authored layers replace. A different,
            // restrained camera inflection for each semantic stage makes the pipeline legible
            // without moving or scaling the card itself.
            let direction: CGFloat = stage.rawValue.isMultiple(of: 2) ? 1 : -1
            let depth: CGFloat = stage.isTerminal ? 8 : 6
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 330)),
                NSValue(caTransform3D: spatialTransform(
                    x: direction * 0.65, y: stage == .inserting ? -0.7 : 0,
                    z: depth, scale: stage.isTerminal ? 1.045 : 1.035,
                    scaleX: 1.035, scaleY: 0.94,
                    rotateX: stage == .transcribing ? -0.10 : 0.06,
                    rotateY: direction * 0.12,
                    rotateZ: direction * (stage == .polishing ? 0.10 : 0.035),
                    perspective: 330
                )),
                NSValue(caTransform3D: spatialTransform(
                    x: -direction * 0.18, z: 2, scale: 1.012,
                    rotateX: -0.018, rotateY: -direction * 0.025,
                    perspective: 330
                )),
                NSValue(caTransform3D: spatialTransform(perspective: 330)),
            ]
            times = [0, 0.38, 0.78, 1]
        case .settleToLayer:
            spatial = [
                NSValue(caTransform3D: spatialTransform(z: -5, scale: 0.92,
                                                        rotateX: 0.24,
                                                        perspective: 310)),
                NSValue(caTransform3D: spatialTransform(z: 5, scale: 1.035,
                                                        rotateX: -0.06,
                                                        perspective: 310)),
                NSValue(caTransform3D: spatialTransform(perspective: 310)),
            ]
            times = [0, 0.70, 1]
        case .ordinary, .applicationArrival, .appWheelWave, .voiceModeSwitch:
            spatial = [
                NSValue(caTransform3D: spatialTransform(perspective: 320)),
                NSValue(caTransform3D: spatialTransform(z: 6, scale: 1.035,
                                                        rotateY: 0.10,
                                                        perspective: 320)),
                NSValue(caTransform3D: spatialTransform(perspective: 320)),
            ]
            times = [0, 0.52, 1]
        }
        addConnectedKeyframes(
            keyPath: "transform", values: spatial, keyTimes: times,
            duration: duration, beginTime: begin,
            timing: CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1),
            to: container.layer, key: "nativeSymbolCamera"
        )
        installNativeSymbolAccent(in: container, motion: motion,
                                  duration: duration, begin: begin)

        let generation = contentMorphGeneration
        let wait = max(0, begin - CACurrentMediaTime())
        let destinationTint = incoming.contentTintColor
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak outgoing] in
            guard let self, let outgoing,
                  self.contentMorphGeneration == generation,
                  outgoing.superview != nil else { return }
            outgoing.contentTintColor = destinationTint
            if #available(macOS 14.0, *) {
                ActionSymbolStyle.replaceSymbol(
                    in: outgoing, with: newImage, cue: cue,
                    preferMagic: !motion.usesStrictByLayerReplacement
                )
            }
        }
        return container
    }

    /// Controls whose physical input is naturally rate-driven. The first event establishes a
    /// readable face; later events in the same family are state updates, not new animation beats.
    private func continuousFeedbackFamily(for action: Action) -> String? {
        switch action {
        case .media(let key):
            switch key.lowercased() {
            case "volup", "volumeup", "voldown", "volumedown": return "volume"
            default: return nil
            }
        case .brightness, .brightnessStep:
            return "brightness"
        case .repeatKey(let keys, _, _):
            return "repeat:\(keys.lowercased())"
        case .mouse(let op):
            switch op.lowercased() {
            case "move", "scroll": return "mouse:\(op.lowercased())"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `Controller` reports an action just before its executor posts the real system key. Continuous
    /// values use the current measurement for zero-latency feedback, then this sampler confirms the
    /// result after macOS applies the key. Mute is predicted as one post-toggle transaction up front,
    /// so its normal confirmation is a no-op; only a failed/missed edge causes a corrective replace.
    /// Absolute brightness actions receive extra samples because their implementation ramps through
    /// hardware-key notches.
    private func scheduleControlStateRefresh(
        for handled: Controller.HandledAction,
        expectedPresentationKey: String,
        duration: TimeInterval,
        disabled: Bool
    ) {
        guard !disabled else { return }
        let refreshGeneration = controlStateRefreshGeneration
        let delays: [TimeInterval]
        switch handled.action {
        case .media(let key):
            guard ["volup", "volumeup", "voldown", "volumedown", "mute"]
                .contains(key.lowercased()) else { return }
            // MediaController posts key-up at 50 ms; sample after that edge has reached CoreAudio.
            delays = [0.085]
        case .applescript where SystemControlState.isSystemOutputMuteToggle(handled.action):
            // AppleScript normally commits well before the first sample. The second is a cheap
            // fallback for a busy system and is de-duplicated against the same measured state.
            delays = [0.085, 0.18]
        case .brightnessStep:
            delays = [0.070, 0.16]
        case .brightness:
            delays = [0.070, 0.16, 0.27]
        default:
            return
        }

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.controlStateRefreshGeneration == refreshGeneration,
                      self.enabled, self.isConnected, !self.isHolding, self.isTransient,
                      self.currentPresentationKey == expectedPresentationKey,
                      self.lastEvent?.key == handled.key else { return }
                SystemControlState.refresh(for: handled.action) { [weak self] state in
                    guard let self, let state,
                          self.controlStateRefreshGeneration == refreshGeneration,
                          self.enabled, self.isConnected, !self.isHolding, self.isTransient,
                          self.currentPresentationKey == expectedPresentationKey,
                          self.lastEvent?.key == handled.key else { return }
                    let refreshed = self.actionFace(
                        key: handled.key,
                        action: handled.action,
                        presentation: handled.presentation,
                        subtitle: self.gestureLabel(for: handled.key),
                        controlStateOverride: state
                    )
                    guard refreshed.controlState != self.currentControlState else { return }
                    if SystemControlState.isSystemOutputMuteToggle(handled.action) {
                        self.refreshMuteState(
                            refreshed,
                            expectedPresentationKey: expectedPresentationKey,
                            handledKey: handled.key,
                            duration: duration,
                            generation: refreshGeneration
                        )
                    } else {
                        self.presentTransient(refreshed, duration: duration, animate: false,
                                              playSymbolCue: false)
                    }
                }
            }
        }
    }

    /// Apply a measured mute edge to the live symbol view. Apple's Magic Replace owns the speaker
    /// topology, so the slash draws on/off while the speaker body stays spatially continuous. If a
    /// Layer → Mute entrance is still using exact snapshot proxies, wait for that handoff before
    /// starting the native transition; otherwise the slash animation would run behind an overlay
    /// and only its final frame would be visible.
    private func refreshMuteState(
        _ face: Face,
        expectedPresentationKey: String,
        handledKey: String,
        duration: TimeInterval,
        generation: Int
    ) {
        guard let state = face.controlState else { return }
        if !contentMorphProxyViews.isEmpty {
            if let pending = pendingControlRefresh,
               pending.generation == generation, pending.state == state { return }
            pendingControlRefresh = (generation, state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self] in
                guard let self,
                      self.controlStateRefreshGeneration == generation,
                      let pending = self.pendingControlRefresh,
                      pending.generation == generation, pending.state == state else { return }
                self.pendingControlRefresh = nil
                guard self.enabled, self.isConnected, !self.isHolding, self.isTransient,
                      self.currentPresentationKey == expectedPresentationKey,
                      self.lastEvent?.key == handledKey else { return }
                self.applyMuteState(face, duration: duration)
            }
            return
        }
        pendingControlRefresh = nil
        applyMuteState(face, duration: duration)
    }

    private func applyMuteState(_ face: Face, duration: TimeInterval) {
        guard let source = face.image else {
            presentTransient(face, duration: duration, animate: false, playSymbolCue: false)
            return
        }
        let oldSymbolName = currentSymbolName
        let image = ActionSymbolStyle.hierarchicalImage(
            source, symbolName: face.symbolName, tint: face.tint, cue: face.symbolCue
        ) ?? source

        currentFaceTint = face.tint
        currentSymbolName = face.symbolName
        currentSymbolCue = face.symbolCue
        currentControlState = face.controlState
        currentPresentationKey = face.key
        surface.titleLabel.stringValue = face.title
        surface.subtitleLabel.stringValue = face.subtitle
        surface.iconView.contentTintColor = nil
        applyHoldContentContrast()
        applyColors(face.tint, animated: false)

        if supportsNativeSymbolMorph(from: oldSymbolName, to: face.symbolName),
           #available(macOS 14.0, *) {
            // No secondary mute cue: Magic Replace itself is the complete state feedback. Adding
            // variable-colour on top would restart the speaker layers and make the slash flicker.
            ActionSymbolStyle.replaceSymbol(in: surface.iconView, with: image,
                                            cue: nil, speed: 2.8)
        } else {
            surface.iconView.image = image
        }
        scheduleIdle(after: duration)
    }

    /// Use the symbol's authored internal layers as the moving parts. Speeds are intentionally
    /// brisk because these effects share the same 220–280 ms interaction envelope as the rest of
    /// the widget; the permanent icon takes over before any lingering ornamental tail can form.
    private func applyNativeSymbolCue(_ cue: SymbolCue?, to imageView: NSImageView) {
        guard let cue, #available(macOS 14.0, *) else { return }
        ActionSymbolStyle.apply(cue, to: imageView)
    }

    private func installNativeSymbolAccent(in container: NSView, motion: IconMotion,
                                           duration: CFTimeInterval,
                                           begin: CFTimeInterval) {
        guard let root = container.layer else { return }
        let tint = (surface.iconView.contentTintColor ?? currentFaceTint)
            .usingColorSpace(.deviceRGB) ?? .controlAccentColor
        let timing = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1)

        switch motion {
        case .layerRebuild(let direction):
            let sign: CGFloat = direction >= 0 ? 1 : -1
            for index in 0..<3 {
                let sheet = CAShapeLayer()
                sheet.frame = container.bounds
                sheet.path = layerSheetPath(in: container.bounds)
                sheet.fillColor = tint.withAlphaComponent(0.035 + CGFloat(index) * 0.02).cgColor
                sheet.strokeColor = tint.withAlphaComponent(0.58).cgColor
                sheet.lineWidth = 0.85
                sheet.opacity = 0
                root.insertSublayer(sheet, at: 0)
                let depth = CGFloat(index - 1) * 7
                addConnectedKeyframes(
                    keyPath: "transform", values: [
                        NSValue(caTransform3D: spatialTransform(scale: 0.78,
                                                                perspective: 270)),
                        NSValue(caTransform3D: spatialTransform(
                            x: sign * CGFloat(index - 1) * 2.0,
                            y: CGFloat(index - 1) * 5.0, z: depth,
                            scale: 1.05, rotateX: CGFloat(index - 1) * 0.12,
                            rotateY: sign * CGFloat(index - 1) * 0.10,
                            perspective: 270
                        )),
                        NSValue(caTransform3D: spatialTransform(scale: 0.86,
                                                                perspective: 270)),
                    ], keyTimes: [0, 0.52, 1], duration: duration,
                    beginTime: begin + Double(index) * 0.008,
                    timing: timing, to: sheet, key: "nativeLayerSheet\(index)"
                )
                addConnectedKeyframes(
                    keyPath: "opacity", values: [0, 0.78, 0],
                    keyTimes: [0, 0.42, 1], duration: duration,
                    beginTime: begin + Double(index) * 0.008,
                    timing: timing, to: sheet, key: "nativeLayerSheetOpacity\(index)"
                )
            }

        case .actionImpulse(let requestedCount):
            let count = max(1, min(3, requestedCount))
            for index in 0..<count {
                let ring = CAShapeLayer()
                ring.frame = container.bounds
                ring.fillColor = nil
                ring.strokeColor = tint.withAlphaComponent(0.62).cgColor
                ring.lineWidth = 1.0
                ring.opacity = 0
                root.insertSublayer(ring, at: 0)
                let paths: [CGPath] = [4.0, 11.5, 18.5].map { radius in
                    CGPath(ellipseIn: CGRect(x: container.bounds.midX - radius,
                                             y: container.bounds.midY - radius,
                                             width: radius * 2, height: radius * 2),
                           transform: nil)
                }
                let stagger = Double(index) * 0.022
                addConnectedKeyframes(keyPath: "path", values: paths,
                                      keyTimes: [0, 0.46, 1], duration: duration - stagger,
                                      beginTime: begin + stagger, timing: timing,
                                      to: ring, key: "nativeImpulsePath\(index)")
                addConnectedKeyframes(keyPath: "opacity", values: [0, 0.62, 0],
                                      keyTimes: [0, 0.30, 1], duration: duration - stagger,
                                      beginTime: begin + stagger, timing: timing,
                                      to: ring, key: "nativeImpulseOpacity\(index)")
            }

        case .returnSweep:
            let trail = CAShapeLayer()
            trail.frame = container.bounds
            trail.path = returnArcPath(in: container.bounds)
            trail.fillColor = nil
            trail.strokeColor = tint.withAlphaComponent(0.76).cgColor
            trail.lineWidth = 1.15
            trail.lineCap = .round
            trail.opacity = 0
            root.addSublayer(trail)
            addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 0.86, 1],
                                  keyTimes: [0, 0.72, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: trail,
                                  key: "nativeReturnDraw")
            addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0, 0.70],
                                  keyTimes: [0, 0.64, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: trail,
                                  key: "nativeReturnErase")
            addConnectedKeyframes(keyPath: "opacity", values: [0, 0.88, 0],
                                  keyTimes: [0, 0.30, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: trail,
                                  key: "nativeReturnOpacity")

        case .holdSequence:
            for side: CGFloat in [-1, 1] {
                let rail = CAShapeLayer()
                rail.frame = container.bounds
                let x = container.bounds.midX + side * 15
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: container.bounds.midY - 9))
                path.addLine(to: CGPoint(x: x, y: container.bounds.midY + 9))
                rail.path = path
                rail.fillColor = nil
                rail.strokeColor = tint.withAlphaComponent(0.52).cgColor
                rail.lineWidth = 0.85
                rail.lineCap = .round
                rail.opacity = 0
                root.addSublayer(rail)
                addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 1, 1],
                                      keyTimes: [0, 0.50, 1], duration: duration,
                                      beginTime: begin, timing: timing, to: rail,
                                      key: "nativeHoldRailDraw\(side)")
                addConnectedKeyframes(keyPath: "opacity", values: [0, 0.62, 0],
                                      keyTimes: [0, 0.36, 1], duration: duration,
                                      beginTime: begin, timing: timing, to: rail,
                                      key: "nativeHoldRailOpacity\(side)")
            }

        case .voicePipeline(let stage):
            installVoicePipelineFilaments(in: root, bounds: container.bounds,
                                           tint: tint, stage: stage,
                                           duration: duration, begin: begin)

        case .settleToLayer:
            let seam = CAShapeLayer()
            seam.frame = container.bounds
            let path = CGMutablePath()
            path.move(to: CGPoint(x: container.bounds.midX - 13, y: container.bounds.midY))
            path.addLine(to: CGPoint(x: container.bounds.midX + 13, y: container.bounds.midY))
            seam.path = path
            seam.fillColor = nil
            seam.strokeColor = tint.withAlphaComponent(0.62).cgColor
            seam.lineWidth = 1.0
            seam.lineCap = .round
            seam.opacity = 0
            root.insertSublayer(seam, at: 0)
            addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0.42, 0.50],
                                  keyTimes: [0, 0.58, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: seam,
                                  key: "nativeSettleStart")
            addConnectedKeyframes(keyPath: "strokeEnd", values: [1, 0.58, 0.50],
                                  keyTimes: [0, 0.58, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: seam,
                                  key: "nativeSettleEnd")
            addConnectedKeyframes(keyPath: "opacity", values: [0, 0.70, 0],
                                  keyTimes: [0, 0.32, 1], duration: duration,
                                  beginTime: begin, timing: timing, to: seam,
                                  key: "nativeSettleOpacity")

        case .ordinary, .applicationArrival, .appWheelWave, .voiceModeSwitch:
            break
        }
    }

    /// A stage-specific signal contour. It is deliberately neither a progress bar nor a spinner:
    /// the same acoustic filament changes topology as Voice moves from sound, through refinement
    /// and delivery, into its terminal state. Two staggered strokes create depth without particles
    /// or dots, both of which become noisy in a 40 pt icon aperture.
    private func voicePipelineContourPaths(in bounds: CGRect,
                                           stage: VoicePipelineVisualStage) -> [CGPath] {
        let left = bounds.minX + 4
        let right = bounds.maxX - 4
        let midX = bounds.midX
        let midY = bounds.midY
        func path(_ build: (CGMutablePath) -> Void) -> CGPath {
            let value = CGMutablePath()
            build(value)
            return value
        }

        switch stage {
        case .transcribing:
            return [-3.0, 3.0].map { offset in
                path {
                    $0.move(to: CGPoint(x: left, y: midY + offset))
                    $0.addCurve(to: CGPoint(x: right, y: midY - offset),
                                control1: CGPoint(x: left + 8, y: midY + 9 + offset),
                                control2: CGPoint(x: right - 8, y: midY - 9 - offset))
                }
            }
        case .polishing, .rewriting:
            return [-1.0, 1.0].map { direction in
                path {
                    $0.move(to: CGPoint(x: left + 1, y: midY))
                    $0.addCurve(to: CGPoint(x: right - 1, y: midY),
                                control1: CGPoint(x: midX - 3, y: midY + direction * 15),
                                control2: CGPoint(x: midX + 3, y: midY - direction * 15))
                }
            }
        case .inserting:
            return [-3.2, 3.2].map { offset in
                path {
                    $0.move(to: CGPoint(x: left, y: midY + offset))
                    $0.addCurve(to: CGPoint(x: midX + 4, y: midY + offset),
                                control1: CGPoint(x: left + 7, y: midY + offset),
                                control2: CGPoint(x: midX - 3, y: midY + offset))
                    $0.addCurve(to: CGPoint(x: right - 1, y: midY + directionFor(offset) * 8),
                                control1: CGPoint(x: midX + 9, y: midY + offset),
                                control2: CGPoint(x: right - 4, y: midY + directionFor(offset) * 5))
                }
            }
        case .inserted, .replaced:
            return [0.0, 2.2].map { offset in
                path {
                    $0.move(to: CGPoint(x: left + 2, y: midY + offset))
                    $0.addLine(to: CGPoint(x: midX - 2, y: midY - 7 + offset))
                    $0.addLine(to: CGPoint(x: right - 1, y: midY + 9 + offset))
                }
            }
        case .copied:
            return [-2.4, 2.4].map { offset in
                let rect = CGRect(x: left + 5 + offset, y: midY - 8 - offset,
                                  width: 17, height: 16)
                return CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3,
                              transform: nil)
            }
        case .error:
            return [-2.0, 2.0].map { offset in
                path {
                    $0.move(to: CGPoint(x: left, y: midY + offset))
                    $0.addLine(to: CGPoint(x: midX - 5, y: midY + 7 + offset))
                    $0.addLine(to: CGPoint(x: midX + 4, y: midY - 7 + offset))
                    $0.addLine(to: CGPoint(x: right, y: midY + offset))
                }
            }
        }
    }

    private func directionFor(_ value: CGFloat) -> CGFloat { value < 0 ? -1 : 1 }

    private func installVoicePipelineFilaments(in root: CALayer, bounds: CGRect,
                                               tint: NSColor,
                                               stage: VoicePipelineVisualStage,
                                               duration: CFTimeInterval,
                                               begin: CFTimeInterval) {
        let timing = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        for (index, path) in voicePipelineContourPaths(in: bounds, stage: stage).enumerated() {
            let filament = CAShapeLayer()
            filament.frame = bounds
            filament.path = path
            filament.fillColor = nil
            filament.strokeColor = tint.withAlphaComponent(index == 0 ? 0.78 : 0.46).cgColor
            filament.lineWidth = index == 0 ? 1.25 : 0.82
            filament.lineCap = .round
            filament.lineJoin = .round
            filament.strokeStart = 0
            filament.strokeEnd = 0
            filament.opacity = 0
            filament.shadowColor = tint.cgColor
            filament.shadowOpacity = index == 0 ? 0.28 : 0.14
            filament.shadowRadius = index == 0 ? 2.8 : 1.7
            filament.shadowOffset = .zero
            root.insertSublayer(filament, at: 0)

            let stagger = Double(index) * 0.018
            let localDuration = max(0.16, duration - stagger)
            addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 0.86, 1],
                                  keyTimes: [0, 0.66, 1], duration: localDuration,
                                  beginTime: begin + stagger, timing: timing,
                                  to: filament, key: "voicePipelineDraw\(index)")
            addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0.04, 0.76],
                                  keyTimes: [0, 0.58, 1], duration: localDuration,
                                  beginTime: begin + stagger, timing: timing,
                                  to: filament, key: "voicePipelineErase\(index)")
            addConnectedKeyframes(keyPath: "opacity", values: [0, 0.88, 0.52, 0],
                                  keyTimes: [0, 0.22, 0.72, 1], duration: localDuration,
                                  beginTime: begin + stagger, timing: timing,
                                  to: filament, key: "voicePipelineOpacity\(index)")
        }
    }

    /// First Final stage has no outgoing ordinary icon: it inherits the live acoustic console.
    /// Install the same signal contour beside that collapse and start the destination symbol's
    /// authored layers as they become visible. Subsequent stages use makeNativeSymbolMorph above.
    private func animateVoicePipelineIgnition(_ stage: VoicePipelineVisualStage,
                                               expectedKey: String,
                                               cue: SymbolCue?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let contentRoot = surface.contentView.layer else { return }
        voicePipelineAccentRoot?.removeFromSuperlayer()
        let root = CALayer()
        root.frame = surface.iconView.frame
        root.masksToBounds = false
        if let normalLayer = surface.normalContentView.layer {
            contentRoot.insertSublayer(root, below: normalLayer)
        } else {
            contentRoot.addSublayer(root)
        }
        voicePipelineAccentRoot = root
        let begin = CACurrentMediaTime() + 0.030
        installVoicePipelineFilaments(in: root, bounds: root.bounds,
                                      tint: stage.tint, stage: stage,
                                      duration: 0.26, begin: begin)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.082) { [weak self] in
            guard let self, self.currentPresentationKey == expectedKey else { return }
            self.applyNativeSymbolCue(cue, to: self.surface.iconView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { [weak self, weak root] in
            guard let self, let root, self.voicePipelineAccentRoot === root else { return }
            root.removeFromSuperlayer()
            self.voicePipelineAccentRoot = nil
        }
    }

    /// Icon motion is the status widget's interaction grammar. Geometry remains constrained to the
    /// icon's fixed frame; auxiliary contours may briefly breathe outside it, but neither the card,
    /// its Layer border, nor the text layout moves. All paths finish inside the same 220–280 ms
    /// window so a newer input can replace them without waiting.
    @discardableResult
    private func makeSemanticIconTransition(outgoing: NSView, incoming: NSView,
                                             oldSnapshot: LabelSnapshot?,
                                             newSnapshot: LabelSnapshot?,
                                             outgoingOpacity: Float, motion: IconMotion,
                                             duration: CFTimeInterval, delay: CFTimeInterval,
                                             timelineStart: CFTimeInterval) -> NSView {
        let container = NSView(frame: incoming.frame)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        outgoing.removeFromSuperview()
        surface.contentView.addSubview(container)

        guard let oldSnapshot, let newSnapshot else {
            return makeSnapshotFallback(outgoing: outgoing, incoming: incoming,
                                        in: container, outgoingOpacity: outgoingOpacity,
                                        duration: duration, delay: delay,
                                        timelineStart: timelineStart)
        }

        let front = makeSnapshotView(oldSnapshot, frame: container.bounds)
        let back = makeSnapshotView(newSnapshot, frame: container.bounds)
        front.alphaValue = CGFloat(outgoingOpacity)
        back.alphaValue = 0
        container.addSubview(front)
        container.addSubview(back)

        let tint = (surface.iconView.contentTintColor ?? currentFaceTint)
            .usingColorSpace(.deviceRGB) ?? .controlAccentColor
        var structureLayers: [CAShapeLayer] = []
        var apertureMask: CAShapeLayer?
        var sheetRig: CATransformLayer?
        var appWheelDots: [CALayer] = []
        var impactShards: [CAShapeLayer] = []
        var returnTrail: CAShapeLayer?
        var depthRails: [CAShapeLayer] = []
        var settleSeam: CAShapeLayer?

        switch motion {
        case .layerRebuild:
            // Three clean sheets become a real 3D hierarchy. The stack itself is the object: it
            // opens in Z, changes order under a shallow camera yaw, then closes as the new Layer.
            let rig = CATransformLayer()
            rig.bounds = container.bounds
            rig.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            rig.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            if let backLayer = back.layer {
                container.layer?.insertSublayer(rig, above: backLayer)
            } else {
                container.layer?.addSublayer(rig)
            }
            sheetRig = rig
            for index in 0..<3 {
                let sheet = CAShapeLayer()
                sheet.frame = container.bounds
                sheet.path = layerSheetPath(in: container.bounds)
                sheet.fillColor = tint.withAlphaComponent(0.08 + CGFloat(index) * 0.025).cgColor
                sheet.strokeColor = tint.withAlphaComponent(0.96 - CGFloat(index) * 0.12).cgColor
                sheet.lineWidth = index == 1 ? 1.35 : 1.10
                sheet.lineJoin = .round
                sheet.opacity = 0
                sheet.shadowColor = tint.cgColor
                sheet.shadowOpacity = index == 1 ? 0.20 : 0.10
                sheet.shadowRadius = index == 1 ? 3.2 : 1.8
                sheet.shadowOffset = .zero
                rig.addSublayer(sheet)
                structureLayers.append(sheet)
            }
        case .applicationArrival:
            let mask = CAShapeLayer()
            mask.frame = container.bounds
            back.layer?.mask = mask
            apertureMask = mask

            for index in 0..<3 {
                let orbit = CAShapeLayer()
                orbit.frame = container.bounds
                orbit.fillColor = nil
                orbit.strokeColor = (index == 1 ? NSColor.white : tint)
                    .withAlphaComponent(index == 1 ? 0.72 : 0.60).cgColor
                orbit.lineWidth = index == 1 ? 1.15 : 0.85
                orbit.lineCap = .round
                orbit.lineDashPattern = index == 1 ? nil : [5, 3]
                orbit.opacity = 0
                orbit.shadowColor = tint.cgColor
                orbit.shadowOpacity = index == 1 ? 0.28 : 0.14
                orbit.shadowRadius = index == 1 ? 3 : 1.5
                orbit.shadowOffset = .zero
                container.layer?.addSublayer(orbit)
                structureLayers.append(orbit)
            }
        case .appWheelWave:
            // These are pixel slices of the real destination SF Symbol, not substitute circles.
            // The relay can therefore address all nine destinations independently and still land
            // on the exact AppKit-rendered glyph without a final size/weight jump.
            appWheelDots = makeAppWheelDotLayers(from: newSnapshot,
                                                 in: container.bounds)
            for dot in appWheelDots {
                container.layer?.addSublayer(dot)
            }
        case .actionImpulse(let count):
            for _ in 0..<max(1, min(3, count)) {
                let ring = CAShapeLayer()
                ring.frame = container.bounds
                ring.fillColor = nil
                ring.strokeColor = tint.withAlphaComponent(0.78).cgColor
                ring.lineWidth = 1.20
                ring.opacity = 0
                container.layer?.insertSublayer(ring, at: 0)
                structureLayers.append(ring)
            }
            // Eight tiny radial facets make the press feel like a point impact, without adding a
            // persistent glow or particle system that would cost energy while the widget is idle.
            for index in 0..<8 {
                let shard = CAShapeLayer()
                shard.frame = container.bounds
                let angle = CGFloat(index) * .pi / 4
                let inner: CGFloat = 12.5
                let outer: CGFloat = 15.5
                let path = CGMutablePath()
                path.move(to: CGPoint(x: container.bounds.midX + cos(angle) * inner,
                                      y: container.bounds.midY + sin(angle) * inner))
                path.addLine(to: CGPoint(x: container.bounds.midX + cos(angle) * outer,
                                         y: container.bounds.midY + sin(angle) * outer))
                shard.path = path
                shard.fillColor = nil
                shard.strokeColor = tint.withAlphaComponent(0.78).cgColor
                shard.lineWidth = 1.15
                shard.lineCap = .round
                shard.opacity = 0
                container.layer?.addSublayer(shard)
                impactShards.append(shard)
            }
        case .returnSweep:
            let trail = CAShapeLayer()
            trail.frame = container.bounds
            trail.path = returnArcPath(in: container.bounds)
            trail.fillColor = nil
            trail.strokeColor = tint.withAlphaComponent(0.82).cgColor
            trail.lineWidth = 1.25
            trail.lineCap = .round
            trail.strokeStart = 0
            trail.strokeEnd = 0
            trail.opacity = 0
            trail.shadowColor = tint.cgColor
            trail.shadowOpacity = 0.24
            trail.shadowRadius = 2.5
            trail.shadowOffset = .zero
            container.layer?.addSublayer(trail)
            returnTrail = trail
        case .holdSequence:
            for side: CGFloat in [-1, 1] {
                let rail = CAShapeLayer()
                rail.frame = container.bounds
                let path = CGMutablePath()
                let x = container.bounds.midX + side * 15
                path.move(to: CGPoint(x: x, y: container.bounds.midY - 9))
                path.addLine(to: CGPoint(x: x, y: container.bounds.midY + 9))
                rail.path = path
                rail.fillColor = nil
                rail.strokeColor = tint.withAlphaComponent(0.58).cgColor
                rail.lineWidth = 0.9
                rail.lineCap = .round
                rail.opacity = 0
                container.layer?.addSublayer(rail)
                depthRails.append(rail)
            }
        case .voiceModeSwitch:
            // Three routes share one physical side button. Concentric partial traces expose that
            // topology for one beat, then disappear into the selected symbol; no generic spinner
            // and no card-scale pulse are introduced.
            for index in 0..<3 {
                let orbit = CAShapeLayer()
                orbit.frame = container.bounds
                let inset = CGFloat(5 + index * 4)
                orbit.path = CGPath(ellipseIn: container.bounds.insetBy(dx: inset, dy: inset),
                                    transform: nil)
                orbit.fillColor = nil
                orbit.strokeColor = tint.withAlphaComponent(0.78 - CGFloat(index) * 0.14).cgColor
                orbit.lineWidth = index == 1 ? 1.15 : 0.85
                orbit.lineCap = .round
                orbit.strokeStart = 0
                orbit.strokeEnd = 0
                orbit.opacity = 0
                orbit.shadowColor = tint.cgColor
                orbit.shadowOpacity = index == 1 ? 0.24 : 0.10
                orbit.shadowRadius = index == 1 ? 2.6 : 1.4
                orbit.shadowOffset = .zero
                container.layer?.addSublayer(orbit)
                structureLayers.append(orbit)
            }
        case .voicePipeline(let stage):
            for (index, path) in voicePipelineContourPaths(
                in: container.bounds, stage: stage
            ).enumerated() {
                let filament = CAShapeLayer()
                filament.frame = container.bounds
                filament.path = path
                filament.fillColor = nil
                filament.strokeColor = tint.withAlphaComponent(index == 0 ? 0.82 : 0.48).cgColor
                filament.lineWidth = index == 0 ? 1.30 : 0.84
                filament.lineCap = .round
                filament.lineJoin = .round
                filament.strokeStart = 0
                filament.strokeEnd = 0
                filament.opacity = 0
                filament.shadowColor = tint.cgColor
                filament.shadowOpacity = index == 0 ? 0.28 : 0.14
                filament.shadowRadius = index == 0 ? 2.8 : 1.6
                filament.shadowOffset = .zero
                container.layer?.insertSublayer(filament, at: 0)
                structureLayers.append(filament)
            }
        case .settleToLayer:
            let seam = CAShapeLayer()
            seam.frame = container.bounds
            let path = CGMutablePath()
            path.move(to: CGPoint(x: container.bounds.midX - 13,
                                  y: container.bounds.midY))
            path.addLine(to: CGPoint(x: container.bounds.midX + 13,
                                     y: container.bounds.midY))
            seam.path = path
            seam.fillColor = nil
            seam.strokeColor = tint.withAlphaComponent(0.76).cgColor
            seam.lineWidth = 1.2
            seam.lineCap = .round
            seam.opacity = 0
            seam.shadowColor = tint.cgColor
            seam.shadowOpacity = 0.20
            seam.shadowRadius = 2.2
            seam.shadowOffset = .zero
            container.layer?.addSublayer(seam)
            settleSeam = seam
        case .ordinary:
            break
        }

        let begin = timelineStart + delay
        let standard = CAMediaTimingFunction(controlPoints: 0.20, 0, 0, 1)
        let decelerate = CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
        let accelerate = CAMediaTimingFunction(controlPoints: 0.30, 0, 1, 1)
        func spatialValue(x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0,
                          scale: CGFloat = 1, scaleX: CGFloat = 1, scaleY: CGFloat = 1,
                          rotateX: CGFloat = 0, rotateY: CGFloat = 0,
                          rotateZ: CGFloat = 0,
                          perspective: CGFloat = 340) -> NSValue {
            NSValue(caTransform3D: spatialTransform(
                x: x, y: y, z: z, scale: scale, scaleX: scaleX, scaleY: scaleY,
                rotateX: rotateX, rotateY: rotateY, rotateZ: rotateZ,
                perspective: perspective
            ))
        }
        func opacity(_ values: [Float], _ times: [NSNumber], _ target: CALayer?,
                     _ timing: CAMediaTimingFunction, _ key: String,
                     duration localDuration: CFTimeInterval? = nil,
                     begin localBegin: CFTimeInterval? = nil) {
            addConnectedKeyframes(keyPath: "opacity", values: values, keyTimes: times,
                                  duration: localDuration ?? duration,
                                  beginTime: localBegin ?? begin, timing: timing,
                                  to: target, key: key)
        }
        func transforms(_ values: [NSValue], _ times: [NSNumber], _ target: CALayer?,
                        _ timing: CAMediaTimingFunction, _ key: String,
                        duration localDuration: CFTimeInterval? = nil,
                        begin localBegin: CFTimeInterval? = nil) {
            addConnectedKeyframes(keyPath: "transform", values: values, keyTimes: times,
                                  duration: localDuration ?? duration,
                                  beginTime: localBegin ?? begin, timing: timing,
                                  to: target, key: key)
        }

        switch motion {
        case .layerRebuild(let direction):
            let sign: CGFloat = direction >= 0 ? 1 : -1
            opacity([outgoingOpacity, outgoingOpacity, 0, 0],
                    [0, 0.14, 0.31, 1], front.layer, accelerate, "layerOld")
            transforms([
                spatialValue(),
                spatialValue(z: 3, scale: 1.04, rotateY: sign * 0.18),
                spatialValue(z: -14, scale: 0.72, rotateY: sign * 1.05),
            ], [0, 0.18, 1], front.layer, accelerate, "layerOldDepth")
            opacity([0, 0, 0.22, 1], [0, 0.61, 0.75, 1],
                    back.layer, decelerate, "layerNew")
            transforms([
                spatialValue(z: -13, scale: 0.70, rotateY: -sign * 0.92),
                spatialValue(z: 4, scale: 1.045, rotateY: -sign * 0.12),
                spatialValue(),
            ], [0, 0.78, 1], back.layer, decelerate, "layerNewDepth")

            if let sheetRig {
                transforms([
                    spatialValue(z: -3, scale: 0.88, rotateX: -0.08,
                                 rotateY: sign * 0.08, perspective: 270),
                    spatialValue(z: 11, scale: 1.08, rotateX: -0.16,
                                 rotateY: sign * 0.42, perspective: 270),
                    spatialValue(z: 8, scale: 1.05, rotateX: 0.12,
                                 rotateY: -sign * 0.31, perspective: 270),
                    spatialValue(z: 0, scale: 0.96, rotateY: 0, perspective: 270),
                ], [0, 0.34, 0.68, 1], sheetRig, standard, "layerRigOrbit")
            }

            let offsets: [CGFloat] = [-6.4, 0, 6.4]
            let depths: [CGFloat] = [12, 1.5, -9]
            for (index, sheet) in structureLayers.enumerated() {
                let stagger = Double(index) * 0.012
                let localBegin = begin + stagger
                let localDuration = duration - stagger
                transforms([
                    spatialValue(scale: 0.82, perspective: 270),
                    spatialValue(x: sign * CGFloat(index - 1) * 1.8,
                                 y: offsets[index], z: depths[index],
                                 scale: 1.02, rotateX: CGFloat(index - 1) * -0.12,
                                 rotateY: sign * CGFloat(index - 1) * 0.10,
                                 perspective: 270),
                    spatialValue(x: -sign * CGFloat(index - 1) * 1.8,
                                 y: -offsets[index], z: -depths[index],
                                 scale: 1.02, rotateX: CGFloat(index - 1) * 0.12,
                                 rotateY: -sign * CGFloat(index - 1) * 0.10,
                                 perspective: 270),
                    spatialValue(scale: 0.88, perspective: 270),
                ], [0, 0.35, 0.67, 1], sheet, standard, "layerSheetMove\(index)",
                   duration: localDuration, begin: localBegin)
                opacity([0, 0.96, 0.88, 0], [0, 0.17, 0.76, 1],
                        sheet, standard, "layerSheetOpacity\(index)",
                        duration: localDuration, begin: localBegin)
            }

        case .applicationArrival:
            opacity([outgoingOpacity, outgoingOpacity * 0.64, 0], [0, 0.28, 1],
                    front.layer, standard, "appOld")
            transforms([
                spatialValue(),
                spatialValue(z: -18, scale: 0.54, rotateX: 0.92, rotateZ: -0.10,
                             perspective: 285),
            ], [0, 1], front.layer, accelerate, "appOldFocus")
            opacity([0, 0, 0.74, 1], [0, 0.22, 0.52, 1], back.layer, decelerate, "appNew")
            transforms([
                spatialValue(z: -30, scale: 0.38, rotateX: -1.18,
                             rotateY: 0.32, rotateZ: 0.16, perspective: 285),
                spatialValue(z: 7, scale: 1.075, rotateX: 0.08,
                             rotateY: -0.04, rotateZ: -0.025, perspective: 285),
                spatialValue(z: 0, scale: 1, perspective: 285),
            ], [0, 0.76, 1], back.layer, decelerate, "appNewFocus")
            let maxRadius = hypot(container.bounds.width, container.bounds.height) * 0.54
            let radii: [CGFloat] = [1.2, maxRadius * 0.46, maxRadius]
            let paths = radii.map { radius in
                CGPath(ellipseIn: CGRect(x: container.bounds.midX - radius,
                                         y: container.bounds.midY - radius,
                                         width: radius * 2, height: radius * 2),
                       transform: nil)
            }
            addConnectedKeyframes(keyPath: "path", values: paths, keyTimes: [0, 0.54, 1],
                                  duration: duration, beginTime: begin, timing: decelerate,
                                  to: apertureMask, key: "appAperture")
            for (index, orbit) in structureLayers.enumerated() {
                let radiusScale = 0.78 + CGFloat(index) * 0.18
                let orbitPaths = radii.map { radius in
                    let r = radius * radiusScale
                    return CGPath(ellipseIn: CGRect(x: container.bounds.midX - r,
                                                    y: container.bounds.midY - r,
                                                    width: r * 2, height: r * 2),
                                  transform: nil)
                }
                let stagger = Double(index) * 0.014
                let localBegin = begin + stagger
                let localDuration = duration - stagger
                addConnectedKeyframes(keyPath: "path", values: orbitPaths,
                                      keyTimes: [0, 0.50, 1], duration: localDuration,
                                      beginTime: localBegin, timing: decelerate,
                                      to: orbit, key: "appOrbitPath\(index)")
                addConnectedKeyframes(keyPath: "strokeEnd", values: [0.08, 0.78, 1],
                                      keyTimes: [0, 0.62, 1], duration: localDuration,
                                      beginTime: localBegin, timing: standard,
                                      to: orbit, key: "appOrbitDraw\(index)")
                opacity([0, index == 1 ? 0.76 : 0.52, 0], [0, 0.46, 1],
                        orbit, standard, "appOrbitOpacity\(index)",
                        duration: localDuration, begin: localBegin)
                transforms([
                    spatialValue(z: -8, scale: 0.42,
                                 rotateX: 1.10 - CGFloat(index) * 0.12,
                                 rotateZ: CGFloat(index - 1) * 0.42, perspective: 270),
                    spatialValue(z: 5, scale: 1.06,
                                 rotateX: 0.34 - CGFloat(index) * 0.06,
                                 rotateZ: CGFloat(index - 1) * -0.18, perspective: 270),
                    spatialValue(scale: 1.18, rotateX: 0,
                                 rotateZ: CGFloat(index - 1) * 0.10, perspective: 270),
                ], [0, 0.62, 1], orbit, decelerate, "appOrbitSpatial\(index)",
                   duration: localDuration, begin: localBegin)
            }

        case .appWheelWave:
            // The old semantic object yields quickly, then the nine real symbol components travel
            // through a diagonal relay. No whole-icon pop occurs: each destination establishes
            // itself, overshoots by less than one logical pixel, and settles inside 280 ms.
            opacity([outgoingOpacity, outgoingOpacity * 0.66, 0, 0],
                    [0, 0.16, 0.40, 1], front.layer, accelerate, "wheelOld")
            transforms([
                spatialValue(perspective: 330),
                spatialValue(y: 0.7, z: -7, scale: 0.86,
                             rotateX: 0.16, perspective: 330),
            ], [0, 1], front.layer, accelerate, "wheelOldSettle",
                       duration: duration * 0.42, begin: begin)

            // The complete destination snapshot only enters during the landing overlap. Until
            // then the user sees the nine independently moving pieces, not an icon hidden below
            // them. This last crossfade also makes the proxy → permanent-view handoff pixel exact.
            opacity([0, 0, 1], [0, 0.82, 1], back.layer, standard, "wheelExactLanding")

            // Row-major layer indexes mapped onto a diagonal wave. Every rank is unique, so the
            // nine dots appear one by one instead of three rows blinking in unison.
            let relayRank = [0, 2, 5,
                             1, 4, 7,
                             3, 6, 8]
            for (index, dot) in appWheelDots.enumerated() {
                let rank = relayRank[index]
                let appear = 0.030 + Double(rank) * 0.0115
                let crest = appear + 0.050
                let settle = min(0.205, crest + 0.044)
                let appearT = NSNumber(value: appear / duration)
                let crestT = NSNumber(value: crest / duration)
                let settleT = NSNumber(value: settle / duration)
                opacity([0, 0, 0.44, 1, 1, 0],
                        [0, appearT, NSNumber(value: (appear + 0.020) / duration),
                         crestT, 0.82, 1], dot, decelerate,
                        "wheelDotOpacity\(index)")
                transforms([
                    spatialValue(y: -1.7, z: -3, scale: 0.24, perspective: 300),
                    spatialValue(y: -1.7, z: -3, scale: 0.24, perspective: 300),
                    spatialValue(y: 0.55, z: 3.5, scale: 1.13, perspective: 300),
                    spatialValue(perspective: 300),
                    spatialValue(perspective: 300),
                ], [0, appearT, crestT, settleT, 1], dot, decelerate,
                           "wheelDotRelay\(index)")
            }

        case .actionImpulse(let requestedCount):
            opacity([outgoingOpacity, outgoingOpacity * 0.42, 0], [0, 0.24, 1],
                    front.layer, standard, "actionOld")
            transforms([
                spatialValue(),
                spatialValue(y: -1.5, z: -19, scale: 0.70,
                             rotateX: 0.48, rotateY: -0.14, perspective: 255),
            ], [0, 1], front.layer, accelerate, "actionOldCompress")
            opacity([0, 0.72, 1], [0, 0.36, 1], back.layer, decelerate, "actionNew")
            transforms([
                spatialValue(y: 1.8, z: 22, scale: 0.58,
                             rotateX: -0.62, rotateY: 0.16, perspective: 255),
                spatialValue(y: -0.35, z: 4, scale: 1.085,
                             rotateX: 0.06, rotateY: -0.025, perspective: 255),
                spatialValue(perspective: 255),
            ], [0, 0.70, 1],
                       back.layer, decelerate, "actionNewImpulse")
            let count = max(1, min(3, requestedCount))
            for index in 0..<count {
                let stagger = Double(index) * 0.026
                let localBegin = begin + stagger
                let localDuration = duration - stagger
                let radii: [CGFloat] = [4.2, 10.8, 18.2]
                let paths = radii.map { radius in
                    CGPath(ellipseIn: CGRect(x: container.bounds.midX - radius,
                                             y: container.bounds.midY - radius,
                                             width: radius * 2, height: radius * 2),
                           transform: nil)
                }
                addConnectedKeyframes(keyPath: "path", values: paths,
                                      keyTimes: [0, 0.46, 1], duration: localDuration,
                                      beginTime: localBegin, timing: decelerate,
                                      to: structureLayers[index], key: "actionRingPath\(index)")
                opacity([0, 0.58, 0], [0, 0.26, 1], structureLayers[index], standard,
                        "actionRingOpacity\(index)", duration: localDuration,
                        begin: localBegin)
                transforms([
                    spatialValue(scale: 0.52, rotateX: 0.96,
                                 rotateZ: CGFloat(index) * 0.16, perspective: 245),
                    spatialValue(z: 5, scale: 1.05, rotateX: 0.22,
                                 rotateZ: CGFloat(index) * -0.08, perspective: 245),
                    spatialValue(scale: 1.12, rotateX: 0,
                                 rotateZ: CGFloat(index) * -0.12, perspective: 245),
                ], [0, 0.48, 1], structureLayers[index], decelerate,
                   "actionRingSpatial\(index)", duration: localDuration,
                   begin: localBegin)
            }
            for (index, shard) in impactShards.enumerated() {
                let localBegin = begin + 0.030 + Double(index % 2) * 0.006
                let localDuration = max(0.12, duration - 0.030)
                opacity([0, 0.46, 0], [0, 0.28, 1], shard, standard,
                        "actionShardOpacity\(index)", duration: localDuration,
                        begin: localBegin)
                transforms([
                    spatialValue(scale: 0.48, rotateZ: -0.08, perspective: 260),
                    spatialValue(z: 4, scale: 1.10, rotateZ: 0.03, perspective: 260),
                    spatialValue(scale: 1.34, rotateZ: 0.08, perspective: 260),
                ], [0, 0.42, 1], shard, decelerate,
                   "actionShardSpatial\(index)", duration: localDuration,
                   begin: localBegin)
            }

        case .returnSweep:
            // The old face closes around a left-side hinge. The new Back face swings off the same
            // axis and lands with one restrained counter-rotation, while a drawn arc exposes the
            // path of that hinge. It reads as "go back", not merely "something changed".
            opacity([outgoingOpacity, outgoingOpacity * 0.62, 0], [0, 0.34, 1],
                    front.layer, accelerate, "returnOld")
            transforms([
                spatialValue(perspective: 265),
                spatialValue(x: -5.8, z: -8, scale: 0.84,
                             rotateY: -1.24, rotateZ: -0.06, perspective: 265),
            ], [0, 1], front.layer, accelerate, "returnOldDirection")
            opacity([0, 0.72, 1], [0, 0.38, 1], back.layer, decelerate, "returnNew")
            transforms([
                spatialValue(x: 5.5, z: -10, scale: 0.80,
                             rotateY: 1.18, rotateZ: 0.05, perspective: 265),
                spatialValue(x: -0.9, z: 4, scale: 1.055,
                             rotateY: -0.10, rotateZ: -0.018, perspective: 265),
                spatialValue(perspective: 265),
            ], [0, 0.78, 1],
                       back.layer, decelerate, "returnNewDirection")
            if let trail = returnTrail {
                addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 0.82, 1],
                                      keyTimes: [0, 0.68, 1], duration: duration,
                                      beginTime: begin, timing: standard,
                                      to: trail, key: "returnTrailDraw")
                addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0.12, 0.76],
                                      keyTimes: [0, 0.54, 1], duration: duration,
                                      beginTime: begin, timing: standard,
                                      to: trail, key: "returnTrailErase")
                opacity([0, 0.74, 0], [0, 0.32, 1], trail, standard,
                        "returnTrailOpacity")
                transforms([
                    spatialValue(scale: 0.76, rotateX: 0.56, perspective: 250),
                    spatialValue(z: 5, scale: 1.03, rotateX: 0.12, perspective: 250),
                    spatialValue(scale: 1.08, perspective: 250),
                ], [0, 0.62, 1], trail, decelerate, "returnTrailSpatial")
            }
            installPrismEdgeFlash(in: container, axisX: 0, axisY: 1,
                                  duration: duration, begin: begin)

        case .holdSequence:
            // The stage edge is also the water-reset edge. Expose the destination immediately as a
            // small, foreshortened object instead of hiding it for the first 42% of the animation;
            // this makes the semantic change readable on the same frame while preserving depth.
            opacity([outgoingOpacity, outgoingOpacity * 0.42, 0], [0, 0.30, 1],
                    front.layer, standard, "holdOld")
            transforms([
                spatialValue(perspective: 285),
                spatialValue(y: 5.2, z: -24, scale: 0.68,
                             rotateX: 0.54, perspective: 285),
            ], [0, 1], front.layer, accelerate, "holdOldDepth")
            opacity([0.18, 0.74, 1], [0, 0.38, 1], back.layer, decelerate, "holdNew")
            transforms([
                spatialValue(y: -5.4, z: 20, scale: 0.66,
                             rotateX: -0.64, perspective: 285),
                spatialValue(y: 0.5, z: 4, scale: 1.055,
                             rotateX: 0.06, perspective: 285),
                spatialValue(perspective: 285),
            ], [0, 0.78, 1], back.layer, decelerate, "holdNewDepth")
            for (index, rail) in depthRails.enumerated() {
                let sign: CGFloat = index == 0 ? -1 : 1
                opacity([0, 0.52, 0], [0, 0.44, 1], rail, standard,
                        "holdRailOpacity\(index)")
                transforms([
                    spatialValue(x: -sign * 2.2, scaleY: 0.08,
                                 rotateX: 0.76, perspective: 270),
                    spatialValue(x: sign * 0.8, z: 7, scaleY: 1.12,
                                 rotateX: 0.12, perspective: 270),
                    spatialValue(x: sign * 2.0, scaleY: 0.32,
                                 perspective: 270),
                ], [0, 0.56, 1], rail, decelerate, "holdRailDepth\(index)")
            }

        case .voiceModeSwitch(let direction):
            let sign: CGFloat = direction >= 0 ? 1 : -1
            // The old and new symbols are opposite faces of the same shallow voice selector. The
            // hand-off clears the centre at 90 degrees, avoiding the muddy cross-fade that made
            // earlier icon transitions look like a blur.
            opacity([outgoingOpacity, outgoingOpacity, 0, 0],
                    [0, 0.18, 0.48, 1], front.layer, accelerate, "voiceModeOld")
            transforms([
                spatialValue(perspective: 285),
                spatialValue(z: 6, scale: 1.035, rotateY: sign * 0.34, perspective: 285),
                spatialValue(z: -10, scaleX: 0.07, scaleY: 0.86,
                             rotateY: sign * .pi / 2, perspective: 285),
            ], [0, 0.34, 1], front.layer, accelerate, "voiceModeOldTurn")
            opacity([0, 0, 0.78, 1], [0, 0.28, 0.58, 1],
                    back.layer, decelerate, "voiceModeNew")
            transforms([
                spatialValue(z: -10, scaleX: 0.07, scaleY: 0.86,
                             rotateY: -sign * .pi / 2, perspective: 285),
                spatialValue(z: 6, scale: 1.055, rotateY: -sign * 0.08,
                             perspective: 285),
                spatialValue(perspective: 285),
            ], [0, 0.76, 1], back.layer, decelerate, "voiceModeNewTurn")
            for (index, orbit) in structureLayers.enumerated() {
                let stagger = Double(index) * 0.012
                let localBegin = begin + stagger
                let localDuration = max(0.17, duration - stagger)
                addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 0.68, 1, 1],
                                      keyTimes: [0, 0.38, 0.70, 1], duration: localDuration,
                                      beginTime: localBegin, timing: standard,
                                      to: orbit, key: "voiceModeOrbitDraw\(index)")
                addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0, 0.18, 0.86],
                                      keyTimes: [0, 0.46, 0.72, 1], duration: localDuration,
                                      beginTime: localBegin, timing: standard,
                                      to: orbit, key: "voiceModeOrbitErase\(index)")
                opacity([0, 0.72, 0.48, 0], [0, 0.24, 0.72, 1], orbit, standard,
                        "voiceModeOrbitOpacity\(index)", duration: localDuration,
                        begin: localBegin)
                transforms([
                    spatialValue(scale: 0.64, rotateX: 0.72,
                                 rotateZ: -sign * (0.28 + CGFloat(index) * 0.12), perspective: 260),
                    spatialValue(z: 5, scale: 1.04, rotateX: 0.16,
                                 rotateZ: sign * (0.20 + CGFloat(index) * 0.10), perspective: 260),
                    spatialValue(scale: 1.10, rotateX: 0,
                                 rotateZ: sign * (0.48 + CGFloat(index) * 0.16), perspective: 260),
                ], [0, 0.58, 1], orbit, decelerate, "voiceModeOrbitTurn\(index)",
                           duration: localDuration, begin: localBegin)
            }

        case .voicePipeline(let stage):
            // macOS 13 fallback for the live by-layer Symbols replacement used above. Both exact
            // snapshots meet at the same horizontal signal edge, so the icon becomes its next
            // semantic state instead of cross-fading or behaving like another card.
            let direction: CGFloat = stage.rawValue.isMultiple(of: 2) ? 1 : -1
            opacity([outgoingOpacity, outgoingOpacity, 0, 0],
                    [0, 0.16, 0.48, 1], front.layer, accelerate, "voicePipelineOld")
            transforms([
                spatialValue(perspective: 315),
                spatialValue(z: 4, scaleX: 1.035, scaleY: 0.90,
                             rotateX: direction * 0.16, perspective: 315),
                spatialValue(z: -9, scaleX: 0.78, scaleY: 0.045,
                             rotateX: direction * 1.18, perspective: 315),
            ], [0, 0.30, 1], front.layer, accelerate, "voicePipelineOldFold")
            opacity([0, 0, 0.76, 1], [0, 0.24, 0.58, 1],
                    back.layer, decelerate, "voicePipelineNew")
            transforms([
                spatialValue(z: -9, scaleX: 0.78, scaleY: 0.045,
                             rotateX: -direction * 1.18, perspective: 315),
                spatialValue(z: 5, scaleX: 1.035, scaleY: 1.045,
                             rotateX: -direction * 0.07, perspective: 315),
                spatialValue(perspective: 315),
            ], [0, 0.76, 1], back.layer, decelerate, "voicePipelineNewUnfold")
            for (index, filament) in structureLayers.enumerated() {
                let stagger = Double(index) * 0.018
                let localDuration = max(0.16, duration - stagger)
                addConnectedKeyframes(keyPath: "strokeEnd", values: [0, 0.88, 1],
                                      keyTimes: [0, 0.66, 1], duration: localDuration,
                                      beginTime: begin + stagger, timing: standard,
                                      to: filament, key: "voiceFallbackDraw\(index)")
                addConnectedKeyframes(keyPath: "strokeStart", values: [0, 0.04, 0.76],
                                      keyTimes: [0, 0.58, 1], duration: localDuration,
                                      beginTime: begin + stagger, timing: standard,
                                      to: filament, key: "voiceFallbackErase\(index)")
                opacity([0, 0.86, 0.44, 0], [0, 0.22, 0.72, 1],
                        filament, standard, "voiceFallbackOpacity\(index)",
                        duration: localDuration, begin: begin + stagger)
            }

        case .settleToLayer:
            opacity([outgoingOpacity, outgoingOpacity * 0.70, 0], [0, 0.36, 1],
                    front.layer, standard, "settleOld")
            transforms([
                spatialValue(perspective: 300),
                spatialValue(z: -10, scaleX: 0.76, scaleY: 0.055,
                             rotateX: 0.42, perspective: 300),
            ], [0, 1], front.layer, accelerate, "settleOldDepth")
            opacity([0, 0.72, 1], [0, 0.46, 1], back.layer, decelerate, "settleNew")
            transforms([
                spatialValue(z: 10, scaleX: 0.74, scaleY: 0.06,
                             rotateX: -0.48, perspective: 300),
                spatialValue(z: 3, scale: 1.045, scaleY: 1.04,
                             rotateX: 0.045, perspective: 300),
                spatialValue(perspective: 300),
            ], [0, 0.76, 1], back.layer, decelerate, "settleNewDepth")
            if let seam = settleSeam {
                opacity([0, 0.78, 0.42, 0], [0, 0.34, 0.62, 1], seam, standard,
                        "settleSeamOpacity")
                transforms([
                    spatialValue(scaleX: 0.05, perspective: 300),
                    spatialValue(z: 5, scaleX: 1.08, perspective: 300),
                    spatialValue(scaleX: 0.22, perspective: 300),
                ], [0, 0.52, 1], seam, decelerate, "settleSeamSpatial")
            }

        case .ordinary:
            opacity([outgoingOpacity, 0], [0, 1], front.layer, standard, "semanticOld")
            opacity([0, 1], [0, 1], back.layer, standard, "semanticNew")
        }
        return container
    }

    /// Split the final App Wheel snapshot into its nine authored dots. `contentsRect` references
    /// the full Retina snapshot while each layer occupies only one dot's logical rectangle, so the
    /// pixels, antialiasing, configured weight and palette are exactly the ones AppKit will show at
    /// rest. The normalised centres were measured from the actual 40×40 production image view.
    private func makeAppWheelDotLayers(from snapshot: LabelSnapshot,
                                       in bounds: CGRect) -> [CALayer] {
        let xCentres: [CGFloat] = [0.200, 0.481, 0.768]
        let yCentres: [CGFloat] = [0.231, 0.494, 0.753]
        let side = min(bounds.width, bounds.height) * 0.262
        let pixel = 1 / max(1, snapshot.scale)
        func snap(_ value: CGFloat) -> CGFloat { (value / pixel).rounded() * pixel }

        return yCentres.flatMap { y in
            xCentres.map { x in
                let centre = CGPoint(x: bounds.minX + bounds.width * x,
                                     y: bounds.minY + bounds.height * y)
                let rect = CGRect(x: snap(centre.x - side / 2),
                                  y: snap(centre.y - side / 2),
                                  width: snap(side), height: snap(side))
                    .intersection(bounds)
                let dot = CALayer()
                dot.frame = rect
                dot.contents = snapshot.image
                dot.contentsRect = CGRect(
                    x: (rect.minX - bounds.minX) / bounds.width,
                    y: (rect.minY - bounds.minY) / bounds.height,
                    width: rect.width / bounds.width,
                    height: rect.height / bounds.height
                )
                dot.contentsGravity = .resize
                dot.contentsScale = snapshot.scale
                dot.minificationFilter = .linear
                dot.magnificationFilter = .linear
                dot.opacity = 0
                return dot
            }
        }
    }

    private func layerSheetPath(in bounds: CGRect) -> CGPath {
        let width = bounds.width * 0.58
        let height = bounds.height * 0.25
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX, y: bounds.midY + height / 2))
        path.addLine(to: CGPoint(x: bounds.midX + width / 2, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY - height / 2))
        path.addLine(to: CGPoint(x: bounds.midX - width / 2, y: bounds.midY))
        path.closeSubpath()
        return path
    }

    private func returnArcPath(in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let start = CGPoint(x: bounds.midX + 12.5, y: bounds.midY - 5.5)
        let end = CGPoint(x: bounds.midX - 11.5, y: bounds.midY + 1.5)
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: bounds.midX + 11, y: bounds.midY + 12),
                      control2: CGPoint(x: bounds.midX - 5, y: bounds.midY + 14))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 4.2, y: end.y + 3.8))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 4.6, y: end.y - 3.2))
        return path
    }

    private func spatialTransform(x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0,
                                  scale: CGFloat = 1,
                                  scaleX: CGFloat = 1, scaleY: CGFloat = 1,
                                  rotateX: CGFloat = 0, rotateY: CGFloat = 0,
                                  rotateZ: CGFloat = 0,
                                  perspective: CGFloat = 360) -> CATransform3D {
        var value = CATransform3DIdentity
        value.m34 = -1 / max(1, perspective)
        value = CATransform3DTranslate(value, x, y, z)
        if rotateX != 0 { value = CATransform3DRotate(value, rotateX, 1, 0, 0) }
        if rotateY != 0 { value = CATransform3DRotate(value, rotateY, 0, 1, 0) }
        if rotateZ != 0 { value = CATransform3DRotate(value, rotateZ, 0, 0, 1) }
        value = CATransform3DScale(value, scale * scaleX, scale * scaleY, 1)
        return value
    }

    private func makeSnapshotLayer(_ snapshot: LabelSnapshot, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = snapshot.image
        layer.contentsScale = snapshot.scale
        layer.contentsGravity = .resize
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        return layer
    }

    /// At the exact face handoff, a physical object exposes a lit edge. Three sub-pixel traces
    /// produce a brief spectral bevel without blurring the icon or painting another card gradient.
    private func installPrismEdgeFlash(in container: NSView,
                                       axisX: CGFloat, axisY: CGFloat,
                                       duration: CFTimeInterval,
                                       begin: CFTimeInterval) {
        let vertical = axisY > axisX
        let bounds = container.bounds
        let length = vertical ? min(bounds.height * 0.68, 30) : min(bounds.width * 0.86, 92)
        let basePath = CGMutablePath()
        if vertical {
            basePath.move(to: CGPoint(x: bounds.midX, y: bounds.midY - length / 2))
            basePath.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + length / 2))
        } else {
            basePath.move(to: CGPoint(x: bounds.midX - length / 2, y: bounds.midY))
            basePath.addLine(to: CGPoint(x: bounds.midX + length / 2, y: bounds.midY))
        }

        let traces: [(NSColor, CGFloat, Float)] = [
            (.systemCyan, -0.85, 0.26),
            (.white, 0, 0.88),
            (.systemPink, 0.85, 0.22),
        ]
        for (index, trace) in traces.enumerated() {
            let line = CAShapeLayer()
            line.frame = bounds
            line.path = basePath
            line.strokeColor = trace.0.withAlphaComponent(CGFloat(trace.2)).cgColor
            line.fillColor = nil
            line.lineWidth = index == 1 ? 1.15 : 0.75
            line.lineCap = .round
            line.opacity = 0
            line.shadowColor = trace.0.cgColor
            line.shadowOpacity = index == 1 ? 0.34 : 0.16
            line.shadowRadius = index == 1 ? 2.8 : 1.4
            line.shadowOffset = .zero
            line.transform = CATransform3DMakeTranslation(
                vertical ? trace.1 : 0, vertical ? 0 : trace.1, 0
            )
            container.layer?.addSublayer(line)
            addConnectedKeyframes(
                keyPath: "opacity", values: [0, 0, trace.2, trace.2 * 0.58, 0],
                keyTimes: [0, 0.38, 0.49, 0.57, 1], duration: duration,
                beginTime: begin, timing: CAMediaTimingFunction(name: .easeInEaseOut),
                to: line, key: "prismEdgeOpacity\(index)"
            )
            let scaleKey = vertical ? "transform.scale.y" : "transform.scale.x"
            addConnectedKeyframes(
                keyPath: scaleKey, values: [0.08, 0.72, 1, 0.28],
                keyTimes: [0, 0.40, 0.52, 1], duration: duration,
                beginTime: begin, timing: CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1),
                to: line, key: "prismEdgeScale\(index)"
            )
        }
    }

    private func makeSnapshotView(_ snapshot: LabelSnapshot, frame: CGRect) -> NSImageView {
        let view = NSImageView(frame: frame)
        view.image = NSImage(cgImage: snapshot.image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        return view
    }

    private func animateIconFold(front: NSImageView, back: NSImageView,
                                 direction: CGFloat, duration: CFTimeInterval,
                                 begin: CFTimeInterval, container: NSView) {
        let sign: CGFloat = direction >= 0 ? 1 : -1
        let standard = CAMediaTimingFunction(controlPoints: 0.20, 0, 0, 1)
        let accelerate = CAMediaTimingFunction(controlPoints: 0.30, 0, 1, 1)
        func fold(_ angle: CGFloat, scale: CGFloat = 1) -> NSValue {
            var value = CATransform3DIdentity
            value.m34 = -1 / 420
            value = CATransform3DRotate(value, angle, 0, 1, 0)
            value = CATransform3DScale(value, scale, scale, 1)
            return NSValue(caTransform3D: value)
        }
        addConnectedKeyframes(keyPath: "transform",
                              values: [fold(0), fold(sign * .pi * 0.31, scale: 0.965)],
                              keyTimes: [0, 1], duration: duration, beginTime: begin,
                              timing: accelerate, to: front.layer, key: "iconFoldOld")
        addConnectedKeyframes(keyPath: "opacity", values: [front.alphaValue, 0],
                              keyTimes: [0, 1], duration: duration * 0.66,
                              beginTime: begin, timing: accelerate,
                              to: front.layer, key: "iconFoldOldOpacity")
        addConnectedKeyframes(keyPath: "transform",
                              values: [fold(-sign * .pi * 0.31, scale: 0.965), fold(0)],
                              keyTimes: [0, 1], duration: duration, beginTime: begin,
                              timing: standard, to: back.layer, key: "iconFoldNew")
        addConnectedKeyframes(keyPath: "opacity", values: [0, 0.58, 1],
                              keyTimes: [0, 0.42, 1], duration: duration,
                              beginTime: begin, timing: standard,
                              to: back.layer, key: "iconFoldNewOpacity")
    }

    private func animateLabelPageTurn(front: NSImageView, back: NSImageView,
                                      direction: CGFloat, duration: CFTimeInterval,
                                      begin: CFTimeInterval, container: NSView) {
        let sign: CGFloat = direction >= 0 ? 1 : -1
        let standard = CAMediaTimingFunction(controlPoints: 0.20, 0, 0, 1)
        let accelerate = CAMediaTimingFunction(controlPoints: 0.30, 0, 1, 1)
        func page(_ angle: CGFloat, y: CGFloat, z: CGFloat = 0,
                  scale: CGFloat = 1) -> NSValue {
            var value = CATransform3DIdentity
            value.m34 = -1 / 520
            value = CATransform3DTranslate(value, 0, y, z)
            value = CATransform3DRotate(value, angle, 1, 0, 0)
            value = CATransform3DScale(value, scale, scale, 1)
            return NSValue(caTransform3D: value)
        }
        // Swap the two exact snapshots while both are at the same 56° foreshortening. Keeping the
        // faces mutually exclusive avoids a double-exposed word, while stopping short of 90°
        // avoids a visibly empty edge-on frame on a compact, frequently changing surface.
        addConnectedKeyframes(keyPath: "transform",
                              values: [page(0, y: 0),
                                       page(-sign * .pi * 0.31, y: sign * 1.7,
                                            z: 6.5, scale: 0.98),
                                       page(-sign * .pi * 0.31, y: sign * 1.7,
                                            z: 6.5, scale: 0.98)],
                              keyTimes: [0, 0.50, 1], duration: duration, beginTime: begin,
                              timing: accelerate, to: front.layer, key: "labelTurnOld")
        addConnectedKeyframes(keyPath: "opacity",
                              values: [front.alphaValue, front.alphaValue, 0, 0],
                              keyTimes: [0, 0.48, 0.50, 1], duration: duration,
                              beginTime: begin, timing: CAMediaTimingFunction(name: .linear),
                              to: front.layer, key: "labelTurnOldOpacity")
        addConnectedKeyframes(keyPath: "transform",
                              values: [page(sign * .pi * 0.31, y: -sign * 1.7,
                                            z: 6.5, scale: 0.98),
                                       page(sign * .pi * 0.31, y: -sign * 1.7,
                                            z: 6.5, scale: 0.98),
                                       page(0, y: 0)],
                              keyTimes: [0, 0.50, 1], duration: duration, beginTime: begin,
                              timing: standard, to: back.layer, key: "labelTurnNew")
        addConnectedKeyframes(keyPath: "opacity", values: [0, 0, 1, 1],
                              keyTimes: [0, 0.48, 0.50, 1], duration: duration,
                              beginTime: begin, timing: CAMediaTimingFunction(name: .linear),
                              to: back.layer, key: "labelTurnNewOpacity")
    }

    private func makeSnapshotFallback(outgoing: NSView, incoming: NSView, in container: NSView,
                                      outgoingOpacity: Float, duration: CFTimeInterval,
                                      delay: CFTimeInterval,
                                      timelineStart: CFTimeInterval) -> NSView {
        let destination: NSView
        if let icon = incoming as? NSImageView {
            destination = copiedIconView(icon)
        } else if let label = incoming as? NSTextField {
            destination = copiedLabel(label)
        } else {
            destination = NSView(frame: incoming.bounds)
        }
        outgoing.frame = container.bounds
        destination.frame = container.bounds
        container.addSubview(outgoing)
        container.addSubview(destination)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.layer?.opacity = 0
        destination.layer?.opacity = 1
        CATransaction.commit()
        let begin = timelineStart + delay
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        addConnectedKeyframes(keyPath: "opacity", values: [outgoingOpacity, 0],
                              keyTimes: [0, 1], duration: duration, beginTime: begin,
                              timing: timing, to: outgoing.layer, key: "snapshotFallbackOld")
        addConnectedKeyframes(keyPath: "opacity", values: [0, 1], keyTimes: [0, 1],
                              duration: duration, beginTime: begin, timing: timing,
                              to: destination.layer, key: "snapshotFallbackNew")
        return container
    }

    /// Characters found in both strings are one persistent object that moves to its new slot.
    /// Only inserted/removed characters fold through the horizontal midline. This makes a title
    /// change readable as a transformation, not two words cross-fading through one another.
    @discardableResult
    private func makeGlyphRelay(outgoing: NSTextField, incoming: NSTextField,
                                outgoingOpacity: Float, direction: CGFloat,
                                duration: CFTimeInterval, delay: CFTimeInterval,
                                timelineStart: CFTimeInterval) -> NSView {
        let container = NSView(frame: incoming.frame.insetBy(dx: -2, dy: -2))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.contentsScale = surface.panel.backingScaleFactor
        // Capture the real AppKit labels before reparenting anything. Every animated character is
        // a pixel-exact slice of these images, so the last proxy frame is indistinguishable from
        // the permanent raster layer that remains after the animation.
        let oldSnapshot = makeLabelSnapshot(outgoing)
        let newSnapshot = makeLabelSnapshot(incoming)
        outgoing.removeFromSuperview()
        let oldGlyphs = glyphLayout(for: outgoing)
        let newGlyphs = glyphLayout(for: incoming)
        // A repeated letter several slots away is not a meaningful shared element; retaining it
        // makes unrelated words appear to scatter. Only nearby matches earn connected motion.
        let nearbyMatches = longestCommonGlyphs(oldGlyphs.map(\.text), newGlyphs.map(\.text)).filter {
            abs(oldGlyphs[$0.0].x - newGlyphs[$0.1].x) <= 12
        }
        // One isolated shared letter reads as a typo suspended between two otherwise unrelated
        // titles. Connected typography starts only when at least a pair can carry the word shape.
        let matches = nearbyMatches.count >= 2 ? nearbyMatches : []
        let matchedOld = Set(matches.map(\.0))
        let matchedNew = Set(matches.map(\.1))
        let begin = timelineStart + delay
        let timing = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0)
        let contentOffset = CGPoint(x: 2, y: 2)

        for (oldIndex, newIndex) in matches {
            let oldGlyph = oldGlyphs[oldIndex]
            let newGlyph = newGlyphs[newIndex]
            let glyphLayer = makeGlyphLayer(newGlyph, source: incoming, offset: contentOffset,
                                            snapshot: newSnapshot,
                                            isLast: newIndex == newGlyphs.count - 1)
            container.layer?.addSublayer(glyphLayer)
            let dx = oldGlyph.x - newGlyph.x
            addConnectedKeyframes(
                keyPath: "transform", values: [
                    NSValue(caTransform3D: lensTransform(x: dx, scaleX: 1, scaleY: 1)),
                    NSValue(caTransform3D: lensTransform(x: dx * 0.28, scaleX: 0.96,
                                                        scaleY: 1.05)),
                    NSValue(caTransform3D: CATransform3DIdentity),
                ], keyTimes: [0, 0.64, 1], duration: duration,
                beginTime: begin + glyphRelayStagger(newIndex),
                timing: timing, to: glyphLayer, key: "glyphRetain"
            )
        }

        for index in oldGlyphs.indices where !matchedOld.contains(index) {
            let glyph = oldGlyphs[index]
            let glyphLayer = makeGlyphLayer(glyph, source: outgoing, offset: contentOffset,
                                            snapshot: oldSnapshot,
                                            isLast: index == oldGlyphs.count - 1)
            container.layer?.addSublayer(glyphLayer)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyphLayer.opacity = 0
            CATransaction.commit()
            addConnectedKeyframes(
                keyPath: "opacity", values: [outgoingOpacity, outgoingOpacity * 0.86, 0],
                keyTimes: [0, 0.30, 1], duration: duration * 0.58,
                beginTime: begin + glyphRelayStagger(index),
                timing: timing, to: glyphLayer, key: "glyphOldOpacity"
            )
            addConnectedKeyframes(
                keyPath: "transform", values: [
                    NSValue(caTransform3D: CATransform3DIdentity),
                    NSValue(caTransform3D: lensTransform(x: -direction * 0.8,
                                                        scaleX: 1.04, scaleY: 0.74)),
                    NSValue(caTransform3D: lensTransform(x: -direction * 2.8,
                                                        scaleX: 0.76, scaleY: 0.08)),
                ], keyTimes: [0, 0.35, 1], duration: duration * 0.58,
                beginTime: begin + glyphRelayStagger(index),
                timing: timing, to: glyphLayer, key: "glyphOldFold"
            )
        }

        for index in newGlyphs.indices where !matchedNew.contains(index) {
            let glyph = newGlyphs[index]
            let glyphLayer = makeGlyphLayer(glyph, source: incoming, offset: contentOffset,
                                            snapshot: newSnapshot,
                                            isLast: index == newGlyphs.count - 1)
            container.layer?.addSublayer(glyphLayer)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyphLayer.opacity = 1
            CATransaction.commit()
            let glyphBegin = begin + duration * 0.42 + glyphRelayStagger(index)
            addConnectedKeyframes(
                keyPath: "opacity", values: [0, 0.08, 1], keyTimes: [0, 0.24, 1],
                duration: duration * 0.68, beginTime: glyphBegin,
                timing: timing, to: glyphLayer, key: "glyphNewOpacity"
            )
            addConnectedKeyframes(
                keyPath: "transform", values: [
                    NSValue(caTransform3D: lensTransform(x: direction * 2.8,
                                                        scaleX: 0.76, scaleY: 0.08)),
                    NSValue(caTransform3D: lensTransform(x: direction * 0.45,
                                                        scaleX: 1.035, scaleY: 1.08)),
                    NSValue(caTransform3D: CATransform3DIdentity),
                ], keyTimes: [0, 0.72, 1], duration: duration * 0.68,
                beginTime: glyphBegin, timing: timing, to: glyphLayer,
                key: "glyphNewUnfold"
            )
        }

        surface.contentView.addSubview(container)
        return container
    }

    private struct GlyphLayoutItem {
        let text: String
        let x: CGFloat
        let width: CGFloat
    }

    private struct LabelSnapshot {
        let image: CGImage
        let scale: CGFloat
    }

    private func glyphLayout(for label: NSTextField) -> [GlyphLayoutItem] {
        let text = label.stringValue
        guard !text.isEmpty else { return [] }
        let font = label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        var result: [GlyphLayoutItem] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let startOffset = index.utf16Offset(in: text)
            let endOffset = next.utf16Offset(in: text)
            let x = CGFloat(CTLineGetOffsetForStringIndex(line, startOffset, nil))
            let nextX = CGFloat(CTLineGetOffsetForStringIndex(line, endOffset, nil))
            result.append(GlyphLayoutItem(text: String(text[index..<next]),
                                          x: x, width: max(0, nextX - x)))
            index = next
        }
        return result
    }

    private func makeViewSnapshot(_ source: NSView) -> LabelSnapshot? {
        let bounds = source.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var result: LabelSnapshot?
        // Ask AppKit for the exact backing-store representation it already uses for this label.
        // Unlike a hand-built bitmap context, this retains the window's real Retina scale,
        // baseline, font smoothing and cell insets. AppKit skips a view whose backing-layer model
        // opacity is zero, so restore that model value only inside this disabled-actions
        // transaction. It is returned to its original value before Core Animation can commit a
        // frame, making the semantic label drawable for caching but never visible on screen.
        // Resolve semantic colours inside this label's effective material appearance. Without
        // this scope an offscreen animation snapshot can accidentally inherit whichever unrelated
        // AppKit view drew most recently, producing white glyphs for a light material.
        source.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let bitmap = source.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            let originalOpacity = source.layer?.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            source.layer?.opacity = 1
            source.cacheDisplay(in: bounds, to: bitmap)
            source.layer?.opacity = originalOpacity ?? 1
            CATransaction.commit()
            guard let image = bitmap.cgImage else { return }
            let scale = max(1, CGFloat(image.width) / max(1, bounds.width))
            result = LabelSnapshot(image: image, scale: scale)
        }
        return result
    }

    private func makeLabelSnapshot(_ source: NSTextField) -> LabelSnapshot? {
        makeViewSnapshot(source)
    }

    private func resolvedMaterialColor(_ color: NSColor) -> NSColor {
        var result = color
        surface.cardView.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB) ?? color
        }
        return result
    }

    /// The fast path is a pixel slice of the real NSTextField, rather than a separately rendered
    /// CATextLayer. Besides being lightweight, this guarantees identical kerning, baseline,
    /// antialiasing and font weight at the handoff. The text-layer fallback is only for the highly
    /// unusual case where AppKit cannot provide a cache bitmap.
    private func makeGlyphLayer(_ glyph: GlyphLayoutItem, source: NSTextField,
                                offset: CGPoint, snapshot: LabelSnapshot?,
                                isLast: Bool) -> CALayer {
        if let snapshot = snapshot {
            let pixelWidth = snapshot.image.width
            let startPixel = max(0, min(pixelWidth,
                Int(floor(glyph.x * snapshot.scale))))
            let naturalEnd = Int(floor((glyph.x + glyph.width) * snapshot.scale))
            let endPixel = max(startPixel, min(pixelWidth,
                isLast ? pixelWidth : naturalEnd))
            let slice = CALayer()
            guard startPixel < endPixel else {
                slice.frame = CGRect(x: offset.x + glyph.x, y: offset.y,
                                     width: 0, height: source.bounds.height)
                return slice
            }
            slice.contents = snapshot.image
            slice.contentsRect = CGRect(x: CGFloat(startPixel) / CGFloat(pixelWidth), y: 0,
                                        width: CGFloat(endPixel - startPixel)
                                            / CGFloat(pixelWidth),
                                        height: 1)
            slice.contentsGravity = .resize
            slice.contentsScale = snapshot.scale
            slice.minificationFilter = .linear
            slice.magnificationFilter = .linear
            slice.frame = CGRect(x: offset.x + CGFloat(startPixel) / snapshot.scale,
                                 y: offset.y,
                                 width: CGFloat(endPixel - startPixel) / snapshot.scale,
                                 height: source.bounds.height)
            return slice
        }

        let glyphLayer = CATextLayer()
        let font = source.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let foreground = resolvedMaterialColor(source.textColor ?? .labelColor)
        glyphLayer.string = NSAttributedString(
            string: glyph.text,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
            ]
        )
        glyphLayer.frame = CGRect(x: offset.x + glyph.x, y: offset.y,
                                  width: glyph.width + 1.5, height: source.frame.height)
        glyphLayer.contentsScale = surface.panel.backingScaleFactor
        glyphLayer.alignmentMode = .left
        glyphLayer.truncationMode = .none
        glyphLayer.isWrapped = false
        glyphLayer.allowsFontSubpixelQuantization = true
        return glyphLayer
    }

    /// The relay wave saturates after seven slots. Long labels therefore retain the same visual
    /// rhythm without extending their tail beyond the fixed cleanup/handoff boundary.
    private func glyphRelayStagger(_ index: Int) -> CFTimeInterval {
        min(Double(index), 7) * 0.003
    }

    private func longestCommonGlyphs(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1),
                          count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [(Int, Int)] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// The secondary line follows the title instead of competing with it. A short clipped roll is
    /// enough to establish direction while keeping the entire component spatially stationary.
    @discardableResult
    private func makeSharedAxisRoll(outgoing: NSTextField, incoming: NSTextField,
                                    outgoingOpacity: Float, direction: CGFloat,
                                    duration: CFTimeInterval, delay: CFTimeInterval,
                                    timelineStart: CFTimeInterval) -> NSView {
        let container = NSView(frame: incoming.frame.insetBy(dx: -1, dy: -2))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        outgoing.removeFromSuperview()
        let oldLabel = copiedLabel(outgoing)
        let newLabel = copiedLabel(incoming)
        oldLabel.frame = NSRect(x: 1, y: 2, width: incoming.frame.width,
                                height: incoming.frame.height)
        newLabel.frame = oldLabel.frame
        container.addSubview(oldLabel)
        container.addSubview(newLabel)
        let begin = timelineStart + delay
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.20, 1.0)
        let travel = direction * 5.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldLabel.layer?.opacity = 0
        newLabel.layer?.opacity = 1
        CATransaction.commit()
        addConnectedKeyframes(keyPath: "opacity", values: [outgoingOpacity, 0],
                              keyTimes: [0, 1], duration: duration * 0.62,
                              beginTime: begin, timing: timing, to: oldLabel.layer,
                              key: "subtitleOldOpacity")
        addConnectedKeyframes(
            keyPath: "transform", values: [
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DMakeTranslation(0, travel, 0)),
            ], keyTimes: [0, 1], duration: duration * 0.62, beginTime: begin,
            timing: timing, to: oldLabel.layer, key: "subtitleOldRoll"
        )
        addConnectedKeyframes(keyPath: "opacity", values: [0, 1], keyTimes: [0, 1],
                              duration: duration * 0.66, beginTime: begin + duration * 0.25,
                              timing: timing, to: newLabel.layer,
                              key: "subtitleNewOpacity")
        addConnectedKeyframes(
            keyPath: "transform", values: [
                NSValue(caTransform3D: CATransform3DMakeTranslation(0, -travel, 0)),
                NSValue(caTransform3D: CATransform3DIdentity),
            ], keyTimes: [0, 1], duration: duration * 0.66,
            beginTime: begin + duration * 0.25, timing: timing,
            to: newLabel.layer, key: "subtitleNewRoll"
        )
        surface.contentView.addSubview(container)
        return container
    }

    private func lensTransform(x: CGFloat, scaleX: CGFloat,
                               scaleY: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(x, 0, 0)
        transform = CATransform3DScale(transform, scaleX, scaleY, 1)
        return transform
    }

    private func addConnectedKeyframes(keyPath: String, values: [Any],
                                       keyTimes: [NSNumber], duration: CFTimeInterval,
                                       beginTime: CFTimeInterval,
                                       timing: CAMediaTimingFunction, to layer: CALayer?,
                                       key: String) {
        guard let layer = layer else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.beginTime = layer.convertTime(beginTime, from: nil)
        animation.timingFunctions = Array(repeating: timing, count: max(0, keyTimes.count - 1))
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    /// Treat each visual as one two-sided object. The outgoing icon rotates to its 90° edge around
    /// Y exactly as the incoming icon rotates off the reverse face. Text uses the orthogonal X axis
    /// so it reads as a compact vertical page turn rather than another crossfade or scale effect.
    private func animateElementFlip(from proxy: NormalContentProxy?, direction: CGFloat,
                                    animateSubtitle: Bool) {
        guard let proxy = proxy else { return }
        let generation = contentMorphGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let totalDuration: CFTimeInterval = reduceMotion ? 0.16 : 0.34
        let oldOpacities = proxy.views.map {
            $0.layer?.presentation()?.opacity ?? $0.layer?.opacity ?? 1
        }

        let outgoingViews = animateSubtitle
            ? proxy.views : [proxy.iconView, proxy.titleLabel]
        let incomingLayers = animateSubtitle
            ? [surface.iconView.layer, surface.titleLabel.layer, surface.subtitleLabel.layer]
            : [surface.iconView.layer, surface.titleLabel.layer]
        if !animateSubtitle { proxy.subtitleLabel.removeFromSuperview() }

        if reduceMotion {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy.views.forEach { $0.layer?.opacity = 0 }
            CATransaction.commit()
            for (index, oldView) in outgoingViews.enumerated() {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = oldOpacities[index]
                fade.toValue = 0
                fade.duration = totalDuration
                oldView.layer?.add(fade, forKey: "contentMorphOutgoing")
            }
            for layer in incomingLayers.compactMap({ $0 }) {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = totalDuration
                layer.add(fade, forKey: "contentMorphIncoming")
            }
            finishContentMorph(generation: generation, after: totalDuration + 0.04)
            return
        }

        // Build literal front/back pairs inside one temporary layer. The parent layer owns the
        // entire 180° rotation, so both faces are mathematically constrained to one hinge rather
        // than approximating a flip with two independent 90° animations and opacity hand-offs.
        var containers: [NSView] = []
        let iconContainer = makeTwoSidedFlipContainer(
            front: proxy.iconView,
            back: copiedIconView(surface.iconView),
            frame: surface.iconView.frame,
            frontOpacity: oldOpacities[0]
        )
        containers.append(iconContainer)

        let oldLabels = animateSubtitle
            ? [proxy.titleLabel, proxy.subtitleLabel] : [proxy.titleLabel]
        let newLabels = animateSubtitle
            ? [surface.titleLabel, surface.subtitleLabel] : [surface.titleLabel]
        for index in oldLabels.indices {
            let container = makeTwoSidedFlipContainer(
                front: oldLabels[index],
                back: copiedLabel(newLabels[index]),
                frame: newLabels[index].frame,
                frontOpacity: oldOpacities[index + 1]
            )
            containers.append(container)
        }

        // The real destination hierarchy remains underneath and is revealed only after its exact
        // duplicate back face has landed. This removes the crossfade entirely without a final snap.
        for layer in incomingLayers.compactMap({ $0 }) {
            let hidden = CAKeyframeAnimation(keyPath: "opacity")
            hidden.values = [0, 0]
            hidden.keyTimes = [0, 1]
            hidden.duration = totalDuration + 0.055
            layer.add(hidden, forKey: "contentMorphIncoming")
        }

        contentMorphProxyViews = containers
        let iconAngle = CGFloat.pi * direction
        animateTwoSidedContainer(iconContainer, angle: iconAngle,
                                 x: 0, y: 1, duration: totalDuration, delay: 0)
        for (index, container) in containers.dropFirst().enumerated() {
            animateTwoSidedContainer(container, angle: -iconAngle,
                                     x: 1, y: 0, duration: totalDuration,
                                     delay: Double(index) * 0.014)
        }
        finishContentMorph(generation: generation, after: totalDuration + 0.055)
    }

    private func makeTwoSidedFlipContainer(front: NSView, back: NSView, frame: NSRect,
                                           frontOpacity: Float) -> NSView {
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.masksToBounds = false

        front.removeFromSuperview()
        front.frame = container.bounds
        back.frame = container.bounds
        container.addSubview(front)
        container.addSubview(back)
        front.layer?.isDoubleSided = false
        back.layer?.isDoubleSided = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        front.layer?.opacity = frontOpacity
        front.layer?.transform = CATransform3DIdentity
        back.layer?.opacity = 0
        back.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        surface.contentView.addSubview(container)
        return container
    }

    private func animateTwoSidedContainer(_ container: NSView, angle: CGFloat,
                                          x: CGFloat, y: CGFloat,
                                          duration: CFTimeInterval,
                                          delay: CFTimeInterval,
                                          timelineStart: CFTimeInterval? = nil) {
        guard let layer = container.layer else { return }
        let begin = (timelineStart ?? CACurrentMediaTime()) + delay
        let turn = CAKeyframeAnimation(keyPath: "transform")
        turn.values = [flipTransform(angle: 0, x: x, y: y),
                       flipTransform(angle: angle * 0.5, x: x, y: y),
                       flipTransform(angle: -angle * 0.5, x: x, y: y),
                       flipTransform(angle: angle * 0.018, x: x, y: y),
                       flipTransform(angle: 0, x: x, y: y)]
        turn.keyTimes = [0, 0.47, 0.49, 0.86, 1]
        turn.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.72, 0.46),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.18, 0.72, 0.18, 1.0),
            CAMediaTimingFunction(name: .easeOut),
        ]
        turn.duration = duration
        turn.beginTime = layer.convertTime(begin, from: nil)
        turn.fillMode = .backwards
        layer.add(turn, forKey: "twoSidedElementFlip")

        guard let frontLayer = container.subviews.first?.layer,
              let backLayer = container.subviews.last?.layer else { return }
        let frontOpacity = frontLayer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frontLayer.opacity = 0
        backLayer.opacity = 0
        CATransaction.commit()

        // Gate the two faces exactly at the shared 90° edge. The container jumps from +90° to −90°
        // while edge-on, so the destination can return upright without ever drawing mirrored text.
        let frontVisibility = CAKeyframeAnimation(keyPath: "opacity")
        frontVisibility.values = [frontOpacity, frontOpacity, 0, 0]
        frontVisibility.keyTimes = [0, 0.47, 0.49, 1]
        frontVisibility.duration = duration
        frontVisibility.beginTime = frontLayer.convertTime(begin, from: nil)
        frontVisibility.fillMode = .both
        frontVisibility.isRemovedOnCompletion = false
        frontLayer.add(frontVisibility, forKey: "twoSidedFrontVisibility")

        let backVisibility = CAKeyframeAnimation(keyPath: "opacity")
        backVisibility.values = [0, 0, 1, 1]
        backVisibility.keyTimes = [0, 0.47, 0.49, 1]
        backVisibility.duration = duration
        backVisibility.beginTime = backLayer.convertTime(begin, from: nil)
        backVisibility.fillMode = .both
        backVisibility.isRemovedOnCompletion = false
        backLayer.add(backVisibility, forKey: "twoSidedBackVisibility")
    }

    private func flipTransform(angle: CGFloat, x: CGFloat, y: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 360
        return CATransform3DRotate(transform, angle, x, y, 0)
    }

    private func animateCardResponse() {
        // Repeated actions acknowledge on the icon only. The material card and its Layer identity
        // edge are a single fixed-size object and never pulse against one another.
        let iconScale = CAKeyframeAnimation(keyPath: "transform.scale")
        iconScale.values = [0.975, 1.018, 0.998, 1.0]
        iconScale.keyTimes = [0.0, 0.46, 0.76, 1.0]
        iconScale.duration = 0.18
        iconScale.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.22, 1.0)]
        surface.iconView.layer?.add(iconScale, forKey: "statusIconSpring")

        // A flat circular glow used to pulse here. Once the icon folded away it was exposed as a
        // stray coloured dot, so the icon response now carries the feedback by itself.
    }

    // MARK: Whole-card hold progress surface

    private func configureHoldProgressVisualStyle() {
        let bounds = surface.holdProgressContainer.bounds
        let usesWater = holdProgressVisualStyle == .water
        let rimInset: CGFloat = usesWater ? 0.75 : 1.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.holdProgressWaterRoot.opacity = usesWater ? 1 : 0
        surface.holdProgressGlassRoot.opacity = usesWater ? 0 : 1
        surface.holdProgressRim.path = CGPath(
            roundedRect: bounds.insetBy(dx: rimInset, dy: rimInset),
            cornerWidth: cornerRadius - rimInset,
            cornerHeight: cornerRadius - rimInset,
            transform: nil
        )
        surface.holdProgressRim.lineWidth = usesWater ? 1.15 : 2.4
        surface.holdProgressRim.shadowRadius = usesWater ? 0 : 3.2
        surface.holdProgressRim.shadowOpacity = usesWater ? 0 : 0.28
        surface.holdProgressRim.strokeStart = 0
        surface.holdProgressRim.strokeEnd = 1
        surface.holdProgressRim.opacity = 1
        CATransaction.commit()
    }

    private func startHoldProgress(startedAt: CFTimeInterval) {
        holdProgressTimer?.invalidate()
        holdProgressTimer = nil
        // A rapid release→new hold can overlap the previous 140 ms fade. Freeze the current
        // presentation before replacing it so the new surface never inherits an old fade/reveal.
        let visibleOpacity = surface.holdProgressContainer.presentation()?.opacity
            ?? surface.holdProgressContainer.opacity
        surface.holdProgressContainer.removeAnimation(forKey: "compactHoldReveal")
        surface.holdProgressContainer.removeAnimation(forKey: "compactHoldFade")
        isHoldProgressActive = true
        applyHoldContentContrast()
        holdProgressStartedAt = startedAt
        holdProgressLastTick = CACurrentMediaTime()
        holdProgressStage = -1
        holdProgressLevel = 0
        holdProgressDrainStartedAt = nil
        holdProgressDrainFrom = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.holdProgressContainer.opacity = 1
        CATransaction.commit()
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = visibleOpacity
        reveal.toValue = 1
        reveal.duration = 0.15
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.20, 1.0)
        surface.holdProgressContainer.add(reveal, forKey: "compactHoldReveal")

        // The first frame is a real timeline sample, not a cosmetic zero frame. If setup itself was
        // delayed, this resolves straight to the current release action and commits that face with
        // the water state in this same main-loop turn.
        tickHoldProgress()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickHoldProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdProgressTimer = timer
    }

    private func stopHoldProgress(immediate: Bool = false) {
        holdProgressTimer?.invalidate()
        holdProgressTimer = nil
        holdProgressDrainStartedAt = nil
        holdProgressStage = -1
        guard isHoldProgressActive || surface.holdProgressContainer.opacity > 0 else { return }
        isHoldProgressActive = false

        let visibleOpacity = surface.holdProgressContainer.presentation()?.opacity
            ?? surface.holdProgressContainer.opacity
        surface.holdProgressContainer.removeAnimation(forKey: "compactHoldReveal")
        surface.holdProgressContainer.removeAnimation(forKey: "compactHoldFade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.holdProgressContainer.opacity = 0
        CATransaction.commit()
        guard !immediate, visibleOpacity > 0.001 else {
            applyHoldContentContrast()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visibleOpacity
        fade.toValue = 0
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        surface.holdProgressContainer.add(fade, forKey: "compactHoldFade")
        // Keep the same material-driven typography until the progress layer is actually gone. A
        // mid-fade style refresh would otherwise create one muddy frame over the visible fill.
        DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration) { [weak self] in
            guard let self = self, !self.isHoldProgressActive else { return }
            self.applyHoldContentContrast()
        }
    }

    private func tickHoldProgress() {
        guard isHoldProgressActive, enabled, isHolding else {
            stopHoldProgress(immediate: true)
            return
        }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - holdProgressLastTick, 0), 0.05))
        holdProgressLastTick = now
        let elapsed = max(0, now - holdProgressStartedAt)

        // One elapsed sample owns BOTH the visible action and the water. No threshold-specific
        // DispatchWorkItem exists anymore, so main-queue pressure cannot make the icon chase a
        // water surface that has already advanced to another stage.
        let stage = HoldTiming.reachedStageCount(
            elapsed: elapsed, stageDelays: holdStageDelays
        )
        if stage != holdProgressStage {
            let previous = holdProgressStage
            holdProgressStage = stage
            if previous >= 0, stage < holdStages.count {
                holdProgressDrainStartedAt = now
                holdProgressDrainFrom = holdProgressLevel
            } else if stage >= holdStages.count {
                holdProgressDrainStartedAt = nil
                pulseHoldProgressRim()
            }
            synchronizeHoldFace(stage: stage, previousStage: previous)
        }

        if let drainStarted = holdProgressDrainStartedAt {
            let fraction = CGFloat((now - drainStarted) / holdProgressDrainDuration)
            if fraction < 1 {
                holdProgressLevel = holdProgressDrainFrom * (1 - fraction * fraction)
                renderHoldProgress(at: now)
                return
            }
            holdProgressDrainStartedAt = nil
            holdProgressLevel = 0
        }

        let target: CGFloat
        if stage >= holdStages.count {
            target = 1
        } else {
            let segmentStart = stage == 0
                ? min(holdProgressAppearDelay, holdStages[0].threshold)
                : holdStages[stage - 1].threshold
            let segmentEnd = holdStages[stage].threshold
            let fraction = (elapsed - segmentStart) / max(segmentEnd - segmentStart, 0.0001)
            target = CGFloat(min(max(fraction, 0), 1))
        }
        // Frame-rate-independent exponential following: quick enough to read the true boundary,
        // soft enough that timer jitter can never make the visible progress edge chatter.
        let response = 1 - pow(0.72, dt * 60)
        holdProgressLevel += (target - holdProgressLevel) * response
        holdProgressLevel = min(max(holdProgressLevel, 0), 1)
        renderHoldProgress(at: now)
    }

    /// Resolve the face from the exact stage already used by `tickHoldProgress`. A late display tick
    /// presents only the current face with no catch-up animation; a normal adjacent boundary gets
    /// the authored hold transition, beginning in this same compositor transaction as the water.
    private func synchronizeHoldFace(stage: Int, previousStage: Int) {
        let item: HoldItem?
        let subtitle: String
        if stage == 0 {
            item = holdBase
            let nextLabel = holdStages.first.map {
                ActionVisual.resolve($0.item.action, $0.item.presentation,
                                     prefersTargetAppIcon: false).label
            }
            subtitle = nextLabel.map { L("Hold for %@", $0) } ?? L("Keep holding")
        } else if holdStages.indices.contains(stage - 1) {
            item = holdStages[stage - 1].item
            subtitle = item?.isCancel == true ? L("Release to cancel") : L("Release to choose")
        } else {
            item = nil
            subtitle = L("Keep holding")
        }
        guard let item, !isLayerStateAction(item.action), activeHoldKey != item.key else { return }
        let adjacentBoundary = previousStage >= 0 && stage == previousStage + 1
        let animate = previousStage == -1 ? stage == 0 : adjacentBoundary
        presentHold(item, subtitle: subtitle, animated: animate)
    }

    private func renderHoldProgress(at now: CFTimeInterval) {
        switch holdProgressVisualStyle {
        case .water:
            renderWaterHoldProgress(at: now)
        case .glass:
            renderGlassHoldProgress(at: now)
        }
    }

    private func renderWaterHoldProgress(at now: CFTimeInterval) {
        let bounds = surface.holdProgressContainer.bounds
        let elapsed = CGFloat(max(0, now - holdProgressStartedAt))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let edgeCalm = min(holdProgressLevel / 0.055, 1)
        let backAmplitude: CGFloat = reduceMotion ? 0 : 1.80 * edgeCalm
        let frontAmplitude: CGFloat = reduceMotion ? 0 : 2.35 * edgeCalm
        let backPhase = elapsed * 2.45 + 1.10
        let frontPhase = -elapsed * 3.15
        let back = holdWaterPath(in: bounds, level: max(0, holdProgressLevel - 0.025),
                                 amplitude: backAmplitude, cycles: 1.25,
                                 phase: backPhase, crestOnly: false)
        let front = holdWaterPath(in: bounds, level: holdProgressLevel,
                                  amplitude: frontAmplitude, cycles: 1.65,
                                  phase: frontPhase, crestOnly: false)
        let crest = holdWaterPath(in: bounds, level: holdProgressLevel,
                                  amplitude: frontAmplitude, cycles: 1.65,
                                  phase: frontPhase, crestOnly: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.holdProgressBackWave.path = back
        surface.holdProgressFrontWave.path = front
        surface.holdProgressCrest.path = crest
        surface.holdProgressRim.strokeStart = 0
        surface.holdProgressRim.strokeEnd = 1
        surface.holdProgressRim.opacity = 1
        surface.holdProgressRim.shadowOpacity = 0
        CATransaction.commit()
    }

    private func renderGlassHoldProgress(at now: CFTimeInterval) {
        let bounds = surface.holdProgressContainer.bounds
        let elapsed = CGFloat(max(0, now - holdProgressStartedAt))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let progress = holdProgressLevel * holdProgressLevel * (3 - 2 * holdProgressLevel)
        let baseX = -bounds.width * 0.20 + progress * bounds.width * 1.40
        let handoff: CGFloat
        if let drainStarted = holdProgressDrainStartedAt {
            let fraction = min(max(CGFloat((now - drainStarted) / holdProgressDrainDuration), 0), 1)
            handoff = sin(fraction * .pi)
        } else {
            handoff = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in surface.holdProgressGlassBands.enumerated() {
            let bandWidth = 50 + CGFloat(index) * 25
            band.bounds = CGRect(x: 0, y: 0, width: bandWidth,
                                 height: bounds.height * 1.46)
            let drift = reduceMotion ? 0 : sin(elapsed * 0.65 + CGFloat(index)) * 1.6
            band.position = CGPoint(x: baseX - CGFloat(index) * 9 + drift,
                                    y: bounds.midY)
            band.transform = CATransform3DMakeRotation(-0.10 + CGFloat(index) * 0.018,
                                                       0, 0, 1)
            band.opacity = Float(0.47 - CGFloat(index) * 0.065 + handoff * 0.10)
        }
        for (index, caustic) in surface.holdProgressGlassCaustics.enumerated() {
            caustic.path = holdGlassCausticPath(
                in: bounds,
                x: baseX - CGFloat(index) * 8,
                amplitude: reduceMotion ? 0 : 1.45 + CGFloat(index) * 0.52,
                cycles: 0.82 + CGFloat(index) * 0.18,
                phase: reduceMotion ? 0 : elapsed * (1.10 + CGFloat(index) * 0.22)
            )
            caustic.opacity = Float(0.22 + progress * 0.26 + handoff * 0.16)
        }
        let bloomX = min(max(baseX / max(bounds.width, 1), 0), 1)
        surface.holdProgressGlassBloom.startPoint = CGPoint(x: bloomX, y: 0.5)
        surface.holdProgressGlassBloom.endPoint = CGPoint(x: min(1.35, bloomX + 0.42), y: 0.92)
        surface.holdProgressGlassBloom.opacity = Float(0.08 + handoff * 0.52)
        surface.holdProgressRim.strokeStart = 0
        surface.holdProgressRim.strokeEnd = max(0.001, progress)
        surface.holdProgressRim.opacity = Float(min(1, 0.50 + progress * 0.46 + handoff * 0.20))
        surface.holdProgressRim.shadowOpacity = Float(min(0.82,
            0.28 + progress * 0.42 + handoff * 0.16))
        CATransaction.commit()
    }

    private func holdWaterPath(in bounds: CGRect, level: CGFloat, amplitude: CGFloat,
                               cycles: CGFloat, phase: CGFloat,
                               crestOnly: Bool) -> CGPath {
        let path = CGMutablePath()
        let samples = 64
        func point(_ index: Int) -> CGPoint {
            let fraction = CGFloat(index) / CGFloat(samples)
            let wave = sin(fraction * cycles * 2 * .pi + phase) * amplitude
            let y = min(max(bounds.height * level + wave, 0), bounds.height)
            return CGPoint(x: bounds.width * fraction, y: y)
        }
        if crestOnly {
            path.move(to: point(0))
            for index in 1...samples { path.addLine(to: point(index)) }
            return path
        }
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: point(0))
        for index in 1...samples { path.addLine(to: point(index)) }
        path.addLine(to: CGPoint(x: bounds.width, y: 0))
        path.closeSubpath()
        return path
    }

    private func holdGlassCausticPath(in bounds: CGRect, x: CGFloat, amplitude: CGFloat,
                                      cycles: CGFloat, phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let samples = 42
        for index in 0...samples {
            let fraction = CGFloat(index) / CGFloat(samples)
            let point = CGPoint(
                x: x + sin(fraction * cycles * 2 * .pi + phase) * amplitude,
                y: bounds.height * fraction
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func pulseHoldProgressRim() {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.70, 1.0, 0.78]
        pulse.keyTimes = [0.0, 0.42, 1.0]
        pulse.duration = 0.30
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        surface.holdProgressRim.add(pulse, forKey: "compactHoldBoundary")
    }

    private func startHoldRipple() {
        for (index, ripple) in surface.rippleLayers.enumerated() {
            ripple.removeAnimation(forKey: "holdRipple")
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.92, 0.975, 1.035]
            scale.keyTimes = [0.0, 0.38, 1.0]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, 0.16, 0.0]
            opacity.keyTimes = [0.0, 0.32, 1.0]

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.42
            group.repeatCount = .infinity
            group.beginTime = ripple.convertTime(CACurrentMediaTime(), from: nil)
                + Double(index) * 0.36
            group.fillMode = .backwards
            group.isRemovedOnCompletion = false
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(group, forKey: "holdRipple")
        }
    }

    private func stopHoldRipple(immediate: Bool = false) {
        for ripple in surface.rippleLayers {
            let visibleOpacity = ripple.presentation()?.opacity ?? ripple.opacity
            ripple.removeAnimation(forKey: "holdRipple")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ripple.opacity = 0
            CATransaction.commit()
            guard !immediate, visibleOpacity > 0.001 else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = visibleOpacity
            fade.toValue = 0
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(fade, forKey: "holdRippleFade")
        }
    }

    /// Keep typography attached to the material's own background classification while preserving
    /// the icon's semantic system colour. In particular, hold progress must not turn Close/Quit
    /// from system red into an ordinary black glyph; shape + label + colour jointly carry severity.
    private func applyHoldContentContrast() {
        let style = surface.cardView.interiorBackgroundStyle
        surface.titleLabel.cell?.backgroundStyle = style
        surface.subtitleLabel.cell?.backgroundStyle = style
        surface.titleLabel.textColor = .labelColor
        surface.subtitleLabel.textColor = .secondaryLabelColor
        if currentSymbolName != nil {
            // Hierarchical colour is embedded in the symbol configuration.
            surface.iconView.contentTintColor = nil
        } else if surface.iconView.image?.isTemplate == true {
            surface.iconView.contentTintColor = currentFaceTint
        }
        for label in [surface.voiceHeaderLabel, surface.voiceLiveLabel,
                      surface.voicePitchLabel, surface.voiceBrightnessLabel] {
            label.cell?.backgroundStyle = style
        }
        surface.voiceHeaderLabel.textColor = .labelColor
        surface.voicePitchLabel.textColor = .secondaryLabelColor
        surface.voiceBrightnessLabel.textColor = .secondaryLabelColor
        surface.voiceLiveLabel.attributedStringValue = Self.voiceLiveAttributedText(
            surface.voiceLiveLabel.stringValue,
            font: surface.voiceLiveLabel.font,
            foregroundColor: .secondaryLabelColor
        )
        let highlightColor = resolvedMaterialColor(.labelColor).withAlphaComponent(0.92).cgColor
        surface.voiceBarHighlightLayers.forEach { $0.backgroundColor = highlightColor }
    }

    private func materialAppearanceChanged() {
        applyHoldContentContrast()
        applyLayerIdentity(animated: false)
        renderVoiceBars(animated: false)
    }

    private func setVoiceWaveformActive(_ active: Bool, immediate: Bool = false) {
        guard active != isVoiceWaveformActive else { return }
        isVoiceWaveformActive = active
        if active || immediate {
            voiceSelectionEditingContext = nil
            voiceHistory = [VoiceVisualSample](repeating: .silence,
                                               count: surface.voiceBarLayers.count)
            voiceLevelNormalizer.reset()
            voicePitchBaselineLog2 = nil
            voiceSmoothedPitchLog2 = nil
            voicePitchPosition = 0
            voicePitchConfidence = 0
            voiceBrightness = 0
            voiceLastVoicedAt = 0
            voiceStartedAt = active ? CACurrentMediaTime() : 0
            voiceLastReadoutTick = -1
            renderVoiceBars(animated: false)
        }

        let oldWaveOpacity = surface.voiceWaveformLayer.presentation()?.opacity
            ?? surface.voiceWaveformLayer.opacity
        let oldAmbientOpacity = surface.voiceAmbientLayer.presentation()?.opacity
            ?? surface.voiceAmbientLayer.opacity
        let oldNormalOpacity = surface.normalContentView.layer?.presentation()?.opacity
            ?? surface.normalContentView.layer?.opacity ?? 1
        let voiceLabels = [surface.voiceHeaderLabel, surface.voiceLiveLabel,
                           surface.voicePitchLabel, surface.voiceBrightnessLabel]
        let oldVoiceLabelOpacities = voiceLabels.map {
            $0.layer?.presentation()?.opacity ?? $0.layer?.opacity ?? 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.voiceWaveformLayer.opacity = active ? 1 : 0
        surface.voiceAmbientLayer.opacity = active ? 1 : 0
        surface.normalContentView.layer?.opacity = active ? 0 : 1
        voiceLabels.forEach { $0.layer?.opacity = active ? 1 : 0 }
        CATransaction.commit()

        guard !immediate else {
            surface.voiceWaveformLayer.removeAllAnimations()
            surface.voiceAmbientLayer.removeAllAnimations()
            surface.normalContentView.layer?.removeAllAnimations()
            voiceLabels.forEach { $0.layer?.removeAllAnimations() }
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let timing = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1.0)
        func animateOpacity(_ layer: CALayer?, from: Float, to: Float,
                            duration: CFTimeInterval, delay: CFTimeInterval = 0,
                            key: String) {
            guard let layer = layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = duration
            fade.timingFunction = timing
            if delay > 0 {
                fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
                fade.fillMode = .backwards
            }
            layer.add(fade, forKey: key)
        }
        animateOpacity(surface.voiceWaveformLayer, from: oldWaveOpacity,
                       to: active ? 1 : 0,
                       duration: reduceMotion ? 0.16 : (active ? 0.28 : 0.20),
                       delay: active && !reduceMotion ? 0.020 : 0,
                       key: "voiceWaveformFade")
        animateOpacity(surface.voiceAmbientLayer, from: oldAmbientOpacity,
                       to: active ? 1 : 0,
                       duration: reduceMotion ? 0.16 : (active ? 0.32 : 0.24),
                       key: "voiceAmbientFade")
        animateOpacity(surface.normalContentView.layer, from: oldNormalOpacity,
                       to: active ? 0 : 1,
                       duration: reduceMotion ? 0.16 : (active ? 0.19 : 0.23),
                       delay: !active && !reduceMotion ? 0.040 : 0,
                       key: "voiceNormalContentFade")
        for (index, label) in voiceLabels.enumerated() {
            animateOpacity(label.layer, from: oldVoiceLabelOpacities[index],
                           to: active ? 1 : 0,
                           duration: reduceMotion ? 0.16 : (active ? 0.22 : 0.13),
                           delay: active && !reduceMotion ? 0.060 + Double(index) * 0.016 : 0,
                           key: "voiceReadoutFade")
            guard !reduceMotion, let layer = label.layer else { continue }
            let sourceFrame = index < 2 ? surface.titleLabel.frame : surface.subtitleLabel.frame
            let dx = sourceFrame.midX - label.frame.midX
            let dy = sourceFrame.midY - label.frame.midY
            let moveX = CAKeyframeAnimation(keyPath: "transform.translation.x")
            moveX.values = active ? [dx, 0.0] : [0.0, dx]
            moveX.keyTimes = [0, 1]
            let moveY = CAKeyframeAnimation(keyPath: "transform.translation.y")
            moveY.values = active ? [dy, 0.0] : [0.0, dy]
            moveY.keyTimes = [0, 1]
            let turn = CAKeyframeAnimation(keyPath: "transform.rotation.x")
            turn.values = active
                ? [CGFloat.pi * 0.5, -CGFloat.pi * 0.018, 0]
                : [0, -CGFloat.pi * 0.5]
            turn.keyTimes = active ? [0, 0.84, 1] : [0, 1]
            let labelMorph = CAAnimationGroup()
            labelMorph.animations = [moveX, moveY, turn]
            labelMorph.duration = active ? 0.28 : 0.18
            labelMorph.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
                + (active ? 0.060 + Double(index) * 0.016 : 0)
            labelMorph.fillMode = .backwards
            labelMorph.timingFunction = timing
            layer.add(labelMorph, forKey: "voiceReadoutMorph")
        }

        if !active {
            // Keep the last real acoustic silhouette intact while it collapses across the icon's
            // 40 pt footprint. Clearing history at key-up made the console snap flat before exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                guard let self = self, !self.isVoiceWaveformActive else { return }
                self.voiceHistory = [VoiceVisualSample](
                    repeating: .silence, count: self.surface.voiceBarLayers.count
                )
                self.voicePitchBaselineLog2 = nil
                self.voiceSmoothedPitchLog2 = nil
                self.voicePitchPosition = 0
                self.voicePitchConfidence = 0
                self.voiceBrightness = 0
                self.voiceLastVoicedAt = 0
                self.voiceStartedAt = 0
                self.voiceLastReadoutTick = -1
                self.renderVoiceBars(animated: false)
            }
        }

        guard !reduceMotion else { return }

        // The real waveform bars are the icon's back face. They begin edge-on and distributed
        // across the icon's exact 40 pt footprint; only after that shared-axis hand-off do they fan
        // into the 176 pt acoustic console. The full console never rotates around a second centre.
        let iconMinXInWaveform = surface.iconView.frame.minX
            - surface.voiceWaveformLayer.frame.minX
        let iconSourceWidth = surface.iconView.frame.width
        let middleBar = CGFloat(surface.voiceBarLayers.count - 1) / 2
        for (index, bar) in surface.voiceBarLayers.enumerated() {
            let finalX = bar.position.x
            let fraction = surface.voiceBarLayers.count > 1
                ? CGFloat(index) / CGFloat(surface.voiceBarLayers.count - 1) : 0.5
            let sourceX = iconMinXInWaveform + iconSourceWidth * fraction
            let position = CAKeyframeAnimation(keyPath: "position.x")
            if active {
                let overshoot = finalX + (finalX - sourceX) * 0.018
                position.values = [sourceX, overshoot, finalX]
                position.keyTimes = [0, 0.82, 1]
            } else {
                position.values = [finalX, sourceX]
                position.keyTimes = [0, 1]
            }
            let barTurn = CAKeyframeAnimation(keyPath: "transform")
            barTurn.values = active
                ? [flipTransform(angle: -CGFloat.pi * 0.5, x: 0, y: 1),
                   flipTransform(angle: CGFloat.pi * 0.018, x: 0, y: 1),
                   flipTransform(angle: 0, x: 0, y: 1)]
                : [flipTransform(angle: 0, x: 0, y: 1),
                   flipTransform(angle: CGFloat.pi * 0.5, x: 0, y: 1)]
            barTurn.keyTimes = active ? [0, 0.84, 1] : [0, 1]
            let group = CAAnimationGroup()
            group.animations = [position, barTurn]
            group.duration = active ? 0.30 : 0.22
            group.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil)
                + (active ? 0.085 + abs(CGFloat(index) - middleBar) * 0.0015 : 0)
            group.fillMode = .backwards
            group.timingFunction = timing
            bar.add(group, forKey: "voiceIconBarMorph")
        }

        // The icon is the front face: rotate it to the shared edge on entry, and reveal it from the
        // opposite edge on release. It never shrinks into a dot.
        if let iconLayer = surface.iconView.layer {
            iconLayer.isDoubleSided = false
            let iconTurn = CAKeyframeAnimation(keyPath: "transform")
            iconTurn.values = active
                ? [flipTransform(angle: 0, x: 0, y: 1),
                   flipTransform(angle: CGFloat.pi * 0.5, x: 0, y: 1)]
                : [flipTransform(angle: -CGFloat.pi * 0.5, x: 0, y: 1),
                   flipTransform(angle: CGFloat.pi * 0.018, x: 0, y: 1),
                   flipTransform(angle: 0, x: 0, y: 1)]
            iconTurn.keyTimes = active ? [0, 1] : [0, 0.84, 1]
            iconTurn.duration = active ? 0.17 : 0.21
            iconTurn.beginTime = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
                + (active ? 0 : 0.085)
            iconTurn.fillMode = .backwards
            iconTurn.timingFunction = timing
            iconLayer.add(iconTurn, forKey: "voiceNormalElementMorph")
        }

        let normalElements: [(CALayer?, CFTimeInterval)] = [
            (surface.titleLabel.layer, 0.018),
            (surface.subtitleLabel.layer, 0.040),
        ]
        for item in normalElements {
            guard let layer = item.0 else { continue }
            layer.isDoubleSided = false
            let turn = CAKeyframeAnimation(keyPath: "transform")
            turn.values = active
                ? [flipTransform(angle: 0, x: 1, y: 0),
                   flipTransform(angle: -CGFloat.pi * 0.5, x: 1, y: 0)]
                : [flipTransform(angle: CGFloat.pi * 0.5, x: 1, y: 0),
                   flipTransform(angle: -CGFloat.pi * 0.018, x: 1, y: 0),
                   flipTransform(angle: 0, x: 1, y: 0)]
            turn.keyTimes = active ? [0, 1] : [0, 0.84, 1]
            turn.duration = active ? 0.17 : 0.21
            turn.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
                + item.1 + (active ? 0 : 0.075)
            turn.fillMode = .backwards
            turn.timingFunction = timing
            layer.add(turn, forKey: "voiceNormalElementMorph")
        }

    }

    private func renderVoiceBars(animated: Bool) {
        for (index, bar) in surface.voiceBarLayers.enumerated() {
            let sample = voiceHistory.indices.contains(index)
                ? voiceHistory[index] : VoiceVisualSample.silence
            let height = 3.0 + sample.level * 37.0
            let color = voiceColor(for: sample).cgColor
            let highlight = surface.voiceBarHighlightLayers[index]
            let oldHeight = bar.presentation()?.bounds.height ?? bar.bounds.height
            let oldColor = bar.presentation()?.backgroundColor ?? bar.backgroundColor
            let oldHighlightOpacity = highlight.presentation()?.opacity ?? highlight.opacity
            let oldHighlightPosition = highlight.presentation()?.position ?? highlight.position
            let highlightOpacity = Float(sample.level > 0.025
                ? 0.08 + sample.brightness * 0.78 : 0.02)
            let highlightPosition = CGPoint(x: bar.bounds.midX, y: max(1.2, height - 1.0))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = height
            bar.backgroundColor = color
            highlight.position = highlightPosition
            highlight.opacity = highlightOpacity
            CATransaction.commit()

            guard animated else { continue }
            let change = CABasicAnimation(keyPath: "bounds.size.height")
            change.fromValue = oldHeight
            change.toValue = height
            change.duration = 0.075
            change.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(change, forKey: "voiceLevel")

            let colourChange = CABasicAnimation(keyPath: "backgroundColor")
            colourChange.fromValue = oldColor
            colourChange.toValue = color
            colourChange.duration = 0.12
            colourChange.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(colourChange, forKey: "voicePitchColor")

            let highlightChange = CABasicAnimation(keyPath: "opacity")
            highlightChange.fromValue = oldHighlightOpacity
            highlightChange.toValue = highlightOpacity
            highlightChange.duration = 0.10
            highlightChange.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlight.add(highlightChange, forKey: "voiceBrightness")

            let highlightMove = CABasicAnimation(keyPath: "position")
            highlightMove.fromValue = oldHighlightPosition
            highlightMove.toValue = highlightPosition
            highlightMove.duration = 0.075
            highlightMove.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlight.add(highlightMove, forKey: "voiceBrightnessPosition")
        }
        let newest = voiceHistory.last ?? .silence
        updateVoiceAmbient(with: newest, animated: animated)
        updateVoiceReadouts(with: newest)
    }

    private func updateVoiceReadouts(with sample: VoiceVisualSample, force: Bool = false) {
        guard isVoiceWaveformActive else { return }
        let elapsed = max(0, CACurrentMediaTime() - voiceStartedAt)
        let tick = Int(elapsed * 10)
        guard force || tick != voiceLastReadoutTick else { return }
        voiceLastReadoutTick = tick

        surface.voiceHeaderLabel.stringValue = voiceSelectionEditingContext == nil ? "VOICE" : "EDIT"
        let minutes = Int(elapsed) / 60
        let seconds = elapsed - Double(minutes * 60)
        let livePrefix = voiceSelectionEditingContext == nil ? "● LIVE" : "● EDIT"
        let liveText = String(format: "%@  %02d:%04.1f", livePrefix, minutes, seconds)
        surface.voiceLiveLabel.attributedStringValue = Self.voiceLiveAttributedText(
            liveText, font: surface.voiceLiveLabel.font,
            foregroundColor: .secondaryLabelColor
        )
        if sample.pitchConfidence > 0.10 {
            let semitones = sample.pitchPosition * 5
            let arrow = semitones > 0.45 ? "↗" : (semitones < -0.45 ? "↘" : "→")
            surface.voicePitchLabel.stringValue = String(
                format: "PITCH %@  %+.1f ST", arrow, Double(semitones)
            )
        } else {
            surface.voicePitchLabel.stringValue = "PITCH  ···"
        }
        if let selection = voiceSelectionEditingContext {
            surface.voiceBrightnessLabel.stringValue = "\(selection.characterCount) CHARS"
        } else {
            surface.voiceBrightnessLabel.stringValue = String(
                format: "BRIGHT  %02d%%", Int((sample.brightness * 100).rounded())
            )
        }
    }

    private func animateVoiceReadoutChange(_ label: NSTextField, to text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = label.layer else { return }
        let flip = CAKeyframeAnimation(keyPath: "transform.rotation.x")
        flip.values = [CGFloat.pi * 0.48, -CGFloat.pi * 0.025, 0]
        flip.keyTimes = [0, 0.82, 1]
        flip.duration = 0.20
        flip.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        layer.add(flip, forKey: "voiceSemanticFlip")
    }

    private func updateVoiceAmbient(with sample: VoiceVisualSample, animated: Bool) {
        let colour = voiceColor(for: sample).usingColorSpace(.deviceRGB) ?? voiceNeutralTint
        let strength = 0.055 + sample.level * 0.16
        let colors = [
            colour.withAlphaComponent(strength).cgColor,
            colour.withAlphaComponent(strength * 0.34).cgColor,
            NSColor.clear.cgColor,
        ]
        let centre = CGPoint(x: 0.5 + sample.pitchPosition * 0.18, y: 0.50)
        let oldColors: Any?
        if let presentedColors = surface.voiceAmbientLayer.presentation()?
            .value(forKeyPath: "colors") {
            oldColors = presentedColors
        } else {
            oldColors = surface.voiceAmbientLayer.colors
        }
        let oldCentre = surface.voiceAmbientLayer.presentation()?.startPoint
            ?? surface.voiceAmbientLayer.startPoint
        let oldBaseline = surface.voiceBaselineLayer.presentation()?.backgroundColor
            ?? surface.voiceBaselineLayer.backgroundColor
        let baseline = colour.withAlphaComponent(0.20 + sample.level * 0.10).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.voiceAmbientLayer.colors = colors
        surface.voiceAmbientLayer.startPoint = centre
        surface.voiceBaselineLayer.backgroundColor = baseline
        CATransaction.commit()
        guard animated else { return }

        let timing = CAMediaTimingFunction(name: .easeOut)
        let colourChange = CABasicAnimation(keyPath: "colors")
        colourChange.fromValue = oldColors
        colourChange.toValue = colors
        colourChange.duration = 0.18
        colourChange.timingFunction = timing
        surface.voiceAmbientLayer.add(colourChange, forKey: "voiceAmbientColor")

        let centreChange = CABasicAnimation(keyPath: "startPoint")
        centreChange.fromValue = oldCentre
        centreChange.toValue = centre
        centreChange.duration = 0.20
        centreChange.timingFunction = timing
        surface.voiceAmbientLayer.add(centreChange, forKey: "voiceAmbientPosition")

        let baselineChange = CABasicAnimation(keyPath: "backgroundColor")
        baselineChange.fromValue = oldBaseline
        baselineChange.toValue = baseline
        baselineChange.duration = 0.16
        baselineChange.timingFunction = timing
        surface.voiceBaselineLayer.add(baselineChange, forKey: "voiceBaselineColor")
    }

    private static func voiceLiveAttributedText(_ text: String, font: NSFont?,
                                                foregroundColor: NSColor) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: foregroundColor,
        ]
        if let font = font { attributes[.font] = font }
        let value = NSMutableAttributedString(string: text, attributes: attributes)
        if !text.isEmpty {
            value.addAttribute(
                .foregroundColor,
                value: NSColor(srgbRed: 1.0, green: 0.24, blue: 0.20, alpha: 1.0),
                range: NSRange(location: 0, length: 1)
            )
        }
        return value
    }

    /// Premium three-stop palette: falling intonation is indigo, the speaker's own centre is
    /// cyan, and rising intonation warms toward amber. Confidence blends back to the current
    /// Layer tint so breaths and consonants never become random rainbow flashes.
    private func voiceColor(for sample: VoiceVisualSample) -> NSColor {
        let low = NSColor(srgbRed: 0.51, green: 0.35, blue: 1.00, alpha: 1)
        let centre = NSColor(srgbRed: 0.10, green: 0.80, blue: 0.96, alpha: 1)
        let high = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.24, alpha: 1)
        let pitchColor: NSColor
        if sample.pitchPosition < 0 {
            pitchColor = mixedColor(low, centre, fraction: sample.pitchPosition + 1)
        } else {
            pitchColor = mixedColor(centre, high, fraction: sample.pitchPosition)
        }
        var result = mixedColor(voiceNeutralTint, pitchColor,
                                fraction: sample.pitchConfidence)
        let dark = surface.panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        result = mixedColor(result, .white,
                            fraction: sample.brightness * (dark ? 0.15 : 0.09))
        return result.withAlphaComponent(dark ? 0.96 : 0.90)
    }

    private func mixedColor(_ first: NSColor, _ second: NSColor,
                            fraction rawFraction: CGFloat) -> NSColor {
        let fraction = min(1, max(0, rawFraction))
        let a = first.usingColorSpace(.deviceRGB) ?? first
        let b = second.usingColorSpace(.deviceRGB) ?? second
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * fraction)
    }

    /// Paint the current Layer as a persistent identity around the card. Action colour remains
    /// free to communicate semantics inside the component (Voice red, Music pink, mouse teal),
    /// while this edge never stops answering "which Layer am I in?".
    private func applyLayerIdentity(animated: Bool) {
        let dark = surface.panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rawTint = layerAppearance(currentLayerID).tint
        let tint = rawTint.usingColorSpace(.deviceRGB) ?? rawTint
        let borderColors = [
            tint.withAlphaComponent(dark ? 0.18 : 0.14).cgColor,
            tint.withAlphaComponent(dark ? 0.44 : 0.34).cgColor,
            tint.withAlphaComponent(dark ? 0.22 : 0.18).cgColor,
            tint.withAlphaComponent(dark ? 0.36 : 0.29).cgColor,
            tint.withAlphaComponent(dark ? 0.16 : 0.12).cgColor,
        ]
        let auraStroke = tint.withAlphaComponent(dark ? 0.10 : 0.07).cgColor

        let oldBorderColors: Any?
        if let presented = surface.layerIdentityBorder.presentation()?.value(forKeyPath: "colors") {
            oldBorderColors = presented
        } else {
            oldBorderColors = surface.layerIdentityBorder.colors
        }
        let oldAuraStroke = surface.layerIdentityAura.presentation()?.strokeColor
            ?? surface.layerIdentityAura.strokeColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layerIdentityBorder.colors = borderColors
        surface.layerIdentityAura.strokeColor = auraStroke
        CATransaction.commit()

        guard animated else { return }
        let duration: CFTimeInterval = 0.38
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.80, 0.18, 1.0)

        let borderChange = CABasicAnimation(keyPath: "colors")
        borderChange.fromValue = oldBorderColors
        borderChange.toValue = borderColors
        borderChange.duration = duration
        borderChange.timingFunction = timing
        surface.layerIdentityBorder.add(borderChange, forKey: "layerIdentityColor")

        func animateColor(_ keyPath: String, from: CGColor?, to: CGColor, key: String) {
            let change = CABasicAnimation(keyPath: keyPath)
            change.fromValue = from
            change.toValue = to
            change.duration = duration
            change.timingFunction = timing
            surface.layerIdentityAura.add(change, forKey: key)
        }
        animateColor("strokeColor", from: oldAuraStroke, to: auraStroke,
                     key: "layerIdentityAuraStroke")

        // One restrained breath acknowledges the Layer change without turning the persistent
        // border into a looping decoration. At rest it is completely static.
        let breathe = CAKeyframeAnimation(keyPath: "opacity")
        breathe.values = [1.0, 1.0, 0.72, 1.0]
        breathe.keyTimes = [0, 0.22, 0.54, 1]
        breathe.duration = duration
        breathe.timingFunctions = [timing, timing, timing]
        surface.layerIdentityBorder.add(breathe, forKey: "layerIdentityBreath")
    }

    private func applyColors(_ tint: NSColor, animated: Bool) {
        let dark = surface.panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tintRGB = tint.usingColorSpace(.deviceRGB) ?? tint
        let colors = [
            tintRGB.withAlphaComponent(dark ? 0.22 : 0.13).cgColor,
            tintRGB.withAlphaComponent(dark ? 0.07 : 0.035).cgColor,
            NSColor.clear.cgColor,
        ]
        let accent = tintRGB.withAlphaComponent(dark ? 0.92 : 0.84).cgColor
        let glow = tintRGB.withAlphaComponent(dark ? 0.24 : 0.17).cgColor
        let ripple = tintRGB.withAlphaComponent(dark ? 0.46 : 0.34).cgColor
        let waveform = tintRGB.withAlphaComponent(dark ? 0.96 : 0.88).cgColor
        let usesWater = holdProgressVisualStyle == .water
        let waterBackBase = tintRGB.blended(withFraction: dark ? 0.24 : 0.16,
                                             of: .white) ?? tintRGB
        let waterFrontBase = tintRGB.blended(withFraction: dark ? 0.08 : 0.03,
                                              of: .white) ?? tintRGB
        let holdBackground = tintRGB.withAlphaComponent(
            usesWater ? (dark ? 0.07 : 0.045) : (dark ? 0.055 : 0.035)
        ).cgColor
        let holdBack = waterBackBase.withAlphaComponent(dark ? 0.31 : 0.24).cgColor
        let holdFront = waterFrontBase.withAlphaComponent(dark ? 0.64 : 0.55).cgColor
        let holdCrest = NSColor.white.withAlphaComponent(dark ? 0.66 : 0.56).cgColor
        let holdBloomColors = [
            NSColor.white.withAlphaComponent(dark ? 0.20 : 0.14).cgColor,
            tintRGB.withAlphaComponent(dark ? 0.065 : 0.045).cgColor,
            NSColor.clear.cgColor,
        ]
        let holdBandColors: [[CGColor]] = surface.holdProgressGlassBands.indices.map { index in
            let strength = (dark ? 0.22 : 0.16) - CGFloat(index) * (dark ? 0.035 : 0.025)
            return [
                NSColor.clear.cgColor,
                NSColor.white.withAlphaComponent(strength * 0.55).cgColor,
                tintRGB.withAlphaComponent(strength).cgColor,
                NSColor.white.withAlphaComponent(strength * 0.82).cgColor,
                NSColor.clear.cgColor,
            ]
        }
        let holdCaustics = surface.holdProgressGlassCaustics.indices.map { index in
            NSColor.white.withAlphaComponent(
                (dark ? 0.34 : 0.26) - CGFloat(index) * (dark ? 0.07 : 0.05)
            ).cgColor
        }
        let holdRim = tintRGB.withAlphaComponent(
            usesWater ? (dark ? 0.60 : 0.48) : (dark ? 0.88 : 0.74)
        ).cgColor

        let oldColors: Any?
        if let presented = surface.tintLayer.presentation()?.value(forKeyPath: "colors") {
            oldColors = presented
        } else {
            oldColors = surface.tintLayer.colors
        }
        let oldAccent = surface.accentLayer.presentation()?.backgroundColor
            ?? surface.accentLayer.backgroundColor
        let oldHoldBackground = surface.holdProgressContainer.presentation()?.backgroundColor
            ?? surface.holdProgressContainer.backgroundColor
        let oldHoldBack = surface.holdProgressBackWave.presentation()?.fillColor
            ?? surface.holdProgressBackWave.fillColor
        let oldHoldFront = surface.holdProgressFrontWave.presentation()?.fillColor
            ?? surface.holdProgressFrontWave.fillColor
        let oldHoldCrest = surface.holdProgressCrest.presentation()?.strokeColor
            ?? surface.holdProgressCrest.strokeColor
        func visibleGradientColors(_ layer: CAGradientLayer) -> Any? {
            if let presented = layer.presentation()?.value(forKeyPath: "colors") {
                return presented
            }
            return layer.colors as Any?
        }
        let oldHoldBloomColors = visibleGradientColors(surface.holdProgressGlassBloom)
        let oldHoldBandColors = surface.holdProgressGlassBands.map(visibleGradientColors)
        let oldHoldCaustics = surface.holdProgressGlassCaustics.map {
            $0.presentation()?.strokeColor ?? $0.strokeColor
        }
        let oldHoldRim = surface.holdProgressRim.presentation()?.strokeColor
            ?? surface.holdProgressRim.strokeColor
        let oldHoldRimShadow = surface.holdProgressRim.presentation()?.shadowColor
            ?? surface.holdProgressRim.shadowColor
        voiceNeutralTint = tintRGB
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.tintLayer.colors = colors
        surface.accentLayer.backgroundColor = accent
        surface.glowLayer.backgroundColor = glow
        surface.rippleLayers.forEach { $0.strokeColor = ripple }
        if !isVoiceWaveformActive {
            surface.voiceBarLayers.forEach { $0.backgroundColor = waveform }
            surface.voiceBaselineLayer.backgroundColor = tintRGB
                .withAlphaComponent(dark ? 0.20 : 0.14).cgColor
            surface.voiceAmbientLayer.colors = [
                tintRGB.withAlphaComponent(dark ? 0.08 : 0.05).cgColor,
                tintRGB.withAlphaComponent(dark ? 0.025 : 0.015).cgColor,
                NSColor.clear.cgColor,
            ]
            surface.voiceBarHighlightLayers.forEach {
                $0.backgroundColor = NSColor.white.cgColor
                $0.opacity = 0
            }
        }
        surface.holdProgressContainer.backgroundColor = holdBackground
        surface.holdProgressBackWave.fillColor = holdBack
        surface.holdProgressFrontWave.fillColor = holdFront
        surface.holdProgressCrest.strokeColor = holdCrest
        surface.holdProgressGlassBloom.colors = holdBloomColors
        for (index, band) in surface.holdProgressGlassBands.enumerated() {
            band.colors = holdBandColors[index]
        }
        for (index, caustic) in surface.holdProgressGlassCaustics.enumerated() {
            caustic.strokeColor = holdCaustics[index]
        }
        surface.holdProgressRim.strokeColor = holdRim
        surface.holdProgressRim.shadowColor = tintRGB.cgColor
        CATransaction.commit()

        guard animated else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.18, 1.0)
        let colorAnimation = CABasicAnimation(keyPath: "colors")
        colorAnimation.fromValue = oldColors
        colorAnimation.toValue = colors
        colorAnimation.duration = 0.22
        colorAnimation.timingFunction = timing
        surface.tintLayer.add(colorAnimation, forKey: "statusTint")

        let accentAnimation = CABasicAnimation(keyPath: "backgroundColor")
        accentAnimation.fromValue = oldAccent
        accentAnimation.toValue = accent
        accentAnimation.duration = 0.22
        accentAnimation.timingFunction = timing
        surface.accentLayer.add(accentAnimation, forKey: "statusAccent")

        func animateColor(_ layer: CALayer, keyPath: String, from: CGColor?, to: CGColor,
                          key: String) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 0.22
            animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        func animateGradient(_ layer: CAGradientLayer, from: Any?, to: [CGColor], key: String) {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 0.22
            animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        animateColor(surface.holdProgressContainer, keyPath: "backgroundColor",
                     from: oldHoldBackground, to: holdBackground, key: "holdBackgroundTint")
        animateColor(surface.holdProgressBackWave, keyPath: "fillColor",
                     from: oldHoldBack, to: holdBack, key: "holdBackTint")
        animateColor(surface.holdProgressFrontWave, keyPath: "fillColor",
                     from: oldHoldFront, to: holdFront, key: "holdFrontTint")
        animateColor(surface.holdProgressCrest, keyPath: "strokeColor",
                     from: oldHoldCrest, to: holdCrest, key: "holdCrestTint")
        animateGradient(surface.holdProgressGlassBloom, from: oldHoldBloomColors,
                        to: holdBloomColors, key: "holdGlassBloomTint")
        for (index, band) in surface.holdProgressGlassBands.enumerated() {
            animateGradient(band, from: oldHoldBandColors[index],
                            to: holdBandColors[index], key: "holdGlassBandTint")
        }
        for (index, caustic) in surface.holdProgressGlassCaustics.enumerated() {
            animateColor(caustic, keyPath: "strokeColor", from: oldHoldCaustics[index],
                         to: holdCaustics[index], key: "holdGlassCausticTint")
        }
        animateColor(surface.holdProgressRim, keyPath: "strokeColor",
                     from: oldHoldRim, to: holdRim, key: "holdRimTint")
        animateColor(surface.holdProgressRim, keyPath: "shadowColor",
                     from: oldHoldRimShadow, to: tintRGB.cgColor, key: "holdRimShadowTint")
    }

    // MARK: - Position persistence / display recovery

    func windowDidMove(_ notification: Notification) {
        guard enabled, !isMovingProgrammatically else { return }
        scheduleMoveSettlement()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyHoldContentContrast()
    }

    private func scheduleMoveSettlement() {
        moveGeneration += 1
        let generation = moveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self = self, self.enabled, self.moveGeneration == generation else { return }
            // Do not clamp underneath a held mouse. A short pause during a slow drag is still a drag.
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleMoveSettlement()
                return
            }
            self.settleAndSavePosition()
        }
    }

    private func settleAndSavePosition() {
        guard let screen = bestScreen(for: surface.panel.frame) else { return }
        let origin = clampedOrigin(surface.panel.frame.origin, in: screen.visibleFrame)
        if origin != surface.panel.frame.origin { setFrameOrigin(origin) }
        savePosition(on: screen)
    }

    private func restorePosition() {
        guard !NSScreen.screens.isEmpty else { return }
        let storedID = defaults.object(forKey: DefaultsKey.displayID) == nil
            ? nil : CGDirectDisplayID(defaults.integer(forKey: DefaultsKey.displayID))
        let storedScreen = storedID.flatMap { id in NSScreen.screens.first { $0.hudDisplayID == id } }
        let screen = storedScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let hasCoordinates = defaults.object(forKey: DefaultsKey.normalizedX) != nil
            && defaults.object(forKey: DefaultsKey.normalizedY) != nil
        let nx = hasCoordinates ? clamp(defaults.double(forKey: DefaultsKey.normalizedX)) : 1.0
        let ny = hasCoordinates ? clamp(defaults.double(forKey: DefaultsKey.normalizedY)) : 1.0
        setFrameOrigin(origin(normalizedX: nx, normalizedY: ny, on: screen))
        // If the remembered display disappeared, adopt the fallback now; reconnecting that old
        // monitor later must not pull the widget away from the screen the user has continued using.
        savePosition(on: screen)
    }

    private func screenParametersChanged() {
        guard enabled, isConnected else { return }
        moveGeneration += 1
        restorePosition()
        materialAppearanceChanged()
        surface.panel.orderFrontRegardless()
    }

    private func activeSpaceChanged() {
        guard enabled, isConnected else { return }
        // macOS may drop an already-ordered auxiliary panel during a full-screen Space transition.
        // Re-ordering is idempotent and does not activate HyperVibe.
        ensureReachable()
        surface.panel.orderFrontRegardless()
    }

    private func ensureReachable() {
        guard !NSScreen.screens.isEmpty else { return }
        let visibleArea = NSScreen.screens.reduce(CGFloat(0)) {
            $0 + surface.panel.frame.intersection($1.visibleFrame).area
        }
        if visibleArea < 16 { restorePosition() }
    }

    private func savePosition(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let availableWidth = max(1, visible.width - windowSize.width)
        let availableHeight = max(1, visible.height - windowSize.height)
        let nx = clamp((surface.panel.frame.minX - visible.minX) / availableWidth)
        let ny = clamp((surface.panel.frame.minY - visible.minY) / availableHeight)
        defaults.set(Int(screen.hudDisplayID), forKey: DefaultsKey.displayID)
        defaults.set(Double(nx), forKey: DefaultsKey.normalizedX)
        defaults.set(Double(ny), forKey: DefaultsKey.normalizedY)
    }

    private func origin(normalizedX nx: CGFloat, normalizedY ny: CGFloat,
                        on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.minX + clamp(nx) * max(0, visible.width - windowSize.width),
                       y: visible.minY + clamp(ny) * max(0, visible.height - windowSize.height))
    }

    private func clampedOrigin(_ point: NSPoint, in visible: NSRect) -> NSPoint {
        let maxX = max(visible.minX, visible.maxX - windowSize.width)
        let maxY = max(visible.minY, visible.maxY - windowSize.height)
        return NSPoint(x: min(max(point.x, visible.minX), maxX),
                       y: min(max(point.y, visible.minY), maxY))
    }

    private func setFrameOrigin(_ point: NSPoint) {
        isMovingProgrammatically = true
        surface.panel.setFrameOrigin(point)
        DispatchQueue.main.async { [weak self] in self?.isMovingProgrammatically = false }
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let overlapping = screens.max(by: {
            frame.intersection($0.visibleFrame).area < frame.intersection($1.visibleFrame).area
        }), frame.intersection(overlapping.visibleFrame).area > 0 {
            return overlapping
        }
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            squaredDistance(centre, NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY))
                < squaredDistance(centre, NSPoint(x: $1.visibleFrame.midX, y: $1.visibleFrame.midY))
        }
    }

    private func squaredDistance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func clamp<T: BinaryFloatingPoint>(_ value: T) -> T { min(1, max(0, value)) }

    // MARK: - Construction

    private static func makeSurface(windowSize: NSSize, cardFrame: NSRect,
                                    cornerRadius: CGFloat) -> Surface {
        let panel = StatusPanel(contentRect: NSRect(origin: .zero, size: windowSize),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let root = DragSurfaceView(frame: NSRect(origin: .zero, size: windowSize))
        root.wantsLayer = true
        root.layer?.masksToBounds = false

        // The soft edge is a real low-alpha stroke on the transparent root, not a CALayer shadow.
        // WindowServer can amplify coloured shadows around transparent auxiliary panels into a
        // jagged neon fringe; this wider stroke stays smooth, quiet and colour-accurate.
        let layerIdentityAura = CAShapeLayer()
        layerIdentityAura.frame = root.bounds
        let auraRect = cardFrame.insetBy(dx: -0.6, dy: -0.6)
        layerIdentityAura.path = CGPath(
            roundedRect: auraRect,
            cornerWidth: cornerRadius + 0.6,
            cornerHeight: cornerRadius + 0.6,
            transform: nil
        )
        layerIdentityAura.fillColor = NSColor.clear.cgColor
        layerIdentityAura.lineWidth = 4.0
        layerIdentityAura.lineJoin = .round
        layerIdentityAura.shadowOpacity = 0
        layerIdentityAura.shouldRasterize = false
        root.layer?.addSublayer(layerIdentityAura)

        let card = AdaptiveMaterialView(frame: cardFrame)
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0

        let tintLayer = CAGradientLayer()
        tintLayer.frame = card.bounds
        tintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        tintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        tintLayer.locations = [0, 0.55, 1]
        tintLayer.cornerRadius = cornerRadius
        tintLayer.cornerCurve = .continuous
        card.layer?.addSublayer(tintLayer)

        let accent = CALayer()
        accent.frame = CGRect(x: 0, y: 17, width: 3.5, height: 38)
        accent.cornerRadius = 1.75
        card.layer?.addSublayer(accent)

        // Keep the surface slot stable, but do not render a flat circle behind the icon. During
        // element morphs that circle was exposed as an unrelated blue/red point.
        let glow = CALayer()
        glow.frame = CGRect(x: 13, y: 12, width: 48, height: 48)
        glow.cornerRadius = 24
        glow.opacity = 0
        card.layer?.addSublayer(glow)

        // Voice owns the whole card while active. This low-amplitude radial field follows the
        // current pitch colour behind the bars; it is dormant for every non-Voice face.
        let voiceAmbient = CAGradientLayer()
        voiceAmbient.frame = card.bounds
        voiceAmbient.type = .radial
        voiceAmbient.locations = [0, 0.52, 1]
        voiceAmbient.startPoint = CGPoint(x: 0.5, y: 0.5)
        voiceAmbient.endPoint = CGPoint(x: 0.98, y: 0.98)
        voiceAmbient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor,
                               NSColor.clear.cgColor]
        voiceAmbient.cornerRadius = cornerRadius
        voiceAmbient.cornerCurve = .continuous
        voiceAmbient.masksToBounds = true
        voiceAmbient.opacity = 0
        card.layer?.addSublayer(voiceAmbient)

        // The complete card is the progress surface. Water and glass treatments coexist behind a
        // single timing/state machine; only the selected root is visible. Content stays above both,
        // so progress reads as a state of the whole component rather than an icon-sized gauge.
        let holdProgress = CALayer()
        holdProgress.frame = card.bounds
        holdProgress.cornerRadius = cornerRadius
        holdProgress.cornerCurve = .continuous
        holdProgress.masksToBounds = true
        holdProgress.opacity = 0
        card.layer?.insertSublayer(holdProgress, above: tintLayer)

        let holdWaterRoot = CALayer()
        holdWaterRoot.frame = holdProgress.bounds
        holdProgress.addSublayer(holdWaterRoot)

        let holdBackWave = CAShapeLayer()
        holdBackWave.frame = holdWaterRoot.bounds
        holdBackWave.fillRule = .nonZero
        holdWaterRoot.addSublayer(holdBackWave)

        let holdFrontWave = CAShapeLayer()
        holdFrontWave.frame = holdWaterRoot.bounds
        holdFrontWave.fillRule = .nonZero
        holdWaterRoot.addSublayer(holdFrontWave)

        let holdCrest = CAShapeLayer()
        holdCrest.frame = holdWaterRoot.bounds
        holdCrest.fillColor = NSColor.clear.cgColor
        holdCrest.lineWidth = 1.05
        holdCrest.lineCap = .round
        holdCrest.lineJoin = .round
        holdWaterRoot.addSublayer(holdCrest)

        let holdGlassRoot = CALayer()
        holdGlassRoot.frame = holdProgress.bounds
        holdProgress.addSublayer(holdGlassRoot)

        let holdGlassBloom = CAGradientLayer()
        holdGlassBloom.frame = holdGlassRoot.bounds
        holdGlassBloom.type = .radial
        holdGlassBloom.locations = [0, 0.45, 1]
        holdGlassBloom.opacity = 0
        holdGlassRoot.addSublayer(holdGlassBloom)

        var holdGlassBands: [CAGradientLayer] = []
        for index in 0..<3 {
            let band = CAGradientLayer()
            band.locations = [0, 0.24, 0.50, 0.68, 1]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.opacity = Float(0.47 - CGFloat(index) * 0.065)
            holdGlassRoot.addSublayer(band)
            holdGlassBands.append(band)
        }

        var holdGlassCaustics: [CAShapeLayer] = []
        for index in 0..<3 {
            let caustic = CAShapeLayer()
            caustic.frame = holdGlassRoot.bounds
            caustic.fillColor = NSColor.clear.cgColor
            caustic.lineWidth = index == 0 ? 1.05 : 0.65
            caustic.lineCap = .round
            caustic.opacity = 0
            holdGlassRoot.addSublayer(caustic)
            holdGlassCaustics.append(caustic)
        }

        let holdRim = CAShapeLayer()
        holdRim.frame = holdProgress.bounds
        holdRim.path = CGPath(roundedRect: holdProgress.bounds.insetBy(dx: 1.45, dy: 1.45),
                              cornerWidth: cornerRadius - 1.45,
                              cornerHeight: cornerRadius - 1.45,
                              transform: nil)
        holdRim.fillColor = NSColor.clear.cgColor
        holdRim.lineWidth = 2.4
        holdRim.lineCap = .round
        holdRim.shadowRadius = 3.2
        holdRim.shadowOpacity = 0.28
        holdRim.shadowOffset = .zero
        holdProgress.addSublayer(holdRim)

        // Three restrained rounded-rectangle ripples traverse the full component. They are
        // dormant at rest and remain deliberately quiet because this card can animate frequently.
        var ripples: [CAShapeLayer] = []
        for _ in 0..<3 {
            let ripple = CAShapeLayer()
            ripple.frame = card.bounds
            ripple.path = CGPath(roundedRect: ripple.bounds.insetBy(dx: 5, dy: 5),
                                 cornerWidth: cornerRadius - 5,
                                 cornerHeight: cornerRadius - 5,
                                 transform: nil)
            ripple.fillColor = NSColor.clear.cgColor
            ripple.lineWidth = 1.0
            ripple.opacity = 0
            ripple.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            card.layer?.addSublayer(ripple)
            ripples.append(ripple)
        }

        let content = NSView(frame: card.bounds)
        content.wantsLayer = true

        // Keep the ordinary icon/text hierarchy together so a state hand-off can retain and move
        // both the outgoing and incoming faces as one coherent piece. Voice lives alongside this
        // view and can therefore take over the card without opacity changes fighting each other.
        let normalContent = NSView(frame: content.bounds)
        normalContent.wantsLayer = true
        content.addSubview(normalContent)

        let icon = NSImageView(frame: NSRect(x: 17, y: 16, width: 40, height: 40))
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        normalContent.addSubview(icon)

        // A full-card scrolling acoustic console. Twenty-five samples preserve ~0.83 s at 30 Hz;
        // height, colour and cap brightness all come from real PCM features. There is deliberately
        // no repeating decorative CA animation supplying any of those values.
        let voiceWaveform = CALayer()
        voiceWaveform.frame = CGRect(x: 14, y: 14, width: 176, height: 44)
        voiceWaveform.opacity = 0
        let voiceBaseline = CALayer()
        voiceBaseline.frame = CGRect(x: 0, y: voiceWaveform.bounds.midY - 0.25,
                                     width: voiceWaveform.bounds.width, height: 0.5)
        voiceBaseline.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        voiceWaveform.addSublayer(voiceBaseline)
        var voiceBars: [CALayer] = []
        var voiceHighlights: [CALayer] = []
        let barWidth: CGFloat = 2.6
        let barCount = 25
        let gap = (voiceWaveform.bounds.width - CGFloat(barCount) * barWidth)
            / CGFloat(barCount - 1)
        for index in 0..<barCount {
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: 3)
            bar.position = CGPoint(x: barWidth / 2 + CGFloat(index) * (barWidth + gap),
                                   y: voiceWaveform.bounds.midY)
            bar.cornerRadius = barWidth / 2
            bar.masksToBounds = true
            let highlight = CALayer()
            highlight.bounds = CGRect(x: 0, y: 0, width: max(0.8, barWidth - 0.8), height: 1.1)
            highlight.position = CGPoint(x: barWidth / 2, y: 2)
            highlight.cornerRadius = 0.55
            highlight.backgroundColor = NSColor.white.cgColor
            highlight.opacity = 0
            bar.addSublayer(highlight)
            voiceWaveform.addSublayer(bar)
            voiceBars.append(bar)
            voiceHighlights.append(highlight)
        }
        content.layer?.addSublayer(voiceWaveform)

        let title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 71, y: 35, width: 118, height: 21)
        title.font = .systemFont(ofSize: 14.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.wantsLayer = true
        normalContent.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.frame = NSRect(x: 71, y: 17, width: 118, height: 16)
        subtitle.font = .systemFont(ofSize: 10.5, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.wantsLayer = true
        normalContent.addSubview(subtitle)

        func voiceReadout(_ text: String, frame: NSRect,
                          alignment: NSTextAlignment = .left,
                          weight: NSFont.Weight = .semibold) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = frame
            label.font = .monospacedSystemFont(ofSize: 7.2, weight: weight)
            label.textColor = .secondaryLabelColor
            label.alignment = alignment
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.wantsLayer = true
            label.layer?.opacity = 0
            content.addSubview(label)
            return label
        }
        let voiceHeader = voiceReadout("VOICE", frame: NSRect(x: 14, y: 56, width: 48, height: 10),
                                       weight: .bold)
        voiceHeader.textColor = .labelColor
        let voiceLive = voiceReadout("● LIVE  00:00.0",
                                     frame: NSRect(x: 91, y: 56, width: 99, height: 10),
                                     alignment: .right)
        voiceLive.attributedStringValue = voiceLiveAttributedText(
            "● LIVE  00:00.0", font: voiceLive.font,
            foregroundColor: .secondaryLabelColor
        )
        let voicePitch = voiceReadout("PITCH  ···",
                                      frame: NSRect(x: 14, y: 5, width: 112, height: 10))
        let voiceBrightness = voiceReadout("BRIGHT  00%",
                                           frame: NSRect(x: 119, y: 5, width: 71, height: 10),
                                           alignment: .right)

        card.addSubview(content)

        // A conic gradient makes the hairline breathe differently around each corner while still
        // being one uninterrupted Layer-colour ring. Keeping it above all subviews guarantees the
        // identity survives Voice, hold progress and every transient action face.
        let layerIdentityBorder = CAGradientLayer()
        layerIdentityBorder.frame = card.bounds
        layerIdentityBorder.type = .conic
        layerIdentityBorder.startPoint = CGPoint(x: 0.5, y: 0.5)
        layerIdentityBorder.endPoint = CGPoint(x: 0.5, y: 0)
        layerIdentityBorder.locations = [0, 0.18, 0.43, 0.72, 1]
        layerIdentityBorder.zPosition = 100
        let identityMask = CAShapeLayer()
        identityMask.frame = layerIdentityBorder.bounds
        identityMask.path = CGPath(
            roundedRect: layerIdentityBorder.bounds.insetBy(dx: 0.72, dy: 0.72),
            cornerWidth: cornerRadius - 0.72,
            cornerHeight: cornerRadius - 0.72,
            transform: nil
        )
        identityMask.fillColor = NSColor.clear.cgColor
        identityMask.strokeColor = NSColor.white.cgColor
        identityMask.lineWidth = 1.35
        layerIdentityBorder.mask = identityMask
        card.layer?.addSublayer(layerIdentityBorder)

        root.addSubview(card)
        panel.contentView = root
        return Surface(panel: panel, cardView: card, cardLayer: card.layer!,
                       tintLayer: tintLayer,
                       layerIdentityAura: layerIdentityAura,
                       layerIdentityBorder: layerIdentityBorder,
                       accentLayer: accent, glowLayer: glow,
                       holdProgressContainer: holdProgress,
                       holdProgressWaterRoot: holdWaterRoot,
                       holdProgressBackWave: holdBackWave,
                       holdProgressFrontWave: holdFrontWave,
                       holdProgressCrest: holdCrest,
                       holdProgressGlassRoot: holdGlassRoot,
                       holdProgressGlassBloom: holdGlassBloom,
                       holdProgressGlassBands: holdGlassBands,
                       holdProgressGlassCaustics: holdGlassCaustics,
                       holdProgressRim: holdRim,
                       rippleLayers: ripples,
                       voiceAmbientLayer: voiceAmbient,
                       voiceWaveformLayer: voiceWaveform,
                       voiceBaselineLayer: voiceBaseline,
                       voiceBarLayers: voiceBars,
                       voiceBarHighlightLayers: voiceHighlights,
                       voiceHeaderLabel: voiceHeader, voiceLiveLabel: voiceLive,
                       voicePitchLabel: voicePitch, voiceBrightnessLabel: voiceBrightness,
                       contentView: content, normalContentView: normalContent, iconView: icon,
                       titleLabel: title, subtitleLabel: subtitle)
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
