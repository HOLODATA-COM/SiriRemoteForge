//
//  VoicePipelineHUD.swift
//  HyperVibe
//
//  A temporary, Typeless-style Voice capsule.  It is intentionally independent from the optional
//  always-on Layer widget: native dictation must still have immediate visual feedback when that
//  widget is disabled.  The capsule never activates HyperVibe, never changes size between states,
//  joins every Space, and follows the display containing the pointer. Each Voice turn begins at
//  the lower centre of that display; the user may drag it for the lifetime of the current turn.
//

import AppKit
import CoreGraphics
import QuartzCore
import Symbols

/// Pure placement math kept outside AppKit's live screen objects so cross-display behaviour can be
/// regression-tested without moving a real window or requiring a second monitor in CI.
enum VoicePipelineScreenPlacement {
    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    static func defaultOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX - windowSize.width / 2,
                y: visibleFrame.minY + 48)
    }
}

/// Authored motion for the temporary Voice capsule. The window never changes geometry: a centred
/// aperture reveals or clips the existing surface, which keeps the material, text and waveform
/// rasterised at their final size while still producing the requested CRT-like motion.
enum VoicePipelineApertureMotion {
    static let entranceDuration: CFTimeInterval = 0.205
    static let exitDuration: CFTimeInterval = 0.155

    static let entranceScales: [CGSize] = [
        CGSize(width: 0.006, height: 0.035), // phosphor point
        CGSize(width: 0.48, height: 0.035),  // centre line opens to both sides
        CGSize(width: 1.0, height: 0.32),    // line blooms into a shallow band
        CGSize(width: 1.0, height: 1.0),
    ]
    static let entranceKeyTimes: [NSNumber] = [0, 0.28, 0.67, 1]

    static let exitScales: [CGSize] = [
        CGSize(width: 1.0, height: 1.0),
        CGSize(width: 1.0, height: 0.040),   // picture collapses to the CRT scan line
        CGSize(width: 0.30, height: 0.028),
        CGSize(width: 0.006, height: 0.020), // line snaps back to the centre
    ]
    static let exitKeyTimes: [NSNumber] = [0, 0.52, 0.82, 1]
}

