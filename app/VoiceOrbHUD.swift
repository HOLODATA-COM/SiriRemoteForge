//
//  VoiceOrbHUD.swift
//  HyperVibe
//
//  The current native-Voice presentation: one audio-reactive dotted orb and one short state word.
//  Its motion language is inspired by thinking-orbs (MIT, Jakub Antalik), but this is a native
//  AppKit/Core Graphics renderer built around HyperVibe's existing acoustic meter and lifecycle.
//
//  The previous rectangular/CRT implementation remains intact in VoicePipelineHUD.swift as
//  LegacyVoicePipelineHUDController. Keeping both implementations compiled makes visual A/B work
//  and rollback possible without recovering deleted source.
//

import AppKit
import CoreGraphics
import QuartzCore

/// Semantic shapes intentionally share one particle topology. A transition can therefore begin
/// from the exact currently rendered frame, even when another transition is interrupted midway.
enum VoiceOrbMotion: Int, Hashable {
    case listening
    case searching
    case solving
    case weaving
    case shaping
    case resolved
    case constellation
    case breathing
    case alert
}

enum VoiceOrbTransitionMath {
    static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    static func shortestAngleDistance(_ lhs: Double, _ rhs: Double) -> Double {
        var distance = (lhs - rhs).truncatingRemainder(dividingBy: .pi * 2)
        if distance > .pi { distance -= .pi * 2 }
        if distance < -.pi { distance += .pi * 2 }
        return abs(distance)
    }
}

enum VoiceOrbSemanticState: Equatable {
    case listening
    case selectionListening
    case transcribing
    case polishing
    case rewriting
    case inserting
    case inserted
    case replaced
    case copied
    case error
    case modeExternal
    case modeFinal
    case modeLive

    var motion: VoiceOrbMotion {
        switch self {
        case .listening, .selectionListening, .modeLive: return .listening
        case .transcribing: return .searching
        case .polishing: return .solving
        case .rewriting: return .weaving
        case .inserting: return .shaping
        case .inserted, .replaced: return .resolved
        case .copied, .modeExternal: return .constellation
        case .modeFinal: return .breathing
        case .error: return .alert
        }
    }

    var label: String {
        switch self {
        case .listening: return L("Listening")
        case .selectionListening: return L("Edit")
        case .transcribing: return L("Transcribing")
        case .polishing: return L("Polishing")
        case .rewriting: return L("Rewriting")
        case .inserting: return L("Inserting")
        case .inserted, .replaced: return L("Done")
        case .copied: return L("Copied")
        case .error: return L("Error")
        case .modeExternal: return L("External")
        case .modeFinal: return L("Final")
        case .modeLive: return L("Live")
        }
    }

    var tint: NSColor {
        switch self {
        case .listening: return .systemRed
        case .selectionListening, .rewriting: return .systemIndigo
        case .transcribing, .modeLive: return .systemOrange
        case .polishing, .modeFinal: return .systemPurple
        case .inserting, .copied, .modeExternal: return .systemBlue
        case .inserted, .replaced: return .systemGreen
        case .error: return .systemRed
        }
    }
}

private struct VoiceOrbRGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static func color(_ color: NSColor, alpha: Double = 1) -> VoiceOrbRGBA {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return VoiceOrbRGBA(red: Double(rgb.redComponent),
                            green: Double(rgb.greenComponent),
                            blue: Double(rgb.blueComponent),
                            alpha: alpha)
    }

    func mixed(with other: VoiceOrbRGBA, fraction: Double) -> VoiceOrbRGBA {
        let t = min(1, max(0, fraction))
        return VoiceOrbRGBA(red: red + (other.red - red) * t,
                            green: green + (other.green - green) * t,
                            blue: blue + (other.blue - blue) * t,
                            alpha: alpha + (other.alpha - alpha) * t)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
                alpha: CGFloat(alpha))
    }
}

private struct VoiceOrbParticle {
    var x: Double
    var y: Double
    var depth: Double
    var radius: Double
    var color: VoiceOrbRGBA

    func mixed(with other: VoiceOrbParticle, fraction: Double) -> VoiceOrbParticle {
        let t = VoiceOrbTransitionMath.smoothstep(fraction)
        return VoiceOrbParticle(x: x + (other.x - x) * t,
                                y: y + (other.y - y) * t,
                                depth: depth + (other.depth - depth) * t,
                                radius: radius + (other.radius - radius) * t,
                                color: color.mixed(with: other.color, fraction: t))
    }
}

/// Vector renderer for the orb. It keeps a frozen snapshot of the last on-screen particle frame at
/// every semantic change. A rapid second change uses that snapshot as its new source, so no state
/// can snap back to its own authored frame zero.
private final class VoiceOrbCanvasView: NSView {
    private static let rows = 9
    private static let columns = 14
    private static let particleCount = rows * columns

