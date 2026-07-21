//
//  HoldProgressHUD.swift
//  HyperVibe
//
//  Makes release-to-select visible. Multi-stage long-press fires whichever stage you were in when
//  you let go, which is impossible to use without either memorising the thresholds or guessing. So
//  while a button with hold bindings is held, this shows a track that fills, ticks for each bound
//  stage, and the name of the action that will run if you release right now.
//
//  Same card treatment as LayerHUD (continuous-corner squircle, gradient, masked shadow), but
//  landscape, because it has to carry a track and a label.
//

import AppKit
import QuartzCore

final class HoldProgressHUD {

    /// How one choice presents itself on the card.
    struct Face {
        let label: String
        /// The real app icon where one exists, otherwise an SF Symbol — see ActionVisual.
        let image: NSImage?
        /// Show the image alone, without the label — see ActionVisual.Visual.iconOnly.
        let iconOnly: Bool
    }

    struct Stage {
        let threshold: TimeInterval
        let face: Face
    }

    // Card geometry. `pad` is transparent room around the card for the soft shadow.
    private let cardW: CGFloat = 330
    private let cardH: CGFloat = 118
    private let pad: CGFloat = 40
    private let corner: CGFloat = 24
    private var winW: CGFloat { cardW + pad * 2 }
    private var winH: CGFloat { cardH + pad * 2 }

    private var window: NSWindow?
    private var gradient: CAGradientLayer?
    private var titleLabel: NSTextField?
    private var iconView: NSImageView?
    private var hintLabel: NSTextField?
    private var trackLayer: CALayer?
    private var fillLayer: CAGradientLayer?
    private var tickLayers: [CAShapeLayer] = []

    private var stages: [Stage] = []
    private var base: Face?
    private var startTime: CFTimeInterval = 0
    private var tickTimer: Timer?
    private var appearWork: DispatchWorkItem?
    private var isShowing = false
    private var shownStage = -1
    private var fadeToken = 0

    /// Held presses shorter than this never show anything — otherwise every ordinary tap flashes a
    /// card on screen.
    private let appearDelay: TimeInterval = 0.18

    init() {}

    // MARK: - Public API

