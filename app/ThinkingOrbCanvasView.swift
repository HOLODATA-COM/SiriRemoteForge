//
//  ThinkingOrbCanvasView.swift
//  HyperVibe
//
//  Thin AppKit renderer around ThinkingOrbEngine. The geometry, depth shading and painter order
//  remain upstream-compatible; HyperVibe adds interruptible per-dot motion and a live acoustic
//  envelope for the listening wave.
//

import AppKit
import QuartzCore

enum ThinkingOrbSymbolGeometry {
    /// Turns the configured SF Symbol into a dotted target pose. The image is only a mask: the
    /// renderer still draws the same independent particles used by the listening sphere, and the
    /// normal interruptible transition engine moves those particles into this silhouette.
    static func systemSymbolFrame(_ symbolName: String,
                                  time: Double,
                                  center: Double = 37,
                                  extent: Double = 60) -> ThinkingOrbFrame {
        let pixelSize = 96
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return ThinkingOrbFrame(dots: [], lines: []) }

        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return ThinkingOrbFrame(dots: [], lines: [])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        let available = 84.0
        let sourceSize = image.size
        let scale = min(available / max(1, sourceSize.width),
                        available / max(1, sourceSize.height))
        let drawSize = NSSize(width: sourceSize.width * scale,
                              height: sourceSize.height * scale)
        let drawRect = NSRect(x: (Double(pixelSize) - drawSize.width) / 2,
                              y: (Double(pixelSize) - drawSize.height) / 2,
                              width: drawSize.width, height: drawSize.height)
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var dots: [ThinkingOrbDot] = []
        var ordinal = 0
        // A four-pixel lattice produces roughly the listening sphere's 134 particles for the
        // default symbols. A tiny deterministic offset prevents the result looking like pixels.
        for pixelY in stride(from: 6, to: pixelSize - 5, by: 4) {
            for pixelX in stride(from: 6, to: pixelSize - 5, by: 4) {
                guard let color = bitmap.colorAt(x: pixelX, y: pixelY),
                      color.alphaComponent >= 0.14 else { continue }
                let individuality = sin(Double(ordinal) * 2.399)
                let jitterX = 0.28 * sin(Double(ordinal) * 1.731)
                let jitterY = 0.28 * cos(Double(ordinal) * 2.117)
                let x = center + (Double(pixelX) - Double(pixelSize) / 2)
                    / available * extent + jitterX
                let y = center + (Double(pixelY) - Double(pixelSize) / 2)
                    / available * extent + jitterY
                dots.append(ThinkingOrbDot(
                    x: x, y: y, z: individuality * 0.04,
                    r: 0.91 + 0.09 * sin(time * 1.2 + Double(ordinal) * 0.43),
                    white: 0.12 + 0.10 * (individuality + 1) / 2,
                    alpha: min(1, 0.72 + Double(color.alphaComponent) * 0.28)
                ))
                ordinal += 1
            }
        }
        dots.sort { $0.z < $1.z }
        return ThinkingOrbFrame(dots: dots, lines: [])
    }

    static func frame(success: Bool, time: Double,
                      center: Double = 32) -> ThinkingOrbFrame {
        let offset = center - 32
        let paths: [(CGPoint, CGPoint, Int)] = success
            ? [(CGPoint(x: 14 + offset, y: 34 + offset),
                CGPoint(x: 27 + offset, y: 46 + offset), 18),
               (CGPoint(x: 27 + offset, y: 46 + offset),
                CGPoint(x: 51 + offset, y: 18 + offset), 34)]
            : [(CGPoint(x: 18 + offset, y: 18 + offset),
                CGPoint(x: 46 + offset, y: 46 + offset), 28),
               (CGPoint(x: 46 + offset, y: 18 + offset),
                CGPoint(x: 18 + offset, y: 46 + offset), 28)]
        var dots: [ThinkingOrbDot] = []
        var ordinal = 0
        for (pathIndex, path) in paths.enumerated() {
            for index in 0..<path.2 where pathIndex == 0 || index > 0 {
                let fraction = Double(index) / Double(max(1, path.2 - 1))
                let x = Double(path.0.x) + (Double(path.1.x) - Double(path.0.x)) * fraction
                let y = Double(path.0.y) + (Double(path.1.y) - Double(path.0.y)) * fraction
                let individuality = sin(Double(ordinal) * 2.399)
                dots.append(ThinkingOrbDot(
                    x: x, y: y, z: individuality * 0.025,
                    r: 1.02 + 0.10 * sin(time * 0.9 + Double(ordinal) * 0.47),
                    white: 0.12 + 0.10 * (individuality + 1) / 2
                ))
                ordinal += 1
            }
        }
        dots.sort { $0.z < $1.z }
        return ThinkingOrbFrame(dots: dots, lines: [])
    }

    static func copyFrame(time: Double, center: Double = 32) -> ThinkingOrbFrame {
        let offset = center - 32
        var dots: [ThinkingOrbDot] = []
        var ordinal = 0
        appendRoundedSquare(center: CGPoint(x: 27.5 + offset, y: 27.5 + offset), halfSize: 12.5,
                            count: 38, alpha: 0.56, white: 0.30,
                            time: time, ordinal: &ordinal, dots: &dots)
        appendRoundedSquare(center: CGPoint(x: 37.5 + offset, y: 37.5 + offset), halfSize: 12.5,
                            count: 42, alpha: 1, white: 0.12,
                            time: time, ordinal: &ordinal, dots: &dots)
        dots.sort { $0.z < $1.z }
        return ThinkingOrbFrame(dots: dots, lines: [])
    }

    private static func appendRoundedSquare(center: CGPoint,
                                            halfSize: Double,
                                            count: Int,
                                            alpha: Double,
                                            white: Double,
                                            time: Double,
                                            ordinal: inout Int,
                                            dots: inout [ThinkingOrbDot]) {
        for index in 0..<count {
            let angle = -.pi / 2 + Double(index) / Double(count) * 2 * .pi
            let cosine = cos(angle)
            let sine = sin(angle)
            let x = Double(center.x)
                + halfSize * copysign(pow(abs(cosine), 0.28), cosine)
            let y = Double(center.y)
                + halfSize * copysign(pow(abs(sine), 0.28), sine)
            let individuality = sin(Double(ordinal) * 2.399)
            dots.append(ThinkingOrbDot(
                x: x, y: y, z: individuality * 0.025,
                r: 0.92 + 0.08 * sin(time * 0.9 + Double(ordinal) * 0.41),
                white: white + 0.06 * (individuality + 1) / 2,
                alpha: alpha
            ))
            ordinal += 1
        }
    }
}

