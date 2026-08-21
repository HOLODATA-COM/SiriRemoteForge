//
//  HoldProgressHUD.swift
//  HyperVibe
//
//  Makes release-to-select visible. Multi-stage long-press fires whichever stage you were in when
//  you let go, which is impossible to use without either memorising the thresholds or guessing.
//
//  Presentation: a square vessel that fills like poured water, ONE STAGE AT A TIME. The water level
//  is the time WITHIN the current stage — with stages at 1 s / 2 s / 3 s the vessel fills over the
//  first second, then flushes empty and swaps its centre icon, then fills again, and so on. The
//  final stage (usually cancel) is different: it does NOT empty, it fills to the brim and sloshes —
//  an overflow that reads as "let go now and nothing happens." The centre icon is always the action
//  a release would run right now. No text.
//
//  Surface: a SUM OF TRAVELLING SINE WAVES (the clean, good-looking moving-water surface), made
//  organic rather than mechanical by using several non-harmonic frequencies going different ways so
//  crests form and dissolve by interference, by a slow "breathing" of each wave's amplitude, by a
//  small random phase jitter, and by random per-show phases — so it reads as real, ever-changing
//  water without the instability or the single-giant-slosh of a physics sim. Events (pour, stage
//  cross, flush, overflow) briefly swell the whole surface.
//
//  Rendering: the water is a CAMetalLayer and a fragment shader — every pixel decides for itself
//  whether it sits below the summed sine surface (water, with the vertical gradient), on it (the
//  antialiased crest line), or above it (clear). The CPU's entire per-frame job is a dozen floats
//  of wave-state bookkeeping and a 112-byte uniform upload behind one 3-vertex draw: no path
//  building, no layer mutation, no heap allocation. A CADisplayLink drives it in lockstep with the
//  display — asking for the FULL panel rate, so a ProMotion display gets true 120 Hz water — and
//  exists only while the HUD is on screen: the app schedules nothing while idle, which is almost
//  always. All easing/decay constants are applied through dt, so the motion design is identical at
//  60 and 120 Hz; the higher rate only adds smoothness. The shader ships as MSL source compiled
//  once on first show, so the build stays a plain swiftc invocation.
//

import AppKit
import QuartzCore
import Metal
import CoreVideo

final class HoldProgressHUD: NSObject {

    /// How one choice presents itself. Only `image` and `isCancel` are drawn now (no text); `label`
    /// and `iconOnly` are kept so the producers that build faces (ActionVisual) need no change.
    struct Face {
        let label: String
        let image: NSImage?          // real app icon where one exists, else an SF Symbol
        let iconOnly: Bool
        var isCancel: Bool = false   // the escape hatch: grey water + overflow instead of emptying
    }

    struct Stage {
        let threshold: TimeInterval
        let face: Face
    }

    // Square vessel. `pad` is transparent room around it for the soft shadow.
    private let side: CGFloat = 140
    private let pad: CGFloat = 40
    private let corner: CGFloat = 34
    private let iconSide: CGFloat = 62
    private var winSide: CGFloat { side + pad * 2 }

    // MARK: Surface = sum of travelling sine waves
    // The STATE lives here — advancing it is a dozen floats a frame, and keeping it on the CPU
    // preserves the random phase jitter, which is a true random walk no pure function of time can
    // express. The EVALUATION (summing the sines at every x) happens per pixel in the shader.
    private struct Wave {
        var freq: CGFloat        // crests across the width
        var amp: CGFloat         // height in points
        var speed: CGFloat       // phase advance, rad/s (sign = travel direction)
        var phase: CGFloat       // current phase (advances + jitters)
        var driftPhase: CGFloat  // slow amplitude "breathing" phase
        var driftSpeed: CGFloat  // rad/s of that breathing
    }
    private var waves: [Wave] = []
    private var envelope: CGFloat = 1        // overall amplitude ×; event swells decay back to 1
    private var lastTick: CFTimeInterval = 0

    // MARK: GPU water

