//
//  LayerHUD.swift
//  HyperVibe
//
//  A clean, BTT-style heads-up overlay shown briefly when a sticky LAYER is toggled on or off, so
//  there's clear on-screen confirmation. A light (dark-mode-aware) squircle card with CONTINUOUS
//  (Apple-style) rounded corners, a soft shadow that follows the rounded shape, a large SF Symbol,
//  and the layer name + on/off. Borderless + click-through; fades in/out. All UI runs on main.
//
//  Note: the window itself is transparent and shadowless — the shadow lives on an inner container
//  and is masked to the card's rounded rect, so there's no square shadow halo around the corners.
//

import AppKit
import QuartzCore

final class LayerHUD {

    private let card: CGFloat = 168         // the visible squircle
    private let pad: CGFloat = 44           // transparent room around it for the soft shadow
    private let corner: CGFloat = 34
    private var winSide: CGFloat { card + pad * 2 }

    private var window: NSWindow?
    private var gradient: CAGradientLayer?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?

    private let holdDuration: TimeInterval = 0.9
    private var hideTimer: Timer?
    private var fadeToken = 0
    private var isShowing = false

    init() {}

    // MARK: - Public API

    /// A layer turned ON (sticky): accent tint, filled-layers icon.
    func showOn(_ layerName: String) {
        show(symbol: "square.stack.3d.up.fill", title: layerName, subtitle: "Layer on",
             tint: .controlAccentColor)
    }

    /// A layer turned OFF (back to base): dimmed tint, slashed-layers icon.
    func showOff(_ layerName: String) {
        show(symbol: "square.stack.3d.up.slash.fill", title: layerName, subtitle: "Layer off",
             tint: .secondaryLabelColor)
    }

    // MARK: - Show / hide

    private func show(symbol: String, title: String, subtitle: String, tint: NSColor) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            self.applyAppearanceColors()
            self.configure(symbol: symbol, title: title, subtitle: subtitle, tint: tint)
            self.fadeToken += 1
            self.positionWindow()
            if !self.isShowing {
                self.isShowing = true
                self.window?.alphaValue = 0
                self.window?.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    self.window?.animator().alphaValue = 1
                }
            } else {
                self.window?.animator().alphaValue = 1
            }
            self.resetHideTimer()
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.beginHide()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func beginHide() {
        guard isShowing else { return }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.isShowing = false
            self.window?.orderOut(nil)
        })
    }

    // MARK: - Content

    private func configure(symbol: String, title: String, subtitle: String, tint: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 62, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        iconView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        titleLabel?.stringValue = title.isEmpty ? subtitle : title
        subtitleLabel?.stringValue = title.isEmpty ? "" : subtitle
    }

    /// Light card in light mode, dark card in dark mode (a subtle top→bottom gradient either way).
    private func applyAppearanceColors() {
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(calibratedWhite: 0.26, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)
        let bot = dark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        gradient?.colors = [top.cgColor, bot.cgColor]
    }

    // MARK: - Window

    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        // Horizontal center, lower third — where the system volume/brightness HUD sits.
        let x = vf.midX - winSide / 2
        let y = vf.minY + vf.height * 0.18 - pad
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let winRect = NSRect(x: 0, y: 0, width: winSide, height: winSide)
        let cardRect = NSRect(x: pad, y: pad, width: card, height: card)

        let win = NSWindow(contentRect: winRect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false          // no square window shadow — we draw a rounded one below
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Container holds the soft shadow, clipped to the card's rounded rect (no corner halo).
        let container = NSView(frame: winRect)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.22
        container.layer?.shadowRadius = 22
        container.layer?.shadowOffset = CGSize(width: 0, height: -8)
        container.layer?.shadowPath = CGPath(roundedRect: cardRect, cornerWidth: corner,
                                             cornerHeight: corner, transform: nil)

        // The card: a solid gradient squircle with CONTINUOUS corners (the Apple squircle curve).
        let cardView = NSView(frame: cardRect)
        cardView.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = cardView.bounds
        grad.cornerRadius = corner
        grad.cornerCurve = .continuous
        grad.masksToBounds = true
        grad.startPoint = CGPoint(x: 0.5, y: 1)
        grad.endPoint = CGPoint(x: 0.5, y: 0)
        // A whisper of a hairline for definition on very light/dark backdrops.
        grad.borderWidth = 0.5
        grad.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        cardView.layer?.addSublayer(grad)
        cardView.layer?.cornerRadius = corner
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 0, y: card * 0.36, width: card, height: card * 0.40))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        cardView.addSubview(icon)

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 8, y: card * 0.19, width: card - 16, height: 24)
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        cardView.addSubview(label)

        let sub = NSTextField(labelWithString: "")
        sub.frame = NSRect(x: 8, y: card * 0.09, width: card - 16, height: 16)
        sub.alignment = .center
        sub.font = .systemFont(ofSize: 11.5, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        cardView.addSubview(sub)

        container.addSubview(cardView)
        win.contentView = container

        window = win
        gradient = grad
        iconView = icon
        titleLabel = label
        subtitleLabel = sub
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