enum ThinkingOrbEntranceMath {
    static let duration = 0.22
    static let initialRadius = 0.58

    static func dot(_ target: ThinkingOrbDot, index: Int,
                    elapsed: CFTimeInterval,
                    entranceSeed: Double,
                    center: Double = 32) -> ThinkingOrbDot {
        let directionSeed = hashUnit(index, salt: entranceSeed + 0.137)
        let distanceSeed = hashUnit(index, salt: entranceSeed + 4.731)
        let curveSeed = hashUnit(index, salt: entranceSeed + 14.913)
        // No stagger: every particle leaves its random start as soon as the first frame advances.
        let local = min(1, max(0, elapsed / duration))
        let settled = ThinkingOrbTransitionMath.smoothstep(local)
        // Opacity establishes in the opening quarter while particles are still near the window
        // edges. The travel therefore reads first; fading only softens the initial appearance.
        let fade = ThinkingOrbTransitionMath.smoothstep(min(1, local / 0.28))
        let remaining = local - 1
        // A restrained ease-out-back: fast, fully legible travel with one small overshoot.
        let spring = local >= 1 ? 1
            : 1 + 1.7 * remaining * remaining * remaining
                + 0.7 * remaining * remaining

        // Each presentation receives a new seed. Independent polar starts beyond the finished
        // sphere make particles arrive from every side of the window rather than expanding from
        // a shared centre or replaying the same arrangement on every hold.
        let startAngle = directionSeed * 2 * .pi
        let startDistance = 60 + distanceSeed * 24
        let startX = center + cos(startAngle) * startDistance
        let startY = center + sin(startAngle) * startDistance
        let travelX = target.x - startX
        let travelY = target.y - startY
        let travelLength = max(0.001, hypot(travelX, travelY))
        let tangentX = -travelY / travelLength
        let tangentY = travelX / travelLength
        let arc = sin(.pi * settled) * (curveSeed - 0.5) * 7.5
        let radiusBounce = sin(.pi * settled) * target.r * (0.06 + 0.08 * curveSeed)

        return ThinkingOrbDot(
            x: startX + (target.x - startX) * spring + tangentX * arc,
            y: startY + (target.y - startY) * spring + tangentY * arc,
            z: target.z,
            r: max(0.18,
                   initialRadius + (target.r - initialRadius) * settled + radiusBounce),
            white: target.white,
            alpha: target.alpha * fade
        )
    }

