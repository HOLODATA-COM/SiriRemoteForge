//
//  LayerHUD.swift
//  HyperVibe
//
//  A clean, BTT-style heads-up overlay shown briefly to confirm a state change on screen — a sticky
//  LAYER toggling on/off, and the remote connecting or dropping. A light (dark-mode-aware) squircle
//  card with CONTINUOUS
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

    /// `.canJoinAllSpaces` mirrors a window across Spaces, not across physical displays. Keep one
    /// real window per display so the confirmation is visible regardless of which screen the user
    /// is looking at. The windows share state and animate together.
    private final class Surface {
        let window: NSWindow
        let gradient: CAGradientLayer
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField

        init(window: NSWindow, gradient: CAGradientLayer, iconView: NSImageView,
             titleLabel: NSTextField, subtitleLabel: NSTextField) {
            self.window = window
            self.gradient = gradient
            self.iconView = iconView
            self.titleLabel = titleLabel
            self.subtitleLabel = subtitleLabel
        }
    }
    private var surfaces: [CGDirectDisplayID: Surface] = [:]

    private let holdDuration: TimeInterval = 0.9
    private var hideTimer: Timer?
    private var fadeToken = 0
    private var isShowing = false

    init() {}

    // MARK: - Public API

    // Layer switching always answers the same question — WHICH LAYER IS ACTIVE NOW — rather than
    // announcing that something was turned off. The base state is a layer too: leaving L1 does not
    // mean "no layer", it means the base layer is active again. Naming the destination keeps the
    // two cards symmetric and matches how the keys actually behave.

    /// Switched INTO a named layer (sticky).
    func showOn(_ layerName: String) {
        show(symbol: "square.stack.3d.up.fill", title: layerName, subtitle: "Layer active",
             tint: .controlAccentColor)
    }

    /// Switched back to the base layer. Same subject, outline + dimmed rather than a slash: a slash
    /// would read as "layers are off", which is exactly the wrong idea.
    func showOff(_ layerName: String) {
        show(symbol: "square.stack.3d.up", title: "Base", subtitle: "Layer active",
             tint: .secondaryLabelColor)
    }

    /// The remote connected: filled remote, green — matching the green dot in Settings.
    func showRemoteConnected() {
        show(symbol: "appletvremote.gen4.fill", title: "Siri Remote", subtitle: "Connected",
             tint: .systemGreen)
    }

    /// The remote dropped: same subject, outline + dimmed, so the state reads at a glance without
    /// changing what the icon depicts. (There is no `appletvremote.gen4.slash` symbol to use.)
    func showRemoteDisconnected() {
        show(symbol: "appletvremote.gen4", title: "Siri Remote", subtitle: "Disconnected",
             tint: .secondaryLabelColor)
    }

    // MARK: - Show / hide

    private func show(symbol: String, title: String, subtitle: String, tint: NSColor) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.syncSurfaces()
            guard !self.surfaces.isEmpty else { return }
            for surface in self.surfaces.values {
                self.applyAppearanceColors(to: surface)
                self.configure(surface, symbol: symbol, title: title, subtitle: subtitle, tint: tint)
            }
            self.fadeToken += 1
            let wasShowing = self.isShowing
            self.isShowing = true

            // Always re-order every mirror. A cached window can be removed from the visible window
            // list by a Space/full-screen transition while `isShowing` is still true; only ordering
            // on the false→true transition made later notifications silently stay hidden.
            for surface in self.surfaces.values {
                if !wasShowing { surface.window.alphaValue = 0 }
                surface.window.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = wasShowing ? 0.10 : 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for surface in self.surfaces.values {
                    surface.window.animator().alphaValue = 1
                }
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
            for surface in surfaces.values {
                surface.window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.isShowing = false
            for surface in self.surfaces.values { surface.window.orderOut(nil) }
        })
    }

    // MARK: - Content

    private func configure(_ surface: Surface, symbol: String, title: String,
                           subtitle: String, tint: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 62, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        surface.iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        surface.titleLabel.stringValue = title.isEmpty ? subtitle : title
        surface.subtitleLabel.stringValue = title.isEmpty ? "" : subtitle
    }

    /// Light card in light mode, dark card in dark mode (a subtle top→bottom gradient either way).
    private func applyAppearanceColors(to surface: Surface) {
        let dark = surface.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(calibratedWhite: 0.26, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)
        let bot = dark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        surface.gradient.colors = [top.cgColor, bot.cgColor]
    }

    // MARK: - Window

    /// Reconcile mirrors against the displays connected right now. This runs before every show, so
    /// unplugging, reconnecting or rearranging displays cannot strand the HUD on a stale screen.
    private func syncSurfaces() {
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
        }
    }

    private func position(_ window: NSWindow, on screen: NSScreen) {
        let vf = screen.visibleFrame
        // Horizontal center, lower third — where the system volume/brightness HUD sits.
        let x = vf.midX - winSide / 2
        let y = vf.minY + vf.height * 0.18 - pad
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makeSurface() -> Surface {
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
        return Surface(window: win, gradient: grad, iconView: icon,
                       titleLabel: label, subtitleLabel: sub)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
