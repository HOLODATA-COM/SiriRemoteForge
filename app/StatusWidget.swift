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
import QuartzCore

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

    private struct Face {
        let key: String
        let title: String
        let subtitle: String
        let image: NSImage?
        let tint: NSColor
    }

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

    private struct Surface {
        let panel: StatusPanel
        let cardView: NSVisualEffectView
        let cardLayer: CALayer
        let tintLayer: CAGradientLayer
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
    private var currentLayerID = "BASE"
    private var currentPresentationKey: String?
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
    private var voiceHistory = [VoiceVisualSample](repeating: .silence, count: 25)
    private var voicePitchBaselineLog2: CGFloat?
    private var voiceSmoothedPitchLog2: CGFloat?
    private var voicePitchPosition: CGFloat = 0
    private var voicePitchConfidence: CGFloat = 0
    private var voiceBrightness: CGFloat = 0
    private var voiceLastVoicedAt: CFTimeInterval = 0
    private var voiceNeutralTint = NSColor.systemBlue
    private var voiceStartedAt: CFTimeInterval = 0
    private var voiceLastReadoutTick = -1
    private var contentMorphGeneration = 0
    private var contentMorphProxyViews: [NSView] = []
    private var releasedHold: (key: String, time: CFTimeInterval)?
    private var observerTokens: [NSObjectProtocol] = []
    /// A launch binding announces the destination before AppWatcher observes activation. Remember
    /// that app for a moment so the confirmed activation updates the subtitle instead of producing
    /// a second, visually noisy bounce of the same icon.
    private var pendingActivation: (name: String, time: CFTimeInterval)?
    private var lastEvent: (key: String, time: CFTimeInterval)?

    init(layers: [Config.LayerDefinition], enabled: Bool,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.surface = Self.makeSurface(windowSize: windowSize, cardFrame: cardFrame,
                                        cornerRadius: cornerRadius)
        super.init()
        surface.panel.delegate = self
        configureHoldProgressVisualStyle()
        normalize(layers)

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

    func configure(layers: [Config.LayerDefinition], enabled: Bool) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.normalize(layers)
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
            let previousLayerID = self.currentLayerID
            let destinationLayerID = layer?.uppercased() ?? "BASE"
            self.currentLayerID = destinationLayerID
            self.idleGeneration += 1
            guard !self.isHolding else { return }
            self.isTransient = false
            guard self.enabled else { return }
            self.present(self.idleFace(), animated: animated, returningToIdle: false,
                         layerRoll: animated && previousLayerID != destinationLayerID)
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
            self.idleGeneration += 1
            if self.isHolding {
                self.isHolding = false
                self.holdGeneration += 1
                self.holdBase = nil
                self.holdStages = []
                self.activeHoldKey = nil
                self.holdVisualIsVisible = false
                self.cancelHoldVisualWork()
                self.stopHoldProgress(immediate: true)
                self.setVoiceWaveformActive(false, immediate: true)
                self.stopHoldRipple(immediate: true)
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
                            image: info.icon, tint: self.tint(forBundleID: bundleID))
            self.presentTransient(face, duration: duration, animate: !confirmsPendingLaunch)
        }
    }

    func showAction(_ handled: Controller.HandledAction,
                    durationOverride: TimeInterval? = nil) {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isConnected, !self.isHolding else { return }
            // Layer actions already produce `setLayer` with the actual destination name/colour.
            // Showing their implementation label ("Next Layer") first is redundant and noisy.
            switch handled.action {
            case .layer, .layerCycle: return
            default: break
            }
            let now = CACurrentMediaTime()
            // A release-to-select action is reported immediately after `endHold`. Its face is
            // already on screen and has been visible for the whole hold, so only extend the dwell;
            // bouncing it again on key-up makes a frequent interaction feel nervous.
            if let released = self.releasedHold,
               released.key == handled.key, now - released.time < 0.30 {
                self.releasedHold = nil
                self.lastEvent = (handled.key, now)
                self.scheduleIdle(after: 0.48)
                return
            }
            self.releasedHold = nil
            // Keep a held media/repeat action from re-springing the card on every timer tick. A
            // multi-tap gesture resolves to its own `.double`/`.triple` key and still animates; two
            // very fast identical base events share one visible pulse but extend its dwell.
            if let previous = self.lastEvent,
               previous.key == handled.key, now - previous.time < 0.22 {
                self.lastEvent = (handled.key, now)
                self.scheduleIdle(after: self.duration(for: handled.key, action: handled.action))
                return
            }
            self.lastEvent = (handled.key, now)

            let face = self.actionFace(key: handled.key, action: handled.action,
                                       presentation: handled.presentation,
                                       subtitle: self.gestureLabel(for: handled.key))

            if let launched = self.launchedAppName(handled.action) {
                self.pendingActivation = (launched, now)
            } else {
                self.pendingActivation = nil
            }
            self.presentTransient(face,
                                  duration: durationOverride
                                      ?? self.duration(for: handled.key, action: handled.action),
                                  animate: true)
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

            // Match the large HUD's deliberate 0.18 s visual lead-in. This preview does not
            // claim the gesture: the base action is still what release selects until the first
            // real threshold. Showing it early leaves enough visible runway for the selected
            // whole-card treatment instead of making progress appear at the first boundary.
            let now = CACurrentMediaTime()
            if !self.holdStages.isEmpty {
                let delay = max(0, startedAt + self.holdProgressAppearDelay - now)
                let previewWork = DispatchWorkItem { [weak self] in
                    guard let self = self, self.enabled, self.isHolding,
                          self.holdGeneration == generation else { return }
                    self.holdVisualIsVisible = true
                    self.startHoldRipple()
                    self.startHoldProgress(startedAt: startedAt)

                    // A Layer base action is implementation state (for example layerCycle), not a
                    // useful face. Keep the actual current Layer visible and let whole-card progress
                    // carry the progress until its first real non-layer stage arrives.
                    if let base = self.holdBase, !self.isLayerStateAction(base.action) {
                        let nextLabel = self.holdStages.first.map {
                            ActionVisual.resolve($0.item.action, $0.item.presentation,
                                                 prefersTargetAppIcon: false).label
                        }
                        self.presentHold(base,
                                         subtitle: nextLabel.map { L("Hold for %@", $0) }
                                             ?? L("Keep holding"),
                                         animated: true)
                    }
                }
                self.holdVisualWorkItems.append(previewWork)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: previewWork)
            }

            // Every action face still changes at the real input threshold, using the immutable
            // startedAt anchor shared with release selection. If a stage is unusually earlier than
            // the 0.18 s preview, start the progress surface there so feedback never trails an action already
            // selected by the input state machine.
            for stage in self.holdStages {
                let delay = max(0, startedAt + stage.threshold - now)
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.enabled, self.isHolding,
                          self.holdGeneration == generation else { return }
                    // Layer actions are state transitions, not useful previews. The actual
                    // destination arrives through Controller.onLayerChanged and is the only layer
                    // face this widget should ever show.
                    guard !self.isLayerStateAction(stage.item.action) else { return }
                    if !self.holdVisualIsVisible {
                        self.holdVisualIsVisible = true
                        self.startHoldRipple()
                        self.startHoldProgress(startedAt: startedAt)
                    }
                    self.presentHold(
                        stage.item,
                        subtitle: stage.item.isCancel
                            ? L("Release to cancel")
                            : L("Release to choose"),
                        animated: true
                    )
                }
                self.holdVisualWorkItems.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

            let hadVisibleHold = self.holdVisualIsVisible
            self.isHolding = false
            self.holdVisualIsVisible = false
            self.holdGeneration += 1
            self.cancelHoldVisualWork()
            self.stopHoldRipple()
            self.stopHoldProgress()
            self.setVoiceWaveformActive(false)
            let selectedIsLayer = selected.map { self.isLayerStateAction($0.action) } ?? false
            if selectedIsLayer {
                // A quick layer-cycle tap used to pass through `presentHold` here and briefly show
                // “Next Layer” even though showAction correctly suppressed it later. Return straight
                // to the already-updated destination Layer instead.
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
            self.activeHoldKey = nil
            if selectedIsLayer { return }
            self.scheduleIdle(after: selected?.isCancel == true ? 0.36 : 0.48)
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

    func endContinuousAction(key: String) {
        onMain { [weak self] in
            guard let self = self, self.isHolding else { return }
            // Only close the session that opened this key; a stale release from another mirrored
            // HID interface must not dismiss a newer continuous action.
            guard self.holdBase?.key == key else { return }
            if let base = self.holdBase, case .pushToTalk = base.action {
                self.endVoiceHold()
                return
            }
            self.endHold(firedIndex: 0)
        }
    }

    /// Voice is a mode of the same compact surface, not a navigated page. On release, return
    /// directly to the current Layer underneath the console; never expose a temporary Completed
    /// face or route through the ordinary left/right action transition.
    private func endVoiceHold() {
        isHolding = false
        holdVisualIsVisible = false
        holdGeneration += 1
        idleGeneration += 1
        cancelHoldVisualWork()
        stopHoldRipple()
        stopHoldProgress()

        let destination = idleFace()
        setVoiceWaveformActive(false)
        configure(face: destination)
        applyColors(destination.tint, animated: true)
        currentPresentationKey = destination.key
        isTransient = false
        releasedHold = nil
        holdBase = nil
        holdStages = []
        activeHoldKey = nil
    }

    /// Real acoustic samples from BuiltinMicFeeder. Every bar retains its own loudness, relative
    /// pitch colour, voicing confidence, and spectral brightness, creating a short sound signature
    /// rather than a decorative time-based animation.
    func updateVoiceMeter(_ sample: VoiceMeterSample) {
        onMain { [weak self] in
            guard let self = self, self.enabled, self.isVoiceWaveformActive else { return }
            self.voiceHistory.removeFirst()
            self.voiceHistory.append(self.voiceVisualSample(from: sample))
            self.renderVoiceBars(animated: true)
        }
    }

    private func voiceVisualSample(from sample: VoiceMeterSample) -> VoiceVisualSample {
        let level = CGFloat(min(1, max(0, sample.level.isFinite ? sample.level : 0)))
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
        currentPresentationKey = nil
        surface.cardLayer.removeAnimation(forKey: "widgetDisappear")
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
        isHolding = false
        holdGeneration += 1
        holdBase = nil
        holdStages = []
        activeHoldKey = nil
        holdVisualIsVisible = false
        cancelHoldVisualWork()
        stopHoldProgress(immediate: true)
        setVoiceWaveformActive(false, immediate: true)
        stopHoldRipple(immediate: true)

        let restoreTransform = { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.surface.cardLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        guard animated else {
            surface.panel.alphaValue = 0
            surface.panel.orderOut(nil)
            restoreTransform()
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
            restoreTransform()
        })
    }

    /// The refined entrance: the card springs up from small with a warm ring breathing outward and
    /// the icon pops. A plain fade stands in when Reduce Motion is on.
    private func animateWidgetAppear() {
        surface.cardLayer.removeAnimation(forKey: "widgetDisappear")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.74, 1.06, 0.99, 1.0]
        scale.keyTimes = [0.0, 0.55, 0.82, 1.0]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [-10.0, 1.5, 0.0]
        rise.keyTimes = [0.0, 0.72, 1.0]
        let group = CAAnimationGroup()
        group.animations = [scale, rise]
        group.duration = 0.60
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.18, 1.0)
        surface.cardLayer.add(group, forKey: "widgetAppear")

        let iconPop = CAKeyframeAnimation(keyPath: "transform.scale")
        iconPop.values = [0.5, 1.14, 0.98, 1.0]
        iconPop.keyTimes = [0.0, 0.55, 0.80, 1.0]
        iconPop.duration = 0.56
        iconPop.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.20, 1.0)
        surface.iconView.layer?.add(iconPop, forKey: "widgetAppearIcon")

        for (index, ripple) in surface.rippleLayers.enumerated() {
            ripple.removeAnimation(forKey: "holdRipple")
            let rScale = CAKeyframeAnimation(keyPath: "transform.scale")
            rScale.values = [0.90, 1.16]
            rScale.keyTimes = [0.0, 1.0]
            let rOpacity = CAKeyframeAnimation(keyPath: "opacity")
            rOpacity.values = [0.0, 0.50, 0.0]
            rOpacity.keyTimes = [0.0, 0.30, 1.0]
            let rGroup = CAAnimationGroup()
            rGroup.animations = [rScale, rOpacity]
            rGroup.duration = 0.90
            rGroup.beginTime = ripple.convertTime(CACurrentMediaTime(), from: nil)
                + 0.08 + Double(index) * 0.14
            rGroup.fillMode = .backwards
            rGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(rGroup, forKey: "widgetAppearRing")
        }
    }

    /// The precise exit: a small anticipation, then the card sinks and contracts as it fades. The
    /// alpha fade and this run for the same duration, so the scale never visibly snaps back.
    private func animateWidgetDisappear() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.03, 0.90]
        scale.keyTimes = [0.0, 0.26, 1.0]
        let sink = CAKeyframeAnimation(keyPath: "transform.translation.y")
        sink.values = [0.0, 1.0, -6.0]
        sink.keyTimes = [0.0, 0.26, 1.0]
        let group = CAAnimationGroup()
        group.animations = [scale, sink]
        group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.70, 0.30)
        surface.cardLayer.add(group, forKey: "widgetDisappear")
    }

    private func presentTransient(_ face: Face, duration: TimeInterval, animate: Bool) {
        isTransient = true
        present(face, animated: animate, returningToIdle: false)
        scheduleIdle(after: duration)
    }

    private func scheduleIdle(after duration: TimeInterval) {
        idleGeneration += 1
        let generation = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.enabled, self.idleGeneration == generation else { return }
            self.isTransient = false
            self.present(self.idleFace(), animated: true, returningToIdle: true)
        }
    }

    private func present(_ face: Face, animated: Bool, returningToIdle: Bool,
                         layerRoll: Bool = false) {
        // Content updates never surface the panel while it is intentionally hidden (no remote).
        guard enabled, isConnected else { return }
        ensureReachable()
        surface.panel.orderFrontRegardless()
        let contentChanges = currentPresentationKey != face.key
        let outgoing = animated && contentChanges ? makeNormalContentProxy() : nil
        applyColors(face.tint, animated: animated && contentChanges)
        configure(face: face)
        currentPresentationKey = face.key
        if animated {
            if layerRoll && contentChanges {
                animateLayerElementMorph(from: outgoing)
            } else if contentChanges {
                animateContentTransition(from: outgoing, returningToIdle: returningToIdle)
            } else {
                animateCardResponse()
            }
        }
    }

    private func presentHold(_ item: HoldItem, subtitle: String, animated: Bool) {
        guard !isLayerStateAction(item.action) else { return }
        let face = actionFace(key: item.key, action: item.action,
                              presentation: item.presentation, subtitle: subtitle)
        activeHoldKey = item.key
        present(face, animated: animated, returningToIdle: false)
    }

    private func cancelHoldVisualWork() {
        holdVisualWorkItems.forEach { $0.cancel() }
        holdVisualWorkItems.removeAll()
    }

    private func configure(face: Face) {
        surface.iconView.image = face.image
        surface.iconView.contentTintColor = face.image?.isTemplate == true
            ? (isHoldProgressActive ? .white : face.tint) : nil
        surface.titleLabel.stringValue = face.title
        surface.subtitleLabel.stringValue = face.subtitle
        applyHoldContentContrast()
        applyColors(face.tint, animated: false)
        currentPresentationKey = face.key
    }

    // MARK: - Faces

    private func actionFace(key: String, action: Action,
                            presentation: Config.Presentation?, subtitle: String) -> Face {
        let visual = ActionVisual.resolve(action, presentation, prefersTargetAppIcon: false)
        return Face(key: "action:\(key):\(visual.label)",
                    title: visual.label,
                    subtitle: subtitle,
                    image: visual.image,
                    tint: tint(for: action))
    }

    private func isLayerStateAction(_ action: Action) -> Bool {
        switch action {
        case .layer, .layerCycle: return true
        default: return false
        }
    }

    private func idleFace() -> Face {
        let appearance = layerAppearance(currentLayerID)
        return Face(key: "layer:\(currentLayerID)", title: appearance.label,
                    subtitle: L("Current Layer"),
                    image: symbol("square.stack.3d.up.fill", size: 26),
                    tint: appearance.tint)
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

    private func layerAppearance(_ rawID: String) -> (label: String, tint: NSColor) {
        let id = rawID.uppercased()
        let definition = configuredLayers[id]
        let explicitName = definition?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = explicitName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLayerName(id)
        let tint = definition?.color.flatMap(configuredColor) ?? fallbackLayerTint(id)
        return (label, tint)
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

    private func tint(for action: Action) -> NSColor {
        switch action {
        case .media: return .systemPink
        case .launch, .appWheel: return .systemIndigo
        case .space, .fullscreen, .minimize, .closeWindow: return .systemBlue
        case .mouse: return .systemTeal
        case .brightness: return .systemOrange
        case .pushToTalk: return .systemRed
        case .layer, .layerCycle: return layerAppearance(currentLayerID).tint
        default: return .controlAccentColor
        }
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
        return label
    }

    private func makeNormalContentProxy() -> NormalContentProxy {
        contentMorphGeneration += 1
        contentMorphProxyViews.forEach { $0.removeFromSuperview() }
        contentMorphProxyViews.removeAll()

        for layer in [surface.iconView.layer, surface.titleLabel.layer,
                      surface.subtitleLabel.layer].compactMap({ $0 }) {
            layer.removeAnimation(forKey: "contentMorphIncoming")
            layer.removeAnimation(forKey: "layerMorphIncoming")
        }

        let icon = copiedIconView(surface.iconView)
        let title = copiedLabel(surface.titleLabel)
        let subtitle = copiedLabel(surface.subtitleLabel)
        let proxy = NormalContentProxy(iconView: icon, titleLabel: title,
                                       subtitleLabel: subtitle)
        for view in proxy.views { surface.contentView.addSubview(view) }

        let pairs: [(CALayer?, CALayer?)] = [
            (surface.iconView.layer, icon.layer),
            (surface.titleLabel.layer, title.layer),
            (surface.subtitleLabel.layer, subtitle.layer),
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (source, destination) in pairs {
            destination?.opacity = source?.presentation()?.opacity ?? source?.opacity ?? 1
            destination?.transform = source?.presentation()?.transform ?? CATransform3DIdentity
        }
        CATransaction.commit()
        contentMorphProxyViews = proxy.views
        return proxy
    }

    private func finishContentMorph(generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.contentMorphGeneration == generation else { return }
            self.contentMorphProxyViews.forEach { $0.removeFromSuperview() }
            self.contentMorphProxyViews.removeAll()
        }
    }

    /// Layer changes use the same physical flip as ordinary actions. The unchanged
    /// "Current Layer" subtitle stays in place while the icon and layer name reveal their backs.
    private func animateLayerElementMorph(from proxy: NormalContentProxy?) {
        animateElementFlip(from: proxy, direction: 1, animateSubtitle: false)
    }

    private func animateContentTransition(from proxy: NormalContentProxy?,
                                          returningToIdle: Bool) {
        animateElementFlip(from: proxy,
                           direction: returningToIdle ? -1 : 1,
                           animateSubtitle: true)
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
                                          delay: CFTimeInterval) {
        guard let layer = container.layer else { return }
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
        turn.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
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
        frontVisibility.beginTime = frontLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        frontVisibility.fillMode = .both
        frontVisibility.isRemovedOnCompletion = false
        frontLayer.add(frontVisibility, forKey: "twoSidedFrontVisibility")

        let backVisibility = CAKeyframeAnimation(keyPath: "opacity")
        backVisibility.values = [0, 0, 1, 1]
        backVisibility.keyTimes = [0, 0.47, 0.49, 1]
        backVisibility.duration = duration
        backVisibility.beginTime = backLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
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
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.986, 1.012, 0.998, 1.0]
        scale.keyTimes = [0.0, 0.20, 0.56, 0.82, 1.0]

        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0.0, -1.0, 0.7, -0.2, 0.0]
        hop.keyTimes = scale.keyTimes

        let group = CAAnimationGroup()
        group.animations = [scale, hop]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1.0)
        surface.cardLayer.add(group, forKey: "statusSpring")

        let iconScale = CAKeyframeAnimation(keyPath: "transform.scale")
        iconScale.values = [0.92, 1.035, 0.99, 1.0]
        iconScale.keyTimes = [0.0, 0.50, 0.78, 1.0]
        iconScale.duration = 0.28
        iconScale.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.22, 1.0)]
        surface.iconView.layer?.add(iconScale, forKey: "statusIconSpring")

        // A flat circular glow used to pulse here. Once the icon folded away it was exposed as a
        // stray coloured dot, so the icon response now carries the feedback by itself.
    }

    private func animateCardReveal() {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.94, 1.01, 0.998, 1.0]
        scale.keyTimes = [0.0, 0.58, 0.82, 1.0]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [-3.0, 0.5, 0.0]
        rise.keyTimes = [0.0, 0.70, 1.0]
        let group = CAAnimationGroup()
        group.animations = [scale, rise]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0)
        surface.cardLayer.add(group, forKey: "statusReveal")
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
        renderHoldProgress(at: holdProgressLastTick)

        if surface.iconView.image?.isTemplate == true {
            surface.iconView.contentTintColor = .white
        }

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
        // Keep white hold typography until the progress layer is actually gone. Restoring semantic
        // secondary colours at release used to create one muddy frame over the still-visible fill.
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

        // Same stage calculation as HoldTiming/large HUD: the number of thresholds crossed. The
        // final stage remains complete; an intermediate boundary clears the selected treatment
        // before the next stage continues from its already-running absolute time.
        var stage = 0
        for item in holdStages where elapsed >= item.threshold { stage += 1 }
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

    /// The selected whole-card treatment travels behind every label, not only the icon.
    /// Hold-specific contrast keeps both typographic levels legible over its brightest region, then
    /// restores semantic macOS colours as soon as the progress surface dismisses.
    private func applyHoldContentContrast() {
        surface.titleLabel.textColor = isHoldProgressActive ? .white : .labelColor
        surface.subtitleLabel.textColor = isHoldProgressActive
            ? NSColor.white.withAlphaComponent(0.80) : .secondaryLabelColor
    }

    private func setVoiceWaveformActive(_ active: Bool, immediate: Bool = false) {
        guard active != isVoiceWaveformActive else { return }
        isVoiceWaveformActive = active
        if active || immediate {
            voiceHistory = [VoiceVisualSample](repeating: .silence,
                                               count: surface.voiceBarLayers.count)
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

    private func updateVoiceReadouts(with sample: VoiceVisualSample) {
        guard isVoiceWaveformActive else { return }
        let elapsed = max(0, CACurrentMediaTime() - voiceStartedAt)
        let tick = Int(elapsed * 10)
        guard tick != voiceLastReadoutTick else { return }
        voiceLastReadoutTick = tick

        surface.voiceHeaderLabel.stringValue = "VOICE"
        let minutes = Int(elapsed) / 60
        let seconds = elapsed - Double(minutes * 60)
        let liveText = String(format: "● LIVE  %02d:%04.1f", minutes, seconds)
        surface.voiceLiveLabel.attributedStringValue = Self.voiceLiveAttributedText(
            liveText, font: surface.voiceLiveLabel.font
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
        surface.voiceBrightnessLabel.stringValue = String(
            format: "BRIGHT  %02d%%", Int((sample.brightness * 100).rounded())
        )
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

    private static func voiceLiveAttributedText(_ text: String, font: NSFont?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.82),
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

    private func applyColors(_ tint: NSColor, animated: Bool) {
        let dark = surface.panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tintRGB = tint.usingColorSpace(.deviceRGB) ?? tint
        let colors = [
            tintRGB.withAlphaComponent(dark ? 0.22 : 0.13).cgColor,
            tintRGB.withAlphaComponent(dark ? 0.07 : 0.035).cgColor,
            NSColor.clear.cgColor,
        ]
        let border = tintRGB.withAlphaComponent(dark ? 0.34 : 0.25).cgColor
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
        let oldBorder = surface.cardLayer.presentation()?.borderColor ?? surface.cardLayer.borderColor
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
        surface.cardLayer.borderColor = border
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

        let borderAnimation = CABasicAnimation(keyPath: "borderColor")
        borderAnimation.fromValue = oldBorder
        borderAnimation.toValue = border
        borderAnimation.duration = 0.22
        borderAnimation.timingFunction = timing
        surface.cardLayer.add(borderAnimation, forKey: "statusBorder")

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

        let card = NSVisualEffectView(frame: cardFrame)
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.7

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
            label.textColor = NSColor.white.withAlphaComponent(0.82)
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
        voiceHeader.textColor = NSColor.white.withAlphaComponent(0.92)
        let voiceLive = voiceReadout("● LIVE  00:00.0",
                                     frame: NSRect(x: 91, y: 56, width: 99, height: 10),
                                     alignment: .right)
        voiceLive.attributedStringValue = voiceLiveAttributedText(
            "● LIVE  00:00.0", font: voiceLive.font
        )
        let voicePitch = voiceReadout("PITCH  ···",
                                      frame: NSRect(x: 14, y: 5, width: 112, height: 10))
        let voiceBrightness = voiceReadout("BRIGHT  00%",
                                           frame: NSRect(x: 119, y: 5, width: 71, height: 10),
                                           alignment: .right)

        card.addSubview(content)
        root.addSubview(card)
        panel.contentView = root
        return Surface(panel: panel, cardView: card, cardLayer: card.layer!,
                       tintLayer: tintLayer, accentLayer: accent, glowLayer: glow,
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