final class VoicePipelineHUDController: NSObject, NSWindowDelegate {
    private final class PipelinePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class DragSurface: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    private final class AdaptiveMaterial: NSVisualEffectView {
        var appearanceDidChange: (() -> Void)?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in self?.appearanceDidChange?() }
        }
    }

    private struct AcousticFrame {
        let level: CGFloat
        let pitchPosition: CGFloat
        let pitchConfidence: CGFloat
        let brightness: CGFloat
        static let silence = AcousticFrame(level: 0, pitchPosition: 0,
                                           pitchConfidence: 0, brightness: 0)
    }

    private struct Surface {
        let panel: PipelinePanel
        let card: AdaptiveMaterial
        let apertureMask: CAShapeLayer
        let ambient: CAGradientLayer
        let border: CAShapeLayer
        let arcTrack: CAShapeLayer
        let arcProgress: CAShapeLayer
        let iconView: NSImageView
        let title: CATextLayer
        let detail: CATextLayer
        let mode: CATextLayer
        let waveform: CALayer
        let baseline: CALayer
        let bars: [CALayer]
        let highlights: [CALayer]
    }

    private enum ExitStyle {
        case standard
        case streamingRelease
    }

    private let windowSize = NSSize(width: 312, height: 84)
    private let cardFrame = NSRect(x: 6, y: 12, width: 300, height: 60)
    private let surface: Surface
    private var configuredIcons: [String: String] = [:]
    private var enabled = true
    private var visible = false
    private var listening = false
    private var awaitingReleasePhase = false
    private var currentStage: VoicePipelineVisualStage?
    /// Non-nil only while the hardware mode-switch confirmation owns this temporary capsule.
    /// External never sets it: that route intentionally has no Voice floating window.
    private var currentModePreview: Config.DictationMode?
    private var currentSymbolName: String?
    private var appearanceGeneration = 0
    private var transitionGeneration = 0
    private var moveGeneration = 0
    private var isMovingProgrammatically = false
    private var presentationDisplayID: CGDirectDisplayID?
    private var cursorScreenTimer: Timer?
    private var cursorFollowSuppressedUntil: CFTimeInterval = 0
    private var transientLayers: [CALayer] = []
    private var history = [AcousticFrame](repeating: .silence, count: 21)
    private var normalizer = VoiceWaveformLevelNormalizer()
    private var pitchBaselineLog2: CGFloat?
    private var smoothedPitchLog2: CGFloat?
    private var pitchPosition: CGFloat = 0
    private var pitchConfidence: CGFloat = 0
    private var brightness: CGFloat = 0
    private var lastVoicedAt: CFTimeInterval = 0
    private var meterSuppressedUntil: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init(icons: [String: String] = [:], enabled: Bool = true) {
        self.configuredIcons = icons
        self.enabled = enabled
        self.surface = Self.makeSurface(windowSize: windowSize, cardFrame: cardFrame)
        super.init()
        surface.panel.delegate = self
        surface.card.appearanceDidChange = { [weak self] in self?.applyMaterialContrast() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.screenParametersChanged() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.activeSpaceChanged() })
        observers.append(NotificationCenter.default.addObserver(
            forName: Loc.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.relocalize() })
        applyMaterialContrast()
        applyPalette(.systemRed, animated: false)
    }

    deinit {
        cursorScreenTimer?.invalidate()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func configure(icons: [String: String], enabled: Bool) {
        onMain { [weak self] in
            guard let self else { return }
            self.configuredIcons = icons
            self.enabled = enabled
            if !enabled { self.hide(animated: true) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        onMain { [weak self] in
            guard let self else { return }
            self.enabled = enabled
            if !enabled { self.hide(animated: true) }
        }
    }

    /// Called only after the side button has crossed the existing native-Voice hold threshold.
    /// Priming a quick tap never opens this panel.
    func beginListening() {
        onMain { [weak self] in
            guard let self, self.enabled else { return }
            self.transitionGeneration += 1
            self.clearTransientLayers()
            self.cancelInFlightExitForNewPresentation()
            self.listening = true
            self.awaitingReleasePhase = false
            self.currentStage = nil
            self.currentModePreview = nil
            self.normalizer.reset()
            self.pitchBaselineLog2 = nil
            self.smoothedPitchLog2 = nil
            self.pitchPosition = 0
            self.pitchConfidence = 0
            self.brightness = 0
            self.lastVoicedAt = 0
            self.history = [AcousticFrame](repeating: .silence, count: self.surface.bars.count)
            self.renderWaveform(animated: false)
            self.configureListeningFace()
            // A drag is intentionally turn-local. Every fresh press returns to a predictable
            // Typeless-style anchor on whichever display currently owns the pointer.
            self.restorePositionForPresentation()
            self.prepareListeningEntrance()
            self.showIfNeeded(animateAlpha: false)
            self.animateListeningEntrance()
        }
    }

    /// Stops accepting acoustic frames at physical key-up while preserving the last silhouette.
    /// The immediately following Final/Streaming phase decides whether it crystallises or exits.
    func endListening() {
        onMain { [weak self] in
            self?.listening = false
            self?.awaitingReleasePhase = true
        }
    }

    func suppressMeter(for duration: TimeInterval) {
        onMain { [weak self] in
            guard let self, duration.isFinite, duration > 0 else { return }
            self.meterSuppressedUntil = CACurrentMediaTime() + min(1, duration)
            self.normalizer.reset()
            self.history = [AcousticFrame](repeating: .silence, count: self.surface.bars.count)
            self.renderWaveform(animated: false)
        }
    }

    func updateVoiceMeter(_ sample: VoiceMeterSample) {
        onMain { [weak self] in
            guard let self, self.enabled, self.visible, self.listening,
                  CACurrentMediaTime() >= self.meterSuppressedUntil else { return }
            self.history.removeFirst()
            self.history.append(self.acousticFrame(from: sample))
            self.renderWaveform(animated: true)
        }
    }

    /// Confirm a global mode selected with Mute+Side. Final and Live briefly use this independent
    /// Voice capsule as well as the compact status widget; External only dismisses an existing mode
    /// preview and otherwise stays absent by design.
    func showVoiceModeSwitch(_ mode: Config.DictationMode) {
        onMain { [weak self] in
            guard let self, self.enabled else { return }

            if !VoiceModePresentationPolicy.showsFloatingCapsule(for: mode) {
                if self.currentModePreview != nil {
                    self.hide(animated: true)
                }
                return
            }

            // Never overwrite a real capture or a post-capture delivery state. A turn freezes its
            // own mode, and its truthful progress is more important than a selector confirmation.
            guard !self.listening, !self.awaitingReleasePhase, self.currentStage == nil else {
                return
            }

            self.transitionGeneration += 1
            let generation = self.transitionGeneration
            let replacingPreview = self.visible && self.currentModePreview != nil
            self.clearTransientLayers()
            self.cancelInFlightExitForNewPresentation()
            self.currentModePreview = mode
            self.configureModeSwitchFace(mode, replacing: replacingPreview,
                                         generation: generation)
            self.showIfNeeded()
            self.animateModeSwitch(mode, replacing: replacingPreview)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.86) { [weak self] in
                guard let self, self.transitionGeneration == generation,
                      self.currentModePreview == mode,
                      !self.listening, self.currentStage == nil else { return }
                self.hide(animated: true)
            }
        }
    }

    func showNativeDictationPhase(_ phase: VoiceDictationPhase, message: String) {
        onMain { [weak self] in
            guard let self, self.enabled else { return }
            switch phase {
            case .priming, .listening:
                return
            case .idle:
                let releasedFromStreaming = self.awaitingReleasePhase
                self.awaitingReleasePhase = false
                self.hide(animated: true,
                          exitStyle: releasedFromStreaming ? .streamingRelease : .standard)
            case .transcribing, .polishing, .inserting, .inserted, .copied, .error:
                guard let stage = VoicePipelineVisualStage(phase) else { return }
                self.transition(to: stage, message: message)
            }
        }
    }

    func hideImmediately() { onMain { [weak self] in self?.hide(animated: false) } }

    // MARK: - State composition

    private func configureListeningFace() {
        let symbolName = configuredSymbol(key: "voice.listening",
                                          fallback: "waveform.circle.fill")
        setIcon(symbolName, tint: .systemRed, cue: .voice, animated: currentSymbolName != nil)
        setText(surface.title, L("Listening"))
        setText(surface.detail, L("Release to finish"))
        setText(surface.mode, "● LIVE")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.title.opacity = 0
        surface.detail.opacity = 0
        surface.mode.opacity = 1
        surface.waveform.opacity = 1
        surface.arcProgress.strokeStart = 0.04
        surface.arcProgress.strokeEnd = 0.16
        CATransaction.commit()
        applyPalette(.systemRed, animated: true)
    }

    private func configureModeSwitchFace(_ mode: Config.DictationMode,
                                         replacing: Bool, generation: Int) {
        let symbolName = configuredSymbol(key: "voice.mode.\(mode.rawValue)",
                                          fallback: mode.presentationSymbol)
        setIcon(symbolName, tint: mode.presentationTint, cue: mode.presentationCue,
                animated: replacing)
        if replacing {
            animateText(surface.title, to: mode.presentationTitle, delay: 0.012,
                        direction: 1, generation: generation)
            animateText(surface.detail, to: mode.presentationDetail, delay: 0.038,
                        direction: -1, generation: generation)
            animateText(surface.mode, to: mode.presentationBadge, delay: 0.026,
                        direction: 1, generation: generation)
        } else {
            setText(surface.title, mode.presentationTitle)
            setText(surface.detail, mode.presentationDetail)
            setText(surface.mode, mode.presentationBadge)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.title.opacity = 1
        surface.detail.opacity = 1
        surface.mode.opacity = 1
        surface.waveform.opacity = 0
        surface.arcProgress.strokeStart = 0.04
        surface.arcProgress.strokeEnd = 0.72
        CATransaction.commit()
        applyPalette(mode.presentationTint, animated: true)
        animateArc(to: mode == .final ? 0.62 : 0.90, tint: mode.presentationTint)
    }

    private func transition(to stage: VoicePipelineVisualStage, message: String) {
        if !visible { showIfNeeded() }
        transitionGeneration += 1
        let generation = transitionGeneration
        clearTransientLayers()
        let wasListening = awaitingReleasePhase
        awaitingReleasePhase = false
        listening = false
        let oldStage = currentStage
        currentStage = stage
        currentModePreview = nil

        let symbolName = configuredSymbol(key: stage.configIconKey,
                                          fallback: stage.fallbackSymbol)
        applyPalette(stage.tint, animated: true)
        setIcon(symbolName, tint: stage.tint, cue: stage.symbolCue, animated: true)
        if wasListening {
            setText(surface.title, stage.title)
            setText(surface.detail, message)
        } else {
            animateText(surface.title, to: stage.title, delay: 0.018,
                        direction: 1, generation: generation)
            animateText(surface.detail, to: message, delay: 0.044,
                        direction: -1, generation: generation)
        }
        animateText(surface.mode,
                    to: stage.isTerminal ? (stage == .error ? "ATTENTION" : "DONE") : "FINAL",
                    delay: wasListening ? 0.078 : 0.030,
                    direction: 1, generation: generation)
        animateArc(to: stage.progress, tint: stage.tint)
        animateSignalTransfer(stage: stage)

        if wasListening {
            collapseWaveformIntoPipeline(stage: stage, generation: generation)
        } else if oldStage != stage {
            animatePhaseContinuity(stage: stage)
        }
    }

    // MARK: - Acoustic visualization

    private func acousticFrame(from sample: VoiceMeterSample) -> AcousticFrame {
        let level = normalizer.normalize(sample.level)
        let now = CACurrentMediaTime()
        let confidence = CGFloat(sample.pitchConfidence.isFinite
                                 ? min(1, max(0, sample.pitchConfidence)) : 0)
        let voiced = sample.pitchHz.isFinite && sample.pitchHz > 55 && sample.pitchHz < 1_200
            && confidence > 0.52 && level > 0.025
        let rawBrightness = CGFloat(sample.brightness.isFinite
                                    ? min(1, max(0, sample.brightness)) : 0)
        let targetBrightness = rawBrightness * min(1, level * 4)
        brightness += (targetBrightness - brightness) * (targetBrightness > brightness ? 0.34 : 0.13)

        if voiced {
            var logPitch = CGFloat(log2(Double(sample.pitchHz)))
            if let previous = smoothedPitchLog2 {
                while logPitch - previous > 0.5 { logPitch -= 1 }
                while logPitch - previous < -0.5 { logPitch += 1 }
                smoothedPitchLog2 = previous + min(0.20, max(-0.20, logPitch - previous)) * 0.34
            } else {
                smoothedPitchLog2 = logPitch
            }
            if pitchBaselineLog2 == nil { pitchBaselineLog2 = logPitch }
            if let smooth = smoothedPitchLog2, let baseline = pitchBaselineLog2 {
                pitchBaselineLog2 = baseline + min(0.25, max(-0.25, smooth - baseline)) * 0.006
                pitchPosition = min(1, max(-1, (smooth - (pitchBaselineLog2 ?? baseline)) * 12 / 5))
            }
            pitchConfidence = min(1, max(0, (confidence - 0.52) / 0.48))
            lastVoicedAt = now
        } else if lastVoicedAt > 0, now - lastVoicedAt < 0.14 {
            pitchConfidence *= CGFloat(1 - (now - lastVoicedAt) / 0.20)
        } else {
            pitchPosition *= 0.92
            pitchConfidence *= 0.76
        }
        return AcousticFrame(level: level, pitchPosition: pitchPosition,
                             pitchConfidence: pitchConfidence, brightness: brightness)
    }

    private func renderWaveform(animated: Bool) {
        for index in surface.bars.indices {
            let frame = history.indices.contains(index) ? history[index] : .silence
            let bar = surface.bars[index]
            let highlight = surface.highlights[index]
            let height = 3 + frame.level * 30
            let color = acousticColor(frame).cgColor
            let oldHeight = bar.presentation()?.bounds.height ?? bar.bounds.height
            let oldColor = bar.presentation()?.backgroundColor ?? bar.backgroundColor
            let oldHighlight = highlight.presentation()?.opacity ?? highlight.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = height
            bar.backgroundColor = color
            highlight.position.y = max(1.2, height - 1)
            highlight.opacity = Float(frame.level > 0.025
                                      ? 0.08 + frame.brightness * 0.72 : 0.02)
            CATransaction.commit()
            guard animated else { continue }
            animateBasic(bar, keyPath: "bounds.size.height", from: oldHeight, to: height,
                         duration: 0.072, key: "voiceHeight")
            animateBasic(bar, keyPath: "backgroundColor", from: oldColor ?? color,
                         to: color, duration: 0.11, key: "voiceColour")
            animateBasic(highlight, keyPath: "opacity", from: oldHighlight,
                         to: highlight.opacity, duration: 0.09, key: "voiceHighlight")
        }
        if listening {
            let level = history.last?.level ?? 0
            let from = surface.arcProgress.presentation()?.lineWidth
                ?? surface.arcProgress.lineWidth
            let target = 1.7 + level * 1.25
            surface.arcProgress.lineWidth = target
            animateBasic(surface.arcProgress, keyPath: "lineWidth", from: from, to: target,
                         duration: 0.08, key: "listeningArcBreath")
        }
    }

    private func acousticColor(_ frame: AcousticFrame) -> NSColor {
        let neutral = NSColor.systemRed.usingColorSpace(.deviceRGB) ?? .systemRed
        guard frame.pitchConfidence > 0.04 else {
            return neutral.blended(withFraction: frame.brightness * 0.10,
                                   of: .white) ?? neutral
        }
        let low = NSColor(calibratedRed: 0.52, green: 0.34, blue: 1.0, alpha: 1)
        let high = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.48, alpha: 1)
        let voiced = low.blended(withFraction: (frame.pitchPosition + 1) / 2,
                                 of: high) ?? neutral
        let mixed = neutral.blended(withFraction: frame.pitchConfidence * 0.88,
                                    of: voiced) ?? voiced
        return mixed.blended(withFraction: frame.brightness * 0.16, of: .white) ?? mixed
    }

    // MARK: - Motion

    private func animateModeSwitch(_ mode: Config.DictationMode, replacing: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        let direction: CGFloat = mode == .streaming ? 1 : -1
        let iconStart = surface.iconView.layer?.presentation()?.transform
            ?? surface.iconView.layer?.transform ?? CATransform3DIdentity
        addKeyframes(surface.iconView.layer, keyPath: "transform", values: [
            NSValue(caTransform3D: iconStart),
            transform(x: direction * 0.7, z: 7, scale: 1.055,
                      scaleY: 0.94, rotateY: direction * 0.30),
            transform(x: -direction * 0.12, z: 2, scale: 1.012,
                      rotateY: -direction * 0.035),
            transform(),
        ], times: [0, 0.42, 0.78, 1], duration: 0.24, begin: now,
                     key: "voiceModeIconTurn")

        guard let root = surface.card.layer else { return }
        let tint = mode.presentationTint.usingColorSpace(.deviceRGB) ?? mode.presentationTint
        let centre = CGPoint(x: surface.iconView.frame.midX, y: surface.iconView.frame.midY)
        for index in 0..<3 {
            let orbit = CAShapeLayer()
            orbit.frame = surface.card.bounds
            let radius = CGFloat(12 + index * 5)
            orbit.path = CGPath(ellipseIn: CGRect(x: centre.x - radius,
                                                  y: centre.y - radius,
                                                  width: radius * 2, height: radius * 2),
                                transform: nil)
            orbit.fillColor = nil
            orbit.strokeColor = tint.withAlphaComponent(0.68 - CGFloat(index) * 0.12).cgColor
            orbit.lineWidth = index == 1 ? 1.1 : 0.8
            orbit.lineCap = .round
            orbit.strokeStart = 0
            orbit.strokeEnd = 0
            orbit.opacity = 0
            root.insertSublayer(orbit, below: surface.iconView.layer)
            transientLayers.append(orbit)

            let begin = now + Double(index) * 0.012
            addKeyframes(orbit, keyPath: "strokeEnd", values: [0, 0.72, 1, 1],
                         times: [0, 0.42, 0.72, 1], duration: 0.24, begin: begin,
                         key: "voiceModeOrbitDraw\(index)")
            addKeyframes(orbit, keyPath: "strokeStart", values: [0, 0, 0.18, 0.88],
                         times: [0, 0.48, 0.74, 1], duration: 0.24, begin: begin,
                         key: "voiceModeOrbitErase\(index)")
            addKeyframes(orbit, keyPath: "opacity", values: [0, 0.76, 0.46, 0],
                         times: [0, 0.25, 0.72, 1], duration: 0.24, begin: begin,
                         key: "voiceModeOrbitOpacity\(index)")
            addKeyframes(orbit, keyPath: "transform", values: [
                transform(scale: replacing ? 0.84 : 0.62,
                          rotateX: 0.72, rotateZ: -direction * 0.24),
                transform(z: 4, scale: 1.04, rotateX: 0.12,
                          rotateZ: direction * 0.18),
                transform(scale: 1.10, rotateZ: direction * (0.42 + CGFloat(index) * 0.12)),
            ], times: [0, 0.58, 1], duration: 0.24, begin: begin,
                         key: "voiceModeOrbitTransform\(index)")
        }
    }

    private func animateListeningEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        let apertureValues = VoicePipelineApertureMotion.entranceScales.map(apertureTransform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.apertureMask.transform = CATransform3DIdentity
        CATransaction.commit()
        addKeyframes(surface.apertureMask, keyPath: "transform",
                     values: apertureValues,
                     times: VoicePipelineApertureMotion.entranceKeyTimes,
                     duration: VoicePipelineApertureMotion.entranceDuration,
                     begin: now, key: "voiceApertureEntrance")
        animateApertureGlow(tint: .systemRed, entering: true, begin: now)

        let iconLayer = surface.iconView.layer
        addKeyframes(iconLayer, keyPath: "transform", values: [
            transform(z: -7, scale: 0.72, scaleY: 0.18),
            transform(z: 3, scale: 1.025, scaleY: 1.02),
            transform(),
        ], times: [0, 0.78, 1], duration: VoicePipelineApertureMotion.entranceDuration,
                     begin: now,
                     key: "listenIconEntrance")
        let middle = CGFloat(surface.bars.count - 1) / 2
        for (index, bar) in surface.bars.enumerated() {
            let destination = bar.position.x
            let source = surface.waveform.bounds.midX
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = [source, destination + (destination - source) * 0.025, destination]
            animation.keyTimes = [0, 0.80, 1]
            animation.duration = VoicePipelineApertureMotion.entranceDuration
            animation.beginTime = bar.convertTime(now, from: nil)
                + abs(CGFloat(index) - middle) * 0.0007
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.16, 1)
            bar.add(animation, forKey: "listenBarCentreReveal")
        }
        addKeyframes(surface.border, keyPath: "opacity", values: [0, 0.28, 1],
                     times: [0, 0.55, 1],
                     duration: VoicePipelineApertureMotion.entranceDuration,
                     begin: now, key: "listenBorderReveal")
    }

    private func prepareListeningEntrance() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.apertureMask.removeAllAnimations()
        surface.apertureMask.opacity = 1
        surface.apertureMask.transform = reduce
            ? CATransform3DIdentity
            : apertureTransform(VoicePipelineApertureMotion.entranceScales[0]).caTransform3DValue
        CATransaction.commit()
    }

    private func animateApertureGlow(tint: NSColor, entering: Bool,
                                     begin: CFTimeInterval) {
        guard let root = surface.card.layer else { return }
        let rgb = tint.usingColorSpace(.deviceRGB) ?? tint
        let glow = CAGradientLayer()
        glow.frame = CGRect(x: 0, y: surface.card.bounds.midY - 1.35,
                            width: surface.card.bounds.width, height: 2.7)
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.locations = [0, 0.36, 0.5, 0.64, 1]
        glow.colors = [
            NSColor.clear.cgColor,
            rgb.withAlphaComponent(0.20).cgColor,
            NSColor.white.withAlphaComponent(0.94).cgColor,
            rgb.withAlphaComponent(0.20).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.shadowColor = rgb.cgColor
        glow.shadowOpacity = 0.62
        glow.shadowRadius = 4.5
        glow.shadowOffset = .zero
        glow.opacity = 0
        root.addSublayer(glow)
        transientLayers.append(glow)

        let duration = entering ? VoicePipelineApertureMotion.entranceDuration
                                : VoicePipelineApertureMotion.exitDuration
        let values: [Any] = entering ? [0, 0.96, 0.42, 0] : [0, 0.18, 1, 0]
        let times: [NSNumber] = entering ? [0, 0.24, 0.64, 1] : [0, 0.40, 0.78, 1]
        addKeyframes(glow, keyPath: "opacity", values: values, times: times,
                     duration: duration, begin: begin,
                     key: entering ? "voiceApertureGlowIn" : "voiceApertureGlowOut")
    }

    private func collapseWaveformIntoPipeline(stage: VoicePipelineVisualStage,
                                              generation: Int) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()
        let targetX = surface.iconView.frame.midX - surface.waveform.frame.minX
        let middle = CGFloat(surface.bars.count - 1) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.waveform.opacity = 0
        surface.title.opacity = 1
        surface.detail.opacity = 1
        CATransaction.commit()
        guard !reduce else { return }

        for (index, bar) in surface.bars.enumerated() {
            let startX = bar.presentation()?.position.x ?? bar.position.x
            let position = CAKeyframeAnimation(keyPath: "position.x")
            position.values = [startX, targetX + (startX - targetX) * 0.12, targetX]
            position.keyTimes = [0, 0.52, 1]
            let turn = CAKeyframeAnimation(keyPath: "transform")
            turn.values = [transform(), transform(z: 3, scaleX: 0.78, scaleY: 0.22,
                                                  rotateY: .pi * 0.44),
                           transform(scaleX: 0.08, scaleY: 0.08, rotateY: .pi / 2)]
            turn.keyTimes = [0, 0.62, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 0.70, 0]
            fade.keyTimes = [0, 0.54, 1]
            let group = CAAnimationGroup()
            group.animations = [position, turn, fade]
            group.duration = 0.245
            group.beginTime = bar.convertTime(now, from: nil)
                + abs(CGFloat(index) - middle) * 0.0011
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
            bar.add(group, forKey: "pipelineCrystallise")
        }
        animateOpacity(surface.waveform, from: surface.waveform.presentation()?.opacity ?? 1,
                       to: 0, duration: 0.23, key: "waveformExit")
        animateOpacity(surface.title, from: 0, to: 1, duration: 0.19,
                       delay: 0.064, key: "pipelineTitleReveal")
        animateOpacity(surface.detail, from: 0, to: 1, duration: 0.18,
                       delay: 0.088, key: "pipelineDetailReveal")
        addKeyframes(surface.title, keyPath: "transform", values: [
            transform(y: -1.5, z: -5, scaleY: 0.10, rotateX: -.pi * 0.43),
            transform(y: 0.18, z: 1.5, scaleY: 1.018, rotateX: 0.018),
            transform(),
        ], times: [0, 0.80, 1], duration: 0.135, begin: now + 0.064,
                     key: "pipelineTitleUnfold")
        addKeyframes(surface.detail, keyPath: "transform", values: [
            transform(y: 1.3, z: -4, scaleY: 0.12, rotateX: .pi * 0.40),
            transform(y: -0.15, z: 1, scaleY: 1.012, rotateX: -0.015),
            transform(),
        ], times: [0, 0.80, 1], duration: 0.13, begin: now + 0.088,
                     key: "pipelineDetailUnfold")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.transitionGeneration == generation, !self.listening else { return }
            self.history = [AcousticFrame](repeating: .silence, count: self.surface.bars.count)
            self.renderWaveform(animated: false)
        }
    }

    private func animatePhaseContinuity(stage: VoicePipelineVisualStage) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let direction: CGFloat = stage.rawValue.isMultiple(of: 2) ? 1 : -1
        let layer = surface.iconView.layer
        let start = layer?.presentation()?.transform ?? CATransform3DIdentity
        addKeyframes(layer, keyPath: "transform", values: [
            NSValue(caTransform3D: start),
            transform(x: direction * 0.7, z: 7, scale: 1.045,
                      scaleY: 0.94, rotateY: direction * 0.13,
                      rotateZ: direction * (stage == .polishing ? 0.09 : 0.03)),
            transform(x: -direction * 0.16, z: 2, scale: 1.012,
                      rotateY: -direction * 0.02),
            transform(),
        ], times: [0, 0.38, 0.78, 1], duration: 0.25,
                     begin: CACurrentMediaTime(), key: "phaseContinuity")
    }

    private func animateSignalTransfer(stage: VoicePipelineVisualStage) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let root = surface.card.layer else { return }
        let start = CGPoint(x: surface.iconView.frame.maxX - 2,
                            y: surface.iconView.frame.midY)
        let end = CGPoint(x: surface.title.frame.minX + 15,
                          y: surface.title.frame.midY)
        let sign: CGFloat = stage.rawValue.isMultiple(of: 2) ? 1 : -1
        for index in 0..<2 {
            let filament = CAShapeLayer()
            filament.frame = surface.card.bounds
            let path = CGMutablePath()
            path.move(to: CGPoint(x: start.x, y: start.y + CGFloat(index) * 2 - 1))
            path.addCurve(to: CGPoint(x: end.x, y: end.y + CGFloat(index) * 2 - 1),
                          control1: CGPoint(x: start.x + 10, y: start.y + sign * 9),
                          control2: CGPoint(x: end.x - 8, y: end.y - sign * 7))
            filament.path = path
            filament.fillColor = nil
            filament.strokeColor = stage.tint.withAlphaComponent(index == 0 ? 0.78 : 0.42).cgColor
            filament.lineWidth = index == 0 ? 1.35 : 0.82
            filament.lineCap = .round
            filament.shadowColor = stage.tint.cgColor
            filament.shadowOpacity = index == 0 ? 0.30 : 0.12
            filament.shadowRadius = index == 0 ? 3 : 1.5
            filament.shadowOffset = .zero
            filament.opacity = 0
            root.addSublayer(filament)
            transientLayers.append(filament)
            let begin = CACurrentMediaTime() + Double(index) * 0.018
            addKeyframes(filament, keyPath: "strokeEnd", values: [0, 0.88, 1],
                         times: [0, 0.68, 1], duration: 0.25, begin: begin,
                         key: "signalDraw")
            addKeyframes(filament, keyPath: "strokeStart", values: [0, 0.04, 0.76],
                         times: [0, 0.58, 1], duration: 0.25, begin: begin,
                         key: "signalErase")
            addKeyframes(filament, keyPath: "opacity", values: [0, 0.88, 0.48, 0],
                         times: [0, 0.20, 0.72, 1], duration: 0.25, begin: begin,
                         key: "signalOpacity")
        }
    }

    private func animateArc(to progress: CGFloat, tint: NSColor) {
        let from = surface.arcProgress.presentation()?.strokeEnd ?? surface.arcProgress.strokeEnd
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.arcProgress.strokeColor = tint.cgColor
        surface.arcProgress.strokeStart = 0.04
        surface.arcProgress.strokeEnd = min(0.98, max(0.08, progress))
        surface.arcProgress.lineWidth = 2.15
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        let crest = min(1, max(progress, from) + 0.035)
        sweep.values = [from, crest, progress]
        sweep.keyTimes = [0, 0.78, 1]
        sweep.duration = 0.25
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        surface.arcProgress.add(sweep, forKey: "pipelineArcAdvance")
    }

    private func animateText(_ layer: CATextLayer, to string: String,
                             delay: CFTimeInterval, direction: CGFloat,
                             generation: Int) {
        let old = Self.copyTextLayer(layer)
        old.string = layer.string
        surface.card.layer?.addSublayer(old)
        transientLayers.append(old)
        let oldTransform = old.transform
        let oldOpacity = old.opacity
        layer.removeAllAnimations()
        setText(layer, string)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            old.removeFromSuperlayer()
            return
        }

        let begin = CACurrentMediaTime() + delay
        let outgoingDuration: CFTimeInterval = 0.096
        let incomingBegin = begin + 0.108
        let incomingDuration: CFTimeInterval = 0.118
        let outgoingFinal = transform(y: direction * 1.35, z: -6, scaleY: 0.035,
                                      rotateX: direction * .pi * 0.49)
        // The proxy's model layer must already be its hidden destination. If only the animation
        // fades it, Core Animation removes that animation at 96 ms and the old word reappears at
        // full opacity until the proxy cleanup runs — a single but very visible ghost frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        old.opacity = 0
        old.transform = outgoingFinal.caTransform3DValue
        CATransaction.commit()
        addKeyframes(old, keyPath: "transform", values: [
            NSValue(caTransform3D: oldTransform),
            outgoingFinal,
        ], times: [0, 1], duration: outgoingDuration, begin: begin,
                     key: "textOldFold")
        addKeyframes(old, keyPath: "opacity", values: [oldOpacity, oldOpacity * 0.34, 0],
                     times: [0, 0.58, 1], duration: outgoingDuration, begin: begin,
                     key: "textOldOpacity")
        addKeyframes(layer, keyPath: "transform", values: [
            transform(y: -direction * 1.35, z: -6, scaleY: 0.035,
                      rotateX: -direction * .pi * 0.49),
            transform(y: direction * -0.18, z: 1.5, scaleY: 1.018,
                      rotateX: direction * -0.018),
            transform(),
        ], times: [0, 0.80, 1], duration: incomingDuration, begin: incomingBegin,
                     key: "textNewFold")
        addKeyframes(layer, keyPath: "opacity", values: [0, 0.12, 0.88, 1],
                     times: [0, 0.16, 0.78, 1], duration: incomingDuration,
                     begin: incomingBegin,
                     key: "textNewOpacity")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.245) { [weak self, weak old] in
            guard let self, let old, self.transitionGeneration == generation else {
                old?.removeFromSuperlayer()
                return
            }
            old.removeFromSuperlayer()
            self.transientLayers.removeAll { $0 === old }
        }
    }

    private func setIcon(_ name: String, tint: NSColor, cue: ActionSymbolCue,
                         animated: Bool) {
        guard let source = symbol(name, size: 25) else { return }
        let image = ActionSymbolStyle.hierarchicalImage(source, symbolName: name, tint: tint,
                                                        cue: cue)
            ?? source
        if animated, currentSymbolName != nil, #available(macOS 14.0, *) {
            ActionSymbolStyle.replaceSymbol(in: surface.iconView, with: image, cue: cue,
                                            speed: 2.75, preferMagic: false)
        } else {
            surface.iconView.image = image
            if animated, #available(macOS 14.0, *) {
                ActionSymbolStyle.apply(cue, to: surface.iconView, speed: 2.85)
            }
        }
        surface.iconView.contentTintColor = nil
        currentSymbolName = name
    }

    // MARK: - Window lifecycle

    private func showIfNeeded(animateAlpha: Bool = true) {
        guard enabled else { return }
        appearanceGeneration += 1
        let wasVisible = visible
        if !visible {
            restorePositionForPresentation()
            visible = true
            surface.panel.alphaValue = animateAlpha ? 0 : 1
        }
        surface.panel.orderFrontRegardless()
        startCursorScreenTracking()
        // AppKit's window-alpha animator keeps running independently from the content layers. A
        // second dictation can begin while the previous capsule is only halfway through its exit;
        // explicitly retargeting alpha here prevents that stale exit from making the new waveform
        // disappear a few frames later.
        if !animateAlpha {
            ensureReachable()
            surface.panel.alphaValue = 1
        } else if !wasVisible || surface.panel.alphaValue < 0.999 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = wasVisible ? 0.13 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.20, 1)
                self.surface.panel.animator().alphaValue = 1
            }
        } else {
            ensureReachable()
            surface.panel.alphaValue = 1
        }
    }

    private func hide(animated: Bool, exitStyle: ExitStyle = .standard) {
        guard visible || surface.panel.isVisible else { return }
        appearanceGeneration += 1
        let generation = appearanceGeneration
        transitionGeneration += 1
        let exitTint = currentStage?.tint ?? currentModePreview?.presentationTint ?? .systemRed
        listening = false
        awaitingReleasePhase = false
        currentStage = nil
        currentModePreview = nil
        clearTransientLayers()
        guard animated else {
            visible = false
            stopCursorScreenTracking()
            surface.panel.alphaValue = 0
            surface.panel.orderOut(nil)
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduce { animateCRTExitElements(tint: exitTint) }
        // Keep the panel fully legible while the material compresses into its scan line, then kill
        // the last phosphor point quickly. Fading from frame zero would turn this into a generic
        // dissolve and erase the old-television read.
        let fadeDelay: TimeInterval = reduce ? 0 : VoicePipelineApertureMotion.exitDuration * 0.72
        let fadeDuration: TimeInterval = reduce ? 0.11 : 0.052
        let beginFade = { [weak self] in
            guard let self, self.appearanceGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.surface.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.appearanceGeneration == generation else { return }
                self.visible = false
                self.stopCursorScreenTracking()
                self.surface.panel.orderOut(nil)
            })
        }
        if fadeDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay, execute: beginFade)
        } else {
            beginFade()
        }
    }

    private func animateCRTExitElements(tint: NSColor) {
        let now = CACurrentMediaTime()
        let start = surface.apertureMask.presentation()?.transform
            ?? surface.apertureMask.transform
        var values = VoicePipelineApertureMotion.exitScales.map(apertureTransform)
        values[0] = NSValue(caTransform3D: start)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.apertureMask.opacity = 1
        surface.apertureMask.transform = values.last?.caTransform3DValue
            ?? CATransform3DIdentity
        CATransaction.commit()
        addKeyframes(surface.apertureMask, keyPath: "transform", values: values,
                     times: VoicePipelineApertureMotion.exitKeyTimes,
                     duration: VoicePipelineApertureMotion.exitDuration,
                     begin: now, key: "voiceApertureExit")
        animateApertureGlow(tint: tint, entering: false, begin: now)
    }

    /// Resolve model values from an interrupted exit before composing a fresh listening state.
    /// Every touched value is rewritten later in the same main-run-loop turn, so this cannot expose
    /// a reset frame; it only prevents two animations for the same transform from fighting.
    private func cancelInFlightExitForNewPresentation() {
        let permanent = [surface.iconView.layer, surface.title, surface.detail, surface.mode,
                         surface.waveform, surface.arcTrack, surface.arcProgress,
                         surface.border, surface.apertureMask].compactMap { $0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        permanent.forEach {
            $0.removeAllAnimations()
            $0.transform = CATransform3DIdentity
        }
        surface.apertureMask.opacity = 1
        surface.bars.forEach { $0.removeAllAnimations() }
        surface.highlights.forEach { $0.removeAllAnimations() }
        CATransaction.commit()
    }

    // MARK: - Palette / material

    private func applyPalette(_ tint: NSColor, animated: Bool) {
        let rgb = tint.usingColorSpace(.deviceRGB) ?? tint
        let dark = surface.card.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors: [CGColor] = [
            rgb.withAlphaComponent(dark ? 0.20 : 0.13).cgColor,
            rgb.withAlphaComponent(dark ? 0.065 : 0.040).cgColor,
            NSColor.clear.cgColor,
        ]
        let old = surface.ambient.presentation()?.colors ?? surface.ambient.colors
        let oldBorder = surface.border.presentation()?.strokeColor ?? surface.border.strokeColor
        let oldTrack = surface.arcTrack.presentation()?.strokeColor ?? surface.arcTrack.strokeColor
        let oldProgress = surface.arcProgress.presentation()?.strokeColor
            ?? surface.arcProgress.strokeColor
        let borderColor = rgb.withAlphaComponent(dark ? 0.58 : 0.44).cgColor
        let trackColor = rgb.withAlphaComponent(dark ? 0.14 : 0.10).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.ambient.colors = colors
        surface.border.strokeColor = borderColor
        surface.arcTrack.strokeColor = trackColor
        surface.arcProgress.strokeColor = rgb.cgColor
        surface.baseline.backgroundColor = rgb.withAlphaComponent(dark ? 0.18 : 0.12).cgColor
        CATransaction.commit()
        guard animated else { return }
        let morph = CABasicAnimation(keyPath: "colors")
        morph.fromValue = old
        morph.toValue = colors
        morph.duration = 0.24
        morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        surface.ambient.add(morph, forKey: "pipelinePalette")
        animateBasic(surface.border, keyPath: "strokeColor", from: oldBorder ?? borderColor,
                     to: borderColor, duration: 0.22, key: "pipelineBorderColour")
        animateBasic(surface.arcTrack, keyPath: "strokeColor", from: oldTrack ?? trackColor,
                     to: trackColor, duration: 0.22, key: "pipelineTrackColour")
        animateBasic(surface.arcProgress, keyPath: "strokeColor", from: oldProgress ?? rgb.cgColor,
                     to: rgb.cgColor, duration: 0.22, key: "pipelineProgressColour")
    }

    private func applyMaterialContrast() {
        let scale = surface.panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [surface.title, surface.detail, surface.mode] { layer.contentsScale = scale }
        surface.title.foregroundColor = NSColor.labelColor.cgColor
        surface.detail.foregroundColor = NSColor.secondaryLabelColor.cgColor
        surface.mode.foregroundColor = NSColor.secondaryLabelColor.cgColor
        surface.highlights.forEach { $0.backgroundColor = NSColor.labelColor.cgColor }
        if let stage = currentStage { applyPalette(stage.tint, animated: false) }
        else if let mode = currentModePreview { applyPalette(mode.presentationTint, animated: false) }
        else { applyPalette(.systemRed, animated: false) }
    }

    private func relocalize() {
        guard visible else { return }
        if let stage = currentStage {
            setText(surface.title, stage.title)
        } else if let mode = currentModePreview {
            setText(surface.title, mode.presentationTitle)
            setText(surface.detail, mode.presentationDetail)
            setText(surface.mode, mode.presentationBadge)
        } else if listening {
            setText(surface.title, L("Listening"))
            setText(surface.detail, L("Release to finish"))
        }
    }

    // MARK: - Placement

    func windowDidMove(_ notification: Notification) {
        guard visible, !isMovingProgrammatically else { return }
        // A drag can cross a display boundary. Do not let cursor-follow remap the panel while the
        // user's pointer still owns the window; settle the authored position first.
        cursorFollowSuppressedUntil = CACurrentMediaTime() + 0.25
        moveGeneration += 1
        let generation = moveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.moveGeneration == generation else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.windowDidMove(Notification(name: NSWindow.didMoveNotification))
                return
            }
            self.settleAfterDrag()
        }
    }

    private func restorePositionForPresentation() {
        guard !NSScreen.screens.isEmpty else { return }
        let screen = screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        moveToDefaultPosition(on: screen)
    }

    private func moveToDefaultPosition(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = VoicePipelineScreenPlacement.defaultOrigin(
            windowSize: windowSize, visibleFrame: visible
        )
        setFrameOrigin(clampedOrigin(origin, in: visible))
        presentationDisplayID = screen.hudDisplayID
    }

    private func settleAfterDrag() {
        guard let screen = bestScreen(for: surface.panel.frame) else { return }
        let pointerScreen = screenContainingMouse() ?? screen
        if presentationDisplayID != pointerScreen.hudDisplayID {
            moveToDefaultPosition(on: pointerScreen)
            applyMaterialContrast()
            surface.panel.orderFrontRegardless()
            return
        }
        let origin = clampedOrigin(surface.panel.frame.origin, in: screen.visibleFrame)
        if origin != surface.panel.frame.origin { setFrameOrigin(origin) }
        presentationDisplayID = screen.hudDisplayID
    }

    private func screenParametersChanged() {
        guard visible else { return }
        followCursorScreen(force: true)
        applyMaterialContrast()
        surface.panel.orderFrontRegardless()
    }

    private func activeSpaceChanged() {
        guard visible else { return }
        followCursorScreen(force: false)
        ensureReachable()
        surface.panel.orderFrontRegardless()
    }

    private func ensureReachable() {
        let area = NSScreen.screens.reduce(CGFloat(0)) {
            $0 + surface.panel.frame.intersection($1.visibleFrame).area
        }
        if area < 16 { followCursorScreen(force: true) }
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let index = VoicePipelineScreenPlacement.screenIndex(
            containing: mouse, frames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    private func startCursorScreenTracking() {
        guard cursorScreenTimer == nil else {
            followCursorScreen(force: false)
            return
        }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.followCursorScreen(force: false)
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        cursorScreenTimer = timer
        followCursorScreen(force: false)
    }

    private func stopCursorScreenTracking() {
        cursorScreenTimer?.invalidate()
        cursorScreenTimer = nil
    }

    private func followCursorScreen(force: Bool) {
        guard visible, CACurrentMediaTime() >= cursorFollowSuppressedUntil,
              NSEvent.pressedMouseButtons == 0,
              let screen = screenContainingMouse() else { return }
        let displayID = screen.hudDisplayID
        guard force || presentationDisplayID != displayID else { return }
        moveToDefaultPosition(on: screen)
        applyMaterialContrast()
        surface.panel.orderFrontRegardless()
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let overlapping = screens.max(by: {
            frame.intersection($0.visibleFrame).area < frame.intersection($1.visibleFrame).area
        }), frame.intersection(overlapping.visibleFrame).area > 0 { return overlapping }
        return screenContainingMouse() ?? NSScreen.main ?? screens[0]
    }

    private func clampedOrigin(_ point: NSPoint, in visible: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - windowSize.width)),
                y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - windowSize.height)))
    }

    private func setFrameOrigin(_ point: NSPoint) {
        isMovingProgrammatically = true
        surface.panel.setFrameOrigin(point)
        DispatchQueue.main.async { [weak self] in self?.isMovingProgrammatically = false }
    }

    // MARK: - Layer helpers

    private func configuredSymbol(key: String, fallback: String) -> String {
        ActionVisual.firstValidSystemSymbol(
            [configuredIcons[key], fallback, configuredIcons["fallback"]],
            fallback: "command.circle.fill"
        )
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    private func setText(_ layer: CATextLayer, _ string: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = string
        CATransaction.commit()
    }

    private func clearTransientLayers() {
        transientLayers.forEach { $0.removeFromSuperlayer() }
        transientLayers.removeAll()
    }

    private func animateOpacity(_ layer: CALayer, from: Float, to: Float,
                                duration: CFTimeInterval, delay: CFTimeInterval = 0,
                                key: String) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = delay > 0 ? .backwards : .removed
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        layer.add(animation, forKey: key)
    }

    private func animateBasic(_ layer: CALayer, keyPath: String, from: Any, to: Any,
                              duration: CFTimeInterval, key: String) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }

    private func addKeyframes(_ layer: CALayer?, keyPath: String, values: [Any],
                              times: [NSNumber], duration: CFTimeInterval,
                              begin: CFTimeInterval, key: String) {
        guard let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.beginTime = layer.convertTime(begin, from: nil)
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        layer.add(animation, forKey: key)
    }

    private func transform(x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0,
                           scale: CGFloat = 1, scaleX: CGFloat = 1, scaleY: CGFloat = 1,
                           rotateX: CGFloat = 0, rotateY: CGFloat = 0,
                           rotateZ: CGFloat = 0, perspective: CGFloat = 340) -> NSValue {
        var value = CATransform3DIdentity
        value.m34 = -1 / max(1, perspective)
        value = CATransform3DTranslate(value, x, y, z)
        if rotateX != 0 { value = CATransform3DRotate(value, rotateX, 1, 0, 0) }
        if rotateY != 0 { value = CATransform3DRotate(value, rotateY, 0, 1, 0) }
        if rotateZ != 0 { value = CATransform3DRotate(value, rotateZ, 0, 0, 1) }
        value = CATransform3DScale(value, scale * scaleX, scale * scaleY, 1)
        return NSValue(caTransform3D: value)
    }

    private func apertureTransform(_ scale: CGSize) -> NSValue {
        NSValue(caTransform3D: CATransform3DMakeScale(scale.width, scale.height, 1))
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private static func copyTextLayer(_ source: CATextLayer) -> CATextLayer {
        let layer = CATextLayer()
        layer.frame = source.frame
        layer.string = source.string
        layer.font = source.font
        layer.fontSize = source.fontSize
        layer.foregroundColor = source.foregroundColor
        layer.alignmentMode = source.alignmentMode
        layer.truncationMode = source.truncationMode
        layer.contentsScale = source.contentsScale
        layer.isWrapped = source.isWrapped
        if let presentation = source.presentation() {
            layer.opacity = presentation.opacity
            layer.transform = presentation.transform
        } else {
            layer.opacity = source.opacity
            layer.transform = source.transform
        }
        return layer
    }

    private static func makeSurface(windowSize: NSSize, cardFrame: NSRect) -> Surface {
        let panel = PipelinePanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none

        let root = DragSurface(frame: NSRect(origin: .zero, size: windowSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = root

        let card = AdaptiveMaterial(frame: cardFrame)
        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 21
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        root.addSubview(card)

        let apertureMask = CAShapeLayer()
        apertureMask.frame = card.bounds
        apertureMask.path = CGPath(roundedRect: card.bounds,
                                   cornerWidth: 21, cornerHeight: 21, transform: nil)
        apertureMask.fillColor = NSColor.white.cgColor
        apertureMask.opacity = 1
        card.layer?.mask = apertureMask

        let ambient = CAGradientLayer()
        ambient.frame = card.bounds
        ambient.startPoint = CGPoint(x: 0.02, y: 0.88)
        ambient.endPoint = CGPoint(x: 0.86, y: 0.14)
        ambient.locations = [0, 0.46, 1]
        card.layer?.addSublayer(ambient)

        let border = CAShapeLayer()
        border.frame = card.bounds
        border.path = CGPath(roundedRect: card.bounds.insetBy(dx: 0.75, dy: 0.75),
                             cornerWidth: 20.25, cornerHeight: 20.25, transform: nil)
        border.fillColor = nil
        border.lineWidth = 1.25
        border.strokeStart = 0
        border.strokeEnd = 1
        card.layer?.addSublayer(border)

        let icon = NSImageView(frame: CGRect(x: 14, y: 12, width: 36, height: 36))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        card.addSubview(icon)

        let arcRect = CGRect(x: 9.5, y: 7.5, width: 45, height: 45)
        let arcPath = CGMutablePath()
        arcPath.addArc(center: CGPoint(x: arcRect.midX, y: arcRect.midY),
                       radius: arcRect.width / 2, startAngle: -.pi * 0.72,
                       endAngle: .pi * 1.20, clockwise: false)
        let arcTrack = CAShapeLayer()
        arcTrack.frame = card.bounds
        arcTrack.path = arcPath
        arcTrack.fillColor = nil
        arcTrack.lineWidth = 1.15
        arcTrack.lineCap = .round
        card.layer?.insertSublayer(arcTrack, below: icon.layer)

        let arcProgress = CAShapeLayer()
        arcProgress.frame = card.bounds
        arcProgress.path = arcPath
        arcProgress.fillColor = nil
        arcProgress.lineWidth = 2.15
        arcProgress.lineCap = .round
        arcProgress.strokeStart = 0.04
        arcProgress.strokeEnd = 0.16
        card.layer?.insertSublayer(arcProgress, above: arcTrack)

        func text(frame: CGRect, font: NSFont, color: NSColor,
                  alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
            let layer = CATextLayer()
            layer.frame = frame
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = color.cgColor
            layer.alignmentMode = alignment
            layer.truncationMode = .end
            layer.isWrapped = false
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            return layer
        }
        let title = text(frame: CGRect(x: 63, y: 30, width: 162, height: 19),
                         font: .systemFont(ofSize: 13.5, weight: .semibold),
                         color: .labelColor)
        let detail = text(frame: CGRect(x: 63, y: 12, width: 220, height: 16),
                          font: .systemFont(ofSize: 10.5, weight: .medium),
                          color: .secondaryLabelColor)
        let mode = text(frame: CGRect(x: 231, y: 34, width: 53, height: 13),
                        font: .monospacedSystemFont(ofSize: 8.2, weight: .bold),
                        color: .secondaryLabelColor, alignment: .right)
        card.layer?.addSublayer(title)
        card.layer?.addSublayer(detail)
        card.layer?.addSublayer(mode)

        let waveform = CALayer()
        waveform.frame = CGRect(x: 62, y: 10, width: 221, height: 40)
        waveform.masksToBounds = false
        let baseline = CALayer()
        baseline.frame = CGRect(x: 0, y: waveform.bounds.midY - 0.25,
                                width: waveform.bounds.width, height: 0.5)
        waveform.addSublayer(baseline)
        let count = 21
        let width: CGFloat = 3.2
        let gap = (waveform.bounds.width - CGFloat(count) * width) / CGFloat(count - 1)
        var bars: [CALayer] = []
        var highlights: [CALayer] = []
        for index in 0..<count {
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: 3)
            bar.position = CGPoint(x: width / 2 + CGFloat(index) * (width + gap),
                                   y: waveform.bounds.midY)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.cornerRadius = width / 2
            bar.masksToBounds = false
            let highlight = CALayer()
            highlight.bounds = CGRect(x: 0, y: 0, width: max(1, width - 1), height: 1.0)
            highlight.position = CGPoint(x: width / 2, y: 2)
            highlight.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            highlight.cornerRadius = 0.5
            highlight.opacity = 0
            bar.addSublayer(highlight)
            waveform.addSublayer(bar)
            bars.append(bar)
            highlights.append(highlight)
        }
        card.layer?.insertSublayer(waveform, below: title)

        return Surface(panel: panel, card: card, apertureMask: apertureMask,
                       ambient: ambient, border: border,
                       arcTrack: arcTrack, arcProgress: arcProgress, iconView: icon,
                       title: title, detail: detail, mode: mode,
                       waveform: waveform, baseline: baseline,
                       bars: bars, highlights: highlights)
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
