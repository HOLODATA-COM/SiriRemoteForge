//
//  CursorHighlighter.swift
//  HyperVibe
//
//  "Find my cursor" highlight. macOS's native shake-to-locate only reacts to real HID cursor
//  motion, not our synthesized CGEvent moves, so we draw our own: a borderless click-through
//  overlay window that follows the pointer and paints a bright ring + radar-ping ripples via
//  CoreAnimation. Triggered by TouchHandler's shake detector (onShake). All UI runs on main.
//

import AppKit
import CoreGraphics
import QuartzCore

final class CursorHighlighter {

    // MARK: - Tunables (defaults chosen for high visibility)

    /// Bright highlight color. Default warm amber (#FFCC00) — pops on light and dark backgrounds.
    var color: CGColor = CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) {
        didSet { view?.update(color: color, ringDiameter: nil) }
    }
    /// Diameter (pt) of the bright ring hugging the cursor.
    var ringDiameter: CGFloat = 64 {
        didSet { view?.update(color: nil, ringDiameter: ringDiameter) }
    }
    /// How long the highlight stays visible after the last `flash()` before it fades out.
    /// Each `flash()` resets this, so continued shaking keeps it on screen.
    var duration: TimeInterval = 1.2

    /// Overlay window edge length (pt). Must comfortably contain the largest ripple.
    private let windowSize: CGFloat = 220
    /// Fade-out duration when auto-hiding.
    private let fadeDuration: CFTimeInterval = 0.28

    // MARK: - State

    private var window: NSWindow?
    private var view: HighlightView?
    private var followTimer: Timer?
    private var hideTimer: Timer?
    /// A fixed screen anchor (bottom-left origin). When nil, the window follows the live cursor.
    private var anchor: CGPoint?
    /// True once ordered in and not yet fully hidden.
    private var isShowing = false
    /// Bumped on every `flash()`/hide so a stale fade-completion can't hide a re-shown highlight.
    private var fadeToken = 0

    init() {}

    // MARK: - Public API

    /// Show / refresh the highlight following the live cursor. Call repeatedly to keep it up.
    func flash() {
        onMain { [weak self] in
            self?.anchor = nil
            self?.show()
        }
    }

    /// Show the highlight pinned at a fixed screen point (bottom-left origin), without following
    /// the cursor. Used by `--test-highlight` for headless visual QC.
    func flash(at point: CGPoint) {
        onMain { [weak self] in
            self?.anchor = point
            self?.show()
        }
    }

    // MARK: - Show / hide

    private func show() {
        ensureWindow()
        // Cancel any in-flight fade so a re-show is instant and fully opaque.
        fadeToken += 1
        view?.layer?.removeAnimation(forKey: "fade")
        view?.layer?.opacity = 1

        if !isShowing {
            isShowing = true
            view?.startRipples()
            positionWindow()
            window?.orderFrontRegardless()
            startFollowTimer()
        }
        resetHideTimer()
    }

    private func beginHide() {
        guard isShowing, let layer = view?.layer else { return }
        fadeToken += 1
        let token = fadeToken
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = fadeDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.finishHide()
        }
        layer.add(anim, forKey: "fade")
        CATransaction.commit()
    }

    private func finishHide() {
        isShowing = false
        stopFollowTimer()
        view?.stopRipples()
        window?.orderOut(nil)
        view?.layer?.removeAnimation(forKey: "fade")
        view?.layer?.opacity = 1
    }

    // MARK: - Timers

    private func resetHideTimer() {
        hideTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.beginHide()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func startFollowTimer() {
        guard followTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.positionWindow()
        }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func stopFollowTimer() {
        followTimer?.invalidate()
        followTimer = nil
    }

    // MARK: - Window

    private func positionWindow() {
        guard let window = window else { return }
        // NSEvent.mouseLocation is bottom-left-origin global coordinates — the same space as
        // NSWindow.setFrameOrigin, so no flip is needed.
        let p = anchor ?? NSEvent.mouseLocation
        let half = windowSize / 2
        window.setFrameOrigin(NSPoint(x: p.x - half, y: p.y - half))
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let size = NSSize(width: windowSize, height: windowSize)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true          // click-through
        win.level = .screenSaver                // float above ordinary windows
        win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary, .ignoresCycle]
        let v = HighlightView(frame: NSRect(origin: .zero, size: size),
                              color: color, ringDiameter: ringDiameter)
        win.contentView = v
        window = win
        view = v
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Content view (CoreAnimation)

/// Draws the highlight centered in the window: a soft radial glow, a bright ring with a subtle
/// dark outline for contrast, and two staggered radar-ping ripples. Layer-backed; geometry is
/// rebuilt on layout so it stays centered.
private final class HighlightView: NSView {

    private var color: CGColor
    private var ringDiameter: CGFloat

    private let glowLayer = CAGradientLayer()
    private let outlineLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let ripple1 = CAShapeLayer()
    private let ripple2 = CAShapeLayer()

    private let ripplePeriod: CFTimeInterval = 0.9

    init(frame: NSRect, color: CGColor, ringDiameter: CGFloat) {
        self.color = color
        self.ringDiameter = ringDiameter
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        applyColors()
        rebuildGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        rebuildGeometry()
    }

    // MARK: Build

    private func buildLayers() {
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        glowLayer.locations = [0.0, 1.0]

        for r in [ripple1, ripple2] {
            r.fillColor = NSColor.clear.cgColor
            r.lineWidth = 3
            r.opacity = 0                       // hidden until animated
        }
        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineWidth = 7
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 4
        ringLayer.shadowRadius = 6
        ringLayer.shadowOpacity = 0.9
        ringLayer.shadowOffset = .zero

        // Back-to-front: glow, ripples, dark outline, bright ring.
        [glowLayer, ripple1, ripple2, outlineLayer, ringLayer].forEach { layer?.addSublayer($0) }
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clear = color.copy(alpha: 0.0) ?? color
        let glowInner = color.copy(alpha: 0.55) ?? color
        glowLayer.colors = [glowInner, clear]
        ripple1.strokeColor = color
        ripple2.strokeColor = color
        ringLayer.strokeColor = color
        ringLayer.shadowColor = color
        // Subtle dark outline so the bright ring reads on light backgrounds.
        outlineLayer.strokeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.4)
        CATransaction.commit()
    }

    private func rebuildGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ringRadius = ringDiameter / 2
        let rippleRadius = ringRadius + 2
        ringLayer.path = circlePath(radius: ringRadius)
        outlineLayer.path = circlePath(radius: ringRadius)
        for (r, radius) in [(ripple1, rippleRadius), (ripple2, rippleRadius)] {
            r.frame = bounds
            r.path = circlePath(radius: radius)
        }
        let glowSide = ringDiameter * 2.4
        glowLayer.frame = CGRect(x: bounds.midX - glowSide / 2,
                                 y: bounds.midY - glowSide / 2,
                                 width: glowSide, height: glowSide)
        CATransaction.commit()
    }

    private func circlePath(radius: CGFloat) -> CGPath {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                        width: radius * 2, height: radius * 2), transform: nil)
    }

    // MARK: Animation

    func startRipples() {
        addRipple(to: ripple1, phase: 0.0)
        addRipple(to: ripple2, phase: 0.5)
    }

    func stopRipples() {
        ripple1.removeAnimation(forKey: "ripple")
        ripple2.removeAnimation(forKey: "ripple")
    }

    private func addRipple(to layer: CAShapeLayer, phase: Double) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = ripplePeriod
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.timeOffset = ripplePeriod * phase   // stagger the two pings by half a period
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "ripple")
    }

    // MARK: Tunable updates

    func update(color newColor: CGColor?, ringDiameter newDiameter: CGFloat?) {
        if let newColor = newColor { color = newColor }
        if let newDiameter = newDiameter { ringDiameter = newDiameter }
        applyColors()
        rebuildGeometry()
    }
}