    /// Replays the same seeded particle route backwards. `source` is deliberately a snapshot of
    /// the actually rendered dot, so releasing while the entrance is still in flight cannot snap
    /// the particle to its authored listening position before it leaves.
    static func departureDot(_ source: ThinkingOrbDot, index: Int,
                             elapsed: CFTimeInterval,
                             entranceSeed: Double,
                             center: Double = 32) -> ThinkingOrbDot {
        dot(source, index: index,
            elapsed: max(0, duration - min(duration, elapsed)),
            entranceSeed: entranceSeed, center: center)
    }

    private static func hashUnit(_ index: Int, salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43_758.5453
        return value - floor(value)
    }
}

final class ThinkingOrbCanvasView: NSView {
    private static let orbSize = 84.0
    private static let particleRadiusScale = 1.14
    // Leave a stable gap above the status word while giving a voiced outer-ring hit enough room
    // to travel beyond the authored sphere without clipping against the expanded window.
    private static let orbOriginY = 22.0
    private static let orbCenter = orbSize / 2
    private static let transitionDuration = 0.54
    private static let transitionStagger = 0.10
    private static let entranceDuration = ThinkingOrbEntranceMath.duration

    private struct DotPair {
        var source: ThinkingOrbDot
        var target: ThinkingOrbDot
        var seed: Double
        var delay: Double
    }

    private var state: VoiceOrbSemanticState = .listening
    private var modeSymbolName: String?
    private var modeSymbolFrames: [String: ThinkingOrbFrame] = [:]
    private var transitionPairs: [DotPair] = []
    private var transitionSourceLines: [ThinkingOrbLine] = []
    private var transitionTargetLines: [ThinkingOrbLine] = []
    private var transitionStartedAt: CFTimeInterval = 0
    private var motionStartsAt: CFTimeInterval = 0
    private var entranceStartedAt: CFTimeInterval = 0
    private var entranceSeed = 0.0
    private var departureSourceFrame: ThinkingOrbFrame?
    private var departureStartedAt: CFTimeInterval = 0
    private var particlesHidden = false
    private var tint = NSColor.systemGreen
    private var previousTint = NSColor.systemGreen
    private var tintStartedAt: CFTimeInterval = 0
    private var previousLabel = ""
    private var labelStartedAt: CFTimeInterval = 0