    /// Everything visual about the water in ~20 lines of MSL. `uv` is 0…1 across the card with y
    /// up from the bottom, so the maths reads exactly like the old CPU sampler did.
    private static let waterShader = """
    #include <metal_stdlib>
    using namespace metal;

    struct WaterVaryings {
        float4 position [[position]];
        float2 uv;                       // 0…1 across the card, y up from the bottom
    };

    // One triangle that covers the whole layer; uv interpolates to 0…1 over the visible square.
    vertex WaterVaryings water_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
        WaterVaryings out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = p * 0.5 + 0.5;
        return out;
    }

    struct WaterUniforms {
        float4 freq;      // crests across the width, one lane per wave
        float4 phase;     // current phase (the CPU advances it, jitter and all)
        float4 amp;       // effective amplitude: base × breathing × event envelope × near-empty calm
        float4 top;       // water gradient at the card's top, straight (non-premultiplied) sRGB
        float4 bot;       // water gradient at the card's bottom
        float4 crest;     // crest line colour
        float4 misc;      // x: water level in points  y: card side  z: crest opacity  w: ½-px AA width
    };

    fragment float4 water_fragment(WaterVaryings in [[stage_in]],
                                   constant WaterUniforms &u [[buffer(0)]]) {
        float side = u.misc.y;
        float2 p = in.uv * side;

        // The summed surface, clamped into the vessel like the old sampler clamped each column,
        // plus its analytic slope so the crest keeps constant thickness on steep stretches.
        float4 ph = u.freq * (2.0 * M_PI_F * in.uv.x) + u.phase;
        float surface = clamp(u.misc.x + dot(u.amp, sin(ph)), 0.0, side);
        float slope = dot(u.amp * u.freq, cos(ph)) * (2.0 * M_PI_F / side);

        // Signed distance to the surface (positive above water), antialiased over one pixel.
        float d = (p.y - surface) * rsqrt(1.0 + slope * slope);
        float aa = u.misc.w;
        float body = 1.0 - smoothstep(-aa, aa, d);
        float line = (1.0 - smoothstep(0.75 - aa, 0.75 + aa, abs(d))) * u.misc.z;

        // Water gradient over the card height, crest composited on top; premultiplied out.
        float4 wcol = mix(u.bot, u.top, in.uv.y);
        float4 water = float4(wcol.rgb, 1.0) * (wcol.a * body);
        float4 crest = float4(u.crest.rgb, 1.0) * (u.crest.a * line);
        return crest + water * (1.0 - crest.a);
    }
    """

    /// Swift mirror of `WaterUniforms` — seven float4s, 16-byte lanes, no padding surprises.
    private struct Uniforms {
        var freq: SIMD4<Float>
        var phase: SIMD4<Float>
        var amp: SIMD4<Float>
        var top: SIMD4<Float>
        var bot: SIMD4<Float>
        var crest: SIMD4<Float>
        var misc: SIMD4<Float>
    }

    /// The shader/pipeline are shared; each physical display owns its own drawable layer and
    /// window. Compiling once keeps adding a second or third screen cheap.
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var rendererAttempted = false
    private let passDescriptor: MTLRenderPassDescriptor = {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear     // belt & braces; the triangle covers all
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return pass
    }()

    /// `.canJoinAllSpaces` does not mirror one window onto every display. Each Surface is one
    /// synchronized copy of the HUD on one physical screen.
    private final class Surface {
        let window: NSWindow
        let iconView: NSImageView
        let metalLayer: CAMetalLayer?
        let flatFill: CALayer?
        var halfPixel: Float = 0.25          // ½ device pixel in points; shader AA width

        init(window: NSWindow, iconView: NSImageView,
             metalLayer: CAMetalLayer?, flatFill: CALayer?) {
            self.window = window
            self.iconView = iconView
            self.metalLayer = metalLayer
            self.flatFill = flatFill
        }
    }
    private var surfaces: [CGDirectDisplayID: Surface] = [:]

