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

    private struct Surface {
        let panel: StatusPanel
        let cardView: NSVisualEffectView
        let cardLayer: CALayer
        let tintLayer: CAGradientLayer
        let accentLayer: CALayer
        let glowLayer: CALayer
        let contentView: NSView
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
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
    private var isMovingProgrammatically = false
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
        normalize(layers)

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.screenParametersChanged() })
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.activeSpaceChanged() })

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
            if self.enabled, !self.isTransient {
                self.present(self.idleFace(), animated: false, returningToIdle: false)
            }
        }
    }

    func setEnabled(_ wanted: Bool) {
        onMain { [weak self] in self?.setEnabledOnMain(wanted) }
    }

    /// `nil` is the base layer. A layer switch is itself a visible state transition and becomes the
    /// new resting face immediately; a stale action timer can never snap it back to the old layer.
    func setLayer(_ layer: String?, animated: Bool = true) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.currentLayerID = layer?.uppercased() ?? "BASE"
            self.idleGeneration += 1
            self.isTransient = false
            guard self.enabled else { return }
            self.present(self.idleFace(), animated: animated, returningToIdle: false)
        }
    }

    func showApplication(bundleID: String, duration: TimeInterval = 0.90) {
        onMain { [weak self] in
            guard let self = self, self.enabled else { return }
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

            let face = Face(key: "app:\(bundleID)", title: info.name, subtitle: "Active App",
                            image: info.icon, tint: self.tint(forBundleID: bundleID))
            self.presentTransient(face, duration: duration, animate: !confirmsPendingLaunch)
        }
    }

    func showAction(_ handled: Controller.HandledAction,
                    durationOverride: TimeInterval? = nil) {
        onMain { [weak self] in
            guard let self = self, self.enabled else { return }
            let now = CACurrentMediaTime()
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

            let visual = ActionVisual.resolve(handled.action, handled.presentation,
                                              prefersTargetAppIcon: false)
            let face = Face(key: "action:\(handled.key):\(visual.label)",
                            title: visual.label,
                            subtitle: self.gestureLabel(for: handled.key),
                            image: visual.image,
                            tint: self.tint(for: handled.action))

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

    // MARK: - Enable / transient lifecycle

    private func setEnabledOnMain(_ wanted: Bool) {
        guard wanted != enabled else {
            if wanted {
                ensureReachable()
                surface.panel.orderFrontRegardless()
            }
            return
        }
        enabled = wanted
        visibilityGeneration += 1
        let generation = visibilityGeneration
        idleGeneration += 1

        if wanted {
            restorePosition()
            let displayID = bestScreen(for: surface.panel.frame)?.hudDisplayID ?? 0
            print("🧭 status widget shown — display \(displayID), frame \(NSStringFromRect(surface.panel.frame))")
            isTransient = false
            currentPresentationKey = nil
            configure(face: idleFace())
            surface.panel.alphaValue = 0
            surface.panel.orderFrontRegardless()
            animateCardReveal()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.surface.panel.animator().alphaValue = 1
            }
        } else {
            pendingActivation = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.surface.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, !self.enabled,
                      self.visibilityGeneration == generation else { return }
                self.surface.panel.orderOut(nil)
            })
        }
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

    private func present(_ face: Face, animated: Bool, returningToIdle: Bool) {
        guard enabled else { return }
        ensureReachable()
        surface.panel.orderFrontRegardless()
        let contentChanges = currentPresentationKey != face.key
        if animated && contentChanges {
            animateContentTransition(returningToIdle: returningToIdle)
        }
        applyColors(face.tint, animated: animated && contentChanges)
        configure(face: face)
        currentPresentationKey = face.key
        if animated { animateCardResponse() }
    }

    private func configure(face: Face) {
        surface.iconView.image = face.image
        surface.iconView.contentTintColor = face.image?.isTemplate == true ? face.tint : nil
        surface.titleLabel.stringValue = face.title
        surface.subtitleLabel.stringValue = face.subtitle
        applyColors(face.tint, animated: false)
        currentPresentationKey = face.key
    }

    // MARK: - Faces

    private func idleFace() -> Face {
        let appearance = layerAppearance(currentLayerID)
        return Face(key: "layer:\(currentLayerID)", title: appearance.label,
                    subtitle: "Current Layer",
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
        if key.hasSuffix(".taphold3") { return "Tap + hold · stage 3" }
        if key.hasSuffix(".taphold2") { return "Tap + hold · stage 2" }
        if key.hasSuffix(".taphold") { return "Tap + hold" }
        if key.hasSuffix(".hold3") { return "Long hold · stage 3" }
        if key.hasSuffix(".hold2") { return "Long hold · stage 2" }
        if key.hasSuffix(".hold") { return "Long hold" }
        if key.hasSuffix(".triple") { return "Triple tap" }
        if key.hasSuffix(".double") { return "Double tap" }
        if key.hasSuffix(".tap") { return "Tap" }
        if key == "tap.two" { return "Two-finger tap" }
        if key.hasPrefix("swipe.") { return "Swipe" }
        if key.hasPrefix("ring.") { return "Ring" }
        return "Action"
    }

    private func duration(for key: String, action: Action) -> TimeInterval {
        if key.hasSuffix(".taphold3") || key.hasSuffix(".hold3") { return 1.35 }
        if key.hasSuffix(".taphold2") || key.hasSuffix(".hold2") { return 1.20 }
        if key.hasSuffix(".taphold") || key.hasSuffix(".hold") { return 1.05 }
        if key.hasSuffix(".triple") { return 0.92 }
        if key.hasSuffix(".double") { return 0.80 }
        switch action {
        case .launch, .appWheel: return 0.95
        default: return 0.66
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
        if let ordinal = configuredOrdinals[id] { return "Layer \(ordinal)" }
        if id == "BASE" { return "Layer 1" }
        if id.hasPrefix("L"), let number = Int(id.dropFirst()), number > 0 {
            return "Layer \(number + 1)"
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

    private func animateContentTransition(returningToIdle: Bool) {
        let transition = CATransition()
        transition.type = .push
        transition.subtype = returningToIdle ? .fromBottom : .fromTop
        transition.duration = 0.25
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.18, 1.0)
        surface.contentView.layer?.add(transition, forKey: "statusContent")
    }

    private func animateCardResponse() {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.955, 1.045, 0.992, 1.0]
        scale.keyTimes = [0.0, 0.20, 0.56, 0.82, 1.0]

        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0.0, -3.0, 2.0, -0.5, 0.0]
        hop.keyTimes = scale.keyTimes

        let group = CAAnimationGroup()
        group.animations = [scale, hop]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.18, 1.0)
        surface.cardLayer.add(group, forKey: "statusSpring")

        let iconScale = CAKeyframeAnimation(keyPath: "transform.scale")
        iconScale.values = [0.74, 1.14, 0.965, 1.0]
        iconScale.keyTimes = [0.0, 0.50, 0.78, 1.0]
        iconScale.duration = 0.40
        iconScale.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.22, 1.0)]
        surface.iconView.layer?.add(iconScale, forKey: "statusIconSpring")

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.22, 0.52, 0.20]
        pulse.keyTimes = [0.0, 0.45, 1.0]
        pulse.duration = 0.42
        surface.glowLayer.add(pulse, forKey: "statusGlowPulse")
    }

    private func animateCardReveal() {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.84, 1.035, 0.992, 1.0]
        scale.keyTimes = [0.0, 0.58, 0.82, 1.0]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [-8.0, 1.5, 0.0]
        rise.keyTimes = [0.0, 0.70, 1.0]
        let group = CAAnimationGroup()
        group.animations = [scale, rise]
        group.duration = 0.40
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0)
        surface.cardLayer.add(group, forKey: "statusReveal")
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

        let oldColors: Any?
        if let presented = surface.tintLayer.presentation()?.value(forKeyPath: "colors") {
            oldColors = presented
        } else {
            oldColors = surface.tintLayer.colors
        }
        let oldBorder = surface.cardLayer.presentation()?.borderColor ?? surface.cardLayer.borderColor
        let oldAccent = surface.accentLayer.presentation()?.backgroundColor
            ?? surface.accentLayer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.tintLayer.colors = colors
        surface.cardLayer.borderColor = border
        surface.accentLayer.backgroundColor = accent
        surface.glowLayer.backgroundColor = glow
        CATransaction.commit()

        guard animated else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.18, 1.0)
        let colorAnimation = CABasicAnimation(keyPath: "colors")
        colorAnimation.fromValue = oldColors
        colorAnimation.toValue = colors
        colorAnimation.duration = 0.30
        colorAnimation.timingFunction = timing
        surface.tintLayer.add(colorAnimation, forKey: "statusTint")

        let borderAnimation = CABasicAnimation(keyPath: "borderColor")
        borderAnimation.fromValue = oldBorder
        borderAnimation.toValue = border
        borderAnimation.duration = 0.30
        borderAnimation.timingFunction = timing
        surface.cardLayer.add(borderAnimation, forKey: "statusBorder")

        let accentAnimation = CABasicAnimation(keyPath: "backgroundColor")
        accentAnimation.fromValue = oldAccent
        accentAnimation.toValue = accent
        accentAnimation.duration = 0.30
        accentAnimation.timingFunction = timing
        surface.accentLayer.add(accentAnimation, forKey: "statusAccent")
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
        guard enabled else { return }
        moveGeneration += 1
        restorePosition()
        surface.panel.orderFrontRegardless()
    }

    private func activeSpaceChanged() {
        guard enabled else { return }
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
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.24
        root.layer?.shadowRadius = 17
        root.layer?.shadowOffset = CGSize(width: 0, height: -5)
        root.layer?.shadowPath = CGPath(roundedRect: cardFrame, cornerWidth: cornerRadius,
                                       cornerHeight: cornerRadius, transform: nil)

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

        let glow = CALayer()
        glow.frame = CGRect(x: 13, y: 12, width: 48, height: 48)
        glow.cornerRadius = 24
        glow.opacity = 0.20
        glow.shadowColor = NSColor.black.cgColor
        glow.shadowOpacity = 0
        card.layer?.addSublayer(glow)

        let content = NSView(frame: card.bounds)
        content.wantsLayer = true

        let icon = NSImageView(frame: NSRect(x: 17, y: 16, width: 40, height: 40))
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 71, y: 35, width: 118, height: 21)
        title.font = .systemFont(ofSize: 14.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.wantsLayer = true
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.frame = NSRect(x: 71, y: 17, width: 118, height: 16)
        subtitle.font = .systemFont(ofSize: 10.5, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.wantsLayer = true
        content.addSubview(subtitle)

        card.addSubview(content)
        root.addSubview(card)
        panel.contentView = root
        return Surface(panel: panel, cardView: card, cardLayer: card.layer!,
                       tintLayer: tintLayer, accentLayer: accent, glowLayer: glow,
                       contentView: content, iconView: icon,
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
