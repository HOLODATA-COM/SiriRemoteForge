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
        let cardLayer: CALayer
        let contentView: NSView
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField

        init(window: NSWindow, gradient: CAGradientLayer, cardLayer: CALayer,
             contentView: NSView, iconView: NSImageView,
             titleLabel: NSTextField, subtitleLabel: NSTextField) {
            self.window = window
            self.gradient = gradient
            self.cardLayer = cardLayer
            self.contentView = contentView
            self.iconView = iconView
            self.titleLabel = titleLabel
            self.subtitleLabel = subtitleLabel
        }
    }
    private var surfaces: [CGDirectDisplayID: Surface] = [:]

    private let holdDuration: TimeInterval
    private var hideTimer: Timer?
    private var fadeToken = 0
    private var isShowing = false
    /// Config-backed presentation keyed by BASE/L1/L2/...; normalized once so key case does not
    /// become a surprising reason for an otherwise valid definition to be ignored. Ordinals retain
    /// the authored array order for unnamed custom ids (`EDITING` can still fall back to Layer 3).
    private var configuredLayers: [String: Config.LayerDefinition]
    private var configuredOrdinals: [String: Int]
    private var configuredIcons: [String: String]
    /// Distinguishes a real in-place state change from a repeated notification. Content transitions
    /// only run when the face actually changes; repeated connection callbacks do not wobble the HUD.
    private var currentPresentationKey: String?
    private var currentSymbolName: String?

    init(layers: [Config.LayerDefinition] = [], icons: [String: String] = [:],
         holdDuration: TimeInterval = 0.9) {
        (configuredLayers, configuredOrdinals) = Self.normalized(layers)
        configuredIcons = icons
        self.holdDuration = holdDuration
    }

    /// Hot-reload hook. The next layer card uses the new label/colour without rebuilding the app.
    func configure(layers: [Config.LayerDefinition], icons: [String: String] = [:]) {
        onMain { [weak self] in
            guard let self = self else { return }
            (self.configuredLayers, self.configuredOrdinals) = Self.normalized(layers)
            self.configuredIcons = icons
        }
    }

    // MARK: - Public API

    // Layer switching always answers the same question — WHICH LAYER IS ACTIVE NOW — rather than
    // announcing that something was turned off. The base state is a layer too: leaving L1 does not
    // mean "no layer", it means the base layer is active again. Naming the destination keeps the
    // two cards symmetric and matches how the keys actually behave.

    /// Switched INTO a named layer (sticky).
    func showOn(_ layerName: String) {
        let appearance = appearance(forLayer: layerName)
        show(symbol: appearance.icon, title: appearance.label,
             subtitle: L("Layer active"),
             tint: appearance.tint, cue: .layer,
             presentationKey: "layer:\(layerName.uppercased())")
    }

    /// Switched back to the base layer. Same subject, outline + dimmed rather than a slash: a slash
    /// would read as "layers are off", which is exactly the wrong idea.
    func showOff(_ layerName: String) {
        let appearance = appearance(forLayer: "BASE")
        show(symbol: appearance.icon, title: appearance.label,
             subtitle: L("Layer active"),
             tint: appearance.tint, cue: .layer, presentationKey: "layer:BASE")
    }

    /// The remote connected: filled remote, green — matching the green dot in Settings.
    func showRemoteConnected() {
        show(symbol: configuredIcon("remote.connected", fallback: "appletvremote.gen4.fill"),
             title: "Siri Remote", subtitle: L("Connected"),
             tint: .systemGreen, cue: .connected, presentationKey: "remote:connected")
    }

    /// The remote dropped: same subject in outline form. System orange communicates an interruption
    /// that needs attention without mislabelling it as destructive red.
    func showRemoteDisconnected() {
        show(symbol: configuredIcon("remote.disconnected", fallback: "appletvremote.gen4"),
             title: "Siri Remote", subtitle: L("Disconnected"),
             tint: .systemOrange, cue: .disconnected, presentationKey: "remote:disconnected")
    }

    /// Immediately remove every mirrored HUD surface when its JSON visibility setting is disabled.
    /// A pending fade completion is invalidated so it cannot mutate a later re-enabled presentation.
    func hideImmediately() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.hideTimer?.invalidate()
            self.hideTimer = nil
            self.fadeToken += 1
            self.isShowing = false
            self.currentPresentationKey = nil
            self.currentSymbolName = nil
            for surface in self.surfaces.values {
                surface.window.alphaValue = 0
                surface.window.orderOut(nil)
            }
        }
    }

    // MARK: - Show / hide

    private func show(symbol: String, title: String, subtitle: String, tint: NSColor,
                      cue: ActionSymbolCue,
                      presentationKey: String) {
        onMain { [weak self] in
            guard let self = self else { return }
            let symbol = ActionVisual.firstValidSystemSymbol(
                [symbol, self.configuredIcons["fallback"]], fallback: "command.circle.fill"
            )
            self.syncSurfaces()
            guard !self.surfaces.isEmpty else { return }
            let wasShowing = self.isShowing
            let contentIsChanging = wasShowing && self.currentPresentationKey != presentationKey
            let isLayerRoll = contentIsChanging
                && self.currentPresentationKey?.hasPrefix("layer:") == true
                && presentationKey.hasPrefix("layer:")
            for surface in self.surfaces.values {
                if contentIsChanging {
                    self.prepareContentTransition(on: surface, layerRoll: isLayerRoll)
                }
                self.applyAppearanceColors(to: surface, tint: tint, animated: contentIsChanging)
                self.configure(surface, symbol: symbol, title: title, subtitle: subtitle, tint: tint,
                               cue: cue, animateSymbol: contentIsChanging || !wasShowing)
                if isLayerRoll {
                    self.animateLayerRoll(on: surface)
                } else if contentIsChanging {
                    self.animateStateChange(on: surface)
                } else if !wasShowing {
                    self.animateReveal(on: surface)
                }
            }
            self.currentPresentationKey = presentationKey
            self.currentSymbolName = symbol
            self.fadeToken += 1
            self.isShowing = true

            // Always re-order every mirror. A cached window can be removed from the visible window
            // list by a Space/full-screen transition while `isShowing` is still true; only ordering
            // on the false→true transition made later notifications silently stay hidden.
            for surface in self.surfaces.values {
                if !wasShowing { surface.window.alphaValue = 0 }
                surface.window.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = wasShowing ? 0.16 : 0.20
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
                           subtitle: String, tint: NSColor,
                           cue: ActionSymbolCue, animateSymbol: Bool) {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 62, weight: .medium))
        let image = ActionSymbolStyle.hierarchicalImage(base, symbolName: symbol, tint: tint)
        surface.iconView.contentTintColor = nil
        if animateSymbol,
           ActionSymbolStyle.supportsTopologyAwareReplacement(
               from: currentSymbolName, to: symbol
           ),
           #available(macOS 14.0, *), let image,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ActionSymbolStyle.replaceSymbol(in: surface.iconView, with: image, cue: cue)
        } else {
            surface.iconView.image = image
            if animateSymbol, #available(macOS 14.0, *) {
                ActionSymbolStyle.apply(cue, to: surface.iconView)
            }
        }
        surface.titleLabel.stringValue = title.isEmpty ? subtitle : title
        surface.subtitleLabel.stringValue = title.isEmpty ? "" : subtitle
    }

    /// BASE, L1 and L2 use deliberately distant points in the system palette. Future numbered
    /// layers continue round a stable palette rather than falling back to the user's accent colour,
    /// so two layers can never become indistinguishable merely because macOS accent is blue.
    private func tint(forLayer rawName: String) -> NSColor {
        let name = rawName.uppercased()
        if name == "BASE" { return .systemGreen }
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange,
                                  .systemPink, .systemTeal, .systemIndigo]
        if name.hasPrefix("L"), let number = Int(name.dropFirst()), number > 0 {
            return palette[(number - 1) % palette.count]
        }
        return .systemBlue
    }

    private func appearance(forLayer rawName: String) -> (label: String, tint: NSColor, icon: String) {
        let style = configuredLayers[rawName.uppercased()]
        let configuredLabel = style?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = configuredLabel.flatMap { $0.isEmpty ? nil : $0 }
            ?? displayName(forLayer: rawName)
        let tint = style?.color.flatMap(configuredColor(named:)) ?? tint(forLayer: rawName)
        let icon = ActionVisual.firstValidSystemSymbol(
            [style?.icon, configuredIcons["layer.default"], configuredIcons["fallback"]],
            fallback: "square.stack.3d.up.fill"
        )
        return (label, tint, icon)
    }

    private func configuredIcon(_ key: String, fallback: String) -> String {
        ActionVisual.firstValidSystemSymbol(
            [configuredIcons[key], configuredIcons["fallback"]], fallback: fallback
        )
    }

    private static func normalized(_ layers: [Config.LayerDefinition])
        -> ([String: Config.LayerDefinition], [String: Int]) {
        var definitions: [String: Config.LayerDefinition] = [:]
        var ordinals: [String: Int] = [:]
        for (index, layer) in layers.enumerated() {
            let key = layer.id.uppercased()
            definitions[key] = layer
            ordinals[key] = index + 1
        }
        return (definitions, ordinals)
    }

    /// Accept adaptive macOS system colours for the common case and CSS-style hex for arbitrary
    /// brand palettes. #RRGGBBAA uses the conventional final alpha byte.
    private func configuredColor(named rawValue: String) -> NSColor? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "accent", "accentcolor", "controlaccentcolor": return .controlAccentColor
        case "red", "systemred":       return .systemRed
        case "orange", "systemorange": return .systemOrange
        case "yellow", "systemyellow": return .systemYellow
        case "green", "systemgreen":   return .systemGreen
        case "mint", "systemmint":     return .systemMint
        case "teal", "systemteal":     return .systemTeal
        case "cyan", "systemcyan":     return .systemCyan
        case "blue", "systemblue":     return .systemBlue
        case "indigo", "systemindigo": return .systemIndigo
        case "purple", "systempurple": return .systemPurple
        case "pink", "systempink":     return .systemPink
        case "brown", "systembrown":   return .systemBrown
        case "gray", "grey", "systemgray", "systemgrey": return .systemGray
        default: return colorFromHex(value)
        }
    }

    private func colorFromHex(_ value: String) -> NSColor? {
        guard value.hasPrefix("#") else { return nil }
        let digits = String(value.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              let packed = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let red = CGFloat((packed >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((packed >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((packed >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? CGFloat(packed & 0xff) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Config uses BASE/L1/L2 because layers are modifiers over an unlayered mode. The HUD speaks
    /// in user-facing ordinals instead: BASE is the first layer, config L1 the second, and so on.
    /// Keeping this translation at the presentation boundary avoids leaking implementation names.
    private func displayName(forLayer rawName: String) -> String {
        let name = rawName.uppercased()
        if let ordinal = configuredOrdinals[name] { return L("Layer %d", ordinal) }
        if name == "BASE" { return L("Layer 1") }
        if name.hasPrefix("L"), let number = Int(name.dropFirst()), number > 0 {
            return L("Layer %d", number + 1)
        }
        return rawName
    }

    /// Light card in light mode, dark card in dark mode. The layer tint is washed gently into the
    /// neutral material, making the state readable from the whole silhouette rather than only the
    /// icon. Explicit colour animations preserve continuity through rapid layer taps.
    private func applyAppearanceColors(to surface: Surface, tint: NSColor, animated: Bool) {
        let dark = surface.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let neutralTop = dark ? NSColor(calibratedWhite: 0.25, alpha: 1)
                              : NSColor(calibratedWhite: 0.995, alpha: 1)
        let neutralBottom = dark ? NSColor(calibratedWhite: 0.16, alpha: 1)
                                 : NSColor(calibratedWhite: 0.93, alpha: 1)
        let top = neutralTop.blended(withFraction: dark ? 0.19 : 0.08, of: tint) ?? neutralTop
        let bottom = neutralBottom.blended(withFraction: dark ? 0.12 : 0.13, of: tint) ?? neutralBottom
        let colors = [top.cgColor, bottom.cgColor]
        let border = tint.withAlphaComponent(dark ? 0.30 : 0.22).cgColor

        let oldColors: Any?
        if let presentedColors = surface.gradient.presentation()?.value(forKeyPath: "colors") {
            oldColors = presentedColors
        } else {
            oldColors = surface.gradient.colors
        }
        let oldBorder = surface.gradient.presentation()?.borderColor
            ?? surface.gradient.borderColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.gradient.colors = colors
        surface.gradient.borderColor = border
        CATransaction.commit()

        guard animated else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1.0)
        let colorAnimation = CABasicAnimation(keyPath: "colors")
        colorAnimation.fromValue = oldColors
        colorAnimation.toValue = colors
        colorAnimation.duration = 0.34
        colorAnimation.timingFunction = timing
        surface.gradient.add(colorAnimation, forKey: "layerTint")

        let borderAnimation = CABasicAnimation(keyPath: "borderColor")
        borderAnimation.fromValue = oldBorder
        borderAnimation.toValue = border
        borderAnimation.duration = 0.34
        borderAnimation.timingFunction = timing
        surface.gradient.add(borderAnimation, forKey: "layerBorderTint")
    }

    /// Core Animation snapshots the old contents for CATransition. Layer-to-layer changes always
    /// advance vertically: the old layer rolls above the centre axis while the next one enters
    /// from below. That direction remains constant across the final→first wrap, so the configured
    /// layer list reads as one continuous wheel rather than reversing at its seam.
    private func prepareContentTransition(on surface: Surface, layerRoll: Bool) {
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1.0)
        let transition = CATransition()
        transition.type = .push
        transition.subtype = layerRoll ? .fromBottom : .fromRight
        transition.duration = layerRoll ? 0.34 : 0.30
        transition.timingFunction = timing
        surface.contentView.layer?.add(transition, forKey: "layerContent")
    }

    /// The content container's default anchor point is its centre. A small perspective X rotation
    /// there turns the vertical push into a cylindrical-picker roll without moving or scaling the
    /// card itself — important for a control that may animate on every layer tap.
    private func animateLayerRoll(on surface: Surface) {
        let pitch = CAKeyframeAnimation(keyPath: "transform")
        pitch.values = [rollTransform(angle: 0),
                        rollTransform(angle: -0.105),
                        rollTransform(angle: 0.030),
                        rollTransform(angle: 0)]
        pitch.keyTimes = [0.0, 0.36, 0.76, 1.0]
        pitch.duration = 0.34
        pitch.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.30, 0.0, 0.34, 1.0),
            CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0),
            CAMediaTimingFunction(name: .easeOut),
        ]
        surface.contentView.layer?.add(pitch, forKey: "layerRollPitch")
    }

    private func rollTransform(angle: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 520
        return CATransform3DRotate(transform, angle, 1, 0, 0)
    }

    /// Non-layer state changes use depth on the icon only. The card remains a stable reference and
    /// the authored symbol layers carry the actual connect/disconnect punctuation.
    private func animateStateChange(on surface: Surface) {
        var away = CATransform3DIdentity
        away.m34 = -1 / 460
        away = CATransform3DRotate(away, -0.13, 0, 1, 0)
        away = CATransform3DTranslate(away, 0, 0, -6)
        var settle = CATransform3DIdentity
        settle.m34 = -1 / 460
        settle = CATransform3DRotate(settle, 0.025, 0, 1, 0)
        let turn = CAKeyframeAnimation(keyPath: "transform")
        turn.values = [NSValue(caTransform3D: away), NSValue(caTransform3D: settle),
                       NSValue(caTransform3D: CATransform3DIdentity)]
        turn.keyTimes = [0.0, 0.74, 1.0]
        turn.duration = 0.26
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0)
        surface.iconView.layer?.add(turn, forKey: "connectionIconDepth")
    }

    /// First presentation is distinct from an in-place switch: rise softly from below and settle,
    /// while the window itself fades in. Keeping the two motions separate avoids a generic pop.
    private func animateReveal(on surface: Surface) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.88, 1.025, 0.995, 1.0]
        scale.keyTimes = [0.0, 0.58, 0.82, 1.0]

        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [-9.0, 1.5, 0.0]
        rise.keyTimes = [0.0, 0.70, 1.0]

        let group = CAAnimationGroup()
        group.animations = [scale, rise]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0)
        surface.cardLayer.add(group, forKey: "layerReveal")
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
        win.alphaValue = 0
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

        // Typography rolls as one wheel segment. The symbol deliberately lives outside this view:
        // its three authored layers rebuild in place instead of the whole icon sliding like text.
        let content = NSView(frame: cardView.bounds)
        content.wantsLayer = true

        let icon = NSImageView(frame: NSRect(x: 0, y: card * 0.36, width: card, height: card * 0.40))
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        cardView.addSubview(icon)

        let label = NSTextField(labelWithString: "")
        label.wantsLayer = true
        label.frame = NSRect(x: 8, y: card * 0.19, width: card - 16, height: 24)
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)

        let sub = NSTextField(labelWithString: "")
        sub.wantsLayer = true
        sub.frame = NSRect(x: 8, y: card * 0.09, width: card - 16, height: 16)
        sub.alignment = .center
        sub.font = .systemFont(ofSize: 11.5, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        content.addSubview(sub)

        cardView.addSubview(content)

        container.addSubview(cardView)
        win.contentView = container
        return Surface(window: win, gradient: grad, cardLayer: cardView.layer!,
                       contentView: content, iconView: icon,
                       titleLabel: label, subtitleLabel: sub)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