    private var frameTimer: Timer?
    private var lastFrameAt: CFTimeInterval = 0
    private var lastMeterAt: CFTimeInterval = 0
    private var targetHistory = [Double](repeating: 0, count: 10)
    private var displayedHistory = [Double](repeating: 0, count: 10)
    private var targetLevel = 0.0
    private var displayedLevel = 0.0
    private var targetPitch = 0.0
    private var displayedPitch = 0.0
    private var targetPitchConfidence = 0.0
    private var displayedPitchConfidence = 0.0
    private var targetBrightness = 0.0
    private var displayedBrightness = 0.0
    private var pitchBaselineLog2: Double?

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
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
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
        let oldLabel = visibleLabel(at: now)
        let source = presentationFrame(at: now)
        let oldState = state
        state = newState
        previousLabel = oldLabel
        labelStartedAt = now
        setAccessibilityLabel(newState.label)
        let shouldMorph = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && oldState.renderFamily != newState.renderFamily
        if shouldMorph {
            motionStartsAt = now + Self.transitionDuration
            let target = authoredFrame(at: now)
            beginTransition(from: source, to: target, at: now)
        } else if animated, oldState.renderFamily == newState.renderFamily {
            // Selection-listening and ordinary listening share one physical orb. Only their word
            // changes; keep every ring and any in-flight entrance exactly where it is.
        } else {
            transitionPairs = []
            transitionSourceLines = []
            transitionTargetLines = []
            transitionStartedAt = 0
            motionStartsAt = now
        }
        needsDisplay = true
    }

    /// Morphs the currently rendered particles into a configured mode symbol. Capturing the
    /// source before replacing `modeSymbolName` is important when a rapid hardware chord changes
    /// one icon into the next while the previous transition is still in flight.
    func setModeSymbol(_ symbolName: String,
                       state newState: VoiceOrbSemanticState,
                       animated: Bool = true,
                       beginWithListeningOrb: Bool = false) {
        let now = CACurrentMediaTime()
        if beginWithListeningOrb {
            state = .listening
            modeSymbolName = nil
            transitionPairs = []
            transitionSourceLines = []
            transitionTargetLines = []
            transitionStartedAt = 0
        }
        let source = presentationFrame(at: now)
        let oldLabel = visibleLabel(at: now)
        modeSymbolName = symbolName
        state = newState
        // When the panel itself is appearing, there is no visible outgoing word to crossfade.
        // Keeping "Listening" here produced a muddy one-frame overlap with the selected mode.
        previousLabel = beginWithListeningOrb ? "" : oldLabel
        labelStartedAt = now
        setAccessibilityLabel(newState.label)
        motionStartsAt = now + Self.transitionDuration
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            beginTransition(from: source, to: authoredFrame(at: now), at: now)
        } else {
            transitionPairs = []
            transitionSourceLines = []
            transitionTargetLines = []
            transitionStartedAt = 0
            motionStartsAt = now
        }
        needsDisplay = true
    }

    func isRenderingModeSymbolForTesting() -> Bool {
        state.isModePreview && modeSymbolName != nil && !particlesHidden
    }

    func prepareEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        departureSourceFrame = nil
        departureStartedAt = 0
        entranceStartedAt = now
        entranceSeed = Double.random(in: 0..<1)
        motionStartsAt = max(motionStartsAt, now + Self.entranceDuration * 0.70)
        needsDisplay = true
    }

    /// Sends every currently visible particle back toward the far-away point assigned to it for
    /// this appearance. Returning the duration lets the owning panel remain fully opaque until the
    /// last particle has arrived and faded, instead of hiding the effect with a window-level fade.
    @discardableResult
    func prepareReverseEntranceExit() -> CFTimeInterval {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        let now = CACurrentMediaTime()
        departureSourceFrame = presentationFrame(at: now)
        departureStartedAt = now
        entranceStartedAt = 0
        transitionPairs = []
        transitionSourceLines = []
        transitionTargetLines = []
        transitionStartedAt = 0
        needsDisplay = true
        return Self.entranceDuration
    }

    func cancelReverseEntranceExit() {
        departureSourceFrame = nil
        departureStartedAt = 0
        needsDisplay = true
    }

    func setParticlesHidden(_ hidden: Bool) {
        particlesHidden = hidden
        needsDisplay = true
    }

    func particlesAreHiddenForTesting() -> Bool { particlesHidden }

    func setTint(_ color: NSColor, animated: Bool = true) {
        let now = CACurrentMediaTime()
        previousTint = renderedTint(at: now)
        tint = color
        tintStartedAt = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? now : 0
        needsDisplay = true
    }

    func relocalize() {
        previousLabel = state.label
        labelStartedAt = 0
        setAccessibilityLabel(state.label)
        needsDisplay = true
    }

    func resetAudio() {
        lastMeterAt = 0
        targetHistory = [Double](repeating: 0, count: 10)
        displayedHistory = [Double](repeating: 0, count: 10)
        targetLevel = 0
        displayedLevel = 0
        targetPitch = 0
        displayedPitch = 0
        targetPitchConfidence = 0
        displayedPitchConfidence = 0
        targetBrightness = 0
        displayedBrightness = 0
        pitchBaselineLog2 = nil
        needsDisplay = true
    }

    func finishAudio() {
        targetHistory = [Double](repeating: 0, count: 10)
        targetLevel = 0
        targetPitchConfidence = 0
        targetBrightness = 0
    }

    func ingest(_ sample: VoiceMeterSample) {
        let raw = sample.level.isFinite ? Double(sample.level) : 0
        let perceptual = min(1, max(0, pow(raw, 0.72)))
        targetLevel = perceptual
        targetHistory.removeFirst()
        targetHistory.append(perceptual)
        let confidence = sample.pitchConfidence.isFinite
            ? min(1, max(0, Double(sample.pitchConfidence))) : 0
        targetPitchConfidence = confidence
        if confidence > 0.32, sample.pitchHz.isFinite,
           sample.pitchHz > 55, sample.pitchHz < 1_200 {
            let pitchLog2 = log2(Double(sample.pitchHz))
            if pitchBaselineLog2 == nil { pitchBaselineLog2 = pitchLog2 }
            let baseline = pitchBaselineLog2 ?? pitchLog2
            targetPitch = min(1, max(-1, (pitchLog2 - baseline) / (7.0 / 12.0)))
            pitchBaselineLog2 = baseline + (pitchLog2 - baseline) * 0.004
        }
        targetBrightness = sample.brightness.isFinite
            ? min(1, max(0, Double(sample.brightness))) : 0
        lastMeterAt = CACurrentMediaTime()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = CACurrentMediaTime()
        if !particlesHidden {
            draw(presentationFrame(at: now), tint: renderedTint(at: now))
        }
        drawLabel(at: now)
    }

    private func renderedTint(at time: CFTimeInterval) -> NSColor {
        guard tintStartedAt > 0 else { return tint }
        let progress = ThinkingOrbTransitionMath.smoothstep((time - tintStartedAt) / 0.28)
        if progress >= 1 {
            tintStartedAt = 0
            previousTint = tint
            return tint
        }
        return previousTint.blended(withFraction: CGFloat(progress), of: tint) ?? tint
    }

    private func advanceFrame() {
        let now = CACurrentMediaTime()
        let delta = lastFrameAt > 0 ? min(0.05, max(0, now - lastFrameAt)) : 1 / 60
        lastFrameAt = now
        if lastMeterAt > 0, now - lastMeterAt > 0.12 {
            let decay = pow(0.055, delta)
            for index in targetHistory.indices { targetHistory[index] *= decay }
            targetLevel *= decay
            targetPitchConfidence *= decay
            targetBrightness *= decay
        }
        for index in displayedHistory.indices {
            let target = targetHistory[index]
            let constant = target > displayedHistory[index] ? 0.038 : 0.15
            let fraction = 1 - exp(-delta / constant)
            displayedHistory[index] += (target - displayedHistory[index]) * fraction
        }
        displayedLevel = approach(displayedLevel, targetLevel, delta: delta,
                                  rise: 0.032, fall: 0.14)
        displayedPitch = approach(displayedPitch, targetPitch, delta: delta,
                                  rise: 0.07, fall: 0.12)
        displayedPitchConfidence = approach(displayedPitchConfidence, targetPitchConfidence,
                                            delta: delta, rise: 0.06, fall: 0.16)
        displayedBrightness = approach(displayedBrightness, targetBrightness,
                                       delta: delta, rise: 0.07, fall: 0.18)
        needsDisplay = true
    }

    private func approach(_ current: Double, _ target: Double, delta: Double,
                          rise: Double, fall: Double) -> Double {
        let constant = target > current ? rise : fall
        let fraction = 1 - exp(-delta / max(0.001, constant))
        return current + (target - current) * fraction
    }

    private func authoredFrame(at time: CFTimeInterval) -> ThinkingOrbFrame {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let age = max(0, time - motionStartsAt)
        let rawTime = reducedMotion ? 0.6 : Double(age) * state.orbState.speed
        if state.isModePreview, let modeSymbolName {
            return modeSymbolFrame(named: modeSymbolName, time: Double(age))
        }
        if state == .copied {
            return ThinkingOrbSymbolGeometry.copyFrame(time: Double(age),
                                                        center: Self.orbCenter)
        }
        if let success = state.completionSymbol {
            return ThinkingOrbSymbolGeometry.frame(success: success, time: Double(age),
                                                    center: Self.orbCenter)
        }
        let acoustics = !reducedMotion && state.orbState == .listening
            ? ThinkingOrbAcoustics(ringLevels: displayedHistory,
                                   overallLevel: displayedLevel,
                                   pitch: displayedPitch,
                                   pitchConfidence: displayedPitchConfidence,
                                   brightness: displayedBrightness) : nil
        return ThinkingOrbEngine.frame(state: state.orbState, size: Self.orbSize,
                                       time: rawTime, acoustics: acoustics)
    }

    private func modeSymbolFrame(named symbolName: String,
                                 time: Double) -> ThinkingOrbFrame {
        let base: ThinkingOrbFrame
        if let cached = modeSymbolFrames[symbolName] {
            base = cached
        } else {
            let sampled = ThinkingOrbSymbolGeometry.systemSymbolFrame(
                symbolName, time: 0, center: Self.orbCenter
            )
            modeSymbolFrames[symbolName] = sampled
            base = sampled
        }
        let dots = base.dots.enumerated().map { index, dot -> ThinkingOrbDot in
            var animated = dot
            animated.r = 0.91 + 0.09 * sin(time * 1.2 + Double(index) * 0.43)
            return animated
        }
        return ThinkingOrbFrame(dots: dots, lines: [])
    }

    /// Every visible dot receives its own destination, delay and under-damped trajectory. A new
    /// state captures these current in-flight positions and immediately remaps from there.
    private func presentationFrame(at time: CFTimeInterval) -> ThinkingOrbFrame {
        if let departureSourceFrame {
            return departureFrame(departureSourceFrame, at: time)
        }
        let target = authoredFrame(at: time)
        let base: ThinkingOrbFrame
        if transitionPairs.isEmpty {
            base = target
        } else {
            let elapsed = time - transitionStartedAt
            if elapsed >= Self.transitionDuration {
                transitionPairs = []
                transitionSourceLines = []
                transitionTargetLines = []
                base = target
            } else {
                base = interpolatedTransition(elapsed: elapsed)
            }
        }
        return entranceFrame(base, at: time)
    }

    private func departureFrame(_ source: ThinkingOrbFrame,
                                at time: CFTimeInterval) -> ThinkingOrbFrame {
        let elapsed = min(Self.entranceDuration, max(0, time - departureStartedAt))
        let dots = source.dots.enumerated().map { index, dot in
            ThinkingOrbEntranceMath.departureDot(
                dot, index: index, elapsed: elapsed, entranceSeed: entranceSeed,
                center: Self.orbCenter
            )
        }.sorted { $0.z < $1.z }
        let lineOpacity = 1 - ThinkingOrbTransitionMath.smoothstep(
            elapsed / Self.entranceDuration
        )
        let lines = source.lines.map { line -> ThinkingOrbLine in
            var copy = line
            copy.alpha *= lineOpacity
            return copy
        }
        return ThinkingOrbFrame(dots: dots, lines: lines)
    }

    private func beginTransition(from source: ThinkingOrbFrame,
                                 to target: ThinkingOrbFrame,
                                 at time: CFTimeInterval) {
        let sourceOrder = polarOrder(source.dots)
        let targetOrder = polarOrder(target.dots)
        let pairCount = max(sourceOrder.count, targetOrder.count)
        guard pairCount > 0 else {
            transitionPairs = []
            return
        }
        var sourceSlots: [Int] = []
        var targetSlots: [Int] = []
        sourceSlots.reserveCapacity(pairCount)
        targetSlots.reserveCapacity(pairCount)
        for index in 0..<pairCount {
            sourceSlots.append(min(sourceOrder.count - 1,
                Int(Double(index) / Double(pairCount) * Double(sourceOrder.count))))
            targetSlots.append(min(targetOrder.count - 1,
                Int(Double(index) / Double(pairCount) * Double(targetOrder.count))))
        }
        let sourceMultiplicity = Dictionary(grouping: sourceSlots, by: { $0 })
            .mapValues(\.count)
        let targetMultiplicity = Dictionary(grouping: targetSlots, by: { $0 })
            .mapValues(\.count)
        transitionPairs = (0..<pairCount).map { index in
            var sourceDot = source.dots[sourceOrder[sourceSlots[index]]]
            var targetDot = target.dots[targetOrder[targetSlots[index]]]
            sourceDot.alpha /= Double(sourceMultiplicity[sourceSlots[index]] ?? 1)
            targetDot.alpha /= Double(targetMultiplicity[targetSlots[index]] ?? 1)
            let seed = hashUnit(index)
            return DotPair(source: sourceDot, target: targetDot, seed: seed,
                           delay: seed * Self.transitionStagger)
        }
        transitionSourceLines = source.lines
        transitionTargetLines = target.lines
        transitionStartedAt = time
    }

    private func interpolatedTransition(elapsed: CFTimeInterval) -> ThinkingOrbFrame {
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(transitionPairs.count)
        for pair in transitionPairs {
            let available = Self.transitionDuration - Self.transitionStagger
            let local = min(1, max(0, (elapsed - pair.delay) / available))
            let opacityProgress = ThinkingOrbTransitionMath.smoothstep(local)
            let springProgress = local >= 1 ? 1
                : 1 - exp(-7.2 * local) * (cos(10.4 * local) + 0.10 * sin(10.4 * local))
            let arc = sin(.pi * opacityProgress) * (pair.seed - 0.5) * 4.2
            var dot = ThinkingOrbDot(
                x: pair.source.x + (pair.target.x - pair.source.x) * springProgress + arc,
                y: pair.source.y + (pair.target.y - pair.source.y) * springProgress,
                z: pair.source.z + (pair.target.z - pair.source.z) * opacityProgress,
                r: max(0.18, pair.source.r + (pair.target.r - pair.source.r) * opacityProgress),
                white: pair.source.white
                    + (pair.target.white - pair.source.white) * opacityProgress,
                alpha: pair.source.alpha
                    + (pair.target.alpha - pair.source.alpha) * opacityProgress
            )
            if dot.alpha < 0.02 { dot.alpha = 0 }
            dots.append(dot)
        }
        dots.sort { $0.z < $1.z }
        let lineProgress = ThinkingOrbTransitionMath.smoothstep(
            elapsed / Self.transitionDuration
        )
        let sourceLines = transitionSourceLines.map { line -> ThinkingOrbLine in
            var copy = line
            copy.alpha *= 1 - lineProgress
            return copy
        }
        let targetLines = transitionTargetLines.map { line -> ThinkingOrbLine in
            var copy = line
            copy.alpha *= lineProgress
            return copy
        }
        return ThinkingOrbFrame(dots: dots,
                                lines: (sourceLines + targetLines).filter { $0.alpha >= 0.02 })
    }

    private func entranceFrame(_ frame: ThinkingOrbFrame,
                               at time: CFTimeInterval) -> ThinkingOrbFrame {
        guard entranceStartedAt > 0 else { return frame }
        let elapsed = time - entranceStartedAt
        guard elapsed < Self.entranceDuration else {
            entranceStartedAt = 0
            return frame
        }
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(frame.dots.count)
        for (index, target) in frame.dots.enumerated() {
            dots.append(ThinkingOrbEntranceMath.dot(
                target, index: index, elapsed: elapsed, entranceSeed: entranceSeed,
                center: Self.orbCenter
            ))
        }
        dots.sort { $0.z < $1.z }
        return ThinkingOrbFrame(dots: dots, lines: frame.lines)
    }

    private func polarOrder(_ dots: [ThinkingOrbDot]) -> [Int] {
        dots.indices.sorted { lhs, rhs in
            let left = atan2(dots[lhs].y - Self.orbCenter,
                             dots[lhs].x - Self.orbCenter)
            let right = atan2(dots[rhs].y - Self.orbCenter,
                              dots[rhs].x - Self.orbCenter)
            if abs(left - right) > 0.000_001 { return left < right }
            let leftRadius = hypot(dots[lhs].x - Self.orbCenter,
                                   dots[lhs].y - Self.orbCenter)
            let rightRadius = hypot(dots[rhs].x - Self.orbCenter,
                                    dots[rhs].y - Self.orbCenter)
            return leftRadius < rightRadius
        }
    }

    private func hashUnit(_ index: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + 78.233) * 43_758.5453
        return value - floor(value)
    }

    private func draw(_ frame: ThinkingOrbFrame, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let originX = (Double(bounds.width) - Self.orbSize) / 2
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resolvedTint = tint.usingColorSpace(.deviceRGB) ?? tint
        context.saveGState()
        context.translateBy(x: originX, y: Self.orbOriginY + Self.orbSize)
        context.scaleBy(x: 1, y: -1)

        for line in frame.lines {
            let white = min(1, max(0, line.white))
            context.setStrokeColor(inkColor(tint: resolvedTint, white: white,
                                            dark: dark,
                                            alpha: min(1, max(0, line.alpha))).cgColor)
            context.setLineWidth(line.width * 1.08)
            context.beginPath()
            context.move(to: CGPoint(x: line.x1, y: line.y1))
            context.addLine(to: CGPoint(x: line.x2, y: line.y2))
            context.strokePath()
        }
        for dot in frame.dots {
            let white = min(1, max(0, dot.white))
            context.setFillColor(inkColor(tint: resolvedTint, white: white,
                                          dark: dark,
                                          alpha: min(1, max(0, dot.alpha))).cgColor)
            let radius = dot.r * Self.particleRadiusScale
            context.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius,
                                           width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    /// Preserve the upstream front/back depth signal while expressing it through the active
    /// Layer hue. This changes neither geometry nor alpha and adds no outline around the sphere.
    private func inkColor(tint: NSColor, white: Double,
                          dark: Bool, alpha: Double) -> NSColor {
        let frontness = CGFloat(1 - white)
        let anchor: NSColor = dark ? .white : .black
        let fraction = dark
            ? 0.18 + frontness * 0.52
            : 0.10 + frontness * 0.30
        let colored = tint.blended(withFraction: fraction, of: anchor) ?? tint
        return colored.withAlphaComponent(CGFloat(alpha))
    }

    private func drawLabel(at time: CFTimeInterval) {
        let progress = labelStartedAt > 0
            ? ThinkingOrbTransitionMath.smoothstep((time - labelStartedAt) / 0.22) : 1
        let departureOpacity = departureStartedAt > 0
            ? 1 - ThinkingOrbTransitionMath.smoothstep(
                (time - departureStartedAt) / Self.entranceDuration
            ) : 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let rect = NSRect(x: 0, y: 3, width: bounds.width, height: 17)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .paragraphStyle: paragraph,
            .kern: 0.12,
        ]
        if !previousLabel.isEmpty, previousLabel != state.label, progress < 1 {
            var outgoing = attributes
            outgoing[.foregroundColor] = NSColor.secondaryLabelColor
                .withAlphaComponent(CGFloat(max(0, 1 - progress * 1.3) * departureOpacity))
            (previousLabel as NSString).draw(in: rect.offsetBy(dx: 0, dy: CGFloat(progress)),
                                             withAttributes: outgoing)
        }
        var incoming = attributes
        incoming[.foregroundColor] = NSColor.secondaryLabelColor
            .withAlphaComponent(CGFloat(min(1, progress * 1.3) * departureOpacity))
        (state.label as NSString).draw(in: rect.offsetBy(dx: 0, dy: CGFloat(progress - 1)),
                                       withAttributes: incoming)
    }

    private func visibleLabel(at time: CFTimeInterval) -> String {
        guard !previousLabel.isEmpty, labelStartedAt > 0 else { return state.label }
        let progress = ThinkingOrbTransitionMath.smoothstep((time - labelStartedAt) / 0.22)
        return progress < 0.5 ? previousLabel : state.label
    }
}

private extension VoiceOrbSemanticState {
    var isModePreview: Bool {
        switch self {
        case .modeExternal, .modeFinal, .modeLive: return true
        default: return false
        }
    }

    var completionSymbol: Bool? {
        switch self {
        case .inserted, .replaced: return true
        case .error: return false
        default: return nil
        }
    }

    var renderFamily: String {
        if isModePreview { return "mode-symbol" }
        if self == .copied { return "copy" }
        if let completionSymbol { return completionSymbol ? "success" : "failure" }
        return orbState.rawValue
    }

    var orbState: ThinkingOrbState {
        switch self {
        case .listening, .selectionListening, .modeLive: return .listening
        case .transcribing: return .working
        case .polishing: return .solving
        case .rewriting: return .weaving
        case .inserting: return .shaping
        case .inserted, .replaced: return .breathing
        case .copied: return .breathing
        case .modeExternal: return .searching
        case .modeFinal: return .composing
        case .error: return .working
        }
    }
}