    // Water colours as uniform values; `setWaterColor` swaps them for the cancel greys.
    private var topColor = SIMD4<Float>(0, 0, 0, 0)
    private var botColor = SIMD4<Float>(0, 0, 0, 0)
    private var crestColor = SIMD4<Float>(1, 1, 1, 0.6)

    // The display link only lives while the HUD is visible. CADisplayLink is macOS 14+, and the
    // deployment floor is 13, so it is stored untyped with a CVDisplayLink understudy beside it.
    private var caLink: AnyObject?
    private var cvLink: CVDisplayLink?

    private var stages: [Stage] = []
    private var base: Face?
    private var startTime: CFTimeInterval = 0
    private var appearWork: DispatchWorkItem?
    private var isShowing = false
    private var shownStage = -1

    private var displayLevel: CGFloat = 0    // 0…1 fill fraction; eases toward its target
    private var draining = false             // between-stage clear: a fast accelerating drop (flush)
    private var drainStart: CFTimeInterval = 0
    private var drainFrom: CGFloat = 0
    private let drainDur: CFTimeInterval = 0.16
    private var confirming = false           // on release: freeze the choice, fill to the brim, fade
    private var fadeToken = 0
    private let ease: CGFloat = 0.28
    /// Visual lead-in only. The input state machine still owns the real hold thresholds (for
    /// example Select starts sticky drag at 0.5 s). Showing the vessel at 0.18 s leaves enough
    /// visible runway to watch its water rise toward that boundary; releasing before a real stage
    /// still resolves as the ordinary tap, and releasing before this delay shows no HUD at all.
    private let appearDelay: TimeInterval = 0.18

    // MARK: - Public API

    /// Compile the Metal pipeline and create the hidden per-display surfaces before the first
    /// physical hold. Lazy setup inside `reveal()` can cost several frames (or much more on a cold
    /// shader cache), turning a nominal 0.18 s lead-in into visibly late feedback. Prewarming never
    /// orders a window and never starts a display link; it only moves that one-time work to startup.
    func prewarm() {
        onMain { [weak self] in self?.syncSurfaces() }
    }