    private var state: VoiceOrbSemanticState = .listening
    private var transitionSource: [VoiceOrbParticle]?
    private var transitionStartedAt: CFTimeInterval = 0
    private var transitionDuration: CFTimeInterval = 0.42
    private var renderedParticles: [VoiceOrbParticle] = []
    private var previousLabel = ""
    private var labelStartedAt: CFTimeInterval = 0

    private var frameTimer: Timer?
    private var lastFrameAt: CFTimeInterval = 0
    private var targetLevel: Double = 0
    private var displayedLevel: Double = 0
    private var targetPitch: Double = 0
    private var displayedPitch: Double = 0
    private var targetPitchConfidence: Double = 0
    private var displayedPitchConfidence: Double = 0
    private var targetBrightness: Double = 0
    private var displayedBrightness: Double = 0
    private var lastMeterAt: CFTimeInterval = 0
    private var levelHistory = [Double](repeating: 0, count: columns)

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(state.label)
    }

    required init?(coder: NSCoder) { nil }

    deinit { stopAnimating() }

    func startAnimating() {
        guard frameTimer == nil else { return }
        lastFrameAt = CACurrentMediaTime()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsDisplay = true
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func stopAnimating() {
        frameTimer?.invalidate()
        frameTimer = nil
        lastFrameAt = 0
    }

    func setState(_ newState: VoiceOrbSemanticState, animated: Bool = true) {
        let now = CACurrentMediaTime()
        let current = particles(at: now)
        previousLabel = visibleLabel(at: now)
        state = newState
        setAccessibilityLabel(newState.label)
        labelStartedAt = now
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            transitionSource = current
            transitionStartedAt = now
            transitionDuration = newState.motion == .resolved ? 0.46 : 0.38
        } else {
            transitionSource = nil
            transitionStartedAt = 0
        }
        needsDisplay = true
    }

    func relocalize() {
        previousLabel = state.label
        labelStartedAt = 0
        setAccessibilityLabel(state.label)
        needsDisplay = true
    }

    func resetAudio() {
        targetLevel = 0
        displayedLevel = 0
        targetPitch = 0
        displayedPitch = 0
        targetPitchConfidence = 0
        displayedPitchConfidence = 0
        targetBrightness = 0
        displayedBrightness = 0
        lastMeterAt = 0
        levelHistory = [Double](repeating: 0, count: Self.columns)
        needsDisplay = true
    }

    func finishAudio() {
        targetLevel = 0
        targetPitchConfidence = 0
        targetBrightness = 0
    }

    func ingest(_ sample: VoiceMeterSample) {
        let rawLevel = Double(sample.level.isFinite ? sample.level : 0)
        targetLevel = min(1, max(0, pow(rawLevel, 0.78)))
        let confidence = Double(sample.pitchConfidence.isFinite ? sample.pitchConfidence : 0)
        targetPitchConfidence = min(1, max(0, confidence))
        if sample.pitchHz.isFinite, sample.pitchHz > 55, sample.pitchHz < 1_200,
           targetPitchConfidence > 0.38 {
            let semitoneSpan = 7.0 / 12.0
            targetPitch = min(1, max(-1, log2(Double(sample.pitchHz) / 180) / semitoneSpan))
        }
        let rawBrightness = Double(sample.brightness.isFinite ? sample.brightness : 0)
        targetBrightness = min(1, max(0, rawBrightness))
        levelHistory.removeFirst()
        levelHistory.append(targetLevel)
        lastMeterAt = CACurrentMediaTime()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = CACurrentMediaTime()
        let particles = particles(at: now)
        renderedParticles = particles
        drawHalo(for: particles)
        drawParticles(particles)
        drawStatusLabel(at: now)
    }

    private func advanceFrame() {
        let now = CACurrentMediaTime()
        let delta = lastFrameAt > 0 ? min(0.05, max(0, now - lastFrameAt)) : 1.0 / 60.0
        lastFrameAt = now
        if lastMeterAt > 0, now - lastMeterAt > 0.12 {
            targetLevel *= pow(0.08, delta)
            targetPitchConfidence *= pow(0.04, delta)
            targetBrightness *= pow(0.08, delta)
        }
        displayedLevel = approach(displayedLevel, targetLevel, delta: delta,
                                  rise: 0.042, fall: 0.16)
        displayedPitch = approach(displayedPitch, targetPitch, delta: delta,
                                  rise: 0.08, fall: 0.14)
        displayedPitchConfidence = approach(displayedPitchConfidence, targetPitchConfidence,
                                            delta: delta, rise: 0.07, fall: 0.18)
        displayedBrightness = approach(displayedBrightness, targetBrightness, delta: delta,
                                       rise: 0.08, fall: 0.20)
        needsDisplay = true
    }

    private func approach(_ current: Double, _ target: Double, delta: Double,
                          rise: Double, fall: Double) -> Double {
        let constant = target > current ? rise : fall
        let fraction = 1 - exp(-delta / max(0.001, constant))
        return current + (target - current) * fraction
    }

    private func particles(at time: CFTimeInterval) -> [VoiceOrbParticle] {
        let target = makePose(state: state, time: time)
        guard let source = transitionSource, source.count == target.count else { return target }
        let progress = (time - transitionStartedAt) / max(0.001, transitionDuration)
        guard progress < 1 else {
            transitionSource = nil
            return target
        }
        return zip(source, target).map { $0.mixed(with: $1, fraction: progress) }
    }

    private func makePose(state: VoiceOrbSemanticState,
                          time: CFTimeInterval) -> [VoiceOrbParticle] {
        let t = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Double(time)
        let centerX = Double(bounds.midX)
        let centerY = 70.0
        let tint = VoiceOrbRGBA.color(state.tint)
        let white = VoiceOrbRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        var result: [VoiceOrbParticle] = []
        result.reserveCapacity(Self.particleCount)

        for index in 0..<Self.particleCount {
            let row = index / Self.columns
            let column = index % Self.columns
            let latitude = -.pi / 2 + .pi * (Double(row) + 0.5) / Double(Self.rows)
            var longitude = .pi * 2 * Double(column) / Double(Self.columns)
            let cosLatitude = cos(latitude)
            var x = cosLatitude * cos(longitude)
            var y = sin(latitude)
            var z = cosLatitude * sin(longitude)
            var radiusScale = 1.0
            var alphaScale = 1.0
            var brightnessMix = 0.08

            switch state.motion {
            case .listening:
                longitude += t * 0.30
                let historyIndex = (Self.columns - 1 - column + Self.columns) % Self.columns
                let localLevel = max(displayedLevel * 0.46, levelHistory[historyIndex])
                let travelling = sin(longitude * 2.0 - t * 8.6 + latitude * 2.7)
                let voiceDisplacement = localLevel * (0.10 + 0.17 * travelling)
                let restingBreath = 0.018 * sin(t * 2.1 + latitude * 1.8)
                let radial = 1 + restingBreath + voiceDisplacement
                x = cosLatitude * cos(longitude) * radial
                y = (sin(latitude) * radial)
                    + localLevel * 0.13 * sin(longitude * 2.0 - t * 9.4)
                z = cosLatitude * sin(longitude) * radial
                let pitchLean = displayedPitch * displayedPitchConfidence * 0.22
                (y, z) = rotate(y, z, angle: pitchLean)
                radiusScale = 0.88 + localLevel * 0.82 + displayedBrightness * 0.18
                alphaScale = 0.76 + localLevel * 0.24
                brightnessMix = 0.10 + displayedBrightness * 0.26

            case .searching:
                longitude += t * 0.72
                x = cosLatitude * cos(longitude)
                y = sin(latitude)
                z = cosLatitude * sin(longitude)
                let scanner = t * 2.15
                let distance = VoiceOrbTransitionMath.shortestAngleDistance(longitude, scanner)
                let scan = exp(-distance * distance / 0.055)
                radiusScale = 0.82 + scan * 0.72
                alphaScale = 0.55 + scan * 0.45
                brightnessMix = 0.08 + scan * 0.48

            case .solving:
                let bandDirection = row.isMultiple(of: 2) ? 1.0 : -1.0
                let settle = pow(sin(t * 1.42 + Double(row) * 0.67), 3) * 0.24
                longitude += t * 0.24 + settle * bandDirection
                x = cosLatitude * cos(longitude)
                y = sin(latitude) * (0.94 + 0.06 * cos(t * 1.8 + Double(row)))
                z = cosLatitude * sin(longitude)
                radiusScale = 0.90 + 0.20 * max(0, sin(t * 2.4 + Double(row)))
                alphaScale = 0.70 + (Double(row % 3) * 0.10)
                brightnessMix = 0.12 + 0.18 * max(0, z)

            case .weaving:
                let strand = Double(column % 3)
                longitude += t * (0.40 + strand * 0.055)
                    + sin(latitude * 3 + t * 1.6 + strand * 2.08) * 0.24
                let weave = 1 + 0.08 * sin(latitude * 5 - t * 2.2 + strand * 2.08)
                x = cosLatitude * cos(longitude) * weave
                y = sin(latitude) + 0.055 * sin(longitude * 3 + t + strand)
                z = cosLatitude * sin(longitude) * weave
                radiusScale = 0.82 + 0.26 * (strand / 2)
                alphaScale = 0.64 + 0.17 * strand
                brightnessMix = 0.08 + 0.10 * strand

            case .shaping:
                let phase = (sin(t * 1.75) + 1) / 2
                let squareX = copysign(pow(abs(x), 0.68), x)
                let squareY = copysign(pow(abs(y), 0.68), y)
                x += (squareX - x) * phase * 0.42
                y += (squareY - y) * phase * 0.42
                let pinch = 1 - 0.12 * sin(t * 3.1 + longitude * 2)
                x *= pinch
                z *= 2 - pinch
                radiusScale = 0.86 + 0.20 * phase
                alphaScale = 0.68 + 0.22 * (1 - phase)
                brightnessMix = 0.10 + phase * 0.20

            case .resolved:
                let completionAge = max(0, t - transitionStartedAt)
                let pulse = exp(-completionAge * 2.8) * sin(completionAge * 10.5)
                longitude += t * 0.18
                let ringBias = 1 - 0.08 * cos(latitude * 4)
                x = cosLatitude * cos(longitude) * ringBias * (1 + pulse * 0.055)
                y = sin(latitude) * (1 + pulse * 0.055)
                z = cosLatitude * sin(longitude) * ringBias
                radiusScale = 0.96 + max(0, pulse) * 0.55
                alphaScale = 0.82 + max(0, pulse) * 0.18
                brightnessMix = 0.18 + max(0, pulse) * 0.42

            case .constellation:
                let group = Double(index % 4)
                longitude += t * (0.24 + group * 0.035) + group * 0.13
                let orbit = 1 + 0.075 * sin(t * 1.9 + group * 1.57 + latitude * 2)
                x = cosLatitude * cos(longitude) * orbit
                y = sin(latitude) * orbit
                z = cosLatitude * sin(longitude) * orbit
                radiusScale = index.isMultiple(of: 7) ? 1.42 : 0.76
                alphaScale = index.isMultiple(of: 7) ? 1 : 0.58
                brightnessMix = index.isMultiple(of: 7) ? 0.40 : 0.06

            case .breathing:
                longitude += t * 0.20
                let breath = 1 + 0.045 * sin(t * 2.25)
                    + 0.025 * sin(t * 1.35 + latitude * 4)
                x = cosLatitude * cos(longitude) * breath
                y = sin(latitude) * breath
                z = cosLatitude * sin(longitude) * breath
                radiusScale = 0.86 + 0.16 * (sin(t * 2.25) + 1) / 2
                alphaScale = 0.72 + 0.18 * (sin(t * 2.25) + 1) / 2
                brightnessMix = 0.12

            case .alert:
                let jitter = 0.035 * sin(t * 21 + Double(index) * 2.399)
                longitude += t * 0.12 + jitter
                let uneven = 1 + 0.06 * sin(t * 13 + Double(row) * 1.7)
                x = cosLatitude * cos(longitude) * uneven + jitter
                y = sin(latitude) * uneven
                z = cosLatitude * sin(longitude) * uneven
                radiusScale = 0.82 + 0.24 * max(0, sin(t * 9 + Double(index)))
                alphaScale = 0.58 + 0.34 * max(0, sin(t * 7 + Double(index) * 0.4))
                brightnessMix = 0.15 + 0.30 * max(0, sin(t * 7))
            }

            let ambientTurn = state.motion == .alert ? 0 : sin(t * 0.27) * 0.16
            (x, z) = rotate(x, z, angle: ambientTurn)
            let baseRadius = 38.0
            let perspective = 1 + z * 0.085
            let depthLight = min(1, max(0, (z + 1) / 2))
            let dotRadius = (1.18 + depthLight * 0.78) * radiusScale
            var color = tint.mixed(with: white,
                                   fraction: min(0.72, brightnessMix + depthLight * 0.16))
            color.alpha = min(1, max(0.12, (0.28 + depthLight * 0.72) * alphaScale))
            result.append(VoiceOrbParticle(
                x: centerX + x * baseRadius * perspective,
                y: centerY + y * baseRadius * perspective,
                depth: z,
                radius: dotRadius,
                color: color
            ))
        }
        return result
    }

    private func rotate(_ first: Double, _ second: Double,
                        angle: Double) -> (Double, Double) {
        let cosine = cos(angle)
        let sine = sin(angle)
        return (first * cosine - second * sine, first * sine + second * cosine)
    }

    private func drawHalo(for particles: [VoiceOrbParticle]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: 70)
        let average = particles.reduce(
            VoiceOrbRGBA(red: 0, green: 0, blue: 0, alpha: 0)
        ) { partial, particle in
            VoiceOrbRGBA(red: partial.red + particle.color.red,
                         green: partial.green + particle.color.green,
                         blue: partial.blue + particle.color.blue,
                         alpha: partial.alpha + particle.color.alpha)
        }
        let divisor = Double(max(1, particles.count))
        let tint = VoiceOrbRGBA(red: average.red / divisor,
                                green: average.green / divisor,
                                blue: average.blue / divisor,
                                alpha: average.alpha / divisor)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(calibratedRed: CGFloat(tint.red), green: CGFloat(tint.green),
                    blue: CGFloat(tint.blue), alpha: 0.13).cgColor,
            NSColor(calibratedRed: CGFloat(tint.red), green: CGFloat(tint.green),
                    blue: CGFloat(tint.blue), alpha: 0.025).cgColor,
            NSColor.clear.cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors,
                                        locations: [0, 0.52, 1]) else { return }
        let energy = particles.reduce(0.0) { $0 + $1.radius } / Double(max(1, particles.count))
        let radius = 47 + min(8, max(0, energy - 1.7) * 7)
        context.saveGState()
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 2,
                                   endCenter: center, endRadius: CGFloat(radius),
                                   options: [.drawsAfterEndLocation])
        context.restoreGState()
    }

    private func drawParticles(_ particles: [VoiceOrbParticle]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        let ordered = particles.sorted { $0.depth < $1.depth }
        for particle in ordered {
            let color = particle.color.nsColor
            let radius = CGFloat(max(0.35, particle.radius))
            context.setFillColor(color.cgColor)
            if particle.depth > 0.18 {
                context.setShadow(offset: .zero, blur: 2.2,
                                  color: color.withAlphaComponent(0.42).cgColor)
            } else {
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            context.fillEllipse(in: CGRect(x: CGFloat(particle.x) - radius,
                                           y: CGFloat(particle.y) - radius,
                                           width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    private func drawStatusLabel(at time: CFTimeInterval) {
        let labelProgress: Double
        if labelStartedAt == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            labelProgress = 1
        } else {
            labelProgress = VoiceOrbTransitionMath.smoothstep((time - labelStartedAt) / 0.24)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .paragraphStyle: paragraph,
            .shadow: shadow,
            .kern: 0.15,
        ]
        let rect = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
        if !previousLabel.isEmpty, previousLabel != state.label, labelProgress < 1 {
            var old = base
            old[.foregroundColor] = NSColor.labelColor.withAlphaComponent(
                CGFloat(max(0, 1 - labelProgress * 1.45))
            )
            let outgoing = rect.offsetBy(dx: 0, dy: CGFloat(labelProgress * 2.5))
            (previousLabel as NSString).draw(in: outgoing, withAttributes: old)
        }
        var incoming = base
        incoming[.foregroundColor] = NSColor.labelColor.withAlphaComponent(
            CGFloat(min(1, labelProgress * 1.55))
        )
        let incomingRect = rect.offsetBy(dx: 0, dy: CGFloat((1 - labelProgress) * -2.5))
        (state.label as NSString).draw(in: incomingRect, withAttributes: incoming)
    }

    private func visibleLabel(at time: CFTimeInterval) -> String {
        guard !previousLabel.isEmpty, labelStartedAt > 0 else { return state.label }
        let progress = VoiceOrbTransitionMath.smoothstep((time - labelStartedAt) / 0.24)
        return progress < 0.5 ? previousLabel : state.label
    }
}

final class VoicePipelineHUDController: NSObject, NSWindowDelegate {
    private final class OrbPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class DragSurface: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    private let windowSize = NSSize(width: 120, height: 112)
    private let panel: OrbPanel
    private let orbView: ThinkingOrbCanvasView
    private var enabled: Bool
    private var configuredIcons: [String: String]
    private var configuredLayers: [Config.LayerDefinition]
    private var currentLayerID = "BASE"
    private var visible = false
    private var listening = false
    private var awaitingReleasePhase = false
    private var currentStage: VoicePipelineVisualStage?
    private var currentModePreview: Config.DictationMode?
    private var shortCaptureExitInFlight = false
    private var appearanceGeneration = 0
    private var moveGeneration = 0
    private var presentationDisplayID: CGDirectDisplayID?
    private var isMovingProgrammatically = false
    private var cursorScreenTimer: Timer?
    private var cursorFollowSuppressedUntil: CFTimeInterval = 0
    private var modePreviewHideWork: DispatchWorkItem?
    private var meterSuppressedUntil: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init(layers: [Config.LayerDefinition] = [],
         icons: [String: String] = [:], enabled: Bool = true) {
        self.enabled = enabled
        self.configuredIcons = icons
        self.configuredLayers = layers
        let panel = OrbPanel(contentRect: NSRect(origin: .zero, size: windowSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
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
        let orbView = ThinkingOrbCanvasView(frame: root.bounds)
        orbView.autoresizingMask = [.width, .height]
        root.addSubview(orbView)
        panel.contentView = root

        self.panel = panel
        self.orbView = orbView
        super.init()
        orbView.setTint(VoiceLayerPalette.tint(for: nil, layers: layers), animated: false)
        panel.delegate = self
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
        ) { [weak self] _ in self?.orbView.relocalize() })
    }

    deinit {
        modePreviewHideWork?.cancel()
        cursorScreenTimer?.invalidate()
        orbView.stopAnimating()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func configure(layers: [Config.LayerDefinition],
                   icons: [String: String], enabled: Bool) {
        onMain { [weak self] in
            guard let self else { return }
            self.configuredLayers = layers
            self.configuredIcons = icons
            let tint = self.currentModePreview?.presentationTint
                ?? VoiceLayerPalette.tint(for: self.currentLayerID, layers: layers)
            self.orbView.setTint(tint, animated: self.visible)
            self.setEnabled(enabled)
        }
    }

    func setLayer(_ layer: String?, animated: Bool = true) {
        onMain { [weak self] in
            guard let self else { return }
            self.currentLayerID = layer?.uppercased() ?? "BASE"
            guard self.currentModePreview == nil else { return }
            self.orbView.setTint(
                VoiceLayerPalette.tint(for: self.currentLayerID,
                                       layers: self.configuredLayers),
                animated: animated && self.visible
            )
        }
    }

    func setEnabled(_ enabled: Bool) {
        onMain { [weak self] in
            guard let self else { return }
            self.enabled = enabled
            if !enabled { self.hide(animated: true) }
        }
    }

    func beginListening() {
        onMain { [weak self] in
            guard let self, self.enabled else { return }
            self.modePreviewHideWork?.cancel()
            self.modePreviewHideWork = nil
            self.appearanceGeneration += 1
            self.cancelInFlightExit()
            self.listening = true
            self.awaitingReleasePhase = false
            self.currentStage = nil
            self.currentModePreview = nil
            self.meterSuppressedUntil = 0
            self.orbView.resetAudio()
            self.orbView.setParticlesHidden(false)
            self.orbView.setTint(self.activeLayerTint(), animated: self.visible)
            self.orbView.setState(.listening, animated: self.visible)
            self.restorePositionForPresentation()
            self.showIfNeeded(entrance: !self.visible)
            // An on-screen mode symbol is already made from these particles, so setState above
            // morphs it directly back into the listening sphere. A fresh entrance is only for a
            // genuinely hidden panel.
        }
    }

    func showSelectionEditing(characterCount _: Int, applicationName _: String) {
        onMain { [weak self] in
            guard let self, self.enabled, self.visible, self.listening else { return }
            self.orbView.setState(.selectionListening)
        }
    }

    func endListening() {
        onMain { [weak self] in
            self?.listening = false
            self?.awaitingReleasePhase = true
            self?.orbView.finishAudio()
        }
    }

    /// A capture below the configured PCM-duration gate never enters processing. Its listening
    /// particles return to this appearance's own randomized entrance points while the panel stays
    /// fully opaque, making the dismissal read as a genuine reversal rather than a generic fade.
    func dismissShortCapture() {
        onMain { [weak self] in
            guard let self else { return }
            guard self.visible, self.panel.isVisible,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                self.hide(animated: true)
                return
            }
            self.modePreviewHideWork?.cancel()
            self.modePreviewHideWork = nil
            self.appearanceGeneration += 1
            let generation = self.appearanceGeneration
            self.listening = false
            self.awaitingReleasePhase = false
            self.currentStage = nil
            self.currentModePreview = nil
            self.shortCaptureExitInFlight = true
            self.orbView.finishAudio()
            self.cancelWindowAlphaAnimation()
            self.layerIdentity()
            let duration = self.orbView.prepareReverseEntranceExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.appearanceGeneration == generation,
                      self.shortCaptureExitInFlight else { return }
                self.shortCaptureExitInFlight = false
                self.visible = false
                self.stopCursorScreenTracking()
                self.orbView.stopAnimating()
                self.panel.alphaValue = 0
                self.panel.orderOut(nil)
                self.orbView.cancelReverseEntranceExit()
                self.layerIdentity()
            }
        }
    }

    func suppressMeter(for duration: TimeInterval) {
        onMain { [weak self] in
            guard let self, duration.isFinite, duration > 0 else { return }
            self.meterSuppressedUntil = CACurrentMediaTime() + min(1, duration)
            self.orbView.resetAudio()
        }
    }

    func updateVoiceMeter(_ sample: VoiceMeterSample) {
        onMain { [weak self] in
            guard let self, self.enabled, self.visible, self.listening,
                  CACurrentMediaTime() >= self.meterSuppressedUntil else { return }
            self.orbView.ingest(sample)
        }
    }

    func showVoiceModeSwitch(_ mode: Config.DictationMode) {
        onMain { [weak self] in
            guard let self, self.enabled,
                  VoiceModePresentationPolicy.showsModeSwitchCapsule(for: mode),
                  !self.listening, !self.awaitingReleasePhase,
                  self.currentStage == nil else { return }
            self.modePreviewHideWork?.cancel()
            self.modePreviewHideWork = nil
            self.cancelInFlightExit()
            self.appearanceGeneration += 1
            let generation = self.appearanceGeneration
            let wasVisible = self.visible
            self.currentModePreview = mode
            let semantic: VoiceOrbSemanticState
            switch mode {
            case .external: semantic = .modeExternal
            case .final: semantic = .modeFinal
            case .streaming: semantic = .modeLive
            }
            let symbolName = ActionVisual.firstValidSystemSymbol(
                [self.configuredIcons["voice.mode.\(mode.rawValue)"], mode.presentationSymbol,
                 self.configuredIcons["fallback"]],
                fallback: "command.circle.fill"
            )
            self.orbView.setParticlesHidden(false)
            self.orbView.setTint(mode.presentationTint, animated: wasVisible)
            self.orbView.setModeSymbol(symbolName, state: semantic, animated: true,
                                       beginWithListeningOrb: !wasVisible)
            self.restorePositionForPresentation()
            self.showIfNeeded(entrance: false)
            let hideWork = DispatchWorkItem { [weak self] in
                guard let self, self.appearanceGeneration == generation,
                      self.currentModePreview == mode,
                      !self.listening, self.currentStage == nil else { return }
                self.modePreviewHideWork = nil
                self.hide(animated: true)
            }
            self.modePreviewHideWork = hideWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.98, execute: hideWork)
        }
    }

    func showNativeDictationPhase(_ phase: VoiceDictationPhase, message _: String) {
        onMain { [weak self] in
            guard let self, self.enabled else { return }
            switch phase {
            case .priming, .listening:
                return
            case .idle:
                self.awaitingReleasePhase = false
                if self.shortCaptureExitInFlight { return }
                self.hide(animated: true)
            case .transcribing, .polishing, .rewriting, .inserting, .inserted, .replaced,
                 .copied, .error:
                guard let stage = VoicePipelineVisualStage(phase) else { return }
                self.transition(to: stage)
            }
        }
    }

    func hideImmediately() { onMain { [weak self] in self?.hide(animated: false) } }

    func listeningPresentationIsVisibleForTesting() -> Bool {
        listening && visible && panel.isVisible && panel.alphaValue >= 0.98
    }

    /// Production-inert probes for the isolated mode-selector QC paths. During the panel's exit,
    /// the symbol must remain the only visible central content until the window is fully gone.
    func modePreviewExitIsCleanForTesting() -> Bool {
        visible && panel.isVisible && orbView.isRenderingModeSymbolForTesting()
    }

    func writeSnapshotForTesting(to url: URL) -> Bool {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func transition(to stage: VoicePipelineVisualStage) {
        modePreviewHideWork?.cancel()
        modePreviewHideWork = nil
        cancelInFlightExit()
        listening = false
        awaitingReleasePhase = false
        currentStage = stage
        currentModePreview = nil
        orbView.setParticlesHidden(false)
        orbView.setTint(activeLayerTint(), animated: visible)
        let semantic: VoiceOrbSemanticState
        switch stage {
        case .transcribing: semantic = .transcribing
        case .polishing: semantic = .polishing
        case .rewriting: semantic = .rewriting
        case .inserting: semantic = .inserting
        case .inserted: semantic = .inserted
        case .replaced: semantic = .replaced
        case .copied: semantic = .copied
        case .error: semantic = .error
        }
        orbView.setState(semantic, animated: visible)
        restorePositionForPresentation()
        showIfNeeded(entrance: !visible)
    }

    private func showIfNeeded(entrance: Bool) {
        guard enabled else { return }
        let wasVisible = visible
        if !visible {
            visible = true
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
        startCursorScreenTracking()
        orbView.startAnimating()
        cancelWindowAlphaAnimation()
        guard entrance, !wasVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layerIdentity()
            return
        }
        orbView.prepareEntrance()
        layerIdentity()
    }

    private func hide(animated: Bool) {
        guard visible || panel.isVisible else { return }
        modePreviewHideWork?.cancel()
        modePreviewHideWork = nil
        appearanceGeneration += 1
        let generation = appearanceGeneration
        listening = false
        awaitingReleasePhase = false
        currentStage = nil
        currentModePreview = nil
        shortCaptureExitInFlight = false
        orbView.cancelReverseEntranceExit()
        orbView.finishAudio()
        guard animated else {
            visible = false
            stopCursorScreenTracking()
            orbView.stopAnimating()
            panel.alphaValue = 0
            panel.orderOut(nil)
            layerIdentity()
            return
        }
        if let layer = orbView.layer,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
            scale.toValue = 0.96
            scale.duration = 0.16
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.50, 0.02, 0.78, 0.20)
            layer.add(scale, forKey: "orbExitScale")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.appearanceGeneration == generation else { return }
            self.visible = false
            self.stopCursorScreenTracking()
            self.orbView.stopAnimating()
            self.panel.orderOut(nil)
            self.layerIdentity()
        })
    }

    private func cancelInFlightExit() {
        appearanceGeneration += 1
        shortCaptureExitInFlight = false
        orbView.cancelReverseEntranceExit()
        cancelWindowAlphaAnimation()
        restoreLayerAfterInterruption()
    }

    private func activeLayerTint() -> NSColor {
        VoiceLayerPalette.tint(for: currentLayerID, layers: configuredLayers)
    }

    private func cancelWindowAlphaAnimation() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
    }

    private func layerIdentity() {
        guard let layer = orbView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Continue from the window's actual in-flight scale instead of snapping back to 100%. This
    /// complements the particle renderer's pose snapshot: both the outer entrance/exit envelope
    /// and the internal orb geometry remain continuous when a fresh turn interrupts an exit.
    private func restoreLayerAfterInterruption() {
        guard let layer = orbView.layer else { return }
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        guard panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: currentTransform)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transform.duration = 0.16
        transform.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.16, 1)
        layer.add(transform, forKey: "orbInterruptionScaleRecovery")
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = currentOpacity
        opacity.toValue = 1
        opacity.duration = 0.12
        opacity.timingFunction = transform.timingFunction
        layer.add(opacity, forKey: "orbInterruptionOpacityRecovery")
    }

    func windowDidMove(_ notification: Notification) {
        guard visible, !isMovingProgrammatically else { return }
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
        let origin = VoicePipelineScreenPlacement.defaultOrigin(
            windowSize: windowSize, visibleFrame: screen.visibleFrame
        )
        setFrameOrigin(clampedOrigin(origin, in: screen.visibleFrame))
        presentationDisplayID = screen.hudDisplayID
    }

    private func settleAfterDrag() {
        guard let screen = bestScreen(for: panel.frame) else { return }
        let pointerScreen = screenContainingMouse() ?? screen
        if presentationDisplayID != pointerScreen.hudDisplayID {
            moveToDefaultPosition(on: pointerScreen)
            panel.orderFrontRegardless()
            return
        }
        let origin = clampedOrigin(panel.frame.origin, in: screen.visibleFrame)
        if origin != panel.frame.origin { setFrameOrigin(origin) }
        presentationDisplayID = screen.hudDisplayID
    }

    private func screenParametersChanged() {
        guard visible else { return }
        followCursorScreen(force: true)
        panel.orderFrontRegardless()
    }

    private func activeSpaceChanged() {
        guard visible else { return }
        followCursorScreen(force: false)
        ensureReachable()
        panel.orderFrontRegardless()
    }

    private func ensureReachable() {
        let area = NSScreen.screens.reduce(CGFloat(0)) {
            let intersection = panel.frame.intersection($1.visibleFrame)
            return $0 + (intersection.isNull || intersection.isEmpty
                         ? 0 : intersection.width * intersection.height)
        }
        if area < 16 { followCursorScreen(force: true) }
    }

    private func screenContainingMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = VoicePipelineScreenPlacement.screenIndex(
            containing: NSEvent.mouseLocation, frames: screens.map(\.frame)
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
        panel.orderFrontRegardless()
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let overlapping = screens.max(by: {
            let first = frame.intersection($0.visibleFrame)
            let second = frame.intersection($1.visibleFrame)
            let firstArea = first.isNull || first.isEmpty ? 0 : first.width * first.height
            let secondArea = second.isNull || second.isEmpty ? 0 : second.width * second.height
            return firstArea < secondArea
        }) {
            let overlap = frame.intersection(overlapping.visibleFrame)
            if !overlap.isNull, !overlap.isEmpty { return overlapping }
        }
        return screenContainingMouse() ?? NSScreen.main ?? screens[0]
    }

    private func clampedOrigin(_ point: NSPoint, in visible: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, visible.minX),
                       max(visible.minX, visible.maxX - windowSize.width)),
                y: min(max(point.y, visible.minY),
                       max(visible.minY, visible.maxY - windowSize.height)))
    }

    private func setFrameOrigin(_ point: NSPoint) {
        isMovingProgrammatically = true
        panel.setFrameOrigin(point)
        DispatchQueue.main.async { [weak self] in self?.isMovingProgrammatically = false }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