    /// A button with at least one bound hold stage went down. `base` is what a release BEFORE the
    /// first threshold would run — the button's ordinary tap. Releasing early is a real choice, not
    /// a cancel, so the card names it like any other stage rather than showing a blank.
    func begin(base: Face?, stages: [Stage]) {
        let sorted = stages.sorted { $0.threshold < $1.threshold }
        guard !sorted.isEmpty else { return }
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingAppear()
            self.base = base
            self.stages = sorted
            self.startTime = CACurrentMediaTime()
            self.shownStage = -1

            let work = DispatchWorkItem { [weak self] in self?.reveal() }
            self.appearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.appearDelay, execute: work)
        }
    }

    /// The button was released. `firedStage` is 1…3, or 0 if it was released before stage 1.
    func end(firedStage: Int) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingAppear()
            self.stopTicking()
            guard self.isShowing else { return }
            if firedStage >= 1, firedStage <= self.stages.count {
                // Confirm what was chosen: snap the track to that stage and flash the label, so the
                // selection registers even when the release is quick.
                self.render(elapsed: self.stages[firedStage - 1].threshold, force: true)
                self.hintLabel?.stringValue = "running"
                self.pulseTitle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in self?.beginHide() }
            } else {
                self.beginHide()
            }
        }
    }

    // MARK: - Show / tick / hide

    private func reveal() {
        appearWork = nil
        ensureWindow()
        applyAppearanceColors()
        layoutTicks()
        render(elapsed: CACurrentMediaTime() - startTime, force: true)
        positionWindow()

        fadeToken += 1
        if !isShowing {
            isShowing = true
            window?.alphaValue = 0
            window?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window?.animator().alphaValue = 1
            }
        }
        startTicking()
    }

    private func startTicking() {
        stopTicking()
        // 60 Hz: the fill is redrawn per tick rather than animated to a target, so it tracks the
        // real elapsed time exactly and cannot drift away from which stage will actually fire.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.render(elapsed: CACurrentMediaTime() - self.startTime, force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
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
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.isShowing = false
            self.window?.orderOut(nil)
        })
    }

    // MARK: - Rendering

    private var maxThreshold: TimeInterval { stages.last?.threshold ?? 1 }

    /// Track fills to the LAST stage's threshold, so the ticks are spread across the whole bar and
    /// the final stage sits at the very end — the bar being full means "deepest stage reached".
    private func render(elapsed: TimeInterval, force: Bool) {
        let progress = min(max(elapsed / maxThreshold, 0), 1)
        let inset: CGFloat = 22
        let trackW = cardW - inset * 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // we drive the value every frame; no implicit anim
        fillLayer?.frame = CGRect(x: 0, y: 0, width: trackW * CGFloat(progress), height: 6)
        CATransaction.commit()

        // Which stage would fire if released right now?
        var stage = 0
        for (i, s) in stages.enumerated() where elapsed >= s.threshold { stage = i + 1 }

        for (i, tick) in tickLayers.enumerated() {
            let reached = (i + 1) <= stage
            tick.fillColor = (reached ? NSColor.controlAccentColor
                                      : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).cgColor
        }

        guard stage != shownStage || force else { return }
        let crossedForward = stage > shownStage && shownStage >= 0
        shownStage = stage

        if stage == 0 {
            titleLabel?.stringValue = base?.label ?? "—"
            titleLabel?.textColor = base == nil ? .tertiaryLabelColor : .labelColor
            iconView?.image = base?.image
            hintLabel?.stringValue = base == nil ? "keep holding"
                                                : "release to run · keep holding for more"
            centreTitleGroup(iconOnly: base?.iconOnly ?? false)
        } else {
            titleLabel?.stringValue = stages[stage - 1].face.label
            titleLabel?.textColor = .labelColor
            iconView?.image = stages[stage - 1].face.image
            centreTitleGroup(iconOnly: stages[stage - 1].face.iconOnly)
            hintLabel?.stringValue = stage < stages.count ? "release to run · keep holding for more"
                                                          : "release to run"
            if crossedForward {
                pulseTitle()
                pulseTick(index: stage - 1)
            }
        }
    }

    /// Centre the icon + label as one group. Both are variable width, so this is measured rather
    /// than pinned — an icon-less stage centres the label alone, with no hole where the icon was.
    private func centreTitleGroup(iconOnly: Bool) {
        guard let title = titleLabel else { return }
        let inset: CGFloat = 22
        let maxW = cardW - inset * 2
        let image = iconView?.image

        // An app icon stands alone, centred and larger. Nothing to measure or align against.
        if iconOnly, let image = image {
            title.isHidden = true
            let side = max(image.size.width, image.size.height)
            iconView?.frame = NSRect(x: (cardW - side) / 2, y: rowMidY - side / 2,
                                     width: side, height: side)
            return
        }

        title.isHidden = false
        // Size the icon by HEIGHT, with the width following its own aspect ratio. Symbols are not
        // square — `playpause.fill` is 40x22 — and fitting one into a square box renders it at
        // barely half the height of a square symbol like `moon.fill`, so icons looked randomly
        // sized. Matching heights is what makes them read as one set.
        let iconH: CGFloat = image != nil ? 24 : 0
        let aspect = (image?.size.height ?? 0) > 0 ? image!.size.width / image!.size.height : 1
        let iconW: CGFloat = image != nil ? min((iconH * aspect).rounded(), 46) : 0
        let gap: CGFloat = image != nil ? 9 : 0

        let font = title.font ?? .systemFont(ofSize: 16, weight: .semibold)
        let measured = (title.stringValue as NSString)
            .size(withAttributes: [.font: font]).width.rounded(.up) + 4
        let textW = min(measured, maxW - iconW - gap)
        let groupW = iconW + gap + textW
        let x = (cardW - groupW) / 2
        let textH: CGFloat = 30

        title.alignment = .left
        title.frame = NSRect(x: x + iconW + gap, y: rowMidY - textH / 2, width: textW, height: textH)

        // Centre the icon on the text's CAP-HEIGHT box rather than on its frame: a label's frame
        // reserves descender room that a word like "Music" never uses, so frame-centring an icon
        // twice the cap height leaves it sitting visibly low.
        //
        // The baseline comes from AppKit rather than from ascender/descender arithmetic — a label
        // does not lay its line out the way that reconstruction assumes, and guessing put the icon
        // a few points under the text. Read it AFTER setting the frame.
        let baseline = title.frame.maxY - title.firstBaselineOffsetFromTop
        let capCentre = baseline + font.capHeight / 2
        iconView?.frame = NSRect(x: x, y: capCentre - iconH / 2, width: iconW, height: iconH)
    }

    /// Vertical centre of the title/icon row, in card coordinates. Sits a clear gap above the
    /// track — an icon is a solid block, and butting it against the bar reads as a mistake.
    private var rowMidY: CGFloat { cardH - 40 }

    /// A short lift+settle on the label, so crossing into a new stage is felt, not just read.
    private func pulseTitle() {
        guard let layer = titleLabel?.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.94
        a.toValue = 1.0
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "pulse")
    }

    private func pulseTick(index: Int) {
        guard index >= 0, index < tickLayers.count else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0
        a.toValue = 1.9
        a.duration = 0.26
        a.autoreverses = true
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tickLayers[index].add(a, forKey: "tickPulse")
    }

    // MARK: - Layout

    private func layoutTicks() {
        tickLayers.forEach { $0.removeFromSuperlayer() }
        tickLayers.removeAll()
        guard let track = trackLayer else { return }

        let trackW = track.bounds.width
        for s in stages {
            let x = trackW * CGFloat(s.threshold / maxThreshold)
            let dot = CAShapeLayer()
            let r: CGFloat = 3.0
            dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2),
                              transform: nil)
            // Clamp so the final tick's dot is not half-cut at the track's end.
            dot.position = CGPoint(x: min(max(x, r), trackW - r), y: 3)
            dot.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
            track.addSublayer(dot)
            tickLayers.append(dot)
        }
    }

    private func applyAppearanceColors() {
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(calibratedWhite: 0.26, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)
        let bot = dark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        gradient?.colors = [top.cgColor, bot.cgColor]
        trackLayer?.backgroundColor = (dark ? NSColor(calibratedWhite: 1, alpha: 0.13)
                                            : NSColor(calibratedWhite: 0, alpha: 0.10)).cgColor
    }

    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        // Same band as the layer/connection HUDs so all overlays appear in one familiar place.
        window.setFrameOrigin(NSPoint(x: vf.midX - winW / 2,
                                      y: vf.minY + vf.height * 0.18 - pad))
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let winRect = NSRect(x: 0, y: 0, width: winW, height: winH)
        let cardRect = NSRect(x: pad, y: pad, width: cardW, height: cardH)

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
        container.layer?.shadowOpacity = 0.22
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -7)
        container.layer?.shadowPath = CGPath(roundedRect: cardRect, cornerWidth: corner,
                                             cornerHeight: corner, transform: nil)

        let card = NSView(frame: cardRect)
        card.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = card.bounds
        grad.cornerRadius = corner
        grad.cornerCurve = .continuous
        grad.masksToBounds = true
        grad.startPoint = CGPoint(x: 0.5, y: 1)
        grad.endPoint = CGPoint(x: 0.5, y: 0)
        grad.borderWidth = 0.5
        grad.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.layer?.addSublayer(grad)
        card.layer?.cornerRadius = corner
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        let inset: CGFloat = 22
        let title = NSTextField(labelWithString: "—")
        title.frame = NSRect(x: inset, y: cardH - 55, width: cardW - inset * 2, height: 30)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.wantsLayer = true
        card.addSubview(title)

        let icon = NSImageView(frame: NSRect(x: 0, y: cardH - 54, width: 28, height: 28))
        icon.imageScaling = .scaleProportionallyUpOrDown
        // Symbols are template images, so this makes them carry the label's colour instead of the
        // default grey — a mid-grey glyph beside near-black text reads as a mistake. Real app icons
        // are not templates and are left in full colour, which is the point of showing them.
        icon.contentTintColor = .labelColor
        icon.wantsLayer = true
        card.addSubview(icon)

        let track = CALayer()
        track.frame = CGRect(x: inset, y: 42, width: cardW - inset * 2, height: 6)
        track.cornerRadius = 3
        track.masksToBounds = false      // ticks sit on the track and may pulse past its bounds
        card.layer?.addSublayer(track)

        let fill = CAGradientLayer()
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: 6)
        fill.cornerRadius = 3
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.colors = [NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor,
                       NSColor.controlAccentColor.cgColor]
        track.addSublayer(fill)

        let hint = NSTextField(labelWithString: "keep holding")
        hint.frame = NSRect(x: inset, y: 16, width: cardW - inset * 2, height: 16)
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        card.addSubview(hint)

        container.addSubview(card)
        win.contentView = container

        window = win
        gradient = grad
        titleLabel = title
        iconView = icon
        hintLabel = hint
        trackLayer = track
        fillLayer = fill
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