    func begin(startedAt: CFTimeInterval = CACurrentMediaTime(), base: Face?, stages: [Stage]) {
        // Preserve the caller's display order for equal thresholds. Swift's `sorted` is not stable,
        // and reordering a tie here would make the displayed face disagree with the input handler's
        // zero-based stage position on release.
        let sorted = stages.enumerated().sorted {
            $0.element.threshold == $1.element.threshold
                ? $0.offset < $1.offset
                : $0.element.threshold < $1.element.threshold
        }.map(\.element)
        guard !sorted.isEmpty else { return }
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingAppear()
            self.base = base
            self.stages = sorted
            // The input state machine supplies its monotonic press anchor. Sharing it is what makes
            // the face shown here and the action selected on release cross thresholds together.
            self.startTime = startedAt
            self.lastTick = self.startTime
            self.shownStage = -1
            self.displayLevel = 0
            self.draining = false
            self.confirming = false
            self.envelope = 1.5                              // enters a touch livelier, as if just poured
            self.makeWaves()

            // The water HUD intentionally begins BEFORE the first action boundary. It is only a
            // progress preview: stage/face selection below still compares the caller's immutable
            // `startedAt` against the real configured thresholds. `end` cancels this work item, so
            // an ordinary quick tap under 0.18 s never flashes the vessel.
            let revealDelay = max(0, startedAt + self.appearDelay - CACurrentMediaTime())
            let work = DispatchWorkItem { [weak self] in self?.reveal() }
            self.appearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: work)
        }
    }

    /// `firedIndex` is a 1-BASED POSITION IN THE LIST PASSED TO `begin`, not the binding's stage
    /// number (earlier unbound stages make the two differ — see git history).
    func end(firedIndex: Int) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingAppear()
            guard self.isShowing else { self.stopTicking(); return }
            if firedIndex >= 1, firedIndex <= self.stages.count {
                let face = self.stages[firedIndex - 1].face
                self.confirming = true
                for surface in self.surfaces.values { surface.iconView.image = face.image }
                self.setWaterColor(cancel: face.isCancel)
                self.envelope = max(self.envelope, 2.2)      // a swell as the choice locks in
                self.popIcon(from: 0.86)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.stopTicking(); self?.beginHide()
                }
            } else {
                self.stopTicking()
                self.beginHide()
            }
        }
    }

    /// Remove the HUD synchronously from the next main-loop turn when its JSON switch is disabled.
    /// Unlike `end`, this is a preference change, not a gesture result, so it must not play the
    /// confirmation fill or leave a fading surface visible after the user asked to hide it.
    func hideImmediately() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingAppear()
            self.stopTicking()
            self.fadeToken += 1
            self.isShowing = false
            self.confirming = false
            for surface in self.surfaces.values {
                surface.window.alphaValue = 0
                surface.window.orderOut(nil)
            }
        }
    }

    // MARK: - Show / tick / hide

    private func reveal() {
        appearWork = nil
        syncSurfaces()
        guard !surfaces.isEmpty else { return }

        fadeToken += 1
        let wasShowing = isShowing
        isShowing = true
        // Always order every mirror, even while our logical state says "showing". A Space change
        // can remove a cached NSWindow from the visible list without changing that boolean.
        for surface in surfaces.values {
            if !wasShowing { surface.window.alphaValue = 0 }
            surface.window.orderFrontRegardless()
        }
        // A CAMetalLayer is not guaranteed to vend a drawable while its window is ordered out.
        // Put every mirror on screen (still transparent on first appearance) before the first
        // render, so no display begins with a blank vessel and waits for the second vsync.
        render(elapsed: CACurrentMediaTime() - startTime, force: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = wasShowing ? 0.12 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for surface in surfaces.values {
                surface.window.animator().alphaValue = 1
            }
        }
        startTicking()
    }

    /// One callback per display refresh, only while visible. CADisplayLink (14+) follows the
    /// window's display and fires on the main runloop; on the macOS 13 floor a CVDisplayLink hops
    /// its high-priority thread callback over to main. Either way `stopTicking` tears it down the
    /// moment the HUD is done, so an idle HUD costs nothing at all.
    private func startTicking() {
        stopTicking()
        lastTick = CACurrentMediaTime()
        if #available(macOS 14.0, *), let view = surfaces.values.first?.window.contentView {
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            // Ask for the panel's full rate: ProMotion displays schedule true 120 Hz callbacks
            // instead of the power-saving default; fixed-rate panels just give their native rate.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            caLink = link
        } else {
            var ref: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&ref)
            guard let link = ref else { return }
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                DispatchQueue.main.async { self?.tick() }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            cvLink = link
        }
    }

    private func stopTicking() {
        if #available(macOS 14.0, *), let link = caLink as? CADisplayLink { link.invalidate() }
        caLink = nil
        if let link = cvLink { CVDisplayLinkStop(link) }
        cvLink = nil
    }

    @objc private func step(_ sender: Any) { tick() }

    private func tick() {
        guard caLink != nil || cvLink != nil else { return }   // a stale hop after stopTicking
        render(elapsed: CACurrentMediaTime() - startTime, force: false)
    }

    private func cancelPendingAppear() {
        appearWork?.cancel()
        appearWork = nil
    }

    private func beginHide() {
        guard isShowing else { return }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for surface in surfaces.values {
                surface.window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.isShowing = false
            for surface in self.surfaces.values { surface.window.orderOut(nil) }
        })
    }

    // MARK: - Surface waves

    /// Four non-harmonic components going different directions, with random per-show phases so no two
    /// holds look the same. Amplitudes fall off with frequency (big slow swell + fine fast ripples).
    /// With Reduce Motion on, the amplitudes are zero: the surface is a level line and only the
    /// fill/drain motion remains — which IS the information, so it stays.
    private func makeWaves() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let specs: [(freq: CGFloat, amp: CGFloat, speed: CGFloat)] = [
            (1.3, 3.0,  0.9),
            (2.1, 2.0, -1.3),
            (3.4, 1.3,  1.7),
            (4.8, 0.8, -2.1),
        ]
        waves = specs.map {
            Wave(freq: $0.freq, amp: still ? 0 : $0.amp, speed: $0.speed,
                 phase: CGFloat.random(in: 0..<(2 * .pi)),
                 driftPhase: CGFloat.random(in: 0..<(2 * .pi)),
                 driftSpeed: CGFloat.random(in: 0.15...0.45))
        }
    }

    /// Advance phases (with a little random jitter so it never becomes perfectly periodic), breathe
    /// the amplitudes, and relax the event swell back toward the idle 1. The jitter and the decay
    /// are scaled through dt so the water behaves identically at 60 and 120 Hz.
    private func advanceWaves(dt: CGFloat) {
        for i in waves.indices {
            waves[i].phase += waves[i].speed * dt + CGFloat.random(in: -0.02...0.02) * dt * 60
            waves[i].driftPhase += waves[i].driftSpeed * dt
        }
        envelope = 1 + (envelope - 1) * pow(0.94, dt * 60)
    }

    // MARK: - Rendering

    private func render(elapsed: TimeInterval, force: Bool) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastTick, 0), 0.05))
        lastTick = now
        advanceWaves(dt: dt)
        // `ease` was tuned as a per-frame factor at 60 fps; this is the same exponential approach
        // expressed through dt, so the fill feels identical at 120 Hz — just twice as smooth.
        let step = 1 - pow(1 - ease, dt * 60)

        if confirming {
            displayLevel += (1 - displayLevel) * step
            displayLevel = min(max(displayLevel, 0), 1)
            pushFrame()
            return
        }

        // Which stage would fire if released right now? = thresholds crossed.
        var stage = 0
        for (i, s) in stages.enumerated() where elapsed >= s.threshold { stage = i + 1 }

        if stage != shownStage || force {
            let crossedForward = stage > shownStage && shownStage >= 0
            shownStage = stage
            let face: Face? = stage == 0 ? base : stages[stage - 1].face
            for surface in surfaces.values { surface.iconView.image = face?.image }
            setWaterColor(cancel: face?.isCancel ?? false)
            if crossedForward {
                popIcon(from: 0.82)
                if stage < stages.count {
                    draining = true; drainStart = now; drainFrom = displayLevel
                    envelope = max(envelope, 2.6)          // the flush swells the surface as it drops
                } else {
                    envelope = max(envelope, 3.4); popIcon(from: 0.64)   // overflow: brimful, big swell
                }
            }
        }

        // The flush: level follows an ease-IN drop (accelerating out) and ignores the fill target.
        if draining {
            let dp = CGFloat((now - drainStart) / drainDur)
            if dp < 1 {
                displayLevel = drainFrom * (1 - dp * dp)
                pushFrame()
                return
            }
            draining = false
            displayLevel = 0
            envelope = max(envelope, 2.0)                  // splash as it hits the bottom
        }

        // Normal fill toward the CURRENT stage's window (progress within it, not cumulative).
        let target: CGFloat
        if stage >= stages.count {
            target = 1
        } else {
            let segStart = stage == 0 ? 0 : stages[stage - 1].threshold
            let segEnd = stages[stage].threshold
            let frac = (elapsed - segStart) / max(segEnd - segStart, 0.0001)
            target = CGFloat(min(max(frac, 0), 1))
        }
        displayLevel += (target - displayLevel) * step
        displayLevel = min(max(displayLevel, 0), 1)
        pushFrame()
    }

    /// The per-frame CPU cost, in full: pack ~28 floats of uniforms, encode one 3-vertex draw.
    /// No paths, no CATransaction, no heap allocation (command buffers come from Metal's pool) —
    /// the sine sum, the fill mask, the gradient and the antialiased crest are all per-pixel work
    /// in `waterShader`. The wave fades out as the vessel nears empty so it settles cleanly.
    private func pushFrame() {
        let calm = min(displayLevel / 0.05, 1)
        var freq = SIMD4<Float>(repeating: 0)
        var phase = SIMD4<Float>(repeating: 0)
        var amp = SIMD4<Float>(repeating: 0)
        for i in 0..<min(waves.count, 4) {
            let w = waves[i]
            freq[i] = Float(w.freq)
            phase[i] = Float(w.phase.truncatingRemainder(dividingBy: 2 * .pi))
            amp[i] = Float(w.amp * (1 + 0.35 * sin(w.driftPhase)) * envelope * calm)
        }
        // Keep any no-GPU surfaces functional. In normal use either every surface is Metal-backed
        // or every surface is flat, but updating both makes display hot-plug reconciliation safe.
        if surfaces.values.contains(where: { $0.flatFill != nil }) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for surface in surfaces.values {
                surface.flatFill?.frame = CGRect(x: 0, y: 0,
                                                 width: side, height: side * displayLevel)
            }
            CATransaction.commit()
        }

        guard let queue = commandQueue, let pipeline = pipeline,
              let commands = queue.makeCommandBuffer() else { return }
        var encodedAny = false
        for surface in surfaces.values {
            guard let layer = surface.metalLayer, let drawable = layer.nextDrawable() else { continue }
            var u = Uniforms(freq: freq, phase: phase, amp: amp,
                             top: topColor, bot: botColor, crest: crestColor,
                             misc: SIMD4<Float>(Float(side * displayLevel), Float(side),
                                                displayLevel > 0.02 ? 1 : 0,
                                                surface.halfPixel))
            passDescriptor.colorAttachments[0].texture = drawable.texture
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                continue
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commands.present(drawable)
            encodedAny = true
        }
        if encodedAny { commands.commit() }
    }

    private func setWaterColor(cancel: Bool) {
        if cancel {
            topColor = rgba(NSColor(calibratedWhite: 0.55, alpha: 0.78))
            botColor = rgba(NSColor(calibratedWhite: 0.45, alpha: 0.93))
        } else {
            topColor = rgba(NSColor.controlAccentColor.withAlphaComponent(0.80))
            botColor = rgba(NSColor.controlAccentColor.withAlphaComponent(0.97))
        }
        crestColor = SIMD4<Float>(1, 1, 1, cancel ? 0.35 : 0.6)
        let flats = surfaces.values.compactMap(\.flatFill)
        if !flats.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = cancel ? NSColor(calibratedWhite: 0.45, alpha: 0.93).cgColor
                               : NSColor.controlAccentColor.withAlphaComponent(0.97).cgColor
            for flat in flats { flat.backgroundColor = color }
            CATransaction.commit()
        }
    }

    /// A colour as straight (non-premultiplied) sRGB components, ready for the uniform buffer.
    private func rgba(_ color: NSColor) -> SIMD4<Float> {
        guard let c = color.usingColorSpace(.sRGB) else { return SIMD4<Float>(0.5, 0.5, 0.5, 1) }
        return SIMD4<Float>(Float(c.redComponent), Float(c.greenComponent),
                            Float(c.blueComponent), Float(c.alphaComponent))
    }

    private func popIcon(from: CGFloat) {
        for surface in surfaces.values {
            guard let layer = surface.iconView.layer else { continue }
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [from, 1.08, 1.0]
            a.keyTimes = [0, 0.7, 1]
            a.duration = 0.28
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "pop")
        }
    }

    // MARK: - Layout

    /// Reconcile one mirrored surface per display before every appearance. `NSScreen` objects and
    /// coordinates can change after hot-plug or rearrangement, so positions are refreshed even for
    /// surfaces that already exist.
    private func syncSurfaces() {
        prepareRenderer()
        let screens = NSScreen.screens
        let activeIDs = Set(screens.map(\.hudDisplayID))
        for id in Array(surfaces.keys) where !activeIDs.contains(id) {
            surfaces.removeValue(forKey: id)?.window.orderOut(nil)
        }
        for screen in screens {
            let id = screen.hudDisplayID
            let surface: Surface
            if let existing = surfaces[id] {
                surface = existing
            } else {
                surface = makeSurface()
                surfaces[id] = surface
            }
            position(surface.window, on: screen)
            updateDrawableScale(for: surface, on: screen)
        }
    }

    private func position(_ window: NSWindow, on screen: NSScreen) {
        let vf = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: vf.midX - winSide / 2,
                                      y: vf.minY + vf.height * 0.18 - pad))
    }

    /// Match each drawable to its own display. Mixed Retina/non-Retina setups therefore keep the
    /// same physical card size and a crisp one-device-pixel water edge on every screen.
    private func updateDrawableScale(for surface: Surface, on screen: NSScreen) {
        guard let layer = surface.metalLayer else { return }
        let scale = max(screen.backingScaleFactor, 1)
        let size = CGSize(width: side * scale, height: side * scale)
        guard layer.drawableSize != size else { return }
        layer.contentsScale = scale
        layer.drawableSize = size
        surface.halfPixel = Float(0.5 / scale)
    }

    /// Compile the shader once. Every display's CAMetalLayer uses this same device, queue and
    /// pipeline; only its drawable and backing scale differ.
    private func prepareRenderer() {
        guard !rendererAttempted else { return }
        rendererAttempted = true
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: Self.waterShader, options: nil),
              let vertexFn = library.makeFunction(name: "water_vertex"),
              let fragmentFn = library.makeFunction(name: "water_fragment"),
              let queue = device.makeCommandQueue() else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return }
        metalDevice = device
        commandQueue = queue
        pipeline = state
    }

    private func makeSurface() -> Surface {
        let winRect = NSRect(x: 0, y: 0, width: winSide, height: winSide)
        let cardRect = NSRect(x: pad, y: pad, width: side, height: side)

        let win = NSWindow(contentRect: winRect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView(frame: winRect)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.24
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -7)
        container.layer?.shadowPath = CGPath(roundedRect: cardRect, cornerWidth: corner,
                                             cornerHeight: corner, transform: nil)

        let card = NSView(frame: cardRect)
        card.wantsLayer = true
        card.layer?.cornerRadius = corner
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        let glass = CAGradientLayer()
        glass.frame = card.bounds
        glass.startPoint = CGPoint(x: 0.5, y: 1)
        glass.endPoint = CGPoint(x: 0.5, y: 0)
        glass.colors = [NSColor(calibratedWhite: 0.20, alpha: 0.98).cgColor,
                        NSColor(calibratedWhite: 0.13, alpha: 0.98).cgColor]
        card.layer?.addSublayer(glass)

        // The water: one drawable layer per screen, all driven by the shared timeline and shader.
        var water: CAMetalLayer?
        var flat: CALayer?
        if let device = metalDevice, pipeline != nil, commandQueue != nil {
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.isOpaque = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.frame = card.bounds
            card.layer?.addSublayer(layer)
            water = layer
        }
        if water == nil {
            // No Metal device (a stripped-down VM, in practice): a flat accent fill keeps the HUD
            // functional — level, drain, overflow and colours all still read; only the waves go.
            let layer = CALayer()
            card.layer?.addSublayer(layer)
            flat = layer
        }

        let rim = CALayer()
        rim.frame = card.bounds
        rim.cornerRadius = corner
        rim.cornerCurve = .continuous
        rim.borderWidth = 0.5
        rim.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        card.layer?.addSublayer(rim)

        let icon = NSImageView(frame: NSRect(x: (side - iconSide) / 2, y: (side - iconSide) / 2,
                                             width: iconSide, height: iconSide))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        icon.wantsLayer = true
        icon.layer?.shadowColor = NSColor.black.cgColor
        icon.layer?.shadowOpacity = 0.28
        icon.layer?.shadowRadius = 4
        icon.layer?.shadowOffset = CGSize(width: 0, height: -1)
        card.addSubview(icon)

        container.addSubview(card)
        win.contentView = container
        return Surface(window: win, iconView: icon, metalLayer: water, flatFill: flat)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
